# Images and other modalities

## How images get into a session (observed: 25 image blocks across 8 sessions)

1. **Pasted or attached by the user.** A `user` record with `turnOrigin: human`, content `[image, text]` or
   `[text, image, text]`, `imagePasteIds: [n]`, the image as
   `{"type":"image","source":{"type":"base64","media_type": "image/png"|"image/jpeg","data":"…"}}`. Observed 30 KB to
   360 KB of base64 each. The text usually refers to it ("This is the TA's feedback…").
2. **Read by a tool.** `Read` on a PNG returns a `tool_result` whose `content` is a list with an `image` block (18 of
   the 25). Same base64 shape.
3. **Returned by MCP tools.** Per the docs, full-size copies land in `<session>/tool-results/` (none observed here).
4. **Duplicated** in `api-request-blob` records (the request body that carried the image). Skip those.

Since Claude Code 2.1.274 pasted images are also saved under the temp dir (`…/<session>/images/`), not under
`~/.claude`, and the OS may clear it. **Decode from the jsonl**, which always has the bytes.

## Will the text embedding model work for images?

No. The text-only EmbeddingGemma 2 GGUF (310 MB) embeds tokens, not pixels. Three options, in the order I would try
them:

| Option                            | How                                                                                                                                                                                                                                                                                                      | Cost                                                       | Finds                                                            |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- | ---------------------------------------------------------------- |
| **A. Proxy text (v0)**            | Embed the surrounding text: the user's words in the same message, and the assistant's next text/thinking (it almost always describes what it saw). Store the image bytes + a thumbnail for display.                                                                                                      | zero extra model                                           | "the session where I pasted the TA feedback screenshot"          |
| **B. OCR → keyword index**        | Apple Vision in the Swift client (free, on-device) or Tesseract in Go. Text goes to FTS5 only. DigUp found OCR _vectors_ made screenshots outrank better matches; keyword-only is the right use.                                                                                                         | ~0.25 s/image                                              | exact strings: error codes, file names, UI labels in screenshots |
| **C. True image vectors (later)** | EmbeddingGemma 2 is multimodal: the `mmproj` encoder (555 MB more) puts images in the **same 768-d space** as text, so "screenshot of a red error dialog" matches the picture. Measured: `llama-server --mmproj` does it through `/v1/embeddings`, ~45 ms per image on an M4 Max (`embedding-spike.md`). | 555 MB download, +0.55 GB sidecar memory, no custom worker | content of the image itself                                      |

Decision (Juan, 2026-11-07): **do all three.** A first, B with the Swift client, C as the real target, not an
afterthought. Document minimum requirements rather than avoiding the download: text model 310 MB + image encoder 555 MB,
~1 GB RAM while embedding with the encoder loaded (DigUp's measurement), Apple Silicon with Metal for acceptable speed
(0.1–0.3 s per image on an M4 Pro). The segment table carries `modality` from day one; vectors from different modalities
are z-scaled by modality as DigUp does.

## Other modalities

Content block types seen across all sessions: `text`, `tool_use`, `tool_result`, `thinking`, `image`, `tool_addition`,
`tool_reference`. No `document` (PDF) or audio blocks. PDFs read with the Read tool arrive as text or page images inside
`tool_result`; audio/video never enter a transcript. For Claude Code sessions today, **text + images is the complete
set**, and text is 99% of it by count. Other users may route audio, PDFs or video through MCP tools (the docs say MCP
image results are copied full-size into `tool-results/`), so keep extraction pluggable per block type and revisit once
we see such sessions. EmbeddingGemma 2 covers audio in the same vector space, and the spike showed it works today
through the same sidecar: synthesised speech scored 0.80–0.85 against its matching text query and ~0.52 against an
unrelated one.
