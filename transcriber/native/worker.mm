#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <fcntl.h>
#include <fstream>
#include <memory>
#include <mach-o/dyld.h>
#include <sstream>
#include <stdexcept>
#include <string_view>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <vector>
#include "whisper.h"
#include "ggml-backend.h"
#include "../core/policy.h"
#include "../core/asr_words.h"
#include "speaker_cache.h"
#include "transcript_rows.h"
#include "prepared_audio.h"
#include "forced_alignment.h"
#include "vad_filter.h"
#include "../../src/dictate_dict.h"
#include "../../src/dictate_text.h"

namespace {
constexpr int sample_rate = 16000;
constexpr int64_t max_samples = int64_t(sample_rate) * 4 * 3600;

class ContextError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

std::string read_meeting_context(const char* path) {
    std::ifstream stream(path, std::ios::binary);
    if (!stream) throw ContextError("Не удалось прочитать контекст встречи");
    char buffer[4097];
    stream.read(buffer, sizeof(buffer));
    const auto count = stream.gcount();
    if (stream.bad() || count >= static_cast<std::streamsize>(sizeof(buffer)))
        throw ContextError("Контекст встречи слишком длинный");
    std::string text(buffer, static_cast<size_t>(count));
    if (text.find('\0') != std::string::npos ||
        ![[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding])
        throw ContextError("Некорректный текст контекста встречи");
    return text;
}

void write_all(int fd, const void* bytes, size_t count) {
    const auto* p = static_cast<const char*>(bytes);
    while (count) {
        const auto n = write(fd, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) throw std::runtime_error("Не удалось записать данные на диск");
        p += n; count -= static_cast<size_t>(n);
    }
}

void progress(const char* stage, double fraction) {
    NSDictionary* event = @{@"stage": @(stage), @"progress": @(fraction)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    write_all(STDOUT_FILENO, data.bytes, data.length);
    write_all(STDOUT_FILENO, "\n", 1);
}

class PCM {
public:
    explicit PCM(NSString* output) {
        std::string pattern = std::string(output.fileSystemRepresentation) + ".pcm-XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end()); name.push_back('\0');
        fd_ = mkstemp(name.data());
        if (fd_ < 0) throw std::runtime_error("Нет места для временного аудио");
        fcntl(fd_, F_SETFD, FD_CLOEXEC);
        // No named leftover even if the supervisor force-kills this process.
        unlink(name.data());
    }
    PCM(const PCM&) = delete;
    PCM& operator=(const PCM&) = delete;
    ~PCM() {
        if (data_) munmap(const_cast<float*>(data_), count_ * sizeof(float));
        if (fd_ >= 0) close(fd_);
    }
    void append_at(NSData* bytes, int64_t timestamp) {
        if (bytes.length % sizeof(float)) throw std::runtime_error("Неверный формат аудио");
        if (timestamp > max_samples) throw std::runtime_error("Эта версия поддерживает записи до 4 часов");
        const auto placement = transcriber::place_audio(count_, timestamp, bytes.length / sizeof(float));
        if (placement.gap > uint64_t(max_samples) - count_ ||
            placement.take > uint64_t(max_samples) - count_ - placement.gap)
            throw std::runtime_error("Эта версия поддерживает записи до 4 часов");
        static const float silence[4096]{};
        uint64_t gap = placement.gap;
        while (gap) {
            const auto n = std::min<uint64_t>(gap, 4096);
            write_all(fd_, silence, n * sizeof(float)); count_ += n; gap -= n;
        }
        if (placement.take) {
            write_all(fd_, static_cast<const float*>(bytes.bytes) + placement.skip, placement.take * sizeof(float));
            count_ += placement.take;
        }
    }
    void map() {
        if (!count_) throw std::runtime_error("В файле нет аудио");
        auto* p = mmap(nullptr, count_ * sizeof(float), PROT_READ, MAP_PRIVATE, fd_, 0);
        if (p == MAP_FAILED) throw std::runtime_error("Недостаточно памяти для аудио");
        data_ = static_cast<const float*>(p);
    }
    const float* data() const { return data_; }
    size_t size() const { return count_; }
private:
    int fd_{-1}; size_t count_{0}; const float* data_{nullptr};
};

void decode(NSString* input, PCM& pcm) {
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:input] options:nil];
    NSArray<AVAssetTrack*>* tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (!tracks.count) throw std::runtime_error("В файле нет поддерживаемой аудиодорожки");
    NSError* error = nil;
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (!reader) throw std::runtime_error("Не удалось открыть запись");
    NSDictionary* settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(sample_rate), AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @32, AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO};
    AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:tracks.firstObject outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) throw std::runtime_error("Неподдерживаемый аудиокодек");
    [reader addOutput:output];
    if (![reader startReading]) {
        fprintf(stderr, "AVAssetReader: %s (%ld)\n", reader.error.domain.UTF8String, (long)reader.error.code);
        NSError* underlying = reader.error.userInfo[NSUnderlyingErrorKey];
        if (underlying) fprintf(stderr, "Underlying: %s (%ld)\n", underlying.domain.UTF8String, (long)underlying.code);
        throw std::runtime_error("Не удалось декодировать запись");
    }
    while (CMSampleBufferRef buffer = [output copyNextSampleBuffer]) {
        @autoreleasepool {
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(buffer);
            const auto length = block ? CMBlockBufferGetDataLength(block) : 0;
            NSMutableData* bytes = [NSMutableData dataWithLength:length];
            const auto status = block ? CMBlockBufferCopyDataBytes(block, 0, length, bytes.mutableBytes) : -1;
            const auto presentation = CMSampleBufferGetPresentationTimeStamp(buffer);
            CFRelease(buffer);
            if (status) throw std::runtime_error("Повреждённые аудиоданные");
            if (!CMTIME_IS_NUMERIC(presentation)) throw std::runtime_error("Неверные таймкоды аудио");
            const auto timestamp = CMTimeConvertScale(presentation, sample_rate, kCMTimeRoundingMethod_RoundHalfAwayFromZero);
            pcm.append_at(bytes, timestamp.value);
        }
    }
    if (reader.status != AVAssetReaderStatusCompleted) throw std::runtime_error("Чтение записи прервано");
    pcm.map();
}

NSMutableArray* transcribe_words(const PCM& pcm, const char* model, const char* dictionary, const char* vad_model,
                                const std::string& meeting_context) {
    if (vad_model) progress("vad", 0);
#ifdef TRANSCRIBER_BUNDLED
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    std::vector<char> executable(size);
    if (_NSGetExecutablePath(executable.data(), &size) != 0)
        throw std::runtime_error("Не удалось найти библиотеки приложения.");
    NSURL* binary = [[NSURL fileURLWithPath:@(executable.data())] URLByResolvingSymlinksInPath];
    NSURL* backends = [[[binary URLByDeletingLastPathComponent] URLByDeletingLastPathComponent]
        URLByAppendingPathComponent:@"Frameworks/ggml"];
    ggml_backend_load_all_from_path(backends.fileSystemRepresentation);
#else
    ggml_backend_load_all_from_path(GGML_LIBEXEC);
#endif
    const auto vad = detect_conservative_vad(pcm.data(), static_cast<int>(pcm.size()), vad_model);
    // The small CPU VAD context is already released. Load Whisper lazily so a
    // confidently empty recording need not allocate the ASR model at all.
    std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(nullptr, whisper_free);
    progress("transcribing", 0);
    std::string prompt = meeting_context;
    if (dictionary) {
        std::ifstream stream(dictionary);
        if (!stream) throw std::runtime_error("Не удалось прочитать словарь");
        std::ostringstream content; content << stream.rdbuf();
        prompt = dict::build_initial_prompt(content.str());
    }
    NSMutableArray* rows = [NSMutableArray array];
    constexpr size_t stride = sample_rate * 25;
    size_t skipped = 0, total = 0, skipped_samples = 0;
    for (size_t core = 0; core < pcm.size(); core += stride) {
        const size_t begin = core > sample_rate ? core - sample_rate : 0;
        const size_t core_end = std::min(core + stride, pcm.size());
        const size_t end = std::min(core_end + sample_rate, pcm.size());
        ++total;
        if (vad.skip_window(begin, end)) {
            ++skipped; skipped_samples += core_end - core;
            progress("transcribing", double(core_end) / pcm.size());
            continue;
        }
        if (!ctx) {
            auto cp = whisper_context_default_params(); cp.use_gpu = true; cp.flash_attn = true;
            ctx.reset(whisper_init_from_file_with_params(model, cp));
            if (!ctx) throw std::runtime_error("Не удалось загрузить модель распознавания");
            if (!meeting_context.empty()) {
                // Never let Whisper silently discard part of the user's hint.
                const int limit = std::min(224, whisper_n_text_ctx(ctx.get()) / 2);
                std::vector<whisper_token> tokens(static_cast<size_t>(limit + 1));
                const int count = whisper_tokenize(ctx.get(), prompt.c_str(), tokens.data(), limit + 1);
                if (count < 0 || count > limit)
                    throw ContextError("Контекст встречи слишком длинный для Whisper. Сократите его и повторите попытку.");
                fprintf(stderr, "meeting context: %d tokens\n", count);
            }
        }
        auto wp = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        wp.language = "ru"; wp.translate = false; wp.n_threads = 4;
        wp.no_context = true; wp.no_timestamps = false;
        wp.print_progress = wp.print_realtime = wp.print_timestamps = wp.print_special = false;
        wp.token_timestamps = true; wp.max_len = 1; wp.split_on_word = true;
        wp.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();
        if (whisper_full(ctx.get(), wp, pcm.data() + begin, static_cast<int>(end - begin)))
            throw std::runtime_error("Ошибка распознавания речи");
        transcriber::AsrWordCollector words(core * 1000 / sample_rate, core_end * 1000 / sample_rate);
        for (int i = 0; i < whisper_full_n_segments(ctx.get()); ++i) {
            const int64_t a = int64_t(begin * 1000 / sample_rate) + whisper_full_get_segment_t0(ctx.get(), i) * 10;
            const int64_t b = std::min(int64_t(pcm.size() * 1000 / sample_rate),
                int64_t(begin * 1000 / sample_rate) + whisper_full_get_segment_t1(ctx.get(), i) * 10);
            words.add(a, b, normalize_ws(whisper_full_get_segment_text(ctx.get(), i)));
        }
        for (const auto& result : words.finish()) {
            NSString* word = [NSString stringWithUTF8String:result.text.c_str()];
            if (!word) throw std::runtime_error("Неверная кодировка результата");
            [rows addObject:@{@"startMS": @(result.start_ms), @"endMS": @(result.end_ms), @"text": word,
                             @"timingUncertain": @(result.timing_uncertain)}];
        }
        progress("transcribing", double(core_end) / pcm.size());
    }
    fprintf(stderr, "vad: skipped=%zu total=%zu skipped_audio=%.3fs\n",
            skipped, total, double(skipped_samples) / sample_rate);
    return rows;
}

void write_transcript(NSString* output, int64_t duration, NSArray* rows, NSDictionary* speakers,
                      const char* model, NSDictionary* provenance = nil) {
    NSMutableDictionary* document = [@{@"schemaVersion": @1, @"durationMS": @(duration),
        @"segments": rows, @"speakers": speakers, @"model": [@(model) lastPathComponent]} mutableCopy];
    if (provenance) document[@"diarization"] = provenance;
    NSData* data = [NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingPrettyPrinted error:nil];
    if (!data || ![data writeToFile:output options:NSDataWritingAtomic error:nil])
        throw std::runtime_error("Не удалось сохранить расшифровку");
}
}  // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        umask(0077);
        try {
            if (argc == 4 && std::string_view(argv[1]) == "--align") {
                try { align_prepared(@(argv[2]),argv[3]); }
                catch (const std::exception& error) { fprintf(stderr,"alignment fallback: %s\n",error.what()); }
                progress("aligning",1); return 0;
            }
            if (argc == 3 && std::string_view(argv[1]) == "--finalize") {
                NSString* directory = @(argv[2]);
                NSDictionary* prepared = read_prepared(directory);
                const int64_t duration = [prepared[@"durationMS"] longLongValue];
                NSArray* words = read_prepared_words(directory, duration);
                std::vector<transcriber::Turn> turns;
                NSDictionary* provenance = read_prepared_turns(directory, duration, turns);
                NSMutableDictionary* speakers = [NSMutableDictionary dictionary];
                for (const auto& t : turns) {
                    NSString* key = [NSString stringWithFormat:@"%d", t.speaker];
                    if (!speakers[key]) speakers[key] = [NSString stringWithFormat:@"Говорящий %lu", speakers.count + 1];
                }
                write_transcript(prepared_path(directory, @"transcript.json"), duration,
                    transcript_rows(words, turns), speakers, [prepared[@"asrModel"] UTF8String], provenance);
                progress("done", 1); return 0;
            }
            const bool prepare = argc >= 2 && std::string_view(argv[1]) == "--prepare";
            if (!prepare || argc < 5) {
                fprintf(stderr, "usage: transcriber-worker --prepare INPUT ASR ATTEMPT | --finalize ATTEMPT\n"); return 2;
            }
            const char* dictionary = nullptr;
            const char* context_file = nullptr;
            const char* vad_model = nullptr;
                        for (int i = 5; i < argc; ++i) {
                if (std::string_view(argv[i]) == "--vad-model" && i + 1 < argc && !vad_model)
                    vad_model = argv[++i];
                else if (std::string_view(argv[i]) == "--context-file" && i + 1 < argc && !context_file)
                    context_file = argv[++i];
                else if (std::string_view(argv[i]) == "--dictionary" && i + 1 < argc && !dictionary)
                    dictionary = argv[++i];
                else if (argv[i][0] != '-' && !dictionary) dictionary = argv[i];
                else throw std::invalid_argument("Неверные аргументы worker");
            }
            if (dictionary && context_file) throw std::invalid_argument("Укажите либо словарь, либо контекст встречи");
            const auto meeting_context = context_file ? read_meeting_context(context_file) : std::string{};
            const char* asr = argv[3];
            NSString* input = @(argv[2]);
            NSString* directory = @(argv[4]);
            NSString* output = prepared_path(directory, @"transcript.json");
            progress("decoding", 0); PCM pcm(output); decode(input, pcm);
            float peak = 0;
            for (size_t i = 0; i < pcm.size(); ++i) {
                if (!std::isfinite(pcm.data()[i])) throw std::runtime_error("Неверные аудиосэмплы");
                peak = std::max(peak, std::abs(pcm.data()[i]));
            }
            {
                auto words = peak > 0.000001f ? transcribe_words(pcm, asr, dictionary, vad_model, meeting_context) : [NSMutableArray array];
                const int64_t duration = pcm.size() * 1000 / sample_rate;
                prepared_write(prepared_path(directory, @"audio.f32"), [NSData dataWithBytesNoCopy:const_cast<float*>(pcm.data()) length:pcm.size() * sizeof(float) freeWhenDone:NO]);
                prepared_write_json(prepared_path(directory, @"words.json"), words);
                prepared_write_json(prepared_path(directory, @"prepared.json"), @{
                    @"schemaVersion":@1, @"sampleRate":@16000, @"sampleCount":@(pcm.size()),
                    @"durationMS":@(duration), @"pcmFormat":@"f32le-mono", @"decodeVersion":@1,
                    @"sourceSHA256":prepared_hash(input), @"pcmFile":@"audio.f32", @"wordsFile":@"words.json", @"asrModel":[@(asr) lastPathComponent]});
                write_transcript([output stringByAppendingString:@".preview.json"], duration, transcript_rows(words, {}), @{}, asr);
                progress("preview", 1); return 0;
            }
        } catch (const ContextError& e) {
            fprintf(stderr, "%s\n", e.what()); return 3;
        } catch (const std::exception& e) {
            fprintf(stderr, "%s\n", e.what()); return 1;
        }
    }
}
