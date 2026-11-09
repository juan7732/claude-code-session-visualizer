# Embedding spike (M5)

Measured 2026-11-09 on Juan's MacBook Pro (Apple M4 Max, 16 cores, 128 GB) with llama.cpp 0.9.0 from Homebrew (build
12110, Metal) and the text-only EmbeddingGemma 2 model DigUp pins: `ggml-org/embeddinggemma-2-GGUF`
`embeddinggemma-2-Q8_0.gguf` at revision `bfcd298…`, 310 MB, SHA-256 verified. Inputs were 300 real segments drawn at
random from this machine's index (181 assistant, 80 prompt, 39 thinking; 688 characters on average, about 157 tokens
each), framed as the model card says: `title: none | text: …` for documents and `task: search result | query: …` for
queries. Pooling mean, L2-normalised, context 2048.

## Numbers

| Measurement                                          | Result                                 |
| ---------------------------------------------------- | -------------------------------------- |
| Model download                                       | 6.6 s                                  |
| `llama-embedding`, load + one text, Metal            | 0.49 s process total                   |
| `llama-embedding`, 300 segments, Metal               | 3.66 s total including load            |
| `llama-embedding`, 300 segments, CPU only (`-ngl 0`) | 37.4 s (10× slower)                    |
| `llama-server` ready (model loaded, `/health` ok)    | 1.05 s                                 |
| `llama-server` one query, warm                       | 6–7 ms (130 ms for the first)          |
| `llama-server` batch of 32 segments (5,013 tokens)   | 0.26 s                                 |
| `llama-server` all 300 segments in batches of 32     | 2.95 s = 102 segments/s ≈ 16k tokens/s |
| `llama-server` resident memory                       | 539 MB                                 |
| Metal vs CPU agreement                               | min cosine 0.9998 over 300 vectors     |
| `llama-server` vs `llama-embedding` agreement        | cosine 1.0000                          |
| Vector                                               | 768 dimensions                         |

## Quality sanity (five queries against the 300-segment sample)

- "subagent transcripts location on disk" → the probe-subagent turn first, z = 5.5. Right.
- "where did we discuss the retention sweep" → best z = 3.0, but the sample did not contain the retention segments
  (random 300 of 2,543), so the top hits were loosely related session-management text. Expected.
- "recipe for dinner" (nothing relevant exists) → best z = 2.9. **DigUp's z-gate of 2.0 would have let this through.**
  With 300 vectors the score distribution is narrow; the gate must be tuned on our eval and probably combined with an
  absolute cosine floor, not inherited as-is. The eval harness (M1's fixtures plus a query file) is the place to settle
  it.

## Projections

- This machine's whole index today (2,543 segments): about 25 s once.
- A heavy year (300 requests a day × ~3 segments × 250 days ≈ 225k segments): about 37 minutes once, then a few seconds
  per session as they arrive. A 100-request session embeds in about 3 s.
- Storage: 768 × fp16 = 1.5 KB per vector; 225k vectors = 345 MB in the index, held in memory for brute-force cosine
  (DigUp's approach). Fine for years; revisit with a quantised or on-disk index only if it ever hurts.
- CPU-only machines work at a tenth of the speed; acceptable for incremental indexing, slow for a first full pass.

## What this decides

See `decisions/0005-embedding-worker.md`: ship `llama-server` as the text embedding sidecar, write no worker of our own
for text, keep DigUp's `LlamaRuntime` design in reserve for image vectors.
