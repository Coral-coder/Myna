//go:build windows

package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"runtime"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"

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
	keepPlace(uintptr(view.Window()))
	// Open on the home screen (the transcript); Status is the last tab. Until
	// the worker is set up, this lands on Status by itself.
	view.Navigate(statusURL + "browse")

	view.Run()
}

var (
	user32            = windows.NewLazySystemDLL("user32.dll")
	procGetWindowRect = user32.NewProc("GetWindowRect")
	procSetWindowPos  = user32.NewProc("SetWindowPos")
	procIsWindow      = user32.NewProc("IsWindow")
	procIsIconic      = user32.NewProc("IsIconic")
)

type rect struct{ Left, Top, Right, Bottom int32 }

// keepPlace puts the window where it was last time (so it doesn't jump to
// the middle of the screen after an update) and remembers where it is moved.
func keepPlace(hwnd uintptr) {
	if hwnd == 0 {
		return
	}
	var saved rect
	if raw, err := os.ReadFile(sub("window.json")); err == nil && json.Unmarshal(raw, &saved) == nil &&
		saved.Right-saved.Left >= 400 && saved.Bottom-saved.Top >= 300 {
		const noZOrder, noActivate = 0x0004, 0x0010
		procSetWindowPos.Call(hwnd, 0, uintptr(saved.Left), uintptr(saved.Top),
			uintptr(saved.Right-saved.Left), uintptr(saved.Bottom-saved.Top), noZOrder|noActivate)
	}
	go func() {
		var last rect
		for {
			time.Sleep(2 * time.Second)
			if alive, _, _ := procIsWindow.Call(hwnd); alive == 0 {
				return
			}
			if minimised, _, _ := procIsIconic.Call(hwnd); minimised != 0 {
				continue
			}
			var now rect
			if ok, _, _ := procGetWindowRect.Call(hwnd, uintptr(unsafe.Pointer(&now))); ok == 0 || now == last {
				continue
			}
			last = now
			if raw, err := json.Marshal(now); err == nil {
				_ = os.WriteFile(sub("window.json"), raw, 0o600)
			}
		}
	}()
}
