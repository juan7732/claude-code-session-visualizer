# 0008 · The archive never shrinks

Date: 2026-11-10. Status: accepted.

**Context.** Tenet 1 says we never lose a session. A review on 2026-11-09 found three ways the archive could, each
reproduced with the synthetic fixture:

1. **The source shrank.** A transcript that got shorter made `archive` rewrite the copy in place, from 31 lines to 5.
2. **A write was torn.** Bytes left at the end of a copy by a crash or a full disk stayed there, the next frame was
   appended after them, and the copy stopped decoding at the tear.
3. **`list` hid growth.** `list` refreshes a row's source fingerprint as its cache key. `archive` read the same
   fingerprint as "already copied", so lines added between an archive and a `list` were never copied. With `serve` this
   is the normal order of events: the client lists, then the watcher archives.

**Decision.** The raw copy follows three rules, implemented in `sessionkit/archive/copy.go`.

- **The index records what the copy is,** apart from what the source looks like: the copy's size on disk, a hash of the
  last 64 KiB of source it covers, and the source fingerprint it was made from (index schema 3). "Unchanged" means that
  fingerprint matches and the copy is still that size.
- **An append is checked first.** The source must still contain the hashed bytes at the same offset. A copy longer than
  recorded is cut back to the recorded size, provided what remains still decodes to what was archived. Otherwise the
  copy is rewritten.
- **A rewrite is atomic and never discards more than it writes.** It goes to a temp file, is synced, and is renamed over
  the copy. If the copy it replaces holds more lines, belongs to a source that has since diverged, or no longer decodes,
  that copy is renamed to `<copy>.prev-<UTC time>` and kept. skit never deletes it. The one exception is
  `--strip-requests` on a lossless copy, where a smaller copy is what was asked for.

Subagent transcripts follow the rewrite rule. Other companion files (spilled tool outputs, `meta.json`) are written
through a temp file when their bytes differ. One archive lock (`~/.sessionkit/archive.lock`) keeps a manual
`skit archive` and `skit serve` from writing the same copy at once.

`skit archive --verify` (and `GET /v0/archive/verify`) decodes every copy and compares it with the index: `ok`,
`missing`, `corrupt` with the number of readable lines, or `mismatch`. It changes nothing and exits non-zero on any
problem.

**Consequences.** Rows from schema 2 know none of the three facts, so their first ingest after the upgrade rewrites the
copy under the length check; nothing is lost and it happens once. `.prev-` files accumulate only when a source really
shrank or was replaced; they are plain zstd (`zstd -dc`) and are listed by `--verify`. Nothing reads them back
automatically: deciding which copy is the session is left to the user. Since 2026-11-10 the copy also takes the bytes
after the last newline, so it is an exact prefix of the source at every moment: a line that never got its newline (a
crash mid-write, a file with no final newline) is archived as it stands, and when the source grows the next append
continues it byte for byte. The parser counts such a last line as a record when it is a whole JSON value and reports the
session as partial when it is not.
