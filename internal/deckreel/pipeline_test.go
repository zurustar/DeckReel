package deckreel

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fixtureSlide struct {
	id, file, notes string
	hidden          bool
}

func fixture(t *testing.T, path string, slides []fixtureSlide) {
	t.Helper()
	fixtureWithExt(t, path, slides, "")
}
func fixtureWithExt(t *testing.T, path string, slides []fixtureSlide, ext string) {
	t.Helper()
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	put := func(n, s string) {
		w, e := z.Create(n)
		if e != nil {
			t.Fatal(e)
		}
		if _, e = w.Write([]byte(s)); e != nil {
			t.Fatal(e)
		}
	}
	var ids, rels strings.Builder
	for i, s := range slides {
		fmt.Fprintf(&ids, `<p:sldId id="%s" r:id="r%d"/>`, s.id, i)
		fmt.Fprintf(&rels, `<Relationship Id="r%d" Type="x/slide" Target="slides/%s.xml"/>`, i, s.file)
		show := "1"
		if s.hidden {
			show = "0"
		}
		put("ppt/slides/"+s.file+".xml", `<p:sld xmlns:p="p" show="`+show+`"/>`)
		put("ppt/slides/_rels/"+s.file+".xml.rels", `<Relationships><Relationship Id="n" Type="x/notesSlide" Target="../notesSlides/`+s.file+`.xml"/></Relationships>`)
		put("ppt/notesSlides/"+s.file+".xml", `<p:notes xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="sldNum"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>NOT SCRIPT</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type="body"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>`+s.notes+`</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>`)
	}
	put("ppt/presentation.xml", `<p:presentation xmlns:p="p" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst>`+ids.String()+`</p:sldIdLst>`+ext+`</p:presentation>`)
	put("ppt/_rels/presentation.xml.rels", `<Relationships>`+rels.String()+`</Relationships>`)
	if e := z.Close(); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(path, b.Bytes(), 0600); e != nil {
		t.Fatal(e)
	}
}
func TestPPTXOrderNotesHidden(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.pptx")
	fixture(t, p, []fixtureSlide{{"300", "slide9", "First", false}, {"256", "slide1", "Second", true}})
	d, e := ReadDeck(p)
	if e != nil {
		t.Fatal(e)
	}
	if len(d.Slides) != 2 || d.Slides[0].ID != "300" || d.Slides[0].Notes != "First" || !d.Slides[1].Hidden {
		t.Fatalf("%+v", d)
	}
}
func TestPPTXSectionsIgnored(t *testing.T) {
	p := filepath.Join(t.TempDir(), "a.pptx")
	sections := `<p:extLst><p:ext uri="{521415D9-36F7-43E2-AB2F-B90AF26B5E84}"><p14:sectionLst xmlns:p14="http://schemas.microsoft.com/office/powerpoint/2010/main"><p14:section name="A" id="{1}"><p14:sldIdLst><p14:sldId id="300"/></p14:sldIdLst></p14:section><p14:section name="B" id="{2}"><p14:sldIdLst><p14:sldId id="256"/></p14:sldIdLst></p14:section></p14:sectionLst></p:ext></p:extLst>`
	fixtureWithExt(t, p, []fixtureSlide{{"300", "slide9", "First", false}, {"256", "slide1", "Second", false}}, sections)
	d, e := ReadDeck(p)
	if e != nil {
		t.Fatal(e)
	}
	if len(d.Slides) != 2 || d.Slides[0].ID != "300" || d.Slides[1].ID != "256" {
		t.Fatalf("%+v", d)
	}
}
func TestRelationshipEscape(t *testing.T) {
	for _, target := range []string{"../../../outside", "https://example.org/x", "x?query", "..\\outside"} {
		if _, e := resolvePart("ppt/slides/a.xml", relationship{Target: target}); e == nil {
			t.Fatalf("accepted %s", target)
		}
	}
}
func TestNotesParagraphs(t *testing.T) {
	n, e := extractNotes([]byte(`<notes><cSld><spTree><sp><nvSpPr><nvPr><ph type="body"/></nvPr></nvSpPr><txBody><p><r><t>A&amp;B</t></r><br/><r><t>C</t></r></p><p><r><t>D</t></r></p></txBody></sp></spTree></cSld></notes>`))
	if e != nil || n != "A&B\nC\nD" {
		t.Fatalf("%q %v", n, e)
	}
}
func TestReadingAndWAV(t *testing.T) {
	if got := Script(" API\r\n X ", []Reading{{"API", "A"}, {"A", "B"}}); got != "B\nX" {
		t.Fatal(got)
	}
	pcm := make([]byte, 3202)
	wav := WAV(pcm)
	p, e := PCM(wav)
	if e != nil || len(p) != len(pcm) {
		t.Fatal(e)
	}
	if Frames(len(p)/2, 0) != 2 {
		t.Fatal("truncates audio")
	}
	if _, e = PCM(wav[:len(wav)-1]); e == nil {
		t.Fatal("accepted truncated WAV")
	}
	if _, e = PCM([]byte("not a wav")); e == nil {
		t.Fatal("accepted invalid WAV")
	}
}

type fakeRenderer struct{ exports int }

func (f *fakeRenderer) Version(context.Context) (string, error) { return "test-powerpoint", nil }
func (f *fakeRenderer) Export(_ context.Context, in, out string) error {
	f.exports++
	d, e := ReadDeck(in)
	if e != nil {
		return e
	}
	b, _ := json.Marshal(d)
	return os.WriteFile(out, b, 0600)
}

type fakeMedia struct {
	clips, joins int
	fail         bool
}

func (f *fakeMedia) Info(context.Context) (string, error) { return "test-native", nil }
func (f *fakeMedia) Render(_ context.Context, pdf, dir string) (int, error) {
	b, e := os.ReadFile(pdf)
	if e != nil {
		return 0, e
	}
	var d Deck
	if e = json.Unmarshal(b, &d); e != nil {
		return 0, e
	}
	if e = os.MkdirAll(dir, 0700); e != nil {
		return 0, e
	}
	for i, s := range d.Slides {
		if e = os.WriteFile(filepath.Join(dir, fmt.Sprintf("%04d.png", i+1)), []byte("fixed pixels "+s.ID), 0600); e != nil {
			return 0, e
		}
	}
	return len(d.Slides), nil
}
func (f *fakeMedia) Clip(_ context.Context, image, audio, out string, frames int) error {
	f.clips++
	if f.fail {
		f.fail = false
		return fmt.Errorf("injected clip failure")
	}
	return writeMovie(out, float64(frames)/30)
}
func (f *fakeMedia) Join(_ context.Context, list, out string) error {
	f.joins++
	b, e := os.ReadFile(list)
	if e != nil {
		return e
	}
	var paths []string
	if e = json.Unmarshal(b, &paths); e != nil {
		return e
	}
	var sum float64
	for _, p := range paths {
		b, e = os.ReadFile(p)
		if e != nil {
			return e
		}
		var v map[string]float64
		if e = json.Unmarshal(b, &v); e != nil {
			return e
		}
		sum += v["duration"]
	}
	return writeMovie(out, sum)
}
func (f *fakeMedia) Inspect(_ context.Context, p string) ([]byte, error) { return os.ReadFile(p) }
func writeMovie(path string, seconds float64) error {
	b, _ := json.Marshal(map[string]float64{"duration": seconds, "audio_duration": seconds, "video_duration": seconds})
	return os.WriteFile(path, b, 0600)
}

type fakeVoice struct {
	syntheses, queries int
	dict               string
	invalid            bool
}

func (v *fakeVoice) server(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/version":
			fmt.Fprint(w, `"0.test"`)
		case "/speakers":
			fmt.Fprint(w, `[{"name":"Test","speaker_uuid":"uuid","version":"1","styles":[{"name":"Normal","id":3,"type":"streaming_talk"}]}]`)
		case "/core_versions":
			fmt.Fprint(w, `["test"]`)
		case "/engine_manifest":
			fmt.Fprint(w, `{"uuid":"engine"}`)
		case "/user_dict":
			fmt.Fprintf(w, `{"revision":%q}`, v.dict)
		case "/audio_query":
			v.queries++
			json.NewEncoder(w).Encode(map[string]any{"accent_phrases": []any{}, "speedScale": 1, "test_text": r.URL.Query().Get("text")})
		case "/synthesis":
			v.syntheses++
			var q map[string]any
			if e := json.NewDecoder(r.Body).Decode(&q); e != nil {
				t.Error(e)
			}
			if !v.invalid && (q["outputSamplingRate"] != float64(SampleRate) || q["outputStereo"] != false) {
				t.Error("missing explicit WAV format")
			}
			if v.invalid {
				fmt.Fprint(w, "broken")
				return
			}
			w.Header().Set("Content-Type", "audio/wav")
			pcm := make([]byte, SampleRate/10*2)
			text, _ := q["test_text"].(string)
			hash := Hash([]byte(text + v.dict))
			copy(pcm, []byte(hash))
			w.Write(WAV(pcm))
		default:
			http.NotFound(w, r)
		}
	}))
}
func TestPipelineIncrementalAndResume(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "deck.pptx")
	slides := []fixtureSlide{{"300", "slide9", "Hello", false}, {"301", "slide1", "World", false}, {"302", "slide3", "", false}, {"303", "slide4", "hidden", true}}
	fixture(t, input, slides)
	v := &fakeVoice{}
	srv := v.server(t)
	defer srv.Close()
	m := &fakeMedia{}
	r := &fakeRenderer{}
	p := Pipeline{Media: m, Renderer: r}
	cfg := Config{Input: input, Output: filepath.Join(root, "out.mp4"), WorkDir: filepath.Join(root, "work"), VoicevoxURL: srv.URL, Speaker: 3, Speed: 1, Silence: 0.1, Tail: 0.05, EmptyNotes: "silence", Overwrite: true}
	run := func() {
		t.Helper()
		if e := p.Run(context.Background(), cfg); e != nil {
			t.Fatal(e)
		}
	}
	run()
	if v.syntheses != 2 || m.clips != 3 || m.joins != 1 {
		t.Fatalf("initial %d/%d/%d", v.syntheses, m.clips, m.joins)
	}
	run()
	if v.syntheses != 2 || m.clips != 3 || m.joins != 1 || r.exports != 1 {
		t.Fatal("cache miss")
	}
	slides[0].notes = "Changed"
	fixture(t, input, slides)
	run()
	if v.syntheses != 3 || m.clips != 4 || r.exports != 2 {
		t.Fatalf("incremental %d/%d", v.syntheses, m.clips)
	}
	cfg.Tail = 0.1
	run()
	if v.syntheses != 3 || m.clips != 6 {
		t.Fatalf("tail invalidation %d/%d", v.syntheses, m.clips)
	}
	// A dictionary change at the Engine must invalidate spoken audio, but not silent slides.
	v.dict = "updated"
	run()
	if v.syntheses != 5 {
		t.Fatal("Engine dictionary did not invalidate audio")
	}
	slides[1].notes = "Interrupted"
	fixture(t, input, slides)
	m.fail = true
	if e := p.Run(context.Background(), cfg); e == nil {
		t.Fatal("injected failure ignored")
	}
	n := v.syntheses
	run()
	if v.syntheses != n {
		t.Fatal("resume synthesized successful audio again")
	}
	// Tampering must be detected despite the manifest still saying succeeded.
	if e := os.WriteFile(filepath.Join(root, "work/slides/300/audio.wav"), []byte("broken"), 0600); e != nil {
		t.Fatal(e)
	}
	run()
	if v.syntheses != n+1 {
		t.Fatal("corruption reused")
	}
	cfg.EmptyNotes = "skip"
	run()
	b, _ := os.ReadFile(filepath.Join(root, "work/manifest.json"))
	var manifest Manifest
	json.Unmarshal(b, &manifest)
	if len(manifest.Order) != 2 {
		t.Fatal("skip/hidden included")
	}
}
func TestVoicevoxPrivacyAndFailures(t *testing.T) {
	for _, address := range []string{"https://127.0.0.1:50021", "http://example.org:50021", "http://127.0.0.1:50021?token=x", "http://127.0.0.1.evil/", "http://user:pass@127.0.0.1"} {
		if _, e := NewVoicevox(address); e == nil {
			t.Fatalf("accepted %s", address)
		}
	}
	v := &fakeVoice{invalid: true}
	s := v.server(t)
	defer s.Close()
	client, e := NewVoicevox(s.URL)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = client.Info(context.Background(), 99, ""); e == nil {
		t.Fatal("missing style accepted")
	}
	if _, e = client.Synthesize(context.Background(), []byte(`{}`), 3); e == nil {
		t.Fatal("invalid WAV accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e = client.Speakers(ctx); e == nil {
		t.Fatal("cancel ignored")
	}
	// Error text must not reveal the script carried in the URL query.
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "secret script", 500) }))
	defer bad.Close()
	client, _ = NewVoicevox(bad.URL)
	_, e = client.Query(context.Background(), "secret script", 3, 1)
	if e == nil || strings.Contains(e.Error(), "secret") {
		t.Fatal(e)
	}
}
func TestCacheLockPublish(t *testing.T) {
	root := t.TempDir()
	c, e := OpenCache(filepath.Join(root, "work"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	if c2, e := OpenCache(c.Dir); e == nil {
		c2.Close()
		t.Fatal("concurrent lock accepted")
	}
	if _, e = c.path("../escape"); e == nil {
		t.Fatal("escape accepted")
	}
	outside := filepath.Join(root, "outside")
	os.WriteFile(outside, []byte("old"), 0600)
	if e = os.Symlink(root, filepath.Join(c.Dir, "link")); e != nil {
		t.Fatal(e)
	}
	if _, e = c.path("link/outside"); e == nil {
		t.Fatal("symlink accepted")
	}
	source := filepath.Join(root, "source")
	os.WriteFile(source, []byte("new"), 0600)
	if e = Publish(source, outside, false); e == nil {
		t.Fatal("overwrote existing file")
	}
	b, _ := os.ReadFile(outside)
	if string(b) != "old" {
		t.Fatal("lost original")
	}
	if e = Publish(source, outside, true); e != nil {
		t.Fatal(e)
	}
	b, _ = os.ReadFile(outside)
	if string(b) != "new" {
		t.Fatal("overwrite failed")
	}
}
