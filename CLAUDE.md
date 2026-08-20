# CLAUDE.md — `dictate`

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
  `dictate_watchdog.h` (main-thread watchdog gate: heartbeat staleness + poll cadence, the
  take-start deadline arithmetic, and which restart reasons are worth a `sample` snapshot),
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
The client verbs remain for scripting/tests: `start stop cancel ping restart quit`.
`stop` prints the transcript to stdout (the daemon also copies it to the clipboard
and auto-pastes). `--file [--once] [--lang xx] [--model P]` is the standalone path:
`--file` streams (VAD-segmented) like a take, `--once` does a single whole-buffer pass
(the A/B reference). Run TSan/ASan over `--file` to cover the tap↔worker concurrency.

Daemon socket commands (newline-terminated, raw replies): `ping`→`pong`,
`start`→`ok`/`err …`, `stop`→transcript (script/test path: clipboard, **no** editor),
`cancel`→`ok`, `feedfile <path>`→`ok`, `restart`→`ok` (relaunch the daemon process — graceful
via the main queue, force-restarted from the socket thread after 2 s if main is wedged),
`wedge <sec>`→`ok` (debug: block the main queue, the only way to exercise the watchdog /
force-restart e2e — **gated on `DICTATE_DEBUG`**, otherwise `err unknown`),
`reconfig`→`ok` (debug, same gate: run the route-change path — `Recorder -reconfigure`, which drops
and rebuilds the engine — without physically unplugging anything; works both idle and mid-take),
`quit`→`bye`.
The take-start deadline has its own e2e hook for the same reason (nothing else hangs the mic
start on demand): `DICTATE_DEBUG_TAKESTART_STALL=<sec>` (with `DICTATE_DEBUG`) stalls inside the
armed window, on the main queue, under `g_mu` — start a take and the daemon restarts with reason
`take-start` and leaves a `/tmp/dictate-wedge-*.txt` naming `daemon_start`.
`DICTATE_DEBUG_POISON=1` (with `DICTATE_DEBUG`) is the same kind of hook for the deferred
`audio-poisoned` restart: every successful mic start reports a fake `kAudioHardwareIllegalOperationError`,
so a take + cancel is enough to watch the daemon wait out the take and then restart while idle.
Each connection is served on **its own thread** (`socket_accept_loop`, capped at
`SOCK_MAX_INFLIGHT`): most verbs `dispatch_sync` to the main queue, so serving inline meant one
client blocked on a wedged main thread starved the accept loop and `restart` — the verb whose
job is to break that wedge — was never even read. Editor protocol (daemon ↔ the
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
  input in one `convertToBuffer:`), sets `sess->live`, and calls `sess->feed`.
  **One Recorder and one `AVAudioEngine` per daemon**, not per take (gotcha #25): building the
  engine is what touches `-[AVAudioEngine inputNode]`, and that call constructs the AUHAL, publishes
  AVFoundation's process-private `CADefaultDeviceAggregate-<pid>-0` and — when that aggregate has
  gone bad — disappears into `AVAEHalUtil::GetSubDevices` for **10–35 s**, on the main queue, under
  `g_mu`, i.e. exactly inside the take-start deadline. Reusing the engine leaves one construction
  per process instead of one per ⌘⇧D (measured: ~470 ms for the first take, ~110 ms for every take
  after it). The hardware input format is cached alongside it (`_inFmt`) — `-inputFormatForBus:` IS
  `GetHWFormat`, the same wedge site — and can only go stale behind a configuration-change
  notification, which drops the whole engine. So `g_rec` no longer means “a take is running”;
  `g_sess` does, and `-stop` now ends the take (tap off, engine stopped) without destroying the
  engine. A failed `-startFeeding:` drops the engine and clears `_sess` — the cleanup the old
  throw-the-Recorder-away code got for free. And because a persistent engine turns a one-take
  annoyance into a permanent one, every start checks afterwards that the engine really landed on
  `_pinnedDev`; if it did not (a failed `setDeviceID:`, a device that drifted) the engine is marked
  `_engineSuspect` and rebuilt before the next take — otherwise a single failed pin would leave
  every later take recording from BlackHole/Teams, i.e. silent, with no error anywhere. It observes
  `AVAudioEngineConfigurationChangeNotification` and on a device/route change (unplugging AirPods,
  switching input) **drops the engine entirely**, re-enumerating and re-pinning on the rebuild —
  that notification means the format and possibly the device id are wrong, and the old per-take
  rebuild used to refresh both for free. Without any of it the engine stops and the take silently
  dribbles to an empty transcript.
  Capture is **pinned to the built-in mic**, not the system default (`prefer_builtin_input` →
  `find_builtin_input_device`, CoreAudio HAL: `kAudioDeviceTransportTypeBuiltIn` + ≥1 input
  channel — the channel check matters, the built-in *speakers* also report the built-in
  transport; aggregates are rejected by `kAudioObjectPropertyClass`, since the one device we can
  never want to pin to is precisely the `CADefaultDeviceAggregate` above). Without it the default
  routinely sits on a virtual device (BlackHole, Teams Audio) that carries no mic signal, or on
  AirPods. Pinning posts one self-induced
  configuration-change notification, swallowed via `_pinReconfig` (gotcha #22).
  On a start failure that looks like a stale CoreAudio client (`kAudioHardwareNotRunningError`,
  `'stop'` = 1937010544), the whole `AVAudioEngine` is rebuilt and start retried **once**
  (`-buildEngine`/`-dropEngine`/`-startWithHALRecovery:`); if it still fails, the HAL itself
  is wedged and only `sudo killall coreaudiod` helps — the error says so (gotcha #23).
  A **different** refusal — `kAudioHardwareIllegalOperationError` (`'nope'` = 1852797029) from
  `setDeviceID:` or from `-startAndReturnError:` on a device the HAL otherwise describes happily —
  is not a stale client but rot in this process's own audio state, and only a fresh process clears
  it. It is also the documented precursor to the `GetHWFormat` wedge (in the 2026-08-19 incident it
  was logged **five minutes** before the daemon hung mid-take). So it sets `g_audio_poisoned` and
  arms a 2 s poll (`-armPoisonRestart` / `-poisonTick:`) that restarts the daemon at the next moment
  with no take, no pending finish and no editor — same ~1 s cure the watchdog applies, except
  nobody is mid-sentence. Guards: it is ignored until this process has captured at least once
  (`g_capture_ok_since_launch`), or a Mac where the pin can never work would restart after every
  take forever; it honours the aborted-restart backoff; and “audio-poisoned” is deliberately not a
  `wd_reason_is_wedge` reason, so it takes no `sample` snapshot (nothing is stuck). Every successful
  mic start logs its own timings — `capture live: … (engine N ms, fmt N ms, start N ms)`, plus a
  warning past `MIC_START_SLOW_MS` — so a mic start creeping toward `DICTATE_TAKESTART_SEC` is
  visible in `/tmp/dictate.log` before it costs a restart.
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
- **Restart / watchdog** (`restart_process_now` + `DictateController.setupWatchdog`): the daemon
  owns state that can't be reset in place (Metal ctx, CoreAudio HAL client, hotkey, windows), so
  recovery = a fresh process (~1 s model load). `restart_process_now` takes **no locks and never
  hops to the main queue** — callable from the watchdog/socket thread while main is wedged.
  **Order matters**: it lines the successor up FIRST (`posix_spawn` of `daemon --replace`, never
  `fork` — Metal + threads; `--replace` makes the child wait for our socket to vanish instead of
  bowing out as a duplicate) and only then tears down. So a failed spawn aborts the restart with
  nothing dropped (a wedged daemon beats no daemon), and under launchd nothing is spawned at all
  (`XPC_SERVICE_NAME` → `KeepAlive` is the successor). Teardown — unlink socket + state file —
  runs exactly once (`g_torn_down`), so a forced second caller can't unlink the successor's fresh
  socket, and the editor child is `SIGTERM`ed (`g_editor_pid`): a fresh daemon has no
  `g_target_app` and re-registers ⌘⇧D, so an orphan would paste into the wrong app. `g_restarting`
  keeps the graceful main-queue path and the `restart` verb's force path to one restart; the force
  waits `RESTART_DEADLINE_SEC+1` so it doesn't beat the graceful path on a healthy daemon. The
  watchdog itself: the main queue stamps `g_wd_beat_ms` at 1 Hz, a background thread restarts the
  process when the stamp is `DICTATE_WATCHDOG_SEC` stale. Four false-positive traps it avoids —
  the heartbeat timer is in **`NSRunLoopCommonModes`** (menu tracking would starve a default-mode
  timer), the clock is **`CLOCK_UPTIME_RAW`** (stops during system sleep; `CLOCK_MONOTONIC` does
  not — a closed lid would look like an 8-hour stall), `wd_checker_starved` skips a round when the
  watchdog thread's OWN sleep overran (SIGSTOP/suspension starves both threads; `lastCheck` is
  stamped before the first sleep so round 1 is guarded too), and `g_longop_until_ms` marks an
  on-demand model reload so a slow one is waited out instead of killing the take — a **deadline**
  (`LONGOP_GRACE_SEC`), not a flag, because a load that never returns (model on a stalled volume)
  would otherwise disarm the watchdog forever in the worst wedge of all; and its RAII guard stamps
  the heartbeat on the way out, since main is still mid-block (mic warm-up) when the exemption
  lifts. Restart bookkeeping: `g_replacement_spawned` is only the spawn CLAIM — a second caller
  tears down only once `g_replacement_ready` confirms a successor exists (or launchd is one), and
  `g_restart_gen` stands the armed deadline/force threads down when a restart aborts, so the
  daemon can't restart itself moments after telling the user the restart failed.
  Three more deliberate details, each verified e2e with the `wedge` verb: (a) the heartbeat is armed
  by the FIRST timer tick, never up-front — a daemon whose run loop never starts is left alone
  instead of restart-looping; (b) `wd_checker_starved` suppresses a round when the watchdog thread's
  OWN sleep overran (SIGSTOP / suspension starves both threads — tested with `kill -STOP`); (c) the
  graceful `restartNow:` arms an off-main `RESTART_DEADLINE_SEC` thread BEFORE stopping the recorder
  and joining the worker, since those are exactly the calls that can hang. Restart logging is
  `raw_log` (`write(2)`), not `fprintf` — a thread wedged while holding stderr's stdio lock would
  deadlock a printf.
- **Take-start deadline** (`g_takestart_until_ms`, `DICTATE_TAKESTART_SEC`, default 8 s — gotcha #24): a second,
  much tighter watcher armed only around the mic-start critical section in `daemon_start` — the
  `AVAudioEngine` build, the built-in-mic pin and the engine start, all synchronous CoreAudio on the
  main queue **with `g_mu` held**. That is where the wedge actually lands in practice (2026-08-17:
  `setDeviceID:` → `kAudioHardwareIllegalOperationError` → AVFoundation never returned → 35 s of
  dead UI), and the heartbeat timeout cannot be lowered to match because it also has to cover the
  model reload, the editor spawn and every AppKit callback. Own thread, 1 s poll, same
  `restart_process_now` with reason `take-start`; same `wd_checker_starved` suspension guard.
  Disarmed the instant `-startFeeding:` returns, not at the end of `daemon_start`: the take-log
  write and the live-watch thread that follow are disk/bookkeeping work, and leaving them inside a
  budget sized for CoreAudio would turn a stalled disk into a restart *loop*. Disabled together
  with the watchdog (`DICTATE_WATCHDOG_SEC=0`).
  **Mic permission not yet granted** (first run): the TCC dialog owns this exact section until the
  user answers, and a restart would take the prompt down with the process — an unescapable loop
  where the permission can never be granted. Suppressing just this deadline is not enough, since
  the heartbeat is stale for the same reason and fires a few seconds later; so a pending prompt
  takes the **long-op exemption** instead (the one the model reload uses, bounded by
  `LONGOP_GRACE_SEC` so an unanswered prompt still cannot disarm the watchdog forever).
- **Wedge forensics** (`wedge_sample_init` / `wedge_sample_loop` / `request_wedge_sample`, gotcha #24): the
  restart is also the moment the evidence dies — after it, all that is left of a wedge is *absent*
  log lines. So an involuntary restart (`wd_reason_is_wedge`: `watchdog` / `socket-force` /
  `take-start`, never a user-initiated ⟳) `sample`s the process for `WEDGE_SAMPLE_SEC` first,
  leaving `~/.local/share/dictate/wedge/wedge-<epoch>.txt` with every thread's stack — including
  the stuck one, the single thing the log cannot give. Two structural rules, both learned the hard
  way in review: (a) **the restart path allocates nothing** — the report dir, the argv strings and
  a helper thread parked on a `dispatch_semaphore` are all set up at startup, and the restart only
  signals the semaphore and polls an atomic with a `WEDGE_SAMPLE_WAIT_SEC` deadline. A wedge inside
  CoreAudio/AVFoundation can hold the allocator lock, so a `posix_spawn` issued from the restart
  path could block forever and defeat the restart it was documenting — and under launchd that
  would be a *new* way to lose the daemon, since the managed path otherwise spawns nothing. The
  helper blocks instead, where blocking costs only the report (and its blocking `waitpid` is also
  what keeps a timed-out `sample` from becoming a zombie if the restart later aborts). (b) the
  report goes under `~/.local/share/dictate/wedge/` (0700), **not** `/tmp`: a predictable name in a
  world-writable directory lets any local user pre-plant a symlink and have `sample -file` truncate
  whatever the daemon can write. `DICTATE_WEDGE_SAMPLE=0` turns it off.
- **Restart backoff** (`g_restart_backoff_until_ms`, `wd_in_backoff`): a restart that ABORTS (no
  replacement could be spawned — a wedged daemon beats no daemon) leaves main still wedged, so both
  watchers would fire again on their very next round: a hot loop of failing spawns, one `sample`
  each. The abort stamps `RESTART_BACKOFF_SEC`, which only the automatic triggers honour — a user
  asking for a restart is never made to wait.
- **Stamped log lines** (`slog`/`raw_log`, `ts_prefix`, gotcha #24): every line the daemon writes itself starts
  with `HH:MM:SS.mmm`; whisper's own chatter stays unstamped, which conveniently makes ours the
  greppable ones. `/tmp/dictate.log` used to have no time at all — nothing in it could be lined up
  against `log show`, the take log or `ps`, which is most of what made the 2026-08-17 post-mortem
  slow. Both go through `write(2)` (never stdio, see above), stamp+message in one `writev` so two
  threads can't interleave, and the UTC offset is cached at startup rather than calling
  `localtime_r` (it takes a timezone lock) — a DST flip mid-run skews wall-clock by an hour but
  never the ordering. The `--file`/client paths keep plain `fprintf`: a timestamp on interactive
  CLI output is noise.
- **Known narrow race** (pre-existing, shared with `quit`): between our exit and
  the replacement binding, a concurrent `dictate start` can spawn a second daemon; whichever binds
  first wins and the loser bows out via the single-instance guard — but if the loser is the launchd
  job, `KeepAlive` re-runs it every ~10 s until the other daemon exits. Not worth a lock file today.

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

**One-shot deploy:** `make deploy` (or `scripts/deploy.sh`) does the whole dance —
`make test` → `make` → install to `~/.local/bin` → `launchctl kickstart -k` →
`scripts/post-build-check.sh` (waits for the daemon to come up, then verifies binary/signature/
LaunchAgent/ping/Accessibility). Flags: `scripts/deploy.sh --no-test` / `--no-check` (or
`make deploy ARGS=--no-test`). The manual steps below are the underlying commands.

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
- `DICTATE_BUILTIN_MIC=0` — stop pinning capture to the built-in mic and follow the system
  default input instead (default ON; the pin is what keeps takes off BlackHole / Teams Audio
  / AirPods — gotcha #22). No-ops on a Mac with no built-in input, keeping the default. Note
  it overrides an external mic you actually chose, and since the daemon is launchd-started,
  `export`ing it in a shell does nothing — opting out means an `EnvironmentVariables` dict in
  `~/Library/LaunchAgents/com.user.dictate.plist` + `launchctl bootout`/`bootstrap`. (Same for
  every other var here when the daemon runs under the LaunchAgent.)
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
- `DICTATE_WATCHDOG_SEC=N` (built-in default `30`, **`15` in the installed plist**, `0` = off,
  values < 10 clamp up to 10) — restart the daemon if the main run loop stops stamping its 1 Hz
  heartbeat for N seconds. The pure gate is `src/dictate_watchdog.h` (unit-tested); see the
  Native-UI section for the false-positive traps (common run-loop modes, sleep-excluding clock,
  checker starvation, long-op exemption).
- `DICTATE_TAKESTART_SEC=N` (default `8`, `0` = off, values < 3 clamp up to 3 — gotcha #24) — restart the daemon
  if the mic-start section (`AVAudioEngine` build + built-in-mic pin + engine start, main queue,
  `g_mu` held) does not return within N seconds. Tighter than the heartbeat on purpose — see the
  Native-UI section. Off when the watchdog is off.
- `DICTATE_DEBUG_POISON=1` (debug, needs `DICTATE_DEBUG`) — fake a `kAudioHardwareIllegalOperationError`
  on every successful mic start, to exercise the deferred `audio-poisoned` restart (gotcha #25).
- `DICTATE_WEDGE_SAMPLE=0` — skip the `/usr/bin/sample` snapshot taken before an involuntary
  restart (default ON, writes `~/.local/share/dictate/wedge/wedge-<epoch>.txt`). The snapshot costs
  ~1.5 s of an already-broken daemon's restart and is the only source of the stuck stack.
- VAD/segmentation constants in `src/dictate_vad.h` (with the pure `Segmenter`):
  `SILENCE_CLOSE_FR` (~700 ms pause closes a segment), `SPEECH_FACTOR`/`ABS_FLOOR`
  (sensitivity), `MAX_SEG_FR` (~20 s hard cap), `PREROLL_FR` (~300 ms kept before onset),
  `SPEECH_CONFIRM_FR`, `FRAME`. The Silero VAD params live in `make_params`
  (`min_silence_duration_ms`, `speech_pad_ms`).

## whisper.cpp notes (Homebrew 1.8.7)

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
**self-recovery: menubar right-click menu (state + ⟳ перезапустить + лог), `restart` socket
verb / CLI, and a main-thread watchdog that relaunches the daemon after
`DICTATE_WATCHDOG_SEC` (15 s in the installed plist) of a stalled run loop —
`src/dictate_watchdog.h`** ·
**wedge diagnostics + faster recovery (after the 2026-08-17 mic-start wedge): a `DICTATE_TAKESTART_SEC`
(8 s) deadline around the mic-start critical section, a `/usr/bin/sample` snapshot of the stuck
stacks (`~/.local/share/dictate/wedge/`, taken by a helper parked since startup so the restart path
still allocates nothing) before any involuntary restart, a backoff after an aborted restart, and
`HH:MM:SS.mmm` stamps on every daemon log line** ·
**per-process `AVAudioEngine` + deferred `audio-poisoned` restart (after the 2026-08-19 repeat of the
mic-start wedge): the engine and the hardware format are built once per daemon instead of once per
take (the `inputNode`/`GetHWFormat` wedge site now runs once, and a warm take starts in ~110 ms
instead of ~190 ms), a `kAudioHardwareIllegalOperationError` books a restart for the next idle
moment rather than waiting to be wedged mid-take, and every mic start logs its per-step timings —
gotcha #25** ·
**status-only banner: no live transcript in the banner (it jumped/grew as words streamed) —
the take's words appear in the post-take editor. The open-segment live-preview machinery
(callback, tap snapshot, `maybePreview`, `PREVIEW_*`, `--interim`/`--realtime`) was removed
entirely; per-segment streaming into `parts_` stays (the latency win) — gotcha #12**.

Declined: warm-mic option (pre-open device to kill the ~0.5–1.5 s avfoundation warm-up) —
deliberately not pursued; don't re-propose.

Editor follow-ups (minor, not blocking): make editor-after-every-take optional if it feels
heavy; `relayout` re-measures on every `drawRect` (cheap at current word counts). (The in-take
banner live-preview is gone entirely now — the banner is status-only.)
