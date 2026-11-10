// Package embed turns text into vectors with EmbeddingGemma 2 running in a
// local llama-server (ADR 0005). It holds the pinned model file and its one
// download, the sidecar process, the HTTP client for /v1/embeddings, the prompt
// framing, the chunker and the float16 vector format. It knows nothing about
// sessions or the index: package archive decides what to embed, package search
// what to do with the vectors.
//
// The model download is the only network traffic in skit. Everything else
// talks to 127.0.0.1.
package embed

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// ModelFile is one file of a model repository at a pinned revision.
type ModelFile struct {
	Repo     string // Hugging Face repository
	Revision string // commit the file is pinned to
	Name     string
	Bytes    int64
	SHA256   string
	// BaseURL is the host the file is fetched from. Empty means Hugging Face;
	// tests point it at a local server.
	BaseURL string
}

// TextModel is EmbeddingGemma 2 (text encoder), ggml-org's Q8_0 conversion:
// the file the spike measured (docs/embedding-spike.md). Q8_0 gives the same
// vectors as BF16 (cosine 0.9999) at half the size.
var TextModel = ModelFile{
	Repo:     "ggml-org/embeddinggemma-2-GGUF",
	Revision: "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
	Name:     "embeddinggemma-2-Q8_0.gguf",
	Bytes:    309_855_456,
	SHA256:   "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
}

// Dimensions is the length of an EmbeddingGemma 2 vector (its maximum; we do
// not truncate).
const Dimensions = 768

// vectorVersion is bumped only when the same text would get a different
// vector for a reason Source does not already name (a changed sidecar flag,
// say). A llama.cpp upgrade that reproduces the reference vectors keeps it.
const vectorVersion = 1

// Source names everything that decides what vector a text gets. The index
// stores it beside the vectors and drops them when it changes, so vectors from
// two sources are never compared.
func (m ModelFile) Source() string {
	rev := m.Revision
	if len(rev) > 12 {
		rev = rev[:12]
	}
	return fmt.Sprintf("%s@%s/%s pooling=mean frame=gemma-v1 dim=%d v%d", m.Repo, rev, m.Name, Dimensions, vectorVersion)
}

// ModelsDir is where model files live inside a skit home.
func ModelsDir(home string) string { return filepath.Join(home, "models") }

// Path is where the file lives inside a skit home.
func (m ModelFile) Path(home string) string { return filepath.Join(ModelsDir(home), m.Name) }

// URL is the file's address at the pinned revision.
func (m ModelFile) URL() string {
	base := m.BaseURL
	if base == "" {
		base = "https://huggingface.co"
	}
	return fmt.Sprintf("%s/%s/resolve/%s/%s", strings.TrimRight(base, "/"), m.Repo, m.Revision, m.Name)
}

// ModelState says what is on disk for a model file.
type ModelState struct {
	Path    string `json:"path"`
	Present bool   `json:"present"` // the whole file, checksum verified
	Bytes   int64  `json:"bytes"`   // on disk, including a partial download
	Want    int64  `json:"want_bytes"`
	Detail  string `json:"detail,omitempty"` // why it is not present
}

// Check reports whether the file is in home and intact. The checksum is
// computed once and remembered in a marker beside the file (size and
// modification time), so later checks cost one stat.
func (m ModelFile) Check(home string) ModelState {
	st := ModelState{Path: m.Path(home), Want: m.Bytes}
	fi, err := os.Stat(st.Path)
	if err != nil {
		if part, perr := os.Stat(st.Path + ".part"); perr == nil {
			st.Bytes = part.Size()
			st.Detail = "download not finished"
		} else {
			st.Detail = "not downloaded"
		}
		return st
	}
	st.Bytes = fi.Size()
	if fi.Size() != m.Bytes {
		st.Detail = fmt.Sprintf("wrong size (%d bytes, expected %d)", fi.Size(), m.Bytes)
		return st
	}
	marker := fmt.Sprintf("%s %d %d\n", m.SHA256, fi.Size(), fi.ModTime().UnixNano())
	if b, err := os.ReadFile(st.Path + ".verified"); err == nil && string(b) == marker {
		st.Present = true
		return st
	}
	sum, err := fileSHA256(st.Path)
	if err != nil {
		st.Detail = err.Error()
		return st
	}
	if sum != m.SHA256 {
		st.Detail = "checksum does not match the pinned file"
		return st
	}
	_ = os.WriteFile(st.Path+".verified", []byte(marker), 0o644) // best effort: without it the next check hashes again
	st.Present = true
	return st
}

// Ensure makes the file present in home, downloading it when it is not. A
// download that was cut short resumes where it stopped. The bytes are checked
// against the pinned SHA-256 before the file takes its name. progress, when
// set, is called with the bytes on disk so far.
func (m ModelFile) Ensure(ctx context.Context, home string, progress func(done, total int64)) error {
	if m.Check(home).Present {
		return nil
	}
	if err := os.MkdirAll(ModelsDir(home), 0o755); err != nil {
		return err
	}
	final := m.Path(home)
	if fi, err := os.Stat(final); err == nil {
		// A file with the right name and the wrong content is not ours to keep
		// feeding to the sidecar; move it aside rather than delete it.
		aside := fmt.Sprintf("%s.rejected-%d", final, fi.ModTime().Unix())
		if err := os.Rename(final, aside); err != nil {
			return err
		}
	}
	part := final + ".part"
	for attempt := 0; ; attempt++ {
		err := m.fetch(ctx, part, progress)
		if err == nil {
			break
		}
		// A partial file the server will not continue from is started over once.
		if errors.Is(err, errRestart) && attempt == 0 {
			os.Remove(part)
			continue
		}
		return err
	}
	sum, err := fileSHA256(part)
	if err != nil {
		return err
	}
	if sum != m.SHA256 {
		os.Remove(part)
		return fmt.Errorf("%s: the download does not match the pinned checksum (got %s); nothing was kept", m.Name, sum[:12])
	}
	if err := os.Rename(part, final); err != nil {
		return err
	}
	if !m.Check(home).Present {
		return fmt.Errorf("%s: downloaded but not usable", m.Name)
	}
	return nil
}

var errRestart = errors.New("partial download cannot be resumed")

// fetch appends the missing bytes of the file to part.
func (m ModelFile) fetch(ctx context.Context, part string, progress func(done, total int64)) error {
	var have int64
	if fi, err := os.Stat(part); err == nil {
		have = fi.Size()
	}
	if have > m.Bytes {
		return errRestart
	}
	if have == m.Bytes {
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, m.URL(), nil)
	if err != nil {
		return err
	}
	if have > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("download %s: %w", m.Name, err)
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusPartialContent && have > 0:
	case resp.StatusCode == http.StatusOK && have == 0:
	case resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusRequestedRangeNotSatisfiable:
		return errRestart // the server ignored or refused the range
	default:
		return fmt.Errorf("download %s: %s from %s", m.Name, resp.Status, req.URL.Host)
	}
	f, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	buf := make([]byte, 1<<20)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				return werr
			}
			have += int64(n)
			if progress != nil {
				progress(have, m.Bytes)
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			return fmt.Errorf("download %s: %w (run again to resume at %d bytes)", m.Name, rerr, have)
		}
	}
	if have != m.Bytes {
		return fmt.Errorf("download %s: got %d bytes, expected %d (run again to resume)", m.Name, have, m.Bytes)
	}
	return f.Sync()
}

func fileSHA256(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
