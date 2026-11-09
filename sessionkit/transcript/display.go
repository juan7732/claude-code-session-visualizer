package transcript

import "strings"

// DisplayTitle is the generated title, else the first line of the first
// prompt, else the slug, else the id.
func (s *Session) DisplayTitle() string {
	if s.Title != "" {
		return s.Title
	}
	if len(s.Prompts) > 0 {
		if line := FirstLine(s.Prompts[0].Text); line != "" {
			return line
		}
	}
	if s.Slug != "" {
		return s.Slug
	}
	return s.ID
}

// FirstLine returns the first non-empty line of text, trimmed.
func FirstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if t := strings.TrimSpace(line); t != "" {
			return t
		}
	}
	return ""
}

// StripImages replaces inline image bytes with their size, for JSON output
// that should not carry megabytes of base64. It mutates the session.
func (s *Session) StripImages() {
	for _, r := range s.Records {
		if r.Message == nil {
			continue
		}
		stripBlocks(r.Message.Content)
	}
	for _, t := range s.Turns {
		stripBlocks(t.Blocks)
	}
	for _, sa := range s.Subagents {
		if sa.Session != nil {
			sa.Session.StripImages()
		}
	}
}

func stripBlocks(blocks Blocks) {
	for i := range blocks {
		if src := blocks[i].Source; src != nil && src.Data != "" {
			src.Size = len(src.Data) * 3 / 4
			src.Data = ""
		}
		if len(blocks[i].Content) > 0 {
			stripBlocks(blocks[i].Content)
		}
	}
}
