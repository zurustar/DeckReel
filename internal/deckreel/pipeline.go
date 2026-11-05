package deckreel

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
)

type Media interface {
	Info(context.Context) (string, error)
	Render(context.Context, string, string) (int, error)
	Clip(context.Context, string, string, string, int) error
	Join(context.Context, string, string) error
	Inspect(context.Context, string) ([]byte, error)
}
type Renderer interface {
	Version(context.Context) (string, error)
	Export(context.Context, string, string) error
}
type Config struct {
	Input, Output, WorkDir, Dictionary, VoicevoxURL, ModelRevision string
	Speaker                                                        int
	Speed, Silence, Tail                                           float64
	EmptyNotes                                                     string
	Overwrite                                                      bool
	RenderRevision                                                 string
}
type Pipeline struct {
	Media    Media
	Renderer Renderer
	Log      io.Writer
}

func (c *Config) Validate() error {
	if c.Input == "" || !strings.EqualFold(filepath.Ext(c.Input), ".pptx") {
		return fmt.Errorf("specify one .pptx input")
	}
	var e error
	c.Input, e = filepath.Abs(c.Input)
	if e != nil {
		return e
	}
	st, e := os.Stat(c.Input)
	if e != nil || !st.Mode().IsRegular() {
		return fmt.Errorf("input must be a readable PPTX file")
	}
	if st.Size() > 512<<20 {
		return fmt.Errorf("input exceeds 512MiB limit")
	}
	if c.Output == "" {
		c.Output = strings.TrimSuffix(c.Input, filepath.Ext(c.Input)) + ".mp4"
	}
	c.Output, e = filepath.Abs(c.Output)
	if e != nil {
		return e
	}
	if !strings.EqualFold(filepath.Ext(c.Output), ".mp4") {
		return fmt.Errorf("output must end in .mp4")
	}
	if !c.Overwrite {
		if _, e := os.Lstat(c.Output); e == nil {
			return fmt.Errorf("output exists; choose another path or use --overwrite")
		} else if !os.IsNotExist(e) {
			return e
		}
	}
	if st, e := os.Stat(c.Output); e == nil {
		input, _ := os.Stat(c.Input)
		if os.SameFile(input, st) {
			return fmt.Errorf("output must not refer to input")
		}
	}
	if c.WorkDir == "" {
		base := strings.TrimSuffix(filepath.Base(c.Input), filepath.Ext(c.Input))
		c.WorkDir = filepath.Join(filepath.Dir(c.Input), "work", base+"-"+Hash([]byte(c.Input))[:12])
	}
	c.WorkDir, e = filepath.Abs(c.WorkDir)
	if e != nil {
		return e
	}
	if c.EmptyNotes != "silence" && c.EmptyNotes != "skip" {
		return fmt.Errorf("--empty-notes must be silence or skip")
	}
	for _, x := range []float64{c.Speed, c.Silence, c.Tail} {
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return fmt.Errorf("settings must be finite")
		}
	}
	if c.Speed < 0.5 || c.Speed > 2 || c.Silence <= 0 || c.Silence > 3600 || c.Tail < 0 || c.Tail > 3600 {
		return fmt.Errorf("speed must be 0.5..2; silence 0..3600 (exclusive zero); tail 0..3600")
	}
	if _, e = NewVoicevox(c.VoicevoxURL); e != nil {
		return e
	}
	return nil
}
func (p Pipeline) log(format string, args ...any) {
	if p.Log != nil {
		fmt.Fprintf(p.Log, format+"\n", args...)
	}
}
func (p Pipeline) Run(ctx context.Context, cfg Config) (err error) {
	if err = cfg.Validate(); err != nil {
		return err
	}
	dict, err := ReadDictionary(cfg.Dictionary)
	if err != nil {
		return err
	}
	probe, err := os.CreateTemp(filepath.Dir(cfg.Output), ".deckreel-check-*")
	if err != nil {
		return fmt.Errorf("output directory is not writable: %w", err)
	}
	probe.Close()
	os.Remove(probe.Name())
	cache, err := OpenCache(cfg.WorkDir)
	if err != nil {
		return err
	}
	defer cache.Close()
	// An output inside the cache can overwrite an intermediate artifact; keep publication separate.
	if rel, e := filepath.Rel(cache.Dir, cfg.Output); e == nil && filepath.IsLocal(rel) {
		return fmt.Errorf("output must be outside the work directory")
	}
	snapshot := filepath.Join(cache.Dir, "input", "presentation.pptx")
	raw, err := os.ReadFile(cfg.Input)
	if err != nil {
		return err
	}
	sourceHash, err := FileHash(cfg.Input)
	if err != nil || sourceHash != Hash(raw) {
		return fmt.Errorf("input changed while reading; retry")
	}
	if err = AtomicWrite(snapshot, raw); err != nil {
		return err
	}
	deck, err := ReadDeck(snapshot)
	if err != nil {
		return fmt.Errorf("read PPTX: %w", err)
	}
	var slides []Slide
	var scripts []string
	needSpeech := false
	for _, s := range deck.Slides {
		if s.Hidden {
			continue
		}
		text := Script(s.Notes, dict)
		if text == "" && cfg.EmptyNotes == "skip" {
			continue
		}
		slides = append(slides, s)
		scripts = append(scripts, text)
		needSpeech = needSpeech || text != ""
	}
	if len(slides) == 0 {
		return fmt.Errorf("no slides to render after hidden/empty-note filtering")
	}
	if needSpeech && cfg.Speaker < 0 {
		return fmt.Errorf("--speaker is required; use --list-speakers to see VOICEVOX styles")
	}
	cache.Manifest.Input = Hash(raw)
	cache.Manifest.Order = nil
	for _, s := range slides {
		cache.Manifest.Order = append(cache.Manifest.Order, s.ID)
	}
	if err = cache.Save(); err != nil {
		return err
	}
	// All adapters are preflighted before PowerPoint export or synthesis.
	env, err := p.Media.Info(ctx)
	if err != nil {
		return err
	}
	version, err := p.Renderer.Version(ctx)
	if err != nil {
		return err
	}
	voice, err := NewVoicevox(cfg.VoicevoxURL)
	if err != nil {
		return err
	}
	var info VoiceInfo
	if needSpeech {
		if cfg.Speaker < 0 {
			return fmt.Errorf("--speaker is required; use --list-speakers to see VOICEVOX styles")
		}
		info, err = voice.Info(ctx, cfg.Speaker, cfg.ModelRevision)
		if err != nil {
			return err
		}
	}
	identity, _ := json.MarshalIndent(struct {
		Voice         VoiceInfo `json:"voice"`
		Speed         float64   `json:"speed"`
		ModelRevision string    `json:"model_revision,omitempty"`
	}{info, cfg.Speed, cfg.ModelRevision}, "", "  ")
	if err = AtomicWrite(filepath.Join(cache.Dir, "voice.json"), identity); err != nil {
		return err
	}
	p.log("Render: %d slides", len(slides))
	renderKey := Key([]any{"render-v1", Hash(raw), env, version, cfg.RenderRevision})
	renderPaths := []string{"render/presentation.pdf", "render/pages.json"}
	for _, s := range deck.Slides {
		if !s.Hidden {
			renderPaths = append(renderPaths, "render/"+s.ID+".png")
		}
	}
	if !cache.Valid("render", renderKey) {
		err = p.stage(cache, "render", renderKey, renderPaths, func() error {
			tmp, e := os.MkdirTemp(cache.Dir, "render-tmp-")
			if e != nil {
				return e
			}
			defer os.RemoveAll(tmp)
			pdf := filepath.Join(tmp, "presentation.pdf")
			if e = p.Renderer.Export(ctx, snapshot, pdf); e != nil {
				return e
			}
			pages := filepath.Join(tmp, "pages")
			count, e := p.Media.Render(ctx, pdf, pages)
			if e != nil {
				return e
			}
			visible := 0
			for _, s := range deck.Slides {
				if !s.Hidden {
					visible++
				}
			}
			if count != len(deck.Slides) && count != visible {
				return fmt.Errorf("PDF page count %d does not match %d slides / %d visible slides", count, len(deck.Slides), visible)
			}
			dest := filepath.Join(cache.Dir, "render")
			if e = os.MkdirAll(dest, 0700); e != nil {
				return e
			}
			if e = os.Rename(pdf, filepath.Join(dest, "presentation.pdf")); e != nil {
				return e
			}
			index := 0
			mapping := map[string]int{}
			for _, s := range deck.Slides {
				if s.Hidden {
					continue
				}
				index++
				page := index
				if count == len(deck.Slides) {
					page = s.Position
				}
				mapping[s.ID] = page
				if e = os.Rename(filepath.Join(pages, fmt.Sprintf("%04d.png", page)), filepath.Join(dest, s.ID+".png")); e != nil {
					return e
				}
			}
			b, _ := json.Marshal(mapping)
			return AtomicWrite(filepath.Join(dest, "pages.json"), b)
		})
		if err != nil {
			return fmt.Errorf("render slides: %w", err)
		}
	} else {
		p.log("Render: cached")
	}
	var clips []string
	var clipHashes []string
	totalFrames := 0
	for i, s := range slides {
		if e := ctx.Err(); e != nil {
			return e
		}
		p.log("Slide %d/%d (PowerPoint %d)", i+1, len(slides), s.Position)
		rel := filepath.Join("slides", s.ID)
		dir, e := cache.path(rel)
		if e != nil {
			return e
		}
		if e = os.MkdirAll(dir, 0700); e != nil {
			return e
		}
		if e = AtomicWrite(filepath.Join(dir, "source.txt"), []byte(s.Notes)); e != nil {
			return e
		}
		if e = AtomicWrite(filepath.Join(dir, "script.txt"), []byte(scripts[i])); e != nil {
			return e
		}
		audioRel := filepath.Join(rel, "audio.wav")
		queryRel := filepath.Join(rel, "audio_query.json")
		audioKey := Key([]any{"audio-v1", scripts[i], info.Fingerprint, cfg.Speaker, cfg.Speed})
		audioPaths := []string{audioRel, queryRel}
		if scripts[i] == "" {
			audioKey = Key([]any{"silence-v1", cfg.Silence})
			audioPaths = []string{audioRel}
		}
		stageName := s.ID + "/audio"
		if !cache.Valid(stageName, audioKey) {
			e = p.stage(cache, stageName, audioKey, audioPaths, func() error {
				if scripts[i] == "" {
					return AtomicWrite(filepath.Join(dir, "audio.wav"), PadPCM(nil, Frames(0, cfg.Silence)))
				}
				q, e := voice.Query(ctx, scripts[i], cfg.Speaker, cfg.Speed)
				if e != nil {
					return e
				}
				b, e := voice.Synthesize(ctx, q, cfg.Speaker)
				if e != nil {
					return e
				}
				if e = AtomicWrite(filepath.Join(dir, "audio_query.json"), q); e != nil {
					return e
				}
				return AtomicWrite(filepath.Join(dir, "audio.wav"), b)
			})
			if e != nil {
				return fmt.Errorf("slide %d audio: %w", s.Position, e)
			}
		} else {
			p.log("  audio: cached")
		}
		audio, e := os.ReadFile(filepath.Join(dir, "audio.wav"))
		if e != nil {
			return e
		}
		pcm, e := PCM(audio)
		if e != nil {
			return e
		}
		tail := cfg.Tail
		if scripts[i] == "" {
			tail = 0
		}
		frames := Frames(len(pcm)/2, tail)
		totalFrames += frames
		image := filepath.Join(cache.Dir, "render", s.ID+".png")
		imageHash, e := FileHash(image)
		if e != nil {
			return e
		}
		clipRel := filepath.Join(rel, "clip.mp4")
		clipPath := filepath.Join(cache.Dir, clipRel)
		clipKey := Key([]any{"clip-v1", imageHash, Hash(audio), frames, env})
		valid := cache.Valid(s.ID+"/clip", clipKey)
		if valid {
			valid = p.validateMovie(ctx, clipPath, float64(frames)/30) == nil
		}
		if !valid {
			e = p.stage(cache, s.ID+"/clip", clipKey, []string{clipRel}, func() error {
				tmp, e := os.MkdirTemp(dir, "clip-tmp-")
				if e != nil {
					return e
				}
				defer os.RemoveAll(tmp)
				padded := filepath.Join(tmp, "padded.wav")
				if e = AtomicWrite(padded, PadPCM(pcm, frames)); e != nil {
					return e
				}
				out := filepath.Join(tmp, "clip.mp4")
				if e = p.Media.Clip(ctx, image, padded, out, frames); e != nil {
					return e
				}
				if e = p.validateMovie(ctx, out, float64(frames)/30); e != nil {
					return e
				}
				return os.Rename(out, clipPath)
			})
			if e != nil {
				return fmt.Errorf("slide %d video: %w", s.Position, e)
			}
		} else {
			p.log("  video: cached")
		}
		clips = append(clips, clipPath)
		h, e := FileHash(clipPath)
		if e != nil {
			return e
		}
		clipHashes = append(clipHashes, h)
	}
	joinKey := Key([]any{"join-v1", clipHashes, env})
	final := filepath.Join(cache.Dir, "output.mp4")
	valid := cache.Valid("join", joinKey)
	if valid {
		valid = p.validateMovie(ctx, final, float64(totalFrames)/30) == nil
	}
	if !valid {
		p.log("Join: %d clips (passthrough)", len(clips))
		err = p.stage(cache, "join", joinKey, []string{"output.mp4"}, func() error {
			tmp, e := os.MkdirTemp(cache.Dir, "join-tmp-")
			if e != nil {
				return e
			}
			defer os.RemoveAll(tmp)
			list := filepath.Join(tmp, "clips.json")
			b, _ := json.Marshal(clips)
			if e = AtomicWrite(list, b); e != nil {
				return e
			}
			out := filepath.Join(tmp, "output.mp4")
			if e = p.Media.Join(ctx, list, out); e != nil {
				return e
			}
			if e = p.validateMovie(ctx, out, float64(totalFrames)/30); e != nil {
				return e
			}
			return os.Rename(out, final)
		})
		if err != nil {
			return fmt.Errorf("join clips: %w", err)
		}
	} else {
		p.log("Join: cached")
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if err = Publish(final, cfg.Output, cfg.Overwrite); err != nil {
		return err
	}
	p.log("Completed: %s", cfg.Output)
	return nil
}
func (p Pipeline) stage(c *Cache, name, key string, paths []string, run func() error) error {
	for _, path := range paths {
		if _, e := c.path(path); e != nil {
			return e
		}
	}
	if e := c.Start(name, key); e != nil {
		return e
	}
	if e := run(); e != nil {
		if saveErr := c.Fail(name, e); saveErr != nil {
			return fmt.Errorf("%w (manifest save also failed: %v)", e, saveErr)
		}
		return e
	}
	return c.Complete(name, key, paths...)
}
func (p Pipeline) validateMovie(ctx context.Context, path string, want float64) error {
	b, e := p.Media.Inspect(ctx, path)
	if e != nil {
		return e
	}
	var v struct {
		Duration float64 `json:"duration"`
		Video    float64 `json:"video_duration"`
		Audio    float64 `json:"audio_duration"`
	}
	if e = json.Unmarshal(b, &v); e != nil {
		return e
	}
	if math.IsNaN(v.Duration) || math.Abs(v.Duration-want) > 1.0/30+0.001 || math.Abs(v.Video-want) > 1.0/30+0.001 || math.Abs(v.Audio-want) > 1.0/30+0.001 {
		return fmt.Errorf("media duration does not match planned duration %.3fs", want)
	}
	return nil
}
