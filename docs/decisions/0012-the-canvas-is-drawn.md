# 0012 · The canvas is drawn by one view

Date: 2026-11-10. Status: accepted.

**Context.** The Canvas (M10) shows a session as cards joined by arrows on a surface that pans and zooms from 6 % to 400
%. The largest session here has 346 steps in 165 turns and lays out 37,800 points tall. The plan asked for a spike
before the view: camera, three levels of detail, a deterministic layout, and what holds 60 frames a second. The plan's
first idea was drawn marks when zoomed out and real SwiftUI views when zoomed in.

**Decision.**

- **One AppKit view draws everything** (`BraidCanvasNSView`: Core Graphics and Core Text in `draw`), under the camera's
  transform, and only what is in view. No SwiftUI views for the cards. A SwiftUI view under `scaleEffect` is a scaled
  picture of itself, so text blurs when zoomed in; drawn text is set again at every zoom. Scroll, pinch, drag, hover,
  right-click and keys are native events in the same view, which SwiftUI does not all offer on the Mac.
- **Text is broken into lines once per session** (`LaidText`), off the main thread. A card's height follows from its
  lines, so the layout is computed, never measured after a first paint as the mock does, and is the same every time.
  What each node says (`BraidContent`) is built once; where each node is (`CanvasLayout`) is recomputed when a turn
  collapses, which takes under a millisecond.
- **Three levels of detail by zoom**, at the mock's thresholds: below 38 % cards are marks with at most a title, to 62 %
  titles and chip names, above it everything.
- **The frame is drawn on the CPU and not cached.** No tiles, no layer per card.

**Consequences.** Measured with `SessionVisualizer --measure-canvas <id>` (release build, offscreen, 2x), median and
95th percentile per frame along a pan of the whole session:

| Session                                                | near, 100 %  | mid, 50 %    | far, 25 %    |
| ------------------------------------------------------ | ------------ | ------------ | ------------ |
| 165 turns, 346 steps, 3000 × 1800 px                   | 5.3 / 7.1 ms | 3.8 / 6.0 ms | 2.0 / 2.2 ms |
| 31 turns, 255 steps, 498 tool calls, 3456 × 2000 px    | 7.4 / 8.8 ms | 6.3 / 7.6 ms | 2.2 / 2.6 ms |
| 27 turns, 2 subagents, 7 background tasks, 3456 × 2000 | 7.4 / 9.6 ms | 6.2 / 8.3 ms | 2.5 / 2.7 ms |

A frame at 60 a second has 16.7 ms. Building the content took 26 to 64 ms once per session. The worst single frames (12
to 30 ms) were the first use of a glyph. Not measured: the window server putting the frame on screen, and a hand on a
trackpad. The cost of this choice: the cards are not accessibility elements and VoiceOver reads nothing on the Canvas
(the accessibility pass was declined on 2026-11-09; the Transcript shows the same session as real views). If frames ever
cost too much, the next step is to keep the drawn cards as images per level of detail, not to change the approach. The
Score (M12) and the Timeline (M11) can draw on the same view with a different layout.
