package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestLoadConfigRequiresClientID(t *testing.T) {
	t.Setenv("SOUNDCLOUD_CLIENT_ID", "")
	t.Setenv("SOUNDCLOUD_CLIENT_SECRET", "secret")
	t.Setenv("SOUNDCLOUD_TOKEN_URL", "https://secure.soundcloud.com/oauth/token")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "SOUNDCLOUD_CLIENT_ID is required") {
		t.Fatalf("expected missing client id error, got %v", err)
	}
}

func TestLoadConfigRejectsInvalidTokenURL(t *testing.T) {
	t.Setenv("SOUNDCLOUD_CLIENT_ID", "id")
	t.Setenv("SOUNDCLOUD_CLIENT_SECRET", "secret")
	t.Setenv("SOUNDCLOUD_TOKEN_URL", "http://[::1")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "invalid SOUNDCLOUD_TOKEN_URL") {
		t.Fatalf("expected invalid token url error, got %v", err)
	}
}

func TestExchangeEndpointRequiresFields(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "*",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/exchange", strings.NewReader(`{"code":"abc"}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rr.Code)
	}

	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload["error"] != "missing_required_fields" {
		t.Fatalf("unexpected error payload: %+v", payload)
	}
}

func TestClientCredentialsProxiesUpstreamJSON(t *testing.T) {
	var gotGrantType, gotClientID, gotSecret string
	var gotFormClientID, gotFormSecret string
	var gotBasicAuth bool

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse form failed: %v", err)
		}
		gotGrantType = r.Form.Get("grant_type")
		gotFormClientID = r.Form.Get("client_id")
		gotFormSecret = r.Form.Get("client_secret")
		gotClientID, gotSecret, gotBasicAuth = r.BasicAuth()

		writeJSON(w, http.StatusOK, map[string]string{"access_token": "token123"})
	}))
	defer upstream.Close()

	cfg := config{
		SoundCloudClientID: "my_id",
		SoundCloudSecret:   "my_secret",
		SoundCloudTokenURL: upstream.URL,
		AllowedOrigin:      "*",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/client-credentials", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rr.Code)
	}
	if gotGrantType != "client_credentials" {
		t.Fatalf("unexpected grant type: %q", gotGrantType)
	}
	if gotFormClientID != "" || gotFormSecret != "" {
		t.Fatalf("client credentials must not be sent in form body: id=%q secret=%q", gotFormClientID, gotFormSecret)
	}
	if !gotBasicAuth || gotClientID != "my_id" || gotSecret != "my_secret" {
		t.Fatalf("unexpected upstream basic auth: ok=%v id=%q secret=%q", gotBasicAuth, gotClientID, gotSecret)
	}

	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload["access_token"] != "token123" {
		t.Fatalf("unexpected access token payload: %+v", payload)
	}
}

func TestProxyTokenRequestRewritesNonJSONResponse(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("not-json"))
	}))
	defer upstream.Close()

	cfg := config{
		SoundCloudTokenURL: upstream.URL,
		RequestTimeout:     2 * time.Second,
	}

	rr := httptest.NewRecorder()
	proxyTokenRequest(rr, cfg, url.Values{"grant_type": []string{"client_credentials"}})

	if rr.Code != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", rr.Code)
	}

	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload["error"] != "upstream_non_json" {
		t.Fatalf("unexpected payload: %+v", payload)
	}
}

func TestCORSPreflightReturnsNoContent(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "http://localhost:3000",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodOptions, "/oauth/soundcloud/refresh", nil)
	rr := httptest.NewRecorder()
	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d", rr.Code)
	}
	if rr.Header().Get("Access-Control-Allow-Origin") != "http://localhost:3000" {
		t.Fatalf("missing/invalid CORS header: %q", rr.Header().Get("Access-Control-Allow-Origin"))
	}
}
