package main

import (
	"bytes"
	"context"
	"testing"
)

func TestCLI(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"--version"}} {
		var b bytes.Buffer
		if code := run(context.Background(), args, &b, &b); code != 0 || b.Len() == 0 {
			t.Fatalf("%v: %d %s", args, code, b.String())
		}
	}
	for _, args := range [][]string{{}, {"--unknown"}, {"missing.pptx", "--speed", "NaN"}} {
		var b bytes.Buffer
		if code := run(context.Background(), args, &b, &b); code != 2 {
			t.Fatalf("%v: %d", args, code)
		}
	}
}
