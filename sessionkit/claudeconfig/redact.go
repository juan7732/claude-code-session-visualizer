package claudeconfig

import (
	"regexp"
	"strings"
	"unicode"
)

// NotShown stands in a settings layer for a value that is set and is not
// printed: a key, a token, a command that fetches one.
const NotShown = "set (not shown)"

// secretWords are the words in a setting's name that say its value is a
// credential or a command that produces one (apiKeyHelper, ANTHROPIC_AUTH_TOKEN,
// awsCredentialExport, otelHeadersHelper).
//
// DECISION: whole words, not substrings. "pass" as a substring would hide
// permissions.defaultMode's neighbours (disableBypassPermissionsMode), and
// "tokens" is left out so MAX_THINKING_TOKENS keeps its number. A value hidden
// that was harmless costs a look in the file; a key printed costs the key.
var secretWords = map[string]bool{
	"key": true, "keys": true, "token": true, "secret": true, "secrets": true, "password": true, "passwd": true,
	"pass": true, "pwd": true, "credential": true, "credentials": true, "auth": true, "authorization": true,
	"cookie": true, "bearer": true, "private": true, "helper": true, "dsn": true,
}

// secretValue recognises a credential by its look, whatever it is filed under:
// the prefixes the common services give their keys, a URL that carries a
// password, a header that carries a bearer token, a PEM block.
var secretValue = regexp.MustCompile(`sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,}|` +
	`AKIA[0-9A-Z]{12,}|ASIA[0-9A-Z]{12,}|xox[abprs]-[A-Za-z0-9-]{8,}|AIza[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{16,}|` +
	`eyJ[A-Za-z0-9_-]{8,}\.eyJ|(?i:authorization)\s*[:=]\s*\S+|(?i:bearer)\s+[A-Za-z0-9._~+/=-]{8,}|[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@|-----BEGIN `)

// opaque is a long run of the characters keys are made of: with nothing in
// its name or its look to say what it is, a 32-character blob is not shown.
var opaque = regexp.MustCompile(`^[A-Za-z0-9+/=_-]{32,}$`)

// redactSettings returns a settings layer with its credentials replaced by
// NotShown. The file is not changed; m is not changed.
//
// SPEC: docs/tenets.md, "Everything stays on the user's machine": settings.json
// is where people put ANTHROPIC_API_KEY (under env) and the command that
// prints one (apiKeyHelper), and `skit claude --json` is made to be pasted.
func redactSettings(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = redactValue(k, v, false)
	}
	return out
}

// redactValue is v as it may be shown under the name key. all is true inside a
// headers object, where every value is a credential or travels beside one.
func redactValue(key string, v any, all bool) any {
	if all || secretName(key) {
		if empty(v) {
			return v
		}
		return NotShown
	}
	switch x := v.(type) {
	case map[string]any:
		inside := strings.EqualFold(key, "headers")
		out := make(map[string]any, len(x))
		for k, vv := range x {
			out[k] = redactValue(k, vv, inside)
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, vv := range x {
			out[i] = redactValue("", vv, false)
		}
		return out
	case string:
		if secretValue.MatchString(x) || opaque.MatchString(x) {
			return NotShown
		}
	}
	return v
}

func empty(v any) bool {
	switch x := v.(type) {
	case nil:
		return true
	case string:
		return x == ""
	case map[string]any:
		return len(x) == 0
	case []any:
		return len(x) == 0
	}
	return false
}

// secretName reports whether one of the name's words is a secret word.
// apiKeyHelper is api, key, helper; ANTHROPIC_AUTH_TOKEN is anthropic, auth, token.
func secretName(name string) bool {
	for _, w := range words(name) {
		if secretWords[w] {
			return true
		}
	}
	return false
}

// words splits a camelCase, snake_case or kebab-case name into lower-case words.
func words(name string) []string {
	var out []string
	var cur []rune
	flush := func() {
		if len(cur) > 0 {
			out = append(out, strings.ToLower(string(cur)))
			cur = cur[:0]
		}
	}
	runes := []rune(name)
	for i, r := range runes {
		switch {
		case !unicode.IsLetter(r) && !unicode.IsDigit(r):
			flush()
			continue
		case unicode.IsUpper(r) && i > 0:
			prev := runes[i-1]
			// A new word starts at aB, and at the last capital of ABc (APIKey is api, key).
			if unicode.IsLower(prev) || unicode.IsDigit(prev) || (unicode.IsUpper(prev) && i+1 < len(runes) && unicode.IsLower(runes[i+1])) {
				flush()
			}
		}
		cur = append(cur, r)
	}
	flush()
	return out
}
