// Unit tests for the daemon's pure idle-unload decisions (src/dictate_idle.h).
// The side effects (NSTimer poll, whisper_free of the ~573 MB Metal ctx, the g_mu gate
// against the worker) stay in dictate.mm and are exercised e2e; here we pin the gate +
// timing arithmetic. gotcha #7 (resident-vs-idle trade-off) / gotcha #19 (off-Mac tests).
#include "doctest.h"
#include "dictate_idle.h"

TEST_CASE("idle_is_active: any in-flight state (or an already-freed model) counts as active") {
    CHECK_FALSE(idle_is_active(false, false, false, /*model_loaded=*/true));  // fully idle, model up → not active
    CHECK(idle_is_active(true,  false, false, true));   // take in flight
    CHECK(idle_is_active(false, true,  false, true));   // async finish/cancel decoding
    CHECK(idle_is_active(false, false, true,  true));   // editor open (mini-take may decode)
    CHECK(idle_is_active(false, false, false, false));  // model already unloaded → nothing to free, reset clock
}

TEST_CASE("idle_should_unload: disabled when timeout_sec <= 0") {
    CHECK_FALSE(idle_should_unload(1e9, 0.0, 0,  false, false, false, true));
    CHECK_FALSE(idle_should_unload(1e9, 0.0, -1, false, false, false, true));
}

TEST_CASE("idle_should_unload: never unload when active") {
    // Even past the deadline, an active state blocks the unload.
    double now = 100000.0, last = 0.0; int to = 10;   // 100 s idle vs 10 s timeout
    CHECK(idle_should_unload(now, last, to, false, false, false, true));   // baseline: would unload
    CHECK_FALSE(idle_should_unload(now, last, to, true,  false, false, true));   // session live
    CHECK_FALSE(idle_should_unload(now, last, to, false, true,  false, true));   // finishing
    CHECK_FALSE(idle_should_unload(now, last, to, false, false, true,  true));   // editor open
    CHECK_FALSE(idle_should_unload(now, last, to, false, false, false, false));  // already unloaded
}

TEST_CASE("idle_should_unload: fires only after the idle interval elapses") {
    int to = 30;                       // 30 s timeout
    double last = 1000.0;              // last active at t=1 s
    // just under the deadline → keep resident
    CHECK_FALSE(idle_should_unload(last + 29999.0, last, to, false, false, false, true));
    // exactly at the deadline → unload (>=)
    CHECK(idle_should_unload(last + 30000.0, last, to, false, false, false, true));
    // well past → unload
    CHECK(idle_should_unload(last + 60000.0, last, to, false, false, false, true));
}

TEST_CASE("idle_poll_interval_sec: fraction of the timeout, clamped to [1, 10] s") {
    CHECK(idle_poll_interval_sec(300) == doctest::Approx(10.0));   // long timeout → cap at 10 s
    CHECK(idle_poll_interval_sec(30)  == doctest::Approx(10.0));   // boundary: not < 30 → 10 s
    CHECK(idle_poll_interval_sec(29)  == doctest::Approx(29.0/3.0));
    CHECK(idle_poll_interval_sec(15)  == doctest::Approx(5.0));    // 15/3
    CHECK(idle_poll_interval_sec(3)   == doctest::Approx(1.0));    // 3/3 = 1 (floor)
    CHECK(idle_poll_interval_sec(1)   == doctest::Approx(1.0));    // 1/3 → clamped up to 1
}
