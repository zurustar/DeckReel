package main

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
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

func TestEventWriter(t *testing.T) {
	var b bytes.Buffer
	w := &eventWriter{enc: json.NewEncoder(&b)}
	w.Write([]byte("Render: 2 slides\n"))
	w.emit(event{Type: "progress", Current: 1, Total: 2})
	w.emit(event{Type: "done", Output: "/tmp/a.mp4"})
	var got []event
	for _, line := range strings.Split(strings.TrimSpace(b.String()), "\n") {
		var e event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatal(err)
		}
		got = append(got, e)
	}
	if len(got) != 3 || got[0] != (event{Type: "log", Message: "Render: 2 slides"}) || got[1].Current != 1 || got[2].Output != "/tmp/a.mp4" {
		t.Fatalf("%+v", got)
	}
}
