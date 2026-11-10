# skit docs

Source of truth for the project. Start with `tenets.md`, then `design-principles.md`, `architecture.md` and
`plan-v0.md`.

Everything written here about the transcript format was observed on Claude Code 2.1.289 to 2.1.319 (macOS, VS Code
extension) and checked against the official docs at code.claude.com. The format is undocumented and changes; the parser
eval is what keeps these notes honest.

| File                       | What                                                                          |
| -------------------------- | ----------------------------------------------------------------------------- |
| `tenets.md`                | Tenets: beliefs that break ties when we decide, Amazon style                  |
| `design-principles.md`     | How skit is built: the design and engineering principles                      |
| `architecture.md`          | Packages, boundaries, data flow, testing, conventions                         |
| `plan-v0.md`               | The plan: milestones M0 to M14 (v0 ends at M9) and confirmed choices          |
| `roadmap.md`               | Ideas grounded in what the session files contain                              |
| `decisions/`               | Architecture decision records                                                 |
| `where-sessions-live.md`   | `~/.claude` layout, what a "project" is, retention, purge                     |
| `record-anatomy.md`        | Every record type, the envelope, the uuid tree, request splitting, compaction |
| `stats-and-cost.md`        | Usage fields, Claude Code's own cost records, what to compute                 |
| `working-with-sessions.md` | Parsing rules, hooks, resume, debug mode                                      |
| `subagents.md`             | Subagent transcripts and how they link to the parent                          |
| `images-and-modalities.md` | How images land in a session; the three embedding tiers                       |
| `archive-sizing.md`        | Measured sizes and long-term projections                                      |
| `embedding-spike.md`       | EmbeddingGemma 2 on llama.cpp measured on this Mac; what it decided           |
| `meaning-search.md`        | Search by meaning: chunks, vectors, the sidecar, the eval, what is not built  |
