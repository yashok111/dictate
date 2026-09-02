# Status / roadmap

Moved out of `CLAUDE.md`; the Declined list stays there (it is a standing rule).

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
