#pragma once
// Pure idle-unload decisions extracted from the daemon's idle timer so they can be
// unit-tested without AppKit / a live whisper context (`make test`; gotcha #19). The
// side effects stay in dictate.mm — the NSTimer fires the poll, whisper_free() releases
// the ~573 MB Metal context (gotcha #7), and g_mu serializes it against the worker
// (gotcha #5) — only the timing/gate arithmetic lives here.

// Should the idle clock be treated as "still active" this tick? True when a take is in
// flight, an async finish/cancel is still decoding (g_finishing), the post-take editor is
// open (a mini-take may decode), OR the model is already unloaded (nothing to free) — in
// every such case the caller resets last_active to now and skips the unload check.
inline bool idle_is_active(bool has_session, bool finishing, bool editor_open,
                           bool model_loaded) {
    return has_session || finishing || editor_open || !model_loaded;
}

// Should the resident model be freed now? True iff the feature is enabled (timeout_sec>0),
// the model is loaded, nothing is active, and the idle interval has elapsed. Self-contained
// (re-checks active) so it is safe to call standalone. Times in milliseconds.
inline bool idle_should_unload(double now_ms, double last_active_ms, int timeout_sec,
                               bool has_session, bool finishing, bool editor_open,
                               bool model_loaded) {
    if (timeout_sec <= 0) return false;                                  // feature disabled (default)
    if (idle_is_active(has_session, finishing, editor_open, model_loaded)) return false;
    return (now_ms - last_active_ms) >= (double)timeout_sec * 1000.0;
}

// Poll cadence (seconds) for a given idle timeout: a fraction of the timeout, clamped to
// [1, 10] s, so the unload fires within ~one tick of the deadline without busy-polling a
// short timeout or lagging far past a long one.
inline double idle_poll_interval_sec(int timeout_sec) {
    double iv = timeout_sec < 30 ? (double)timeout_sec / 3.0 : 10.0;
    if (iv < 1.0) iv = 1.0;
    return iv;
}
