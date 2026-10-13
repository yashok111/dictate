// Pure transcriber logic (transcriber/core/*.h is platform-free C++, so it runs in the portable
// suite and in CI; the rest of the transcriber needs macOS — `make -C transcriber test`).
#include "doctest.h"
#include "../transcriber/core/asr_words.h"

using transcriber::AsrWord;
using transcriber::AsrWordCollector;

TEST_CASE("AsrWordCollector: a word merged with zero-width tokens is timing-uncertain (bug-hunt F138)") {
    AsrWordCollector c(0, 25000);
    c.add(1000, 1000, "a");
    c.add(1000, 1400, "b");
    auto w = c.finish();
    REQUIRE(w.size() == 1u);
    CHECK(w[0].text == "a b");
    CHECK(w[0].timing_uncertain);
}

TEST_CASE("AsrWordCollector: an ordinary timed word stays certain") {
    AsrWordCollector c(0, 25000);
    c.add(1000, 1400, "b");
    auto w = c.finish();
    REQUIRE(w.size() == 1u);
    CHECK_FALSE(w[0].timing_uncertain);
}

TEST_CASE("seam: a word both windows kept is a duplicate; a different or later word is not (bug-hunt F166)") {
    AsrWord prev{24950, 25150, "привет,", false};
    CHECK(transcriber::duplicate_at_seam(prev, {24900, 25100, "привет", false}));
    CHECK_FALSE(transcriber::duplicate_at_seam(prev, {24900, 25100, "пока", false}));
    CHECK_FALSE(transcriber::duplicate_at_seam(prev, {26000, 26300, "привет", false}));   // said again later
    CHECK_FALSE(transcriber::duplicate_at_seam(prev, {24900, 25100, ",", false}));        // punctuation only
}

TEST_CASE("seam: the slack keeps a straddling word in at least one window (bug-hunt F166)") {
    // window k's core ends at 25000; the word's midpoint 25050 is past it
    AsrWordCollector k(0, 25000 + transcriber::SEAM_SLACK_MS);
    k.add(24950, 25150, "слово");
    CHECK(k.finish().size() == 1u);
}
