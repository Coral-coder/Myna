package main

import (
	"net/url"
	"testing"
)

func TestPairingLinkRoundTrips(t *testing.T) {
	link := pairingLink("tok/en+with=odd&chars", "http://192.168.1.20:8789", "http://100.101.102.103")
	parsed, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	if parsed.Scheme != "myna" || parsed.Host != "pair" {
		t.Fatalf("unexpected link %q", link)
	}
	if got := parsed.Query()["url"]; len(got) != 2 || got[0] != "http://192.168.1.20:8789" || got[1] != "http://100.101.102.103" {
		t.Errorf("url = %q", got)
	}
	if got := parsed.Query().Get("token"); got != "tok/en+with=odd&chars" {
		t.Errorf("token = %q", got)
	}
}
