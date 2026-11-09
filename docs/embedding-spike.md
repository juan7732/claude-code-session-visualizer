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

## Addendum: bigger vectors, and the full multimodal encoder

Juan asked whether we can go up in vector size and get image and audio vectors too. Measured the same day.

**Vector size.** 768 is EmbeddingGemma 2's native and maximum output; there is no larger variant (740M parameters: 270M
text, 170M vision, 300M audio). Matryoshka training lets us go _down_: on the 300-segment sample, truncating and
re-normalising kept these shares of the 768d top-10:

| Dimensions | Storage per vector | Top-10 overlap with 768d |
| ---------- | ------------------ | ------------------------ |
| 768        | 1.50 KB            | 100%                     |
| 512        | 1.00 KB            | 84%                      |
| 256        | 0.50 KB            | 70%                      |
| 128        | 0.25 KB            | 62%                      |

Keep 768. Storage is not the constraint (`archive-sizing.md`).

**Precision.** The BF16 text model (558 MB) against Q8_0 (310 MB): cosine agreement 0.9999 mean and minimum over 300
vectors, no NaNs, same speed (3.69 s vs 3.66 s). Q8_0 stays; BF16 was deleted after the test.

**Images and audio through `llama-server`.** With `--mmproj mmproj-embeddinggemma-2-Q8_0.gguf` (555 MB, checksum
verified) the server loads the vision and audio encoders (ready in 0.6 s, 1.1 GB resident instead of 0.54). The
documented request shape works on `POST /v1/embeddings`: each `input` element is an object whose `content` array holds
chat-style parts, `image_url` with a base64 data URI, or `input_audio` with base64 WAV. (The native `/embedding` shape
returned a tokenizer error on this build; the OpenAI route is enough.)

| Measurement                                              | Result                                           |
| -------------------------------------------------------- | ------------------------------------------------ |
| Image, first request (encoder warm-up)                   | 183 ms                                           |
| Image, steady state (64 px to 320 px PNGs)               | 45–47 ms each, about 85 image tokens             |
| Audio, 3–5 s speech clips (macOS `say`, 16 kHz mono WAV) | 62–142 ms each                                   |
| Image vector vs the literal marker text                  | cosine 0.65 (a real vector, not the placeholder) |

Cross-modal sanity, DigUp's logo (an orange cartoon icon) against text queries: "an orange cartoon icon" 0.665, "a logo
of a shovel digging" 0.624, "Go source code for a SQLite schema" 0.578, "a spreadsheet of quarterly revenue numbers"
0.555. Right order, modest spread, which is why DigUp normalises scores per modality.

Audio was the surprise: synthesised speech saying "the retention sweep deletes old transcripts after thirty days" scored
0.804 against the matching text query and 0.519 against an unrelated one; a second clip 0.854 vs 0.536. Speech content
is retrievable by text query out of the box.

Pitfall worth recording: a first attempt with the wrong request shape (`multimodal_data` next to `content`) returned
vectors identical to the marker text with 7 tokens and a constant 5 ms, i.e. the media was silently ignored. Check
`n_tokens` in the server log and compare against the marker's vector before trusting a multimodal path.

## What this decides

See `decisions/0005-embedding-worker.md`: ship `llama-server` as the embedding sidecar for text, images and audio alike;
write no embedding worker of our own. The multimodal encoder is an optional 555 MB download that doubles the sidecar's
memory; the engine turns it on when a session has images or audio to index.
