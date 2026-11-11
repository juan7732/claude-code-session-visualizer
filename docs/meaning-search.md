# Meaning search

Keyword search finds a turn when you remember its words. Meaning search finds it when you remember what it said: "why
does my history vanish after a month" finds the turn about `cleanupPeriodDays` and the retention sweep, which shares no
word with the question. This is M14 in `plan-v0.md`; the decision to use a `llama-server` sidecar is
`decisions/0005-embedding-worker.md`, and the measurements behind it are in `embedding-spike.md`.

State on 2026-11-10: the engine half of M14 is built. It embeds the archive and keeps it embedded without being asked,
ranks by meaning, says when nothing in the archive is close enough, offers `hybrid` (meaning first, then the words),
which beats keyword search on every measure of the eval, and measures itself on that eval of 53 queries.

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
- `skit serve` starts one with the first `/v0/search?mode=meaning` or `hybrid` and stops it after ten minutes without a
  query, so the model (about 540 MB resident) is in memory only while someone is searching.
- `skit serve` also starts one for its background pass (below) when there is text to embed, and stops it when the pass
  ends, unless a search had it running already.
- A `skit` that is killed outright cannot stop its server. Each running sidecar has a small file in
  `~/.sessionkit/run/`; the next `skit` that starts one stops any whose owner is gone, after checking that the process
  id still belongs to a `llama-server`.

The binary is found at `$SKIT_LLAMA_SERVER`, beside the `skit` executable or in the app bundle's `Helpers`, on `PATH`,
or where Homebrew puts it (`/opt/homebrew/bin`, `/usr/local/bin`; `brew install llama.cpp`). The last two are named
outright because the background agent runs under launchd, whose `PATH` has no Homebrew in it: without them meaning
search worked from a shell and failed from the app.

## Kept current without being asked

`skit serve`, which the background agent runs from login on, embeds new text by itself: once its first sweep of the
archive has finished and then every thirty minutes (`--embed-every`; 0 turns it off). A pass first asks the index
whether any text lacks a vector, which needs no model; only if some does is the sidecar started, and it is stopped when
the pass ends. A pass never downloads: until `skit embed` has fetched the model once, it does nothing and says why in
the log, once and not at every interval. It runs on a period and not on every change, so a transcript that grows every
few seconds does not load the model every few seconds. `skit doctor`, `skit embed --status` and `/v0/status` say how
many texts have vectors and when they were last brought up to date. On this archive a pass with 61 new texts took one
second.

## Vectors in memory

A CLI meaning query reads every vector out of SQLite and is done. `skit serve` keeps them: 1,536 bytes a piece, as the
half floats they are stored as, scored through a lookup table. It reads the index again only when the index says the
vectors changed (a counter in the index that moves when chunks or vectors are written or removed, so a change made by
another process is seen too), and lets the memory go after ten minutes without a meaning query. Measured with random
vectors on the M4 Max, one query, nearest ten:

| Pieces  | Read from the index each time | Held in memory |
| ------- | ----------------------------- | -------------- |
| 2,000   | 15 ms                         | 1.6 ms         |
| 20,000  | 213 ms                        | 15 ms          |
| 100,000 | 1.3 s                         | 79 ms          |

This archive has about 1,460 pieces (2.2 MB); a heavy year is estimated at 225,000 (about 350 MB held while searching).

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
skit search --mode meaning …    rank by meaning; each hit has cosine and z; nothing is returned when nothing is close
                                enough (--all returns the nearest anyway; --min-cosine, --min-z move the gate)
skit search --mode hybrid …     meaning matches first, nearest first, then the keyword hits not among them
skit search … --session ID --project P --kind K1,K2 --no-tools
                                narrow either mode: one session (id or prefix), a project, some kinds, no tool calls
skit eval queries.json          R@1, R@5, R@10, MRR per mode and tag; --misses lists what did not come first
skit doctor                     has a "Meaning search" section (the same report as embed --status)
GET /v0/search?mode=meaning&q=  the same hits (mode=hybrid too); 409 until `skit embed` has run, 503 if the sidecar
                                cannot start;
                                session=, project=, kind=a,b, tools=0, all=1, min_cosine=, min_z= as on the CLI
```

**What a hit is.** One segment: a prompt, a piece of reply text, a thinking block, a tool call, a tool result, an
injected context block or a compaction summary. It carries its session, its agent turn and its action, so a face can
open the exact place. In meaning mode a segment is represented by its closest piece, and tool calls, tool results and
context have no vectors, so they never appear. Keyword mode searches every kind; `--no-tools` leaves tool calls and
their results out.

**Hybrid.** First the segments that pass meaning search's gate, nearest first; then the keyword hits that are not among
them, in keyword order. `match` says which a hit is: `meaning`, `keyword`, or `both` for a segment found both ways,
which is listed once, among the meaning hits, with the keyword snippet that shows the words. Keyword stays its own mode
and the default (decided 2026-11-10).

**The gate.** A piece is a match when its cosine reaches 0.73. Below that it is only the nearest thing in an archive
that has nothing on the subject, and it is not returned: the answer is an empty list. A query that is only an id or a
version ("v3.2.1", "JIRA-4821") matches a piece only when the piece contains it. `z` is still reported on every hit, and
is taken over every piece in the index even when the search is narrowed to a session or a kind, but it no longer decides
anything by default (see "The eval so far").

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

Since 2026-11-10 there is an eval, kept outside this repository because it quotes real sessions. It began with 33
queries (26 with a known turn, 7 that should find nothing) and has 53: twenty more that should find nothing were added
to test the gate. Thirteen queries are Juan's own; the rest were proposed in other styles (a few keywords, another
person's sentence, a bare id) and approved by him. The session in which it was written is excluded: before that, it was
the first keyword hit for 12 of 12 queries. The archive under it is live, so numbers taken hours apart can differ by a
query.

The first 33:

| Mode                            | R@1  | R@5  | R@10 | MRR  | "Nothing" queries answered |
| ------------------------------- | ---- | ---- | ---- | ---- | -------------------------- |
| keyword, as first built         | 0.42 | 0.65 | 0.81 | 0.51 | 6 of 7                     |
| keyword, with the stopword list | 0.58 | 0.69 | 0.81 | 0.64 | 5 of 7                     |
| keyword, versions kept whole    | 0.62 | 0.73 | 0.85 | 0.68 | 5 of 7                     |
| keyword, without tool calls     | 0.65 | 0.69 | 0.69 | 0.67 | 4 of 7                     |
| meaning (plain cosine)          | 0.65 | 0.77 | 0.81 | 0.71 | 7 of 7                     |
| meaning, with the gate          | 0.65 | 0.77 | 0.77 | 0.70 | 0 of 7                     |

**The stopword list** (first scoring change judged on the eval). A question typed in full used to match every "how" and
"out" in a tool result. With the common English function words ignored, six queries moved up (four of them to first
place) and one fell out of the first ten: "What did we decide was the issue for schoolwork and not turning it in
early?", whose answer shares only one or two of its remaining words and no longer passes the half-of-the-words rule.
Meaning search has that one in second place.

**Versions kept whole.** "0.5.1" found nothing by keyword: the dots split it into single characters, which were dropped.
A version, a date or a numbered name ("0.5.1", "2026-11-10", "issue-3") is now one term, searched as a phrase. One query
moved from not found to first; nothing else moved.

**The gate.** Without it, the nearest piece to a query the archive has nothing on had cosine 0.649 to 0.724 and z 2.95
to 3.59; the right first hit for a query it does answer had cosine 0.707 to 0.883 and z 3.68 to 9.38. "Cosine ≥ 0.73 or
z ≥ 3.6" gives none of the seven an answer and leaves R@1 and R@5 where they were. R@10 loses one query whose right turn
sat in eighth place below the gate. An answerable query now shows 5 hits at the median instead of every piece in the
index. Either test alone costs more:

| Gate                     | R@1  | R@5  | R@10 | "Nothing" answered | Answerable queries left with no hit |
| ------------------------ | ---- | ---- | ---- | ------------------ | ----------------------------------- |
| none                     | 0.65 | 0.77 | 0.81 | 7 of 7             | 0                                   |
| cosine ≥ 0.70            | 0.65 | 0.77 | 0.77 | 3 of 7             | 0                                   |
| cosine ≥ 0.73            | 0.62 | 0.73 | 0.73 | 0 of 7             | 2                                   |
| cosine ≥ 0.75            | 0.58 | 0.58 | 0.58 | 0 of 7             | 8                                   |
| z ≥ 2.0 (DigUp's)        | 0.65 | 0.77 | 0.81 | 7 of 7             | 0                                   |
| z ≥ 3.3                  | 0.65 | 0.73 | 0.73 | 2 of 7             | 1                                   |
| z ≥ 3.6                  | 0.65 | 0.73 | 0.73 | 0 of 7             | 3                                   |
| cosine ≥ 0.73 or z ≥ 3.6 | 0.65 | 0.77 | 0.77 | 0 of 7             | 0                                   |

Two cautions. The margins are thin (0.724 against 0.73, 3.59 against 3.6) and seven queries drew the line: more queries
that should find nothing are the first thing that should move these values. And z does not hold still as an archive
grows: the largest of n unrelated scores rises with n (about √(2 ln n) standard deviations for a bell curve, 3.8 at
1,400 pieces and 5.0 at 225,000), so a fixed z gate lets more noise through in a larger archive. The cosine floor does
not drift that way.

**The gate, tested and changed.** Both cautions came true within the hour. Twenty new queries with no answer were run
unseen: five about subjects no session touches, seven technical ones the archive does not hold (two of them bare ids),
and eight near misses, which ask about something next to a real subject (a grade for a class not yet taken, Windows
support for a tool that has none). The columns after R@5 count the queries that got an answer and should not have:

| Gate                                         | R@1  | R@5  | first seven | far    | absent | near miss |
| -------------------------------------------- | ---- | ---- | ----------- | ------ | ------ | --------- |
| none                                         | 0.65 | 0.77 | 7 of 7      | 5 of 5 | 7 of 7 | 8 of 8    |
| cosine ≥ 0.73 or z ≥ 3.6 (the first version) | 0.65 | 0.77 | 0 of 7      | 3 of 5 | 2 of 7 | 6 of 8    |
| cosine ≥ 0.73                                | 0.62 | 0.73 | 0 of 7      | 0 of 5 | 2 of 7 | 6 of 8    |
| cosine ≥ 0.73, a bare id must appear (now)   | 0.62 | 0.73 | 0 of 7      | 0 of 5 | 0 of 7 | 6 of 8    |
| cosine ≥ 0.75                                | 0.58 | 0.58 | 0 of 7      | 0 of 5 | 1 of 7 | 2 of 8    |

- **The z test was the leak.** "mortgage refinance rate" has cosine 0.65 and z 3.69. The cosine floor alone stopped
  every far and every absent query written in sentences.
- **A bare id is matched by its characters.** "v3.2.1" sits at cosine 0.76 from a turn about 0.5.1 and v0.6.0. Requiring
  the id to appear stops both id queries and loses no right answer.
- **What the floor costs.** One right first hit: "denelon", a query that is only a name (cosine 0.707). Keyword search
  finds it first, which is what `hybrid` is for.
- **A threshold cannot tell a near miss from an answer.** "How did we fine-tune the embedding model on my own sessions?"
  (never done) scores 0.775 against a turn about measuring it, above several right answers. The vector says "same
  subject", not "answers this". A floor high enough to stop the near misses halves recall. They are tagged `near-miss`
  in the eval and reported apart: the hits they get are related passages, which a search tool may fairly show, and
  telling them from answers needs a model that reads the query and the passage together (a reranker). Decided
  2026-11-10: live with it for now.

On all 53, as of this change: keyword R@1 0.62, R@5 0.69, R@10 0.85, MRR 0.66, answering 14 of 19 "nothing" queries and
8 of 8 near misses; meaning R@1 0.62, R@5 0.73, R@10 0.73, MRR 0.66, answering 0 of 19 and 6 of 8.

**Without tool calls.** Keyword search answers most "nothing" queries from tool output, where every common word turns
up. Leaving tool calls out puts one more right turn first and loses four that were found lower down through what a tool
printed. It is a filter for the user (`--no-tools`), not the default.

**Hybrid** (the measure M14 is done by: hybrid beats keyword on the eval). On the 53, with 26 answerable:

| Mode                                | R@1  | R@5  | R@10 | MRR  | "Nothing" answered | Near misses answered |
| ----------------------------------- | ---- | ---- | ---- | ---- | ------------------ | -------------------- |
| keyword                             | 0.62 | 0.77 | 0.85 | 0.68 | 14 of 19           | 8 of 8               |
| meaning                             | 0.62 | 0.73 | 0.73 | 0.66 | 0 of 19            | 6 of 8               |
| hybrid: meaning first, then keyword | 0.69 | 0.81 | 0.88 | 0.75 | 14 of 19           | 8 of 8               |

Tried and not kept, same queries: reciprocal-rank fusion of the two lists (R@1 0.62, R@5 0.77, R@10 0.92, MRR 0.69); a
weighted sum of a normalised cosine and the keyword score over a grid of weights (R@1 0.62 to 0.65, MRR 0.68 to 0.71);
segments found both ways first (R@1 0.65, MRR 0.72). One list after the other wins because of the gate: what passes it
is short (a median of four segments a query) and usually right, so it can go first whole, and the keyword list catches
what meaning cannot reach: a name, an id, text inside tool output. Against keyword alone, five queries moved up and two
moved down, one of them out of the first ten. Differences between the fusion rules are one or two queries out of 26, so
the simplest rule that a person can predict was taken.

Hybrid cannot say "nothing found" any more than keyword can. When no passage is close in meaning, the keyword hits are
all there is, and for a subject the archive lacks they are tool output that shares a few common words. A face can tell:
no hit is marked `meaning` or `both`. Counting matched words by how rare they are was tried on the keyword side and cut
14 of 19 to 9 of 19, at the cost of right answers (R@10 0.85 to 0.81); not kept.

What the eval shows that is still open:

- Keyword mode cannot say "nothing found": 14 of 19 get an answer, mostly from tool output.
- Each mode finds turns the other misses, which is the case for fusing them.
- Two answers are only in tool output, which has no vectors: the one-line description of a tool in its `--help`, and a
  definition in a file a session read.
- The user's name for a thing is often not the transcript's ("my jev assignment" is "the SLT" in the turn that holds the
  grade).

## What is not built

- **Meaning outside the Search page.** The Finder offers Keyword, Hybrid and Meaning; find in a session (⌘F), the
  Summary's search box and ⌘K are keyword only.
- **Vectors for tool calls.** Tool calls and results have none. First step: embed tool output that reads as prose. Then,
  issue #4: a small local model writes what a call did, and that summary is embedded with the call.
- **A near miss gets related hits**, and keyword and hybrid answer questions about absent subjects from tool output.
  Both need a model that reads the query and the passage together (`roadmap.md`, "Models on top of the archive").
- **A hermetic end-to-end test of the real binary.** The pinned model is 310 MB, so `test/integration` cannot run
  `skit embed`. The commands are tested in process with a stand-in for `llama-server` and a small file in place of the
  model; `just test-model` runs the real server with the real model against recorded reference vectors.
- Images and audio (ADR 0005, tier C).
