# Archive sizing

Implemented in M3: raw lines zstd-compressed per session under `~/.sessionkit/archive/`, appended by byte offset as a
session grows. Since ADR 0007 the copy is lossless including the `api-request*` records (`--strip-requests` drops them);
the index in `skit.sqlite` holds one row per content block for FTS5. Measured 2026-11-09 on 11 sessions: source
transcripts 107 MB, archive 16 MB without request records, 26 MB with them.

Measured on this Mac, 2026-11-07, 8 sessions, 827 requests.

|                                                                                | per request          | notes                                                        |
| ------------------------------------------------------------------------------ | -------------------- | ------------------------------------------------------------ |
| Raw transcript on disk                                                         | ~57 KB               | 47.5 MB / 827 requests                                       |
| What the archive keeps (user, assistant, system, attachment, metadata records) | ~34 KB               | 27.8 MB; drops `api-request*`, queue, bridge, latch records  |
| Of which images                                                                | ~7 KB avg, but lumpy | 5.6 MB in 4 of 8 sessions; one 165-prompt session had 3.6 MB |
| Prose (text + thinking blocks)                                                 | ~1 KB                | 0.9 MB total. Tiny.                                          |
| Tool result text                                                               | ~2 KB                | 1.8 MB total                                                 |

Per-session raw sizes ranged from 0.3 MB (short) to 18 MB (a week-long session with 224 requests, or a 165-prompt
session). The rest of a transcript's bytes are JSON envelope and duplicated usage objects.

## Projections

Assume a heavy day is 300 requests (the busiest observed session averaged ~50 requests per active day, and
`stats-cache.json` shows up to 689 messages in one day).

| Usage                               | Raw transcripts | Archive (kept records) | Archive + index |
| ----------------------------------- | --------------- | ---------------------- | --------------- |
| Light: 30 requests/day, 250 days    | 430 MB/yr       | 255 MB/yr              | ~300 MB/yr      |
| Typical: 100 requests/day, 250 days | 1.4 GB/yr       | 850 MB/yr              | ~1 GB/yr        |
| Heavy: 300 requests/day, 250 days   | 4.3 GB/yr       | 2.6 GB/yr              | ~3 GB/yr        |

Index overhead: one fp16 vector is 1.5 KB; at ~3 segments per request (prompt, reply, one tool call) that is ~5 KB per
request, plus FTS5 at roughly the size of the text it indexes (~3 KB per request). Call it 8 KB per request, ~25% on top
of the kept records.

## Choices that change the numbers

- **Raw lines are stored, all of them (decided 2026-11-08; request records added 2026-11-09, ADR 0007).** The archive
  keeps the original JSONL lines, compressed with zstd, including the `api-request*` records that explain what the model
  received. `--strip-requests` drops those for a smaller copy. Lossless is the point; even the heavy projection stays
  within a few GB a year.
- **Images.** Store as-is (they are already compressed PNG/JPEG) plus a small thumbnail. They dominate when present. An
  option to downscale images over, say, 2 MB keeps outliers in check.
- **Debug mode on** roughly doubles the per-request size (the full request body is stored by Claude Code per request).

Bottom line: a decade of heavy use fits in ~30 GB, a decade of typical use in ~10 GB. Disk is not the constraint;
ingesting before the 30-day sweep is.
