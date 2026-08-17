#pragma once
// Pure decisions for the daemon's main-run-loop watchdog, extracted so they can be
// unit-tested without AppKit / a live run loop (`make test`; gotcha #19). The side effects
// stay in dictate.mm — an NSTimer on the main queue stamps the heartbeat, a background
// thread polls it, and a missed heartbeat means the main thread is wedged (a blocked
// AppKit callback, a stuck CoreAudio/HAL call, a lock held by a dead path), at which point
// the process re-launches itself (launchd KeepAlive, or a posix_spawn'd replacement).
//
// The daemon lives for days and the hotkey/banner/menubar all live on the main thread, so a
// wedged main thread is invisible from the outside: the menubar icon still draws (the
// WindowServer has the last frame) but nothing responds. Restarting costs one model load.

#include <cstring>

// Heartbeat cadence (seconds): how often the main queue stamps "I'm alive". Fast enough that
// a healthy main thread never looks stalled, cheap enough to run forever.
inline double wd_beat_interval_sec() { return 1.0; }

// Poll cadence (seconds) for a given watchdog timeout: a fraction of the timeout, clamped to
// [1, 5] s, so the kill fires within ~one tick of the deadline without busy-polling.
inline double wd_poll_interval_sec(int timeout_sec) {
    double iv = timeout_sec < 15 ? (double)timeout_sec / 3.0 : 5.0;
    if (iv < 1.0) iv = 1.0;
    return iv;
}

// Is the configured timeout sane? Below this the normal main-thread work (starting the mic,
// spawning the editor, an on-demand model reload) would trip a false restart, so a too-small
// value is clamped up by wd_effective_timeout_sec rather than honoured.
inline int wd_min_timeout_sec() { return 10; }

// Effective timeout: <= 0 disables the watchdog (returns 0); anything positive is clamped up
// to wd_min_timeout_sec().
inline int wd_effective_timeout_sec(int requested_sec) {
    if (requested_sec <= 0) return 0;                                    // disabled
    return requested_sec < wd_min_timeout_sec() ? wd_min_timeout_sec() : requested_sec;
}

// Should the daemon restart itself now? True iff the watchdog is enabled, the heartbeat has
// been armed at least once (last_beat_ms > 0 — before the run loop starts there is nothing to
// watch), and no heartbeat landed within the timeout. Times in milliseconds, from a clock that
// does NOT advance while the machine sleeps (CLOCK_UPTIME_RAW) — a sleep-counting clock would
// report a days-long "stall" on every wake.
// `long_op_in_flight` is the escape hatch for work that legitimately owns the main queue for a
// long time — reloading the ~573 MB model after an idle-unload. That is indistinguishable from a
// wedge by heartbeat alone, and killing the daemon there would abort the take the user just
// started, so the caller flags it and the watchdog waits it out.
inline bool wd_should_restart(double now_ms, double last_beat_ms, int timeout_sec,
                              bool long_op_in_flight = false) {
    if (timeout_sec <= 0)     return false;                              // disabled
    if (last_beat_ms <= 0)    return false;                              // not armed yet
    if (long_op_in_flight)    return false;                              // slow on purpose, not wedged
    return (now_ms - last_beat_ms) >= (double)timeout_sec * 1000.0;
}

// Was the CHECKER itself starved? If the watchdog thread's own sleep overran by more than a
// round, the whole process was suspended or descheduled (SIGSTOP, a debugger, heavy swap) — the
// main thread's heartbeat is then stale for the same reason, not because it is wedged, and the
// checker may well resume before the main timer does. The caller skips one round instead of
// restarting. `slack_sec` covers ordinary timer jitter. `last_check_ms <= 0` = first round.
inline bool wd_checker_starved(double now_ms, double last_check_ms, double poll_sec,
                               double slack_sec = 2.0) {
    if (last_check_ms <= 0) return false;
    return (now_ms - last_check_ms) > (poll_sec + slack_sec) * 1000.0;
}

// ── take-start deadline ──────────────────────────────────────────────────────────────────
// The wedge the user actually hits lands INSIDE the take-start critical section: building the
// AVAudioEngine, pinning the built-in mic, starting the engine — synchronous CoreAudio, all on
// the main queue with g_mu held. On 2026-08-17 that section never returned (CoreAudio rejected
// the device switch with kAudioHardwareIllegalOperationError and AVFoundation deadlocked behind
// it), and the UI was dead for 35 s until the generic heartbeat timeout fired.
//
// So that one section gets its own, much tighter deadline. It cannot replace the heartbeat —
// which also covers the model reload, the editor spawn, and every AppKit callback, and therefore
// has to stay generous — but it collapses the dead window for the common case. Both watchers end
// in the same restart_process_now; only the reason string (and the wait) differ.
inline int wd_takestart_min_sec() { return 3; }

// <= 0 disables the deadline; anything positive is clamped up to wd_takestart_min_sec(). The
// floor matters: mic warm-up is ~0.5-1.5 s and the HAL-recovery path may start the engine twice,
// so a 1 s "deadline" would restart the daemon on every healthy take.
inline int wd_takestart_timeout_sec(int requested_sec) {
    if (requested_sec <= 0) return 0;
    return requested_sec < wd_takestart_min_sec() ? wd_takestart_min_sec() : requested_sec;
}

// Poll cadence (seconds) for the deadline check. Fixed and fast — the deadline itself is small,
// and a round costs two atomic loads, so there is nothing to save by polling lazily.
inline double wd_takestart_poll_sec() { return 1.0; }

// Has an armed deadline passed? `deadline_ms` is an uptime-ms stamp, 0 = nothing armed.
inline bool wd_deadline_expired(double now_ms, double deadline_ms) {
    return deadline_ms > 0 && now_ms >= deadline_ms;
}

// Is an automatic restart currently held off? A restart can ABORT (no replacement daemon could be
// spawned, so tearing down would leave no daemon at all — a wedged one beats none). The main
// thread is still wedged when that happens, so both watchers would fire again on their very next
// round: a hot loop of failing spawns, each dragging a `sample` behind it, for as long as whatever
// broke posix_spawn stays broken. The abort therefore stamps a backoff and both watchers honour
// it. Only automatic triggers back off — a user asking for a restart is never made to wait.
// `until_ms` is an uptime-ms stamp, 0 = no backoff pending.
inline bool wd_in_backoff(double now_ms, double until_ms) {
    return until_ms > 0 && now_ms < until_ms;
}

// Does this restart reason mean something was WEDGED? Only those are worth paying a couple of
// seconds to snapshot (`sample`) before the process is torn down: a user-initiated ⟳ / `restart`
// has nothing to explain, and the snapshot would only delay a restart the user is waiting on.
inline bool wd_reason_is_wedge(const char *reason) {
    if (!reason) return false;
    return std::strcmp(reason, "watchdog")     == 0 ||
           std::strcmp(reason, "socket-force") == 0 ||
           std::strcmp(reason, "take-start")   == 0;
}
