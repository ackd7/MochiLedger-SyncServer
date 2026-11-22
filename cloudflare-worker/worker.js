/**
 * MochiLedger Serverless Sync Server for Cloudflare Workers + Cloudflare KV.
 *
 * Bindings required in Cloudflare Workers:
 *   - KV Namespace binding: MOCHI_KV
 *   - Secret / Environment Variable: MOCHI_SYNC_TOKEN (optional; recommended for auth)
 *
 * Endpoints (100% compatible with MochiLedger Windows & Android clients):
 *   - GET  /api/v1/health
 *   - POST /api/v1/sync
 *   - GET  /api/v1/ledger/:ledgerId
 */

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return corsResponse(null, 204);
    }

    if (!isAuthorized(request, env)) {
      return jsonResponse({ error: "Invalid Bearer token" }, 401);
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    try {
      if (request.method === "GET" && (path === "/" || path === "/api/v1/health")) {
        return jsonResponse({
          status: "ok",
          service: "MochiLedger Sync Server (Cloudflare Workers)",
          version: "1.0.0",
          kvBound: Boolean(env.MOCHI_KV),
          serverTime: Date.now(),
        });
      }

      if (!env.MOCHI_KV) {
        return jsonResponse(
          { ok: false, error: "MOCHI_KV namespace is not bound in Cloudflare Worker settings." },
          500,
        );
      }

      if (request.method === "POST" && path === "/api/v1/sync") {
        const body = await request.json();
        const ledgerId = sanitizeLedgerId(body?.ledgerId);
        const deviceId = String(body?.deviceId || "");
        const incoming = body?.snapshot;

        if (!incoming || typeof incoming !== "object") {
          return jsonResponse({ ok: false, error: "Missing snapshot object" }, 400);
        }

        const key = `ledger:${ledgerId}`;
        const existingRaw = await env.MOCHI_KV.get(key);
        const existing = existingRaw ? JSON.parse(existingRaw) : null;
        const now = Date.now();
        const merged = existing ? mergeSnapshots(existing, incoming, now, deviceId) : {
          ...incoming,
          exportedAt: now,
          sourceDeviceId: deviceId || incoming.sourceDeviceId || "",
        };

        await env.MOCHI_KV.put(key, JSON.stringify(merged));

        return jsonResponse({
          ok: true,
          serverTime: now,
          mergedSnapshot: merged,
          message: `Synced ledger '${ledgerId}' on Cloudflare KV`,
        });
      }

      const ledgerMatch = path.match(/^\/api\/v1\/ledger\/([^/]+)$/);
      if (request.method === "GET" && ledgerMatch) {
        const ledgerId = sanitizeLedgerId(decodeURIComponent(ledgerMatch[1]));
        const raw = await env.MOCHI_KV.get(`ledger:${ledgerId}`);
        if (!raw) {
          return jsonResponse({ error: "Ledger not found" }, 404);
        }
        return corsResponse(raw, 200, "application/json; charset=utf-8");
      }

      return jsonResponse({ error: "Not Found" }, 404);
    } catch (err) {
      return jsonResponse(
        { ok: false, error: err instanceof Error ? err.message : String(err) },
        500,
      );
    }
  },
};

function isAuthorized(request, env) {
  const required = (env.MOCHI_SYNC_TOKEN || "").trim();
  if (!required) return true;
  const authHeader = (request.headers.get("Authorization") || "").trim();
  return authHeader === `Bearer ${required}`;
}

function sanitizeLedgerId(raw) {
  const cleaned = String(raw || "default").replace(/[^a-zA-Z0-9_-]/g, "_");
  return cleaned || "default";
}

function mergeSnapshots(existing, incoming, now, deviceId) {
  const rawAccounts = mergeById(existing.accounts || [], incoming.accounts || []);
  const accounts = deduplicateAccounts(rawAccounts);
  const aliasMap = buildAccountAliasMap(rawAccounts, accounts);

  const remappedTx = mergeById(existing.transactions || [], incoming.transactions || []).map((tx) => ({
    ...tx,
    accountId: aliasMap.get(tx.accountId) || tx.accountId,
    targetAccountId: tx.targetAccountId ? (aliasMap.get(tx.targetAccountId) || tx.targetAccountId) : tx.targetAccountId,
  }));
  const transactions = deduplicateTransactions(remappedTx);

  return {
    ...existing,
    ...incoming,
    schemaVersion: Math.max(Number(existing.schemaVersion || 1), Number(incoming.schemaVersion || 1)),
    exportedAt: now,
    sourceDeviceId: deviceId || incoming.sourceDeviceId || "",
    accounts,
    categories: mergeById(existing.categories || [], incoming.categories || []),
    transactions,
    budgets: mergeById(existing.budgets || [], incoming.budgets || []),
    rules: mergeById(existing.rules || [], incoming.rules || []),
  };
}

function mergeById(baseList, incomingList) {
  const map = new Map();
  for (const item of baseList) {
    if (item && item.id) map.set(item.id, item);
  }
  for (const item of incomingList) {
    if (!item || !item.id) continue;
    const prev = map.get(item.id);
    const prevTs = Number(prev?.updatedAt ?? -1);
    const nextTs = Number(item.updatedAt ?? 0);
    if (!prev || nextTs >= prevTs) {
      map.set(item.id, item);
    }
  }
  return Array.from(map.values());
}

function deduplicateAccounts(accounts) {
  const deleted = accounts.filter((a) => a.isDeleted);
  const activeByKey = new Map();
  for (const acc of accounts.filter((a) => !a.isDeleted)) {
    const key = `${String(acc.name || "").trim().toLowerCase()}|${acc.type || ""}`;
    const existing = activeByKey.get(key);
    if (!existing || Number(acc.updatedAt || 0) > Number(existing.updatedAt || 0)) {
      activeByKey.set(key, acc);
    }
  }
  return [...activeByKey.values(), ...deleted];
}

function buildAccountAliasMap(allAccounts, keptAccounts) {
  const canonical = new Map();
  for (const acc of keptAccounts.filter((a) => !a.isDeleted)) {
    const key = `${String(acc.name || "").trim().toLowerCase()}|${acc.type || ""}`;
    canonical.set(key, acc.id);
  }
  const alias = new Map();
  for (const acc of allAccounts.filter((a) => !a.isDeleted)) {
    const key = `${String(acc.name || "").trim().toLowerCase()}|${acc.type || ""}`;
    const targetId = canonical.get(key);
    if (targetId && targetId !== acc.id) {
      alias.set(acc.id, targetId);
    }
  }
  return alias;
}

function deduplicateTransactions(transactions) {
  const deleted = transactions.filter((t) => t.isDeleted);
  const byFp = new Map();
  for (const tx of transactions.filter((t) => !t.isDeleted)) {
    const fp = [
      tx.type || "",
      String(tx.amountCents ?? 0),
      String(Math.floor(Number(tx.timestamp || 0) / 1000)),
      tx.accountId || "",
      tx.targetAccountId || "",
      String(tx.merchant || "").trim().toLowerCase(),
      String(tx.note || "").trim().toLowerCase(),
    ].join("|");
    const existing = byFp.get(fp);
    if (!existing || Number(tx.updatedAt || 0) > Number(existing.updatedAt || 0)) {
      byFp.set(fp, tx);
    }
  }
  return [...byFp.values(), ...deleted];
}

function jsonResponse(data, status = 200) {
  return corsResponse(JSON.stringify(data), status, "application/json; charset=utf-8");
}

function corsResponse(body, status = 200, contentType = null) {
  const headers = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
  if (contentType) headers["Content-Type"] = contentType;
  return new Response(body, { status, headers });
}
