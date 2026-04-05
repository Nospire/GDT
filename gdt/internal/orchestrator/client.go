package orchestrator

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

const (
	BaseURL           = "https://gdt.geekcom.org"
	heartbeatInterval = 10 * time.Minute
)

type Session struct {
	ID           string
	MihomoConfig string // mihomo/sing-box config from orchestrator
}

type Client struct {
	baseURL    string
	httpClient *http.Client
}

func New() *Client {
	return &Client{
		baseURL: BaseURL,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// Start calls POST /api/session/start.
// Request: {"client_type": "gdt", "action": action}
// Response: {"session_id": "...", "mihomo_config": "...", "expires_at": "..."}
func (c *Client) Start(ctx context.Context, action string) (*Session, error) {
	body := map[string]string{
		"client_type": "gdt",
		"action":      action,
	}
	resp, err := c.post(ctx, "/api/session/start", body)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var result struct {
		SessionID    string `json:"session_id"`
		MihomoConfig string `json:"mihomo_config"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("orchestrator: decode start: %w", err)
	}
	return &Session{
		ID:           result.SessionID,
		MihomoConfig: result.MihomoConfig,
	}, nil
}

// Heartbeat calls POST /api/session/{id}/heartbeat with empty body.
func (c *Client) Heartbeat(ctx context.Context, sessionID string) error {
	resp, err := c.post(ctx, "/api/session/"+sessionID+"/heartbeat", nil)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// Complete calls POST /api/session/{id}/complete.
// result should be "success" or "error"; serverUsed is optional (e.g. "NL", "LV").
func (c *Client) Complete(ctx context.Context, sessionID, result, serverUsed string) error {
	body := map[string]any{
		"success": result == "success",
	}
	if serverUsed != "" {
		body["server_used"] = serverUsed
	}
	resp, err := c.post(ctx, "/api/session/"+sessionID+"/complete", body)
	if err != nil {
		return err
	}
	resp.Body.Close()
	return nil
}

// RunHeartbeat ticks every 10 minutes until ctx is cancelled.
func (c *Client) RunHeartbeat(ctx context.Context, sessionID string) {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			if err := c.Heartbeat(ctx, sessionID); err != nil {
				_ = err // non-fatal
			}
		case <-ctx.Done():
			return
		}
	}
}

// post marshals body to JSON and sends a POST request, returning an error on non-2xx.
func (c *Client) post(ctx context.Context, path string, body any) (*http.Response, error) {
	var reqBody io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, fmt.Errorf("orchestrator: marshal: %w", err)
		}
		reqBody = bytes.NewReader(data)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+path, reqBody)
	if err != nil {
		return nil, fmt.Errorf("orchestrator: new request: %w", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("orchestrator: %s: %w", path, err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, fmt.Errorf("orchestrator: %s: status %d", path, resp.StatusCode)
	}
	return resp, nil
}
