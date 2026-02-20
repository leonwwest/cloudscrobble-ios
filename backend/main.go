package main

import (
    "bytes"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "log"
    "net/http"
    "net/url"
    "os"
    "strings"
    "time"
)

type config struct {
    Addr                string
    SoundCloudClientID  string
    SoundCloudSecret    string
    SoundCloudTokenURL  string
    AllowedOrigin       string
    RequestTimeout      time.Duration
}

type exchangeRequest struct {
    Code        string `json:"code"`
    CodeVerifier string `json:"codeVerifier"`
    RedirectURI string `json:"redirectUri"`
}

type refreshRequest struct {
    RefreshToken string `json:"refreshToken"`
}

func main() {
    cfg, err := loadConfig()
    if err != nil {
        log.Fatalf("config error: %v", err)
    }

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
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
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
        if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
            writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid_json"})
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

    log.Printf("token broker listening on %s", cfg.Addr)
    if err := http.ListenAndServe(cfg.Addr, mux); err != nil {
        log.Fatal(err)
    }
}

func loadConfig() (config, error) {
    cfg := config{
        Addr:               envOrDefault("ADDR", ":8787"),
        SoundCloudClientID: os.Getenv("SOUNDCLOUD_CLIENT_ID"),
        SoundCloudSecret:   os.Getenv("SOUNDCLOUD_CLIENT_SECRET"),
        SoundCloudTokenURL: envOrDefault("SOUNDCLOUD_TOKEN_URL", "https://secure.soundcloud.com/oauth/token"),
        AllowedOrigin:      envOrDefault("ALLOWED_ORIGIN", "*"),
        RequestTimeout:     15 * time.Second,
    }

    if cfg.SoundCloudClientID == "" {
        return cfg, errors.New("SOUNDCLOUD_CLIENT_ID is required")
    }
    if cfg.SoundCloudSecret == "" {
        return cfg, errors.New("SOUNDCLOUD_CLIENT_SECRET is required")
    }

    if _, err := url.Parse(cfg.SoundCloudTokenURL); err != nil {
        return cfg, fmt.Errorf("invalid SOUNDCLOUD_TOKEN_URL: %w", err)
    }

    return cfg, nil
}

func proxyTokenRequest(w http.ResponseWriter, cfg config, payload url.Values) {
    req, err := http.NewRequest(http.MethodPost, cfg.SoundCloudTokenURL, strings.NewReader(payload.Encode()))
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
        return val
    }
    return fallback
}
