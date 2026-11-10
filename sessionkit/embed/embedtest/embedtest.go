// Package embedtest stands in for llama-server in tests: the same HTTP routes
// and start-up contract, with vectors computed from the words of a text
// instead of a model. Texts that share words get close vectors, so ranking
// tests have something real to rank. Nothing outside tests imports it.
package embedtest

import (
	"encoding/json"
	"fmt"
	"hash/fnv"
	"math"
	"net"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"unicode"
)

// Dimensions matches embed.Dimensions (not imported: embed's own tests use
// this package).
const Dimensions = 768

// TooLongRunes is the input length from which the fake answers as llama-server
// does for a text with more tokens than its batch.
const TooLongRunes = 6000

// Vector is the fake's vector for a text: each word adds to one dimension
// chosen by its hash, then the whole is scaled to unit length. EmbeddingGemma's
// framing prefixes are dropped first, so a query and a document with the same
// words agree.
func Vector(text string) []float32 {
	for _, p := range []string{"title: none | text: ", "task: search result | query: "} {
		text = strings.TrimPrefix(text, p)
	}
	v := make([]float32, Dimensions)
	words := strings.FieldsFunc(strings.ToLower(text), func(r rune) bool { return !unicode.IsLetter(r) && !unicode.IsDigit(r) })
	for _, w := range words {
		h := fnv.New32a()
		h.Write([]byte(w))
		v[h.Sum32()%Dimensions]++
	}
	var sum float64
	for _, x := range v {
		sum += float64(x) * float64(x)
	}
	if sum == 0 {
		v[0] = 1
		return v
	}
	inv := float32(1 / math.Sqrt(sum))
	for i := range v {
		v[i] *= inv
	}
	return v
}

// Server is the fake's state, for assertions.
type Server struct {
	Key      string       // required bearer token; "" accepts anything
	Requests atomic.Int64 // POST /v1/embeddings calls
	Texts    atomic.Int64 // texts embedded
}

// ServeHTTP answers GET /health and POST /v1/embeddings.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	switch {
	case r.Method == http.MethodGet && r.URL.Path == "/health":
		fmt.Fprint(w, `{"status":"ok"}`)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/embeddings":
		if s.Key != "" && r.Header.Get("Authorization") != "Bearer "+s.Key {
			w.WriteHeader(http.StatusUnauthorized)
			fmt.Fprint(w, `{"error":{"message":"Invalid API Key","type":"authentication_error","code":401}}`)
			return
		}
		var req struct {
			Input []string `json:"input"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error":{"message":"bad request"}}`)
			return
		}
		s.Requests.Add(1)
		type item struct {
			Index     int       `json:"index"`
			Embedding []float32 `json:"embedding"`
		}
		out := struct {
			Data []item `json:"data"`
		}{}
		for i, in := range req.Input {
			if n := len([]rune(in)); n >= TooLongRunes {
				w.WriteHeader(http.StatusInternalServerError)
				fmt.Fprintf(w, `{"error":{"code":500,"message":"input (%d tokens) is too large to process. increase the physical batch size (current batch size: 2048)","type":"server_error"}}`, n)
				return
			}
			out.Data = append(out.Data, item{Index: i, Embedding: Vector(in)})
		}
		s.Texts.Add(int64(len(req.Input)))
		json.NewEncoder(w).Encode(out)
	default:
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, `{"error":{"message":"not found"}}`)
	}
}

// Main behaves like the llama-server binary: it reads --port and -m from the
// arguments and the key from LLAMA_API_KEY, refuses a model file that does not
// exist, and serves until it is signalled. A test binary calls it from
// TestMain when it was started as the fake (see embed's tests).
func Main(args []string) {
	port, model := "", ""
	for i := 0; i+1 < len(args); i++ {
		switch args[i] {
		case "--port":
			port = args[i+1]
		case "-m":
			model = args[i+1]
		}
	}
	if _, err := os.Stat(model); err != nil {
		fmt.Fprintf(os.Stderr, "error: failed to load model '%s'\n", model)
		os.Exit(1)
	}
	l, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		fmt.Fprintln(os.Stderr, "couldn't bind HTTP server socket:", err)
		os.Exit(1)
	}
	fmt.Fprintln(os.Stderr, "server is listening on", l.Addr())
	_ = http.Serve(l, &Server{Key: os.Getenv("LLAMA_API_KEY")})
}
