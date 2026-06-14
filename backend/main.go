package main

import (
	"bytes"
	"crypto/md5"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxJSONBodyBytes int64 = 64 * 1024

type config struct {
	Addr               string
	SoundCloudClientID string
	SoundCloudSecret   string
	SoundCloudTokenURL string
	LastFMAPIKey       string
	LastFMAPISecret    string
	LastFMAPIURL       string
	AllowedOrigin      string
	RequestTimeout     time.Duration
}

type exchangeRequest struct {
	Code         string `json:"code"`
	CodeVerifier string `json:"codeVerifier"`
	RedirectURI  string `json:"redirectUri"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type lastFMAuthRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type lastFMNowPlayingRequest struct {
	SessionKey      string `json:"sessionKey"`
	Artist          string `json:"artist"`
	Track           string `json:"track"`
	DurationSeconds *int   `json:"durationSeconds"`
}

type lastFMScrobbleRequest struct {
	SessionKey string                `json:"sessionKey"`
	Scrobbles  []lastFMScrobbleEntry `json:"scrobbles"`
}

type lastFMScrobbleEntry struct {
	Artist    string `json:"artist"`
	Track     string `json:"track"`
	Timestamp int    `json:"timestamp"`
}

type lastFMTasteRequest struct {
	Username string `json:"username"`
	Limit    int    `json:"limit"`
}

type lastFMTasteTrack struct {
	Artist string `json:"artist"`
	Name   string `json:"name"`
}

type lastFMTasteArtist struct {
	Name      string `json:"name"`
	Playcount int    `json:"playcount"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	mux := newMux(cfg)

	log.Printf("token broker listening on %s", cfg.Addr)
	if err := http.ListenAndServe(cfg.Addr, mux); err != nil {
		log.Fatal(err)
	}
}

func newMux(cfg config) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("/oauth/soundcloud/exchange", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}

		var req exchangeRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}

		if req.Code == "" || req.CodeVerifier == "" || req.RedirectURI == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_required_fields"})
			return
		}

		payload := url.Values{}
		payload.Set("grant_type", "authorization_code")
		payload.Set("client_id", cfg.SoundCloudClientID)
		payload.Set("client_secret", cfg.SoundCloudSecret)
		payload.Set("code", req.Code)
		payload.Set("code_verifier", req.CodeVerifier)
		payload.Set("redirect_uri", req.RedirectURI)

		proxyTokenRequest(w, cfg, payload)
	}))

	mux.HandleFunc("/oauth/soundcloud/refresh", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}

		var req refreshRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}

		if req.RefreshToken == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_refresh_token"})
			return
		}

		payload := url.Values{}
		payload.Set("grant_type", "refresh_token")
		payload.Set("client_id", cfg.SoundCloudClientID)
		payload.Set("client_secret", cfg.SoundCloudSecret)
		payload.Set("refresh_token", req.RefreshToken)

		proxyTokenRequest(w, cfg, payload)
	}))

	mux.HandleFunc("/oauth/soundcloud/client-credentials", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}

		payload := url.Values{}
		payload.Set("grant_type", "client_credentials")

		proxyTokenRequest(w, cfg, payload, withBasicAuth(cfg.SoundCloudClientID, cfg.SoundCloudSecret))
	}))

	mux.HandleFunc("/oauth/lastfm/mobile-session", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}
		if !cfg.hasLastFMConfig() {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "missing_lastfm_config"})
			return
		}

		var req lastFMAuthRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}
		if strings.TrimSpace(req.Username) == "" || req.Password == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_required_fields"})
			return
		}

		params := map[string]string{
			"method":   "auth.getMobileSession",
			"username": strings.TrimSpace(req.Username),
			"password": req.Password,
			"api_key":  cfg.LastFMAPIKey,
		}
		params["api_sig"] = signLastFM(params, cfg.LastFMAPISecret)
		proxyLastFMRequest(w, cfg, params)
	}))

	mux.HandleFunc("/lastfm/now-playing", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}
		if !cfg.hasLastFMConfig() {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "missing_lastfm_config"})
			return
		}

		var req lastFMNowPlayingRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}
		if req.SessionKey == "" || req.Artist == "" || req.Track == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_required_fields"})
			return
		}

		params := map[string]string{
			"method":  "track.updateNowPlaying",
			"artist":  req.Artist,
			"track":   req.Track,
			"api_key": cfg.LastFMAPIKey,
			"sk":      req.SessionKey,
		}
		if req.DurationSeconds != nil && *req.DurationSeconds > 0 {
			params["duration"] = strconv.Itoa(*req.DurationSeconds)
		}
		params["api_sig"] = signLastFM(params, cfg.LastFMAPISecret)
		proxyLastFMRequest(w, cfg, params)
	}))

	mux.HandleFunc("/lastfm/scrobble", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}
		if !cfg.hasLastFMConfig() {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "missing_lastfm_config"})
			return
		}

		var req lastFMScrobbleRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}
		if req.SessionKey == "" || len(req.Scrobbles) == 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_required_fields"})
			return
		}

		batch := req.Scrobbles
		if len(batch) > 50 {
			batch = batch[:50]
		}
		params := map[string]string{
			"method":  "track.scrobble",
			"api_key": cfg.LastFMAPIKey,
			"sk":      req.SessionKey,
		}
		for i, item := range batch {
			if item.Artist == "" || item.Track == "" || item.Timestamp <= 0 {
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_scrobble_payload"})
				return
			}
			params[fmt.Sprintf("artist[%d]", i)] = item.Artist
			params[fmt.Sprintf("track[%d]", i)] = item.Track
			params[fmt.Sprintf("timestamp[%d]", i)] = strconv.Itoa(item.Timestamp)
		}
		params["api_sig"] = signLastFM(params, cfg.LastFMAPISecret)
		proxyLastFMRequest(w, cfg, params)
	}))

	mux.HandleFunc("/lastfm/taste", withCORS(cfg, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method_not_allowed"})
			return
		}
		if !cfg.hasLastFMConfig() {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "missing_lastfm_config"})
			return
		}

		var req lastFMTasteRequest
		if !decodeJSONBody(w, r, &req) {
			return
		}
		username := strings.TrimSpace(req.Username)
		if username == "" {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "missing_required_fields"})
			return
		}

		limit := req.Limit
		if limit <= 0 {
			limit = 50
		}
		if limit > 100 {
			limit = 100
		}

		recent, status, err := fetchLastFMJSON(cfg, map[string]string{
			"method":   "user.getRecentTracks",
			"user":     username,
			"limit":    strconv.Itoa(limit),
			"extended": "0",
			"api_key":  cfg.LastFMAPIKey,
		})
		if err != nil {
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		if isLastFMError(recent) {
			writeJSON(w, http.StatusBadRequest, recent)
			return
		}

		artistLimit := limit
		if artistLimit > 30 {
			artistLimit = 30
		}
		artists, status, err := fetchLastFMJSON(cfg, map[string]string{
			"method":  "user.getTopArtists",
			"user":    username,
			"period":  "1month",
			"limit":   strconv.Itoa(artistLimit),
			"api_key": cfg.LastFMAPIKey,
		})
		if err != nil {
			writeJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		if isLastFMError(artists) {
			writeJSON(w, http.StatusBadRequest, artists)
			return
		}

		writeJSON(w, http.StatusOK, map[string]any{
			"username":     username,
			"recentTracks": normalizeRecentTracks(recent),
			"topArtists":   normalizeTopArtists(artists),
		})
	}))

	return mux
}

func loadConfig() (config, error) {
	cfg := config{
		Addr:               envOrDefault("ADDR", ":8787"),
		SoundCloudClientID: envOrDefault("SOUNDCLOUD_CLIENT_ID", ""),
		SoundCloudSecret:   envOrDefault("SOUNDCLOUD_CLIENT_SECRET", ""),
		SoundCloudTokenURL: envOrDefault("SOUNDCLOUD_TOKEN_URL", "https://secure.soundcloud.com/oauth/token"),
		LastFMAPIKey:       envOrDefault("LASTFM_API_KEY", ""),
		LastFMAPISecret:    envOrDefault("LASTFM_API_SECRET", ""),
		LastFMAPIURL:       envOrDefault("LASTFM_API_URL", "https://ws.audioscrobbler.com/2.0/"),
		AllowedOrigin:      envOrDefault("ALLOWED_ORIGIN", "*"),
		RequestTimeout:     15 * time.Second,
	}

	if cfg.SoundCloudClientID == "" {
		return cfg, errors.New("SOUNDCLOUD_CLIENT_ID is required")
	}
	if cfg.SoundCloudSecret == "" {
		return cfg, errors.New("SOUNDCLOUD_CLIENT_SECRET is required")
	}

	if err := validateHTTPURL(cfg.SoundCloudTokenURL); err != nil {
		return cfg, fmt.Errorf("invalid SOUNDCLOUD_TOKEN_URL: %w", err)
	}
	if err := validateHTTPURL(cfg.LastFMAPIURL); err != nil {
		return cfg, fmt.Errorf("invalid LASTFM_API_URL: %w", err)
	}

	return cfg, nil
}

func (cfg config) hasLastFMConfig() bool {
	return cfg.LastFMAPIKey != "" && cfg.LastFMAPISecret != ""
}

func validateHTTPURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil {
		return err
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return errors.New("must use http or https")
	}
	if parsed.Host == "" {
		return errors.New("must include host")
	}
	return nil
}

func decodeJSONBody(w http.ResponseWriter, r *http.Request, target any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxJSONBodyBytes)
	decoder := json.NewDecoder(r.Body)
	if err := decoder.Decode(target); err != nil {
		if strings.Contains(err.Error(), "request body too large") {
			writeJSON(w, http.StatusRequestEntityTooLarge, map[string]string{"error": "request_too_large"})
		} else {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
		}
		return false
	}
	return true
}

type tokenRequestOption func(*http.Request)

func withBasicAuth(clientID, secret string) tokenRequestOption {
	return func(req *http.Request) {
		req.SetBasicAuth(clientID, secret)
	}
}

func proxyTokenRequest(w http.ResponseWriter, cfg config, payload url.Values, opts ...tokenRequestOption) {
	req, err := http.NewRequest(http.MethodPost, cfg.SoundCloudTokenURL, strings.NewReader(payload.Encode()))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "request_build_failed"})
		return
	}

	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	for _, opt := range opts {
		opt(req)
	}

	client := &http.Client{Timeout: cfg.RequestTimeout}
	res, err := client.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream_unavailable"})
		return
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream_read_failed"})
		return
	}

	if !json.Valid(body) {
		body = []byte(`{"error":"upstream_non_json"}`)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(res.StatusCode)
	_, _ = io.Copy(w, bytes.NewReader(body))
}

func proxyLastFMRequest(w http.ResponseWriter, cfg config, params map[string]string) {
	payload := url.Values{}
	for key, value := range params {
		payload.Set(key, value)
	}
	payload.Set("format", "json")

	req, err := http.NewRequest(http.MethodPost, cfg.LastFMAPIURL, strings.NewReader(payload.Encode()))
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "request_build_failed"})
		return
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: cfg.RequestTimeout}
	res, err := client.Do(req)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream_unavailable"})
		return
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "upstream_read_failed"})
		return
	}
	if !json.Valid(body) {
		body = []byte(`{"error":"upstream_non_json"}`)
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(res.StatusCode)
	_, _ = io.Copy(w, bytes.NewReader(body))
}

func fetchLastFMJSON(cfg config, params map[string]string) (map[string]any, int, error) {
	payload := url.Values{}
	for key, value := range params {
		payload.Set(key, value)
	}
	payload.Set("format", "json")

	req, err := http.NewRequest(http.MethodPost, cfg.LastFMAPIURL, strings.NewReader(payload.Encode()))
	if err != nil {
		return nil, http.StatusInternalServerError, errors.New("request_build_failed")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	client := &http.Client{Timeout: cfg.RequestTimeout}
	res, err := client.Do(req)
	if err != nil {
		return nil, http.StatusBadGateway, errors.New("upstream_unavailable")
	}
	defer res.Body.Close()

	body, err := io.ReadAll(io.LimitReader(res.Body, 2<<20))
	if err != nil {
		return nil, http.StatusBadGateway, errors.New("upstream_read_failed")
	}

	var value map[string]any
	if err := json.Unmarshal(body, &value); err != nil {
		return nil, http.StatusBadGateway, errors.New("upstream_non_json")
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return value, res.StatusCode, errors.New("upstream_error")
	}
	return value, http.StatusOK, nil
}

func signLastFM(params map[string]string, apiSecret string) string {
	keys := make([]string, 0, len(params))
	for key := range params {
		if key == "format" || key == "callback" || key == "api_sig" {
			continue
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(key)
		builder.WriteString(params[key])
	}
	builder.WriteString(apiSecret)

	sum := md5.Sum([]byte(builder.String()))
	return fmt.Sprintf("%x", sum)
}

func isLastFMError(value map[string]any) bool {
	_, hasError := value["error"]
	return hasError
}

func normalizeRecentTracks(value map[string]any) []lastFMTasteTrack {
	recentTracks := mapValue(value, "recenttracks")
	rawTracks := arrayValue(recentTracks["track"])
	tracks := make([]lastFMTasteTrack, 0, len(rawTracks))
	for _, raw := range rawTracks {
		record, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name := stringValue(record["name"])
		artistRecord, _ := record["artist"].(map[string]any)
		artist := stringValue(artistRecord["#text"])
		if artist == "" || name == "" {
			continue
		}
		tracks = append(tracks, lastFMTasteTrack{Artist: artist, Name: name})
	}
	return tracks
}

func normalizeTopArtists(value map[string]any) []lastFMTasteArtist {
	topArtists := mapValue(value, "topartists")
	rawArtists := arrayValue(topArtists["artist"])
	artists := make([]lastFMTasteArtist, 0, len(rawArtists))
	for _, raw := range rawArtists {
		record, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		name := stringValue(record["name"])
		if name == "" {
			continue
		}
		artists = append(artists, lastFMTasteArtist{
			Name:      name,
			Playcount: intValue(record["playcount"]),
		})
	}
	return artists
}

func mapValue(value map[string]any, key string) map[string]any {
	nested, _ := value[key].(map[string]any)
	if nested == nil {
		return map[string]any{}
	}
	return nested
}

func arrayValue(value any) []any {
	switch typed := value.(type) {
	case []any:
		return typed
	case map[string]any:
		return []any{typed}
	default:
		return nil
	}
}

func stringValue(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	default:
		return ""
	}
}

func intValue(value any) int {
	switch typed := value.(type) {
	case string:
		parsed, _ := strconv.Atoi(typed)
		return parsed
	case float64:
		return int(typed)
	case int:
		return typed
	default:
		return 0
	}
}

func withCORS(cfg config, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", cfg.AllowedOrigin)
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, code int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(payload)
}

func envOrDefault(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return strings.TrimSpace(val)
	}
	return fallback
}
