package main

import (
	"net/url"
)

// pairingLink is what the phone scans or pastes: where the server is and the
// token it must present.
func pairingLink(serverURL, token string) string {
	query := url.Values{}
	query.Set("url", serverURL)
	query.Set("token", token)
	return "myna://pair?" + query.Encode()
}
