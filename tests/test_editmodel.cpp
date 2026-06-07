// Unit tests for the pure voice-editor model (src/dictate_editmodel.h): tokenization,
// cursor arithmetic + navigation, word replace/insert, and the per-line nearest-word search.
#include "doctest.h"
#include "dictate_editmodel.h"

TEST_CASE("em_tokenize: whitespace split, empties dropped") {
    CHECK(em_tokenize("a  b\nc") == std::vector<std::string>{"a","b","c"});
    CHECK(em_tokenize("  alpha\tbeta \r\n gamma ") == std::vector<std::string>{"alpha","beta","gamma"});
    CHECK(em_tokenize("").empty());
    CHECK(em_tokenize("   \t\n ").empty());
    CHECK(em_tokenize("solo") == std::vector<std::string>{"solo"});
    CHECK(em_tokenize("привет мир") == std::vector<std::string>{"привет","мир"});   // UTF-8 passes through
}

TEST_CASE("cursor arithmetic: max/onWord/word+gap index") {
    CHECK(em_max_pos(3) == 6);
    CHECK(em_max_pos(0) == 0);
    CHECK(em_on_word(1));  CHECK(em_on_word(5));
    CHECK_FALSE(em_on_word(0)); CHECK_FALSE(em_on_word(2));
    CHECK(em_word_index(1) == 0); CHECK(em_word_index(3) == 1); CHECK(em_word_index(5) == 2);
    CHECK(em_gap_index(0) == 0); CHECK(em_gap_index(2) == 1); CHECK(em_gap_index(6) == 3);
}

TEST_CASE("em_clamp_step: ←/→ clamp to [0, maxPos]") {
    CHECK(em_clamp_step(0, -1, 6) == 0);    // already at start
    CHECK(em_clamp_step(6, +1, 6) == 6);    // already at end
    CHECK(em_clamp_step(3, -1, 6) == 2);
    CHECK(em_clamp_step(3, +1, 6) == 4);
}

TEST_CASE("EditModel::fromText: tokenizes, cursor on first word (or 0 if empty)") {
    EditModel m = EditModel::fromText("alpha beta gamma");
    CHECK(m.words.size() == 3);
    CHECK(m.pos == 1);
    CHECK(m.onWord());
    CHECK(m.wordIndex() == 0);
    EditModel e = EditModel::fromText("   ");
    CHECK(e.words.empty());
    CHECK(e.pos == 0);
}

TEST_CASE("stepLeft/stepRight walk gaps and words and clamp at the edges") {
    EditModel m = EditModel::fromText("a b c");   // pos 1, maxPos 6
    m.stepLeft();  CHECK(m.pos == 0);             // into the leading gap
    m.stepLeft();  CHECK(m.pos == 0);             // clamped
    for (int i = 0; i < 6; i++) m.stepRight();
    CHECK(m.pos == 6);                            // trailing gap
    m.stepRight(); CHECK(m.pos == 6);             // clamped
}

TEST_CASE("em_cursor_kind: structural classification") {
    CHECK(em_cursor_kind(0, 0) == CursorKind::empty);
    CHECK(em_cursor_kind(3, 1) == CursorKind::onWord);
    CHECK(em_cursor_kind(3, 0) == CursorKind::gapStart);
    CHECK(em_cursor_kind(3, 6) == CursorKind::gapEnd);     // g == nwords
    CHECK(em_cursor_kind(3, 2) == CursorKind::gapBetween);
}

TEST_CASE("EditModel::joined round-trips with single spaces") {
    CHECK(EditModel::fromText("a  b   c").joined() == "a b c");
    CHECK(EditModel{}.joined() == "");
}

TEST_CASE("applyResult: replace the current word") {
    EditModel m = EditModel::fromText("a b c");   // pos 1 → word a
    m.applyResult("X");
    CHECK(m.words == std::vector<std::string>{"X","b","c"});
    CHECK(m.pos == 1);
}

TEST_CASE("applyResult: a multi-word result expands in place, cursor on the first") {
    EditModel m = EditModel::fromText("a b c");   // pos 1 → word a
    m.applyResult("X Y");
    CHECK(m.words == std::vector<std::string>{"X","Y","b","c"});
    CHECK(m.pos == 1);                            // 2*0+1
}

TEST_CASE("applyResult: insert at a middle gap") {
    EditModel m = EditModel::fromText("a b c");
    m.pos = 2;                                    // gap after 'a' (gapIndex 1)
    m.applyResult("Z");
    CHECK(m.words == std::vector<std::string>{"a","Z","b","c"});
    CHECK(m.pos == 3);                            // 2*1+1 → on the new word
}

TEST_CASE("applyResult: insert at the leading and trailing gaps") {
    EditModel a = EditModel::fromText("a b c"); a.pos = 0;   // leading gap
    a.applyResult("Z");
    CHECK(a.words == std::vector<std::string>{"Z","a","b","c"});
    CHECK(a.pos == 1);
    EditModel b = EditModel::fromText("a b c"); b.pos = 6;   // trailing gap (gapIndex 3)
    b.applyResult("Z");
    CHECK(b.words == std::vector<std::string>{"a","b","c","Z"});
    CHECK(b.pos == 7);
}

TEST_CASE("applyResult: empty / whitespace-only result is a no-op") {
    EditModel m = EditModel::fromText("a b c");
    m.applyResult("   \n");
    CHECK(m.words == std::vector<std::string>{"a","b","c"});
    CHECK(m.pos == 1);
}

// ── mini-take cleanup: case/punct helpers ──────────────────────────────────────
TEST_CASE("em_is_sentence_punct: only sentence enders") {
    CHECK(em_is_sentence_punct("."));  CHECK(em_is_sentence_punct("!"));
    CHECK(em_is_sentence_punct("?"));  CHECK(em_is_sentence_punct("…"));
    CHECK_FALSE(em_is_sentence_punct(",")); CHECK_FALSE(em_is_sentence_punct("слово"));
    CHECK_FALSE(em_is_sentence_punct(""));
}

TEST_CASE("em_first_is_upper / em_first_is_letter: ASCII + Cyrillic") {
    CHECK(em_first_is_upper("Слово"));  CHECK(em_first_is_upper("Ёлка"));  CHECK(em_first_is_upper("Hello"));
    CHECK_FALSE(em_first_is_upper("слово")); CHECK_FALSE(em_first_is_upper("ёлка"));
    CHECK_FALSE(em_first_is_upper("123")); CHECK_FALSE(em_first_is_upper(""));
    CHECK(em_first_is_letter("слово")); CHECK(em_first_is_letter("X"));
    CHECK_FALSE(em_first_is_letter("123")); CHECK_FALSE(em_first_is_letter("."));
}

TEST_CASE("em_recase_first: upper/lower the first letter only") {
    std::string a = "слово"; em_recase_first(a, true);  CHECK(a == "Слово");
    std::string b = "Слово"; em_recase_first(b, false); CHECK(b == "слово");
    std::string c = "ёж";    em_recase_first(c, true);  CHECK(c == "Ёж");
    std::string d = "Ёж";    em_recase_first(d, false); CHECK(d == "ёж");
    std::string e = "123";   em_recase_first(e, true);  CHECK(e == "123");   // non-letter untouched
}

TEST_CASE("em_to_lower: ASCII + Cyrillic, leaves the rest") {
    CHECK(em_to_lower("Знак Вопроса") == "знак вопроса");
    CHECK(em_to_lower("ТОЧКА") == "точка");
    CHECK(em_to_lower("ЁЛКА123") == "ёлка123");
}

// ── mini-take cleanup: spoken punctuation ──────────────────────────────────────
TEST_CASE("em_spoken_punct: punctuation names → symbols (case/dot-insensitive)") {
    CHECK(em_spoken_punct("знак вопроса") == "?");
    CHECK(em_spoken_punct("Знак вопроса.") == "?");        // whisper's Capital + trailing dot tolerated
    CHECK(em_spoken_punct("вопросительный знак") == "?");
    CHECK(em_spoken_punct("запятая") == ",");
    CHECK(em_spoken_punct("точка") == ".");
    CHECK(em_spoken_punct("точка с запятой") == ";");
    CHECK(em_spoken_punct("двоеточие") == ":");
    CHECK(em_spoken_punct("восклицательный знак") == "!");
    CHECK(em_spoken_punct("многоточие") == "\xE2\x80\xA6");   // …
    CHECK(em_spoken_punct("тире") == "\xE2\x80\x94");          // —
    CHECK(em_spoken_punct("открыть скобку") == "(");
    CHECK(em_spoken_punct("закрыть кавычки") == "\xC2\xBB");   // »
}
TEST_CASE("em_spoken_punct: a normal word is not a punctuation name") {
    CHECK(em_spoken_punct("привет") == "");
    CHECK(em_spoken_punct("это точка зрения") == "");          // phrase ≠ exact name
    CHECK(em_spoken_punct("") == "");
}

// ── mini-take cleanup: applyMiniTake (the real voice-edit path) ─────────────────
TEST_CASE("applyMiniTake: mid-sentence replacement loses Capital + trailing dot") {
    EditModel m = EditModel::fromText("привет старый мир");
    m.pos = 3;                                  // on word "старый"
    m.applyMiniTake("Новый.");                   // whisper's Capital + dot
    CHECK(m.words == std::vector<std::string>{"привет","новый","мир"});
}

TEST_CASE("applyMiniTake: replacing a Capitalized word keeps the Capital") {
    EditModel m = EditModel::fromText("Старый мир");
    m.pos = 1;                                  // on word "Старый" (sentence start)
    m.applyMiniTake("Новый.");
    CHECK(m.words == std::vector<std::string>{"Новый","мир"});
}

TEST_CASE("applyMiniTake: insert at a sentence-start gap capitalizes") {
    EditModel m = EditModel::fromText("конец . привет");   // tokens: конец . привет
    m.pos = 4;                                  // gap after "." (gapIndex 2) → sentence start
    m.applyMiniTake("новый.");
    CHECK(m.words == std::vector<std::string>{"конец",".","Новый","привет"});
}

TEST_CASE("applyMiniTake: insert mid-sentence stays lowercase") {
    EditModel m = EditModel::fromText("раз два");
    m.pos = 2;                                  // gap after "раз" (gapIndex 1), mid-sentence
    m.applyMiniTake("Три.");
    CHECK(m.words == std::vector<std::string>{"раз","три","два"});
}

TEST_CASE("applyMiniTake: spoken punctuation inserts a symbol verbatim") {
    EditModel m = EditModel::fromText("привет");
    m.pos = 2;                                  // trailing gap
    m.applyMiniTake("Знак вопроса.");
    CHECK(m.words == std::vector<std::string>{"привет","?"});
    CHECK(m.joined() == "привет?");             // glued, no space before ?
}

TEST_CASE("applyMiniTake: a real multi-word fix keeps inner words' case, fixes only the first") {
    EditModel m = EditModel::fromText("я знаю это");
    m.pos = 5;                                  // on word "это" (index 2)
    m.applyMiniTake("Москва Сити.");             // proper nouns: only the leading one is recased to context
    CHECK(m.words == std::vector<std::string>{"я","знаю","москва","Сити"});
}

TEST_CASE("em_nearest_word_on_line: closest mid-X on the target line") {
    std::vector<EmCell> cells = {{0,10,0},{0,50,1},{1,12,2},{1,60,3}};
    CHECK(em_nearest_word_on_line(cells, 1, 15.0) == 2);   // |12-15|=3 < |60-15|=45
    CHECK(em_nearest_word_on_line(cells, 0, 45.0) == 1);   // |50-45|=5 < |10-45|=35
    CHECK(em_nearest_word_on_line(cells, 2, 30.0) == -1);  // no word on line 2
}

TEST_CASE("em_nearest_word_on_line: a tie keeps the first (strict <)") {
    std::vector<EmCell> cells = {{0,0,0},{0,20,1}};
    CHECK(em_nearest_word_on_line(cells, 0, 10.0) == 0);   // both |Δ|=10 → first wins
}

// ── punctuation as its own token ───────────────────────────────────────────────
TEST_CASE("em_tokenize: punctuation splits into its own token") {
    CHECK(em_tokenize("тест.")        == std::vector<std::string>{"тест","."});
    CHECK(em_tokenize("привет, мир")  == std::vector<std::string>{"привет",",","мир"});
    CHECK(em_tokenize("a.b")          == std::vector<std::string>{"a",".","b"});
    CHECK(em_tokenize("...")          == std::vector<std::string>{".",".","."});
    CHECK(em_tokenize("дела?!")       == std::vector<std::string>{"дела","?","!"});
    CHECK(em_tokenize("«тест»")       == std::vector<std::string>{"«","тест","»"});
    CHECK(em_tokenize("(тест)")       == std::vector<std::string>{"(","тест",")"});
    CHECK(em_tokenize("раз… два")     == std::vector<std::string>{"раз","…","два"});
}

TEST_CASE("em_tokenize: intra-word hyphen and en/em dash") {
    CHECK(em_tokenize("что-то")            == std::vector<std::string>{"что-то"});   // hyphen stays in word
    CHECK(em_tokenize("Москва — столица")  == std::vector<std::string>{"Москва","—","столица"}); // em dash splits
}

TEST_CASE("em_is_punct_token: single mark vs word") {
    CHECK(em_is_punct_token("."));
    CHECK(em_is_punct_token(","));
    CHECK(em_is_punct_token("«"));
    CHECK(em_is_punct_token("—"));
    CHECK_FALSE(em_is_punct_token("тест"));
    CHECK_FALSE(em_is_punct_token("что-то"));
    CHECK_FALSE(em_is_punct_token(""));
    CHECK_FALSE(em_is_punct_token(".."));     // two codepoints → not a single mark
}

// ── punctuation-aware join (Russian spacing) ───────────────────────────────────
TEST_CASE("em_join: no space before trailing marks, after opening marks") {
    CHECK(em_join({"привет",",","мир"})                == "привет, мир");
    CHECK(em_join({"Привет",".","Как","дела","?"})     == "Привет. Как дела?");
    CHECK(em_join({"«","тест","»"})                    == "«тест»");
    CHECK(em_join({"(","тест",")"})                    == "(тест)");
    CHECK(em_join({"дела","?","!"})                    == "дела?!");
    CHECK(em_join({"раз","…","два"})                   == "раз… два");
}

TEST_CASE("em_join: em dash is word-like (spaced both sides)") {
    CHECK(em_join({"Москва","—","столица"}) == "Москва — столица");
}

TEST_CASE("em_join: straight double-quote alternates open/close") {
    CHECK(em_join({"\"","тест","\""})              == "\"тест\"");
    CHECK(em_join({"он","\"","да","\"","сказал"})  == "он \"да\" сказал");
}

TEST_CASE("em_join: plain words keep single-space behaviour") {
    CHECK(em_join({"a","b","c"}) == "a b c");
    CHECK(em_join({}).empty());
}

TEST_CASE("joined round-trips a real sentence through fromText") {
    CHECK(EditModel::fromText("Привет, мир!").joined()       == "Привет, мир!");
    CHECK(EditModel::fromText("Это «тест», да?").joined()    == "Это «тест», да?");
}

// ── delete (keyCode 51 backspace) ──────────────────────────────────────────────
TEST_CASE("deleteToken: on a word removes it, cursor into the gap left behind") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 3;   // on word b
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"a","c"});
    CHECK(m.pos == 2);                                       // gap between a and c
}

TEST_CASE("deleteToken: on the last word lands in the trailing gap") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 5;   // on word c
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"a","b"});
    CHECK(m.pos == 4);                                       // == maxPos (trailing gap)
}

TEST_CASE("deleteToken: deleting the only word empties and resets cursor") {
    EditModel m = EditModel::fromText("solo");               // pos 1
    m.deleteToken();
    CHECK(m.words.empty());
    CHECK(m.pos == 0);
}

TEST_CASE("deleteToken: empty model is a no-op") {
    EditModel m;                                             // no words, pos 0
    m.deleteToken();
    CHECK(m.words.empty());
    CHECK(m.pos == 0);
}

TEST_CASE("deleteToken: in a gap backspaces the previous token") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 2;   // gap after a
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"b","c"});
    CHECK(m.pos == 0);                                       // gap where a was
}

TEST_CASE("deleteToken: leading gap is a no-op") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 0;   // leading gap
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"a","b","c"});
    CHECK(m.pos == 0);
}

TEST_CASE("deleteToken: trailing gap backspaces the last token") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 6;   // trailing gap
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"a","b"});
    CHECK(m.pos == 4);                                       // gap where c was (== new maxPos)
}

TEST_CASE("deleteToken: removes a punctuation token and join re-spaces") {
    EditModel m = EditModel::fromText("тест, ещё");          // {тест , ещё}, pos 1
    CHECK(m.words == std::vector<std::string>{"тест",",","ещё"});
    m.pos = 3;                                               // on the comma
    CHECK(em_is_punct_token(m.words[m.wordIndex()]));
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"тест","ещё"});
    CHECK(m.joined() == "тест ещё");
}

// ── forward delete (keyCode 117) ───────────────────────────────────────────────
TEST_CASE("deleteForward: on a word removes it, cursor stays in the gap") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 3;   // on word b
    m.deleteForward();
    CHECK(m.words == std::vector<std::string>{"a","c"});
    CHECK(m.pos == 2);
}

TEST_CASE("deleteForward: in a gap removes the next token") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 2;   // gap after a
    m.deleteForward();
    CHECK(m.words == std::vector<std::string>{"a","c"});
    CHECK(m.pos == 2);                                       // chews forward
}

TEST_CASE("deleteForward: trailing gap is a no-op") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 6;   // trailing gap
    m.deleteForward();
    CHECK(m.words == std::vector<std::string>{"a","b","c"});
    CHECK(m.pos == 6);
}

TEST_CASE("deleteForward: on the last word lands in the trailing gap") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 5;   // on word c
    m.deleteForward();
    CHECK(m.words == std::vector<std::string>{"a","b"});
    CHECK(m.pos == 4);
}

TEST_CASE("deleteForward: leading gap removes the first token") {
    EditModel m = EditModel::fromText("a b c"); m.pos = 0;   // leading gap
    m.deleteForward();
    CHECK(m.words == std::vector<std::string>{"b","c"});
    CHECK(m.pos == 0);
}

TEST_CASE("deleteForward: only word empties and resets cursor") {
    EditModel m = EditModel::fromText("solo");               // pos 1
    m.deleteForward();
    CHECK(m.words.empty());
    CHECK(m.pos == 0);
}

TEST_CASE("deleteForward: empty model is a no-op") {
    EditModel m;
    m.deleteForward();
    CHECK(m.words.empty());
    CHECK(m.pos == 0);
}

// ── em_tokenize_spans: byte spans address exactly the token's bytes; em_tokenize delegates ──
TEST_CASE("em_tokenize_spans: word spans + text match em_tokenize") {
    auto sp = em_tokenize_spans("ab  cd");
    REQUIRE(sp.size() == 2);
    CHECK(sp[0].text == "ab"); CHECK(sp[0].start == 0); CHECK(sp[0].len == 2);
    CHECK(sp[1].text == "cd"); CHECK(sp[1].start == 4); CHECK(sp[1].len == 2);   // two spaces skipped
    std::string s = "ab  cd";
    CHECK(s.substr(sp[1].start, sp[1].len) == "cd");                            // span = exact bytes
}

TEST_CASE("em_tokenize_spans: punctuation isolated with its own span") {
    auto sp = em_tokenize_spans("\xD0\xB4\xD0\xB0,");          // "да,"
    REQUIRE(sp.size() == 2);
    CHECK(sp[0].text == "\xD0\xB4\xD0\xB0"); CHECK(sp[0].start == 0); CHECK(sp[0].len == 4);
    CHECK(sp[1].text == ","); CHECK(sp[1].start == 4); CHECK(sp[1].len == 1);
}

TEST_CASE("em_tokenize_spans: texts equal em_tokenize for mixed input") {
    for (const char *in : {"", "  ", "solo", "a, b! c", "что-то «эх»"}) {
        auto sp = em_tokenize_spans(in);
        auto tk = em_tokenize(in);
        REQUIRE(sp.size() == tk.size());
        for (std::size_t i = 0; i < tk.size(); i++) CHECK(sp[i].text == tk[i]);
    }
}

// ── EditModel.conf: parallel per-word confidence kept aligned through every edit ──
TEST_CASE("EditModel.conf: deleteToken erases the matching confidence") {
    EditModel m; m.words = {"a","b","c"}; m.conf = {0.9f, 0.2f, 0.7f}; m.pos = 3;   // on "b"
    m.deleteToken();
    CHECK(m.words == std::vector<std::string>{"a","c"});
    REQUIRE(m.conf.size() == 2);
    CHECK(m.conf[0] == doctest::Approx(0.9f));
    CHECK(m.conf[1] == doctest::Approx(0.7f));
}

TEST_CASE("EditModel.conf: applyResult replace marks new words EM_CONF_SURE") {
    EditModel m; m.words = {"a","b"}; m.conf = {0.9f, 0.2f}; m.pos = 3;             // on "b"
    m.applyResult("x y");
    CHECK(m.words == std::vector<std::string>{"a","x","y"});
    REQUIRE(m.conf.size() == 3);
    CHECK(m.conf[0] == doctest::Approx(0.9f));
    CHECK(m.conf[1] == doctest::Approx(EM_CONF_SURE));
    CHECK(m.conf[2] == doctest::Approx(EM_CONF_SURE));
}

TEST_CASE("EditModel.conf: applyResult insert at gap keeps alignment") {
    EditModel m; m.words = {"a","b"}; m.conf = {0.9f, 0.2f}; m.pos = 2;             // gap between a,b
    m.applyResult("z");
    CHECK(m.words == std::vector<std::string>{"a","z","b"});
    REQUIRE(m.conf.size() == 3);
    CHECK(m.conf[0] == doctest::Approx(0.9f));
    CHECK(m.conf[1] == doctest::Approx(EM_CONF_SURE));
    CHECK(m.conf[2] == doctest::Approx(0.2f));
}

TEST_CASE("EditModel.conf: empty conf stays empty (text-only path)") {
    EditModel m = EditModel::fromText("one two three");       // conf unknown → empty
    CHECK(m.conf.empty());
    m.deleteToken();
    CHECK(m.conf.empty());                                    // ops no-op on conf when empty
    m.applyResult("x");
    CHECK(m.conf.empty());
    CHECK(m.words.size() == 3);                               // words still edited correctly
}
