package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

type HealthResponse struct {
	Status     string `json:"status"`
	Service    string `json:"service"`
	Version    string `json:"version"`
	ServerTime int64  `json:"serverTime"`
}

type SyncRequest struct {
	LedgerID string                 `json:"ledgerId"`
	DeviceID string                 `json:"deviceId"`
	Snapshot map[string]interface{} `json:"snapshot"`
}

type SyncResponse struct {
	OK             bool                   `json:"ok"`
	ServerTime     int64                  `json:"serverTime"`
	MergedSnapshot map[string]interface{} `json:"mergedSnapshot"`
	Message        string                 `json:"message"`
}

type Store struct {
	mu      sync.RWMutex
	dataDir string
}

var safeIDRegex = regexp.MustCompile(`[^a-zA-Z0-9_-]`)

func sanitizeLedgerID(raw string) string {
	s := safeIDRegex.ReplaceAllString(strings.TrimSpace(raw), "_")
	if s == "" {
		return "default"
	}
	return s
}

func (s *Store) ledgerPath(ledgerID string) string {
	return filepath.Join(s.dataDir, sanitizeLedgerID(ledgerID)+".mochi.json")
}

func (s *Store) Read(ledgerID string) (map[string]interface{}, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	b, err := os.ReadFile(s.ledgerPath(ledgerID))
	if err != nil {
		return nil, err
	}
	var snap map[string]interface{}
	if err := json.Unmarshal(b, &snap); err != nil {
		return nil, err
	}
	return snap, nil
}

func (s *Store) MergeAndSave(ledgerID, deviceID string, incoming map[string]interface{}) (map[string]interface{}, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if err := os.MkdirAll(s.dataDir, 0o755); err != nil {
		return nil, err
	}

	path := s.ledgerPath(ledgerID)
	now := time.Now().UnixMilli()

	var existing map[string]interface{}
	if b, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(b, &existing)
	}

	var merged map[string]interface{}
	if existing != nil && len(existing) > 0 {
		merged = mergeSnapshots(existing, incoming, now, deviceID)
	} else {
		merged = cloneMap(incoming)
		merged["exportedAt"] = now
		if deviceID != "" {
			merged["sourceDeviceId"] = deviceID
		}
	}

	encoded, err := json.MarshalIndent(merged, "", "  ")
	if err != nil {
		return nil, err
	}

	tmpPath := path + ".tmp"
	if err := os.WriteFile(tmpPath, encoded, 0o600); err != nil {
		return nil, err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return nil, err
	}
	return merged, nil
}

func cloneMap(src map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}

func toMapSlice(v interface{}) []map[string]interface{} {
	arr, ok := v.([]interface{})
	if !ok {
		return nil
	}
	res := make([]map[string]interface{}, 0, len(arr))
	for _, el := range arr {
		if m, ok := el.(map[string]interface{}); ok {
			res = append(res, m)
		}
	}
	return res
}

func asInt64(v interface{}) int64 {
	switch t := v.(type) {
	case float64:
		return int64(t)
	case int64:
		return t
	case int:
		return int64(t)
	case json.Number:
		n, _ := t.Int64()
		return n
	default:
		return 0
	}
}

func asString(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func asBool(v interface{}) bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

func mergeByID(base, incoming []map[string]interface{}) []map[string]interface{} {
	order := make([]string, 0, len(base)+len(incoming))
	byID := make(map[string]map[string]interface{}, len(base)+len(incoming))

	for _, item := range base {
		id := asString(item["id"])
		if id == "" {
			continue
		}
		if _, exists := byID[id]; !exists {
			order = append(order, id)
		}
		byID[id] = item
	}
	for _, item := range incoming {
		id := asString(item["id"])
		if id == "" {
			continue
		}
		prev, exists := byID[id]
		if !exists {
			order = append(order, id)
			byID[id] = item
		} else if asInt64(item["updatedAt"]) >= asInt64(prev["updatedAt"]) {
			byID[id] = item
		}
	}

	out := make([]map[string]interface{}, 0, len(order))
	for _, id := range order {
		out = append(out, byID[id])
	}
	return out
}

func deduplicateAccounts(accounts []map[string]interface{}) ([]map[string]interface{}, map[string]string) {
	var deleted []map[string]interface{}
	order := make([]string, 0)
	byKey := make(map[string]map[string]interface{})

	for _, acc := range accounts {
		if asBool(acc["isDeleted"]) {
			deleted = append(deleted, acc)
			continue
		}
		key := strings.ToLower(strings.TrimSpace(asString(acc["name"]))) + "|" + asString(acc["type"])
		prev, exists := byKey[key]
		if !exists {
			order = append(order, key)
			byKey[key] = acc
		} else if asInt64(acc["updatedAt"]) > asInt64(prev["updatedAt"]) {
			byKey[key] = acc
		}
	}

	kept := make([]map[string]interface{}, 0, len(order)+len(deleted))
	for _, k := range order {
		kept = append(kept, byKey[k])
	}
	kept = append(kept, deleted...)

	aliases := make(map[string]string)
	for _, acc := range accounts {
		if asBool(acc["isDeleted"]) {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(asString(acc["name"]))) + "|" + asString(acc["type"])
		canonicalID := asString(byKey[key]["id"])
		accID := asString(acc["id"])
		if canonicalID != "" && accID != "" && canonicalID != accID {
			aliases[accID] = canonicalID
		}
	}
	return kept, aliases
}

func deduplicateTransactions(txs []map[string]interface{}, accountAliases map[string]string) []map[string]interface{} {
	var deleted []map[string]interface{}
	order := make([]string, 0)
	byFP := make(map[string]map[string]interface{})

	for _, orig := range txs {
		tx := cloneMap(orig)
		if aid := asString(tx["accountId"]); aid != "" {
			if canonical, ok := accountAliases[aid]; ok {
				tx["accountId"] = canonical
			}
		}
		if tid := asString(tx["targetAccountId"]); tid != "" {
			if canonical, ok := accountAliases[tid]; ok {
				tx["targetAccountId"] = canonical
			}
		}
		if asBool(tx["isDeleted"]) {
			deleted = append(deleted, tx)
			continue
		}
		fp := fmt.Sprintf(
			"%s|%d|%d|%s|%s|%s|%s",
			asString(tx["type"]),
			asInt64(tx["amountCents"]),
			asInt64(tx["timestamp"])/1000,
			asString(tx["accountId"]),
			asString(tx["targetAccountId"]),
			strings.ToLower(strings.TrimSpace(asString(tx["merchant"]))),
			strings.ToLower(strings.TrimSpace(asString(tx["note"]))),
		)
		prev, exists := byFP[fp]
		if !exists {
			order = append(order, fp)
			byFP[fp] = tx
		} else if asInt64(tx["updatedAt"]) > asInt64(prev["updatedAt"]) {
			byFP[fp] = tx
		}
	}

	out := make([]map[string]interface{}, 0, len(order)+len(deleted))
	for _, fp := range order {
		out = append(out, byFP[fp])
	}
	out = append(out, deleted...)
	return out
}

func mergeSnapshots(existing, incoming map[string]interface{}, now int64, deviceID string) map[string]interface{} {
	out := cloneMap(existing)
	for k, v := range incoming {
		out[k] = v
	}

	schemaVer := asInt64(existing["schemaVersion"])
	if iv := asInt64(incoming["schemaVersion"]); iv > schemaVer {
		schemaVer = iv
	}
	if schemaVer <= 0 {
		schemaVer = 1
	}
	out["schemaVersion"] = schemaVer
	out["exportedAt"] = now
	if deviceID != "" {
		out["sourceDeviceId"] = deviceID
	}

	rawAccounts := mergeByID(toMapSlice(existing["accounts"]), toMapSlice(incoming["accounts"]))
	dedupedAccounts, aliases := deduplicateAccounts(rawAccounts)
	rawTxs := mergeByID(toMapSlice(existing["transactions"]), toMapSlice(incoming["transactions"]))

	out["accounts"] = dedupedAccounts
	out["categories"] = mergeByID(toMapSlice(existing["categories"]), toMapSlice(incoming["categories"]))
	out["transactions"] = deduplicateTransactions(rawTxs, aliases)
	out["budgets"] = mergeByID(toMapSlice(existing["budgets"]), toMapSlice(incoming["budgets"]))
	out["rules"] = mergeByID(toMapSlice(existing["rules"]), toMapSlice(incoming["rules"]))
	return out
}

func writeJSON(w http.ResponseWriter, status int, payload interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func newHandler(store *Store, token string) http.Handler {
	token = strings.TrimSpace(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			writeJSON(w, http.StatusNoContent, nil)
			return
		}

		if token != "" && strings.TrimSpace(r.Header.Get("Authorization")) != "Bearer "+token {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "Invalid Bearer token"})
			return
		}

		path := strings.TrimRight(r.URL.Path, "/")
		if path == "" {
			path = "/"
		}

		switch {
		case r.Method == http.MethodGet && (path == "/" || path == "/api/v1/health"):
			writeJSON(w, http.StatusOK, HealthResponse{
				Status:     "ok",
				Service:    "MochiLedger Sync Server (OpenWrt / Cudy TR3000)",
				Version:    "1.2.0",
				ServerTime: time.Now().UnixMilli(),
			})

		case r.Method == http.MethodPost && path == "/api/v1/sync":
			var req SyncRequest
			if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Snapshot == nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "Invalid JSON sync payload"})
				return
			}
			ledgerID := sanitizeLedgerID(req.LedgerID)
			merged, err := store.MergeAndSave(ledgerID, req.DeviceID, req.Snapshot)
			if err != nil {
				writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
				return
			}
			writeJSON(w, http.StatusOK, SyncResponse{
				OK:             true,
				ServerTime:     time.Now().UnixMilli(),
				MergedSnapshot: merged,
				Message:        fmt.Sprintf("Synced ledger '%s'", ledgerID),
			})

		case r.Method == http.MethodGet && strings.HasPrefix(path, "/api/v1/ledger/"):
			ledgerID := strings.TrimPrefix(path, "/api/v1/ledger/")
			snap, err := store.Read(ledgerID)
			if err != nil {
				writeJSON(w, http.StatusNotFound, map[string]string{"error": "Ledger not found"})
				return
			}
			writeJSON(w, http.StatusOK, snap)

		default:
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "Not Found"})
		}
	})
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func main() {
	addr := flag.String("addr", envOr("MOCHI_ADDR", "[::]:8787"), "Dual-stack IPv4/IPv6 listen address (e.g. [::]:8787)")
	dataDir := flag.String("data", envOr("MOCHI_DATA_DIR", "/etc/mochiledger/data"), "Directory for ledger JSON files")
	token := flag.String("token", envOr("MOCHI_SYNC_TOKEN", ""), "Bearer authentication token")
	certFile := flag.String("cert", envOr("MOCHI_TLS_CERT", ""), "Optional TLS certificate PEM file for HTTPS")
	keyFile := flag.String("key", envOr("MOCHI_TLS_KEY", ""), "Optional TLS private key PEM file for HTTPS")
	flag.Parse()

	store := &Store{dataDir: *dataDir}
	handler := newHandler(store, *token)
	if *certFile != "" && *keyFile != "" {
		log.Printf("[MochiLedger OpenWrt Sync] Listening HTTPS on %s (dual-stack IPv4/IPv6, data=%s, auth=%v)", *addr, *dataDir, *token != "")
		if err := http.ListenAndServeTLS(*addr, *certFile, *keyFile, handler); err != nil {
			log.Fatalf("HTTPS server stopped: %v", err)
		}
		return
	}
	log.Printf("[MochiLedger OpenWrt Sync] Listening HTTP on %s (dual-stack IPv4/IPv6, data=%s, auth=%v)", *addr, *dataDir, *token != "")
	if err := http.ListenAndServe(*addr, handler); err != nil {
		log.Fatalf("Server stopped: %v", err)
	}
}
