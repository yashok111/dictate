#pragma once
// Editor vertical-scroll clamp — the pure arithmetic behind EditorView's scrolling, extracted
// from dictate.mm so it is unit-testable without AppKit (gotcha #19). All values are points in
// the editor's FLIPPED coordinates (y grows downward from the top of the view).
//
// The word body occupies the viewport [viewTop, viewBot] — between the header and the footer
// legend. A transcript taller than the viewport scrolls by `scroll` points (the content shifts UP
// by `scroll`, so larger `scroll` reveals lower lines). On a cursor/content change the caller sets
// followCaret=true to scroll MINIMALLY so the cursor line [caretY, caretY+caretH] is revealed; a
// free wheel-scroll sets followCaret=false (only the [0, maxScroll] clamp applies, so a manual
// scroll away from the cursor is not yanked back).

struct EdScrollState {
    double contentH;    // total laid-out text height (lineCount * lineH)
    double viewTop;     // body viewport top    (ED_HDR_TOP)
    double viewBot;     // body viewport bottom (viewHeight - ED_FTR_H)
    double caretY;      // cursor line's top edge   (only used when followCaret)
    double caretH;      // cursor line height        (only used when followCaret)
    double scroll;      // current scroll offset (the value to clamp / the wheel-adjusted target)
    bool   followCaret; // reveal the cursor line this call
};

// Returns the new scroll offset, always within [0, max(0, contentH - viewportHeight)].
inline double ed_scroll_clamp(const EdScrollState &s) {
    double vpH = s.viewBot - s.viewTop;
    double maxScroll = s.contentH - vpH;
    if (maxScroll <= 0) return 0.0;                    // content fits the viewport → never scroll
    double y = s.scroll;
    if (s.followCaret) {
        double lo = s.caretY + s.caretH - s.viewBot;   // y ≥ lo reveals the cursor line's BOTTOM edge
        double hi = s.caretY - s.viewTop;              // y ≤ hi reveals the cursor line's TOP edge
        if (y < lo) y = lo;                            // cursor below the viewport → scroll down to it
        if (y > hi) y = hi;                            // cursor above the viewport → scroll up to it
    }
    if (y < 0) y = 0;
    if (y > maxScroll) y = maxScroll;
    return y;
}
