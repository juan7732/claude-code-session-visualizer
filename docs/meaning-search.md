# Meaning search

Keyword search finds a turn when you remember its words. Meaning search finds it when you remember what it said: "why
does my history vanish after a month" finds the turn about `cleanupPeriodDays` and the retention sweep, which shares no
word with the question. This is M14 in `plan-v0.md`; the decision to use a `llama-server` sidecar is
`decisions/0005-embedding-worker.md`, and the measurements behind it are in `embedding-spike.md`.

State on 2026-11-10: the engine can embed the archive and rank by meaning in a plain form, and it can measure itself on
an eval of 33 queries. The scorer that fuses meaning with words and can say "nothing found" is not built; the eval it is
tuned on now exists, and one change (a stopword list for keyword search) has been judged on it.

## What happens

```
segments (prompt, assistant, thinking, summary)
   │  archive.Chunk: pieces of at most 1,500 characters, cut at a paragraph, a line, a sentence
   ▼
chunks (segment, position, byte range, hash of the text)
   │  archive.Embed: every distinct text without a vector → llama-server → 768 numbers
   ▼
vectors (hash → 768 × float16, unit length)          meta.vector_source says what made them

query ──embed.Query──▶ vector ──cosine against every stored vector──▶ best piece per segment ──▶ hits
```

- **What gets a vector.** Prompts, replies, thinking and compaction summaries: what a person or the model wrote in
  sentences. Tool calls, tool results and injected context are left to keyword search. They are two thirds of all
  segments, they are JSON and command output, and what people look for in them (a path, an id, an error string) is what
  FTS5 already finds. A piece with fewer than sixteen letters ("ok", "continue") gets none: its vector sits close to
  every short query. Both choices are for the eval to confirm or overturn.
- **Pieces, not segments.** The model reads 2,048 tokens. A reply can be longer, and a long reply often changes subject.
  Each piece has its own vector, a hit is the segment's closest piece, and the snippet is that piece, so a subject in
  the last paragraph of a long answer is found and shown.
- **A text is embedded once.** A vector is stored under the hash of its text. Re-indexing a session replaces its
  segments and chunks but finds the vectors again, so a live session that grows only pays for what is new, and text that
  repeats across sessions is embedded one time.
- **One model per index.** `vector_source` names the model repository, revision, file, pooling, framing and dimension.
  If the code would embed with anything else, the stored vectors are dropped and made again; vectors from two sources
  are never compared.
- **Framing.** A document is embedded as `title: none | text: …` and a query as `task: search result | query: …`, as the
  model card prescribes.

## The sidecar

`skit` starts `llama-server` on `127.0.0.1` with a free port and a random key (passed in the environment, so it is not
in the process list), `--offline`, and the web UI off. It waits for `/health`, uses `POST /v1/embeddings`, and stops the
server when it is done. One sidecar belongs to one `skit` process:

- `skit embed`, `skit search --mode meaning` and `skit eval` start one for the command and stop it at the end. Starting
  it takes about half a second on an M4 Max.
- `skit serve` starts one with the first `/v0/search?mode=meaning` and stops it after ten minutes without a query, so
  the model (about 540 MB resident) is in memory only while someone is searching.
- A `skit` that is killed outright cannot stop its server. Each running sidecar has a small file in
  `~/.sessionkit/run/`; the next `skit` that starts one stops any whose owner is gone, after checking that the process
  id still belongs to a `llama-server`.

The binary is found at `$SKIT_LLAMA_SERVER`, beside the `skit` executable or in the app bundle's `Helpers`, or on `PATH`
(`brew install llama.cpp`).

## The one download

`skit embed` is the only command that uses the network, and only until the model is there: one file,
`embeddinggemma-2-Q8_0.gguf` (310 MB), from `huggingface.co/ggml-org/embeddinggemma-2-GGUF` at a pinned revision. It is
written to `~/.sessionkit/models/` as `.part`, resumes if interrupted, and takes its name only after its SHA-256 matches
the pinned one. A file that fails the check is not kept. No other command downloads: a meaning query before the model is
there says to run `skit embed`.

## Commands and routes

```
skit embed                      cut, embed, report; downloads the model the first time
skit embed --status             llama-server, the model file, how many texts have vectors; changes nothing
skit search --mode meaning …    rank by meaning; each hit has cosine and z
skit eval queries.json          R@1, R@5, R@10, MRR per mode and tag; --misses lists what did not come first
skit doctor                     has a "Meaning search" section (the same report as embed --status)
GET /v0/search?mode=meaning&q=  the same hits; 409 until `skit embed` has run, 503 if the sidecar cannot start
```

A hit says why it is there: `match` is `keyword` or `meaning`. A meaning hit carries `cosine` (similarity of its closest
piece) and `z` (how many standard deviations that stands above the mean over every piece scored for the query).

## The eval

"Measure before you tune" (`design-principles.md`): search quality is judged by queries whose answers are known, the
same file before and after a change.

```json
{
  "queries": [
    { "q": "why does my history vanish after a month", "expect": ["36086585@12"], "tag": "paraphrase" },
    { "q": "ENOTFOUND", "expect": ["36086585@40-42", "9cb29ba2"], "tag": "lookup" },
    { "q": "a recipe for dinner", "expect": [], "tag": "nothing" }
  ]
}
```

A target is a session id or a unique prefix, then `@N` for an agent turn of the main transcript (as
`skit show <id> --turn N` numbers them) or `@A-B` for a range; without `@`, any hit in the session counts. Reaching any
one target is enough. Places are counted in distinct turns, so several segments of one turn take one place. A query with
an empty `expect` should find nothing, and the report says how many of those got an answer anyway. Every target must
resolve to an archived session or the eval stops before it runs.

Two more fields. `"exclude": ["a9534066"]` beside `queries` lists session id prefixes whose hits are dropped before
anything is counted: the sessions in which the queries were written quote every query word for word, so they would come
first for each one and answer the queries that should find nothing. A query may carry a `"note"` for whoever maintains
the file; it is not scored.

## Measured so far

On Juan's MacBook Pro (M4 Max), llama.cpp 0.9.0, a copy of the archive made on 2026-11-10:

| Measurement                                       | Result                                                      |
| ------------------------------------------------- | ----------------------------------------------------------- |
| Archive                                           | 13 sessions, 4,167 segments                                 |
| Segments that get vectors                         | 1,053 (337 prompts, 572 replies, 142 thinking, 2 summaries) |
| Pieces                                            | 1,373, of which 1,367 distinct                              |
| `skit embed`, everything, including sidecar start | 12.9 s (106 texts a second)                                 |
| Vectors on disk                                   | 2.1 MB (1,536 bytes each)                                   |
| `skit search --mode meaning`, whole command       | 0.5 s                                                       |

The plain ranking is not good enough to ship as the default, and the numbers say why. On five questions typed by hand,
related and unrelated ones came back with first hits in the same narrow band: cosine 0.74 to 0.78 and z 3.4 to 4.7 for
questions the archive answers, cosine 0.67 to 0.68 and z 3.3 to 3.6 for "a recipe for dinner" and "kubernetes pod
eviction policy". DigUp's gate of z ≥ 2 would let all of them through, as the spike predicted. That is five queries and
an impression, not an eval.

## The eval so far

Since 2026-11-10 there is an eval: 33 queries about Juan's sessions, 26 with a known turn and 7 that should find
nothing. Thirteen are Juan's own; twenty were proposed in other styles (a few keywords, another person's sentence, a
bare id) and approved by him. The file is kept outside this repository because it quotes real sessions. The session in
which it was written is excluded: before that, it was the first keyword hit for 12 of 12 queries.

| Mode                            | R@1  | R@5  | R@10 | MRR  | "Nothing" queries answered |
| ------------------------------- | ---- | ---- | ---- | ---- | -------------------------- |
| keyword, as first built         | 0.42 | 0.65 | 0.81 | 0.51 | 6 of 7                     |
| keyword, with the stopword list | 0.58 | 0.69 | 0.81 | 0.64 | 5 of 7                     |
| meaning (plain cosine)          | 0.65 | 0.77 | 0.81 | 0.71 | 7 of 7                     |

**The stopword list** (first scoring change judged on the eval). A question typed in full used to match every "how" and
"out" in a tool result. With the common English function words ignored, six queries moved up (four of them to first
place) and one fell out of the first ten: "What did we decide was the issue for schoolwork and not turning it in
early?", whose answer shares only one or two of its remaining words and no longer passes the half-of-the-words rule.
Meaning search has that one in second place.

What the eval shows that the scorer has to deal with:

- Neither mode can say "nothing found". That is the gate.
- Each mode finds turns the other misses, which is the case for fusing them.
- A bare version number ("0.5.1") finds nothing by keyword: the dots split it into single characters, which are dropped.
- Two answers are only in tool output, which has no vectors: the one-line description of a tool in its `--help`, and a
  definition in a file a session read.
- The user's name for a thing is often not the transcript's ("my jev assignment" is "the SLT" in the turn that holds the
  grade).

## What is not built

- **The scorer.** Fusing meaning with keyword scores, the gate (z, an absolute cosine floor, or both) and a `hybrid`
  mode. It is tuned on the eval, and each change carries its delta.
- **Vectors for tool calls.** Tool calls and results have none. First step: embed tool output that reads as prose. Then,
  issue #4: a small local model writes what a call did, and that summary is embedded with the call.
- **Embedding without being asked.** Today `skit embed` is run by hand after `skit archive`. The watcher and the
  background agent do not embed. Deferred to issue #3: the agent embeds on its own, periodically.
- **Vectors held in memory by `skit serve`.** Each meaning query reads and decodes every vector from SQLite, which is
  milliseconds for thousands of pieces and will not be for hundreds of thousands.
- **A hermetic end-to-end test of the real binary.** The pinned model is 310 MB, so `test/integration` cannot run
  `skit embed`. The commands are tested in process with a stand-in for `llama-server` and a small file in place of the
  model; `just test-model` runs the real server with the real model against recorded reference vectors.
- Images and audio (ADR 0005, tier C).
