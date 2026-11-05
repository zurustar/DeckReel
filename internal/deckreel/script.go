package deckreel

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type Reading struct {
	From string `json:"from"`
	To   string `json:"to"`
}

func ReadDictionary(path string) ([]Reading, error) {
	if path == "" {
		return nil, nil
	}
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	var r []Reading
	if e = json.Unmarshal(b, &r); e != nil {
		return nil, e
	}
	for _, x := range r {
		if x.From == "" {
			return nil, fmt.Errorf("dictionary contains empty from")
		}
	}
	return r, nil
}
func Script(raw string, dict []Reading) string {
	s := strings.ReplaceAll(raw, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\r", "\n")
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		lines[i] = strings.Join(strings.Fields(l), " ")
	}
	s = strings.TrimSpace(strings.Join(lines, "\n"))
	for _, r := range dict {
		s = strings.ReplaceAll(s, r.From, r.To)
	}
	return strings.TrimSpace(s)
}
