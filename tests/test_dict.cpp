#include "doctest.h"
#include "dictate_dict.h"

using dict::parse_dictionary;
using dict::estimate_tokens;
using dict::build_prompt;
using dict::build_initial_prompt;

// ── parse_dictionary ─────────────────────────────────────────────────────────
TEST_CASE("parse: one entry per line, order = priority, preserved") {
    auto e = parse_dictionary("alpha\nbeta\ngamma");
    REQUIRE(e.size() == 3);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
    CHECK(e[2] == "gamma");
}
TEST_CASE("parse: trims leading/trailing whitespace incl CR") {
    auto e = parse_dictionary("  alpha  \r\n\tbeta\t");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
}
TEST_CASE("parse: lone-CR and CRLF line endings both split (legacy files)") {
    auto crlf = parse_dictionary("alpha\r\nbeta\r\n");
    REQUIRE(crlf.size() == 2);
    CHECK(crlf[0] == "alpha");
    CHECK(crlf[1] == "beta");
    auto cr = parse_dictionary("alpha\rbeta\rgamma");   // classic-Mac, no '\n' at all
    REQUIRE(cr.size() == 3);
    CHECK(cr[0] == "alpha");
    CHECK(cr[1] == "beta");
    CHECK(cr[2] == "gamma");
}
TEST_CASE("parse: blank and whitespace-only lines skipped") {
    auto e = parse_dictionary("alpha\n\n   \n\t\nbeta\n");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
}
TEST_CASE("parse: full-line comment dropped") {
    auto e = parse_dictionary("# header comment\nalpha\n#another\nbeta");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
}
TEST_CASE("parse: inline comment after whitespace stripped, entry kept") {
    auto e = parse_dictionary("alpha   # this is a note\nbeta\t# n");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
}
TEST_CASE("parse: '#' inside a token survives (C#, F#) — comment only at start/after-ws") {
    auto e = parse_dictionary("C#\nF#\nha#sh\nval # comment");
    REQUIRE(e.size() == 4);
    CHECK(e[0] == "C#");     // '#' after 'C' (no preceding ws) → part of the token
    CHECK(e[1] == "F#");
    CHECK(e[2] == "ha#sh");  // '#' mid-token survives
    CHECK(e[3] == "val");    // " # comment" stripped ('#' after a space)
}
TEST_CASE("parse: dedup keeps the first (highest-priority) occurrence") {
    auto e = parse_dictionary("alpha\nbeta\nalpha\ngamma\nbeta");
    REQUIRE(e.size() == 3);
    CHECK(e[0] == "alpha");
    CHECK(e[1] == "beta");
    CHECK(e[2] == "gamma");
}
TEST_CASE("parse: dedup happens after comment-strip + trim") {
    auto e = parse_dictionary("alpha\n  alpha   # dup with note\n");
    REQUIRE(e.size() == 1);
    CHECK(e[0] == "alpha");
}
TEST_CASE("parse: empty content → no entries") {
    CHECK(parse_dictionary("").empty());
    CHECK(parse_dictionary("\n\n  \n# only comment\n").empty());
}
TEST_CASE("parse: last line without trailing newline is captured") {
    auto e = parse_dictionary("alpha\nbeta");
    REQUIRE(e.size() == 2);
    CHECK(e[1] == "beta");
}
TEST_CASE("parse: multi-word phrase entries kept whole") {
    auto e = parse_dictionary("machine learning\nnatural language processing");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "machine learning");
    CHECK(e[1] == "natural language processing");
}
TEST_CASE("parse: Cyrillic entries round-trip intact") {
    auto e = parse_dictionary("Яков\nКубернетес\n");
    REQUIRE(e.size() == 2);
    CHECK(e[0] == "Яков");
    CHECK(e[1] == "Кубернетес");
}

// ── estimate_tokens ──────────────────────────────────────────────────────────
TEST_CASE("estimate_tokens: empty string is 0") {
    CHECK(estimate_tokens("") == 0);
}
TEST_CASE("estimate_tokens: ascii ~2 chars/token + 1 per word") {
    // "abc": 3 chars, 1 word → (3+1)/2 + 1 = 2 + 1 = 3
    CHECK(estimate_tokens("abc") == 3);
    // "ab": 2 chars, 1 word → (2+1)/2 + 1 = 1 + 1 = 2
    CHECK(estimate_tokens("ab") == 2);
}
TEST_CASE("estimate_tokens: counts code points not bytes (Cyrillic)") {
    // "Яков": 4 code points (8 bytes), 1 word → (4+1)/2 + 1 = 2 + 1 = 3
    CHECK(estimate_tokens("Яков") == 3);
    // byte count would have given (8+1)/2 + 1 = 5; code-point counting gives 3
    CHECK(estimate_tokens("Яков") < 5);
}
TEST_CASE("estimate_tokens: each whitespace-separated word adds a token") {
    // "a b c": 3 chars, 3 words → (3+1)/2 + 3 = 2 + 3 = 5
    CHECK(estimate_tokens("a b c") == 5);
    // leading/trailing/extra spaces don't create empty words
    CHECK(estimate_tokens("  a   b  ") == estimate_tokens("a b"));
}
TEST_CASE("estimate_tokens: monotonic in added content") {
    CHECK(estimate_tokens("alpha beta") > estimate_tokens("alpha"));
}

// ── build_prompt / build_initial_prompt ──────────────────────────────────────
TEST_CASE("build: no entries → empty prompt") {
    CHECK(build_prompt({}) == "");
}
TEST_CASE("build: joins kept entries with ', '") {
    CHECK(build_prompt({"alpha", "beta", "gamma"}) == "alpha, beta, gamma");
}
TEST_CASE("build: stops adding once the token budget is reached, keeps priority order") {
    // each "aa" = (2+1)/2 + 1 = 2 tokens; separators add +1 each.
    // budget 5: "aa"(2,used2) + ", bb"(2+1=3,used5<=5) + ", cc"(3 → 8>5 skip) = "aa, bb"
    CHECK(build_prompt({"aa", "bb", "cc"}, 5) == "aa, bb");
    // budget 4: "aa"(2) then ", bb"(3 → 5>4 skip) then ", cc"(3 → skip) = "aa"
    CHECK(build_prompt({"aa", "bb", "cc"}, 4) == "aa");
}
TEST_CASE("build: an oversized entry is skipped, a later smaller one still fits") {
    // "longlonglong" = (12+1)/2 + 1 = 7 tokens; "x" = (1+1)/2 + 1 = 2 tokens.
    // budget 3: first(7)>3 skip; "x"(2, prompt empty so no sep) fits → "x"
    CHECK(build_prompt({"longlonglong", "x"}, 3) == "x");
}
TEST_CASE("build: budget of 0 yields empty prompt") {
    CHECK(build_prompt({"alpha", "beta"}, 0) == "");
}
TEST_CASE("build: a generous budget keeps everything") {
    CHECK(build_prompt({"alpha", "beta", "gamma"}, 1000) == "alpha, beta, gamma");
}
TEST_CASE("build_initial_prompt: parse + assemble end-to-end (comments, dups, order)") {
    std::string content =
        "# my dictionary\n"
        "Яков\n"
        "Кубернетес   # k8s\n"
        "gRPC\n"
        "Яков\n"        // dup → dropped
        "\n"
        "C#\n";
    CHECK(build_initial_prompt(content) == "Яков, Кубернетес, gRPC, C#");
}
TEST_CASE("build_initial_prompt: empty / comment-only content → empty prompt") {
    CHECK(build_initial_prompt("") == "");
    CHECK(build_initial_prompt("# just a comment\n\n   \n") == "");
}
TEST_CASE("build_initial_prompt: budget truncates by priority, never exceeds the cap") {
    std::string content;
    for (int i = 0; i < 500; ++i) content += "слово" + std::to_string(i) + "\n";
    std::string p = build_initial_prompt(content, dict::DEFAULT_MAX_TOKENS);
    CHECK(estimate_tokens(p) <= dict::DEFAULT_MAX_TOKENS);   // cap honored
    CHECK(!p.empty());                                       // some entries fit
    // The cap actually engaged (500 entries can't all fit in 224 tokens): the highest-priority
    // entry is kept and the lowest-priority one is dropped — proves priority-ordered truncation.
    CHECK(p.find("слово0,") == 0);                           // first entry kept, at the front
    CHECK(p.find("слово499") == std::string::npos);          // last entry dropped by the budget
}
