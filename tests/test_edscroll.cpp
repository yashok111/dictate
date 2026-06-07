#include "doctest.h"
#include "dictate_edscroll.h"

// Viewport [100, 500] → height 400. Line height 50. A "cursor line" is [caretY, caretY+50].
static EdScrollState st(double contentH, double caretY, double scroll, bool follow) {
    return EdScrollState{contentH, 100.0, 500.0, caretY, 50.0, scroll, follow};
}

TEST_CASE("ed_scroll_clamp: content that fits never scrolls") {
    // contentH 300 < viewport 400 → always 0, regardless of scroll / followCaret.
    CHECK(ed_scroll_clamp(st(300, 0,   0, false)) == doctest::Approx(0));
    CHECK(ed_scroll_clamp(st(300, 0, 250, false)) == doctest::Approx(0));   // a stale offset is reset
    CHECK(ed_scroll_clamp(st(400, 350, 99, true)) == doctest::Approx(0));   // exactly fills → still 0
}

TEST_CASE("ed_scroll_clamp: free scroll clamps to [0, maxScroll]") {
    // contentH 900, viewport 400 → maxScroll 500.
    CHECK(ed_scroll_clamp(st(900, 0, 200, false)) == doctest::Approx(200));   // in range → passthrough
    CHECK(ed_scroll_clamp(st(900, 0,  -5, false)) == doctest::Approx(0));     // can't scroll above the top
    CHECK(ed_scroll_clamp(st(900, 0, 999, false)) == doctest::Approx(500));   // can't scroll past the bottom
    CHECK(ed_scroll_clamp(st(900, 0, 500, false)) == doctest::Approx(500));   // exactly maxScroll
}

TEST_CASE("ed_scroll_clamp: follow reveals a cursor BELOW the viewport (scroll down)") {
    // Cursor line at absolute y=700 (top=700, bottom=750). Currently scrolled to 0 → cursor off-screen below.
    // Need scroll ≥ caretY+caretH-viewBot = 700+50-500 = 250.
    CHECK(ed_scroll_clamp(st(900, 700, 0, true)) == doctest::Approx(250));
}

TEST_CASE("ed_scroll_clamp: follow reveals a cursor ABOVE the viewport (scroll up)") {
    // Cursor line at y=120. Currently scrolled far down (450) → cursor above the viewport.
    // Need scroll ≤ caretY-viewTop = 120-100 = 20.
    CHECK(ed_scroll_clamp(st(900, 120, 450, true)) == doctest::Approx(20));
}

TEST_CASE("ed_scroll_clamp: follow leaves an already-visible cursor put") {
    // Cursor line y=300 (top=300,bottom=350); scroll=120. After shift: top=180, bottom=230 → inside [100,500].
    // reveal window is [bottom-viewBot, top-viewTop] = [350-500, 300-100] = [-150, 200]; 120 is inside → unchanged.
    CHECK(ed_scroll_clamp(st(900, 300, 120, true)) == doctest::Approx(120));
}

TEST_CASE("ed_scroll_clamp: follow result still obeys the global [0, maxScroll] clamp") {
    // Cursor at the very last line y=850 (bottom 900). reveal-lo = 900-500 = 400 = maxScroll → clamps to 400.
    CHECK(ed_scroll_clamp(st(900, 850, 0, true)) == doctest::Approx(400));
    // Cursor near the top with a negative reveal target → clamped up to 0.
    CHECK(ed_scroll_clamp(st(900, 100, 300, true)) == doctest::Approx(0));
}
