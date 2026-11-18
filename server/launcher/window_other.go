//go:build !windows

package main

// On other systems (used only for development) the status page opens in the
// default browser.
func showWindow() { openBrowser(statusURL + "browse") }
func runWindow()  { openBrowser(statusURL + "browse") }
