package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"github.com/zurustar/DeckReel/internal/deckreel"
	"github.com/zurustar/DeckReel/internal/native"
	"io"
	"os"
	"os/signal"
	"time"
)

func run(ctx context.Context, args []string, out, errout io.Writer) int {
	cfg := deckreel.Config{}
	f := flag.NewFlagSet("deckreel", flag.ContinueOnError)
	f.SetOutput(errout)
	f.StringVar(&cfg.Output, "output", "", "output MP4 path")
	f.StringVar(&cfg.WorkDir, "work-dir", "", "cache directory")
	f.StringVar(&cfg.Dictionary, "dictionary", "", "reading substitutions JSON")
	f.StringVar(&cfg.VoicevoxURL, "voicevox-url", "http://127.0.0.1:50021", "local VOICEVOX Engine URL")
	f.IntVar(&cfg.Speaker, "speaker", -1, "VOICEVOX talk style ID (required for narration)")
	f.Float64Var(&cfg.Speed, "speed", 1, "VOICEVOX speed multiplier (0.5..2)")
	f.Float64Var(&cfg.Silence, "silence-seconds", 3, "empty-note duration")
	f.Float64Var(&cfg.Tail, "tail-seconds", 0.5, "post-narration pause")
	f.StringVar(&cfg.EmptyNotes, "empty-notes", "silence", "silence or skip")
	f.BoolVar(&cfg.Overwrite, "overwrite", false, "replace existing output after successful processing")
	f.StringVar(&cfg.ModelRevision, "model-revision", "", "manual model revision for cache invalidation")
	f.StringVar(&cfg.RenderRevision, "render-revision", "", "manual render revision to invalidate image cache")
	list := f.Bool("list-speakers", false, "list VOICEVOX talk styles and exit")
	version := f.Bool("version", false, "show version")
	f.Usage = func() {
		fmt.Fprint(errout, "DeckReel — PowerPoint notes to narrated MP4\n\nUsage: deckreel presentation.pptx --speaker ID [options]\n       deckreel --list-speakers\n")
		f.PrintDefaults()
	}
	// Accept the documented INPUT-first command while preserving standard flag parsing.
	if len(args) > 0 && len(args[0]) > 0 && args[0][0] != '-' {
		input := args[0]
		args = append(append([]string{}, args[1:]...), input)
	}
	if e := f.Parse(args); e != nil {
		if errors.Is(e, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if *version {
		fmt.Fprintln(out, "DeckReel 0.1.0-dev")
		return 0
	}
	if *list {
		v, e := deckreel.NewVoicevox(cfg.VoicevoxURL)
		if e != nil {
			fmt.Fprintln(errout, e)
			return 2
		}
		ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		s, e := v.Speakers(ctx)
		if e != nil {
			fmt.Fprintln(errout, e)
			return 1
		}
		for _, speaker := range s {
			for _, style := range speaker.Styles {
				if style.Type == "" || style.Type == "talk" {
					fmt.Fprintf(out, "%d\t%s / %s\n", style.ID, speaker.Name, style.Name)
				}
			}
		}
		return 0
	}
	if f.NArg() != 1 {
		f.Usage()
		return 2
	}
	cfg.Input = f.Arg(0)
	if e := cfg.Validate(); e != nil {
		fmt.Fprintln(errout, e)
		return 2
	}
	helper, e := native.Resolve()
	if e != nil {
		fmt.Fprintln(errout, e)
		return 1
	}
	p := deckreel.Pipeline{Media: helper, Renderer: deckreel.PowerPoint{}, Log: errout}
	if e = p.Run(ctx, cfg); e != nil {
		fmt.Fprintln(errout, e)
		if errors.Is(e, context.Canceled) {
			return 130
		}
		return 1
	}
	fmt.Fprintln(out, cfg.Output)
	return 0
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	os.Exit(run(ctx, os.Args[1:], os.Stdout, os.Stderr))
}
