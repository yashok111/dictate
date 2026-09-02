# Self-recovery — restart, watchdog, take-start deadline, wedge forensics

Deep dive moved out of `CLAUDE.md`. Read this before touching `restart_process_now`,
the watchdog / take-start threads, `wedge_sample_*`, the backoff, or `slog`/`raw_log`.

- **Restart / watchdog** (`restart_process_now` + `DictateController.setupWatchdog`): the daemon
  owns state that can't be reset in place (Metal ctx, CoreAudio HAL client, hotkey, windows), so
  recovery = a fresh process (~1 s model load). `restart_process_now` takes **no locks and never
  hops to the main queue** — callable from the watchdog/socket thread while main is wedged.
  **Order matters**: it lines the successor up FIRST (`posix_spawn` of `daemon --replace`, never
  `fork` — Metal + threads; `--replace` makes the child wait for our socket to vanish instead of
  bowing out as a duplicate) and only then tears down. So a failed spawn aborts the restart with
  nothing dropped (a wedged daemon beats no daemon), and under launchd nothing is spawned at all
  (`XPC_SERVICE_NAME` → `KeepAlive` is the successor). Teardown — unlink the socket —
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

The Unix socket + client verbs stay (scripts/tests). The old `/tmp/dictate.recording`
state file (and the per-take thread that touched it) is gone — nothing read it once
Hammerspoon left; `g_sess->live` is the in-process signal. `~/.hammerspoon/init.lua` no longer references dictate (its
dictate block was removed, `clip2vps` kept); the prior version is archived at
`~/.hammerspoon/init.lua.pre-dictate-removal.bak`.
