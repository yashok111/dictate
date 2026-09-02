# Audio capture & streaming — `StreamingSession`, `Recorder`, Silero VAD

Deep dive moved out of `CLAUDE.md` (which keeps the one-line summaries). Read this before
touching `StreamingSession`, `Recorder`, the built-in-mic pin, HAL recovery, or the
`audio-poisoned` restart. Numbering: gotcha #N ≡ ADR-00NN in the Notion ADR database.

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
