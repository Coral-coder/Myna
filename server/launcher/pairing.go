package main

import (
	"net/url"
)

// pairingLink is what the phone scans or pastes: every address the server can
// be reached at (home network, private network) and the token it must present.
// The phone uses whichever address answers.
func pairingLink(token string, serverURLs ...string) string {
	query := url.Values{}
	for _, serverURL := range serverURLs {
		query.Add("url", serverURL)
	}
	query.Set("token", token)
	return "myna://pair?" + query.Encode()
}
