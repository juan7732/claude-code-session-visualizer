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
	"strings"
	"unicode"
)

// keepKeys are string values that carry structure, not content.
var keepKeys = map[string]bool{
	"type": true, "uuid": true, "parentUuid": true, "logicalParentUuid": true, "sessionId": true, "agentId": true,
	"requestId": true, "requestRef": true, "promptId": true, "timestamp": true, "version": true, "entrypoint": true,
	"gitBranch": true, "slug": true, "role": true, "model": true, "id": true, "name": true, "stop_reason": true,
	"status": true, "kind": true, "subtype": true, "level": true, "trigger": true, "service_tier": true, "speed": true,
	"inference_geo": true, "tool_use_id": true, "media_type": true, "userType": true, "turnOrigin": true,
	"decision": true, "source": true, "renderedRole": true, "permissionMode": true, "mode": true, "agentType": true,
	"toolUseId": true, "resolvedModel": true, "requestShape": true, "pickedEffortModel": true, "effort": true,
	"perTurnEffort": true, "advisorModel": true, "requestedModel": true, "attributionSkill": true,
	"attributionAgent": true, "operation": true, "subagent_type": true, "skill": true, "querySource": true,
	"signature": true, "headUuid": true, "anchorUuid": true, "tailUuid": true, "openerUuid": true, "leafUuid": true,
	"messageId": true, "snapshotMessageId": true, "backupFileName": true,
	"commandName": true, "prUrl": true, "prRepository": true, "deliveryId": true, "commandUuid": true,
}

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
			x[k] = redact(val, k)
		}
		return x
	case []any:
		for i := range x {
			x[i] = redact(x[i], key)
		}
		return x
	case string:
		if maskKeys[key] {
			return mask(x)
		}
		if keepKeys[key] || looksLikeID(x) {
			return x
		}
		return mask(x)
	default:
		return v
	}
}

// looksLikeID keeps short token-like strings (uuids, ids, hashes) that have no
// spaces and would be meaningless to mask.
func looksLikeID(s string) bool {
	if len(s) == 0 || len(s) > 64 || strings.ContainsAny(s, " \n\t") {
		return false
	}
	for _, r := range s {
		if !(unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_' || r == '.' || r == ':') {
			return false
		}
	}
	return strings.ContainsAny(s, "0123456789") && !strings.Contains(s, ".")
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
