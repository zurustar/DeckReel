package deckreel

import (
	"archive/zip"
	"encoding/xml"
	"fmt"
	"io"
	"path"
	"strconv"
	"strings"
)

type Slide struct {
	ID       string
	Position int
	Hidden   bool
	Notes    string
}
type Deck struct{ Slides []Slide }
type relationship struct {
	ID     string `xml:"Id,attr"`
	Type   string `xml:"Type,attr"`
	Target string `xml:"Target,attr"`
	Mode   string `xml:"TargetMode,attr"`
}
type packageReader struct{ files map[string]*zip.File }

func ReadDeck(filename string) (Deck, error) {
	z, err := zip.OpenReader(filename)
	if err != nil {
		return Deck{}, err
	}
	defer z.Close()
	p := packageReader{map[string]*zip.File{}}
	if len(z.File) > 20000 {
		return Deck{}, fmt.Errorf("PPTX has too many entries")
	}
	var total uint64
	for _, f := range z.File {
		total += f.UncompressedSize64
		if total > 1<<30 || f.UncompressedSize64 > 64<<20 {
			return Deck{}, fmt.Errorf("PPTX exceeds expanded size limit")
		}
		if _, ok := p.files[f.Name]; ok {
			return Deck{}, fmt.Errorf("duplicate ZIP entry")
		}
		p.files[f.Name] = f
	}
	b, err := p.read("ppt/presentation.xml")
	if err != nil {
		return Deck{}, err
	}
	var pres struct {
		IDs []struct {
			ID  string `xml:"id,attr"`
			RID string
		}
	}
	// Attribute namespaces matter: both p:sldId/@id and r:id have local name id.
	dec := xml.NewDecoder(strings.NewReader(string(b)))
	for {
		t, e := dec.Token()
		if e == io.EOF {
			break
		}
		if e != nil {
			return Deck{}, e
		}
		s, ok := t.(xml.StartElement)
		if !ok || s.Name.Local != "sldId" {
			continue
		}
		var id, rid string
		for _, a := range s.Attr {
			if a.Name.Local == "id" {
				if a.Name.Space == "" {
					id = a.Value
				} else if strings.HasSuffix(a.Name.Space, "/relationships") {
					rid = a.Value
				}
			}
		}
		if _, e := strconv.ParseUint(id, 10, 32); e != nil || rid == "" {
			return Deck{}, fmt.Errorf("invalid slide ID")
		}
		pres.IDs = append(pres.IDs, struct {
			ID  string `xml:"id,attr"`
			RID string
		}{id, rid})
	}
	rels, err := p.rels("ppt/presentation.xml")
	if err != nil {
		return Deck{}, err
	}
	deck := Deck{}
	seen := map[string]bool{}
	for i, id := range pres.IDs {
		if seen[id.ID] {
			return Deck{}, fmt.Errorf("duplicate slide ID")
		}
		seen[id.ID] = true
		r, ok := rels[id.RID]
		if !ok || !strings.HasSuffix(r.Type, "/slide") {
			return Deck{}, fmt.Errorf("missing slide relationship")
		}
		file, err := resolvePart("ppt/presentation.xml", r)
		if err != nil {
			return Deck{}, err
		}
		b, err := p.read(file)
		if err != nil {
			return Deck{}, err
		}
		var s struct {
			Show string `xml:"show,attr"`
		}
		if err := xml.Unmarshal(b, &s); err != nil {
			return Deck{}, err
		}
		slide := Slide{ID: id.ID, Position: i + 1, Hidden: s.Show == "0" || s.Show == "false"}
		rs, err := p.rels(file)
		if err != nil {
			return Deck{}, err
		}
		count := 0
		for _, r := range rs {
			if !strings.HasSuffix(r.Type, "/notesSlide") {
				continue
			}
			count++
			if count > 1 {
				return Deck{}, fmt.Errorf("multiple notes for slide %d", i+1)
			}
			n, err := resolvePart(file, r)
			if err != nil {
				return Deck{}, err
			}
			b, err := p.read(n)
			if err != nil {
				return Deck{}, err
			}
			slide.Notes, err = extractNotes(b)
			if err != nil {
				return Deck{}, err
			}
		}
		deck.Slides = append(deck.Slides, slide)
	}
	return deck, nil
}
func (p packageReader) read(name string) ([]byte, error) {
	f := p.files[name]
	if f == nil {
		return nil, fmt.Errorf("missing PPTX part %s", name)
	}
	r, e := f.Open()
	if e != nil {
		return nil, e
	}
	defer r.Close()
	return io.ReadAll(io.LimitReader(r, 64<<20))
}
func (p packageReader) rels(part string) (map[string]relationship, error) {
	file := path.Join(path.Dir(part), "_rels", path.Base(part)+".rels")
	rs := map[string]relationship{}
	if p.files[file] == nil {
		return rs, nil
	}
	b, e := p.read(file)
	if e != nil {
		return nil, e
	}
	var doc struct {
		R []relationship `xml:"Relationship"`
	}
	if e = xml.Unmarshal(b, &doc); e != nil {
		return nil, e
	}
	for _, r := range doc.R {
		if _, ok := rs[r.ID]; ok {
			return nil, fmt.Errorf("duplicate relationship")
		}
		rs[r.ID] = r
	}
	return rs, nil
}
func resolvePart(source string, r relationship) (string, error) {
	if r.Mode == "External" || strings.ContainsAny(r.Target, "\\?#:") {
		return "", fmt.Errorf("unsupported external or malformed relationship")
	}
	target := r.Target
	if !strings.HasPrefix(target, "/") {
		target = path.Join(path.Dir(source), target)
	}
	target = path.Clean(strings.TrimPrefix(target, "/"))
	if target == ".." || strings.HasPrefix(target, "../") {
		return "", fmt.Errorf("relationship escapes package")
	}
	return target, nil
}
func extractNotes(b []byte) (string, error) {
	var notes struct {
		Shapes []struct {
			Placeholder struct {
				Type string `xml:"type,attr"`
			} `xml:"nvSpPr>nvPr>ph"`
			Body struct {
				Paragraphs []struct {
					Inner string `xml:",innerxml"`
				} `xml:"p"`
			} `xml:"txBody"`
		} `xml:"cSld>spTree>sp"`
	}
	if err := xml.Unmarshal(b, &notes); err != nil {
		return "", err
	}
	var paragraphs []string
	for _, s := range notes.Shapes {
		if s.Placeholder.Type != "body" {
			continue
		}
		for _, p := range s.Body.Paragraphs {
			d := xml.NewDecoder(strings.NewReader("<root>" + p.Inner + "</root>"))
			var out strings.Builder
			for {
				t, e := d.Token()
				if e == io.EOF {
					break
				}
				if e != nil {
					return "", e
				}
				if st, ok := t.(xml.StartElement); ok {
					switch st.Name.Local {
					case "t":
						var text string
						if e := d.DecodeElement(&text, &st); e != nil {
							return "", e
						}
						out.WriteString(text)
					case "br":
						out.WriteByte('\n')
					}
				}
			}
			paragraphs = append(paragraphs, out.String())
		}
	}
	return strings.TrimSpace(strings.Join(paragraphs, "\n")), nil
}
