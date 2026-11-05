//go:build darwin

package native

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"github.com/zurustar/DeckReel/internal/deckreel"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func testPDF() []byte {
	var b bytes.Buffer
	b.WriteString("%PDF-1.4\n")
	objects := []string{"<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 640 480] /Contents 4 0 R /Resources << >> >>", "<< /Length 26 >>\nstream\n1 0 0 rg 0 0 640 480 re f\nendstream"}
	offsets := []int{0}
	for i, s := range objects {
		offsets = append(offsets, b.Len())
		fmt.Fprintf(&b, "%d 0 obj\n%s\nendobj\n", i+1, s)
	}
	start := b.Len()
	fmt.Fprintf(&b, "xref\n0 %d\n0000000000 65535 f \n", len(offsets))
	for _, n := range offsets[1:] {
		fmt.Fprintf(&b, "%010d 00000 n \n", n)
	}
	fmt.Fprintf(&b, "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n", len(offsets), start)
	return b.Bytes()
}
func TestNativeMedia(t *testing.T) {
	h, e := Resolve()
	if e != nil {
		t.Fatal(e)
	}
	ctx := context.Background()
	dir := t.TempDir()
	pdf := filepath.Join(dir, "slide.pdf")
	if e = os.WriteFile(pdf, testPDF(), 0600); e != nil {
		t.Fatal(e)
	}
	if n, e := h.Render(ctx, pdf, dir); e != nil || n != 1 {
		t.Fatalf("render: %d %v", n, e)
	}
	pngFile, e := os.Open(filepath.Join(dir, "0001.png"))
	if e != nil {
		t.Fatal(e)
	}
	picture, e := png.Decode(pngFile)
	pngFile.Close()
	if e != nil {
		t.Fatal(e)
	}
	if picture.Bounds().Dx() != 1920 || picture.Bounds().Dy() != 1080 {
		t.Fatal("wrong resolution")
	}
	red, green, blue, _ := picture.At(960, 540).RGBA()
	if red < 60000 || green > 1000 || blue > 1000 {
		t.Fatal("slide pixels changed")
	}
	red, green, blue, _ = picture.At(0, 540).RGBA()
	if red != 0 || green != 0 || blue != 0 {
		t.Fatal("4:3 letterbox missing")
	}
	pcm := make([]byte, 1600*2*4)
	for i := 0; i < len(pcm)/2; i++ {
		sample := int16(3000 * math.Sin(2*math.Pi*440*float64(i)/48000))
		binary.LittleEndian.PutUint16(pcm[2*i:], uint16(sample))
	}
	wav := filepath.Join(dir, "audio.wav")
	os.WriteFile(wav, deckreel.WAV(pcm), 0600)
	clip := filepath.Join(dir, "clip.mp4")
	if e = h.Clip(ctx, filepath.Join(dir, "0001.png"), wav, clip, 4); e != nil {
		t.Fatal(e)
	}
	// Many short clips expose AAC priming and cumulative timestamp errors quickly.
	var paths []string
	for i := 0; i < 24; i++ {
		paths = append(paths, clip)
	}
	b, _ := json.Marshal(paths)
	list := filepath.Join(dir, "clips.json")
	os.WriteFile(list, b, 0600)
	out := filepath.Join(dir, "out.mp4")
	if e = h.Join(ctx, list, out); e != nil {
		t.Fatal(e)
	}
	b, e = h.Inspect(ctx, out)
	if e != nil {
		t.Fatal(e)
	}
	var info struct {
		Duration float64 `json:"duration"`
		Video    float64 `json:"video_duration"`
		Audio    float64 `json:"audio_duration"`
	}
	if e = json.Unmarshal(b, &info); e != nil {
		t.Fatal(e)
	}
	want := 24 * 4.0 / 30
	for _, d := range []float64{info.Duration, info.Video, info.Audio} {
		if math.Abs(d-want) > 1.0/30+0.001 {
			t.Fatalf("duration %f vs %f", d, want)
		}
	}
}
