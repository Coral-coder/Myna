package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"html"
	"net/http"
	"strings"

	qrcode "github.com/skip2/go-qrcode"
)

const (
	uiPort    = "8788"
	lanPort   = "8789"
	statusURL = "http://127.0.0.1:" + uiPort + "/"
)

func qrImage(text string) string {
	png, err := qrcode.Encode(text, qrcode.Medium, 320)
	if err != nil {
		return ""
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png)
}

// statusPage is what the server's window shows. It is served only to this
// computer.
func statusPage(st *status, token string, settings *launcherSettings) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/lan", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			settings.AllowLAN = !settings.AllowLAN
			settings.save()
			st.set(func(s *status) { s.AllowLAN = settings.AllowLAN })
		}
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		snap, _ := st.snapshot()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"version": snap.Version, "worker_up": snap.WorkerUp, "setup": snap.Setup,
			"tailnet": snap.Tailnet, "login_url": snap.LoginURL, "update": snap.Update,
		})
	})
	// Sign-in happens in the default browser: Google and other sign-in
	// providers refuse to run inside an embedded window.
	mux.HandleFunc("/signin", func(w http.ResponseWriter, r *http.Request) {
		if snap, _ := st.snapshot(); snap.LoginURL != "" {
			openBrowser(snap.LoginURL)
		}
		http.Redirect(w, r, "/", http.StatusSeeOther)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		snap, lines := st.snapshot()
		var b strings.Builder
		b.WriteString(`<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="4"><title>Myna Server</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 20px;color:#1b1c1d;background:#e9e9e6}
h1{font-weight:300;font-size:30px;margin:0 0 4px}.k{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#8a8b88;margin-top:22px}
.v{font-size:17px;font-weight:300}a{color:#1b1c1d}pre{font:12px ui-monospace,monospace;background:#dededb;padding:12px;overflow:auto;max-height:220px}
img{background:#fff;padding:10px;margin-top:8px}button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:8px 14px;border:1px solid #1b1c1d;background:none;border-radius:99px;cursor:pointer}
code{word-break:break-all;font-size:12px}</style>`)
		fmt.Fprintf(&b, `<h1>Myna Server</h1><div class="k">version %s</div>`, html.EscapeString(snap.Version))

		row := func(label, value string) {
			fmt.Fprintf(&b, `<div class="k">%s</div><div class="v">%s</div>`, html.EscapeString(label), html.EscapeString(value))
		}
		worker := snap.Setup
		if snap.WorkerUp {
			worker = "Running"
		}
		row("Transcription and writing", worker)
		row("Private network", snap.Tailnet)
		if snap.LoginURL != "" {
			fmt.Fprintf(&b, `<div class="v">This computer and your iPhone find each other over Tailscale, a private encrypted network. It needs a free account, signed in once here and once on the phone.</div><div class="v" style="margin-top:8px"><a href="/signin">Sign in to Tailscale</a> (opens in your browser; this window updates by itself when done)</div>`)
		}
		if snap.Update != "" {
			row("Updates", snap.Update)
		}

		var addresses []string
		if snap.AllowLAN && snap.LANAddress != "" {
			addresses = append(addresses, "http://"+snap.LANAddress+":"+lanPort)
		}
		if snap.TailnetIP != "" {
			addresses = append(addresses, "http://"+snap.TailnetIP)
		}
		if len(addresses) > 0 {
			link := pairingLink(token, addresses...)
			b.WriteString(`<div class="k">Pair your iPhone</div><div class="v">In Myna, open Settings › Home server and tap Scan the code.</div>`)
			fmt.Fprintf(&b, `<img src="%s" width="260" height="260" alt="pairing code"><div><code>%s</code></div>`, qrImage(link), html.EscapeString(link))
		}
		b.WriteString(`<div class="k">Where the phone can reach this computer</div>`)
		switch {
		case snap.AllowLAN && snap.LANAddress != "":
			b.WriteString(`<div class="v">Home Wi-Fi: on.</div>`)
		case snap.AllowLAN:
			b.WriteString(`<div class="v">Home Wi-Fi: turning on…</div>`)
		default:
			b.WriteString(`<div class="v">Home Wi-Fi: off.</div>`)
		}
		if snap.TailnetIP != "" {
			b.WriteString(`<div class="v">Away from home: on, over the private network.</div>`)
		} else {
			b.WriteString(`<div class="v">Away from home: not yet — sign in to Tailscale above. If you pair before signing in, pair again afterwards so the phone learns the away-from-home address.</div>`)
		}
		label := "Turn home Wi-Fi on (restart to apply)"
		if snap.AllowLAN {
			label = "Turn home Wi-Fi off (restart to apply)"
		}
		fmt.Fprintf(&b, `<form method="post" action="/lan" style="margin-top:10px"><button>%s</button></form>`, label)

		b.WriteString(`<div class="k">Recent activity</div><pre>`)
		start := 0
		if len(lines) > 40 {
			start = len(lines) - 40
		}
		for _, line := range lines[start:] {
			b.WriteString(html.EscapeString(line) + "\n")
		}
		b.WriteString(`</pre>`)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(b.String()))
	})
	return mux
}
