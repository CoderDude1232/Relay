package api

import (
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"
	"time"

	"github.com/gtank/ristretto255"
	"github.com/relayapp/relay-server/internal/supporter"
	"github.com/relayapp/relay-server/internal/supporter/supportertest"
)

type supporterRequest struct {
	Period  string `json:"period"`
	Blinded []byte `json:"blinded"`
}

type supporterCredential struct {
	Period    string `json:"period"`
	Evaluated []byte `json:"evaluated"`
	Proof     []byte `json:"proof"`
}

// blindFor is the app's side: a fresh nonce and blind for a period.
func blindFor(period string) (nonce []byte, r *ristretto255.Scalar, req supporterRequest) {
	nonce = make([]byte, supporter.NonceLength)
	rand.Read(nonce)
	var rb [64]byte
	rand.Read(rb[:])
	r = ristretto255.NewScalar().FromUniformBytes(rb[:])
	b := ristretto255.NewElement().ScalarMult(r, supporter.HashToGroup(period, nonce))
	return nonce, r, supporterRequest{Period: period, Blinded: b.Encode(nil)}
}

func TestSupporterIssueAndRedeem(t *testing.T) {
	env := newTestEnv(t)
	chain := supportertest.NewChain(t, true)
	verifier, err := supporter.NewAppStoreVerifier("app.relaymsg", supporter.ProductIDs, false)
	if err != nil {
		t.Fatal(err)
	}
	verifier.TrustRoot(chain.Root)
	master := make([]byte, 32)
	rand.Read(master)
	env.api.SetSupporter(supporter.NewIssuer(master), verifier)

	alice := env.register("sup-a", "password-a")
	var status struct {
		Available      bool  `json:"available"`
		SupporterUntil int64 `json:"supporterUntil"`
	}
	env.doJSON("GET", "/v1/accounts/me/supporter", alice.authUser(), "", nil, http.StatusOK, &status)
	if !status.Available || status.SupporterUntil != 0 || env.api.IsSupporter(alice.accountID) {
		t.Fatalf("before: %+v", status)
	}

	now := time.Now()
	thisMonth := supporter.PeriodAt(now, false)
	_, monthEnd, _, _ := supporter.ParsePeriod(thisMonth)
	nextMonth := supporter.PeriodAt(monthEnd, false)
	var keys struct {
		Keys map[string]string `json:"keys"`
	}
	env.doJSON("GET", "/v1/supporter/keys", "", "", nil, http.StatusOK, &keys)
	if keys.Keys[thisMonth] == "" || keys.Keys[nextMonth] == "" {
		t.Fatalf("keys: %v", keys.Keys)
	}

	txID := base64.RawURLEncoding.EncodeToString(master[:9])
	jws := chain.Sign(t, supportertest.Payload(now, txID))
	nonce, r, req := blindFor(thisMonth)
	nonce2, r2, req2 := blindFor(nextMonth)
	var issued struct {
		Credentials []supporterCredential `json:"credentials"`
	}
	env.doJSON("POST", "/v1/supporter/issue", "", "", map[string]any{
		"transaction": jws, "requests": []supporterRequest{req, req2},
	}, http.StatusOK, &issued)
	if len(issued.Credentials) != 2 {
		t.Fatalf("issued %d", len(issued.Credentials))
	}
	unblinded := map[string][]byte{}
	for i, c := range issued.Credentials {
		blinded := []supporterRequest{req, req2}[i].Blinded
		key, _ := base64.StdEncoding.DecodeString(keys.Keys[c.Period])
		if !supporter.VerifyProof(key, blinded, c.Evaluated, c.Proof) {
			t.Fatalf("proof for %s doesn't verify", c.Period)
		}
		e := ristretto255.NewElement()
		e.Decode(c.Evaluated)
		unblinded[c.Period] = ristretto255.NewElement().
			ScalarMult(ristretto255.NewScalar().Invert([]*ristretto255.Scalar{r, r2}[i]), e).Encode(nil)
	}

	// Next month's credential isn't usable yet.
	env.doJSON("POST", "/v1/supporter/redeem", alice.authUser(), "", map[string]any{
		"period": nextMonth, "nonce": nonce2, "credential": unblinded[nextMonth],
	}, http.StatusUnprocessableEntity, nil)
	// A forged credential.
	env.doJSON("POST", "/v1/supporter/redeem", alice.authUser(), "", map[string]any{
		"period": thisMonth, "nonce": nonce2, "credential": unblinded[thisMonth],
	}, http.StatusForbidden, nil)

	var redeemed struct {
		SupporterUntil int64 `json:"supporterUntil"`
	}
	env.doJSON("POST", "/v1/supporter/redeem", alice.authUser(), "", map[string]any{
		"period": thisMonth, "nonce": nonce, "credential": unblinded[thisMonth],
	}, http.StatusOK, &redeemed)
	if redeemed.SupporterUntil != monthEnd.UnixMilli() || !env.api.IsSupporter(alice.accountID) {
		t.Fatalf("redeemed until %d, want %d", redeemed.SupporterUntil, monthEnd.UnixMilli())
	}

	// Spent: not again, not on another account.
	bob := env.register("sup-b", "password-b")
	env.doJSON("POST", "/v1/supporter/redeem", bob.authUser(), "", map[string]any{
		"period": thisMonth, "nonce": nonce, "credential": unblinded[thisMonth],
	}, http.StatusConflict, nil)
	if env.api.IsSupporter(bob.accountID) {
		t.Fatal("bob became a supporter")
	}

	// The transaction allows one reissue (a reinstall), then no more.
	_, _, again := blindFor(thisMonth)
	body := map[string]any{"transaction": jws, "requests": []supporterRequest{again}}
	env.doJSON("POST", "/v1/supporter/issue", "", "", body, http.StatusOK, nil)
	env.doJSON("POST", "/v1/supporter/issue", "", "", body, http.StatusConflict, nil)

	// Periods the purchase doesn't cover, and purchases that don't qualify.
	other := chain.Sign(t, supportertest.Payload(now, txID+"x"))
	_, _, far := blindFor("m2030-01")
	env.doJSON("POST", "/v1/supporter/issue", "", "", map[string]any{
		"transaction": other, "requests": []supporterRequest{far},
	}, http.StatusBadRequest, nil)
	env.doJSON("POST", "/v1/supporter/issue", "", "", map[string]any{
		"transaction": other, "requests": []supporterRequest{again, again},
	}, http.StatusBadRequest, nil)
	sandbox := supportertest.Payload(now, txID+"s")
	sandbox["environment"] = "Sandbox"
	env.doJSON("POST", "/v1/supporter/issue", "", "", map[string]any{
		"transaction": chain.Sign(t, sandbox), "requests": []supporterRequest{again},
	}, http.StatusForbidden, nil)
}
