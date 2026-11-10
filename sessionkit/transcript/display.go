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
