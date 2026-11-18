//go:build !windows

package main

import "context"

// On other systems (development only) there is no tray icon.
func runTray(ctx context.Context, _ context.CancelFunc) { <-ctx.Done() }
