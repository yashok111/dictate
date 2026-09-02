# Native UI — hotkeys, banner, auto-paste, menubar

Deep dive moved out of `CLAUDE.md`. Read this before touching `DictateController`'s UI:
hotkey registration, the banner panel, `paste_text`, or the status item.

The daemon is fully self-contained; `DictateController` (the `NSApp` delegate) owns
all UI on the **main thread**:

- **Hotkey**: `RegisterEventHotKey(kVK_ANSI_D=2, ⌘⇧)` toggles a take — keycode 2 is
  the physical D key, so it survives a Cyrillic layout (and needs no Accessibility).
  A second hotkey for **Esc** is registered only for the duration of a take (so Esc
  stays normal everywhere else) and cancels it. A **third**, ⌥⌘⇧D (id 3), restarts the daemon
  and — unlike ⌘⇧D — is **never unregistered**, not even while the editor is open: it covers a
  daemon that is stuck but still pumping its run loop, and the menubar ⟳ item it duplicates is
  unreachable whenever macOS parks the status item off-screen (see Menubar below). All three die
  with the process. **It is NOT an escape hatch from a wedged main thread**: Carbon delivers
  hotkeys to the main run loop, so when main is blocked ⌥⌘⇧D is as dead as the ⟳ menu item (this
  is exactly what the user hits — the 2026-08-17 incident). The only two things that still work
  there are the socket (`dictate restart`, served on its own thread with a force path) and the
  automatic watchdog / take-start deadline.
- **Banner**: a borderless floating `NSPanel` whose content view is a **flat
  translucent fill** (layer-backed `NSView`, black α`BANNER_BG_ALPHA` — Hammerspoon-
  style glass, no blur) + a hairline border, holding one centred `NSTextField`. Spans
  the **full screen width** (`BANNER_HMARGIN` edge gaps), a touch above mid-screen;
  **height auto-grows** with the text from a **fixed top edge**, capped at
  `BANNER_MAXH_FRAC` of the screen. It is **status-only** — it never shows live
  transcript text (the take's words go to the post-take editor); the header is short
  and stable, so it does not jump. Ignores mouse. One attributed string layers bright
  title / dim subtitle — all **explicit** colours (no vibrant backdrop now, so a
  semantic colour like `secondaryLabelColor` would vanish in Light Mode). States:
  «Запуск микрофона…» (warm-up, gated on `g_sess->live` via a 0.1 s poll) → «🎙 говори»
  (static, no live text) → «расшифровка…» → hidden. Updated only
  on the main queue. A `_gen` counter keeps a stale timed auto-hide from hiding a newer
  take's banner. All look/layout knobs are the `BANNER_*` constants atop `src/dictate.mm`.
- **Auto-paste**: `paste_text` — clipboard + synthetic ⌘V (`CGEventPost`), restore
  after 0.4 s; degrades to clipboard-only if not Accessibility-trusted (gotchas #2/#4).
- **Menubar**: `NSStatusItem` — an **SF Symbol template image** (`setStatusGlyphRecording:`:
  `mic` idle / `mic.fill` tinted red while recording; text fallback only if the symbol is nil),
  **left**-click toggles + a 1 Hz `NSTimer` that enforces the 60 s cap and writes the elapsed
  m:ss into the **tooltip**. The glyph is deliberately narrow and fixed-width: macOS packs menu
  bar extras right-to-left and silently parks whatever no longer fits (measured on this Mac: the
  item sat at x≈650-740 pt while the first *drawn* icon was at ≈800 pt), so the old
  «⏳» / «🎙 m:ss» title — 41 pt idle, ~70 pt recording — was invisible on a full menu bar. Both
  the 60 s-cap timer and the warm-up poll are registered in `NSRunLoopCommonModes` (menu tracking
  leaves the default mode; a default-mode-only cap timer would let the mic run past 60 s while
  the user holds the menu open). **Right/⌃-click opens a menu** (`sendActionOn:` both
  mouse-ups; `statusClicked:` routes on `NSApp.currentEvent`): a disabled state line
  (`stateSummary` — `try_lock` on `g_mu`, never `lock`, so a stuck path can't freeze the menu),
  start/stop, **⟳ перезапустить**, open log. The restart is the user's own way out of a wedged
  daemon — it used to need an agent.
