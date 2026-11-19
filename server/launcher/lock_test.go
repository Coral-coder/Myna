package main

import (
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestLockGuardsEveryPageUntilUnlocked(t *testing.T) {
	t.Setenv("MYNA_SERVER_HOME", t.TempDir())
	settings := &launcherSettings{}
	l := newLock(settings)
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("secret transcript")) })
	server := httptest.NewServer(l.guard(inner))
	defer server.Close()
	jar := newJar()
	client := &http.Client{Jar: jar, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}

	body := func(path string) string {
		reply, err := client.Get(server.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		defer reply.Body.Close()
		raw, _ := io.ReadAll(reply.Body)
		return string(raw)
	}
	post := func(path string, form url.Values) *http.Response {
		reply, err := client.PostForm(server.URL+path, form)
		if err != nil {
			t.Fatal(err)
		}
		reply.Body.Close()
		return reply
	}

	if page := body("/browse"); strings.Contains(page, "secret") || !strings.Contains(page, "Choose a password") {
		t.Fatalf("first view should ask for a new password, got %q", page)
	}
	post("/setpassword", url.Values{"password": {"hunter22"}, "again": {"hunter22"}})
	if settings.PasswordHash == "" || strings.Contains(settings.PasswordHash, "hunter22") {
		t.Fatal("the password should be stored as a hash")
	}
	if page := body("/browse"); page != "secret transcript" {
		t.Fatalf("after setting a password the window is open, got %q", page)
	}
	post("/lock", nil)
	if page := body("/browse"); strings.Contains(page, "secret") || !strings.Contains(page, "Locked") {
		t.Fatalf("after Lock the page must be hidden, got %q", page)
	}
	post("/unlock", url.Values{"password": {"hunter22"}})
	if page := body("/browse"); page != "secret transcript" {
		t.Fatalf("the right password opens it again, got %q", page)
	}
	// A second password can't be set over the first.
	post("/lock", nil)
	post("/setpassword", url.Values{"password": {"other"}, "again": {"other"}})
	if page := body("/browse"); strings.Contains(page, "secret") {
		t.Fatal("setting a password again must not unlock")
	}
}

func newJar() http.CookieJar {
	jar, _ := cookiejar.New(nil)
	return jar
}

func TestUnlockSurvivesARestart(t *testing.T) {
	t.Setenv("MYNA_SERVER_HOME", t.TempDir())
	settings := &launcherSettings{}
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte("open")) })
	first := httptest.NewServer(newLock(settings).guard(inner))
	client := &http.Client{Jar: newJar(), CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	reply, _ := client.PostForm(first.URL+"/setpassword", url.Values{"password": {"hunter22"}, "again": {"hunter22"}})
	reply.Body.Close()
	cookies := client.Jar.Cookies(mustURL(first.URL))
	if len(cookies) == 0 {
		t.Fatal("no session cookie")
	}
	first.Close()

	// The server restarts (an update): a new lock, same disk, same cookie.
	second := httptest.NewServer(newLock(settings).guard(inner))
	defer second.Close()
	request, _ := http.NewRequest(http.MethodGet, second.URL+"/browse", nil)
	request.AddCookie(cookies[0])
	reply, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(reply.Body)
	reply.Body.Close()
	if string(body) != "open" {
		t.Fatalf("still unlocked after a restart, got %q", body)
	}
}

func mustURL(raw string) *url.URL {
	parsed, _ := url.Parse(raw)
	return parsed
}
