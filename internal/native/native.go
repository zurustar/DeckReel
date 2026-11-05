package native

import (
	"context"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"time"
)

//go:embed assets/*
var assets embed.FS

type Helper struct{ Path string }

func Resolve() (Helper, error) {
	if runtime.GOOS != "darwin" {
		return Helper{}, fmt.Errorf("PowerPoint rendering requires macOS; use a Mac build")
	}
	name := "deckreel-native-" + runtime.GOARCH
	b, e := assets.ReadFile("assets/" + name)
	if e != nil {
		return Helper{}, fmt.Errorf("native helper not embedded; build with ./scripts/build.sh")
	}
	sum := sha256.Sum256(b)
	tag := hex.EncodeToString(sum[:])
	root, e := os.UserCacheDir()
	if e != nil {
		return Helper{}, e
	}
	dir := filepath.Join(root, "DeckReel", "runtime", tag)
	if e = os.MkdirAll(dir, 0700); e != nil {
		return Helper{}, e
	}
	p := filepath.Join(dir, name)
	old, e := os.ReadFile(p)
	if e != nil || sha256.Sum256(old) != sum {
		f, e := os.CreateTemp(dir, ".native-*")
		if e != nil {
			return Helper{}, e
		}
		tmp := f.Name()
		defer os.Remove(tmp)
		if _, e = f.Write(b); e != nil {
			f.Close()
			return Helper{}, e
		}
		if e = f.Chmod(0700); e != nil {
			f.Close()
			return Helper{}, e
		}
		if e = f.Close(); e != nil {
			return Helper{}, e
		}
		if e = os.Rename(tmp, p); e != nil {
			return Helper{}, e
		}
	}
	return Helper{p}, nil
}
func (h Helper) Call(ctx context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, h.Path, args...)
	b, e := cmd.Output()
	if e != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		if x, ok := e.(*exec.ExitError); ok {
			return nil, fmt.Errorf("native %s: %s", args[0], string(x.Stderr))
		}
		return nil, e
	}
	return b, nil
}
func (h Helper) Info(ctx context.Context) (string, error) {
	b, e := h.Call(ctx, "info")
	return string(b), e
}
func (h Helper) Render(ctx context.Context, pdf, dir string) (int, error) {
	b, e := h.Call(ctx, "render", pdf, dir)
	if e != nil {
		return 0, e
	}
	var r struct {
		Count int `json:"count"`
	}
	e = json.Unmarshal(b, &r)
	return r.Count, e
}
func (h Helper) Clip(ctx context.Context, image, audio, output string, frames int) error {
	_, e := h.Call(ctx, "clip", image, audio, output, fmt.Sprint(frames))
	return e
}
func (h Helper) Join(ctx context.Context, list, output string) error {
	_, e := h.Call(ctx, "join", list, output)
	return e
}
func (h Helper) Inspect(ctx context.Context, file string) ([]byte, error) {
	return h.Call(ctx, "inspect", file)
}
