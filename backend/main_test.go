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

func TestLoadConfigRejectsRelativeTokenURL(t *testing.T) {
	t.Setenv("SOUNDCLOUD_CLIENT_ID", "id")
	t.Setenv("SOUNDCLOUD_CLIENT_SECRET", "secret")
	t.Setenv("SOUNDCLOUD_TOKEN_URL", "/oauth/token")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "invalid SOUNDCLOUD_TOKEN_URL") {
		t.Fatalf("expected invalid token url error, got %v", err)
	}
}

func TestLoadConfigRejectsInvalidLastFMURL(t *testing.T) {
	t.Setenv("SOUNDCLOUD_CLIENT_ID", "id")
	t.Setenv("SOUNDCLOUD_CLIENT_SECRET", "secret")
	t.Setenv("SOUNDCLOUD_TOKEN_URL", "https://secure.soundcloud.com/oauth/token")
	t.Setenv("LASTFM_API_URL", "http://[::1")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "invalid LASTFM_API_URL") {
		t.Fatalf("expected invalid last.fm url error, got %v", err)
	}
}

func TestLoadConfigRejectsRelativeLastFMURL(t *testing.T) {
	t.Setenv("SOUNDCLOUD_CLIENT_ID", "id")
	t.Setenv("SOUNDCLOUD_CLIENT_SECRET", "secret")
	t.Setenv("SOUNDCLOUD_TOKEN_URL", "https://secure.soundcloud.com/oauth/token")
	t.Setenv("LASTFM_API_URL", "/2.0/")

	_, err := loadConfig()
	if err == nil || !strings.Contains(err.Error(), "invalid LASTFM_API_URL") {
		t.Fatalf("expected invalid last.fm url error, got %v", err)
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

func TestExchangeEndpointRejectsOversizedJSON(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "*",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/exchange", strings.NewReader(`{"code":"`+strings.Repeat("a", 70*1024)+`"}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("expected 413, got %d", rr.Code)
	}

	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload["error"] != "request_too_large" {
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

func TestLastFMMobileSessionProxiesUpstreamJSON(t *testing.T) {
	var gotMethod, gotUsername, gotPassword, gotAPIKey, gotFormat, gotAPISig, gotAPISecret string

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse form failed: %v", err)
		}
		gotMethod = r.Form.Get("method")
		gotUsername = r.Form.Get("username")
		gotPassword = r.Form.Get("password")
		gotAPIKey = r.Form.Get("api_key")
		gotFormat = r.Form.Get("format")
		gotAPISig = r.Form.Get("api_sig")
		gotAPISecret = r.Form.Get("api_secret")

		writeJSON(w, http.StatusOK, map[string]any{
			"session": map[string]any{
				"name":       "westf5",
				"key":        "session-key",
				"subscriber": 0,
			},
		})
	}))
	defer upstream.Close()

	cfg := config{
		LastFMAPIKey:    "lastfm-key",
		LastFMAPISecret: "lastfm-secret",
		LastFMAPIURL:    upstream.URL,
		AllowedOrigin:   "*",
		RequestTimeout:  2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/lastfm/mobile-session", strings.NewReader(`{"username":" westf5 ","password":"pw"}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if gotMethod != "auth.getMobileSession" || gotUsername != "westf5" || gotPassword != "pw" {
		t.Fatalf("unexpected upstream auth form: method=%q username=%q password=%q", gotMethod, gotUsername, gotPassword)
	}
	if gotAPIKey != "lastfm-key" || gotFormat != "json" || gotAPISig == "" {
		t.Fatalf("unexpected upstream api fields: api_key=%q format=%q api_sig=%q", gotAPIKey, gotFormat, gotAPISig)
	}
	if gotAPISecret != "" {
		t.Fatalf("api secret must not be sent upstream as a form field")
	}

	var payload struct {
		Session struct {
			Name string `json:"name"`
			Key  string `json:"key"`
		} `json:"session"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload.Session.Name != "westf5" || payload.Session.Key != "session-key" {
		t.Fatalf("unexpected session payload: %+v", payload.Session)
	}
}

func TestLastFMEndpointRequiresConfig(t *testing.T) {
	cfg := config{
		LastFMAPIURL:   "https://example.com/2.0/",
		AllowedOrigin:  "*",
		RequestTimeout: 2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/lastfm/mobile-session", strings.NewReader(`{"username":"westf5","password":"pw"}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d", rr.Code)
	}

	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload["error"] != "missing_lastfm_config" {
		t.Fatalf("unexpected payload: %+v", payload)
	}
}

func TestLastFMScrobbleProxiesIndexedFields(t *testing.T) {
	var gotMethod, gotSessionKey, gotArtist, gotTrack, gotTimestamp, gotFormat, gotAPISig string

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse form failed: %v", err)
		}
		gotMethod = r.Form.Get("method")
		gotSessionKey = r.Form.Get("sk")
		gotArtist = r.Form.Get("artist[0]")
		gotTrack = r.Form.Get("track[0]")
		gotTimestamp = r.Form.Get("timestamp[0]")
		gotFormat = r.Form.Get("format")
		gotAPISig = r.Form.Get("api_sig")

		writeJSON(w, http.StatusOK, map[string]any{})
	}))
	defer upstream.Close()

	cfg := config{
		LastFMAPIKey:    "lastfm-key",
		LastFMAPISecret: "lastfm-secret",
		LastFMAPIURL:    upstream.URL,
		AllowedOrigin:   "*",
		RequestTimeout:  2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/lastfm/scrobble", strings.NewReader(`{"sessionKey":"session","scrobbles":[{"artist":"Artist","track":"Track","timestamp":1710000000}]}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if gotMethod != "track.scrobble" || gotSessionKey != "session" {
		t.Fatalf("unexpected upstream scrobble method/session: method=%q sk=%q", gotMethod, gotSessionKey)
	}
	if gotArtist != "Artist" || gotTrack != "Track" || gotTimestamp != "1710000000" {
		t.Fatalf("unexpected indexed scrobble fields: artist=%q track=%q timestamp=%q", gotArtist, gotTrack, gotTimestamp)
	}
	if gotFormat != "json" || gotAPISig == "" {
		t.Fatalf("unexpected upstream api fields: format=%q api_sig=%q", gotFormat, gotAPISig)
	}
}

func TestLastFMTasteNormalizesProfile(t *testing.T) {
	var gotMethods []string

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Fatalf("parse form failed: %v", err)
		}
		gotMethods = append(gotMethods, r.Form.Get("method"))
		if r.Form.Get("user") != "westf5" {
			t.Fatalf("unexpected user: %q", r.Form.Get("user"))
		}

		switch r.Form.Get("method") {
		case "user.getRecentTracks":
			writeJSON(w, http.StatusOK, map[string]any{
				"recenttracks": map[string]any{
					"track": []map[string]any{
						{
							"name":   "Song A",
							"artist": map[string]string{"#text": "Artist A"},
						},
						{
							"name":   "Song B",
							"artist": map[string]string{"#text": "Artist B"},
						},
					},
				},
			})
		case "user.getTopArtists":
			writeJSON(w, http.StatusOK, map[string]any{
				"topartists": map[string]any{
					"artist": []map[string]any{
						{"name": "Artist A", "playcount": "42"},
						{"name": "Artist C", "playcount": 7},
					},
				},
			})
		default:
			t.Fatalf("unexpected last.fm method: %q", r.Form.Get("method"))
		}
	}))
	defer upstream.Close()

	cfg := config{
		LastFMAPIKey:    "lastfm-key",
		LastFMAPISecret: "lastfm-secret",
		LastFMAPIURL:    upstream.URL,
		AllowedOrigin:   "*",
		RequestTimeout:  2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/lastfm/taste", strings.NewReader(`{"username":" westf5 ","limit":2}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", rr.Code, rr.Body.String())
	}
	if len(gotMethods) != 2 || gotMethods[0] != "user.getRecentTracks" || gotMethods[1] != "user.getTopArtists" {
		t.Fatalf("unexpected upstream method calls: %+v", gotMethods)
	}

	var payload struct {
		Username     string              `json:"username"`
		RecentTracks []lastFMTasteTrack  `json:"recentTracks"`
		TopArtists   []lastFMTasteArtist `json:"topArtists"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json response: %v", err)
	}
	if payload.Username != "westf5" {
		t.Fatalf("unexpected username: %q", payload.Username)
	}
	if len(payload.RecentTracks) != 2 || payload.RecentTracks[0].Artist != "Artist A" || payload.RecentTracks[0].Name != "Song A" {
		t.Fatalf("unexpected recent tracks: %+v", payload.RecentTracks)
	}
	if len(payload.TopArtists) != 2 || payload.TopArtists[0].Name != "Artist A" || payload.TopArtists[0].Playcount != 42 {
		t.Fatalf("unexpected top artists: %+v", payload.TopArtists)
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
	if !strings.Contains(rr.Header().Get("Access-Control-Allow-Headers"), "X-API-Key") {
		t.Fatalf("CORS allowed headers must include X-API-Key: %q", rr.Header().Get("Access-Control-Allow-Headers"))
	}
}

func TestAPIKeyGateRejectsMissingHeader(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "*",
		AppAPIKey:          "secret-key",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/exchange", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rr.Code)
	}
	var payload map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &payload); err != nil {
		t.Fatalf("invalid json: %v", err)
	}
	if payload["error"] != "unauthorized_api_key" {
		t.Fatalf("unexpected error: %+v", payload)
	}
}

func TestAPIKeyGateAllowsCorrectHeader(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "*",
		AppAPIKey:          "secret-key",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/exchange", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", "secret-key")
	rr := httptest.NewRecorder()
	newMux(cfg).ServeHTTP(rr, req)

	// Gate passes; handler proceeds and reports missing fields (400), not 401.
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 after passing gate, got %d", rr.Code)
	}
}

func TestAPIKeyGateDisabledWhenUnset(t *testing.T) {
	cfg := config{
		SoundCloudClientID: "id",
		SoundCloudSecret:   "secret",
		SoundCloudTokenURL: "https://example.com/oauth/token",
		AllowedOrigin:      "*",
		RequestTimeout:     2 * time.Second,
	}

	req := httptest.NewRequest(http.MethodPost, "/oauth/soundcloud/exchange", strings.NewReader(`{}`))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	newMux(cfg).ServeHTTP(rr, req)

	if rr.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 (gate disabled), got %d", rr.Code)
	}
}
