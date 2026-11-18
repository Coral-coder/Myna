// MynaServer runs Myna's home server on this computer: it sets up and
// supervises the Python worker that transcribes and writes, joins your private
// Tailscale network without the Tailscale app, shows a status page for
// pairing, starts with Windows, and updates itself from GitHub releases.
package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"os/signal"
)

func main() {
	background := false
	for _, arg := range os.Args[1:] {
		if arg == "--background" {
			background = true
		}
	}

	// One copy at a time. If the status page port is taken, another copy is
	// already running: just show its page.
	listener, err := net.Listen("tcp", "127.0.0.1:"+uiPort)
	if err != nil {
		openBrowser(statusURL)
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	st := &status{Version: version, Setup: "Starting", Tailnet: "Starting"}
	settings := loadSettings()
	st.AllowLAN = settings.AllowLAN
	st.logf("Myna Server %s starting.", version)

	token, err := readToken()
	if err != nil {
		st.logf("Could not create the pairing token: %v", err)
	}
	if err := registerAutostart(); err != nil {
		st.logf("Could not register to start with Windows: %v", err)
	}

	go func() { _ = http.Serve(listener, statusPage(st, token, &settings)) }()
	go updateLoop(ctx, st)
	go runTailnet(ctx, st)
	if settings.AllowLAN {
		go runLAN(ctx, st)
	}
	go func() {
		payload, err := prepareWorker(ctx, st)
		if err != nil {
			st.set(func(s *status) { s.Setup = "Setup failed: " + err.Error() })
			st.logf("Setup failed: %v", err)
			return
		}
		superviseWorker(ctx, st, payload)
	}()

	if !background {
		openBrowser(statusURL)
	}
	<-ctx.Done()
}
