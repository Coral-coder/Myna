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
	// The database pages come from the worker; this window is already on this
	// computer, so the launcher presents the pairing token for it.
	database := workerProxy()
	// While the worker is still being set up, show the status page instead.
	database.ErrorHandler = func(w http.ResponseWriter, r *http.Request, _ error) {
		http.Redirect(w, r, "/", http.StatusSeeOther)
	}
	mux.HandleFunc("/browse", func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+token)
		database.ServeHTTP(w, r)
	})
	mux.HandleFunc("/browse/", func(w http.ResponseWriter, r *http.Request) {
		r.Header.Set("Authorization", "Bearer "+token)
		database.ServeHTTP(w, r)
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
		b.WriteString(`<!doctype html><meta charset="utf-8"><title>Myna Server</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:760px;margin:28px auto;padding:0 20px;color:#1b1c1d;background:#e9e9e6}
h1{font-weight:300;font-size:30px;margin:0 0 4px}.k{font:11px ui-monospace,monospace;letter-spacing:.14em;text-transform:uppercase;color:#8a8b88;margin-top:22px}
.v{font-size:17px;font-weight:300}a{color:#1b1c1d}pre{font:12px ui-monospace,monospace;background:#dededb;padding:12px;overflow:auto;max-height:220px}
img{background:#fff;padding:10px;margin-top:8px}button{font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:8px 14px;border:1px solid #1b1c1d;background:none;border-radius:99px;cursor:pointer}
code{word-break:break-all;font-size:12px}
nav{display:flex;gap:16px;flex-wrap:wrap;border-bottom:1px solid #0002;padding-bottom:10px;margin-bottom:22px}
nav a{text-decoration:none;font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;color:#6c6d6b}
nav a.on{color:#1b1c1d;border-bottom:1px solid #1b1c1d}</style>
<nav><a href="/browse?kind=utterance">Transcript</a><a href="/browse?kind=note">Notes</a><a href="/browse?kind=memory">Memories</a><a href="/browse?kind=item">Lists</a><a href="/browse?kind=person">People</a><a class="on" href="/" style="margin-left:auto">Status</a></nav><div id="page">`)
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
		b.WriteString(`</pre></div>`)
		// Keep the page current without reloading it, so scrolling (the page or
		// the activity list) stays where you put it.
		b.WriteString(`<script>
let last = document.getElementById('page').innerHTML;
setInterval(async () => {
  try {
    if (String(window.getSelection())) return;
    const text = await (await fetch('/', {cache: 'no-store'})).text();
    const next = new DOMParser().parseFromString(text, 'text/html').getElementById('page');
    if (!next || next.innerHTML === last) return;
    const page = document.getElementById('page');
    const log = page.querySelector('pre');
    const top = log ? log.scrollTop : 0;
    const atEnd = log ? log.scrollTop + log.clientHeight >= log.scrollHeight - 4 : false;
    const y = window.scrollY;
    last = next.innerHTML;
    page.innerHTML = last;
    const fresh = page.querySelector('pre');
    if (fresh) fresh.scrollTop = atEnd && top > 0 ? fresh.scrollHeight : top;
    window.scrollTo(0, y);
  } catch (e) {}
}, 3000);
</script>`)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(b.String()))
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Answer only when addressed as this computer, so no web page elsewhere
		// can reach these pages under another name.
		if host := r.Host; host != "127.0.0.1:"+uiPort && host != "localhost:"+uiPort {
			http.Error(w, "this page is only for this computer", http.StatusForbidden)
			return
		}
		mux.ServeHTTP(w, r)
	})
}
