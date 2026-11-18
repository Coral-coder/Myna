package main

import (
	"crypto/rand"
	"encoding/hex"
	"html"
	"net/http"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// The window is locked behind a password: everything Myna has heard is in
// here. The password is chosen the first time the window opens and kept only
// as a hash. Unlocking lasts until Lock is pressed or the server restarts.
type lock struct {
	mu       sync.Mutex
	settings *launcherSettings
	sessions map[string]bool
}

const sessionCookie = "myna_session"

func newLock(settings *launcherSettings) *lock {
	return &lock{settings: settings, sessions: map[string]bool{}}
}

func (l *lock) unlocked(r *http.Request) bool {
	cookie, err := r.Cookie(sessionCookie)
	if err != nil {
		return false
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.sessions[cookie.Value]
}

func (l *lock) open(w http.ResponseWriter) {
	raw := make([]byte, 32)
	_, _ = rand.Read(raw)
	id := hex.EncodeToString(raw)
	l.mu.Lock()
	l.sessions[id] = true
	l.mu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: sessionCookie, Value: id, Path: "/", HttpOnly: true, SameSite: http.SameSiteStrictMode})
}

// lockAll ends every unlocked session: the next view needs the password.
func (l *lock) lockAll() {
	l.mu.Lock()
	l.sessions = map[string]bool{}
	l.mu.Unlock()
}

func (l *lock) hasPassword() bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.settings.PasswordHash != ""
}

const lockStyle = `<!doctype html><meta charset="utf-8"><title>Myna Server</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:360px;margin:120px auto;padding:0 20px;color:#e9e9e6;background:#141517;color-scheme:dark}
h1{font-weight:300;font-size:26px;margin:0 0 6px}p{color:#9b9d9e;font-size:13px}
input{font:inherit;width:100%;box-sizing:border-box;padding:9px 11px;margin-top:8px;border:1px solid #ffffff33;border-radius:8px;background:#ffffff0d;color:#e9e9e6}
button{margin-top:14px;font:12px ui-monospace,monospace;letter-spacing:.1em;text-transform:uppercase;padding:8px 16px;border:1px solid #e9e9e6;color:#e9e9e6;background:none;border-radius:99px;cursor:pointer}
.bad{color:#e9e9e6}</style>`

func (l *lock) page(w http.ResponseWriter, message string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	note := ""
	if message != "" {
		note = `<p class="bad">` + html.EscapeString(message) + `</p>`
	}
	if !l.hasPassword() {
		_, _ = w.Write([]byte(lockStyle + `<h1>Choose a password</h1>
<p>Everything Myna hears is kept on this computer. This password opens this window; it is asked for whenever the window is locked.</p>` + note + `
<form method="post" action="/setpassword"><input type="password" name="password" placeholder="Password" autofocus>
<input type="password" name="again" placeholder="Again"><button>Set password</button></form>`))
		return
	}
	_, _ = w.Write([]byte(lockStyle + `<h1>Myna Server</h1><p>Locked. The server keeps running.</p>` + note + `
<form method="post" action="/unlock"><input type="password" name="password" placeholder="Password" autofocus><button>Unlock</button></form>`))
}

// guard puts the lock in front of every page.
func (l *lock) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/setpassword" && r.Method == http.MethodPost:
			if l.hasPassword() {
				http.Redirect(w, r, "/", http.StatusSeeOther)
				return
			}
			password := r.FormValue("password")
			if len(password) < 4 {
				l.page(w, "Use at least four characters.")
				return
			}
			if password != r.FormValue("again") {
				l.page(w, "The two didn't match.")
				return
			}
			hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
			if err != nil {
				l.page(w, "Couldn't save the password.")
				return
			}
			l.mu.Lock()
			l.settings.PasswordHash = string(hash)
			l.settings.save()
			l.mu.Unlock()
			l.open(w)
			http.Redirect(w, r, "/browse", http.StatusSeeOther)
		case r.URL.Path == "/unlock" && r.Method == http.MethodPost:
			l.mu.Lock()
			hash := l.settings.PasswordHash
			l.mu.Unlock()
			if bcrypt.CompareHashAndPassword([]byte(hash), []byte(r.FormValue("password"))) != nil {
				time.Sleep(time.Second) // slow down guessing
				l.page(w, "That isn't the password.")
				return
			}
			l.open(w)
			http.Redirect(w, r, "/browse", http.StatusSeeOther)
		case r.URL.Path == "/lock" && r.Method == http.MethodPost:
			l.lockAll()
			http.Redirect(w, r, "/", http.StatusSeeOther)
		case !l.unlocked(r):
			if r.Method != http.MethodGet || r.Header.Get("Sec-Fetch-Dest") == "empty" {
				// A background refresh or a form from a locked window: say so
				// plainly so the page shows the lock screen on its next load.
				http.Error(w, "locked", http.StatusUnauthorized)
				return
			}
			l.page(w, "")
		default:
			next.ServeHTTP(w, r)
		}
	})
}
