package com.mochiledger.server

import io.ktor.client.request.get
import io.ktor.client.request.header
import io.ktor.client.request.post
import io.ktor.client.request.setBody
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.server.testing.testApplication
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class SyncServerTest {

    @Test
    fun healthAndAuthCheck() = testApplication {
        val tmpDir = Files.createTempDirectory("mochi-sync-test").toFile()
        application {
            mochiSyncModule(dataDir = tmpDir, requiredToken = "secret-123")
        }

        val unauth = client.get("/api/v1/health")
        assertEquals(HttpStatusCode.Unauthorized, unauth.status)

        val ok = client.get("/api/v1/health") {
            header(HttpHeaders.Authorization, "Bearer secret-123")
        }
        assertEquals(HttpStatusCode.OK, ok.status)
        assertTrue(ok.bodyAsText().contains("MochiLedger Sync Server"))
    }

    @Test
    fun bidirectionalLwwSyncAcrossDevices() = testApplication {
        val tmpDir = Files.createTempDirectory("mochi-sync-merge").toFile()
        application {
            mochiSyncModule(dataDir = tmpDir, requiredToken = "token-abc")
        }

        val winPayload = """
            {
              "ledgerId": "personal",
              "deviceId": "win-1",
              "snapshot": {
                "schemaVersion": 1,
                "exportedAt": 1000,
                "sourceDeviceId": "win-1",
                "accounts": [],
                "categories": [],
                "transactions": [
                  {"id": "tx1", "merchant": "Windows记录", "updatedAt": 1000}
                ],
                "budgets": [],
                "rules": []
              }
            }
        """.trimIndent()

        val resp1 = client.post("/api/v1/sync") {
            header(HttpHeaders.Authorization, "Bearer token-abc")
            contentType(ContentType.Application.Json)
            setBody(winPayload)
        }
        assertEquals(HttpStatusCode.OK, resp1.status)

        val androidPayload = """
            {
              "ledgerId": "personal",
              "deviceId": "and-1",
              "snapshot": {
                "schemaVersion": 1,
                "exportedAt": 2000,
                "sourceDeviceId": "and-1",
                "accounts": [],
                "categories": [],
                "transactions": [
                  {"id": "tx2", "merchant": "Android自动记账", "updatedAt": 2000}
                ],
                "budgets": [],
                "rules": []
              }
            }
        """.trimIndent()

        val resp2 = client.post("/api/v1/sync") {
            header(HttpHeaders.Authorization, "Bearer token-abc")
            contentType(ContentType.Application.Json)
            setBody(androidPayload)
        }
        assertEquals(HttpStatusCode.OK, resp2.status)
        val mergedText = resp2.bodyAsText()
        assertTrue(mergedText.contains("tx1"))
        assertTrue(mergedText.contains("tx2"))
    }
}
