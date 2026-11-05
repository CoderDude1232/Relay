// Package mail sends relayd's one-time code emails through Resend. The
// provider sees the address and the code, never the Relay account.
package mail

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"io"
	"net/http"
	"time"
)

// Purpose picks an email's wording.
type Purpose string

const (
	SignIn Purpose = "signin" // sign in, or create an account
	Reset  Purpose = "reset"  // forgot the account password
	Change Purpose = "change" // confirm a new address for an account
)

// Sender delivers one code email.
type Sender interface {
	SendCode(ctx context.Context, to string, purpose Purpose, code string) error
}

// Resend sends through the Resend API.
type Resend struct {
	APIKey string
	From   string // "Relay <codes@relaymsg.app>"
	client *http.Client
}

// NewResend makes a Resend sender.
func NewResend(apiKey, from string) *Resend {
	return &Resend{APIKey: apiKey, From: from, client: &http.Client{Timeout: 15 * time.Second}}
}

type wording struct{ Subject, Intro, Footnote string }

var wordings = map[Purpose]wording{
	SignIn: {"Your Relay code: %s", "Here's your code to sign in to Relay:",
		"If you didn't try to sign in, you can ignore this email. No one can sign in without this code."},
	Reset: {"Reset your Relay password: %s", "Here's your code to reset your Relay account password:",
		"If you didn't ask to reset your password, you can ignore this email. Nothing changes without this code."},
	Change: {"Confirm your new Relay email: %s", "Here's your code to use this address with your Relay account:",
		"If you didn't ask to change your email, you can ignore this email. Nothing changes without this code."},
}

var page = template.Must(template.New("code").Parse(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light">
  <title>Your Relay code</title>
</head>
<body style="margin:0; padding:0; background:#ffffff;">
  <div style="display:none; max-height:0; overflow:hidden;">Your Relay code is {{.Code}}</div>
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#ffffff;">
    <tr>
      <td align="center" style="padding:40px 24px;">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:440px; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; color:#111111;">
          <tr><td style="padding:0 0 32px 0;"><img src="https://relaymsg.app/images/relay-logo-dark-ink.png" width="120" alt="Relay" style="display:block; width:120px; height:auto; border:0;"></td></tr>
          <tr><td style="font-size:16px; line-height:24px; padding:0 0 20px 0;">{{.Intro}}</td></tr>
          <tr><td style="padding:0 0 24px 0;"><span style="display:inline-block; background:#f3f3f5; border-radius:8px; padding:12px 18px; font-family:ui-monospace,Menlo,Consolas,'Courier New',monospace; font-size:28px; font-weight:600; letter-spacing:6px; color:#111111;">{{.Code}}</span></td></tr>
          <tr><td style="font-size:14px; line-height:21px; color:#666666; padding:0 0 32px 0;">{{.Footnote}} The code works for 10 minutes.</td></tr>
          <tr><td style="font-size:12px; line-height:18px; color:#999999; border-top:1px solid #eeeeee; padding:16px 0 0 0;"><a href="https://relaymsg.app" style="color:#999999;">relaymsg.app</a></td></tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>
`))

// Render returns an email's subject, HTML and plain-text bodies.
func Render(purpose Purpose, code string) (subject, html, text string, err error) {
	w, ok := wordings[purpose]
	if !ok {
		return "", "", "", fmt.Errorf("mail: unknown purpose %q", purpose)
	}
	var b bytes.Buffer
	if err := page.Execute(&b, map[string]string{"Code": code, "Intro": w.Intro, "Footnote": w.Footnote}); err != nil {
		return "", "", "", err
	}
	text = w.Intro + "\n\n" + code + "\n\n" + w.Footnote + " The code works for 10 minutes.\n\nrelaymsg.app\n"
	return fmt.Sprintf(w.Subject, code), b.String(), text, nil
}

// SendCode implements Sender.
func (r *Resend) SendCode(ctx context.Context, to string, purpose Purpose, code string) error {
	subject, html, text, err := Render(purpose, code)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(map[string]any{
		"from": r.From, "to": []string{to}, "subject": subject, "html": html, "text": text,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.resend.com/emails", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+r.APIKey)
	req.Header.Set("Content-Type", "application/json")
	resp, err := r.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		// The body can echo the address; keep only the status.
		io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10)) //nolint:errcheck
		return fmt.Errorf("mail: resend: HTTP %d", resp.StatusCode)
	}
	return nil
}
