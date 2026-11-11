# Performance

Voges Word has to stay responsive on long documents. This page records how
we measure it, what the numbers were before the work on long documents and
after it, and what is left to do.

## How to measure

`benchmark/long_document.dart` runs the real app with its whole interface,
opens a synthetic novel of 869 pages (72 chapters, 8209 paragraphs,
2.2 million characters) the way the system hands a file over, and drives it
with the messages the system's text input sends.

```sh
flutter build macos --profile -t benchmark/long_document.dart
open -g -n "build/macos/Build/Products/Profile/Voges Word.app" \
  --env BENCH=quiet --stdout /tmp/long.txt --stderr /tmp/long-errors.txt
```

`BENCH` takes options separated by commas: `quiet` (no window focus),
`chapters=N`, `nospell`, `justify` (justified body text with 1.5 lines, so
each chapter is one block of the editor), `repeat=N`, and the groups of steps
to run (`type`, `keys`, `pointer`, `scroll`, `shell`). The app quits by
itself; the last line of the output is `idle after everything`.

Each step prints how long it took, the longest frame it held the app for and
the build and raster times of its frames. Steps made of keys or clicks also
print, for each one, the time until the app answered and until the frame
with the result was built.

To see where the time goes, sample the main thread of the profile build
with `sample <pid> <seconds> 1 -file <file>` while a step runs, and
symbolize the Dart frames with the `App.framework.dSYM` of the same build.

## Before and after

On a MacBook Pro with an M1 Pro, the 869-page book, spell checking on.
"Frame" is the time from the key to the frame showing its result, as the
average of the step. The machine was shared with other work, so the numbers
after vary by a few tens of milliseconds from run to run; the higher ends
are from runs with the machine busy.

| Step | Before | After |
| --- | --- | --- |
| Type a character, frame | 1100–1230 ms | 20–60 ms |
| Type a character, app answers | 75–95 ms | 4–14 ms |
| Move the caret to another paragraph | 970–1170 ms | 15–45 ms |
| Enter in the middle | 1100 ms | 35–65 ms |
| Backspace in the middle | 1120 ms | 50–65 ms |
| Arrow keys | 1000–1070 ms | 20–35 ms |
| Cmd down and up | 1960 ms | 30–45 ms |
| Click on the text | 1100 ms | 45 ms |
| Select all | 1100 ms | 400–700 ms |
| Text sent to the system per key | 2155 KB | 2 KB |
| After opening, until no frame takes 100 ms | over 120 s, frames up to 1.9 s | 6–16 s, frames up to 60 ms |
| Pause after editing (word count, recovery copy) | a frame of 1.2 s | nothing over 35 ms |
| Opening, first frame | 1.7 s | 1.7 s |
| Zoom from 100% to 110% | 1.9 s | 1.9–2.9 s |

With justified text, where each chapter is one block, typing takes 64–80 ms
to the frame and Enter about 60 ms; before the change to blocks, every Enter
built the whole chapter again.

## What changed

- The editor keeps the widget of every paragraph and builds again only the
  ones whose node, neighbors, part of the selection or composing range
  changed (`NodeWidgetCache`, node revisions). Paragraphs are keyed by their
  node.
- Enter inside a block keeps the block node, when Quill would end with the
  same block anyway.
- The app gives the editor callbacks made once, and the spell checker's
  answers rebuild only the paragraphs they are for (`SpellingScope`).
- On macOS the spell check finds only where the mistakes are; suggestions
  are found when the menu of a word opens. Batches are announced one by one
  and kept to 2000 characters.
- Cmd and Control rebuild only paragraphs with links.
- The rule that makes links reads only the paragraph around the key.
- Composing a change into the document's delta keeps the operations the
  change does not touch.
- The system's text input gets about a thousand characters on each side of
  the selection instead of the whole document.
- No selection overlay is made for a caret on a computer.
- A paragraph that crosses a page bottom is laid out again only when it
  changes or moves; it was laid out twice and painted on every key.
- Deletions from the keyboard and caret moves no longer copy and compare the
  whole text.
- The word count of the status bar and the recovery copy run on other
  isolates.

## What is left

Ordered by what they cost on the long book.

1. **The spell check holds the main thread.** `NSSpellChecker` runs on the
   thread the interface runs on: about half of it for the first seconds
   after a long book opens, at 30 frames a second. Checking with
   `requestChecking(of:range:types:options:inSpellDocumentWithTag:)`, which
   runs in the background, would free it; its results and the choice of
   language need comparing with the current ones first.
2. **Select all builds and paints every paragraph** (400–700 ms), since each
   paragraph draws its own part of the selection.
3. **Every build of the editor walks every paragraph.** Looking up the kept
   widgets and updating the children list cost a few milliseconds per frame
   on 8209 paragraphs, and `RenderEditor` composites every paragraph's layer
   whenever it paints. Painting only the paragraphs on screen, and grouping
   paragraphs so that a build visits only the group that changed, would
   make both depend on the screen instead of the book.
4. **Zoom and opening lay out the whole book** (about 2 s each).
5. **Each layout of the page walks every paragraph** to place it, even when
   only one changed; it could stop where nothing moved.
6. **Rules read the document's delta from the start for Enter**
   (`DeltaIterator(document.toDelta())`), and the caret's rectangle is
   looked up child by child after every frame.
7. **Memory**: the book takes about 1 GB.
