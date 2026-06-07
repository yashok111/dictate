// Unit tests for the pure per-word confidence mapping (src/dictate_conf.h): whisper subword
// token probabilities → per-word min confidence aligned to em_tokenize, plus the argv
// serialize/parse round-trip that carries it across the daemon→editor process boundary.
#include "doctest.h"
#include "dictate_conf.h"

using conf::Token;

TEST_CASE("words_confidence: single token → single word") {
    auto c = conf::words_confidence({{"hello", 0.9f}});
    REQUIRE(c.size() == 1);
    CHECK(c[0] == doctest::Approx(0.9f));
}

TEST_CASE("words_confidence: subwords of one word → MIN of their probs") {
    auto c = conf::words_confidence({{"he", 0.9f}, {"llo", 0.3f}});
    REQUIRE(c.size() == 1);                       // "hello" is one word
    CHECK(c[0] == doctest::Approx(0.3f));         // least-certain subword wins
}

TEST_CASE("words_confidence: leading-space token starts a new word") {
    auto c = conf::words_confidence({{"hello", 0.8f}, {" world", 0.4f}});
    REQUIRE(c.size() == 2);
    CHECK(c[0] == doctest::Approx(0.8f));
    CHECK(c[1] == doctest::Approx(0.4f));         // the space byte isn't in any word span
}

TEST_CASE("words_confidence: punctuation gets its own token's prob") {
    // "да" (.9) "," (.2) " нет" (.7)  → words: да , нет
    auto c = conf::words_confidence({{"\xD0\xB4\xD0\xB0", 0.9f}, {",", 0.2f}, {" \xD0\xBD\xD0\xB5\xD1\x82", 0.7f}});
    REQUIRE(c.size() == 3);
    CHECK(c[0] == doctest::Approx(0.9f));
    CHECK(c[1] == doctest::Approx(0.2f));
    CHECK(c[2] == doctest::Approx(0.7f));
}

TEST_CASE("words_confidence: empty token list → empty") {
    CHECK(conf::words_confidence({}).empty());
}

TEST_CASE("words_confidence: length always matches em_tokenize of the concatenation") {
    std::vector<Token> toks = {{"При", 0.6f}, {"вет", 0.8f}, {" мир", 0.5f}, {"!", 0.2f}};
    std::string s;
    for (auto &t : toks) s += t.text;
    CHECK(conf::words_confidence(toks).size() == em_tokenize(s).size());
}

TEST_CASE("serialize/parse: round-trip preserves values within 1/1000") {
    std::vector<float> c = {0.9f, 0.2f, 0.7f};
    std::string s = conf::serialize(c);
    CHECK(s == "900,200,700");
    auto back = conf::parse(s, 3);
    REQUIRE(back.size() == 3);
    CHECK(back[0] == doctest::Approx(0.9f));
    CHECK(back[1] == doctest::Approx(0.2f));
    CHECK(back[2] == doctest::Approx(0.7f));
}

TEST_CASE("serialize: empty in → empty string") {
    CHECK(conf::serialize({}).empty());
}

TEST_CASE("serialize: clamps out-of-range probs to [0,1000]") {
    CHECK(conf::serialize({1.5f, -0.2f}) == "1000,0");
}

TEST_CASE("parse: count mismatch disables the feature (returns empty)") {
    CHECK(conf::parse("900,200", 3).empty());     // 2 fields, expected 3
    CHECK(conf::parse("900,200,700", 2).empty());  // 3 fields, expected 2
}

TEST_CASE("parse: empty string yields empty (no highlighting)") {
    CHECK(conf::parse("", 0).empty());
    CHECK(conf::parse("", 2).empty());             // expected 2 but none → empty
}

TEST_CASE("parse: clamps each field to [0,1]") {
    auto c = conf::parse("1500,0", 2);
    REQUIRE(c.size() == 2);
    CHECK(c[0] == doctest::Approx(1.0f));
    CHECK(c[1] == doctest::Approx(0.0f));
}

// ── realign: carry confidence across finalize_transcript (normalize_text) ──
TEST_CASE("realign: identity when finalize leaves tokenization unchanged") {
    auto c = conf::realign("\xD0\xB0 \xD0\xB1", {0.3f, 0.9f}, "\xD0\xB0 \xD0\xB1");   // "а б"
    REQUIRE(c.size() == 2);
    CHECK(c[0] == doctest::Approx(0.3f));
    CHECK(c[1] == doctest::Approx(0.9f));
}

TEST_CASE("realign: capitalization (text changes, count stable) keeps confidence") {
    // raw "привет мир" → final "Привет мир": same word count, only the case changed.
    auto c = conf::realign("\xD0\xBF\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82 \xD0\xBC\xD0\xB8\xD1\x80",
                           {0.4f, 0.85f},
                           "\xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82 \xD0\xBC\xD0\xB8\xD1\x80");
    REQUIRE(c.size() == 2);
    CHECK(c[0] == doctest::Approx(0.4f));
    CHECK(c[1] == doctest::Approx(0.85f));
}

TEST_CASE("realign: inserted punctuation token gets EM_CONF_SURE, words keep their conf") {
    // raw "a b" (2 words) → final "a, b" (em_tokenize → a , b): punctuation slots in.
    auto c = conf::realign("a b", {0.3f, 0.7f}, "a, b");
    REQUIRE(c.size() == 3);                       // a , b
    CHECK(c[0] == doctest::Approx(0.3f));
    CHECK(c[1] == doctest::Approx(EM_CONF_SURE)); // the comma
    CHECK(c[2] == doctest::Approx(0.7f));
}

TEST_CASE("realign: ellipsis collapse (... → …) preserves word confidence") {
    // raw em_tokenize: [w1, ., ., ., w2] (5) → final [W1, …, w2] (3, … is one punct token).
    std::vector<float> raw = {0.5f, 1.0f, 1.0f, 1.0f, 0.7f};
    auto c = conf::realign("w1 . . . w2", raw, "W1\xE2\x80\xA6 w2");   // "W1… w2"
    REQUIRE(c.size() == 3);                       // W1 … w2
    CHECK(c[0] == doctest::Approx(0.5f));
    CHECK(c[1] == doctest::Approx(EM_CONF_SURE)); // the …
    CHECK(c[2] == doctest::Approx(0.7f));
}

TEST_CASE("realign: non-punct word count change disables (returns empty)") {
    CHECK(conf::realign("a b", {0.5f, 0.6f}, "a b c").empty());   // a real word added
}

TEST_CASE("realign: rawConf not aligned to rawText → empty") {
    CHECK(conf::realign("a b c", {0.5f, 0.6f}, "a b c").empty()); // 3 words, 2 conf
}

TEST_CASE("realign: empty inputs → empty (no highlighting)") {
    CHECK(conf::realign("", {}, "").empty());
}
