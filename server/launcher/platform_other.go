//go:build !windows

package main

import "os/exec"

func hideWindow(cmd *exec.Cmd)     {}
func bindToLauncher(cmd *exec.Cmd) {}
func registerAutostart() error     { return nil }
func openBrowser(url string)       { _ = exec.Command("xdg-open", url).Start() }
func closeOtherCopies() int        { return 0 }
