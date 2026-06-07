#include "doctest.h"
#include "dictate_wav.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <future>
#include <memory>
#include <chrono>
#include <thread>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

namespace {
// little-endian append helpers
void put16(std::string &b, uint16_t v){ b.push_back((char)(v&0xff)); b.push_back((char)((v>>8)&0xff)); }
void put32(std::string &b, uint32_t v){ for(int i=0;i<4;i++) b.push_back((char)((v>>(8*i))&0xff)); }

// Build a WAV. If dataOverrideSize>=0 it is written into the data-chunk size field INSTEAD of
// the real pcm byte count (to forge oversized/truncated chunks). pcm = interleaved int16 samples.
std::string make_wav(uint16_t channels, uint32_t srate, uint16_t bits,
                     const std::vector<int16_t>& pcm, long dataOverrideSize=-1,
                     bool includeFmt=true) {
    std::string b; b += "RIFF"; put32(b, 0); b += "WAVE";
    if (includeFmt) {
        b += "fmt "; put32(b, 16);
        put16(b, 1);                 // PCM
        put16(b, channels);
        put32(b, srate);
        put32(b, srate*channels*(bits/8)); // byterate
        put16(b, (uint16_t)(channels*(bits/8))); // blockalign
        put16(b, bits);
    }
    b += "data";
    uint32_t real = (uint32_t)(pcm.size()*2);
    put32(b, dataOverrideSize>=0 ? (uint32_t)dataOverrideSize : real);
    for (int16_t s : pcm){ b.push_back((char)(s&0xff)); b.push_back((char)((s>>8)&0xff)); }
    return b;
}

// write bytes to a unique temp file; returns path (caller unlinks)
std::string write_tmp(const std::string& bytes){
    char tmpl[] = "/tmp/dictate_wav_XXXXXX";
    int fd = mkstemp(tmpl);
    REQUIRE(fd >= 0);
    ssize_t w = write(fd, bytes.data(), bytes.size());
    REQUIRE(w == (ssize_t)bytes.size());
    close(fd);
    return std::string(tmpl);
}
} // namespace

TEST_CASE("valid mono PCM16 loads, rate parsed, samples scaled") {
    std::vector<int16_t> pcm = {0, 16384, -16384, 32767};
    std::string p = write_tmp(make_wav(1, 16000, 16, pcm));
    std::vector<float> out; uint32_t rate=0;
    CHECK(load_wav_pcm16(p.c_str(), out, &rate));
    CHECK(rate == 16000u);
    CHECK(out.size() == 4u);
    CHECK(out[0] == doctest::Approx(0.0f));
    CHECK(out[1] == doctest::Approx(16384.0f/32768.0f));
    CHECK(out[3] == doctest::Approx(32767.0f/32768.0f));
    unlink(p.c_str());
}

TEST_CASE("stereo is downmixed to mono by averaging channels") {
    // L,R pairs: (32767,-32768) avg≈0 ; (16384,16384) avg=16384
    std::vector<int16_t> pcm = {32767, -32768, 16384, 16384};
    std::string p = write_tmp(make_wav(2, 16000, 16, pcm));
    std::vector<float> out; uint32_t rate=0;
    CHECK(load_wav_pcm16(p.c_str(), out, &rate));
    CHECK(out.size() == 2u);
    CHECK(out[0] == doctest::Approx(((float)32767 + (float)-32768)/(2.0f*32768.0f)));
    CHECK(out[1] == doctest::Approx(16384.0f/32768.0f));
    unlink(p.c_str());
}

TEST_CASE("8-bit PCM is rejected") {
    std::vector<int16_t> pcm = {1,2,3};
    std::string p = write_tmp(make_wav(1, 16000, 8, pcm));
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16(p.c_str(), out, &rate));
    unlink(p.c_str());
}

TEST_CASE("24-bit PCM is rejected") {
    std::vector<int16_t> pcm = {1,2,3};
    std::string p = write_tmp(make_wav(1, 16000, 24, pcm));
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16(p.c_str(), out, &rate));
    unlink(p.c_str());
}

TEST_CASE("data chunk before fmt is rejected (got_fmt false)") {
    std::vector<int16_t> pcm = {1,2,3};
    std::string p = write_tmp(make_wav(1, 16000, 16, pcm, -1, /*includeFmt=*/false));
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16(p.c_str(), out, &rate));
    unlink(p.c_str());
}

TEST_CASE("absurd data chunk size (>256MB) is rejected without allocating") {
    std::vector<int16_t> pcm = {1,2,3};
    // forge data size field to 300MB; the reader must refuse before allocating
    std::string p = write_tmp(make_wav(1, 16000, 16, pcm, /*dataOverrideSize=*/300u*1024*1024));
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16(p.c_str(), out, &rate));
    unlink(p.c_str());
}

TEST_CASE("truncated data chunk (size claims more than present) is rejected") {
    std::vector<int16_t> pcm = {1,2,3};
    std::string p = write_tmp(make_wav(1, 16000, 16, pcm, /*dataOverrideSize=*/2000));
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16(p.c_str(), out, &rate));
    unlink(p.c_str());
}

TEST_CASE("missing file path is rejected (open fails, no hang)") {
    std::vector<float> out; uint32_t rate=0;
    CHECK_FALSE(load_wav_pcm16("/tmp/dictate_does_not_exist_zzz.wav", out, &rate));
}

TEST_CASE("FIFO is rejected via S_ISREG and does NOT hang (O_NONBLOCK)") {
    char tmpl[] = "/tmp/dictate_fifo_XXXXXX";
    // mkstemp creates a regular file; remove it and mkfifo in its place
    int fd = mkstemp(tmpl); REQUIRE(fd>=0); close(fd); unlink(tmpl);
    REQUIRE(mkfifo(tmpl, 0600) == 0);
    // Run on a watchdog thread: if O_NONBLOCK ever regressed, open() on a writerless FIFO
    // would block forever — assert the call RETURNS (within 2 s) rather than letting it hang
    // CI. shared_ptr<promise> + detached thread + copied path → no UAF even on the hang path.
    auto pr = std::make_shared<std::promise<bool>>();
    auto fut = pr->get_future();
    std::string path = tmpl;
    std::thread([pr, path]{
        std::vector<float> out; uint32_t rate=0;
        pr->set_value(load_wav_pcm16(path.c_str(), out, &rate));
    }).detach();
    REQUIRE(fut.wait_for(std::chrono::seconds(2)) == std::future_status::ready);  // did NOT block
    CHECK(fut.get() == false);                                                    // rejected as non-regular
    unlink(tmpl);
}
