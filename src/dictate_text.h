#pragma once
// Text normalizers, extracted from dictate.mm for unit testing (gotcha #19).
// Pure std::string — no platform deps, UTF-8 (the input is whisper's UTF-8 output).
//
//   normalize_ws   — collapse whitespace runs to single spaces, trim ends.
//   normalize_text — full post-normalizer (capitalization / punctuation spacing /
//                    typography) applied to the FINAL transcript before paste/editor.
//                    Built on normalize_ws. Conservative on purpose (see notes by each
//                    pass): it must not mangle mixed RU/EN, domains, files, decimals.
#include <string>

inline std::string normalize_ws(const std::string &s) {
    std::string out; bool sp=false, started=false;
    for (char c : s) {
        if (c==' '||c=='\n'||c=='\t'||c=='\r') { if (started) sp=true; }
        else { if (sp) out+=' '; out+=c; sp=false; started=true; }
    }
    return out;
}

namespace dictate_text_detail {

inline bool is_ascii_digit(unsigned char c) { return c>='0' && c<='9'; }
// A "letter byte" for our heuristics: ASCII alpha OR any byte of a multibyte UTF-8
// codepoint (>=0x80). Deliberately permissive — it only ever feeds heuristics whose
// other guards (digit checks, codepoint-aware uppercasing) stay correct on non-letters.
inline bool is_letterish(unsigned char c) {
    return (c>='A'&&c<='Z') || (c>='a'&&c<='z') || c>=0x80;
}
// UTF-8 continuation byte (10xxxxxx) — used to count codepoints in a byte run.
inline bool is_cont(unsigned char c) { return (c & 0xC0) == 0x80; }

// Uppercase the UTF-8 codepoint starting at s[i], in place, IF it is a lowercase letter
// (ASCII a–z, Cyrillic а–я incl. ё). Anything else (already uppercase, punctuation,
// digit) is left untouched — so it is always safe to call on any byte index.
inline void upper_cp_at(std::string &s, size_t i) {
    if (i >= s.size()) return;
    unsigned char c0 = (unsigned char)s[i];
    if (c0>='a' && c0<='z') { s[i] = (char)(c0-32); return; }   // ASCII
    if (i+1 >= s.size()) return;
    unsigned char c1 = (unsigned char)s[i+1];
    if (c0==0xD1 && c1==0x91) { s[i]=(char)0xD0; s[i+1]=(char)0x81; return; }       // ё U+0451 → Ё U+0401
    if (c0==0xD0 && c1>=0xB0 && c1<=0xBF) { s[i+1]=(char)(c1-0x20); return; }       // а–п U+0430–43F → А–П
    if (c0==0xD1 && c1>=0x80 && c1<=0x8F) { s[i]=(char)0xD0; s[i+1]=(char)(c1+0x20); return; } // р–я U+0440–44F → Р–Я
    // else: already uppercase / not a handled letter → leave as-is.
}

// Length (in bytes) of a "closing" punctuation token at s[j], else 0. These never take a
// space BEFORE them; a space immediately preceding one is dropped.
inline int close_punct_len(const std::string &s, size_t j) {
    if (j >= s.size()) return 0;
    unsigned char c = (unsigned char)s[j];
    if (c==','||c=='.'||c=='!'||c=='?'||c==';'||c==':'||c==')'||c==']') return 1;
    if (c==0xC2 && j+1<s.size() && (unsigned char)s[j+1]==0xBB) return 2;           // » U+00BB
    if (c==0xE2 && j+2<s.size() && (unsigned char)s[j+1]==0x80 && (unsigned char)s[j+2]==0xA6) return 3; // … U+2026
    return 0;
}
// Length of an "opening" punctuation token at s[j] (no space AFTER it), else 0.
inline int open_punct_len(const std::string &s, size_t j) {
    if (j >= s.size()) return 0;
    unsigned char c = (unsigned char)s[j];
    if (c=='('||c=='[') return 1;
    if (c==0xC2 && j+1<s.size() && (unsigned char)s[j+1]==0xAB) return 2;           // « U+00AB
    return 0;
}

// Is the '.' at index i a sentence boundary (vs. a decimal point, a domain/file/version
// separator, or an abbreviation dot)? Used ONLY to decide capitalization of the next
// word — never to insert a space. Conservative: a period is a boundary only when it is
// already FOLLOWED BY WHITESPACE (whisper spaces real sentence breaks; "github.com",
// "file.txt", "3.14", "v2.0" are glued → never boundaries).
inline bool dot_is_boundary(const std::string &s, size_t i) {
    if (i+1 >= s.size()) return false;          // trailing dot: nothing after to capitalize
    if (s[i+1] != ' ') return false;            // glued → domain/file/version/decimal, not a sentence end
    size_t j = i+1; while (j<s.size() && s[j]==' ') j++;
    if (j >= s.size()) return false;
    unsigned char prev = i>0 ? (unsigned char)s[i-1] : 0;
    if (is_ascii_digit(prev) && is_ascii_digit((unsigned char)s[j])) return false; // "3. 14"
    // Abbreviation guard: if the token immediately before the dot is a single letter
    // (е.g. "т.", "и.", "г."), treat it as an abbreviation/initial, not a sentence end.
    if (is_letterish(prev)) {
        size_t k = i;                            // count codepoints in the letter run ending at i-1
        int cps = 0;
        while (k>0 && is_letterish((unsigned char)s[k-1])) { if (!is_cont((unsigned char)s[k-1])) cps++; k--; if (cps>=2) break; }
        if (cps < 2) return false;
    }
    return true;
}

// Pass: collapse runs of 3+ '.' into a single ellipsis "…". Shorter runs are left as-is.
inline std::string collapse_ellipsis(const std::string &a) {
    std::string out; out.reserve(a.size());
    for (size_t i=0; i<a.size();) {
        if (a[i]=='.') {
            size_t j=i; while (j<a.size() && a[j]=='.') j++;
            size_t run = j-i;
            if (run>=3) out += "\xE2\x80\xA6";   // …
            else        out.append(a, i, run);
            i=j; continue;
        }
        out += a[i++];
    }
    return out;
}

// Pass: a hyphen or en-dash flanked by single spaces becomes a spaced em-dash
// (" - " / " – " → " — "). In-word hyphens ("кто-то") have no spaces → untouched.
inline std::string fix_dashes(const std::string &a) {
    std::string out; out.reserve(a.size()+4);
    for (size_t i=0; i<a.size();) {
        bool hyphen   = (a[i]=='-');
        bool endash   = ((unsigned char)a[i]==0xE2 && i+2<a.size() && (unsigned char)a[i+1]==0x80 && (unsigned char)a[i+2]==0x93);
        int  dashlen  = hyphen ? 1 : (endash ? 3 : 0);
        bool spaced   = dashlen && i>0 && a[i-1]==' ' && i+dashlen<a.size() && a[i+dashlen]==' ';
        if (spaced) { out += "\xE2\x80\x94"; i += dashlen; continue; }   // —
        out += a[i++];
    }
    return out;
}

// Pass: drop spaces that sit before a closing punct or after an opening punct.
inline std::string trim_punct_spaces(const std::string &a) {
    std::string out; out.reserve(a.size());
    for (size_t i=0; i<a.size();) {
        if (a[i]==' ') {
            size_t j=i; while (j<a.size() && a[j]==' ') j++;            // run of spaces
            if (close_punct_len(a,j)>0) { i=j; continue; }             // space(s) before close punct → drop
            out += ' '; i=j; continue;                                  // otherwise keep one
        }
        if (int op = open_punct_len(a,i)) {                             // open punct → emit, then drop trailing spaces
            out.append(a, i, op); i += op;
            while (i<a.size() && a[i]==' ') i++;
            continue;
        }
        out += a[i++];
    }
    return out;
}

// Pass: ensure a single space AFTER clause/exclamatory punctuation when it is glued to the
// next word. Applies to , ; : ! ? and … — NOT to '.' (a glued period is almost always a
// domain/file/version/abbreviation, so we never split it). Comma keeps decimals intact.
inline std::string space_after_punct(const std::string &a) {
    std::string out; out.reserve(a.size()+8);
    for (size_t i=0; i<a.size();) {
        unsigned char c = (unsigned char)a[i];
        int plen=0;
        if (c==','||c==';'||c==':'||c=='!'||c=='?') plen=1;
        else if (c==0xE2 && i+2<a.size() && (unsigned char)a[i+1]==0x80 && (unsigned char)a[i+2]==0xA6) plen=3; // …
        if (plen) {
            out.append(a, i, plen);
            size_t k=i+plen;
            if (k<a.size() && a[k]!=' ' && close_punct_len(a,k)==0) {
                bool decimal = (c==',') && i>0 && is_ascii_digit((unsigned char)a[i-1]) && is_ascii_digit((unsigned char)a[k]);
                if (!decimal) out += ' ';
            }
            i+=plen; continue;
        }
        out += a[i++];
    }
    return out;
}

// Pass: capitalize the first letter of the string and the first letter after each
// sentence-ending punctuation (. ! ? …). Uses dot_is_boundary for the '.' case.
inline std::string capitalize(std::string a) {
    if (!a.empty() && is_letterish((unsigned char)a[0])) upper_cp_at(a, 0);
    for (size_t i=0; i<a.size();) {
        unsigned char c = (unsigned char)a[i];
        bool ender=false; size_t after=i+1;
        if (c=='!'||c=='?') ender=true;
        else if (c=='.') ender = dot_is_boundary(a, i);
        else if (c==0xE2 && i+2<a.size() && (unsigned char)a[i+1]==0x80 && (unsigned char)a[i+2]==0xA6) { ender=true; after=i+3; } // …
        if (ender) {
            size_t j=after; while (j<a.size() && a[j]==' ') j++;
            if (j<a.size()) upper_cp_at(a, j);
            i=after; continue;
        }
        i++;
    }
    return a;
}

} // namespace dictate_text_detail

inline std::string normalize_text(const std::string &s) {
    using namespace dictate_text_detail;
    std::string a = normalize_ws(s);
    if (a.empty()) return a;
    a = collapse_ellipsis(a);   // ... → …  (before punct passes treat … as one token)
    a = fix_dashes(a);          // " - " / " – " → " — "
    a = trim_punct_spaces(a);   // drop spaces before close / after open punct
    a = space_after_punct(a);   // ensure space after , ; : ! ? …
    a = capitalize(a);          // first letter + after sentence enders
    return normalize_ws(a);     // tidy any incidental double space; trim
}
