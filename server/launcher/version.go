package main

import (
	"strconv"
	"strings"
)

// version is set at build time (-ldflags "-X main.version=0.1.42").
var version = "0.0.0-dev"

// newer reports whether candidate is a later release than current. Versions
// are dotted numbers; anything unparseable counts as 0, and a "-dev" build is
// never replaced automatically.
func newer(candidate, current string) bool {
	if strings.Contains(current, "dev") {
		return false
	}
	a, b := parts(candidate), parts(current)
	for i := 0; i < len(a) || i < len(b); i++ {
		var x, y int
		if i < len(a) {
			x = a[i]
		}
		if i < len(b) {
			y = b[i]
		}
		if x != y {
			return x > y
		}
	}
	return false
}

func parts(v string) []int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	if i := strings.IndexAny(v, "-+"); i >= 0 {
		v = v[:i]
	}
	var out []int
	for _, field := range strings.Split(v, ".") {
		n, _ := strconv.Atoi(field)
		out = append(out, n)
	}
	return out
}
