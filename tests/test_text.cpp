#include "doctest.h"
#include "dictate_text.h"

TEST_CASE("collapses internal whitespace runs to single spaces") {
    CHECK(normalize_ws("a   b") == "a b");
    CHECK(normalize_ws("a\t\tb") == "a b");
    CHECK(normalize_ws("a\n\nb") == "a b");
    CHECK(normalize_ws("a \t\r\n b") == "a b");
}
TEST_CASE("trims leading and trailing whitespace") {
    CHECK(normalize_ws("   hello") == "hello");
    CHECK(normalize_ws("hello   ") == "hello");
    CHECK(normalize_ws("  hello  world  ") == "hello world");
}
TEST_CASE("empty / all-whitespace input yields empty string") {
    CHECK(normalize_ws("") == "");
    CHECK(normalize_ws("    ") == "");
    CHECK(normalize_ws("\t\n\r ") == "");
}
TEST_CASE("single token is preserved unchanged") {
    CHECK(normalize_ws("word") == "word");
}
TEST_CASE("single internal spaces are preserved") {
    CHECK(normalize_ws("one two three") == "one two three");
}
TEST_CASE("UTF-8 bytes pass through (Cyrillic)") {
    CHECK(normalize_ws("  привет   мир  ") == "привет мир");
}

// ── normalize_text: full post-normalizer (punctuation/case/typography) ─────────
// Conservative, RU-aware, UTF-8 safe. Built on normalize_ws.

TEST_CASE("normalize_text: whitespace still normalized (delegates to normalize_ws)") {
    CHECK(normalize_text("") == "");
    CHECK(normalize_text("   ") == "");
    CHECK(normalize_text("a   b") == "A b");          // + first-letter capitalize
}

TEST_CASE("normalize_text: capitalizes first letter of the string") {
    CHECK(normalize_text("привет") == "Привет");
    CHECK(normalize_text("hello world") == "Hello world");
    CHECK(normalize_text("ёлка") == "Ёлка");          // ё → Ё
    CHECK(normalize_text("йод") == "Йод");            // й → Й  (D0 B9 → D0 99)
    CHECK(normalize_text("ъ") == "Ъ");                // last-row cyrillic (D1 8A → D0 AA)
    CHECK(normalize_text("яма") == "Яма");            // я → Я  (D1 8F → D0 AF)
}
TEST_CASE("normalize_text: leaves already-capital first letter") {
    CHECK(normalize_text("Привет") == "Привет");
    CHECK(normalize_text("ABC") == "ABC");
}
TEST_CASE("normalize_text: does not capitalize when string starts with non-letter") {
    CHECK(normalize_text("123 рубля") == "123 рубля");   // leading digit → no cap
}

TEST_CASE("normalize_text: capitalizes after sentence-ending . ! ?") {
    CHECK(normalize_text("привет. как дела") == "Привет. Как дела");
    CHECK(normalize_text("да! нет") == "Да! Нет");
    CHECK(normalize_text("что? ничего") == "Что? Ничего");
    CHECK(normalize_text("ok. done") == "Ok. Done");     // mixed EN
}
TEST_CASE("normalize_text: does not capitalize after comma/semicolon/colon") {
    CHECK(normalize_text("раз, два") == "Раз, два");
    CHECK(normalize_text("итак: вот") == "Итак: вот");
}

TEST_CASE("normalize_text: removes space before punctuation") {
    CHECK(normalize_text("привет , мир") == "Привет, мир");
    CHECK(normalize_text("да ?") == "Да?");
    CHECK(normalize_text("слово ; ещё") == "Слово; ещё");
    CHECK(normalize_text("текст .") == "Текст.");
}
TEST_CASE("normalize_text: inserts space after clause punctuation") {
    CHECK(normalize_text("привет,мир") == "Привет, мир");
    CHECK(normalize_text("раз,два,три") == "Раз, два, три");
    CHECK(normalize_text("да!нет") == "Да! Нет");        // ! also gets a trailing space
}

TEST_CASE("normalize_text: protects decimals from comma spacing") {
    CHECK(normalize_text("число 3.14 тут") == "Число 3.14 тут");
    CHECK(normalize_text("цена 5,5 рубля") == "Цена 5,5 рубля");
    CHECK(normalize_text("сумма 1,000,000") == "Сумма 1,000,000");
}
TEST_CASE("normalize_text: glued period is left alone (domain/file/version safe)") {
    CHECK(normalize_text("сайт github.com тут") == "Сайт github.com тут");
    CHECK(normalize_text("открой terminal.app сейчас") == "Открой terminal.app сейчас");
    CHECK(normalize_text("файл readme.txt здесь") == "Файл readme.txt здесь");
    CHECK(normalize_text("версия v2.0 готова") == "Версия v2.0 готова");
}
TEST_CASE("normalize_text: abbreviation guard — single-letter token before a dot is not a sentence end") {
    CHECK(normalize_text("и т.д. конец") == "И т.д. конец");
    CHECK(normalize_text("и т.п. далее") == "И т.п. далее");
}

TEST_CASE("normalize_text: collapses 3+ dots into an ellipsis") {
    CHECK(normalize_text("ну...") == "Ну…");
    CHECK(normalize_text("вот....") == "Вот…");
    CHECK(normalize_text("ну...что") == "Ну… Что");      // ellipsis is a sentence end
}
TEST_CASE("normalize_text: spaced hyphen/en-dash becomes em-dash") {
    CHECK(normalize_text("я - ты") == "Я — ты");
    CHECK(normalize_text("я – ты") == "Я — ты");
}
TEST_CASE("normalize_text: in-word hyphen is left untouched") {
    CHECK(normalize_text("кто-то") == "Кто-то");
    CHECK(normalize_text("из-за угла") == "Из-за угла");
}

TEST_CASE("normalize_text: does not break mixed RU/EN") {
    CHECK(normalize_text("use API key") == "Use API key");   // only first letter; API stays
    CHECK(normalize_text("открой terminal.app сейчас") == "Открой terminal.app сейчас");
}

TEST_CASE("normalize_text: leaves quotes untouched (no quote conversion)") {
    CHECK(normalize_text("он сказал \"привет\" мне") == "Он сказал \"привет\" мне"); // straight quotes kept
    CHECK(normalize_text("«цитата» тут") == "«цитата» тут");                          // existing guillemets not mangled
}
TEST_CASE("normalize_text: consecutive sentence punctuation") {
    CHECK(normalize_text("привет!? что") == "Привет!? Что");
}

TEST_CASE("normalize_text: idempotent (a second pass changes nothing)") {
    const char *samples[] = {
        "привет, как дела? всё хорошо.",
        "число 3.14 и т.д.",
        "ну...что дальше",
        "я - ты, он - она",
        "сайт github.com тут",
    };
    for (auto s : samples) {
        std::string once = normalize_text(s);
        CHECK(normalize_text(once) == once);
    }
}
