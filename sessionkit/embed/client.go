package embed

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"unicode/utf8"
)

// BatchSize is how many texts go in one request. The spike measured 32
// segments per request at about 100 segments a second; larger batches were no
// faster.
const BatchSize = 32

// Client speaks llama-server's OpenAI-compatible embeddings route.
type Client struct {
	BaseURL string // http://127.0.0.1:<port>
	Key     string // bearer token, when the server wants one
	HTTP    *http.Client
}

type embeddingsRequest struct {
	Input []string `json:"input"`
}

type embeddingsResponse struct {
	Data []struct {
		Index     int       `json:"index"`
		Embedding []float32 `json:"embedding"`
	} `json:"data"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Embed returns one unit vector per input, in order. Inputs are sent as they
// are: frame them with Document or Query first.
func (c *Client) Embed(ctx context.Context, inputs []string) ([][]float32, error) {
	out := make([][]float32, 0, len(inputs))
	for start := 0; start < len(inputs); start += BatchSize {
		end := min(start+BatchSize, len(inputs))
		vecs, err := c.post(ctx, inputs[start:end])
		if err != nil && isTooLong(err) {
			// One text in the batch is longer than the model reads. Send them
			// one at a time: only that one is cut, the rest keep their whole text.
			vecs = make([][]float32, 0, end-start)
			for _, in := range inputs[start:end] {
				v, oneErr := c.one(ctx, in)
				if oneErr != nil {
					return nil, oneErr
				}
				vecs = append(vecs, v)
			}
			err = nil
		}
		if err != nil {
			return nil, err
		}
		out = append(out, vecs...)
	}
	return out, nil
}

// one embeds a single text, cutting it in half for as long as the server says
// it has too many tokens.
//
// DECISION: a vector for the first part of an over-long text beats no vector.
// The chunker keeps pieces near 1,500 characters, which measured at most 1,502
// tokens (a text of nothing but emoji), so this is a net under a net.
func (c *Client) one(ctx context.Context, in string) ([]float32, error) {
	for {
		vecs, err := c.post(ctx, []string{in})
		if err == nil {
			return vecs[0], nil
		}
		if !isTooLong(err) || len(in) < 64 {
			return nil, err
		}
		cut := len(in) / 2
		for cut > 0 && !utf8.RuneStart(in[cut]) {
			cut--
		}
		in = in[:cut]
	}
}

type serverError struct {
	status  int
	message string
}

func (e *serverError) Error() string {
	return fmt.Sprintf("embedding server: %d %s", e.status, e.message)
}

func isTooLong(err error) bool {
	se, ok := err.(*serverError)
	return ok && strings.Contains(se.message, "too large to process")
}

func (c *Client) post(ctx context.Context, inputs []string) ([][]float32, error) {
	body, err := json.Marshal(embeddingsRequest{Input: inputs})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/v1/embeddings", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if c.Key != "" {
		req.Header.Set("Authorization", "Bearer "+c.Key)
	}
	hc := c.HTTP
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("embedding server: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("embedding server: %w", err)
	}
	var parsed embeddingsResponse
	jsonErr := json.Unmarshal(raw, &parsed)
	if resp.StatusCode != http.StatusOK {
		msg := strings.TrimSpace(string(raw))
		if jsonErr == nil && parsed.Error != nil {
			msg = parsed.Error.Message
		}
		if len(msg) > 300 {
			msg = msg[:300]
		}
		return nil, &serverError{status: resp.StatusCode, message: msg}
	}
	if jsonErr != nil {
		return nil, fmt.Errorf("embedding server: unreadable answer: %w", jsonErr)
	}
	if len(parsed.Data) != len(inputs) {
		return nil, fmt.Errorf("embedding server: %d vectors for %d texts", len(parsed.Data), len(inputs))
	}
	out := make([][]float32, len(inputs))
	for _, d := range parsed.Data {
		if d.Index < 0 || d.Index >= len(out) || out[d.Index] != nil {
			return nil, fmt.Errorf("embedding server: vector index %d out of place", d.Index)
		}
		if len(d.Embedding) != Dimensions {
			return nil, fmt.Errorf("embedding server: vector has %d dimensions, expected %d (is this the pinned model?)", len(d.Embedding), Dimensions)
		}
		out[d.Index] = Normalize(d.Embedding)
	}
	return out, nil
}
