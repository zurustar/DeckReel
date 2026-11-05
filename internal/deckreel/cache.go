package deckreel

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

const cacheVersion = 1

type Artifact struct {
	Path string `json:"path"`
	Hash string `json:"sha256"`
}
type Stage struct {
	Key       string     `json:"key"`
	State     string     `json:"state"`
	Artifacts []Artifact `json:"artifacts,omitempty"`
	Error     string     `json:"error,omitempty"`
}
type Manifest struct {
	Version int              `json:"version"`
	Input   string           `json:"input_sha256"`
	Order   []string         `json:"slide_order"`
	Stages  map[string]Stage `json:"stages"`
	Updated time.Time        `json:"updated"`
}
type Cache struct {
	Dir      string
	Manifest Manifest
	lock     *os.File
}

func Key(v any) string {
	b, e := json.Marshal(v)
	if e != nil {
		panic(e)
	}
	return Hash(b)
}
func Hash(b []byte) string { h := sha256.Sum256(b); return hex.EncodeToString(h[:]) }
func FileHash(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	_, e = io.Copy(h, f)
	return hex.EncodeToString(h.Sum(nil)), e
}
func Lock(path string) (*os.File, error) {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return nil, e
	}
	f, e := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if e != nil {
		return nil, e
	}
	if e = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		f.Close()
		return nil, fmt.Errorf("another DeckReel process holds %s", path)
	}
	return f, nil
}
func OpenCache(dir string) (*Cache, error) {
	abs, e := filepath.Abs(dir)
	if e != nil {
		return nil, e
	}
	f, e := Lock(filepath.Join(abs, ".lock"))
	if e != nil {
		return nil, e
	}
	c := &Cache{Dir: abs, lock: f, Manifest: Manifest{Version: cacheVersion, Stages: map[string]Stage{}}}
	b, e := os.ReadFile(filepath.Join(abs, "manifest.json"))
	if e == nil {
		var m Manifest
		if json.Unmarshal(b, &m) != nil {
			c.Close()
			return nil, fmt.Errorf("invalid manifest; move work directory aside to rebuild")
		}
		if m.Version == cacheVersion && m.Stages != nil {
			c.Manifest = m
		}
	} else if !os.IsNotExist(e) {
		c.Close()
		return nil, e
	}
	return c, nil
}
func (c *Cache) Close() {
	if c.lock != nil {
		syscall.Flock(int(c.lock.Fd()), syscall.LOCK_UN)
		c.lock.Close()
	}
}
func (c *Cache) path(rel string) (string, error) {
	if !filepath.IsLocal(rel) {
		return "", fmt.Errorf("invalid cache path")
	}
	full := filepath.Join(c.Dir, rel)
	for p := full; p != c.Dir; p = filepath.Dir(p) {
		st, e := os.Lstat(p)
		if e == nil && st.Mode()&os.ModeSymlink != 0 {
			return "", fmt.Errorf("symlink in cache path")
		}
		if e != nil && !os.IsNotExist(e) {
			return "", e
		}
	}
	return full, nil
}
func (c *Cache) Valid(name, key string) bool {
	s, ok := c.Manifest.Stages[name]
	if !ok || s.State != "succeeded" || s.Key != key || len(s.Artifacts) == 0 {
		return false
	}
	for _, a := range s.Artifacts {
		p, e := c.path(a.Path)
		if e != nil {
			return false
		}
		h, e := FileHash(p)
		if e != nil || h != a.Hash {
			return false
		}
	}
	return true
}
func (c *Cache) Start(name, key string) error {
	c.Manifest.Stages[name] = Stage{Key: key, State: "running"}
	return c.Save()
}
func (c *Cache) Fail(name string, cause error) error {
	s := c.Manifest.Stages[name]
	s.State = "failed"
	if errors.Is(cause, context.Canceled) {
		s.State = "interrupted"
	}
	s.Error = cause.Error()
	c.Manifest.Stages[name] = s
	return c.Save()
}
func (c *Cache) Complete(name, key string, paths ...string) error {
	s := Stage{Key: key, State: "succeeded"}
	for _, rel := range paths {
		p, e := c.path(rel)
		if e != nil {
			return e
		}
		h, e := FileHash(p)
		if e != nil {
			return e
		}
		s.Artifacts = append(s.Artifacts, Artifact{rel, h})
	}
	c.Manifest.Stages[name] = s
	return c.Save()
}
func (c *Cache) Save() error {
	c.Manifest.Updated = time.Now().UTC()
	b, e := json.MarshalIndent(c.Manifest, "", "  ")
	if e != nil {
		return e
	}
	return AtomicWrite(filepath.Join(c.Dir, "manifest.json"), b)
}
func AtomicWrite(path string, b []byte) error {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".deckreel-*")
	if e != nil {
		return e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	return os.Rename(tmp, path)
}
func Publish(source, dest string, overwrite bool) error {
	in, e := os.Open(source)
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.CreateTemp(filepath.Dir(dest), ".deckreel-output-*.mp4")
	if e != nil {
		return e
	}
	tmp := out.Name()
	defer os.Remove(tmp)
	if _, e = io.Copy(out, in); e != nil {
		out.Close()
		return e
	}
	if e = out.Sync(); e != nil {
		out.Close()
		return e
	}
	if e = out.Close(); e != nil {
		return e
	}
	if overwrite {
		return os.Rename(tmp, dest)
	}
	if e = os.Link(tmp, dest); e != nil {
		return fmt.Errorf("output already exists or cannot be published (use --overwrite only if intended): %w", e)
	}
	return nil
}
