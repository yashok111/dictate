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
    CHECK(normalize_text("ну...что") == "Ну… что");      // … is a pause, not a sentence end (F123)
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
    CHECK(normalize_text("«цитата» тут") == "«Цитата» тут");                          // guillemets kept; the first letter past them is capitalized (F122)
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

// ── bug-hunt regressions (f90bf59 hunt, report F066/F142/F159/F067/F068/F069/F122/F123) ──
TEST_CASE("normalize_text: times, scores and ports keep their colon glued (F066, F142)") {
    CHECK(normalize_text("встреча в 12:30") == "Встреча в 12:30");
    CHECK(normalize_text("встреча в 12:30 завтра") == "Встреча в 12:30 завтра");
    CHECK(normalize_text("счёт 3:1") == "Счёт 3:1");
    CHECK(normalize_text("localhost:3000") == "Localhost:3000");
}
TEST_CASE("normalize_text: URLs, queries and C++ scope stay intact (F066, F142, F067)") {
    CHECK(normalize_text("открой https://example.com/a?x=1") == "Открой https://example.com/a?x=1");
    CHECK(normalize_text("site.com/a?id=5") == "Site.com/a?id=5");
    CHECK(normalize_text("тип std::vector тут") == "Тип std::vector тут");
    CHECK(normalize_text("почта a@b.ru,ок") == "Почта a@b.ru,ок");   // code-like token: left alone
}
TEST_CASE("normalize_text: a closing quote is not split off its mark (F159)") {
    CHECK(normalize_text("Он сказал \"Привет!\" и ушёл") == "Он сказал \"Привет!\" и ушёл");
    CHECK(normalize_text("\xE2\x80\x9C\xD0\x94\xD0\xB0?\xE2\x80\x9D \xE2\x80\x94 спросил он")
          == "\xE2\x80\x9C\xD0\x94\xD0\xB0?\xE2\x80\x9D \xE2\x80\x94 спросил он");     // “Да?” — спросил он
    CHECK(normalize_text("сказал:\"привет\"") == "Сказал: \"привет\"");                     // after ':' it opens
}
TEST_CASE("normalize_text: a dot that starts a name keeps the space before it (F068)") {
    CHECK(normalize_text("файл .env тут") == "Файл .env тут");
    CHECK(normalize_text("нужен .NET") == "Нужен .NET");
}
TEST_CASE("normalize_text: «я» and I end a sentence; initials still do not (F069)") {
    CHECK(normalize_text("это был я. потом ушёл") == "Это был я. Потом ушёл");
    CHECK(normalize_text("it was I. then") == "It was I. Then");
    CHECK(normalize_text("и т.д. конец") == "И т.д. конец");
    CHECK(normalize_text("в XV в. было") == "В XV в. было");
    CHECK(normalize_text("«я. потом»") == "«Я. Потом»");                     // after an opening mark too
}
TEST_CASE("normalize_text: capitalizes past an opening quote, bracket or dialogue dash (F122)") {
    CHECK(normalize_text("Он ушёл. «привет, мир»") == "Он ушёл. «Привет, мир»");
    CHECK(normalize_text("(привет) мир") == "(Привет) мир");
    CHECK(normalize_text("Ну. — да") == "Ну. — Да");
}
TEST_CASE("normalize_text: no capital after a mid-sentence ellipsis (F123)") {
    CHECK(normalize_text("Ну... не знаю") == "Ну… не знаю");
    CHECK(normalize_text("Я думаю... может, завтра") == "Я думаю… может, завтра");
}
TEST_CASE("normalize_text: idempotent over the regression inputs") {
    const char *samples[] = {
        "встреча в 12:30, потом https://example.com/a?x=1",
        "Он сказал \"Привет!\" и ушёл",
        "файл .env тут. это был я. потом",
        "Он ушёл. «привет, мир»",
        "сказал:\"привет\"",
    };
    for (auto s : samples) {
        std::string once = normalize_text(s);
        CHECK(normalize_text(once) == once);
    }
}

// ── utf8_sanitize (bug-hunt F055) ──
TEST_CASE("utf8_sanitize: valid UTF-8 is unchanged") {
    CHECK(utf8_sanitize("Привет, мир — ёж 😀 ok") == "Привет, мир — ёж 😀 ok");
    CHECK(utf8_sanitize("").empty());
}
TEST_CASE("utf8_sanitize: a truncated multibyte tail becomes U+FFFD") {
    std::string s = "слово \xD0";                        // half of a Cyrillic letter at the end
    CHECK(utf8_sanitize(s) == "слово \xEF\xBF\xBD");
    CHECK(utf8_sanitize("a\xF0\x9F\x98") == "a\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD");   // 3 orphan bytes
}
TEST_CASE("utf8_sanitize: stray continuation, overlong and surrogate bytes are replaced") {
    CHECK(utf8_sanitize("x\xABy") == "x\xEF\xBF\xBDy");
    CHECK(utf8_sanitize("\xC0\xAF") == "\xEF\xBF\xBD\xEF\xBF\xBD");        // overlong '/'
    CHECK(utf8_sanitize("\xED\xA0\x80") == "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD");   // U+D800
}

