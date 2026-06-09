// dictate.mm — native push-to-talk dictation for macOS, with streaming.
//
// Architecture: a resident DAEMON holds the whisper model + microphone, and thin
// CLIENT commands (start/stop/cancel) talk to it over a Unix-domain socket. This
// is what makes streaming possible: one process spans the whole take, so audio
// can be transcribed WHILE you speak instead of all-at-once on stop.
//
//   dictate daemon            resident server (auto-spawned by the client)
//   dictate start             begin a take          (idempotent)
//   dictate stop              finalize → prints transcript to stdout
//   dictate cancel            discard the current take
//   dictate ping              "pong" if a daemon is alive
//   dictate --file a.wav      one-shot, no daemon: stream a 16 kHz mono WAV
//   dictate --file a.wav --once   one-shot, single-pass (for A/B comparison)
//
// Streaming model: an energy-VAD segments the mic stream at natural pauses; each
// closed segment is queued to a single worker thread that runs whisper_full and
// appends the text. On stop only the trailing (open) segment is left to finish,
// so stop returns almost immediately. A full-buffer single pass is kept as a
// fallback when the VAD detects nothing.
//
// The model loads ONCE (resident); the clipboard is written via NSPasteboard
// (UTF-8-native — no pbcopy mojibake). It speaks the same start/stop/cancel CLI
// as the old `voice-dictate`, so Hammerspoon only needs its path swapped.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AppKit/AppKit.h>
#import <Accelerate/Accelerate.h>
#import <Carbon/Carbon.h>   // global hotkey: RegisterEventHotKey, kVK_*, cmdKey/shiftKey
#import <ApplicationServices/ApplicationServices.h>   // CGEvent (synthetic ⌘V) + AXIsProcessTrusted

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <cstdarg>
#include <string>
#include <vector>
#include <queue>
#include <mutex>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <algorithm>
#include <memory>
#include <fstream>          // read the user dictionary file (initial_prompt lexical bias)
#include <sstream>          // slurp it into a string for dict::build_initial_prompt
#include <chrono>
#include <cerrno>
#include <csignal>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <mach-o/dyld.h>
#include <spawn.h>           // posix_spawn — spawn the editor safely from the multithreaded daemon
#include <crt_externs.h>     // _NSGetEnviron — environment for posix_spawn
#include <sys/wait.h>        // waitpid — reap the editor child + recover if it dies
#include <sys/time.h>        // struct timeval — SO_RCVTIMEO on accepted client sockets
#include <dirent.h>

#include "whisper.h"
#include "ggml-backend.h"

// Pure logic extracted into platform-independent headers (unit-tested via `make test`;
// see tests/ + gotcha #19). Included here so dictate.mm and the doctest binary share ONE
// definition — no divergence: WAV reader, whitespace normalizer, socket verb parser,
// VAD/segmentation, editor model, peer-auth, and the user-dictionary → initial_prompt builder.
#include "dictate_wav.h"
#include "dictate_text.h"
#include "dictate_proto.h"
#include "dictate_vad.h"
#include "dictate_editmodel.h"
#include "dictate_conf.h"
#include "dictate_authgen.h"
#include "dictate_dict.h"
#include "dictate_idle.h"
#include "dictate_edscroll.h"
#include "dictate_capture.h"
#include "dictate_log.h"

// Homebrew ships ggml's CPU/Metal backends as separate plugin .so files loaded at
// runtime (otherwise the registry is empty → whisper_init aborts, devices=0).
#ifndef GGML_LIBEXEC
#define GGML_LIBEXEC "/opt/homebrew/opt/ggml/libexec"
#endif

// $DICTATE_SOCK overrides the socket so a test daemon can run on a throwaway path without
// clashing with the installed daemon (default /tmp/dictate.sock).
static const std::string SOCK_PATH_S = getenv("DICTATE_SOCK") ? getenv("DICTATE_SOCK") : "/tmp/dictate.sock";
static const char *SOCK_PATH  = SOCK_PATH_S.c_str();
static const char *STATE_FILE = "/tmp/dictate.recording";   // present iff capture is live

// VAD / segmentation tuning (FRAME, SPEECH_FACTOR, ABS_FLOOR, SPEECH_CONFIRM_FR,
// SILENCE_CLOSE_FR, PREROLL_FR, MAX_SEG_FR) + the pure energy-VAD state machine moved to
// src/dictate_vad.h (unit-tested via `make test`; #included above).
static const int    MAX_TAKE_SEC      = 120;     // hard cap on ONE take's buffered audio. Bounds memory on
                                                 // EVERY entry path (mic, socket `start`, editor mini-take),
                                                 // not just the GUI 60 s timer; full_ is reserved to this so
                                                 // the realtime tap thread also never reallocates (gotcha #6).
// Daemon spawn / liveness polling — named to avoid magic numbers (ES.45).
static const int    DAEMON_POLL_TRIES = 300;          // ~6 s total (covers the model-load window)
static const long   DAEMON_POLL_NS    = 20*1000*1000; // 20 ms between client connect attempts
static const long   LIVE_POLL_NS      = 10*1000*1000; // 10 ms between live-flag checks

static double now_ms(void) { return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1.0e6; }

// Default whisper CPU-thread count. This workload is GPU(Metal)-bound, so the thread
// count barely moves transcription time (measured on M1 Pro: 2…8 threads all ≈ equal).
// We still default to the performance-core count (perflevel0) instead of every logical
// core: it avoids scheduling whisper threads onto the efficiency cores for zero
// throughput gain, leaving them free for the UI. Override with WHISPER_THREADS=N (N>0);
// falls back to ≤8 logical cores on non-Apple-Silicon.
static int default_threads(void) {
    if (const char *e = getenv("WHISPER_THREADS")) { int n = atoi(e); if (n > 0) return n; }
    int pcores = 0; size_t sz = sizeof(pcores);
    if (sysctlbyname("hw.perflevel0.physicalcpu", &pcores, &sz, nullptr, 0) == 0 && pcores > 0)
        return pcores;
    return (int)std::min<NSUInteger>(8, [[NSProcessInfo processInfo] activeProcessorCount]);
}

// ── tiny RIFF/WAVE PCM16 reader (downmix → mono float) — moved to src/dictate_wav.h
//    (unit-tested via `make test`; #included above). Used by --file / feedfile paths. ────

static std::string g_vad_model;       // Silero VAD model path; empty → VAD disabled
static std::string g_initial_prompt;  // user-dictionary lexical bias (whisper initial_prompt); empty → none

// whisper context params shared by daemon + --file paths. Flash attention runs the
// attention on Metal with far less memory traffic — measured ~20% faster transcription
// on the large-v3-turbo model (M1 Pro: 18.9 s clip 1.63 s → 1.31 s) with byte-identical
// output. Default ON; WHISPER_FLASH=0 restores the old non-flash path for A/B.
static whisper_context_params make_context_params(void) {
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = true;
    const char *fa = getenv("WHISPER_FLASH");
    cp.flash_attn = !(fa && !strcmp(fa, "0"));   // default ON; WHISPER_FLASH=0 disables
    return cp;
}

// ── post-normalization of the FINAL transcript ───────────────────────────────
// Clean whisper's raw output (sentence capitalization, punctuation spacing, ellipsis,
// em-dash) before it reaches paste or the editor. The transform is pure logic in
// dictate_text.h (`normalize_text`, unit-tested via `make test`, gotcha #19); this only
// gates it. Default ON; DICTATE_NORMALIZE=0 restores raw whisper output (and gives an A/B
// against the normalizer). Applied ONLY at the take boundary — NOT inside finish(), which
// is shared with the editor mini-take where a single-word correction must stay verbatim
// (sentence-capitalizing a one-word replacement would be wrong).
static bool normalize_enabled(void) {
    static const bool on = []{ const char *e = getenv("DICTATE_NORMALIZE"); return !(e && !strcmp(e, "0")); }();
    return on;
}
static std::string finalize_transcript(std::string text) {
    return normalize_enabled() ? normalize_text(text) : text;
}

// ── whisper params shared by streaming + single-pass ─────────────────────────
static whisper_full_params make_params(const char *lang, int nthreads) {
    whisper_full_params wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    wp.language        = lang;
    wp.n_threads       = nthreads;
    wp.translate       = false;
    wp.no_timestamps   = true;
    wp.print_progress  = false;
    wp.print_realtime  = false;
    wp.print_timestamps= false;
    wp.print_special   = false;
    wp.suppress_nst    = true;   // drop non-speech tokens
    // whisper.cpp's built-in Silero VAD: trims silence inside whatever we pass and
    // is what actually kills the «Продолжение следует…» silence hallucination
    // (suppress_nst alone doesn't). This is the same VAD the old shell script used.
    if (!g_vad_model.empty()) {
        wp.vad            = true;
        wp.vad_model_path = g_vad_model.c_str();
        wp.vad_params     = whisper_vad_default_params();
        wp.vad_params.min_silence_duration_ms = 200;
        wp.vad_params.speech_pad_ms           = 60;
    }
    // User-dictionary lexical bias: point whisper at the prompt built once at startup from the
    // dictionary file. initial_prompt is a NON-OWNING const char*, so it must reference storage
    // that outlives the whisper_full call → the process-lifetime global g_initial_prompt. It is a
    // short, token-budgeted vocab list (not prose), so the turbo model doesn't loop on it (gotcha #11).
    if (!g_initial_prompt.empty()) wp.initial_prompt = g_initial_prompt.c_str();
    return wp;
}

// whisper output: the assembled segment text + the per-token (text, prob) stream with
// whisper's special tokens (sot / lang / timestamps / eot, id ≥ whisper_token_eot) filtered
// out — so concatenating the kept token texts reproduces `text` byte-for-byte. The token
// probabilities (whisper_full_get_token_p) drive the editor's per-word confidence highlight.
struct WhisperOut { std::string text; std::vector<conf::Token> tokens; };

static WhisperOut run_whisper_tok(whisper_context *ctx, const std::vector<float> &a,
                                  const char *lang, int nthreads) {
    WhisperOut out;
    if (a.size() < (size_t)WHISPER_SAMPLE_RATE/10) return out;   // < 0.1 s, skip
    whisper_full_params wp = make_params(lang, nthreads);
    // NB: shrinking wp.audio_ctx to the segment length speeds the encoder but the
    // turbo model loops/hallucinates on short segments (measured: a 3 s clip degraded
    // into a repetition loop). Off-distribution positional range — leave it at default.
    if (whisper_full(ctx, wp, a.data(), (int)a.size()) != 0) return out;
    int eot = whisper_token_eot(ctx);
    int n = whisper_full_n_segments(ctx);
    for (int i=0;i<n;i++) {
        out.text += whisper_full_get_segment_text(ctx, i);
        int nt = whisper_full_n_tokens(ctx, i);
        for (int j=0;j<nt;j++) {
            if (whisper_full_get_token_id(ctx, i, j) >= eot) continue;   // skip special tokens
            const char *tt = whisper_full_get_token_text(ctx, i, j);
            out.tokens.push_back({tt ? tt : "", whisper_full_get_token_p(ctx, i, j)});
        }
    }
    return out;
}

// Text-only path (the `--once`/`--file` single-pass and the VAD-heard-nothing fallback in
// finish()). Streaming segments use run_whisper_tok directly (they also need per-word confidence).
static std::string run_whisper(whisper_context *ctx, const std::vector<float> &a,
                               const char *lang, int nthreads) {
    return run_whisper_tok(ctx, a, lang, nthreads).text;
}

// normalize_ws — moved to src/dictate_text.h (unit-tested via `make test`; #included above).

// ── StreamingSession: feed 16 kHz mono float; VAD-segment; transcribe segments
//    on a worker thread; assemble transcript in order ──────────────────────────
class StreamingSession {
public:
    std::atomic<bool> live{false};   // set true on first audio in (capture confirmed)

    StreamingSession(whisper_context *ctx, std::string lang, int nthreads)
        : ctx_(ctx), lang_(std::move(lang)), nthreads_(nthreads) {
        full_.reserve((size_t)MAX_TAKE_SEC * WHISPER_SAMPLE_RATE); // reserve the whole capped take → no realloc on the realtime tap thread
        pending_.reserve((size_t)FRAME * 16);             // steady-state remainder buffer; no first-frame realloc on the tap
        // cur_/preroll_ also live on the realtime tap path (processFrame), so reserve them too, and
        // pre-seed a small pool the worker recycles — closing a segment then swaps in a ready buffer
        // instead of allocating/regrowing cur_ on the tap thread (gotcha #6).
        cur_.reserve(SEG_SAMPLES);
        preroll_.reserve((size_t)(PREROLL_FR + 1) * FRAME);   // +1 frame: the insert precedes the overflow trim
        for (int i = 0; i < RECYCLE_SEED; i++) { std::vector<float> b; b.reserve(SEG_SAMPLES); recycle_.push_back(std::move(b)); }
        worker_ = std::thread([this]{ this->workerLoop(); });
    }

    // RAII (C.21): a joinable std::thread destroyed without join()/detach() calls
    // std::terminate(). Stopping + joining the worker here makes `delete` and stack
    // unwinding safe on EVERY path — notably daemon_start's mic-failure error path,
    // which previously deleted a still-running session and crashed the daemon.
    ~StreamingSession() {
        { std::lock_guard<std::mutex> lk(qmu_); finishing_ = true; canceled_ = true; }
        qcv_.notify_all();
        if (worker_.joinable()) worker_.join();
    }

    void feed(const float *p, size_t n) {
        // Hard-cap the buffered take so an abandoned take (e.g. a mini-take left running,
        // or a socket `start` with no `stop`) can't grow memory without bound. full_ is
        // reserved to `cap`, so clamping here also keeps the tap realloc-free (gotcha #6).
        const size_t cap = (size_t)MAX_TAKE_SEC * WHISPER_SAMPLE_RATE;
        FeedClamp fc = clamp_feed(full_.size(), n, cap);   // pure cap arithmetic (src/dictate_vad.h)
        if (fc.capped) capped_.store(true, std::memory_order_relaxed);
        if (fc.take == 0) return;                          // take already full → drop further audio
        n = fc.take;
        full_.insert(full_.end(), p, p + n);             // kept for the fallback pass
        pending_.insert(pending_.end(), p, p + n);
        // Drain whole frames, then erase the consumed prefix ONCE. Erasing per frame
        // re-shifted the remaining tail every iteration (O(frames²)); a single erase
        // keeps the realtime tap thread's cost linear in the buffer (gotcha #6).
        size_t off = 0;
        for (; pending_.size() - off >= (size_t)FRAME; off += FRAME)
            processFrame(pending_.data() + off);
        if (off) pending_.erase(pending_.begin(), pending_.begin() + off);
    }

    // Flush the open segment, drain the worker, return the assembled transcript.
    std::string finish() {
        if (seg_.inSpeech && cur_.size() >= (size_t)FRAME) enqueue(std::move(cur_));
        cur_.clear(); seg_.inSpeech = false;
        { std::lock_guard<std::mutex> lk(qmu_); finishing_ = true; } qcv_.notify_all();
        if (worker_.joinable()) worker_.join();

        std::string joined; conf_.clear();
        { std::lock_guard<std::mutex> lk(tmu_);
          // Concatenate parts AND their per-word confidence in lockstep. The editor re-tokenizes
          // the joined transcript with em_tokenize; because em_tokenize(A + " " + B) splits exactly
          // at the part boundary, the editor's word list == concat of em_tokenize(part), so conf_
          // (concat of each part's per-word confidence) aligns 1:1 with the editor's words.
          for (size_t k = 0; k < parts_.size(); k++) {
              const std::string &p = parts_[k];
              if (p.empty()) continue;
              if (!joined.empty()) joined += ' ';
              joined += p;
              const std::vector<float> &cw = partsConf_[k];   // parallel to parts_ (pushed together under tmu_)
              conf_.insert(conf_.end(), cw.begin(), cw.end());
          } }
        joined = normalize_ws(joined);

        // Fallback: VAD heard nothing but audio came in → one straight pass (carry confidence too).
        if (joined.empty() && full_.size() >= (size_t)WHISPER_SAMPLE_RATE/5) {
            WhisperOut wt = run_whisper_tok(ctx_, full_, lang_.c_str(), nthreads_);
            joined = normalize_ws(wt.text);
            conf_ = conf::words_confidence(wt.tokens);
        }
        return joined;
    }

    void cancel() {   // discard: stop worker without transcribing the tail
        { std::lock_guard<std::mutex> lk(qmu_); finishing_ = true; canceled_ = true;
          std::queue<std::vector<float>> empty; q_.swap(empty); }
        qcv_.notify_all();
        if (worker_.joinable()) worker_.join();
    }

    double seconds() const { return (double)full_.size() / WHISPER_SAMPLE_RATE; }
    size_t samples() const { return full_.size(); }
    int    segments() const { std::lock_guard<std::mutex> lk(tmu_); return (int)parts_.size(); }
    bool   wasCapped() const { return capped_.load(std::memory_order_relaxed); }  // audio hit MAX_TAKE_SEC → truncated
    // Per-word confidence for the final transcript, aligned to em_tokenize of the editor's text.
    // Valid only AFTER finish() (which assembles it); empty when no segment carried tokens.
    const std::vector<float> &confidence() const { return conf_; }

private:
    void processFrame(const float *fr) {
        // RMS via Accelerate (vectorized NEON). The scalar float→double reduction does
        // not auto-vectorize (fp reassociation is unsafe without -ffast-math), and this
        // runs once per 30 ms frame on the realtime tap thread — keep it cheap (gotcha #6).
        // The VAD DECISION (threshold, noise floor, speech/silence runs, segment-close, the
        // contiguous-reopen seam) lives in the pure Segmenter (src/dictate_vad.h, unit-tested);
        // this method only owns the audio BUFFERS.
        float rmsf; vDSP_rmsqv(fr, 1, &rmsf, (vDSP_Length)FRAME);
        double rms = rmsf;

        if (!seg_.inSpeech) {
            // keep a rolling pre-roll (the noise-floor adapt + speech-run counting happen in
            // seg_.observeIdle below; pre-roll insert/trim is independent of that scalar state)
            preroll_.insert(preroll_.end(), fr, fr+FRAME);
            if (size_t over = preroll_overflow(preroll_.size()))
                preroll_.erase(preroll_.begin(), preroll_.begin()+over);

            Segmenter::Onset onset = seg_.observeIdle(rms);
            if (onset != Segmenter::Onset::none) {
                if (onset == Segmenter::Onset::cleared) cur_.clear();   // contiguous continuation of a >20 s
                else                                    cur_ = preroll_;//   utterance forced shut by MAX_SEG: the
                preroll_.clear();                                       //   audio is contiguous, so DON'T re-prepend
                                                                        //   the pre-roll (already in the closed seg)
            }
        } else {
            cur_.insert(cur_.end(), fr, fr+FRAME);
            bool tooLong = seg_exceeds_max(cur_.size());
            if (seg_.observeSpeech(rms, tooLong)) {   // closes the segment (silence or forced cut)
                rotateSegment();                      // hand cur_ to the worker, swap in a recycled buffer (alloc-free; gotcha #6)
                // tooLong forced a cut mid-utterance (seg_ armed contiguousReopen): drop the
                // pre-roll so the contiguous next segment can't duplicate audio at the seam.
                if (tooLong) preroll_.clear();
            }
        }
    }

    void enqueue(std::vector<float> seg) {
        { std::lock_guard<std::mutex> lk(qmu_); q_.push(std::move(seg)); } qcv_.notify_all();
    }

    // Close the open segment on the REALTIME tap thread: hand cur_'s buffer to the worker and
    // swap in a recycled, pre-reserved buffer so the tap performs NO heap allocation in steady
    // state (gotcha #6). The worker returns decoded buffers to recycle_ (workerLoop); only a cold
    // start or a backed-up queue (pool drained) falls back to a bounded reserve, off the lock.
    void rotateSegment() {
        {
            std::lock_guard<std::mutex> lk(qmu_);
            q_.push(std::move(cur_));
            if (!recycle_.empty()) { cur_ = std::move(recycle_.back()); recycle_.pop_back(); }
            else cur_ = std::vector<float>{};
        }
        qcv_.notify_all();
        if (cur_.capacity() < SEG_SAMPLES) cur_.reserve(SEG_SAMPLES);   // warmup/exhaustion only — never in steady state
        cur_.clear();                                                   // reused buffer keeps its capacity
    }

    // The single worker: decode each closed segment in order as it arrives (this is the
    // "transcribe while you speak" streaming win — when stop comes, only the open tail is
    // left for finish()). Exactly one thread ever touches g_ctx (gotcha #5).
    void workerLoop() {
        for (;;) {
            std::vector<float> seg;
            {
                std::unique_lock<std::mutex> lk(qmu_);
                qcv_.wait(lk, [this]{ return !q_.empty() || finishing_; });
                if (q_.empty()) return;                 // drained + finishing → exit
                seg = std::move(q_.front()); q_.pop();   // a queued segment outranks finishing → drain it
            }
            if (canceled_) continue;
            WhisperOut wt = run_whisper_tok(ctx_, seg, lang_.c_str(), nthreads_);
            std::vector<float> cw;   // per-word confidence (computed outside tmu_ to keep the lock tight)
            if (!wt.text.empty()) cw = conf::words_confidence(wt.tokens);
            { std::lock_guard<std::mutex> lk(tmu_);
              if (!wt.text.empty()) { parts_.push_back(wt.text); partsConf_.push_back(std::move(cw)); } }
            // Return the (capacity-retaining) segment buffer to the pool so the realtime tap reuses
            // it on the next close instead of allocating (gotcha #6). Separate lock scope from tmu_
            // above → never holds both, so no lock-order inversion. Bounded by RECYCLE_MAX.
            { std::lock_guard<std::mutex> lk(qmu_); if (recycle_.size() < RECYCLE_MAX) { seg.clear(); recycle_.push_back(std::move(seg)); } }
        }
    }

    whisper_context *ctx_; std::string lang_; int nthreads_;
    static constexpr size_t SEG_SAMPLES  = (size_t)MAX_SEG_FR * FRAME;  // max open-segment length (the seg_exceeds_max bound)
    static constexpr int    RECYCLE_SEED = 4;                          // segment buffers pre-allocated so the first closes don't alloc on the tap
    static constexpr size_t RECYCLE_MAX  = 8;                          // cap on retained recycled buffers (bounded memory)
    std::vector<float> full_, pending_, cur_, preroll_;
    std::vector<std::vector<float>> recycle_;   // pool of pre-reserved segment buffers the worker returns and the tap reuses (guarded by qmu_; gotcha #6)
    Segmenter seg_;                      // pure energy-VAD scalar state machine (src/dictate_vad.h)
    std::atomic<bool> capped_{false};    // feed() hit MAX_TAKE_SEC and dropped audio (set on the tap thread, relaxed)
    std::queue<std::vector<float>> q_;
    mutable std::mutex qmu_, tmu_;
    std::condition_variable qcv_;
    bool finishing_=false;               // only ever touched under qmu_
    std::atomic<bool> canceled_{false};  // read unlocked in workerLoop → atomic (CP.2, no data race)
    std::vector<std::string> parts_;
    std::vector<std::vector<float>> partsConf_;   // per-segment per-word confidence, parallel to parts_ (under tmu_)
    std::vector<float> conf_;                     // assembled per-word confidence for the final transcript (finish())

    std::thread worker_;                 // declared LAST: started in the ctor body, so every
                                         // member above is fully initialized before it runs.
};

// ── microphone capture → 16 kHz mono → StreamingSession::feed ────────────────
static void on_capture_lost(void);   // mid-take capture rebuild failed → stop the take + notify (defined after DictateController)

@interface Recorder : NSObject
- (BOOL)startFeeding:(StreamingSession *)sess error:(NSError **)err;
- (void)stop;
@end

@implementation Recorder {
    AVAudioEngine    *_engine;
    AVAudioConverter *_conv;
    AVAudioFormat    *_outFmt;
    StreamingSession *_sess;     // non-owning; valid for the life of the take
    id                _cfgObs;   // AVAudioEngineConfigurationChange observer token
    std::shared_ptr<std::atomic<int>> _tapGuard;   // in-flight tap-callback count; -stop waits it to 0
}
- (instancetype)init {
    if ((self=[super init])) {
        _outFmt = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                   sampleRate:WHISPER_SAMPLE_RATE
                                                     channels:1 interleaved:NO];
        _tapGuard = std::make_shared<std::atomic<int>>(0);
    }
    return self;
}
- (BOOL)startFeeding:(StreamingSession *)sess error:(NSError **)err {
    _engine = [[AVAudioEngine alloc] init];
    _sess   = sess;
    // A device/route change (unplug AirPods, switch default input, sample-rate change)
    // STOPS the engine and silences the tap. Without this the take would dribble to a
    // truncated/empty transcript with no signal to the user. Rebuild + restart on change.
    __weak Recorder *weakSelf = self;
    _cfgObs = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioEngineConfigurationChangeNotification
                            object:_engine
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *note){ (void)note; [weakSelf reconfigure]; }];
    return [self installTapAndStart:err];
}
// Read the current input format, (re)build the converter, install the tap, start. Called
// on first start and again on every configuration change (with the new input format).
- (BOOL)installTapAndStart:(NSError **)err {
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *inFmt = [input inputFormatForBus:0];
    if (inFmt.sampleRate <= 0) {
        if (err) *err = [NSError errorWithDomain:@"dictate" code:1
                          userInfo:@{NSLocalizedDescriptionKey:@"нет входного устройства / доступа к микрофону"}];
        return NO;
    }
    _conv = [[AVAudioConverter alloc] initFromFormat:inFmt toFormat:_outFmt];
    AVAudioFormat *outFmt = _outFmt; AVAudioConverter *conv = _conv; StreamingSession *sess = _sess;
    const double ratio = outFmt.sampleRate / inFmt.sampleRate;
    auto guard = _tapGuard;   // shared_ptr copy → the counter outlives the Recorder if a tap is still in flight at teardown
    __block AVAudioPCMBuffer *convOut = nil;   // reused across tap callbacks → no per-callback alloc on the realtime thread (gotcha #6)

    [input installTapOnBus:0 bufferSize:4096 format:inFmt
                     block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        (void)when;
        guard->fetch_add(1, std::memory_order_relaxed);   // mark in-flight; ordering is carried by the fetch_sub(release)/-stop load(acquire) pair (gotcha #5)
        @autoreleasepool {   // drain the converter's transient autoreleased objects each callback (the realtime audio thread has no draining pool)
        // Feed the whole input buffer once, then DRAIN the converter: a sample-rate
        // conversion may not consume all input in one convertToBuffer: call, so loop
        // until it runs dry (idiomatic; avoids dropping samples at buffer boundaries).
        AVAudioFrameCount cap=(AVAudioFrameCount)(buf.frameLength*ratio)+64;
        if (!convOut || convOut.frameCapacity < cap)
            convOut=[[AVAudioPCMBuffer alloc] initWithPCMFormat:outFmt frameCapacity:cap];   // (re)allocate only when the input grows
        __block BOOL fed=NO;
        AVAudioConverterInputBlock feed = ^AVAudioBuffer * _Nullable (AVAudioPacketCount need,
                                                                      AVAudioConverterInputStatus *st){
            (void)need; if (fed){*st=AVAudioConverterInputStatus_NoDataNow;return nil;}
            fed=YES; *st=AVAudioConverterInputStatus_HaveData; return buf;
        };
        if (convOut) for (;;) {
            convOut.frameLength=0;   // reuse: convertToBuffer writes from the start and sets frameLength to what it produced
            NSError *cErr=nil;
            AVAudioConverterOutputStatus st=[conv convertToBuffer:convOut error:&cErr withInputFromBlock:feed];
            if (st==AVAudioConverterOutputStatus_Error) break;
            if (convOut.frameLength>0) {
                sess->live.store(true);                   // capture confirmed live
                sess->feed(convOut.floatChannelData[0], convOut.frameLength);
            }
            if (st!=AVAudioConverterOutputStatus_HaveData) break;   // InputRanDry / EndOfStream → done
        }
        }   // @autoreleasepool
        guard->fetch_sub(1, std::memory_order_release);   // done touching `sess`
    }];
    [_engine prepare];
    return [_engine startAndReturnError:err];
}
- (void)reconfigure {
    if (!_engine) return;                                 // already stopped
    fprintf(stderr, "audio configuration changed → rebuilding capture\n");
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    NSError *err=nil;
    if (![self installTapAndStart:&err]) {
        fprintf(stderr, "⚠ capture rebuild failed: %s\n", err.localizedDescription.UTF8String ?: "?");
        // The mic is dead; don't let the take silently dribble to the 60 s cap. Stop it + notify —
        // DEFERRED so we don't reentrantly [r stop] this very Recorder from inside its own method.
        dispatch_async(dispatch_get_main_queue(), ^{ on_capture_lost(); });
    }
}
- (void)stop {
    if (!_engine) return;
    if (_cfgObs) { [[NSNotificationCenter defaultCenter] removeObserver:_cfgObs]; _cfgObs=nil; }
    [_engine.inputNode removeTapOnBus:0];
    [_engine stop];
    // Wait out any tap callback still touching `_sess`: AVFoundation doesn't document removeTapOnBus
    // as a barrier against an already-running tap block, so without this a late tap could feed() into a
    // session finish()/cancel() is about to read/free (UAF). The tap body is sub-ms → bounded spin.
    while (_tapGuard->load(std::memory_order_acquire) != 0) { struct timespec ts{0, 100000}; nanosleep(&ts, nullptr); }
    _engine=nil; _conv=nil; _sess=nil;
}
- (void)dealloc {   // safety net: if startFeeding: failed after registering the observer, -stop is never
    if (_cfgObs) [[NSNotificationCenter defaultCenter] removeObserver:_cfgObs];   // called → remove it here
}
@end

// ── state file (Hammerspoon reads it natively to know capture is live) ────────
static void touch_state(void){ int fd=open(STATE_FILE,O_CREAT|O_WRONLY|O_CLOEXEC|O_NOFOLLOW,0600); if(fd>=0) close(fd); }
static void clear_state(void){ unlink(STATE_FILE); }

// ── local text logs: owner-only daily NDJSON under ~/.local/share/dictate/logs ──
struct TakeMeta {
    std::string id;
    std::string kind;
};

struct DetachedTake {
    std::unique_ptr<StreamingSession> session;
    TakeMeta meta;
    explicit operator bool() const { return (bool)session; }
};

static std::string local_time_string(const char *fmt) {
    time_t now = time(nullptr);
    struct tm tm{};
    localtime_r(&now, &tm);
    char buf[64];
    if (!strftime(buf, sizeof(buf), fmt, &tm)) return "";
    return buf;
}

static dlog::Date local_date_today(void) {
    time_t now = time(nullptr);
    struct tm tm{};
    localtime_r(&now, &tm);
    return {tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday};
}

static std::string log_timestamp(void) {
    std::string z = local_time_string("%Y-%m-%dT%H:%M:%S%z");
    if (z.size() == 24) z.insert(z.size() - 2, ":");
    return z;
}

static std::string log_day_filename(void) {
    return local_time_string("%Y-%m-%d.ndjson");
}

static bool mkdir_owner(const std::string &path) {
    if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) return false;
    chmod(path.c_str(), 0700);
    return true;
}

static std::string log_dir_path(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return "";
    std::string root(home);
    std::string local = root + "/.local";
    std::string share = local + "/share";
    std::string dictate = share + "/dictate";
    std::string logs = dictate + "/logs";
    if (!mkdir_owner(local) || !mkdir_owner(share) || !mkdir_owner(dictate) || !mkdir_owner(logs))
        return "";
    return logs;
}

class TakeLogger {
public:
    TakeMeta start(const char *kind) {
        if (!enabled()) return {};
        TakeMeta meta{next_id(), kind && *kind ? kind : "main"};
        event(meta, "start", {});
        return meta;
    }

    void event(const TakeMeta &meta, const char *name, std::vector<dlog::Field> fields) {
        if (!enabled()) return;
        if (meta.id.empty() || !name || !*name) return;
        std::lock_guard<std::mutex> lk(mu_);
        std::string dir = log_dir_path();
        if (dir.empty()) return;
        dlog::Event e{log_timestamp(), meta.id, meta.kind, name, std::move(fields)};
        std::string line = dlog::serialize_event(e);
        std::string path = dir + "/" + log_day_filename();
        int fd = open(path.c_str(), O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW, 0600);
        if (fd < 0) return;
        chmod(path.c_str(), 0600);
        const char *p = line.data();
        size_t n = line.size();
        while (n) {
            ssize_t w = write(fd, p, n);
            if (w < 0) { if (errno == EINTR) continue; break; }
            if (w == 0) break;
            p += w; n -= (size_t)w;
        }
        close(fd);
    }

    void prune() {
        if (!enabled()) return;
        std::lock_guard<std::mutex> lk(mu_);
        std::string dir = log_dir_path();
        if (dir.empty()) return;
        DIR *dp = opendir(dir.c_str());
        if (!dp) return;
        dlog::Date today = local_date_today();
        while (dirent *ent = readdir(dp)) {
            std::string name = ent->d_name;
            if (name == "." || name == "..") continue;
            bool is_regular = ent->d_type == DT_REG;
            if (ent->d_type == DT_UNKNOWN) {
                struct stat st{};
                std::string path = dir + "/" + name;
                is_regular = lstat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
            }
            if (dlog::should_prune(name, is_regular, today)) {
                std::string path = dir + "/" + name;
                unlink(path.c_str());
            }
        }
        closedir(dp);
    }

private:
    bool enabled() const {
        return dlog::flag_enabled(getenv("DICTATE_LOG"));
    }

    std::string next_id() {
        static std::atomic<uint64_t> seq{0};
        return local_time_string("%Y%m%dT%H%M%S") + "-" + std::to_string(++seq);
    }

    std::mutex mu_;
};

static TakeLogger g_take_logger;
static TakeMeta g_active_take;
static bool g_has_active_take = false;      // g_mu / main lifecycle
static std::string g_editor_take_id;        // main thread: parent take currently open in editor

static void log_take_cancel(const TakeMeta &meta, double seconds, const char *reason) {
    g_take_logger.event(meta, "cancel", {
        dlog::number_field("duration_sec", seconds),
        dlog::text_field("reason", reason ? reason : ""),
    });
}

static void log_transcript(const TakeMeta &meta, const std::string &rawText,
                           const std::string &finalText, double seconds, int segments) {
    g_take_logger.event(meta, "transcript", {
        dlog::text_field("raw_text", rawText),
        dlog::text_field("normalized_text", finalText),
        dlog::number_field("duration_sec", seconds),
        dlog::integer_field("segment_count", segments),
    });
}

static void log_editor_event(const char *event, const std::string &takeId, NSString *text = nil) {
    if (takeId.empty()) return;
    TakeMeta meta{takeId, "main"};
    std::vector<dlog::Field> fields;
    if (text) fields.push_back(dlog::integer_field("text_chars", (long long)text.length));
    g_take_logger.event(meta, event, std::move(fields));
}

static void log_correction_apply(const std::string &mainTakeId, const std::string &correctionId,
                                 const std::string &rawText, const std::string &appliedText,
                                 const std::string &mode, const std::string &targetText) {
    if (mainTakeId.empty()) return;
    TakeMeta meta{mainTakeId, "main"};
    g_take_logger.event(meta, "correction_apply", {
        dlog::text_field("correction_take_id", correctionId),
        dlog::text_field("mode", mode),
        dlog::text_field("raw_text", rawText),
        dlog::text_field("applied_text", appliedText),
        dlog::text_field("target_text", targetText),
    });
}

static void copy_to_clipboard(NSString *text) {
    NSPasteboard *pb=[NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}

// The screen the user is working on (the one under the pointer), falling back to the main
// screen. [NSScreen mainScreen] is "the screen with the key window" — wrong for a background
// accessory daemon with no key window, so the banner/editor could pop on the wrong monitor.
// Main-thread only (NSEvent.mouseLocation / NSScreen).
static NSScreen *active_screen(void) {
    NSPoint m = [NSEvent mouseLocation];
    for (NSScreen *s in [NSScreen screens]) if (NSPointInRect(m, s.frame)) return s;
    return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
}

// ════════════════════════════ DAEMON ════════════════════════════════════════
// RAII owners for the C handles (R.11/R.20): the model and the current take own
// themselves; raw pointers handed to helpers stay non-owning observers (R.3).
struct WhisperCtxDeleter { void operator()(whisper_context *c) const { if (c) whisper_free(c); } };
using whisper_ctx_ptr = std::unique_ptr<whisper_context, WhisperCtxDeleter>;

static whisper_ctx_ptr g_ctx;
static int   g_nthreads = 4;
static std::string g_lang = "ru";
static Recorder *g_rec = nil;
static std::unique_ptr<StreamingSession> g_sess;
static std::mutex g_mu;                 // guards g_sess / recording transitions
static std::thread g_liveWatch;         // touches STATE_FILE once capture is live
static std::atomic<bool> g_liveWatchStop{false};
static std::atomic<bool> g_finishing{false};   // an async stop (hotkey/timer) is still finalizing a take
                                               // on g_ctx; refuse a new take until it clears, so two
                                               // workers never touch the whisper context (gotcha #5)
static std::string g_model_path;               // remembered so idle-unload can reload the model (gotcha #7)
static int    g_idle_unload_sec = 0;           // DICTATE_IDLE_UNLOAD_SEC; 0 = disabled (resident — gotcha #7). Main-thread only.
static double g_last_active_ms  = 0;           // monotonic ms of last model activity = the idle clock. Main-thread only.

// Backends (the CPU/Metal ggml plugins, gotcha #1) are process-global and never freed — load
// them exactly once. The MODEL (g_ctx) may be freed + reloaded by idle-unload (gotcha #7), so
// it is (re)set on every call.
static void load_backends_and_model(const std::string &modelPath) {
    static std::once_flag backends_once;
    std::call_once(backends_once, []{
        const char *bd = getenv("DICTATE_GGML_BACKENDS");
        ggml_backend_load_all_from_path(bd ? bd : GGML_LIBEXEC);
    });
    whisper_context_params cp = make_context_params();
    g_ctx.reset(whisper_init_from_file_with_params(modelPath.c_str(), cp));
}

// Reload the model if idle-unload (gotcha #7) freed it. MUST be called with g_mu held: it
// mutates g_ctx, every take entry point reads g_ctx under g_mu, and the idle timer frees it
// under g_mu — so g_mu serializes load / use / free against the lone whisper worker (gotcha
// #5). Reload costs ~600 ms-1 s on the calling (main) thread — the price of the idle
// trade-off, paid only on the first take after an unload. Returns true if g_ctx is resident.
static bool ensure_model_loaded(void) {
    if (g_ctx) return true;
    double t0 = now_ms();
    load_backends_and_model(g_model_path);
    if (g_ctx) fprintf(stderr, "✓ model reloaded on demand (%.0f ms)\n", now_ms()-t0);
    else       fprintf(stderr, "✖ model reload failed: %s\n", g_model_path.c_str());
    return (bool)g_ctx;
}

// ── DictateController: the NSApp delegate + UI hub. Every AppKit object and every
//    recording-lifecycle entry point runs on the MAIN thread; the socket thread and
//    the worker thread marshal here via the main GCD queue. UI bodies arrive in
//    later tasks (banner=4, paste=6, menubar=7); this is the lifecycle skeleton. ──
@interface DictateController : NSObject <NSApplicationDelegate>
- (std::string)beginTakeError;                              // main; "" ok / err string
- (void)requestStop;                                       // main; async finish+paste (hotkey/menubar)
- (DetachedTake)stopDetachForSocket;                       // main; hand the take to the socket thread
- (void)stopFinishedWithText:(NSString *)ns conf:(NSString *)conf takeId:(NSString *)takeId;  // main; open editor + per-word confidence
- (void)cancel;                                            // main
- (void)toggle;                                            // main; one entry for hotkey/menubar/socket
- (void)showHint:(NSString *)h;                                  // main; transient banner hint (paste fallback)
- (void)editorAccept:(NSString *)text;                          // main; editor accepted → refocus target + paste
- (void)editorCancel;                                           // main; editor cancelled → refocus target, no paste
- (void)openEditorWithText:(NSString *)ns conf:(NSString *)conf;  // main; spawn the editor on a transcript + confidence
- (void)finalizeSocketStop:(NSString *)ns;                      // main; socket `stop` finalize (clipboard, NO editor)
@end

static DictateController *g_ctrl = nil;
static NSRunningApplication *g_target_app = nil;   // app to paste into (frontmost when the take began)
static std::atomic<bool> g_editor_open{false};     // a post-take editor window is up
static void spawn_editor(NSString *transcript, NSString *conf);    // defined in the EDITOR section, below

// A mid-take device/route change whose capture rebuild failed (Recorder reconfigure): the mic is
// dead, so stop the take cleanly (instead of dribbling to the 60 s cap) and tell the user. Main thread.
static void on_capture_lost(void) {
    [g_ctrl cancel];
    [g_ctrl showHint:@"⚠ устройство ввода изменилось — запись прервана"];
}

// ── Hotkeys (Carbon RegisterEventHotKey — virtual keycodes are keyboard-position
//    based, so keycode 2 (⌘⇧D) survives a Cyrillic layout; the chord is consumed,
//    and no Accessibility grant is needed). Handlers run on the main run loop. ──
static EventHotKeyRef  g_hkToggle  = nullptr;
static EventHotKeyRef  g_hkEsc     = nullptr;
static EventHandlerRef g_hkHandler = nullptr;   // the app event handler; installed exactly once

static OSStatus hotkey_handler(EventHandlerCallRef, EventRef ev, void *) {
    EventHotKeyID hk; GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID,
                                        nullptr, sizeof(hk), nullptr, &hk);
    if (hk.id == 1) [g_ctrl toggle];        // ⌘⇧D
    else if (hk.id == 2) [g_ctrl cancel];   // Esc (registered only for the duration of a take)
    return noErr;
}
static void install_hotkeys(void) {
    if (g_hkHandler) return;   // install the handler once — a second install would double-fire every chord
    EventTypeSpec t = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&hotkey_handler, 1, &t, nullptr, &g_hkHandler);
    EventHotKeyID idD = { 'dict', 1 };
    OSStatus s = RegisterEventHotKey(kVK_ANSI_D, cmdKey|shiftKey, idD, GetApplicationEventTarget(), 0, &g_hkToggle);
    if (s != noErr) fprintf(stderr, "⚠ hotkey ⌘⇧D registration failed (%d)\n", (int)s);
    else            fprintf(stderr, "✓ hotkey ⌘⇧D registered\n");
}
static void register_esc(void) {   // Esc cancels ONLY while a take is live (so Esc is normal elsewhere)
    if (g_hkEsc) return;
    EventHotKeyID idE = { 'dict', 2 };
    RegisterEventHotKey(kVK_Escape, 0, idE, GetApplicationEventTarget(), 0, &g_hkEsc);
}
static void unregister_esc(void) {
    if (g_hkEsc) { UnregisterEventHotKey(g_hkEsc); g_hkEsc = nullptr; }
}
// ⌘⇧D is unregistered while the editor is open so the key reaches the editor's key window
// (a Regular, frontmost app); re-registered when the editor accepts/cancels.
static void register_toggle(void) {
    if (g_hkToggle) return;
    EventHotKeyID idD = { 'dict', 1 };
    RegisterEventHotKey(kVK_ANSI_D, cmdKey|shiftKey, idD, GetApplicationEventTarget(), 0, &g_hkToggle);
}
static void unregister_toggle(void) {
    if (g_hkToggle) { UnregisterEventHotKey(g_hkToggle); g_hkToggle = nullptr; }
}

// ── Paste (synthetic ⌘V via CGEvent — needs Accessibility; degrades to clipboard-only) ──
static bool ax_trusted(bool prompt) {
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @(prompt)};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}
static void paste_text(NSString *text) {                 // main thread
    static uint64_t pasteGen = 0;                        // main-only; a newer paste cancels this one's
    uint64_t myGen = ++pasteGen;                         //   pending clipboard restore (no stale clobber)
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *orig = [pb stringForType:NSPasteboardTypeString] ?: @"";   // non-string content → restored as empty
    copy_to_clipboard(text);                             // text on the clipboard either way
    bool trusted = ax_trusted(false);
    fprintf(stderr, "paste: %lu chars, ax_trusted=%d → %s\n",
            (unsigned long)text.length, trusted, trusted ? "synth ⌘V" : "clipboard-only (grant Accessibility)");
    if (!trusted) { [g_ctrl showHint:@"готово — вставь ⌘V"]; return; }   // degrade, no synthetic key
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateCombinedSessionState);
    CGEventRef down = CGEventCreateKeyboardEvent(src, (CGKeyCode)kVK_ANSI_V, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(src, (CGKeyCode)kVK_ANSI_V, false);
    // Each event reports EXACTLY Command (overriding hardware modifier state), so a Cyrillic
    // layout or other held keys can't alter the chord. A physically-held ⌘⇧ from the triggering
    // hotkey is given ~0.2 s to release on the accept path before this fires (gotcha #4).
    CGEventSetFlags(down, kCGEventFlagMaskCommand);
    CGEventSetFlags(up,   kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, down);
    CGEventPost(kCGHIDEventTap, up);
    if (down) CFRelease(down); if (up) CFRelease(up); if (src) CFRelease(src);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4*NSEC_PER_SEC)),     // restore prior clipboard,
                   dispatch_get_main_queue(), ^{ if (paste_gen_is_current(myGen, pasteGen)) copy_to_clipboard(orig); });  // if still latest (src/dictate_authgen.h)
}

// begin a take (idempotent). returns "" on success or an error string.
// The banner is status-only (no live transcript) — the take's words surface in the post-take
// editor. Closed segments still transcribe during recording (the streaming latency win); only
// the dead open-segment live-preview path is gone.
static std::string daemon_start(const char *kind) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_sess) return (kind && !strcmp(kind, "correction")) ? "busy" : "";   // main start is idempotent; corr-start must know it failed
    if (g_finishing.load()) return "busy";                  // previous take still finalizing on g_ctx (gotcha #5)
    if (!ensure_model_loaded()) return "model load failed";  // idle-unload (gotcha #7) freed it → reload on demand
    g_last_active_ms = now_ms();                             // reset the idle-unload clock
    g_sess = std::make_unique<StreamingSession>(g_ctx.get(), g_lang, g_nthreads);
    g_rec  = [[Recorder alloc] init];
    NSError *err = nil;
    if (![g_rec startFeeding:g_sess.get() error:&err]) {
        std::string msg = err.localizedDescription.UTF8String ?: "engine start failed";
        g_sess.reset(); g_rec=nil;   // dtor joins the worker — safe (was: delete on a live thread → std::terminate)
        return msg;
    }
    g_active_take = g_take_logger.start(kind);
    g_has_active_take = !g_active_take.id.empty();
    // touch STATE_FILE only once real audio flows. The native warm-up poll
    // (DictateController warmTick) reads g_sess->live directly; the file is now just a
    // cheap external "is-recording" flag for scripts/debugging.
    // Self-defend: std::thread::operator= calls std::terminate() if the target is still
    // joinable. The stop/cancel paths join it, but don't rely on that invariant here —
    // join any prior watch locally so a new entry path can never crash the daemon.
    if (g_liveWatch.joinable()) { g_liveWatchStop.store(true); g_liveWatch.join(); }
    g_liveWatchStop.store(false);
    StreamingSession *s = g_sess.get();   // non-owning; the watch is joined before g_sess is released
    g_liveWatch = std::thread([s]{
        while (!g_liveWatchStop.load()) {
            if (s->live.load()) { touch_state(); return; }
            struct timespec ts{0, LIVE_POLL_NS}; nanosleep(&ts, nullptr);
        }
    });
    return "";
}

static void stop_live_watch(void) {
    g_liveWatchStop.store(true);
    if (g_liveWatch.joinable()) g_liveWatch.join();
}

// Detach the current take: stop the engine + live-watch + state file (quick, main-thread
// safe), and hand the session back so the caller runs the blocking finish() OFF the main
// thread (finish() joins the worker and must not freeze the Cocoa run loop).
static DetachedTake daemon_stop_detach(void) {
    DetachedTake out; Recorder *r;
    { std::lock_guard<std::mutex> lk(g_mu); out.session=std::move(g_sess); r=g_rec; g_rec=nil;
      if (g_has_active_take) { out.meta = g_active_take; g_active_take = {}; g_has_active_take = false; }
      if (out.session) g_finishing.store(true); }   // set under g_mu, atomic with the g_sess move-out, so a
                                          // concurrent start/feedfile can't slip a 2nd worker onto g_ctx
    if (!out.session) return {};
    [r stop];
    stop_live_watch(); clear_state();
    return out;
}

static void daemon_cancel(const char *reason) {
    DetachedTake take; Recorder *r;
    { std::lock_guard<std::mutex> lk(g_mu); take.session=std::move(g_sess); r=g_rec; g_rec=nil;
      if (g_has_active_take) { take.meta = g_active_take; g_active_take = {}; g_has_active_take = false; }
      if (take.session) g_finishing.store(true); }   // block a new take until the detached cancel frees g_ctx (gotcha #5)
    if (!take) return;
    [r stop];
    stop_live_watch(); clear_state();
    log_take_cancel(take.meta, take.session->seconds(), reason);
    // cancel() joins the whisper worker, which can be mid-whisper_full (~1-2 s). Run it OFF the main
    // thread so Esc-cancel / corr-cancel / editor-cancel don't freeze the run loop (mirrors requestStop's
    // detached finish()). g_finishing (set above) keeps a new take off g_ctx until the worker is joined.
    StreamingSession *raw = take.session.release();
    std::thread([raw]{
        std::unique_ptr<StreamingSession> own(raw);   // joins + frees on scope exit
        try { own->cancel(); } catch (...) {}
        g_finishing.store(false);
    }).detach();
}

// debug: feed already-loaded PCM as if it were recorded (no mic), leaving the take open so
// a subsequent `stop` returns the streamed transcript. MUST run on the main queue, like
// every other recording transition — the caller reads the WAV first (off-lock, off-main),
// so g_mu is never held across file I/O and a FIFO/device path can't wedge the daemon.
static std::string daemon_feed_audio(const std::vector<float> &audio) {
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_sess || g_finishing.load()) return "busy";
    if (!ensure_model_loaded()) return "model load failed";  // idle-unload (gotcha #7) freed it → reload on demand
    g_last_active_ms = now_ms();                             // reset the idle-unload clock
    g_sess = std::make_unique<StreamingSession>(g_ctx.get(), g_lang, g_nthreads);
    g_active_take = g_take_logger.start("main");
    g_has_active_take = !g_active_take.id.empty();
    size_t step = WHISPER_SAMPLE_RATE/10;                    // 100 ms chunks
    for (size_t i=0;i<audio.size();i+=step)
        g_sess->feed(audio.data()+i, std::min(step, audio.size()-i));
    g_sess->live.store(true); touch_state();
    return "";
}

// ── Banner look & layout (Hammerspoon-style: full-width, translucent, bordered; all tunable) ──
static const double BANNER_RADIUS    = 14;    // corner radius (HS used 14)
static const double BANNER_BG_ALPHA  = 0.5;   // background = black at this alpha (lower ⇒ more see-through, like HS)
static const double BANNER_BORDER_W  = 1;     // hairline border width
static const double BANNER_BORDER_A  = 0.6;   // border colour = white at this alpha
static const double BANNER_HMARGIN   = 12;    // gap to each screen edge; the card otherwise spans the full width
static const double BANNER_HINSET    = 28;    // text inset L/R inside the card
static const double BANNER_VINSET    = 22;    // text inset T/B inside the card
static const double BANNER_MINH      = 96;    // never shorter than this
static const double BANNER_NOMINAL_H = 120;   // nominal height that pins the top edge; the card hangs below it and grows down
static const double BANNER_MAXH_FRAC = 0.5;   // cap the card height at this fraction of the screen
static const double BANNER_VBIAS     = 0.08;  // centre this fraction of screen-height above the middle (HS feel)
static const double BANNER_TITLE_PT  = 24;    // status line   (e.g. «🎙 ЗАПИСЬ — говори»)
static const double BANNER_SUB_PT    = 14;    // dim subtitle  (e.g. «⌘⇧D — стоп · Esc — отмена»)

@implementation DictateController {
    NSPanel     *_banner;
    NSTextField *_text;
    NSTimer     *_warm;        // warm-up poll → promote «Запуск микрофона…» to «говори»
    int          _warmTicks;
    NSUInteger   _gen;         // bumped on every display change; a timed auto-hide only fires
                               // if the banner hasn't moved on since it was scheduled
    NSStatusItem *_status;     // menubar indicator
    NSTimer     *_tick;        // 1 Hz: updates the menubar clock + enforces the 60 s hard cap
    int          _secs;
    NSTimer     *_idle;        // idle-unload poll: frees the resident model after DICTATE_IDLE_UNLOAD_SEC (gotcha #7)
}

// ── recording lifecycle (all on main) ──
- (std::string)beginTakeError {
    { std::lock_guard<std::mutex> lk(g_mu); if (g_sess) return ""; }   // already recording → idempotent (don't reset banner/timer)
    std::string e = daemon_start("main");
    if (e.empty()) { g_target_app = [[NSWorkspace sharedWorkspace] frontmostApplication];   // paste target, before the editor steals focus
                     [self showWarmup]; register_esc(); [self startTimer]; }
    else if (e != "busy") [self showError:@(e.c_str())];   // "busy" = a finalize is in flight → silent no-op
    return e;
}
- (DetachedTake)stopDetachForSocket {
    DetachedTake take = daemon_stop_detach();         // sets g_finishing under g_mu if a take was live
    if (!take) return {};
    unregister_esc(); [self stopTimer]; [self showTranscribing];
    return take;
}
- (void)requestStop {
    DetachedTake take = daemon_stop_detach();         // sets g_finishing under g_mu if a take was live
    if (!take) { [self hideUI]; return; }
    unregister_esc();
    [self stopTimer];
    if (capture_stop_action(take.session->live.load(), take.session->samples())
        == CaptureStopAction::reportNoAudio) {
        log_take_cancel(take.meta, take.session->seconds(), "no_audio");
        StreamingSession *silent = take.session.release();
        std::thread([silent]{
            std::unique_ptr<StreamingSession> own(silent);
            try { own->cancel(); } catch (...) {}
            g_finishing.store(false);
        }).detach();
        [self showError:@"микрофон не передал аудио"];
        return;
    }
    [self showTranscribing];
    StreamingSession *raw = take.session.release();   // ownership handed to the background finish thread
    TakeMeta meta = take.meta;
    std::thread([self, raw, meta]{
        @autoreleasepool {                  // detached thread needs its own pool (ARC BP#5)
            std::string text;
            try { text = raw->finish(); }   // if finish() throws (bad_alloc/join) on this detached thread,
            catch (...) {}                  // an uncaught exception → std::terminate; swallow so we still
                                            // delete + clear g_finishing below (a stuck flag bricks the daemon)
            std::string finalText = text;                                  // post-normalized transcript shown in the editor
            try { finalText = finalize_transcript(text); } catch (...) {}   // post-normalize (DICTATE_NORMALIZE); by-value so a throw leaves the raw text intact, never std::terminate here
            // Per-word confidence, RE-ALIGNED onto the finalized tokenization (finalize re-cases words /
            // rewrites punctuation, so a raw-text-aligned array would drift). realign reads confidence()
            // — valid post-finish — BEFORE delete; best-effort, an empty result just disables highlighting.
            std::string confStr;
            try { confStr = conf::serialize(conf::realign(text, raw->confidence(), finalText)); } catch (...) {}
            double seconds = raw->seconds(); int segments = raw->segments();
            log_transcript(meta, text, finalText, seconds, segments);
            fprintf(stderr, "stop: %.2fs, %d seg → %zu chars\n", seconds, segments, finalText.size());
            delete raw;
            NSString *ns = finalText.empty()? nil : [NSString stringWithUTF8String:finalText.c_str()];
            NSString *confNs = [NSString stringWithUTF8String:confStr.c_str()] ?: @"";
            NSString *takeId = [NSString stringWithUTF8String:meta.id.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{ @autoreleasepool { [self stopFinishedWithText:ns conf:confNs takeId:takeId]; } });
        }
    }).detach();
}
- (void)stopFinishedWithText:(NSString *)ns conf:(NSString *)conf takeId:(NSString *)takeId {
    g_finishing.store(false);              // finalize done → a new take may start
    [self hideUI];
    g_editor_take_id = takeId.UTF8String ?: "";
    [self openEditorWithText:ns conf:conf];
}
- (void)openEditorWithText:(NSString *)ns conf:(NSString *)conf {
    if (!ns.length) { g_editor_take_id.clear(); return; }
    // Open the foreground editor on the transcript instead of pasting directly. ⌘⇧D is
    // unregistered so it reaches the editor's key window; re-registered on accept/cancel/exit.
    // `conf` carries per-word confidence (serialized) for the uncertain-word highlight.
    g_editor_open.store(true);
    unregister_toggle();
    spawn_editor(ns, conf);
}
- (void)finalizeSocketStop:(NSString *)ns {   // socket `stop` is a script/test path: clear state + clipboard, NO editor GUI
    g_finishing.store(false);
    [self hideUI];
    if (ns.length) copy_to_clipboard(ns);
}
- (void)editorAccept:(NSString *)text {
    g_editor_open.store(false);
    register_toggle();                                           // ⌘⇧D is the daemon's global hotkey again
    log_editor_event("editor_accept", g_editor_take_id, text);
    g_editor_take_id.clear();
    NSRunningApplication *app = g_target_app; g_target_app = nil; // release the retained target once used
    if (app) [app activateWithOptions:NSApplicationActivateAllWindows];   // refocus the original app…
    NSString *t = text ?: @"";
    // Trim trailing whitespace/newlines so an auto-paste can't end with a stray newline (which in
    // an Enter-to-send input could submit a line the user didn't intend). Interior text is verbatim.
    { NSCharacterSet *ws=[NSCharacterSet whitespaceAndNewlineCharacterSet]; NSUInteger e=t.length;
      while (e>0 && [ws characterIsMember:[t characterAtIndex:e-1]]) e--;
      if (e<t.length) t=[t substringToIndex:e]; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),  // …then paste once it's frontmost
                   dispatch_get_main_queue(), ^{ @autoreleasepool { if (t.length) paste_text(t); } });
}
- (void)editorCancel {
    g_editor_open.store(false);
    register_toggle();
    log_editor_event("editor_cancel", g_editor_take_id);
    g_editor_take_id.clear();
    daemon_cancel("editor_orphan");   // cancel any orphaned mini-take: if the editor died mid corr-start/recording, its
                       // mic+session would otherwise stay live forever (no-op if no take is in flight)
    NSRunningApplication *app = g_target_app; g_target_app = nil; // release the retained target once used
    if (app) [app activateWithOptions:NSApplicationActivateAllWindows];
}
- (void)cancel { unregister_esc(); [self stopTimer]; daemon_cancel("user"); [self hideUI]; }
- (void)toggle {
    if (g_editor_open.load()) return;                            // editor owns ⌘⇧D while open (hotkey unregistered)
    bool rec; { std::lock_guard<std::mutex> lk(g_mu); rec = (bool)g_sess; }
    if (rec) [self requestStop]; else (void)[self beginTakeError];
}

// ── banner (frosted card, HS-style hairline border; centred, status-only — shows the take's
//    state, never live transcript; sized to its short header; lazily created, all on main) ──
- (void)ensureBanner {
    if (_banner) return;
    NSRect r = NSMakeRect(0,0,800,BANNER_NOMINAL_H);                          // placeholder; layout sets the real frame
    _banner = [[NSPanel alloc] initWithContentRect:r
                styleMask:(NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel)
                backing:NSBackingStoreBuffered defer:NO];
    _banner.level = NSStatusWindowLevel;
    _banner.opaque = NO; _banner.backgroundColor = [NSColor clearColor];
    _banner.hasShadow = YES; _banner.ignoresMouseEvents = YES; _banner.hidesOnDeactivate = NO;
    _banner.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                               | NSWindowCollectionBehaviorStationary
                               | NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *bg = [[NSView alloc] initWithFrame:r];                            // flat translucent fill — HS-style glass
    bg.wantsLayer = YES;
    bg.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:BANNER_BG_ALPHA].CGColor;   // see-through, no blur
    bg.layer.cornerRadius = BANNER_RADIUS; bg.layer.masksToBounds = YES;
    bg.layer.borderWidth = BANNER_BORDER_W;                                   // HS-style hairline edge
    bg.layer.borderColor = [NSColor colorWithWhite:1 alpha:BANNER_BORDER_A].CGColor;
    _banner.contentView = bg;
    _text = [[NSTextField alloc] initWithFrame:NSInsetRect(r, BANNER_HINSET, BANNER_VINSET)];
    _text.editable=NO; _text.bezeled=NO; _text.drawsBackground=NO; _text.selectable=NO;
    _text.alignment=NSTextAlignmentCenter; _text.maximumNumberOfLines=0;
    _text.lineBreakMode=NSLineBreakByWordWrapping;
    [bg addSubview:_text];
}
// header → bright title (first line) + dim subtitle (rest). The banner is status-only:
// it never shows live transcript text (the take's words go to the post-take editor, not here).
- (NSAttributedString *)compose:(NSString *)header {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter; ps.lineSpacing = 3;                 // a touch of air between lines
    NSString *title = header, *subtitle = nil;
    NSRange nl = [header rangeOfString:@"\n"];
    if (nl.location != NSNotFound) { title = [header substringToIndex:nl.location];
                                     subtitle = [header substringFromIndex:NSMaxRange(nl)]; }
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc] init];
    [m appendAttributedString:[[NSAttributedString alloc] initWithString:title
        attributes:@{NSForegroundColorAttributeName:[NSColor whiteColor],
                     NSFontAttributeName:[NSFont systemFontOfSize:BANNER_TITLE_PT weight:NSFontWeightSemibold],
                     NSParagraphStyleAttributeName:ps}]];
    if (subtitle.length) [m appendAttributedString:[[NSAttributedString alloc] initWithString:
        [@"\n" stringByAppendingString:subtitle]
        attributes:@{NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:0.6],
                     NSFontAttributeName:[NSFont systemFontOfSize:BANNER_SUB_PT],
                     NSParagraphStyleAttributeName:ps}]];
    return m;
}
- (CGFloat)bannerWidth {                                     // full screen width minus the side margins
    NSScreen *scr = active_screen();
    return (scr ? scr.frame.size.width : 1200) - 2*BANNER_HMARGIN;
}
- (CGFloat)textHeight:(NSAttributedString *)att {            // wrapped height at the current content width
    return ceil([att boundingRectWithSize:NSMakeSize([self bannerWidth] - 2*BANNER_HINSET, 100000)
                 options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading].size.height);
}
// Size the card to the text (clamped to [MINH, screen·MAXH_FRAC]) and pin its TOP edge so the
// header sits at a stable place across states; the text block is vertically centred.
- (void)layoutForTextHeight:(CGFloat)textH {
    NSScreen *scr = active_screen(); if (!scr) return;
    NSRect s = scr.frame;
    CGFloat w = s.size.width - 2*BANNER_HMARGIN;                                  // span the full screen width
    CGFloat maxH = floor(s.size.height * BANNER_MAXH_FRAC);
    CGFloat h = textH + 2*BANNER_VINSET;
    if (h < BANNER_MINH) h = BANNER_MINH;
    if (h > maxH)        h = maxH;
    CGFloat topY = NSMidY(s) + BANNER_NOMINAL_H/2.0 + s.size.height*BANNER_VBIAS;   // fixed top; box hangs below
    [_banner setFrame:NSMakeRect(s.origin.x + BANNER_HMARGIN, topY-h, w, h) display:YES];
    CGFloat th = MIN(textH, h - 2*BANNER_VINSET);                                 // never overflow the clamped card
    _text.frame = NSMakeRect(BANNER_HINSET, (h-th)/2.0, w-2*BANNER_HINSET, th);
}
// One entry for every banner state: compose the (short, status-only) header, size, and show.
// All callers route through here.
- (void)renderHeader:(NSString *)header {
    [self ensureBanner];
    _gen++;                                          // any display change invalidates a pending auto-hide
    NSAttributedString *att = [self compose:header];
    CGFloat textH = [self textHeight:att];
    _text.attributedStringValue = att;
    [self layoutForTextHeight:textH];
    [_banner orderFrontRegardless];
}
- (NSString *)currentInputSourceName {
    AVCaptureDevice *dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    NSString *name = dev.localizedName ?: dev.uniqueID;
    if (!name.length) return @"";
    return name;
}
- (NSString *)captureHeader:(NSString *)status controls:(NSString *)controls {
    std::string text = capture_banner_text(status.UTF8String ?: "",
                                           [self currentInputSourceName].UTF8String ?: "",
                                           controls.UTF8String ?: "");
    return [NSString stringWithUTF8String:text.c_str()] ?: status;
}
- (void)showWarmup {
    _warmTicks = 0;
    [self renderHeader:[self captureHeader:@"⏳  Запуск микрофона…" controls:@""]];
    [_warm invalidate];
    _warm = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(warmTick:) userInfo:nil repeats:YES];
}
- (void)warmTick:(NSTimer *)t {
    bool live=false; { std::lock_guard<std::mutex> lk(g_mu); live = g_sess && g_sess->live.load(); }
    if (live) { [t invalidate]; if (_warm==t) _warm=nil; [self showLive]; return; }
    if (++_warmTicks > 100) {                          // ~10 s with no audio → show an error instead of a stuck «Запуск…»
        [t invalidate]; if (_warm==t) _warm=nil;
        unregister_esc(); [self stopTimer]; daemon_cancel("no_audio_timeout");
        [self showError:@"микрофон не запустился"];
    }
}
- (void)showLive {
    [self renderHeader:[self captureHeader:@"🎙  ЗАПИСЬ — говори" controls:@"⌘⇧D — стоп · Esc — отмена"]];
}
- (void)showTranscribing { [_warm invalidate]; _warm=nil;
    [self renderHeader:@"⏳  расшифровка…"]; }
- (void)hideUI { [_warm invalidate]; _warm=nil; _gen++; [_banner orderOut:nil];
    // TEAR the banner down — don't just hide a cached panel. The daemon lives for days, but a single
    // long-lived NSPanel loses its CanJoinAllSpaces association over time (accumulating bug): after
    // hours/days it stops following the active Space and reappears only on the main one. The editor
    // never hits this because it's a FRESH PROCESS per take. Mirror that here: rebuild a fresh banner
    // each take (ensureBanner runs on the next show). Cheap — one panel per user-initiated take — and
    // it resets the Space association every time. (gotcha #20 is about the *config*; this is the
    // *longevity* of the window object.)
    _banner = nil; _text = nil; }
- (void)showError:(NSString *)e { [_warm invalidate]; _warm=nil;
    [self renderHeader:[@"✖ " stringByAppendingString:e]];
    NSUInteger g = _gen;   // only auto-hide if the banner hasn't moved on (e.g. a retake started)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (_gen==g) [self hideUI]; }); }
- (void)showHint:(NSString *)h {
    [self renderHeader:h];
    NSUInteger g = _gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ if (_gen==g) [self hideUI]; }); }

// ── menubar indicator + take timer (60 s auto-stop) ──
- (void)setupStatusItem {
    _status = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _status.button.title = @"⏳";
    _status.button.target = self; _status.button.action = @selector(statusClicked:);
    _status.button.toolTip = @"Диктовка — ⌘⇧D или клик: старт/стоп · Esc: отмена";
}
- (void)statusClicked:(id)sender { (void)sender; [self toggle]; }
- (void)startTimer {
    _secs = 0; [_tick invalidate];
    _tick = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(timerTick:) userInfo:nil repeats:YES];
    _status.button.title = @"🎙 0:00";
}
- (void)stopTimer { [_tick invalidate]; _tick=nil; _status.button.title=@"⏳"; }
- (void)timerTick:(NSTimer *)t { (void)t;
    if (++_secs >= 60) { [self stopTimer]; [self requestStop]; return; }   // VD_MAXSEC: hard cap a take at 60 s
    _status.button.title = [NSString stringWithFormat:@"🎙 %d:%02d", _secs/60, _secs%60];
}

// ── idle-unload: free the resident model after DICTATE_IDLE_UNLOAD_SEC of inactivity ──
// (gotcha #7 — trades the resident-speed win for ~573 MB back when unused; the next take
//  reloads in ~600 ms-1 s). Disabled by default (env unset / <= 0). The poll AND the free
//  run on MAIN; the free takes g_mu and fires only when no take/finish/editor is active, so
//  it can never race the lone whisper worker (gotcha #5). Pure gate: src/dictate_idle.h.
- (void)setupIdleTimer {
    g_idle_unload_sec = 0;
    if (const char *e = getenv("DICTATE_IDLE_UNLOAD_SEC")) g_idle_unload_sec = atoi(e);
    if (g_idle_unload_sec <= 0) return;                       // default: model stays resident (gotcha #7)
    g_last_active_ms = now_ms();
    double iv = idle_poll_interval_sec(g_idle_unload_sec);
    _idle = [NSTimer scheduledTimerWithTimeInterval:iv target:self selector:@selector(idleTick:) userInfo:nil repeats:YES];
    fprintf(stderr, "idle-unload: armed — model will free after %d s idle (poll %.0fs)\n", g_idle_unload_sec, iv);
}
- (void)idleTick:(NSTimer *)t { (void)t;
    std::lock_guard<std::mutex> lk(g_mu);   // serialize the free against take-start + the worker (gotcha #5)
    bool sess = (bool)g_sess, fin = g_finishing.load(), ed = g_editor_open.load(), loaded = (bool)g_ctx;
    if (idle_is_active(sess, fin, ed, loaded)) { g_last_active_ms = now_ms(); return; }   // active → reset clock
    if (idle_should_unload(now_ms(), g_last_active_ms, g_idle_unload_sec, sess, fin, ed, loaded)) {
        fprintf(stderr, "idle-unload: freeing model after %.0f s idle\n", (now_ms()-g_last_active_ms)/1000.0);
        g_ctx.reset();                       // whisper_free → ~573 MB Metal released (gotcha #7)
    }
}
@end

static void write_all(int fd, const char *p, size_t n){
    while(n){ ssize_t w=write(fd,p,n); if(w<0){ if(errno==EINTR) continue; break; } if(w==0) break; p+=w; n-=(size_t)w; }
}

static std::vector<std::string> split_tabs(const std::string &s) {
    std::vector<std::string> out;
    size_t start = 0;
    for (;;) {
        size_t tab = s.find('\t', start);
        if (tab == std::string::npos) { out.push_back(s.substr(start)); return out; }
        out.push_back(s.substr(start, tab - start));
        start = tab + 1;
    }
}

// Same-user check on a connected AF_UNIX peer. The `accept <text>` verb synthesizes a paste
// into the frontmost app (borrowing the daemon's Accessibility grant), so an unauthenticated
// peer is a keystroke-injection sink. The socket is also created 0600 — this is defense in depth.
static bool peer_is_owner(int fd) {
    uid_t euid; gid_t egid;
    if (getpeereid(fd, &euid, &egid) != 0) return false;
    return peer_uid_ok(euid, geteuid());   // same-user decision (src/dictate_authgen.h, unit-tested)
}
// RAII clear of g_finishing: a flag left set permanently refuses every new take (gotcha #5),
// so clear it on EVERY exit path of a finalize, not just the happy one.
struct FinishingGuard { ~FinishingGuard(){ g_finishing.store(false); } };

// Serve one client connection on the SOCKET thread. Commands that touch the engine,
// UI, or recording state hop to the main queue; only the blocking finish() (stop) runs
// here, off-main, so the Cocoa run loop is never frozen.
static void serve_client(int cl) {
    @autoreleasepool {
        if (!peer_is_owner(cl)) { close(cl); return; }   // same-user only (auth — see peer_is_owner)
        // The accept loop is single-threaded and serves each client inline, so a client that
        // connects and dribbles a partial line would stall ALL socket traffic. A recv timeout
        // bounds that: a stalled read fails with EAGAIN and we drop the connection.
        struct timeval rcvto{5, 0};
        setsockopt(cl, SOL_SOCKET, SO_RCVTIMEO, &rcvto, sizeof(rcvto));
        // Read one newline-terminated command. A single read can be short or fragmented, so
        // loop until the newline arrives; cap the line so a client can't OOM the daemon.
        std::string data; char buf[4096]; bool got=false;
        for (;;) {
            ssize_t r=read(cl,buf,sizeof(buf));
            if (r>0) { got=true; data.append(buf,(size_t)r);
                       if (data.find('\n')!=std::string::npos) break;
                       if (data.size() > ((size_t)1<<20)) { close(cl); return; }   // runaway line (>1 MB) → drop
                       continue; }
            if (r<0 && errno==EINTR) continue;
            break;   // EOF or error
        }
        if (!got){ close(cl); return; }
        Command parsed = parse_command(first_line(data));   // pure verb/arg split (src/dictate_proto.h)
        const std::string &cmd = parsed.cmd, &arg = parsed.arg;

        if (cmd=="ping") write_all(cl,"pong\n",5);
        else if (cmd=="axcheck") { const char *m = ax_trusted(false)?"trusted\n":"untrusted\n"; write_all(cl,m,strlen(m)); }
        else if (cmd=="start") {
            __block std::string e;
            dispatch_sync(dispatch_get_main_queue(), ^{ e = [g_ctrl beginTakeError]; });
            std::string m = e.empty()? "ok\n" : ("err "+e+"\n"); write_all(cl,m.data(),m.size());
        }
        else if (cmd=="stop") {
            __block DetachedTake take;
            dispatch_sync(dispatch_get_main_queue(), ^{ take = [g_ctrl stopDetachForSocket]; });
            std::string text;
            if (take) {
                std::string rawText;
                if (capture_stop_action(take.session->live.load(), take.session->samples())
                    == CaptureStopAction::reportNoAudio) {
                    log_take_cancel(take.meta, take.session->seconds(), "no_audio");
                    try { take.session->cancel(); } catch (...) {}
                } else {
                    try { rawText = take.session->finish(); }   // off-main: joins the worker without freezing the run loop. A throw
                    catch (...) {}                //   here would std::terminate the socket thread AND skip the finalize
                                                  //   below (g_finishing would wedge) — swallow and finalize regardless.
                    text = rawText;
                    try { text = finalize_transcript(rawText); } catch (...) {}   // post-normalize before clipboard
                    double seconds=take.session->seconds(); int segments=take.session->segments();
                    log_transcript(take.meta, rawText, text, seconds, segments);
                    fprintf(stderr,"stop: %.2fs, %d seg → %zu chars\n", seconds, segments, text.size());
                }
                __block NSString *ns = text.empty()? nil : [NSString stringWithUTF8String:text.c_str()];
                dispatch_sync(dispatch_get_main_queue(), ^{ @autoreleasepool { [g_ctrl finalizeSocketStop:ns]; } });
            }
            write_all(cl,text.data(),text.size());
        }
        else if (cmd=="cancel") { dispatch_sync(dispatch_get_main_queue(), ^{ [g_ctrl cancel]; }); write_all(cl,"ok\n",3); }
        else if (cmd=="accept") {        // from the editor process: paste the (possibly edited) text into the target app
            NSString *t = [NSString stringWithUTF8String:arg.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{ [g_ctrl editorAccept:t]; });
            write_all(cl,"ok\n",3);
        }
        else if (cmd=="editor-cancel") { dispatch_async(dispatch_get_main_queue(), ^{ [g_ctrl editorCancel]; }); write_all(cl,"ok\n",3); }
        else if (cmd=="corr-start") {     // editor mini-take: start the mic (no banner — the editor shows the state)
            __block std::string e;
            dispatch_sync(dispatch_get_main_queue(), ^{ e = daemon_start("correction"); });
            std::string m = e.empty()? "ok\n" : ("err "+e+"\n"); write_all(cl,m.data(),m.size());
        }
        else if (cmd=="corr-stop") {      // stop the mini-take, transcribe, return the text to the editor
            __block DetachedTake take;
            dispatch_sync(dispatch_get_main_queue(), ^{ take = daemon_stop_detach(); });
            std::string text, takeId;
            if (take) {
                FinishingGuard fg;
                takeId = take.meta.id;
                if (capture_stop_action(take.session->live.load(), take.session->samples())
                    == CaptureStopAction::reportNoAudio) {
                    log_take_cancel(take.meta, take.session->seconds(), "no_audio");
                    try { take.session->cancel(); } catch(...) {}
                } else {
                    try { text = take.session->finish(); } catch(...) {}
                    log_transcript(take.meta, text, text, take.session->seconds(), take.session->segments());
                }
            }
            std::string reply = takeId + "\t" + text + "\n";
            write_all(cl,reply.data(),reply.size());
        }
        else if (cmd=="corr-cancel") { dispatch_sync(dispatch_get_main_queue(), ^{ daemon_cancel("user"); }); write_all(cl,"ok\n",3); }
        else if (cmd=="correction-apply") {
            std::vector<std::string> f = split_tabs(arg);
            std::string rawText, appliedText, targetText;
            bool ok = f.size() == 5 &&
                      (f[1] == "replace" || f[1] == "insert") &&
                      dlog::hex_decode(f[2], &rawText) &&
                      dlog::hex_decode(f[3], &appliedText) &&
                      dlog::hex_decode(f[4], &targetText);
            if (ok) {
                __block std::string mainTakeId;
                dispatch_sync(dispatch_get_main_queue(), ^{ mainTakeId = g_editor_take_id; });
                log_correction_apply(mainTakeId, f[0], rawText, appliedText, f[1], targetText);
                write_all(cl,"ok\n",3);
            } else {
                write_all(cl,"err malformed\n",14);
            }
        }
        else if (cmd=="edit") {           // debug: open the editor on the given text (no mic) — mirrors the post-take spawn
            __block NSString *ns = [NSString stringWithUTF8String:arg.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{ [g_ctrl openEditorWithText:ns conf:@""]; });   // debug path: no confidence
            write_all(cl,"ok\n",3);
        }
        else if (cmd=="feedfile"){
            std::vector<float> audio; uint32_t rate=0; __block std::string e;
            if (!load_wav_pcm16(arg.c_str(), audio, &rate)) e="wav read failed";   // read off-main, off-lock
            else dispatch_sync(dispatch_get_main_queue(), ^{ e = daemon_feed_audio(audio); });
            std::string m=e.empty()?"ok\n":("err "+e+"\n"); write_all(cl,m.data(),m.size());
        }
        else if (cmd=="quit") {
            write_all(cl,"bye\n",4); close(cl);
            dispatch_async(dispatch_get_main_queue(), ^{
                DetachedTake take = daemon_stop_detach();   // release the mic if recording
                if (take) {
                    log_take_cancel(take.meta, take.session->seconds(), "quit");
                    take.session->cancel();
                }
                // NB: don't whisper_free(g_ctx) here — an async finish (hotkey/timer stop) may still be
                // decoding on it; _exit reclaims all memory + GPU state cleanly (and skips dtors, so the
                // g_finishing flag set by daemon_stop_detach above needs no explicit clear).
                unlink(SOCK_PATH); _exit(0);
            });
            return;
        }
        else write_all(cl,"err unknown\n",12);
        close(cl);
    }
}

static void socket_accept_loop(int srv) {
    for (;;) {
        int cl=accept(srv,nullptr,nullptr);
        if (cl<0) {
            if (errno==EINTR) continue;
            if (errno==EMFILE || errno==ENFILE) {       // fd exhaustion: back off, don't 100%-CPU spin
                struct timespec ts{0, 100*1000*1000}; nanosleep(&ts, nullptr); continue;
            }
            if (errno==EBADF || errno==EINVAL) break;   // listen socket gone → stop the loop
            continue;
        }
        serve_client(cl);
    }
}

static int run_daemon(const std::string &modelPath) {
    signal(SIGPIPE, SIG_IGN);   // a client that disconnects mid-reply must not kill the daemon
    umask(0077);                // daemon-created files (socket, state file, editor log) → owner-only, not world-readable
    g_take_logger.prune();
    // single instance: if a daemon already answers, bow out.
    { int c=socket(AF_UNIX,SOCK_STREAM,0); sockaddr_un a{}; a.sun_family=AF_UNIX;
      strncpy(a.sun_path,SOCK_PATH,sizeof(a.sun_path)-1);
      if (c>=0 && connect(c,(sockaddr*)&a,sizeof(a))==0){ write_all(c,"ping\n",5); close(c);
          fprintf(stderr,"daemon already running\n"); return 0; }
      if (c>=0) close(c); }
    // Only remove the path if it is actually a socket — defense-in-depth so a redirected
    // $DICTATE_SOCK can't make the daemon unlink an arbitrary user file (lstat, so a symlink is
    // seen AS a symlink and never followed). A stale socket from a dead daemon is the normal case.
    { struct stat st; if (lstat(SOCK_PATH,&st)==0 && !S_ISSOCK(st.st_mode)) {
          fprintf(stderr,"refusing to unlink non-socket %s\n", SOCK_PATH); return 1; } }
    unlink(SOCK_PATH);

    int srv=socket(AF_UNIX,SOCK_STREAM,0);
    if (srv<0){ perror("socket"); return 1; }
    fcntl(srv, F_SETFD, FD_CLOEXEC);   // don't leak the listening socket into any future child
    sockaddr_un addr{}; addr.sun_family=AF_UNIX; strncpy(addr.sun_path,SOCK_PATH,sizeof(addr.sun_path)-1);
    if (bind(srv,(sockaddr*)&addr,sizeof(addr))<0){ perror("bind"); return 1; }
    chmod(SOCK_PATH, 0600);   // owner-only: macOS enforces connect() permission on the socket node (auth backstop)
    if (listen(srv,8)<0){ perror("listen"); return 1; }

    g_model_path = modelPath;   // remembered so idle-unload can reload (gotcha #7)
    fprintf(stderr,"⏳ loading model: %s\n", modelPath.c_str());
    double t0=now_ms();
    load_backends_and_model(modelPath);
    if (!g_ctx){ fprintf(stderr,"✖ model load failed\n"); return 1; }
    fprintf(stderr,"✓ model resident (%.0f ms). listening on %s\n", now_ms()-t0, SOCK_PATH);

    // Become a Cocoa accessory agent: the main thread runs the AppKit run loop (needed
    // for the global hotkey + banner + status item, added in later tasks); the socket
    // accept loop moves to a background thread. The run loop returns only via the `quit`
    // command's _exit(0).
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        g_ctrl = [[DictateController alloc] init];
        NSApp.delegate = g_ctrl;
        install_hotkeys();
        ax_trusted(true);   // prompt once → System Settings ▸ Privacy ▸ Accessibility (for auto-paste)
        [g_ctrl setupStatusItem];
        [g_ctrl setupIdleTimer];   // arm idle-unload if DICTATE_IDLE_UNLOAD_SEC is set (gotcha #7)
        std::thread([srv]{ socket_accept_loop(srv); }).detach();
        [NSApp run];
    }
    return 0;
}

// ════════════════════════════ CLIENT ════════════════════════════════════════
static int connect_daemon(void) {
    int c=socket(AF_UNIX,SOCK_STREAM,0); if (c<0) return -1;
    sockaddr_un a{}; a.sun_family=AF_UNIX; strncpy(a.sun_path,SOCK_PATH,sizeof(a.sun_path)-1);
    if (connect(c,(sockaddr*)&a,sizeof(a))<0){ close(c); return -1; }
    return c;
}

static std::string self_path(void) {
    char buf[4096]; uint32_t sz=sizeof(buf);
    if (_NSGetExecutablePath(buf,&sz)!=0) return "dictate";
    return std::string(buf);
}

// spawn `dictate daemon`, detached, logging to /tmp/dictate.log, and wait for it.
static int ensure_daemon(void) {
    int c=connect_daemon(); if (c>=0){ close(c); return 0; }
    pid_t pid=fork();
    if (pid<0) return -1;
    if (pid==0) {
        setsid();
        int log=open("/tmp/dictate.log",O_CREAT|O_WRONLY|O_APPEND|O_NOFOLLOW,0600);
        if (log>=0){ dup2(log,1); dup2(log,2); close(log); }
        int devnull=open("/dev/null",O_RDONLY); if(devnull>=0){ dup2(devnull,0); close(devnull); }
        std::string self=self_path();
        execl(self.c_str(),"dictate","daemon",(char*)nullptr);
        _exit(127);
    }
    for (int i=0;i<DAEMON_POLL_TRIES;i++){                    // wait out the model-load window
        int d=connect_daemon();
        if (d>=0){ write_all(d,"ping\n",5); char b[8]; read(d,b,sizeof(b)); close(d); return 0; }
        struct timespec ts{0,DAEMON_POLL_NS}; nanosleep(&ts,nullptr);
    }
    return -1;
}

// send one command; print the raw reply to stdout (for `stop`). returns 0/1.
static int client_cmd(const std::string &cmd, bool printReply) {
    int c=connect_daemon();
    if (c<0) { if (cmd=="stop") return 0; return 1; }         // no daemon: nothing to stop
    std::string line=cmd+"\n"; write_all(c,line.data(),line.size());
    std::string reply; char b[4096];
    for (;;){ ssize_t r=read(c,b,sizeof(b)); if(r>0){ reply.append(b,(size_t)r); continue; } if(r<0&&errno==EINTR) continue; break; }
    close(c);
    if (printReply){ fputs(reply.c_str(),stdout); if(!reply.empty()&&reply.back()!='\n') fputc('\n',stdout); }
    if (reply.rfind("err ",0)==0) return 1;
    return 0;
}

// ════════════════════════════ EDITOR (`dictate editor` — Phase 3) ════════════
// Foreground voice-editor shown after a take. Regular activation + a borderless KEY
// window (Phase 0 proved this composites + takes keyDown reliably, unlike the
// background banner). Cursor moves over words/gaps; space runs a mini-take that
// replaces a word / inserts at a gap; ⌘⇧D / ⏎ accept, Esc cancels. For now the
// When daemon-spawned (--from-daemon), mini-takes use the daemon's mic via the
// corr-start/corr-stop/corr-cancel socket verbs, and accept → the daemon refocuses the
// target app + pastes. A standalone `dictate editor "text"` run (no --from-daemon) uses a
// local stub for the mini-take and accept just prints/clipboards (for quick iteration).
static const CGFloat ED_BODY_PT = 30, ED_HDR_TOP = 78, ED_FTR_H = 64, ED_BODY_PAD = 40;

// Uncertain-word highlighting (whisper logprob): a (non-cursor, non-punctuation) word whose
// MIN per-token confidence is below ED_CONF_THRESHOLD is drawn in amber, so the eye lands on
// the likely transcription errors first. Threshold + colour live here per the task spec.
static const float ED_CONF_THRESHOLD = 0.60f;
static NSColor *ed_conf_color(void) { return [NSColor colorWithRed:1.0 green:0.78 blue:0.27 alpha:1.0]; }  // amber

static void edlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap]; va_end(ap);
    NSString *l = [NSString stringWithFormat:@"[ed %8.0f] %@\n", now_ms(), m];
    fputs(l.UTF8String ?: "", stderr); fflush(stderr);   // daemon redirects the editor's stderr → /tmp/dictate-editor.log
}

// NSPanel (not NSWindow): with NSWindowStyleMaskNonactivatingPanel it can become KEY and receive
// keyDown WITHOUT activating the app. That matters because a Regular app's activation switches the
// user to the process's "home" Space — the "editor opens on the main Space" bug. A non-activating
// accessory panel skips activation entirely (the Spotlight/Raycast palette trick, and what the
// banner already does). canBecomeKeyWindow override is still needed (borderless masks return NO).
@interface KeyWindow : NSPanel @end
@implementation KeyWindow
- (BOOL)canBecomeKeyWindow  { return YES; }   // borderless masks return NO by default — override
- (BOOL)canBecomeMainWindow { return YES; }
@end

@interface EdCell : NSObject
@property(nonatomic, strong) NSString *text;
@property(nonatomic) BOOL  isCaret;
@property(nonatomic) int   wordIndex;
@property(nonatomic) NSRect rect;
@property(nonatomic) int   line;
@end
@implementation EdCell @end

static void        editor_send(const std::string &line);     // editor → daemon (defined below)
static std::string editor_request(const std::string &line);  // editor → daemon request/reply (defined below)

@interface EditorView : NSView
@property(nonatomic, strong) NSArray<NSString *> *words;
@property(nonatomic) int pos;
@property(nonatomic) BOOL fromDaemon;        // mini-takes go to the daemon's mic (vs. the standalone stub)
@property(nonatomic, copy) void (^onAccept)(NSString *);
@property(nonatomic, copy) void (^onCancel)(void);
- (instancetype)initWithFrame:(NSRect)f transcript:(NSString *)t conf:(NSString *)conf;
@end
@implementation EditorView {
    NSMutableArray<EdCell *> *_cells; int _lineCount; CGFloat _lineH;
    BOOL _layoutDirty;          // geometry (_cells/_lineCount/_lineH) stale → relayout recomputes; else reuse cache
    NSSize _laidOutSize;        // bounds size the cached _cells were laid out for (recompute on resize)
    BOOL _recording; int _stubIdx;
    BOOL _starting;     // awaiting corr-start ack (daemon warming the mic) — window static, not yet recording
    BOOL _decoding;     // awaiting the daemon's transcript after a mini-take stop
    std::vector<float> _conf;   // per-word confidence parallel to _words; empty → no highlighting (gotcha #21 sibling)
    CGFloat _scrollY;           // vertical scroll offset of the word body (a long transcript scrolls — see updateScroll)
    BOOL _followCaret;          // a cursor/content change happened → next draw scrolls minimally to reveal the cursor line
    EditHistory _history;       // undo/redo history: pre-edit snapshots — ⌘Z/⌃Z undo, ⌘⇧Z/⌃⇧Z redo (src/dictate_editmodel.h)
}
- (instancetype)initWithFrame:(NSRect)f transcript:(NSString *)t conf:(NSString *)conf {
    if ((self = [super initWithFrame:f])) {
        EditModel m = EditModel::fromText(t.UTF8String ?: "");   // pure tokenize + initial cursor (src/dictate_editmodel.h)
        NSMutableArray<NSString *> *w = [NSMutableArray array];
        for (const std::string &s : m.words) [w addObject:[NSString stringWithUTF8String:s.c_str()] ?: @""];
        _words = w; _pos = m.pos; _layoutDirty = YES; self.wantsLayer = YES;
        // Parse per-word confidence; returns empty (→ no highlights) unless the count matches the
        // word count, so any daemon/editor tokenization drift disables colouring rather than mis-painting.
        _conf = conf::parse(conf.UTF8String ?: "", m.words.size());
    }
    return self;
}
- (BOOL)isFlipped             { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { edlog(@"becomeFirstResponder → YES"); return YES; }
// Cursor arithmetic delegates to the pure, unit-tested helpers in src/dictate_editmodel.h.
- (int)maxPos    { return em_max_pos((int)_words.count); }
- (BOOL)onWord   { return em_on_word(_pos); }
- (int)wordIndex { return em_word_index(_pos); }
- (int)gapIndex  { return em_gap_index(_pos); }
- (NSString *)joinedText {   // punctuation-aware join (src/dictate_editmodel.h) — NOT a bare " "
    std::vector<std::string> v; v.reserve(_words.count);
    for (NSString *s in _words) v.push_back(s.UTF8String ?: "");
    return [NSString stringWithUTF8String:em_join(v).c_str()] ?: @"";
}
- (NSString *)cursorDesc {   // classification is em_cursor_kind; the Russian copy stays here
    CursorKind k = em_cursor_kind((int)_words.count, _pos);
    if (k == CursorKind::empty)    return @"пусто";
    if (k == CursorKind::onWord) {   // a single punctuation mark reads «на знаке», a word «на слове»
        NSString *cur = _words[[self wordIndex]];
        BOOL punct = em_is_punct_token(cur.UTF8String ?: "");
        return [NSString stringWithFormat:@"%@ «%@» (%d/%lu)", punct ? @"на знаке" : @"на слове",
                cur, [self wordIndex] + 1, (unsigned long)_words.count];
    }
    if (k == CursorKind::gapStart) return @"вставка в начало";
    if (k == CursorKind::gapEnd)   return @"вставка в конец";
    int g = [self gapIndex];   // gapBetween
    return [NSString stringWithFormat:@"вставка между «%@» и «%@»", _words[g - 1], _words[g]];
}
- (NSFont *)bodyFont  { return [NSFont systemFontOfSize:ED_BODY_PT]; }
- (NSFont *)wordFont  { return [NSFont systemFontOfSize:ED_BODY_PT weight:NSFontWeightSemibold]; }
- (NSFont *)caretFont { return [NSFont systemFontOfSize:ED_BODY_PT weight:NSFontWeightBold]; }
- (void)relayout {
    // Geometry depends only on (bounds size, _words, _pos). Mutators flag _layoutDirty; a resize is
    // caught by the size compare. So skip the full re-measure on repaints that only change colour
    // (cursor highlight, recording/decoding state, confidence) — those leave the layout identical.
    NSSize sz = self.bounds.size;
    if (!_layoutDirty && _cells && NSEqualSizes(sz, _laidOutSize)) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat bodyW = W - 2 * ED_BODY_PAD;
    NSFont *bf = [self bodyFont];
    CGFloat textH = ceil(bf.ascender - bf.descender + bf.leading);
    _lineH = textH + 14;
    CGFloat spaceW = ceil([@" " sizeWithAttributes:@{NSFontAttributeName:bf}].width);
    NSMutableArray<EdCell *> *cells = [NSMutableArray array];
    int N = (int)_words.count;
    EdCell *(^caret)(void) = ^EdCell *{ EdCell *c = [EdCell new]; c.isCaret = YES; c.wordIndex = -1; c.text = @"] ["; return c; };
    if (N == 0) { [cells addObject:caret()]; }
    else {
        for (int k = 0; k < N; k++) {
            if (_pos == 2 * k) [cells addObject:caret()];
            EdCell *c = [EdCell new]; c.isCaret = NO; c.wordIndex = k; c.text = _words[k]; [cells addObject:c];
        }
        if (_pos == 2 * N) [cells addObject:caret()];
    }
    for (EdCell *c in cells) {
        NSFont *f = c.isCaret ? [self caretFont] : bf;
        c.rect = NSMakeRect(0, 0, ceil([c.text sizeWithAttributes:@{NSFontAttributeName:f}].width), textH);
    }
    CGFloat x = 0; int line = 0;
    for (EdCell *c in cells) {
        CGFloat w = c.rect.size.width;
        if (x > 0 && x + spaceW + w > bodyW) { x = 0; line++; } else if (x > 0) { x += spaceW; }
        c.line = line; c.rect = NSMakeRect(x, 0, w, textH); x += w;
    }
    _lineCount = line + 1;
    CGFloat availTop = ED_HDR_TOP, availBot = H - ED_FTR_H;
    CGFloat top = availTop + MAX(0, ((availBot - availTop) - _lineCount * _lineH) / 2);
    for (EdCell *c in cells)
        c.rect = NSMakeRect(ED_BODY_PAD + c.rect.origin.x, top + c.line * _lineH, c.rect.size.width, textH);
    _cells = cells;
    _laidOutSize = sz; _layoutDirty = NO;
    _followCaret = YES;   // a (re)measure means content/cursor/size changed → keep the cursor line on-screen this draw
}
- (EdCell *)cellForWord:(int)wi { for (EdCell *c in _cells) if (!c.isCaret && c.wordIndex == wi) return c; return nil; }
- (EdCell *)caretCell           { for (EdCell *c in _cells) if (c.isCaret) return c; return nil; }
// Vertical scroll: keep the body within [ED_HDR_TOP, H-ED_FTR_H] (never over the footer legend), and
// when the cursor moved (_followCaret) scroll minimally to reveal its line. Pure math in dictate_edscroll.h.
- (void)updateScroll {
    EdCell *cc = [self onWord] ? [self cellForWord:[self wordIndex]] : [self caretCell];
    EdScrollState s{ (double)(_lineCount * _lineH), (double)ED_HDR_TOP, (double)(self.bounds.size.height - ED_FTR_H),
                     (double)(cc ? cc.rect.origin.y : 0), (double)_lineH, (double)_scrollY, (bool)(_followCaret && cc != nil) };
    _scrollY = (CGFloat)ed_scroll_clamp(s);
    _followCaret = NO;
}
- (BOOL)anchorLine:(int *)ln x:(CGFloat *)cx {
    if ([self onWord]) {
        EdCell *c = [self cellForWord:[self wordIndex]];
        if (!c) return NO; if (ln) *ln = c.line; if (cx) *cx = NSMidX(c.rect); return YES;
    }
    EdCell *c = [self caretCell];          // in a gap: anchor on the caret's LEFT edge (the insertion point),
    if (!c) return NO; if (ln) *ln = c.line; if (cx) *cx = NSMinX(c.rect); return YES;   // not the wide «] [» midpoint
}
- (void)keyDown:(NSEvent *)e {
    NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    edlog(@"keyDown keyCode=%u cmd=%d shift=%d", (unsigned)e.keyCode,
          (int)((m & NSEventModifierFlagCommand) != 0), (int)((m & NSEventModifierFlagShift) != 0));
    if (_decoding || _starting) return;               // window static while the daemon warms the mic / transcribes
    if (_recording) {
        switch (e.keyCode) {
            case 49: [self stopTakeApply]; return;   // space — stop & apply
            case 53: [self cancelTake];    return;   // Esc — cancel just this take
            default: return;                          // window static during a take
        }
    }
    if ((m & NSEventModifierFlagCommand) && (m & NSEventModifierFlagShift) && e.keyCode == 2) { [self accept]; return; }
    if ([self isUndoEvent:e]) { [self undo]; return; }                  // ⌘Z / ⌃Z — отменить правку
    if ([self isRedoEvent:e]) { [self redo]; return; }                  // ⌘⇧Z / ⌃⇧Z — вернуть
    switch (e.keyCode) {
        case 49:  [self startTake];                 return;               // space — start a mini dictation
        case 123: _pos = em_clamp_step(_pos, -1, [self maxPos]); [self moved]; return;  // ←
        case 124: _pos = em_clamp_step(_pos, +1, [self maxPos]); [self moved]; return;  // →
        case 126: [self lineMove:-1];               return;               // ↑
        case 125: [self lineMove:+1];               return;               // ↓
        case 51:  [self deleteCurrent:NO];          return;               // ⌫ Delete/Backspace — remove the token
        case 117: [self deleteCurrent:YES];         return;               // ⌦ forward delete (fn+Delete)
        case 36:  case 76: [self accept];           return;               // ⏎ — accept
        case 53:  [self cancel];                    return;               // Esc — cancel
        default: break;
    }
}
- (BOOL)performKeyEquivalent:(NSEvent *)e {
    if (_recording || _decoding || _starting) return [super performKeyEquivalent:e];
    NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((m & NSEventModifierFlagCommand) && (m & NSEventModifierFlagShift) && e.keyCode == 2) {
        edlog(@"performKeyEquivalent ⌘⇧D → accept"); [self accept]; return YES;
    }
    if ([self isUndoEvent:e]) { edlog(@"performKeyEquivalent ⌘Z → undo"); [self undo]; return YES; }
    if ([self isRedoEvent:e]) { edlog(@"performKeyEquivalent ⌘⇧Z → redo"); [self redo]; return YES; }
    return [super performKeyEquivalent:e];
}
// ⌘Z / ⌃Z (no Shift) = undo; ⌘⇧Z / ⌃⇧Z = redo. keyCode 6 = physical Z, so both fire on a
// Cyrillic layout too (like the ⌘⇧D / keycode-2 hotkey — see the Native UI notes).
- (BOOL)isUndoEvent:(NSEvent *)e { return [self isZChord:e withShift:NO]; }
- (BOOL)isRedoEvent:(NSEvent *)e { return [self isZChord:e withShift:YES]; }
- (BOOL)isZChord:(NSEvent *)e withShift:(BOOL)wantShift {
    NSEventModifierFlags m = e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL cmdOrCtrl = (m & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    BOOL shift     = (m & NSEventModifierFlagShift) != 0;   // strictly 0/1, like wantShift → direct compare is safe
    return cmdOrCtrl && (shift == wantShift) && e.keyCode == 6;
}
// The current editor document as a snapshot (view → pure) — the inverse of loadWords:conf:pos:.
// undo/redo park this on the opposite history stack so the pair round-trips losslessly.
- (EditSnapshot)currentSnapshot {
    EditSnapshot s; s.pos = _pos; s.conf = _conf;
    for (NSString *w in _words) s.words.push_back(w.UTF8String ?: "");
    return s;
}
// Step back / forward through the edit history (src/dictate_editmodel.h). No-op (just a log) at
// the end of a stack. Cursor + confidence ride along with the words, so each step is exact.
- (void)undo {
    EditSnapshot cur = [self currentSnapshot], s;
    if (!_history.undo(cur, s)) { edlog(@"undo → ничего отменять"); return; }
    [self loadWords:s.words conf:s.conf pos:s.pos];   // restore the pre-edit document into the view
    edlog(@"undo → %lu word(s) pos=%d (undo:%lu redo:%lu)", (unsigned long)_words.count, _pos,
          (unsigned long)_history.undoStack.size(), (unsigned long)_history.redoStack.size());
    [self setNeedsDisplay:YES];
}
- (void)redo {
    EditSnapshot cur = [self currentSnapshot], s;
    if (!_history.redo(cur, s)) { edlog(@"redo → нечего возвращать"); return; }
    [self loadWords:s.words conf:s.conf pos:s.pos];   // re-apply the next document state
    edlog(@"redo → %lu word(s) pos=%d (undo:%lu redo:%lu)", (unsigned long)_words.count, _pos,
          (unsigned long)_history.undoStack.size(), (unsigned long)_history.redoStack.size());
    [self setNeedsDisplay:YES];
}
// Bridge a pure model/snapshot back into the view's ivars: rebuild _words (NSArray) and reset the
// cursor + confidence, marking the layout dirty so the next draw re-measures. Single source for the
// model→view write shared by applyResult:/deleteCurrent:/undo.
- (void)loadWords:(const std::vector<std::string> &)words conf:(const std::vector<float> &)conf pos:(int)pos {
    NSMutableArray<NSString *> *w = [NSMutableArray arrayWithCapacity:words.size()];
    for (const std::string &s : words) [w addObject:[NSString stringWithUTF8String:s.c_str()] ?: @""];
    _words = w; _pos = pos; _conf = conf; _layoutDirty = YES;
}
- (void)cancelOperation:(id)sender { (void)sender; edlog(@"cancelOperation (Esc) → cancel"); [self cancel]; }
- (void)lineMove:(int)dir {
    [self relayout];
    int curLine; CGFloat curX;
    if (![self anchorLine:&curLine x:&curX]) return;
    int target = curLine + dir;
    if (target < 0 || target >= _lineCount) { edlog(@"lineMove %d: edge", dir); return; }
    std::vector<EmCell> cells;   // hand the laid-out word cells to the pure nearest-word search
    for (EdCell *c in _cells) if (!c.isCaret) cells.push_back({c.line, (double)NSMidX(c.rect), c.wordIndex});
    int wi = em_nearest_word_on_line(cells, target, (double)curX);
    if (wi < 0) return;
    _pos = 2 * wi + 1; [self moved];
}
- (void)moved  { _layoutDirty = YES; edlog(@"cursor → pos=%d", _pos); [self setNeedsDisplay:YES]; }   // pos moves the caret cell → relayout; don't log word content (sensitive)
- (void)accept { NSString *t = [self joinedText]; edlog(@"ACCEPT → %lu chars", (unsigned long)t.length); if (_onAccept) _onAccept(t); }
- (void)cancel { edlog(@"CANCEL"); if (_onCancel) _onCancel(); }
- (void)startTake {
    if (self.fromDaemon) {
        // corr-start makes the daemon spin up AVAudioEngine (up to ~1 s). Do it OFF the
        // main thread so the editor window doesn't freeze; flip to recording on the ack.
        _starting = YES; [self setNeedsDisplay:YES];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::string r = editor_request("corr-start");      // daemon turns the mic on
            BOOL ok = r.rfind("ok", 0) == 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_starting = NO;
                if (ok) { self->_recording = YES;
                          edlog(@"TAKE start @pos=%d (%@)", self->_pos, [self onWord] ? @"replace word" : @"insert in gap"); }
                else      edlog(@"corr-start failed — no take");
                [self setNeedsDisplay:YES];
            });
        });
        return;
    }
    _recording = YES;
    edlog(@"TAKE start @pos=%d (%@)", _pos, [self onWord] ? @"replace word" : @"insert in gap"); [self setNeedsDisplay:YES];
}
- (void)cancelTake { edlog(@"TAKE cancel (no change)"); if (self.fromDaemon) editor_send("corr-cancel"); _recording = NO; [self setNeedsDisplay:YES]; }
- (NSString *)nextStubResult {
    NSArray<NSString *> *stubs = @[@"замена", @"новое слово", @"исправлено", @"ещё немного текста", @"раз два три"];
    NSString *s = stubs[_stubIdx % stubs.count]; _stubIdx++; return s;
}
- (void)stopTakeApply {
    _recording = NO;
    if (self.fromDaemon) {                                      // real mini-take: stop the mic, await the transcript off-main
        _decoding = YES; [self setNeedsDisplay:YES];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            std::string r = editor_request("corr-stop");
            size_t tab = r.find('\t');
            std::string correctionId = tab == std::string::npos ? "" : r.substr(0, tab);
            std::string correctionText = tab == std::string::npos ? r : r.substr(tab + 1);
            NSString *res = [NSString stringWithUTF8String:correctionText.c_str()] ?: @"";
            NSString *cid = [NSString stringWithUTF8String:correctionId.c_str()] ?: @"";
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_decoding = NO;
                [self applyResult:res correctionId:cid];
            });
        });
    } else {
        [self applyResult:[self nextStubResult] correctionId:@""];
    }
}
- (void)applyResult:(NSString *)res correctionId:(NSString *)correctionId {
    std::string r = res.UTF8String ?: "";
    if (em_tokenize(r).empty()) { edlog(@"apply → empty result, no change"); [self setNeedsDisplay:YES]; return; }
    EditModel m; m.pos = _pos;                                  // bridge NSArray<NSString*> ↔ the pure model
    for (NSString *s in _words) m.words.push_back(s.UTF8String ?: "");
    m.conf = _conf;                                             // thread confidence so it stays aligned through the edit
    EditSnapshot before = m.snapshot();
    BOOL wasOnWord = m.onWord(); int wi = m.wordIndex(), gi = m.gapIndex();
    m.applyMiniTake(r);   // voice edit: drop whisper's auto Capital+dot, re-case to context, map spoken punctuation (src/dictate_editmodel.h)
    bool changed = m.snapshot() != before;
    if (changed) _history.recordEdit(before);    // record undo only if the splice actually changed the doc (skip a same-text re-dictation); also forks redo
    if (changed && self.fromDaemon && correctionId.length) {
        size_t begin = wasOnWord ? (size_t)wi : (size_t)gi;
        size_t count = wasOnWord ? m.words.size() - before.words.size() + 1
                                 : m.words.size() - before.words.size();
        std::vector<std::string> appliedWords;
        if (begin <= m.words.size() && count <= m.words.size() - begin)
            appliedWords.assign(m.words.begin() + (std::ptrdiff_t)begin,
                                m.words.begin() + (std::ptrdiff_t)(begin + count));
        std::string applied = em_join(appliedWords);
        std::string target = wasOnWord && wi >= 0 && (size_t)wi < before.words.size()
                           ? before.words[(size_t)wi] : "";
        std::string command = "correction-apply " + std::string(correctionId.UTF8String ?: "") + "\t" +
                              (wasOnWord ? "replace" : "insert") + "\t" +
                              dlog::hex_encode(r) + "\t" + dlog::hex_encode(applied) + "\t" +
                              dlog::hex_encode(target);
        editor_send(command);
    }
    [self loadWords:m.words conf:m.conf pos:m.pos];             // model → view (re-measures)
    if (wasOnWord) edlog(@"apply → replace word %d (%lu chars)", wi, (unsigned long)res.length);
    else           edlog(@"apply → insert %lu chars at gap %d", (unsigned long)res.length, gi);
    [self setNeedsDisplay:YES];
}
- (void)deleteCurrent:(BOOL)forward {   // remove the current/adjacent token (src/dictate_editmodel.h)
    EditModel m; m.pos = _pos;                                  // bridge NSArray<NSString*> ↔ the pure model
    for (NSString *s in _words) m.words.push_back(s.UTF8String ?: "");
    m.conf = _conf;                                             // keep confidence aligned across the delete
    EditSnapshot before = m.snapshot();
    if (forward) m.deleteForward(); else m.deleteToken();       // nop on empty / edge gaps
    if (m.snapshot() != before) _history.recordEdit(before);    // record undo only when a token was actually removed; also forks redo
    [self loadWords:m.words conf:m.conf pos:m.pos];             // model → view (re-measures)
    edlog(@"delete (%@) → %lu word(s) pos=%d", forward ? @"fwd" : @"back", (unsigned long)_words.count, _pos);
    [self setNeedsDisplay:YES];
}
- (void)scrollWheel:(NSEvent *)e {
    // Free scroll (followCaret=NO): adjust by the wheel delta and clamp; cursor-follow resumes on the
    // next navigation. _layoutDirty is left untouched, so relayout early-returns and won't re-arm follow.
    EdScrollState s{ (double)(_lineCount * _lineH), (double)ED_HDR_TOP, (double)(self.bounds.size.height - ED_FTR_H),
                     0, (double)_lineH, (double)(_scrollY - e.scrollingDeltaY), false };
    CGFloat ns = (CGFloat)ed_scroll_clamp(s);
    if (ns != _scrollY) { _scrollY = ns; [self setNeedsDisplay:YES]; }
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty; [self relayout]; [self updateScroll]; NSRect b = self.bounds;
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(b, 1, 1) xRadius:18 yRadius:18];
    [[NSColor colorWithWhite:0.06 alpha:0.96] setFill]; [bg fill];
    [[NSColor colorWithWhite:1 alpha:0.28] setStroke]; bg.lineWidth = 1; [bg stroke];
    NSMutableParagraphStyle *ctr = [NSMutableParagraphStyle new]; ctr.alignment = NSTextAlignmentCenter;
    [@"✎ редактор" drawInRect:NSMakeRect(0, 22, b.size.width, 28)
        withAttributes:@{NSForegroundColorAttributeName:[NSColor whiteColor],
                         NSFontAttributeName:[NSFont boldSystemFontOfSize:18], NSParagraphStyleAttributeName:ctr}];
    NSColor *caretColor = _recording ? [NSColor systemRedColor] : [NSColor colorWithRed:0.42 green:0.78 blue:1.0 alpha:1.0];
    // The word body is clipped to [ED_HDR_TOP, height-ED_FTR_H] and shifted by _scrollY, so a long
    // transcript scrolls (updateScroll) instead of overrunning the footer legend or the window edge.
    CGFloat bodyTop = ED_HDR_TOP, bodyBot = b.size.height - ED_FTR_H, vpH = bodyBot - bodyTop;
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(NSMakeRect(0, bodyTop, b.size.width, vpH));
    { NSAffineTransform *tr = [NSAffineTransform transform]; [tr translateXBy:0 yBy:-_scrollY]; [tr concat]; }
    for (EdCell *c in _cells) {
        if (c.isCaret) {
            [c.text drawAtPoint:c.rect.origin withAttributes:@{NSForegroundColorAttributeName:caretColor, NSFontAttributeName:[self caretFont]}];
        } else {
            BOOL hot = ([self onWord] && c.wordIndex == [self wordIndex]);
            if (hot) {
                NSBezierPath *hl = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(c.rect, -6, -3) xRadius:6 yRadius:6];
                [(_recording ? [NSColor systemRedColor] : [NSColor systemYellowColor]) setFill]; [hl fill];
            }
            // Low-confidence (non-cursor, non-punctuation) words → amber, leading the eye to likely errors.
            BOOL uncertain = (!hot && c.wordIndex >= 0 && c.wordIndex < (int)_conf.size()
                              && _conf[c.wordIndex] < ED_CONF_THRESHOLD
                              && !em_is_punct_token(c.text.UTF8String ?: ""));
            NSColor *fg = hot ? (_recording ? [NSColor whiteColor] : [NSColor blackColor])
                        : uncertain ? ed_conf_color()
                        : [NSColor colorWithWhite:0.93 alpha:1];
            [c.text drawAtPoint:c.rect.origin withAttributes:@{NSForegroundColorAttributeName:fg, NSFontAttributeName:(hot ? [self wordFont] : [self bodyFont])}];
        }
    }
    [NSGraphicsContext restoreGraphicsState];
    // Scroll indicator (faint knob, right margin) whenever the transcript exceeds one screenful.
    CGFloat contentH = _lineCount * _lineH, maxScroll = MAX(0, contentH - vpH);
    if (maxScroll > 0) {
        CGFloat knobH = MAX(28, vpH * vpH / contentH);
        CGFloat knobY = bodyTop + (vpH - knobH) * (_scrollY / maxScroll);
        NSBezierPath *knob = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(b.size.width - 9, knobY, 3, knobH) xRadius:1.5 yRadius:1.5];
        [[NSColor colorWithWhite:1 alpha:0.22] setFill]; [knob fill];
    }
    NSString *status = _recording ? @"🎙 запись… — пробел: стоп · Esc: отмена правки"
                     : _starting  ? @"⏳ запуск микрофона…"
                     : (_decoding ? @"⏳ расшифровка…" : [self cursorDesc]);
    NSColor  *sfg = _recording ? [NSColor systemRedColor]
                  : (_starting || _decoding) ? [NSColor systemOrangeColor]
                  : [NSColor colorWithWhite:1 alpha:0.7];
    [status drawInRect:NSMakeRect(0, b.size.height - 56, b.size.width, 22)
        withAttributes:@{NSForegroundColorAttributeName:sfg, NSFontAttributeName:[NSFont systemFontOfSize:15], NSParagraphStyleAttributeName:ctr}];
    [@"←/→ ↑/↓ навигация · пробел — диктовка · ⌫/⌦ удалить · ⌘Z отменить · ⌘⇧Z вернуть · ⏎ принять · Esc отмена"
        drawInRect:NSMakeRect(0, b.size.height - 30, b.size.width, 20)
        withAttributes:@{NSForegroundColorAttributeName:[NSColor colorWithWhite:1 alpha:0.45], NSFontAttributeName:[NSFont systemFontOfSize:13], NSParagraphStyleAttributeName:ctr}];
}
@end

// editor → daemon (one-shot): send a line to the daemon socket, wait for its ack, close.
static void editor_send(const std::string &line) {
    int c = connect_daemon(); if (c < 0) return;
    std::string l = line + "\n"; write_all(c, l.data(), l.size());
    char b[64]; (void)read(c, b, sizeof(b)); close(c);
}
// editor → daemon (request/reply): send a line, read the full reply (e.g. corr-stop → transcript).
static std::string editor_request(const std::string &line) {
    int c = connect_daemon(); if (c < 0) return "";
    std::string l = line + "\n"; write_all(c, l.data(), l.size());
    std::string reply; char b[4096];
    for (;;){ ssize_t r=read(c,b,sizeof(b)); if(r>0){ reply.append(b,(size_t)r); continue; } if(r<0&&errno==EINTR) continue; break; }
    close(c);
    while (!reply.empty() && (reply.back()=='\n'||reply.back()=='\r')) reply.pop_back();
    return reply;
}
// daemon → editor: spawn `dictate editor --from-daemon <transcript>`. posix_spawn (not fork+exec):
// the daemon is multithreaded with Metal loaded, so a bare fork trips the ObjC fork-safety abort.
static void spawn_editor(NSString *transcript, NSString *conf) {
    std::string self = self_path();
    std::string t = transcript.UTF8String ?: "";
    std::string c = conf.UTF8String ?: "";   // serialized per-word confidence (comma-separated ints), may be empty
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null",                O_RDONLY,                  0);
    posix_spawn_file_actions_addopen(&fa, 1, "/tmp/dictate-editor.log",  O_CREAT|O_WRONLY|O_APPEND|O_NOFOLLOW, 0600);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    // `--conf <ints>` BEFORE the transcript so the editor consumes its value as a flag (the
    // transcript words are the trailing positional args). conf is digits/commas → argv-safe.
    char *argv[] = { (char*)"dictate", (char*)"editor", (char*)"--from-daemon",
                     (char*)"--conf", (char*)c.c_str(), (char*)t.c_str(), nullptr };
    pid_t pid;
    int rc = posix_spawn(&pid, self.c_str(), &fa, nullptr, argv, *_NSGetEnviron());
    posix_spawn_file_actions_destroy(&fa);
    fprintf(stderr, "spawn_editor rc=%d pid=%d\n", rc, (int)pid);
    if (rc == 0) {
        // Reap the child AND recover if it dies WITHOUT sending accept/editor-cancel (crash, ⌘Q):
        // otherwise g_editor_open stays true and ⌘⇧D stays unregistered → daemon wedged.
        std::thread([pid]{
            int st; while (waitpid(pid, &st, 0) < 0 && errno == EINTR) {}
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_editor_open.load()) { fprintf(stderr, "editor exited without accept/cancel → recover\n"); [g_ctrl editorCancel]; }
            });
        }).detach();
    }
}

// NSApp.delegate is a weak reference, so the window/key setup MUST happen in
// applicationDidFinishLaunching: (after the run loop is ready) — doing it inline
// before [NSApp run] leaves the window non-key and keyDown never arrives.
@interface EditorApp : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSString *transcript;
@property(nonatomic, strong) NSString *conf;        // serialized per-word confidence (argv --conf), may be empty
@property(nonatomic) BOOL fromDaemon;
@end
@implementation EditorApp {
    KeyWindow  *_win;
    EditorView *_v;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n {
    (void)n;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];   // NOT Regular: a Regular app's
    // activation switches the user to the process's home Space. Accessory + the non-activating key
    // panel below get keyboard focus on the CURRENT Space without ever activating. See KeyWindow.
    NSMenu *bar = [NSMenu new]; NSMenuItem *ai = [NSMenuItem new]; [bar addItem:ai];
    NSMenu *am = [NSMenu new];
    [am addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"]; ai.submenu = am; NSApp.mainMenu = bar;
    // Never call activate(IgnoringOtherApps:) anywhere in the editor — that activation is exactly what
    // switched the user to the main Space. The non-activating key panel (below) handles focus instead.
    NSScreen *scr = active_screen(); NSRect sf = scr.frame;
    CGFloat W = 1000, H = MIN(sf.size.height * 0.78, 860);   // taller, screen-aware: many lines fit before the body needs to scroll
    CGFloat x = sf.origin.x + (sf.size.width - W) / 2.0, y = sf.origin.y + (sf.size.height - H) / 2.0;
    _win = [[KeyWindow alloc] initWithContentRect:NSMakeRect(x, y, W, H)
                styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                          backing:NSBackingStoreBuffered defer:NO];
    _win.level = NSStatusWindowLevel; _win.opaque = NO; _win.backgroundColor = [NSColor clearColor]; _win.hasShadow = YES;
    _win.hidesOnDeactivate = NO;   // NSPanel hides on app-deactivate by default; we never activate, so pin it visible
    // Present the panel on the user's current Space (incl. a fullscreen-app Space) — the same trio
    // the banner uses. Combined with the accessory app + non-activating key panel above, this is
    // exactly what the working banner does, so the editor surfaces on the current Space, not main.
    _win.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                            | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _v = [[EditorView alloc] initWithFrame:NSMakeRect(0, 0, W, H) transcript:(_transcript ?: @"") conf:(_conf ?: @"")];
    _v.fromDaemon = _fromDaemon;
    BOOL fromD = _fromDaemon;
    _v.onAccept = ^(NSString *t){
        if (fromD) editor_send(std::string("accept ") + (t.UTF8String ?: ""));   // daemon refocuses target + pastes
        else { copy_to_clipboard(t); fprintf(stdout, "%s\n", t.UTF8String ?: ""); fflush(stdout); }
        exit(0);
    };
    _v.onCancel = ^{ if (fromD) editor_send("editor-cancel"); exit(0); };
    // Show WITHOUT activating the app. A non-activating panel becomes key and receives keyDown while
    // the app stays inactive — so there's no app activation and therefore no Space switch. (Earlier
    // attempts failed because the Regular-app activation itself switched Spaces; reordering it before
    // the window didn't help, so we drop activation entirely — the Spotlight/Raycast palette trick.)
    _win.contentView = _v;
    [_win orderFrontRegardless];                                  // surface on the current Space
    [_win makeKeyAndOrderFront:nil]; [_win makeFirstResponder:_v];   // key + first responder → keyDown, no activate
    edlog(@"editor up: %lu word(s) isKey=%d isActive=%d", (unsigned long)_v.words.count, (int)_win.isKeyWindow, (int)NSApp.isActive);
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { (void)a; return YES; }
@end

static EditorApp *g_editor_delegate = nil;   // NSApp.delegate is weak — keep it alive
static int run_editor(NSString *transcript, bool fromDaemon, NSString *conf) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        g_editor_delegate = [[EditorApp alloc] init];
        g_editor_delegate.transcript = transcript;
        g_editor_delegate.fromDaemon = fromDaemon;
        g_editor_delegate.conf = conf;
        NSApp.delegate = g_editor_delegate;
        [NSApp run];
    }
    return 0;
}

// ════════════════════════════ MAIN ══════════════════════════════════════════
int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);   // never die on a broken pipe (socket peer or stdout consumer gone)
        const char *home=getenv("HOME");
        std::string modelPath = getenv("WHISPER_MODEL") ? getenv("WHISPER_MODEL")
            : std::string(home?home:".")+"/.config/whisper/ggml-large-v3-turbo-q5_0.bin";
        g_lang = getenv("WHISPER_LANG") ? getenv("WHISPER_LANG") : "ru";
        g_nthreads = default_threads();

        // Silero VAD model (kills the silence hallucination). Default to the same
        // file the old script used; disable with WHISPER_VAD=0; skip if absent.
        std::string vadPath = getenv("WHISPER_VAD_MODEL") ? getenv("WHISPER_VAD_MODEL")
            : std::string(home?home:".")+"/.config/whisper/ggml-silero-v5.1.2.bin";
        const char *vadOff = getenv("WHISPER_VAD");
        struct stat vst;
        if (vadOff && !strcmp(vadOff,"0")) vadPath.clear();
        else if (stat(vadPath.c_str(),&vst)!=0) vadPath.clear();
        g_vad_model = vadPath;

        // User dictionary → whisper initial_prompt (lexical bias on names / tech terms / English-in-
        // Russian). Mirrors the VAD on/off + path env pair: default ON if the file exists,
        // WHISPER_PROMPT=0 forces it off, an absent/empty file leaves it off. WHISPER_DICT overrides
        // the path; WHISPER_PROMPT_MAXTOK tunes the ~224-token budget down if turbo loops (gotcha #11).
        const char *promptOff = getenv("WHISPER_PROMPT");
        if (!(promptOff && !strcmp(promptOff,"0"))) {
            std::string dictPath = getenv("WHISPER_DICT") ? getenv("WHISPER_DICT")
                : std::string(home?home:".")+"/.config/whisper/dictionary.txt";
            std::ifstream df(dictPath);
            if (df) {
                std::stringstream ss; ss << df.rdbuf();
                std::size_t maxtok = dict::DEFAULT_MAX_TOKENS;
                if (const char *m = getenv("WHISPER_PROMPT_MAXTOK")) { int n=atoi(m); if (n>0) maxtok=(std::size_t)n; }
                g_initial_prompt = dict::build_initial_prompt(ss.str(), maxtok);
                if (!g_initial_prompt.empty())
                    fprintf(stderr,"✓ lexical-bias prompt: ~%zu tok from %s\n",
                            dict::estimate_tokens(g_initial_prompt), dictPath.c_str());
            }
        }

        std::string verb = argc>1 ? argv[1] : "";

        // ---- daemon ----
        if (verb=="daemon") return run_daemon(modelPath);

        // ---- foreground voice-editor (Phase 3; transcript from argv for now) ----
        if (verb=="editor") {
            bool fromDaemon=false; NSMutableString *t = [NSMutableString string]; NSString *confStr=@"";
            for (int i=2;i<argc;i++){ if(!strcmp(argv[i],"--from-daemon")){ fromDaemon=true; continue; }
                if(!strcmp(argv[i],"--conf")){ if(i+1<argc) confStr=[NSString stringWithUTF8String:argv[++i]]?:@""; continue; }   // consume its value
                if(!strncmp(argv[i],"--",2)) continue;
                if (t.length) [t appendString:@" "]; [t appendString:[NSString stringWithUTF8String:argv[i]]?:@""]; }
            return run_editor(t.length ? t : @"привет это проверка редактора", fromDaemon, confStr);
        }

        // ---- thin client verbs (talk to the daemon) ----
        if (verb=="start")  { if (ensure_daemon()!=0){ fprintf(stderr,"✖ daemon unavailable\n"); return 1; } return client_cmd("start",false); }
        if (verb=="stop")   return client_cmd("stop",true);
        if (verb=="cancel") return client_cmd("cancel",false);
        if (verb=="ping")   return client_cmd("ping",true);
        if (verb=="axcheck") return client_cmd("axcheck",true);
        if (verb=="quit")   return client_cmd("quit",true);   // stop the daemon (launchd may respawn it)

        // ---- one-shot file mode (no daemon) ----
        std::string file, langOverride; bool once=false;
        for (int i=1;i<argc;i++){
            if (!strcmp(argv[i],"--file") && i+1<argc) file=argv[++i];
            else if (!strcmp(argv[i],"--lang") && i+1<argc) g_lang=argv[++i];
            else if (!strcmp(argv[i],"--model") && i+1<argc) modelPath=argv[++i];
            else if (!strcmp(argv[i],"--once")) once=true;
            else { fprintf(stderr,"usage: dictate {daemon|start|stop|cancel|ping|axcheck|quit} | --file a.wav [--once] [--lang xx] [--model P]\n"); return 2; }
        }
        if (file.empty()){ fprintf(stderr,"usage: dictate {daemon|start|stop|cancel|ping|axcheck|quit} | --file a.wav\n"); return 2; }

        const char *bd=getenv("DICTATE_GGML_BACKENDS");
        ggml_backend_load_all_from_path(bd?bd:GGML_LIBEXEC);
        fprintf(stderr,"⏳ loading model: %s\n", modelPath.c_str());
        double t0=now_ms();
        whisper_context_params cp=make_context_params();
        whisper_ctx_ptr ctx(whisper_init_from_file_with_params(modelPath.c_str(),cp));
        if (!ctx){ fprintf(stderr,"✖ model load failed\n"); return 1; }
        fprintf(stderr,"✓ model loaded %.0f ms\n", now_ms()-t0);

        std::vector<float> audio; uint32_t rate=0;
        if (!load_wav_pcm16(file.c_str(),audio,&rate)){ fprintf(stderr,"✖ WAV read failed (need PCM16)\n"); return 1; }
        if (rate!=WHISPER_SAMPLE_RATE) fprintf(stderr,"⚠ %u Hz, expected 16000\n", rate);
        double secs=(double)audio.size()/WHISPER_SAMPLE_RATE;

        std::string text; double tt=now_ms();
        if (once) {
            text = normalize_ws(run_whisper(ctx.get(), audio, g_lang.c_str(), g_nthreads));
        } else {
            StreamingSession s(ctx.get(), g_lang, g_nthreads);
            size_t step=WHISPER_SAMPLE_RATE/10;                  // 100 ms chunks
            for (size_t i=0;i<audio.size();i+=step)
                s.feed(audio.data()+i, std::min(step,audio.size()-i));
            text = s.finish();
            if (s.wasCapped())   // the MAX_TAKE_SEC cap bounds the live mic; in --file A/B it truncates — say so, don't be silent
                fprintf(stderr,"⚠ clip exceeds the %d s take cap — streamed transcript truncated (use --once for full-length)\n", MAX_TAKE_SEC);
            fprintf(stderr,"(streamed in %d segment(s))\n", s.segments());
        }
        double ms=now_ms()-tt;
        fprintf(stderr,"✓ %.2fs audio → %.0f ms (×%.1f realtime)%s\n", secs, ms, ms>0?secs*1000.0/ms:0, once?" [single-pass]":" [streaming]");
        if (!text.empty()){ NSString *ns=[NSString stringWithUTF8String:text.c_str()]; if(ns) copy_to_clipboard(ns); printf("%s\n",text.c_str()); }
        else fprintf(stderr,"🎙 empty\n");
        return 0;   // ctx freed by its unique_ptr
    }
}
