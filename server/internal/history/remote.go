package history

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"
)

// RemoteClient is relayd's client for historyd.
type RemoteClient struct {
	base   string
	secret []byte
	client *http.Client

	healthy atomic.Bool
	kick    chan struct{}
}

const (
	remoteProbeInterval = 30 * time.Second
	remoteProbeTimeout  = 5 * time.Second
	remoteTimeout       = 30 * time.Second
	// The remote counts as healthy only with room for a full segment.
	remoteMinFree = MaxSegmentBytes
	maxListBytes  = 64 << 20
)

// NewRemote talks to historyd at baseURL (e.g. https://turn.example:9479). It
// starts unhealthy until the first probe answers.
func NewRemote(baseURL string, secret []byte) *RemoteClient {
	return &RemoteClient{
		base: strings.TrimRight(baseURL, "/"), secret: secret,
		client: &http.Client{Timeout: remoteTimeout},
		kick:   make(chan struct{}, 1),
	}
}

// Healthy reports the last probe's verdict.
func (r *RemoteClient) Healthy() bool { return r.healthy.Load() }

// Failed takes the remote out of rotation and asks for a probe right away.
func (r *RemoteClient) Failed() {
	r.setHealthy(false, "a request failed")
	select {
	case r.kick <- struct{}{}:
	default:
	}
}

func (r *RemoteClient) setHealthy(ok bool, why string) {
	if r.healthy.Swap(ok) == ok {
		return
	}
	if ok {
		slog.Warn("history: remote store healthy")
	} else {
		slog.Warn("history: remote store unhealthy", "why", why)
	}
}

// Probe asks historyd for /health once and updates Healthy.
func (r *RemoteClient) Probe(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, remoteProbeTimeout)
	defer cancel()
	resp, err := r.do(ctx, http.MethodGet, "/health", nil)
	if err != nil {
		r.setHealthy(false, "not answering")
		return false
	}
	defer resp.Body.Close()
	var h struct {
		FreeBytes int64 `json:"freeBytes"`
	}
	if resp.StatusCode != http.StatusOK || json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&h) != nil {
		r.setHealthy(false, fmt.Sprintf("health check: HTTP %d", resp.StatusCode))
		return false
	}
	if h.FreeBytes < remoteMinFree {
		r.setHealthy(false, "out of space")
		return false
	}
	r.setHealthy(true, "")
	return true
}

// Run probes every 30 s, and right after a failure, until ctx ends.
func (r *RemoteClient) Run(ctx context.Context) {
	t := time.NewTicker(remoteProbeInterval)
	defer t.Stop()
	for {
		r.Probe(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		case <-r.kick:
		}
	}
}

func (r *RemoteClient) do(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, method, r.base+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set(AuthHeader, SignRequest(r.secret, method, path, body, time.Now()))
	if body != nil {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	return r.client.Do(req)
}

func statusErr(op string, code int) error {
	switch code {
	case http.StatusNotFound:
		return ErrNotFound
	case http.StatusInsufficientStorage:
		return ErrNoSpace
	}
	return fmt.Errorf("history: remote %s: HTTP %d", op, code)
}

func (r *RemoteClient) Put(ctx context.Context, key string, data []byte) error {
	if !ValidKey(key) {
		return errors.New("history: invalid blob key")
	}
	resp, err := r.do(ctx, http.MethodPut, "/v1/blob/"+key, data)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		return statusErr("put", resp.StatusCode)
	}
	return nil
}

func (r *RemoteClient) Get(ctx context.Context, key string) ([]byte, error) {
	if !ValidKey(key) {
		return nil, ErrNotFound
	}
	resp, err := r.do(ctx, http.MethodGet, "/v1/blob/"+key, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, statusErr("get", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, MaxSegmentBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > MaxSegmentBytes {
		return nil, errors.New("history: remote blob over the segment cap")
	}
	return data, nil
}

// Delete removes a blob; a missing one is not an error.
func (r *RemoteClient) Delete(ctx context.Context, key string) error {
	if !ValidKey(key) {
		return nil
	}
	resp, err := r.do(ctx, http.MethodDelete, "/v1/blob/"+key, nil)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		return statusErr("delete", resp.StatusCode)
	}
	return nil
}

// List returns every blob historyd holds, for the orphan sweep.
func (r *RemoteClient) List(ctx context.Context) ([]BlobInfo, error) {
	resp, err := r.do(ctx, http.MethodGet, "/v1/blobs", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, statusErr("list", resp.StatusCode)
	}
	var out struct {
		Blobs []BlobInfo `json:"blobs"`
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxListBytes)).Decode(&out); err != nil {
		return nil, err
	}
	return out.Blobs, nil
}
