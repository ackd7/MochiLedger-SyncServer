package com.mochiledger.server

import io.ktor.http.HttpStatusCode
import io.ktor.serialization.kotlinx.json.json
import io.ktor.server.application.Application
import io.ktor.server.application.install
import io.ktor.server.engine.embeddedServer
import io.ktor.server.netty.Netty
import io.ktor.server.plugins.calllogging.CallLogging
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.plugins.statuspages.StatusPages
import io.ktor.server.request.receive
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.io.File
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.read
import kotlin.concurrent.write

@Serializable
data class HealthResponse(
    val status: String = "ok",
    val service: String = "MochiLedger Sync Server",
    val version: String = "1.0.0",
    val serverTime: Long = System.currentTimeMillis(),
)

@Serializable
data class GenericSyncRequest(
    val ledgerId: String = "default",
    val deviceId: String = "",
    val snapshot: JsonObject,
)

@Serializable
data class GenericSyncResponse(
    val ok: Boolean,
    val serverTime: Long,
    val mergedSnapshot: JsonObject,
    val message: String,
)

private val serverJson = Json {
    prettyPrint = true
    ignoreUnknownKeys = true
    encodeDefaults = true
}

/**
 * Deterministic LWW (Last-Write-Wins) JSON snapshot merger matching LedgerMerger in :shared.
 */
object SnapshotStore {
    private val lock = ReentrantReadWriteLock()

    fun mergeAndSave(dataDir: File, ledgerId: String, incoming: JsonObject, deviceId: String): JsonObject {
        val safeLedger = ledgerId.replace(Regex("[^a-zA-Z0-9_-]"), "_").ifBlank { "default" }
        val ledgerFile = File(dataDir, "$safeLedger.mochi.json")
        val now = System.currentTimeMillis()

        return lock.write {
            dataDir.mkdirs()
            val merged = if (ledgerFile.exists()) {
                val existing = runCatching {
                    serverJson.parseToJsonElement(ledgerFile.readText(Charsets.UTF_8)).jsonObject
                }.getOrNull()
                if (existing != null) mergeSnapshots(existing, incoming, now, deviceId) else incoming
            } else {
                incoming
            }
            ledgerFile.writeText(serverJson.encodeToString(merged), Charsets.UTF_8)
            merged
        }
    }

    fun readSnapshot(dataDir: File, ledgerId: String): JsonObject? {
        val safeLedger = ledgerId.replace(Regex("[^a-zA-Z0-9_-]"), "_").ifBlank { "default" }
        val ledgerFile = File(dataDir, "$safeLedger.mochi.json")
        return lock.read {
            if (!ledgerFile.exists()) return@read null
            runCatching {
                serverJson.parseToJsonElement(ledgerFile.readText(Charsets.UTF_8)).jsonObject
            }.getOrNull()
        }
    }

    private fun mergeSnapshots(
        existing: JsonObject,
        incoming: JsonObject,
        now: Long,
        deviceId: String,
    ): JsonObject {
        val keys = listOf("accounts", "categories", "transactions", "budgets", "rules")
        val result = existing.toMutableMap()
        result["schemaVersion"] = incoming["schemaVersion"] ?: existing["schemaVersion"] ?: serverJson.parseToJsonElement("1")
        result["exportedAt"] = serverJson.parseToJsonElement(now.toString())
        result["sourceDeviceId"] = serverJson.parseToJsonElement("\"$deviceId\"")

        for (key in keys) {
            val baseList = existing[key]?.jsonArray?.toList().orEmpty()
            val newList = incoming[key]?.jsonArray?.toList().orEmpty()
            result[key] = kotlinx.serialization.json.JsonArray(mergeEntityArray(baseList, newList))
        }
        return JsonObject(result)
    }

    private fun mergeEntityArray(base: List<JsonElement>, incoming: List<JsonElement>): List<JsonElement> {
        val map = LinkedHashMap<String, JsonElement>()
        for (el in base) {
            val id = el.jsonObject["id"]?.jsonPrimitive?.content ?: continue
            map[id] = el
        }
        for (el in incoming) {
            val obj = el.jsonObject
            val id = obj["id"]?.jsonPrimitive?.content ?: continue
            val incomingTs = obj["updatedAt"]?.jsonPrimitive?.longOrNull ?: 0L
            val currentTs = map[id]?.jsonObject?.get("updatedAt")?.jsonPrimitive?.longOrNull ?: -1L
            if (map[id] == null || incomingTs >= currentTs) {
                map[id] = el
            }
        }
        return map.values.toList()
    }
}

fun Application.mochiSyncModule(
    dataDir: File = File(System.getenv("MOCHI_DATA_DIR") ?: "./data"),
    requiredToken: String = System.getenv("MOCHI_SYNC_TOKEN") ?: "",
) {
    install(CallLogging)
    install(ContentNegotiation) {
        json(serverJson)
    }
    install(StatusPages) {
        exception<Throwable> { call, cause ->
            call.respond(
                HttpStatusCode.InternalServerError,
                mapOf("ok" to "false", "error" to (cause.message ?: "Internal server error")),
            )
        }
    }

    fun isAuthorized(authHeader: String?): Boolean {
        if (requiredToken.isBlank()) return true
        return authHeader?.trim() == "Bearer $requiredToken"
    }

    routing {
        get("/api/v1/health") {
            if (!isAuthorized(call.request.headers["Authorization"])) {
                call.respond(HttpStatusCode.Unauthorized, mapOf("error" to "Invalid Bearer token"))
                return@get
            }
            call.respond(HealthResponse())
        }

        post("/api/v1/sync") {
            if (!isAuthorized(call.request.headers["Authorization"])) {
                call.respond(HttpStatusCode.Unauthorized, mapOf("error" to "Invalid Bearer token"))
                return@post
            }
            val req = call.receive<GenericSyncRequest>()
            val merged = SnapshotStore.mergeAndSave(dataDir, req.ledgerId, req.snapshot, req.deviceId)
            call.respond(
                GenericSyncResponse(
                    ok = true,
                    serverTime = System.currentTimeMillis(),
                    mergedSnapshot = merged,
                    message = "Synced ledger '${req.ledgerId}'",
                ),
            )
        }

        get("/api/v1/ledger/{ledgerId}") {
            if (!isAuthorized(call.request.headers["Authorization"])) {
                call.respond(HttpStatusCode.Unauthorized, mapOf("error" to "Invalid Bearer token"))
                return@get
            }
            val ledgerId = call.parameters["ledgerId"] ?: "default"
            val snap = SnapshotStore.readSnapshot(dataDir, ledgerId)
            if (snap == null) {
                call.respond(HttpStatusCode.NotFound, mapOf("error" to "Ledger not found"))
            } else {
                call.respond(snap)
            }
        }
    }
}

fun main() {
    val port = System.getenv("MOCHI_PORT")?.toIntOrNull() ?: 8787
    val host = System.getenv("MOCHI_HOST") ?: "0.0.0.0"
    println("[MochiLedger Sync Server] Listening on http://$host:$port")
    embeddedServer(Netty, port = port, host = host) {
        mochiSyncModule()
    }.start(wait = true)
}
