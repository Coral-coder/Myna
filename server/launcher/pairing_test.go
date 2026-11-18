package main

import (
	"net/url"
	"testing"
)

func TestPairingLinkRoundTrips(t *testing.T) {
	link := pairingLink("http://100.101.102.103", "tok/en+with=odd&chars")
	parsed, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "myna" || parsed.Host != "pair" {
		t.Fatalf("unexpected link %q", link)
	}
	if got := parsed.Query().Get("url"); got != "http://100.101.102.103" {
		t.Errorf("url = %q", got)
	}
	if got := parsed.Query().Get("token"); got != "tok/en+with=odd&chars" {
		t.Errorf("token = %q", got)
	}
}
