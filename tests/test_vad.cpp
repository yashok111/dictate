// Unit tests for the pure energy-VAD state machine + cap arithmetic (src/dictate_vad.h).
// These mirror the segment-close logic that lived in StreamingSession::processFrame.
#include "doctest.h"
#include "dictate_vad.h"

// A clearly-voiced rms (well above ABS_FLOOR and any test noise floor) and a clearly-silent one.
static constexpr double LOUD = 0.5;
static constexpr double QUIET = 0.001;   // below ABS_FLOOR=0.006 → never voiced at default noise

// Drive N voiced frames through observeIdle; return the last Onset seen.
static Segmenter::Onset enterSpeech(Segmenter &s) {
    Segmenter::Onset o = Segmenter::Onset::none;
    for (int i = 0; i < SPEECH_CONFIRM_FR; i++) o = s.observeIdle(LOUD);
    return o;
}

TEST_CASE("isVoiced: floor is max(ABS_FLOOR, noise*SPEECH_FACTOR)") {
    Segmenter s;   // default noise = 1e-4 → noise*3.5 = 3.5e-4 < ABS_FLOOR, so floor = ABS_FLOOR
    CHECK(s.isVoiced(ABS_FLOOR) == false);          // strict >, equal is not voiced
    CHECK(s.isVoiced(ABS_FLOOR - 0.001) == false);
    CHECK(s.isVoiced(ABS_FLOOR + 0.001) == true);
    SUBCASE("high noise floor dominates ABS_FLOOR") {
        s.noise = 0.01;                              // noise*3.5 = 0.035 > ABS_FLOOR
        CHECK(s.isVoiced(0.03) == false);
        CHECK(s.isVoiced(0.04) == true);
    }
}

TEST_CASE("speech onset requires SPEECH_CONFIRM_FR consecutive voiced frames") {
    Segmenter s;
    for (int i = 0; i < SPEECH_CONFIRM_FR - 1; i++) {
        CHECK(s.observeIdle(LOUD) == Segmenter::Onset::none);
        CHECK(s.inSpeech == false);
    }
    CHECK(s.observeIdle(LOUD) == Segmenter::Onset::fromPreroll);   // the confirming frame
    CHECK(s.inSpeech == true);
}

TEST_CASE("a silent frame resets the speech run (must be CONSECUTIVE)") {
    Segmenter s;
    s.observeIdle(LOUD);                 // speechRun = 1
    s.observeIdle(QUIET);               // resets speechRun to 0
    CHECK(s.inSpeech == false);
    // now a single voiced frame is run=1 again, still no onset (CONFIRM_FR=2)
    if (SPEECH_CONFIRM_FR >= 2) {
        CHECK(s.observeIdle(LOUD) == Segmenter::Onset::none);
        CHECK(s.inSpeech == false);
    }
}

TEST_CASE("segment closes after SILENCE_CLOSE_FR silent frames") {
    Segmenter s; enterSpeech(s);
    REQUIRE(s.inSpeech == true);
    for (int i = 0; i < SILENCE_CLOSE_FR - 1; i++)
        CHECK(s.observeSpeech(QUIET, /*tooLong=*/false) == false);   // not closed yet
    CHECK(s.observeSpeech(QUIET, false) == true);                    // the closing frame
    CHECK(s.inSpeech == false);
    CHECK(s.contiguousReopen == false);   // a real-silence close is NOT a forced cut
}

TEST_CASE("a voiced frame mid-segment resets the silence run") {
    Segmenter s; enterSpeech(s);
    for (int i = 0; i < SILENCE_CLOSE_FR - 1; i++) s.observeSpeech(QUIET, false);
    CHECK(s.observeSpeech(LOUD, false) == false);   // voiced → silenceRun back to 0
    for (int i = 0; i < SILENCE_CLOSE_FR - 1; i++)
        CHECK(s.observeSpeech(QUIET, false) == false);
    CHECK(s.observeSpeech(QUIET, false) == true);    // needs a full new run of silence
}

TEST_CASE("tooLong forces a cut even while voiced, and arms contiguousReopen") {
    Segmenter s; enterSpeech(s);
    CHECK(s.observeSpeech(LOUD, /*tooLong=*/true) == true);   // forced cut despite voiced
    CHECK(s.inSpeech == false);
    CHECK(s.contiguousReopen == true);
    CHECK(s.sinceCut == 0);
}

TEST_CASE("contiguousReopen makes the next onset start CLEARED (no pre-roll)") {
    Segmenter s; enterSpeech(s);
    s.observeSpeech(LOUD, /*tooLong=*/true);    // forced cut → contiguousReopen = true
    REQUIRE(s.contiguousReopen == true);
    Segmenter::Onset o = enterSpeech(s);        // re-enter speech immediately (no real pause)
    CHECK(o == Segmenter::Onset::cleared);
    CHECK(s.contiguousReopen == false);         // consumed by the onset
}

TEST_CASE("a real pause (SILENCE_CLOSE_FR idle frames) clears contiguousReopen") {
    Segmenter s; enterSpeech(s);
    s.observeSpeech(LOUD, true);                 // forced cut → contiguousReopen = true, sinceCut = 0
    REQUIRE(s.contiguousReopen == true);
    for (int i = 0; i < SILENCE_CLOSE_FR - 1; i++) {
        s.observeIdle(QUIET);
        CHECK(s.contiguousReopen == true);       // not yet
    }
    s.observeIdle(QUIET);                         // the SILENCE_CLOSE_FR-th idle frame
    CHECK(s.contiguousReopen == false);
    // and now the next onset uses the pre-roll again
    CHECK(enterSpeech(s) == Segmenter::Onset::fromPreroll);
}

TEST_CASE("noise floor adapts ONLY on silent idle frames") {
    Segmenter s;
    double n0 = s.noise;
    s.observeIdle(QUIET);                 // silent → EMA updates
    CHECK(s.noise > n0);                  // 0.95*n0 + 0.05*QUIET, QUIET>n0 → rises
    double n1 = s.noise;
    s.observeIdle(LOUD);                 // voiced → noise unchanged (run counting only)
    CHECK(s.noise == doctest::Approx(n1));
}

TEST_CASE("noise floor is NOT touched while in speech") {
    Segmenter s; enterSpeech(s);
    double n = s.noise;
    s.observeSpeech(QUIET, false);
    s.observeSpeech(LOUD, false);
    CHECK(s.noise == doctest::Approx(n));
}

TEST_CASE("seg_exceeds_max: hard length cap at MAX_SEG_FR*FRAME samples") {
    const std::size_t cap = (std::size_t)MAX_SEG_FR * FRAME;
    CHECK(seg_exceeds_max(cap) == true);
    CHECK(seg_exceeds_max(cap + 1) == true);
    CHECK(seg_exceeds_max(cap - 1) == false);
    CHECK(seg_exceeds_max(0) == false);
}

TEST_CASE("preroll_overflow: samples to drop to stay within PREROLL_FR frames") {
    const std::size_t maxpre = (std::size_t)PREROLL_FR * FRAME;
    CHECK(preroll_overflow(maxpre) == 0u);
    CHECK(preroll_overflow(maxpre - 100) == 0u);
    CHECK(preroll_overflow(maxpre + 1) == 1u);
    CHECK(preroll_overflow(maxpre + 480) == 480u);
}

TEST_CASE("clamp_feed: MAX_TAKE_SEC truncation arithmetic") {
    const std::size_t cap = 1000;
    SUBCASE("fits entirely") {
        auto r = clamp_feed(0, 500, cap);
        CHECK(r.take == 500u); CHECK(r.capped == false);
    }
    SUBCASE("exactly fills remaining → not flagged capped") {
        auto r = clamp_feed(500, 500, cap);
        CHECK(r.take == 500u); CHECK(r.capped == false);
    }
    SUBCASE("partial: clamps to remaining and flags capped") {
        auto r = clamp_feed(600, 500, cap);
        CHECK(r.take == 400u); CHECK(r.capped == true);
    }
    SUBCASE("already full → drop everything") {
        auto r = clamp_feed(1000, 100, cap);
        CHECK(r.take == 0u); CHECK(r.capped == true);
    }
    SUBCASE("over-full (defensive) → drop everything") {
        auto r = clamp_feed(1200, 100, cap);
        CHECK(r.take == 0u); CHECK(r.capped == true);
    }
    SUBCASE("zero input below cap → no-op, not capped") {
        auto r = clamp_feed(0, 0, cap);
        CHECK(r.take == 0u); CHECK(r.capped == false);
    }
}

// ── forced-cut placement (bug-hunt F107, F042) ──
TEST_CASE("cut_tail_frames: carries the frames after the quietest recent frame") {
    const double r1[] = {0.5, 0.4, 0.1, 0.6, 0.7};          // quietest at index 2 → carry 2
    CHECK(cut_tail_frames(r1, 5) == 2);
    const double r2[] = {0.5, 0.6, 0.7};                     // quietest first → carry the rest
    CHECK(cut_tail_frames(r2, 3) == 2);
    const double r3[] = {0.7, 0.6, 0.2};                     // quietest last → cut at the cap
    CHECK(cut_tail_frames(r3, 3) == 0);
    const double r4[] = {0.2, 0.5, 0.2, 0.5};                // tie → the later one, shorter tail
    CHECK(cut_tail_frames(r4, 4) == 1);
    CHECK(cut_tail_frames(r1, 0) == 0);
    CHECK(cut_tail_frames(r1, 1) == 0);
}
TEST_CASE("preroll_overflow_armed: holds tail + a full close of silence beyond the normal pre-roll") {
    const std::size_t armed = (std::size_t)(PREROLL_FR + CUT_WIN_FR + SILENCE_CLOSE_FR) * FRAME;
    CHECK(preroll_overflow_armed(armed) == 0);
    CHECK(preroll_overflow_armed(armed + 7) == 7);
    CHECK(preroll_overflow((std::size_t)(PREROLL_FR + 1) * FRAME) == (std::size_t)FRAME);   // the normal budget is unchanged
}

TEST_CASE("Segmenter: a louder room raises the floor; speech dips do not (bug-hunt F043)") {
    Segmenter s;                                   // floor starts at 1e-4
    for (int i = 0; i < 400; i++) s.observeIdle(0.05);   // a fan comes on: constant 0.05
    CHECK_FALSE(s.isVoiced(0.05));                 // after ~6 s the fan is the new floor
    Segmenter t;
    for (int i = 0; i < 400; i++) t.observeIdle(i % 10 == 0 ? 0.001 : 0.2);   // speech with dips
    CHECK(t.isVoiced(0.2));                        // dips keep the floor low → speech stays voiced
}
TEST_CASE("Segmenter: cap and pause on the same frame do not arm the contiguous seam (bug-hunt F108)") {
    Segmenter s; s.inSpeech = true; s.silenceRun = SILENCE_CLOSE_FR - 1;
    CHECK(s.observeSpeech(0.0, /*tooLong=*/true));
    CHECK_FALSE(s.contiguousReopen);
    Segmenter t; t.inSpeech = true;
    CHECK(t.observeSpeech(0.5, true));             // cap mid-speech → armed
    CHECK(t.contiguousReopen);
}
