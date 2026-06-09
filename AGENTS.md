# AGENTS.md — `dictate`

Native macOS push-to-talk dictation. Captures the mic (AVFoundation), transcribes
locally with whisper.cpp (libwhisper, Metal), shows a banner while you speak, then
opens a **foreground voice-editor** to review/correct the transcript — navigate by
word, fix any word by voice (a mini-dictation) — and on accept **pastes** into the app
that was focused before the take. Fully self-contained: the daemon owns the ⌘⇧D hotkey,
the banner, the editor, auto-paste, and the menubar indicator **natively** — it replaces
both the old bash script (`~/.local/bin/voice-dictate`) and its Hammerspoon UI layer.
Owner dictates in **Russian**; UI strings are Russian, code/docs English.

The whole reason this exists in C++ instead of the shell pipeline: a **resident
daemon** keeps the model in GPU memory (no per-take reload) and enables
**streaming** (transcribe while you speak).

## Layout

- `src/dictate.mm` — the entire program (Objective-C++). One file on purpose.
- `src/dictate_*.h` — pure, platform-independent logic factored OUT of `dictate.mm` so it's
  unit-testable without AppKit/AVFoundation/whisper/Accelerate (gotcha #19). `dictate.mm`
  `#include`s them, so there's one definition: `dictate_wav.h` (WAV reader), `dictate_text.h`
  (`normalize_ws` + `normalize_text` — the post-normalizer: capitalization/punctuation/
  typography, applied to the final transcript), `dictate_proto.h` (socket verb parse), `dictate_vad.h` (energy-VAD
  `Segmenter` + the VAD tuning constants + cap arithmetic), `dictate_editmodel.h` (editor
  tokenize/cursor/apply + line-nav search), `dictate_authgen.h` (peer-uid + paste-gen checks),
  `dictate_dict.h` (user-dictionary parse + token-budgeted `initial_prompt` build — gotcha #21),
  `dictate_idle.h` (idle-unload gate + poll-cadence arithmetic — gotcha #7),
  `dictate_edscroll.h` (editor vertical-scroll clamp / cursor-follow arithmetic).
- `tests/` — doctest unit tests (`tests/doctest.h` vendored; `tests/test_*.cpp`). `make test`.
- `Makefile` — clang++ build; bakes `-DGGML_LIBEXEC` from `brew --prefix ggml`. Also the
  `test` target (host `c++`, no brew/whisper needed — gotcha #19).
- `com.user.dictate.plist` — LaunchAgent template (installed copy in
  `~/Library/LaunchAgents/`; it runs the binary from `~/.local/bin/dictate`, NOT the
  repo build — gotcha #13).
- `README.md` — user-facing; this file is for working ON the code.

## Build / run / test

```sh
make                       # → ./dictate   (needs Xcode CLT + `brew install whisper-cpp`)
make test                  # → tests/run   (doctest; host c++, NO brew/whisper — runs on Linux too)
./dictate --file a.wav     # one-shot, no daemon: stream a 16 kHz mono WAV
./dictate --file a.wav --once   # single-pass (A/B vs streaming)
```

`make test` unit-tests the pure logic in `src/dictate_*.h` (WAV parse, VAD/segmentation,
editor model, socket parse, peer-auth, paste-gen, dictionary→prompt). It links nothing macOS-specific, so it
is the fast inner loop AND the only part that builds off a Mac. It does NOT exercise the
`dictate.mm` macOS build — keep `make` + `make tsan|asan` + `--file`/`feedfile` for that
(gotcha #19).

Make a test clip without a mic (silence hallucination needs *real* noise, not
digital zeros — `anullsrc` won't reproduce it; use a real recording or `anoisesrc`):

```sh
say -v Milena -o /tmp/t.aiff "Привет, это тест"
ffmpeg -i /tmp/t.aiff -ar 16000 -ac 1 -y /tmp/t.wav
./dictate --file /tmp/t.wav
```

Exercise the **daemon** path without a mic via the `feedfile` debug command:

```sh
printf 'feedfile /tmp/t.wav\n' | nc -U /tmp/dictate.sock   # → ok (take left open)
printf 'stop\n'                | nc -U /tmp/dictate.sock   # → streamed transcript
```

## CLI / protocol

Normal use is the **⌘⇧D hotkey owned by the daemon itself** — no client needed.
The client verbs remain for scripting/tests: `start stop cancel ping quit`.
`stop` prints the transcript to stdout (the daemon also copies it to the clipboard
and auto-pastes). `--file [--once] [--lang xx] [--model P]` is the standalone path:
`--file` streams (VAD-segmented) like a take, `--once` does a single whole-buffer pass
(the A/B reference). Run TSan/ASan over `--file` to cover the tap↔worker concurrency.

Daemon socket commands (newline-terminated, raw replies): `ping`→`pong`,
`start`→`ok`/`err …`, `stop`→transcript (script/test path: clipboard, **no** editor),
`cancel`→`ok`, `feedfile <path>`→`ok`, `quit`→`bye`. Editor protocol (daemon ↔ the
`dictate editor` process): `corr-start`→`ok` (mini-take mic on), `corr-stop`→transcript,
`corr-cancel`→`ok`, `accept <text>`→`ok` (refocus target + paste), `editor-cancel`→`ok`,
`edit <text>`→`ok` (debug: open the editor on text, no mic). Standalone:
`dictate editor "слова"` runs the editor alone (stubbed mini-take). Socket
`/tmp/dictate.sock` (override `$DICTATE_SOCK` to run a test daemon off the live one) ·
state file `/tmp/dictate.recording` · logs `/tmp/dictate.log`, `/tmp/dictate-editor.log`.

## Architecture

- **Daemon** (`run_daemon`): a Cocoa **accessory** agent. Single instance (guards
  via socket ping), binds the socket, loads ggml backends + the model **once**, then
  the **main thread runs `[NSApp run]`** (for the hotkey + banner + menubar) while a
  **background thread** serves the Unix socket (`socket_accept_loop`/`serve_client`).
  Holds `g_ctx` (model), `g_sess` (current take), `g_rec` (mic). The recording
  lifecycle + all AppKit live on the main queue; the socket thread and the worker
  marshal there via GCD. `stop`'s blocking `finish()` runs **off-main** so the run
  loop never freezes.
- **Client** (`client_cmd` / `ensure_daemon`): `start` auto-spawns the daemon
  (fork+setsid+exec, logging to `/tmp/dictate.log`) if none answers, then polls
  ~6 s for it to come up (covers the model-load window).
- **StreamingSession**: energy-VAD segments the 16 kHz mono stream at pauses; a
  **single worker thread** runs `whisper_full` per closed segment and appends text
  in order — that's the streaming win: most of the audio is already transcribed by the
  time you stop, so `finish()` only has the open tail left (it flushes that segment,
  drains the worker, joins parts). If the energy VAD heard nothing it falls back to one
  pass over the full buffer. **No live interim text**: the worker just builds `parts_`;
  the banner is status-only and the take's words surface in the post-take editor, not
  live. (The old open-segment live-preview path was removed — see gotcha #12.)
- **Recorder** (`AVAudioEngine`): tap converts the hardware format → 16 kHz mono
  via `AVAudioConverter` (drained in a loop — a sample-rate conversion may not consume all
  input in one `convertToBuffer:`), sets `sess->live`, and calls `sess->feed`. It observes
  `AVAudioEngineConfigurationChangeNotification` and **rebuilds the tap + converter** on a
  device/route change (unplugging AirPods, switching input) — otherwise the engine stops
  and the take silently dribbles to an empty transcript.
- **whisper's built-in Silero VAD** is enabled in `make_params` on top of all
  that — it trims silence *inside* each segment (see gotcha #3).
- **Native UI** (`DictateController`, the `NSApp` delegate): owns the global ⌘⇧D
  hotkey (Carbon `RegisterEventHotKey`, keycode 2) + scoped Esc-cancel, the floating
  banner (`NSPanel`), auto-paste (synthetic ⌘V via `CGEvent`), and the menubar
  `NSStatusItem` + 60 s auto-stop timer — all on the main thread.

## Voice editor (post-take correction)

After a take the daemon opens a **foreground editor** instead of pasting directly
(`dictate editor` — one binary, a mode alongside `daemon`). **Why a separate
process:** a dedicated **KEY** window composites reliably and gets keyDown — unlike the
background accessory banner, whose live repaint the WindowServer throttles during a take
(post-mortem: the `banner-live-paint-unsolved` project memory). The editor
is an **accessory app** (`NSApplicationActivationPolicyAccessory`) whose window is a
**non-activating `NSPanel`** (`NSWindowStyleMaskNonactivatingPanel`): it takes keyboard
focus WITHOUT activating the app, so it surfaces on the user's *current* Space. (It was
briefly `Regular` + activating, but that activation yanked the user to the main Space —
gotcha #20.) So correction happens in the editor; the banner
only shows warm-up + recording status during the take. (The two-model live-preview +
`dictate ui` isolation explored during that saga are **stashed**, not in this build —
the editor supersedes live-preview-during-take.)

- **`EditorView`** (in `dictate.mm`): tokenizes the transcript into words + gaps; the
  cursor is ON a word (highlighted) or IN a gap (a «] [» caret). ←/→ step words+gaps,
  ↑/↓ jump to the nearest word a line up/down (the view owns its own wrapped layout, so
  the same geometry drives drawing + line nav). ⏎ or ⌘⇧D accept, Esc cancels, ⌘Z/⌃Z
  undo and ⌘⇧Z/⌃⇧Z redo the last content edit (a mini-take splice or a delete — NOT
  navigation; restores words+cursor+confidence exactly). The two-stack `EditHistory`
  (pure in `src/dictate_editmodel.h`, unit-tested) holds pre-edit snapshots: each edit
  (`applyResult:`/`deleteCurrent:`) snapshots BEFORE mutating and `recordEdit`s only if the
  document actually changed (snapshot compare — no phantom undo on a same-text re-dictation),
  which also forks the redo stack; undo/redo park the current state on the opposite stack so
  the pair round-trips losslessly. The word
  body is **clipped to the region between the header and the footer legend and scrolls
  vertically**: navigation/insert auto-scrolls minimally to keep the cursor line on-screen
  (`_followCaret`), the scroll wheel scrolls freely, and a faint right-margin knob shows
  position — so a long transcript can't overrun the legend or the window edge. The pure
  clamp/cursor-follow arithmetic is `ed_scroll_clamp` (`src/dictate_edscroll.h`, unit-tested);
  the editor window is sized to a screen-fraction (taller than the old fixed 460 px).
- **Uncertain-word highlight (whisper logprob)**: words whose min per-token confidence
  is below `ED_CONF_THRESHOLD` (0.60) are drawn amber (`ed_conf_color`), leading the eye
  to likely errors. whisper's per-token `p` (`whisper_full_get_token_p`) is pulled in
  `run_whisper_tok`, mapped tokens→words by `conf::words_confidence` (min-prob over each
  word's bytes; `src/dictate_conf.h`, unit-tested), assembled per-word in `finish()`,
  then carried daemon→editor over the `--conf` argv (serialized ints). It is **re-aligned onto
  the post-`finalize_transcript` tokenization** (`conf::realign`) since normalize re-cases
  words / rewrites punctuation; a count drift disables the highlight (never mis-paints).
  Voice-corrected/inserted words become confident (`EM_CONF_SURE`). Threshold + colour are
  editor constants atop the editor section in `src/dictate.mm`.
- **Mini-take (voice edit)**: SPACE on a word / in a gap → editor sends `corr-start`
  (daemon mic on), the window goes static + red 🎙; SPACE again → `corr-stop` → daemon
  transcribes → editor replaces the word / inserts at the gap (async, «расшифровка…»).
  Esc mid-take → `corr-cancel` (cancels just the take). A standalone `dictate editor`
  run (no `--from-daemon`) uses a local stub instead of the daemon mic.
- **Mini-take cleanup (`EditModel::applyMiniTake`, `src/dictate_editmodel.h`)**: whisper
  transcribes a single dictated word as a standalone sentence — Capital + trailing period
  («слово» → "Слово.") — which is wrong for a one-word correction. So the mini-take result
  is cleaned before splicing (NOT via `normalize_text`, which is take-boundary-only and would
  over-capitalize): (a) drop the spurious trailing sentence dot; (b) re-case the first letter
  to context — on a word **replace** it inherits the replaced word's case (keeps proper nouns /
  sentence starts capital, mid-sentence fixes lowercase), at a **gap** insert it Capitalizes
  only at a sentence start (`atSentenceStart`); (c) **spoken punctuation**: if the whole
  utterance names a mark (`em_spoken_punct` — «знак вопроса»→`?`, «точка»→`.`, «запятая»→`,`,
  «тире»→`—`, «открыть скобку»→`(`, «закрыть кавычки»→`»`, …) it inserts that symbol instead
  of the literal words. All pure + unit-tested. The plain `applyResult` (stub / text-only
  path) stays verbatim — only the voice path runs the cleanup.
- **Accept → paste**: the daemon saves the frontmost app at take start (`g_target_app`,
  `NSWorkspace`); on `accept <text>` it re-activates that app (`activateWithOptions:`
  `NSApplicationActivateAllWindows` — `Ignoring*` is a no-op on macOS 14+) and
  `paste_text`s after a short delay. Cancel → `editor-cancel` (refocus, no paste).
- **⌘⇧D routing**: the daemon **unregisters its global ⌘⇧D** while the editor is open
  (so the key reaches the editor's key window) and re-registers on accept/cancel/exit.
  A `waitpid` watcher recovers (re-register ⌘⇧D, clear `g_editor_open`, reap the child)
  if the editor dies without accept/cancel — see gotcha #15.

## Architecture decisions & gotchas → Notion

The hard-won macOS / whisper / concurrency **gotchas** that used to fill this section
were really ADRs, so they now live in Notion (one ADR per gotcha) to keep this file lean:

→ **[Dictate ADRs](https://app.notion.com/p/164ad9f8d7ad4529a6291b9039aa45e2)**
(HQ › Projects › [Dictate](https://app.notion.com/p/379e684244ab81b196abcc223eb8bb56);
also indexed in the HQ **ADR Registry**).

Numbering is preserved one-to-one: **gotcha #N ≡ ADR-00NN** — so the many `gotcha #N`
cross-references still scattered through this file resolve to ADR-00NN in that database
(e.g. `gotcha #5` = ADR-0005, whisper_context thread-safety; `gotcha #14` = ADR-0014, signing).
Read the relevant ADR before changing that area, and record the next hard-won lesson as a
**new ADR there**, not as a new gotcha here.

## Native UI (in-process — Hammerspoon dropped)

The daemon is fully self-contained; `DictateController` (the `NSApp` delegate) owns
all UI on the **main thread**:

- **Hotkey**: `RegisterEventHotKey(kVK_ANSI_D=2, ⌘⇧)` toggles a take — keycode 2 is
  the physical D key, so it survives a Cyrillic layout (and needs no Accessibility).
  A second hotkey for **Esc** is registered only for the duration of a take (so Esc
  stays normal everywhere else) and cancels it.
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
- **Menubar**: `NSStatusItem` (⏳ idle / 🎙 m:ss recording, click toggles) + a 1 Hz
  `NSTimer` that enforces the 60 s cap.

The Unix socket + client verbs stay (scripts/tests). `/tmp/dictate.recording` is
still touched while capture is live — a cheap external flag; nothing reads it now
that Hammerspoon is gone. `~/.hammerspoon/init.lua` no longer references dictate (its
dictate block was removed, `clip2vps` kept); the prior version is archived at
`~/.hammerspoon/init.lua.pre-dictate-removal.bak`.

## Daemon lifecycle (LaunchAgent)

Auto-starts at login as a **user LaunchAgent** (`com.user.dictate`, RunAtLoad +
KeepAlive). It must be a user agent, not a system LaunchDaemon — it needs the user's
mic, clipboard, and GUI session. The plist runs the **installed copy at
`~/.local/bin/dictate`**, not the repo build (gotcha #13).

```sh
make && cp dictate ~/.local/bin/dictate          # build + install (NOT into ~/Documents — gotcha #13)
sed "s|/Users/YOUR_USERNAME|$HOME|" com.user.dictate.plist > ~/Library/LaunchAgents/com.user.dictate.plist  # launchd won't expand ~
# macOS 14+: bootstrap/bootout (legacy `load -w`/`unload` are deprecated — gotcha #13).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.dictate.plist  # enable + start
launchctl bootout   gui/$(id -u)/com.user.dictate                              # stop + disable
launchctl kickstart -k gui/$(id -u)/com.user.dictate                           # restart (pick up a new build)
launchctl print gui/$(id -u)/com.user.dictate | grep -E 'state|pid'            # status
tail -f /tmp/dictate.log                                                       # logs
```

If you see two daemon processes, you have a stray (manual or pre-LaunchAgent
auto-spawn). Clean: `launchctl bootout gui/$(id -u)/com.user.dictate; pkill -9 -f
'dictate daemon'; rm -f /tmp/dictate.sock; launchctl bootstrap gui/$(id -u) …`.

## Config (env) & tuning

- `WHISPER_MODEL` (default `~/.config/whisper/ggml-large-v3-turbo-q5_0.bin`),
  `WHISPER_LANG` (default `ru`), `WHISPER_VAD_MODEL`, `WHISPER_VAD=0` to disable
  VAD, `DICTATE_GGML_BACKENDS` to override the backend dir, `DICTATE_SOCK` to override
  the socket path (run a test daemon off the live one).
- `WHISPER_DICT` (default `~/.config/whisper/dictionary.txt`) — user dictionary that biases
  whisper toward your vocabulary (names / tech terms / English-in-Russian) via `initial_prompt`.
  Default ON if the file exists; `WHISPER_PROMPT=0` disables it (like `WHISPER_VAD`/`WHISPER_FLASH`);
  `WHISPER_PROMPT_MAXTOK=N` overrides the ~224-token budget. One entry/line, order = priority,
  `#` comments; assembled by `src/dictate_dict.h` (gotcha #21). Template: `examples/dictionary.txt`;
  WER harness: `scripts/bench-wer.py`.
- `WHISPER_FLASH=0` disables Metal flash attention (on by default; ~20% faster
  transcription on the turbo model, output unchanged — see gotcha #11).
- `DICTATE_NORMALIZE=0` disables post-normalization of the final transcript (default ON).
  The normalizer (`normalize_text`, `src/dictate_text.h`) capitalizes sentence starts, fixes
  punctuation spacing, and applies light typography (`...`→`…`, ` - `→` — `) — conservative
  by design (leaves mixed RU/EN, domains, file names, versions, decimals alone). It is applied
  via `finalize_transcript()` ONLY at the two final take boundaries (the hotkey/timer worker
  after `raw->finish()`, and the socket `stop` after `s->finish()`) — **never inside `finish()`
  itself**, because `finish()` is shared with the editor mini-take (`corr-stop`), where a
  single-word voice correction must stay verbatim (sentence-capitalizing a one-word replacement
  would be wrong). The standalone `--file` path is left raw (it's the A/B reference).
- `WHISPER_THREADS=N` overrides the CPU-thread count. Default = performance-core
  count (`hw.perflevel0.physicalcpu`), not all logical cores: the workload is
  GPU-bound so thread count barely matters, and this keeps whisper off the E-cores.
- `DICTATE_IDLE_UNLOAD_SEC=N` (default OFF / `0`) — free the ~573 MB resident model after
  N seconds with no take, reloading on demand on the next take (~600 ms–1 s). Trades the
  resident-speed win for memory when idle (gotcha #7). The idle gate (`src/dictate_idle.h`,
  unit-tested — gotcha #19) is polled by an `NSTimer` at `idle_poll_interval_sec(N)`
  (timeout/3, clamped to 1–10 s).
- VAD/segmentation constants in `src/dictate_vad.h` (with the pure `Segmenter`):
  `SILENCE_CLOSE_FR` (~700 ms pause closes a segment), `SPEECH_FACTOR`/`ABS_FLOOR`
  (sensitivity), `MAX_SEG_FR` (~20 s hard cap), `PREROLL_FR` (~300 ms kept before onset),
  `SPEECH_CONFIRM_FR`, `FRAME`. The Silero VAD params live in `make_params`
  (`min_silence_duration_ms`, `speech_pad_ms`).

## whisper.cpp notes (Homebrew 1.8.6)

API used: `whisper_init_from_file_with_params` (+ `whisper_context_default_params`,
`use_gpu=true`), `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`,
`whisper_full`, `whisper_full_n_segments`, `whisper_full_get_segment_text`,
`whisper_free`. VAD via `whisper_full_params.{vad,vad_model_path,vad_params}` +
`whisper_vad_default_params`. Lexical bias via `whisper_full_params.initial_prompt` (a
non-owning `const char*`, backed by the `g_initial_prompt` global — gotcha #21). Headers:
`$(brew --prefix whisper-cpp)/include`;
`ggml.h` from `$(brew --prefix ggml)/include`.

## Status / roadmap

Done: resident model · daemon+client over Unix socket · streaming (VAD-segmented) ·
Silero VAD (silence-hallucination fix) · NSPasteboard clipboard · LaunchAgent
autostart · `--file`/`feedfile` test paths · Metal flash attention (~20% faster) ·
perf-core thread default · vectorized (Accelerate) VAD RMS · self-contained native hotkey + banner + auto-paste + menubar —
Hammerspoon dropped · **post-take voice-editor: navigate (←/→ ↑/↓) + voice-edit
(replace/insert via mini-takes) + accept→focus-restore→paste** · **unit tests (doctest,
`make test`): pure logic factored into `src/dictate_*.h` — WAV parse, VAD/segmentation +
cap, editor model, socket parse, peer-auth, paste-gen — host-portable, gotcha #19** ·
**user-dictionary lexical bias → whisper `initial_prompt` (token-budgeted, env-toggled;
`src/dictate_dict.h` + `scripts/bench-wer.py` WER harness — gotcha #21)** ·
**post-normalization of the final transcript (`normalize_text`: capitalization/punctuation/
typography, `DICTATE_NORMALIZE`; applied at the take boundary, not inside `finish()`)** ·
**uncertain-word highlight in the editor (whisper per-token logprob → per-word min
confidence → amber below `ED_CONF_THRESHOLD`; `src/dictate_conf.h` incl. `realign` across
`normalize_text`, unit-tested — see the Voice-editor section)** ·
**idle-unload: free the resident model after `DICTATE_IDLE_UNLOAD_SEC` idle, reload on
demand — opt-in, off by default; `src/dictate_idle.h` + `idleTick` under `g_mu`, gotcha #7** ·
**status-only banner: no live transcript in the banner (it jumped/grew as words streamed) —
the take's words appear in the post-take editor. The open-segment live-preview machinery
(callback, tap snapshot, `maybePreview`, `PREVIEW_*`, `--interim`/`--realtime`) was removed
entirely; per-segment streaming into `parts_` stays (the latency win) — gotcha #12**.

Declined: warm-mic option (pre-open device to kill the ~0.5–1.5 s avfoundation warm-up) —
deliberately not pursued; don't re-propose.

Editor follow-ups (minor, not blocking): make editor-after-every-take optional if it feels
heavy; `relayout` re-measures on every `drawRect` (cheap at current word counts). (The in-take
banner live-preview is gone entirely now — the banner is status-only.)
