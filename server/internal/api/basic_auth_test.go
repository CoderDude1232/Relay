package api

import (
	"net/http"
	"testing"
)

// TestBasicOnlyForAuthKeyBootstrap: a fresh device's password works only on
// PUT /v1/devices/auth-key, and successful Basic authentications per device
// are capped (each one is a bcrypt).
func TestBasicOnlyForAuthKeyBootstrap(t *testing.T) {
	env := newTestEnv(t)
	var resp struct {
		AccountID string `json:"accountId"`
		DeviceID  uint32 `json:"deviceId"`
	}
	env.doJSON("POST", "/v1/accounts", "", "",
		map[string]string{"username": uniqueUsername("basic"), "password": "password123"},
		http.StatusCreated, &resp)
	c := &client{env: env, accountID: resp.AccountID, deviceID: resp.DeviceID, password: "password123"}

	// Even before an auth key exists, Basic is refused everywhere else.
	env.doJSON("GET", "/v1/keys/count", c.authUser(), c.password, nil, http.StatusUnauthorized, nil)
	env.doJSON("GET", "/v1/devices", c.authUser(), c.password, nil, http.StatusUnauthorized, nil)

	// The bootstrap upload works over Basic (1st success)…
	env.clients[c.authUser()] = c
	c.uploadDeviceAuthKey()
	// …after which the route needs a signature, yet each further correct
	// password still costs a bcrypt and spends the success budget.
	for i := 2; i <= 10; i++ {
		req, _ := http.NewRequest("PUT", env.srv.URL+"/v1/devices/auth-key", nil)
		req.SetBasicAuth(c.authUser(), c.password)
		if got := doStatus(t, req); got != http.StatusUnauthorized {
			t.Fatalf("basic success %d after key upload: got %d, want 401", i, got)
		}
	}
	req, _ := http.NewRequest("PUT", env.srv.URL+"/v1/devices/auth-key", nil)
	req.SetBasicAuth(c.authUser(), c.password)
	if got := doStatus(t, req); got != http.StatusTooManyRequests {
		t.Fatalf("11th basic success: got %d, want 429", got)
	}
}

func doStatus(t *testing.T, req *http.Request) int {
	t.Helper()
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.StatusCode
}
