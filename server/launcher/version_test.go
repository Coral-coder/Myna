package main

import "testing"

func TestNewer(t *testing.T) {
	cases := []struct {
		candidate, current string
		want               bool
	}{
		{"0.1.2", "0.1.1", true},
		{"0.1.10", "0.1.9", true},
		{"0.2.0", "0.1.99", true},
		{"v1.0.0", "0.9.9", true},
		{"0.1.1", "0.1.1", false},
		{"0.1.0", "0.1.1", false},
		{"1.0", "1.0.0", false},
		{"9.9.9", "0.0.0-dev", false}, // development builds are left alone
	}
	for _, c := range cases {
		if got := newer(c.candidate, c.current); got != c.want {
			t.Errorf("newer(%q, %q) = %v, want %v", c.candidate, c.current, got, c.want)
		}
	}
}
