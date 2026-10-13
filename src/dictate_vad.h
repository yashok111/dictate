#pragma once
// VAD / segmentation: the pure, platform-independent decision logic extracted from
// StreamingSession::processFrame so it can be unit-tested without AVFoundation/Accelerate/
// whisper (`make test`; gotcha #19). The audio BUFFER management — pre-roll, open segment,
// preview snapshot, worker queue — stays in dictate.mm; this header owns only the SCALAR
// energy-VAD state machine that decides, per 30 ms frame, when speech starts and when a
// segment closes. RMS is computed by the caller (Accelerate vDSP on macOS) and passed in
// as a double, so nothing here depends on a platform audio API.
#include <cstddef>
#include <algorithm>

// VAD / segmentation tuning (all derived from a 30 ms frame @ 16 kHz = 480 samp).
constexpr int    FRAME             = 480;
constexpr double SPEECH_FACTOR     = 3.5;     // speech if rms > noise_floor * this …
constexpr double ABS_FLOOR         = 0.006;   // … but never below this absolute rms
constexpr int    SPEECH_CONFIRM_FR = 2;       // ~60 ms of speech to enter a segment
constexpr int    SILENCE_CLOSE_FR  = 23;      // ~700 ms of silence closes a segment
constexpr int    PREROLL_FR        = 10;      // ~300 ms kept before speech onset
constexpr int    MAX_SEG_FR        = 666;     // ~20 s hard cap on a single segment

// Open segment hit the hard length cap → the caller must force a cut. `curSamples` is the
// open segment's current length (cur_.size()).
inline bool seg_exceeds_max(std::size_t curSamples) {
    return curSamples >= (std::size_t)MAX_SEG_FR * FRAME;
}
// Leading samples the caller must drop so the rolling pre-roll never exceeds PREROLL_FR
// frames. 0 when the pre-roll is still within budget.
inline std::size_t preroll_overflow(std::size_t prerollSamples) {
    std::size_t maxpre = (std::size_t)PREROLL_FR * FRAME;
    return prerollSamples > maxpre ? prerollSamples - maxpre : 0;
}

// Forced-cut placement (F107). A segment that hits MAX_SEG_FR mid-utterance is cut at the
// QUIETEST of its last CUT_WIN_FR frames instead of at the cap itself — the cap lands at an
// arbitrary frame, usually inside a word, and the two halves then decode as two garbled words.
constexpr int CUT_WIN_FR = 15;   // ~450 ms searched back from the cap

// Given the RMS of the last `n` frames of the segment (n ≤ CUT_WIN_FR), oldest first, return
// how many TRAILING frames to carry into the next segment: the frames after the quietest one
// (ties → the latest quietest, so the carried tail is the shortest). 0 when n ≤ 0.
inline int cut_tail_frames(const double *rms, int n) {
    if (n <= 0) return 0;
    int best = n - 1;
    for (int i = n - 2; i >= 0; i--) if (rms[i] < rms[best]) best = i;
    return n - 1 - best;
}

// Pre-roll budget while a forced-cut seam is armed (Segmenter::contiguousReopen): the carried
// tail plus every frame until the continuation is confirmed — up to a full close of silence —
// must survive, because the continuation segment is seeded from all of it (F042).
inline std::size_t preroll_overflow_armed(std::size_t prerollSamples) {
    std::size_t maxpre = (std::size_t)(PREROLL_FR + CUT_WIN_FR + SILENCE_CLOSE_FR) * FRAME;
    return prerollSamples > maxpre ? prerollSamples - maxpre : 0;
}

// The scalar energy-VAD segmenter. One instance per take, driven once per 30 ms frame on
// the (single) audio thread. The caller owns the audio buffers and reacts to the decisions
// returned here. Mirrors the original processFrame state machine exactly.
struct Segmenter {
    bool   inSpeech = false;
    int    speechRun = 0, silenceRun = 0;
    double noise = 1e-4;
    bool   contiguousReopen = false;   // last close was a MAX_SEG forced cut → next seg skips pre-roll…
    int    sinceCut = 0;               // …unless ≥SILENCE_CLOSE_FR of real silence follows (a NEW utterance)

    // Minimum-statistics floor (F043). `noise` adapts only on unvoiced frames, so a room that got
    // louder than noise*SPEECH_FACTOR (a fan, music) made EVERY frame voiced and the floor could
    // never rise: the take turned into back-to-back 20 s segments of noise. Track the quietest
    // frame of each MINSTAT_BLOCK_FR block; when even the quietest frame of the last
    // MINSTAT_BLOCKS blocks (~6 s) still reads as speech, that level is the new floor. Real
    // speech has inter-word dips far below its peaks, so it does not trip this.
    static constexpr int MINSTAT_BLOCK_FR = 50;   // ~1.5 s per block
    static constexpr int MINSTAT_BLOCKS   = 4;
    double blockMin = 1e9; int blockN = 0;
    double blockMins[MINSTAT_BLOCKS] = {1e9, 1e9, 1e9, 1e9}; int blocksN = 0;

    void trackFloor(double rms) {
        if (rms < blockMin) blockMin = rms;
        if (++blockN < MINSTAT_BLOCK_FR) return;
        for (int i = 1; i < MINSTAT_BLOCKS; i++) blockMins[i - 1] = blockMins[i];
        blockMins[MINSTAT_BLOCKS - 1] = blockMin;
        if (blocksN < MINSTAT_BLOCKS) blocksN++;
        blockMin = 1e9; blockN = 0;
        if (blocksN < MINSTAT_BLOCKS) return;
        double m = blockMins[0];
        for (int i = 1; i < MINSTAT_BLOCKS; i++) m = std::min(m, blockMins[i]);
        // The quietest frame of ~6 s is still "speech" → the room got louder. Set the floor to HALF
        // that level, not to it: the threshold becomes 1.75×m, so the steady noise reads as silence
        // while speech at twice the noise still reads as speech. Setting it to m (threshold 3.5×m)
        // could put ordinary speech in a noisy room below the threshold for good.
        if (isVoiced(m)) noise = m / 2;
    }

    bool isVoiced(double rms) const { return rms > std::max(ABS_FLOOR, noise * SPEECH_FACTOR); }

    // What the caller must do with its pre-roll / open-segment buffers when speech onsets.
    enum class Onset {
        none,         // still idle this frame
        fromPreroll,  // speech began → seed the open segment from the pre-roll buffer
        cleared,      // speech began as a contiguous continuation of a >20 s utterance → seed from the
                      // pre-roll too: since the cut it holds only the carried tail + post-cut frames
    };

    // Drive while NOT in speech. Adapts the noise floor on silence, counts the speech run,
    // and reports onset. The caller inserts+trims its pre-roll buffer around this call (use
    // preroll_overflow); on a non-`none` return it seeds the open segment accordingly.
    Onset observeIdle(double rms) {
        trackFloor(rms);
        bool voiced = isVoiced(rms);
        if (!voiced) {
            noise = 0.95 * noise + 0.05 * rms;
            // A genuine pause after a MAX_SEG forced cut means the next utterance is NEW, not
            // a continuation → stop suppressing its pre-roll once a full close of silence passes.
            if (contiguousReopen && ++sinceCut >= SILENCE_CLOSE_FR) contiguousReopen = false;
        }
        if (voiced && ++speechRun >= SPEECH_CONFIRM_FR) {
            inSpeech = true; silenceRun = 0; speechRun = 0;
            if (contiguousReopen) { contiguousReopen = false; return Onset::cleared; }
            return Onset::fromPreroll;
        }
        if (!voiced) speechRun = 0;
        return Onset::none;
    }

    // Drive while IN speech, AFTER the caller appended this frame to the open segment.
    // `tooLong` = the caller's seg_exceeds_max(cur_.size()) check. Returns true if the
    // segment closes now; on a forced (tooLong) cut, arms the contiguous-reopen seam so the
    // next segment skips its pre-roll (the audio is contiguous — no duplicate at the seam).
    bool observeSpeech(double rms, bool tooLong) {
        trackFloor(rms);
        bool voiced = isVoiced(rms);
        if (voiced) silenceRun = 0; else silenceRun++;
        if (silenceRun >= SILENCE_CLOSE_FR || tooLong) {
            // A real pause closing the segment on the very frame the cap is hit is NOT a cut
            // mid-utterance: arming the seam then would treat the next utterance as contiguous and
            // drop its pre-roll, clipping the first word (F108).
            const bool paused = silenceRun >= SILENCE_CLOSE_FR;
            inSpeech = false; silenceRun = 0; speechRun = 0;
            if (tooLong && !paused) { contiguousReopen = true; sinceCut = 0; }
            return true;
        }
        return false;
    }
};

// MAX_TAKE_SEC cap: how many of the incoming `n` samples to accept given the take already
// holds `curSize`, capped at `cap` total samples. Mirrors StreamingSession::feed's clamp.
// `take == 0 && capped` ⟺ the take is already full (drop everything).
struct FeedClamp { std::size_t take; bool capped; };
inline FeedClamp clamp_feed(std::size_t curSize, std::size_t n, std::size_t cap) {
    if (curSize >= cap) return { 0, true };
    if (n > cap - curSize) return { cap - curSize, true };
    return { n, false };
}
