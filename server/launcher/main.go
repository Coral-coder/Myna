// MynaServer runs Myna's home server on this computer: it sets up and
// supervises the Python worker that transcribes and writes, joins your private
// Tailscale network without the Tailscale app, shows its own window for
// sign-in and pairing, starts with Windows, and updates itself from GitHub
// releases.
package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"os/signal"
)

func main() {
	background, windowOnly := false, false
	for _, arg := range os.Args[1:] {
		switch arg {
		case "--background":
			background = true
		case "--window":
			windowOnly = true
		}
	}
	if windowOnly {
		runWindow()
		return
	}

	// One server at a time. If the status port is taken, the server is already
	// running, so this copy just becomes its window.
	listener, err := net.Listen("tcp", "127.0.0.1:"+uiPort)
	if err != nil {
		runWindow()
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
		showWindow()
	}
	runTray(ctx, stop)
}
