// Unit tests for the daemon's main-run-loop watchdog gate (src/dictate_watchdog.h).
// The side effects (the 1 Hz main-queue heartbeat, the polling thread, the re-launch) stay
// in dictate.mm; here we pin the arming/timing arithmetic so a false restart can't creep in.
// gotcha #19 (off-Mac tests).
#include "doctest.h"
#include "dictate_watchdog.h"

TEST_CASE("wd_effective_timeout_sec: <=0 disables, small values clamp up to the floor") {
    CHECK(wd_effective_timeout_sec(0)  == 0);
    CHECK(wd_effective_timeout_sec(-5) == 0);
    CHECK(wd_effective_timeout_sec(1)  == wd_min_timeout_sec());   // too tight → clamped, never honoured
    CHECK(wd_effective_timeout_sec(wd_min_timeout_sec()) == wd_min_timeout_sec());
    CHECK(wd_effective_timeout_sec(30) == 30);
}

TEST_CASE("wd_should_restart: disabled when timeout_sec <= 0") {
    CHECK_FALSE(wd_should_restart(1e9, 1.0, 0));
    CHECK_FALSE(wd_should_restart(1e9, 1.0, -1));
}

TEST_CASE("wd_should_restart: never fires before the heartbeat is armed") {
    // last_beat == 0 means the run loop has not stamped anything yet (model still loading).
    CHECK_FALSE(wd_should_restart(1e9, 0.0, 30));
    CHECK_FALSE(wd_should_restart(1e9, -1.0, 30));
}

TEST_CASE("wd_should_restart: fires only after the timeout elapses") {
    int to = 30;
    double beat = 5000.0;                                   // last heartbeat at t=5 s
    CHECK_FALSE(wd_should_restart(beat + 1000.0,  beat, to));   // 1 s since the beat → healthy
    CHECK_FALSE(wd_should_restart(beat + 29999.0, beat, to));   // just under the deadline
    CHECK(wd_should_restart(beat + 30000.0, beat, to));         // exactly at the deadline (>=)
    CHECK(wd_should_restart(beat + 90000.0, beat, to));         // well past
}

TEST_CASE("wd_poll_interval_sec: fraction of the timeout, clamped to [1, 5] s") {
    CHECK(wd_poll_interval_sec(300) == doctest::Approx(5.0));    // long timeout → cap at 5 s
    CHECK(wd_poll_interval_sec(15)  == doctest::Approx(5.0));    // boundary: not < 15 → 5 s
    CHECK(wd_poll_interval_sec(12)  == doctest::Approx(4.0));    // 12/3
    CHECK(wd_poll_interval_sec(3)   == doctest::Approx(1.0));    // 3/3
    CHECK(wd_poll_interval_sec(1)   == doctest::Approx(1.0));    // 1/3 → clamped up to 1
}

TEST_CASE("wd_should_restart: a flagged long main-queue op (model reload) suppresses the restart") {
    int to = 30; double beat = 5000.0;
    CHECK(wd_should_restart(beat + 60000.0, beat, to, /*long_op_in_flight=*/false));   // baseline: would restart
    CHECK_FALSE(wd_should_restart(beat + 60000.0, beat, to, /*long_op_in_flight=*/true));
    // …and the flag must not resurrect a disabled or unarmed watchdog.
    CHECK_FALSE(wd_should_restart(beat + 60000.0, beat, 0, false));
    CHECK_FALSE(wd_should_restart(beat + 60000.0, 0.0,  to, false));
}

TEST_CASE("wd_checker_starved: the DEFAULT slack is the one production uses") {
    // The production call site (src/dictate.mm) omits slack_sec, so pin the default here too —
    // otherwise a change to it would keep every other assertion green while making the watchdog
    // trip on ordinary timer jitter.
    double poll = 5.0;
    CHECK_FALSE(wd_checker_starved(1000.0 + 7000.0, 1000.0, poll));   // poll + 2 s default slack → normal
    CHECK(wd_checker_starved(1000.0 + 7001.0, 1000.0, poll));         // just past it → starved
}

TEST_CASE("wd_checker_starved: the checker's own overrun suppresses the round") {
    double poll = 5.0, slack = 2.0;
    CHECK_FALSE(wd_checker_starved(1000.0, 0.0, poll, slack));            // first round → nothing to compare
    CHECK_FALSE(wd_checker_starved(1000.0, -1.0, poll, slack));
    CHECK_FALSE(wd_checker_starved(6000.0, 1000.0, poll, slack));         // exactly one poll → normal
    CHECK_FALSE(wd_checker_starved(8000.0, 1000.0, poll, slack));         // poll + slack → still normal jitter
    CHECK(wd_checker_starved(8001.0,  1000.0, poll, slack));              // just past poll+slack → starved
    CHECK(wd_checker_starved(600000.0, 1000.0, poll, slack));             // process was suspended for 10 min
}

TEST_CASE("wd_beat_interval_sec is well inside the smallest allowed timeout") {
    // Several heartbeats must fit in the timeout window, else one slow tick = a false restart.
    CHECK(wd_beat_interval_sec() * 5.0 <= (double)wd_min_timeout_sec());
}
