#pragma once

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <CommonCrypto/CommonDigest.h>
#include "whisper.h"
#include "../core/vad.h"

// In whisper.cpp 1.9.4 a failed VAD compute can log an error and still return
// true with a zero-filled probability tail. Treat any error as unavailable.
// The worker runs inference sequentially; restore its default logger afterwards.
class VadLogScope {
public:
    VadLogScope() {
        whisper_log_set([](ggml_log_level level, const char* text, void* opaque) {
            if (level == GGML_LOG_LEVEL_ERROR)
                static_cast<std::atomic<bool>*>(opaque)->store(true, std::memory_order_relaxed);
            if (text) std::fputs(text, stderr);
        }, &failed_);
    }
    ~VadLogScope() { whisper_log_set(nullptr, nullptr); }
    VadLogScope(const VadLogScope&) = delete;
    VadLogScope& operator=(const VadLogScope&) = delete;
    bool failed() const { return failed_.load(std::memory_order_relaxed); }
private:
    std::atomic<bool> failed_{false};
};

inline transcriber::ConservativeVad detect_conservative_vad(const float* samples, int count, const char* model) {
    if (!model || count <= 0) return {};
    const auto started = std::chrono::steady_clock::now();
    try {
        // GGML may abort on malformed model headers. Verify the supported
        // artifact before entering it, then load those same immutable bytes.
        std::ifstream stream(model, std::ios::binary);
        std::vector<char> bytes(885098);
        if (!stream.read(bytes.data(), bytes.size()) || stream.peek() != std::char_traits<char>::eof())
            throw std::runtime_error("model unavailable or wrong size");
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes.data(), static_cast<CC_LONG>(bytes.size()), digest);
        std::string checksum;
        for (const auto byte : digest) {
            constexpr char hex[] = "0123456789abcdef";
            checksum += hex[byte >> 4]; checksum += hex[byte & 15];
        }
        if (checksum != "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987")
            throw std::runtime_error("model checksum mismatch");
        struct Buffer { const std::vector<char>& bytes; size_t offset = 0; } buffer{bytes};
        whisper_model_loader loader{};
        loader.context = &buffer;
        loader.read = [](void* opaque, void* output, size_t requested) -> size_t {
            auto& input = *static_cast<Buffer*>(opaque);
            const size_t count = std::min(requested, input.bytes.size() - input.offset);
            std::memcpy(output, input.bytes.data() + input.offset, count);
            input.offset += count;
            return count;
        };
        loader.eof = [](void* opaque) {
            const auto& input = *static_cast<Buffer*>(opaque);
            return input.offset == input.bytes.size();
        };
        loader.close = [](void*) {};
        VadLogScope errors;
        auto params = whisper_vad_default_context_params();
        params.use_gpu = false;
        params.n_threads = 1;
        std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> context(
            whisper_vad_init_with_params(&loader, params), whisper_vad_free);
        if (!context || errors.failed()) throw std::runtime_error("model unavailable");
        if (!whisper_vad_detect_speech(context.get(), samples, count) || errors.failed())
            throw std::runtime_error("inference failed");
        const int n = whisper_vad_n_probs(context.get());
        const float* probabilities = whisper_vad_probs(context.get());
        if (!probabilities || n != (int64_t(count) + 511) / 512)
            throw std::runtime_error("incomplete probability map");
        transcriber::ConservativeVad mask(std::vector<float>(probabilities, probabilities + n), count);
        if (!mask.valid()) throw std::runtime_error("invalid probability map");
        std::fprintf(stderr, "vad: scan=%.3fs frames=%d threshold=0.10 margin=1s\n",
            std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count(), n);
        return mask;
    } catch (const std::exception& error) {
        std::fprintf(stderr, "VAD unavailable (%s); keeping all ASR windows\n", error.what());
        return {};
    }
}
