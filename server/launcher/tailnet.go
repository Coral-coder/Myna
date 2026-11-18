package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"

	"tailscale.com/ipn"
	"tailscale.com/tsnet"
)

// Tailscale runs inside this program (no Tailscale app, no administrator
// rights). The server joins your private network as "myna-server" and listens
// only there; requests are passed to the Python worker on this computer.

func workerProxy() *httputil.ReverseProxy {
	target, _ := url.Parse("http://127.0.0.1:" + workerPort)
	return httputil.NewSingleHostReverseProxy(target)
}

func runTailnet(ctx context.Context, st *status) {
	server := &tsnet.Server{
		Dir:      sub("tsnet"),
		Hostname: "myna-server",
		UserLogf: func(format string, args ...any) { st.logf("tailscale: "+format, args...) },
		Logf:     func(string, ...any) {},
	}
	defer server.Close()

	st.set(func(s *status) { s.Tailnet = "Starting" })
	local, err := server.LocalClient()
	if err != nil {
		st.set(func(s *status) { s.Tailnet = "Could not start: " + err.Error() })
		return
	}

	// Follow sign-in state: the first run needs you to sign in once, in a
	// browser; after that the identity is remembered in the tsnet folder.
	go func() {
		watcher, err := local.WatchIPNBus(ctx, ipn.NotifyInitialState)
		if err != nil {
			return
		}
		defer watcher.Close()
		opened := false
		for {
			notice, err := watcher.Next()
			if err != nil {
				return
			}
			if notice.BrowseToURL != nil && *notice.BrowseToURL != "" {
				link := *notice.BrowseToURL
				st.set(func(s *status) { s.LoginURL = link; s.Tailnet = "Sign in needed" })
				if !opened {
					opened = true
					openBrowser(statusURL)
				}
			}
			if notice.State != nil {
				switch *notice.State {
				case ipn.NeedsLogin:
					st.set(func(s *status) { s.Tailnet = "Sign in needed" })
				case ipn.Running:
					st.set(func(s *status) { s.Tailnet = "Connected"; s.LoginURL = "" })
				}
			}
		}
	}()

	state, err := server.Up(ctx) // waits here until signed in
	if err != nil {
		st.set(func(s *status) { s.Tailnet = "Could not connect: " + err.Error() })
		return
	}
	ip4, _ := server.TailscaleIPs()
	name := strings.TrimSuffix(state.Self.DNSName, ".")
	st.set(func(s *status) {
		s.Tailnet = "Connected"
		s.LoginURL = ""
		s.TailnetIP = ip4.String()
		s.TailnetName = name
	})
	st.logf("On your private network as %s (%s).", name, ip4)

	listener, err := server.Listen("tcp", ":80")
	if err != nil {
		st.set(func(s *status) { s.Tailnet = "Could not listen: " + err.Error() })
		return
	}
	proxy := workerProxy()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Only devices signed in to this same private network get through; the
		// worker then checks the pairing token as well.
		if _, err := local.WhoIs(r.Context(), r.RemoteAddr); err != nil {
			http.Error(w, "not on this private network", http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	httpServer := &http.Server{Handler: handler}
	go func() {
		<-ctx.Done()
		_ = httpServer.Close()
	}()
	_ = httpServer.Serve(listener)
}

// runLAN optionally answers devices on the home network too (off by default).
func runLAN(ctx context.Context, st *status) {
	listener, err := net.Listen("tcp", ":"+lanPort)
	if err != nil {
		st.logf("Home-network listener failed: %v", err)
		return
	}
	proxy := workerProxy()
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		if ip == nil || !(ip.IsPrivate() || ip.IsLoopback()) {
			http.Error(w, "home network only", http.StatusForbidden)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	httpServer := &http.Server{Handler: handler}
	go func() {
		<-ctx.Done()
		_ = httpServer.Close()
	}()
	st.set(func(s *status) { s.LANAddress = lanIP() })
	_ = httpServer.Serve(listener)
}

// lanIP is this computer's address on the home network, for the pairing link.
func lanIP() string {
	conn, err := net.Dial("udp", "192.168.255.255:9")
	if err != nil {
		return ""
	}
	defer conn.Close()
	if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok && addr.IP.IsPrivate() {
		return addr.IP.String()
	}
	return ""
}
