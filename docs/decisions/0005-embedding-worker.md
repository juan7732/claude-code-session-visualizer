# 0005 · The embedding worker is `llama-server` (text, images, audio)

Date: 2026-11-09. Status: accepted. Based on `../embedding-spike.md`.

**Context.** Meaning search needs EmbeddingGemma 2 vectors for every segment and every query. The engine is Go and runs
as a process; the plan called for a sidecar speaking a worker protocol, with DigUp's Swift `LlamaRuntime` as the model.
Ollama was ruled out. The spike showed llama.cpp's own `llama-server` already does the job: 1 s to ready, 6 ms per
query, 100 segments/s on Metal, 539 MB resident, vectors identical to `llama-embedding`.

**Decision.**

- skit spawns `llama-server --embeddings --pooling mean -c 2048 -b 2048 -ub 2048 -ngl 99` on `127.0.0.1` with an
  ephemeral port and a random `--api-key`, and talks to it over the OpenAI-compatible `POST /v1/embeddings`. No worker
  code of our own for text. The `embed` package is a small client plus process management (start, health, idle stop).
- The binary comes from `brew install llama.cpp` on a dev machine and is bundled in the app's `Contents/Helpers/` for
  releases, as DigUp bundles its helper. Its path is configurable.
- Model files are downloaded once by skit into `~/.sessionkit/models/` from the pinned Hugging Face revision with a
  SHA-256 check, resumable. The index records a **vector source** string (model repo, revision, quantisation, pooling,
  prompt framing, and a `vectorVersion` we bump only when vectors actually change), as DigUp does, so a llama.cpp
  upgrade that reproduces the reference vectors keeps the index. A reference-vectors test pins that.
- Prompts: documents `title: none | text: …`, queries `task: search result | query: …`. Mean pooling, L2-normalised, 768
  fp16 per vector stored on the segment row, brute-force cosine in memory, DigUp's z-scaled fusion with the keyword
  score. The z-gate value is an eval question, not a constant we copy (the spike saw a junk query reach z ≈ 2.9).
- CPU-only machines are supported at about a tenth of the speed, with a warning in `doctor`.

**Multimodal (added the same day).** The same server with `--mmproj mmproj-embeddinggemma-2-Q8_0.gguf` embeds images
(`image_url` data URI, ~45 ms each) and audio (`input_audio` WAV, ~60–140 ms per short clip) through `/v1/embeddings`,
into the same 768-dimensional space; measured in `../embedding-spike.md`. So no Swift `LlamaRuntime` or custom mtmd
worker is needed for tier C either. The encoder file is a second, optional download (555 MB) and raises the sidecar's
resident memory from about 0.5 GB to 1.1 GB; skit starts the server with it only when there is media to embed. Vectors
are 768-dimensional (the model's maximum); Matryoshka truncation is possible but not used. Q8_0 over BF16: identical
vectors (cosine 0.9999), half the size.

**Amended 2026-11-10, while building it** (`../meaning-search.md`).

- Vectors are not stored on the segment row. A segment's prose is cut into chunks of at most 1,500 characters, each
  chunk names its text by hash, and one vector is stored per hash. The index replaces a session's segment rows on every
  ingest, so a vector on the row would be recomputed each time a live session grows; and a segment can be longer than
  the 2,048 tokens the model reads, so one vector per segment would cover only its start.
- The API key is passed in `LLAMA_API_KEY`, not `--api-key`, so it does not appear in the process list. The server also
  gets `--offline`, `--no-webui` and `--no-slots`.
- One sidecar belongs to one `skit` process, which stops it; `serve` stops its own after ten idle minutes. There is no
  shared daemon. A sidecar orphaned by a killed `skit` is stopped by the next one through a run file in
  `~/.sessionkit/run/`.
- Only `skit embed` downloads the model. Nothing else reaches the network.
- "DigUp's z-scaled fusion" is not built yet: meaning search ranks by plain cosine until the eval exists.

**Consequences.** Text, image and audio search ship without writing or maintaining llama.cpp bindings. The `embed`
package is a client for one well-documented HTTP API plus process management and model downloads.
