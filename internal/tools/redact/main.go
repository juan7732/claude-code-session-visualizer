// Command redact turns a real Claude Code transcript into a fixture: same
// structure, ids, timestamps, types and numbers, with every piece of content
// masked and api-request* records dropped.
//
//	go run ./internal/tools/redact <session.jsonl> <out-dir>
//
// Writes <out-dir>/<session-id>.jsonl and, when present, the subagents under
// <out-dir>/<session-id>/subagents/ (transcripts and .meta.json).
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode"
)

// keepKeys are string values that carry structure, not content.
var keepKeys = map[string]bool{
	"type": true, "uuid": true, "parentUuid": true, "logicalParentUuid": true, "sessionId": true, "agentId": true,
	"requestId": true, "requestRef": true, "promptId": true, "timestamp": true, "version": true, "entrypoint": true,
	"slug": true, "role": true, "model": true, "id": true, "name": true, "stop_reason": true,
	"status": true, "kind": true, "subtype": true, "level": true, "trigger": true, "service_tier": true, "speed": true,
	"inference_geo": true, "tool_use_id": true, "media_type": true, "userType": true, "turnOrigin": true,
	"decision": true, "source": true, "renderedRole": true, "permissionMode": true, "mode": true, "agentType": true,
	"toolUseId": true, "resolvedModel": true, "requestShape": true, "pickedEffortModel": true, "effort": true,
	"perTurnEffort": true, "advisorModel": true, "requestedModel": true, "attributionSkill": true,
	"attributionAgent": true, "operation": true, "subagent_type": true, "skill": true, "querySource": true,
	"headUuid": true, "anchorUuid": true, "tailUuid": true, "openerUuid": true, "leafUuid": true,
	"messageId": true, "snapshotMessageId": true,
	"commandName": true, "deliveryId": true, "commandUuid": true,
}

// DECISION (2026-11-11): gitBranch, prUrl, prRepository and backupFileName are
// no longer kept as they are. They are content: a branch and a repository say
// what was being worked on and for whom. They are masked like any other text.

// replaceKeys get a fixed placeholder instead of a shape-preserving mask: a
// masked e-mail still reveals it was an e-mail of a given length.
//
// signature is the model's thinking in a form only the API can read. Nobody
// can check what is in it, so it is never copied.
var replaceKeys = map[string]string{
	"userEmail": "user@example.com",
	"signature": "sig",
}

// email finds an address wherever it sits; it is replaced before masking, so
// not even its shape is left (the copy of userEmail inside rendered content
// had to be fixed by hand once).
var email = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+`)

// claudeID is what an id of Claude Code or of the API looks like: a uuid, a
// prefixed id (toolu_…, msg_…, req_…), an agent id, a short hash.
var claudeID = regexp.MustCompile(`^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|(toolu|srvtoolu|msg|req)_[A-Za-z0-9]{1,40}|a[0-9a-f]{16}|[0-9a-f]{6,16}(@v[0-9]+)?)$`)

// credential is what a key or token of the common services looks like. A
// value like this is masked whatever key it is under.
var credential = regexp.MustCompile(`sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_|glpat-|AKIA[0-9A-Z]{12,}|ASIA[0-9A-Z]{12,}|xox[abprs]-|AIza[A-Za-z0-9_-]{16,}|hf_[A-Za-z0-9]{16,}|eyJ[A-Za-z0-9_-]{8,}\.eyJ|-----BEGIN `)

// maskKeys are identifiers tied to a person or account: always masked, even
// though they look like ids.
var maskKeys = map[string]bool{
	"accountUuid": true, "organizationUuid": true, "ownerAccountUuid": true, "ownerOrganizationUuid": true,
	"bridgeSessionId": true, "turnAttributionKey": true,
}

const onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: redact <session.jsonl> <out-dir>")
		os.Exit(2)
	}
	src, out := os.Args[1], os.Args[2]
	id := strings.TrimSuffix(filepath.Base(src), ".jsonl")
	if err := os.MkdirAll(out, 0o755); err != nil {
		die(err)
	}
	dropped, kept, err := redactFile(src, filepath.Join(out, id+".jsonl"))
	if err != nil {
		die(err)
	}
	fmt.Printf("%s: kept %d records, dropped %d api-request* records\n", id, kept, dropped)
	subdir := filepath.Join(filepath.Dir(src), id, "subagents")
	entries, err := os.ReadDir(subdir)
	if err != nil {
		return
	}
	outSub := filepath.Join(out, id, "subagents")
	if err := os.MkdirAll(outSub, 0o755); err != nil {
		die(err)
	}
	for _, e := range entries {
		p := filepath.Join(subdir, e.Name())
		switch {
		case strings.HasSuffix(e.Name(), ".jsonl"):
			d, k, err := redactFile(p, filepath.Join(outSub, e.Name()))
			if err != nil {
				die(err)
			}
			fmt.Printf("  %s: kept %d, dropped %d\n", e.Name(), k, d)
		case strings.HasSuffix(e.Name(), ".meta.json"):
			b, err := os.ReadFile(p)
			if err != nil {
				die(err)
			}
			var v any
			if err := json.Unmarshal(b, &v); err != nil {
				die(err)
			}
			rb, _ := json.Marshal(redact(v, ""))
			if err := os.WriteFile(filepath.Join(outSub, e.Name()), rb, 0o644); err != nil {
				die(err)
			}
		}
	}
}

func redactFile(src, dst string) (dropped, kept int, err error) {
	in, err := os.Open(src)
	if err != nil {
		return 0, 0, err
	}
	defer in.Close()
	outF, err := os.Create(dst)
	if err != nil {
		return 0, 0, err
	}
	defer outF.Close()
	w := bufio.NewWriter(outF)
	defer w.Flush()
	r := bufio.NewReaderSize(in, 1<<20)
	for {
		line, rerr := r.ReadBytes('\n')
		line = bytes.TrimRight(line, "\r\n")
		if len(bytes.TrimSpace(line)) > 0 {
			var v map[string]any
			if json.Unmarshal(line, &v) != nil {
				// keep malformed lines as-is but masked
				fmt.Fprintln(w, mask(string(line)))
				kept++
			} else if t, _ := v["type"].(string); strings.HasPrefix(t, "api-request") {
				dropped++
			} else {
				b, _ := json.Marshal(redact(v, ""))
				w.Write(b)
				w.WriteByte('\n')
				kept++
			}
		}
		if rerr != nil {
			break // EOF or partial last line: partial is dropped on purpose
		}
	}
	return dropped, kept, nil
}

// redact walks a decoded JSON value, masking string content.
func redact(v any, key string) any {
	switch x := v.(type) {
	case map[string]any:
		if mt, ok := x["media_type"].(string); ok && strings.HasPrefix(mt, "image/") {
			if _, has := x["data"]; has {
				x["data"] = onePixelPNG
				x["media_type"] = "image/png"
			}
		}
		for k, val := range x {
			red := redact(val, k)
			// A key that is a path or an address (trackedFileBackups is keyed by file) is content too.
			if strings.ContainsAny(k, "/@ ") {
				delete(x, k)
				k = mask(email.ReplaceAllString(k, "user@example.com"))
			}
			x[k] = red
		}
		return x
	case []any:
		for i := range x {
			x[i] = redact(x[i], key)
		}
		return x
	case string:
		if fixed, ok := replaceKeys[key]; ok {
			return fixed
		}
		if maskKeys[key] || credential.MatchString(x) {
			return mask(x)
		}
		if keepKeys[key] || looksLikeID(x) {
			return x
		}
		// An address keeps neither its letters nor its shape.
		if email.MatchString(x) {
			parts := email.Split(x, -1)
			for i := range parts {
				parts[i] = mask(parts[i])
			}
			return strings.Join(parts, "user@example.com")
		}
		return mask(x)
	default:
		return v
	}
}

// looksLikeID keeps the ids that tie records together (uuids, tool call and
// request ids, agent ids, short hashes), which would be meaningless to mask.
//
// DECISION (2026-11-11): by shape, not by "short, with a digit, no space".
// That rule kept a 40-character GitHub token, an AWS key id, a hex API key, a
// host:port and any user name with a digit in it exactly as they were.
func looksLikeID(s string) bool {
	return claudeID.MatchString(s)
}

// mask keeps length, whitespace, punctuation and path separators; letters
// become x/X and digits 0, so structure (markdown, paths, JSON in strings)
// survives while content does not.
func mask(s string) string {
	var sb strings.Builder
	sb.Grow(len(s))
	for _, r := range s {
		switch {
		case unicode.IsUpper(r):
			sb.WriteRune('X')
		case unicode.IsLetter(r):
			sb.WriteRune('x')
		case unicode.IsDigit(r):
			sb.WriteRune('0')
		default:
			sb.WriteRune(r)
		}
	}
	return sb.String()
}

func die(err error) {
	fmt.Fprintln(os.Stderr, "redact:", err)
	os.Exit(1)
}
