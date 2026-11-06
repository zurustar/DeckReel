package deckreel

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"
)

type Style struct {
	Name string `json:"name"`
	ID   int    `json:"id"`
	Type string `json:"type"`
}
type Speaker struct {
	Name    string  `json:"name"`
	UUID    string  `json:"speaker_uuid"`
	Version string  `json:"version"`
	Styles  []Style `json:"styles"`
}
type VoiceInfo struct {
	EngineVersion string  `json:"engine_version"`
	Speaker       Speaker `json:"speaker"`
	Style         Style   `json:"style"`
	Fingerprint   string  `json:"fingerprint"`
	Credit        string  `json:"credit_candidate"`
}
type Voicevox struct {
	base   *url.URL
	client *http.Client
}

func NewVoicevox(address string) (*Voicevox, error) {
	u, e := url.Parse(address)
	if e != nil || u.Scheme != "http" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Path != "" && u.Path != "/" {
		return nil, fmt.Errorf("VOICEVOX URL must be http://127.0.0.1:PORT or http://[::1]:PORT")
	}
	switch u.Hostname() {
	case "localhost":
		port := u.Port()
		u.Host = "127.0.0.1"
		if port != "" {
			u.Host += ":" + port
		}
	case "127.0.0.1", "::1":
	default:
		return nil, fmt.Errorf("VOICEVOX must be a loopback address")
	}
	u.Path = ""
	if strings.Contains(u.Host, " ") {
		return nil, fmt.Errorf("invalid VOICEVOX URL")
	}
	return &Voicevox{u, &http.Client{Timeout: 5 * time.Minute, Transport: &http.Transport{Proxy: nil}, CheckRedirect: func(*http.Request, []*http.Request) error { return fmt.Errorf("VOICEVOX redirect refused") }}}, nil
}
func (v *Voicevox) request(ctx context.Context, method, endpoint string, query url.Values, body []byte) ([]byte, error) {
	u := *v.base
	u.Path = endpoint
	u.RawQuery = query.Encode()
	req, e := http.NewRequestWithContext(ctx, method, u.String(), bytes.NewReader(body))
	if e != nil {
		return nil, fmt.Errorf("invalid VOICEVOX request")
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, e := v.client.Do(req)
	if e != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("VOICEVOX %s unavailable (check Engine is running)", endpoint)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("VOICEVOX %s returned HTTP %d", endpoint, res.StatusCode)
	}
	b, e := io.ReadAll(io.LimitReader(res.Body, 128<<20+1))
	if e != nil {
		return nil, fmt.Errorf("VOICEVOX response interrupted")
	}
	if len(b) > 128<<20 {
		return nil, fmt.Errorf("VOICEVOX response too large")
	}
	return b, nil
}

// IsTalkStyle reports whether a style type can be used for text-to-speech via
// /audio_query and /synthesis. Engine 0.26+ reports talk styles as "streaming_talk".
func IsTalkStyle(t string) bool {
	return t == "" || t == "talk" || t == "streaming_talk"
}

func (v *Voicevox) Speakers(ctx context.Context) ([]Speaker, error) {
	b, e := v.request(ctx, "GET", "/speakers", nil, nil)
	if e != nil {
		return nil, e
	}
	var s []Speaker
	e = json.Unmarshal(b, &s)
	return s, e
}
func (v *Voicevox) Info(ctx context.Context, id int, revision string) (VoiceInfo, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	version, e := v.request(ctx, "GET", "/version", nil, nil)
	if e != nil {
		return VoiceInfo{}, e
	}
	var ver string
	if e = json.Unmarshal(version, &ver); e != nil || ver == "" {
		return VoiceInfo{}, fmt.Errorf("unsupported Engine version response")
	}
	speakers, e := v.Speakers(ctx)
	if e != nil {
		return VoiceInfo{}, e
	}
	var info VoiceInfo
	found := false
	for _, s := range speakers {
		for _, style := range s.Styles {
			if style.ID == id && IsTalkStyle(style.Type) {
				info = VoiceInfo{EngineVersion: ver, Speaker: s, Style: style, Credit: "VOICEVOX:" + s.Name}
				found = true
			}
		}
	}
	if !found {
		return VoiceInfo{}, fmt.Errorf("VOICEVOX talk style %d not found; use --list-speakers", id)
	}
	parts := []any{ver, speakers, revision}
	for _, endpoint := range []string{"/core_versions", "/engine_manifest", "/user_dict"} {
		b, e := v.request(ctx, "GET", endpoint, nil, nil)
		if e != nil {
			return VoiceInfo{}, e
		}
		var value any
		if e = json.Unmarshal(b, &value); e != nil {
			return VoiceInfo{}, fmt.Errorf("invalid Engine metadata at %s", endpoint)
		}
		parts = append(parts, value)
	}
	info.Fingerprint = Key(parts)
	return info, nil
}
func (v *Voicevox) Query(ctx context.Context, text string, id int, speed float64) ([]byte, error) {
	if utf8.RuneCountInString(text) > 10000 {
		return nil, fmt.Errorf("slide script exceeds 10000 characters; split the slide")
	}
	b, e := v.request(ctx, "POST", "/audio_query", url.Values{"text": {text}, "speaker": {strconv.Itoa(id)}}, nil)
	if e != nil {
		return nil, e
	}
	var q map[string]any
	if e = json.Unmarshal(b, &q); e != nil || q == nil {
		return nil, fmt.Errorf("invalid AudioQuery")
	}
	if _, ok := q["accent_phrases"]; !ok {
		return nil, fmt.Errorf("AudioQuery missing accent_phrases")
	}
	q["speedScale"] = speed
	q["outputSamplingRate"] = SampleRate
	q["outputStereo"] = false
	return json.Marshal(q)
}
func (v *Voicevox) Synthesize(ctx context.Context, query []byte, id int) ([]byte, error) {
	b, e := v.request(ctx, "POST", "/synthesis", url.Values{"speaker": {strconv.Itoa(id)}, "enable_interrogative_upspeak": {"true"}}, query)
	if e != nil {
		return nil, e
	}
	if _, e = PCM(b); e != nil {
		return nil, e
	}
	return b, nil
}
