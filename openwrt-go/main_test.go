package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthAndAuth(t *testing.T) {
	store := &Store{dataDir: t.TempDir()}
	h := newHandler(store, "router-secret")

	req := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}

	req2 := httptest.NewRequest(http.MethodGet, "/api/v1/health", nil)
	req2.Header.Set("Authorization", "Bearer router-secret")
	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec2.Code)
	}
}

func TestSyncMergeAndDeduplicate(t *testing.T) {
	store := &Store{dataDir: t.TempDir()}
	h := newHandler(store, "tok")

	payload1 := `{
		"ledgerId": "home",
		"deviceId": "win-1",
		"snapshot": {
			"schemaVersion": 1,
			"accounts": [{"id":"a1","name":"微信零钱","type":"DIGITAL_WALLET","updatedAt":1000}],
			"transactions": [{"id":"t1","type":"EXPENSE","amountCents":1990,"timestamp":1760000000000,"accountId":"a1","merchant":"瑞幸","updatedAt":1000}]
		}
	}`
	req1 := httptest.NewRequest(http.MethodPost, "/api/v1/sync", bytes.NewBufferString(payload1))
	req1.Header.Set("Authorization", "Bearer tok")
	rec1 := httptest.NewRecorder()
	h.ServeHTTP(rec1, req1)
	if rec1.Code != http.StatusOK {
		t.Fatalf("sync 1 failed: %d", rec1.Code)
	}

	// Second device sends duplicate account & transaction with newer updatedAt + 1 new transaction
	payload2 := `{
		"ledgerId": "home",
		"deviceId": "and-1",
		"snapshot": {
			"schemaVersion": 1,
			"accounts": [{"id":"a2","name":"微信零钱","type":"DIGITAL_WALLET","updatedAt":2000}],
			"transactions": [
				{"id":"t2","type":"EXPENSE","amountCents":1990,"timestamp":1760000000500,"accountId":"a2","merchant":"瑞幸","updatedAt":2000},
				{"id":"t3","type":"EXPENSE","amountCents":3200,"timestamp":1760000099000,"accountId":"a2","merchant":"星巴克","updatedAt":2500}
			]
		}
	}`
	req2 := httptest.NewRequest(http.MethodPost, "/api/v1/sync", bytes.NewBufferString(payload2))
	req2.Header.Set("Authorization", "Bearer tok")
	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req2)
	if rec2.Code != http.StatusOK {
		t.Fatalf("sync 2 failed: %d", rec2.Code)
	}

	var resp SyncResponse
	if err := json.Unmarshal(rec2.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	accs := toMapSlice(resp.MergedSnapshot["accounts"])
	txs := toMapSlice(resp.MergedSnapshot["transactions"])
	if len(accs) != 1 {
		t.Fatalf("expected 1 deduplicated account, got %d", len(accs))
	}
	if len(txs) != 2 {
		t.Fatalf("expected 2 deduplicated transactions, got %d", len(txs))
	}
}
