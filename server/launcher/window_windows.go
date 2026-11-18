//go:build windows

package main

import (
	"os"
	"os/exec"
	"runtime"

	webview2 "github.com/jchv/go-webview2"
)

// The server's own window. It is a separate, short-lived copy of this program
// (started with --window) so closing it never stops the server, and opening
// the exe again just brings the window back.

// showWindow opens the window from the running server.
func showWindow() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	cmd := exec.Command(exe, "--window")
	_ = cmd.Start()
}

// runWindow shows the status page in a native window and returns when it is
// closed. The page refreshes itself, so it follows sign-in and pairing state.
func runWindow() {
	runtime.LockOSThread()
	view := webview2.NewWithOptions(webview2.WebViewOptions{
		AutoFocus: true,
		DataPath:  sub("webview"),
		WindowOptions: webview2.WindowOptions{
			Title:  "Myna Server",
			IconId: 1, // the icon built into the exe (winres/)
			Width:  820,
			Height: 900,
			Center: true,
		},
	})
	if view == nil {
		// The Edge WebView2 runtime ships with Windows 11; if it is somehow
		// missing, fall back to the default browser rather than show nothing.
		openBrowser(statusURL)
		return
	}
	defer view.Destroy()
	// Open on the home screen (the transcript); Status is the last tab. Until
	// the worker is set up, this lands on Status by itself.
	view.Navigate(statusURL + "browse")

	view.Run()
}
