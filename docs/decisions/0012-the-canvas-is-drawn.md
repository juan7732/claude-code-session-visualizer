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

**The Score, on the same view (M12, 2026-11-10).** The camera, the events, the background, the glyph cache and the
selection rings moved into a base class (`CanvasNSView`); the Braid and the Score are subclasses that say what is drawn
under the camera, what stays put over it (the Score's ruler and row names) and what is under a point. The Score has no
content step: its layout is made whole, off the main thread, in 7 to 14 ms, and again when the time scale changes.
Measured the same way with `--measure-canvas <id> --score`, a pan through the whole session:

| Session                                                | near, 130 %    | near, 80 %    | mid, 50 %    | far, 25 %    |
| ------------------------------------------------------ | -------------- | ------------- | ------------ | ------------ |
| 165 turns, 346 actions, 129 idle bands, 3456 × 2000 px | 10.1 / 12.0 ms | 9.8 / 10.9 ms | 7.7 / 9.0 ms | 6.0 / 6.5 ms |
| 31 turns, 255 actions, 498 tool calls, 3456 × 2000 px  | 8.0 / 10.5 ms  | 7.7 / 9.3 ms  | 5.8 / 6.7 ms | 4.3 / 4.6 ms |
| 27 turns, 2 subagents, 7 background tasks, 3456 × 2000 | 10.0 / 11.4 ms | 9.7 / 10.6 ms | 7.2 / 7.9 ms | 5.1 / 5.5 ms |

Inside a 60-a-second frame, not inside a 120-a-second one (8.3 ms) up close. What it took to get there: the hatch of
every idle band in one path, cut to the band by arithmetic and not by a clip; plain lines for dashes that are under a
pixel; steps of the background colour for the fades behind the ruler and the row names, where gradients cost a fifth of
the frame. What is left is about a third nodes, a third bands, a fifth the overlays.
