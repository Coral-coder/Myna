//go:build windows

package main

import (
	"context"
	_ "embed"

	"fyne.io/systray"
)

//go:embed tray.ico
var trayIcon []byte

// runTray keeps Myna Server in the notification area for as long as it runs.
// Closing the window only hides it: click the icon to bring it back, or use
// its menu to quit. Returns when the server is asked to stop.
func runTray(ctx context.Context, stop context.CancelFunc) {
	systray.Run(func() {
		systray.SetIcon(trayIcon)
		systray.SetTitle("Myna Server")
		systray.SetTooltip("Myna Server")
		systray.SetOnTapped(showWindow)
		open := systray.AddMenuItem("Open Myna Server", "Show the window")
		systray.AddSeparator()
		quit := systray.AddMenuItem("Quit", "Stop the server")
		go func() {
			for {
				select {
				case <-open.ClickedCh:
					showWindow()
				case <-quit.ClickedCh:
					stop()
					systray.Quit()
					return
				case <-ctx.Done():
					systray.Quit()
					return
				}
			}
		}()
	}, func() {})
	stop()
}
