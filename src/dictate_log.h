#pragma once
// Pure helpers for local dictation text logs. This header deliberately has no
// AppKit, whisper, sockets, or filesystem writes so the risky formatting and
// retention rules stay unit-testable via make test.

#include <cctype>
#include <cstdint>
#include <iomanip>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace dlog {

struct Date {
    int year;
    int month;
    int day;
};

struct Field {
    std::string name;
    std::string value;
    bool quoted;
};

struct Event {
    std::string timestamp;
    std::string take_id;
    std::string kind;
    std::string event;
    std::vector<Field> fields;
};

inline Field text_field(std::string name, std::string value) {
    return {std::move(name), std::move(value), true};
}

inline Field integer_field(std::string name, long long value) {
    return {std::move(name), std::to_string(value), false};
}

inline Field number_field(std::string name, double value) {
    std::ostringstream os;
    os << std::setprecision(15) << value;
    return {std::move(name), os.str(), false};
}

inline bool flag_enabled(const char *value) {
    if (!value || !*value) return false;
    std::string v;
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p) {
        if (!std::isspace(*p)) v.push_back((char)std::tolower(*p));
    }
    return v == "1" || v == "true" || v == "yes" || v == "on";
}

inline std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size());
    static const char hex[] = "0123456789abcdef";
    for (unsigned char c : s) {
        switch (c) {
        case '"':  out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20) {
                out += "\\u00";
                out.push_back(hex[(c >> 4) & 0xf]);
                out.push_back(hex[c & 0xf]);
            } else {
                out.push_back((char)c);
            }
        }
    }
    return out;
}

inline void append_json_pair(std::string &out, const std::string &name,
                             const std::string &value, bool quoted) {
    out += ",\"";
    out += json_escape(name);
    out += "\":";
    if (quoted) {
        out += "\"";
        out += json_escape(value);
        out += "\"";
    } else {
        out += value;
    }
}

inline std::string serialize_event(const Event &e) {
    std::string out = "{\"schema\":1";
    append_json_pair(out, "timestamp", e.timestamp, true);
    append_json_pair(out, "take_id", e.take_id, true);
    append_json_pair(out, "kind", e.kind, true);
    append_json_pair(out, "event", e.event, true);
    for (const Field &f : e.fields) append_json_pair(out, f.name, f.value, f.quoted);
    out += "}\n";
    return out;
}

inline bool is_leap_year(int y) {
    return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

inline int days_in_month(int y, int m) {
    static const int dim[] = {0,31,28,31,30,31,30,31,31,30,31,30,31};
    if (m == 2) return is_leap_year(y) ? 29 : 28;
    return (m >= 1 && m <= 12) ? dim[m] : 0;
}

inline bool valid_date(const Date &d) {
    return d.year >= 1970 && d.month >= 1 && d.month <= 12 &&
           d.day >= 1 && d.day <= days_in_month(d.year, d.month);
}

inline bool parse_two_digits(const std::string &s, std::size_t off, int *out) {
    if (off + 2 > s.size() || !std::isdigit((unsigned char)s[off]) ||
        !std::isdigit((unsigned char)s[off + 1])) return false;
    *out = (s[off] - '0') * 10 + (s[off + 1] - '0');
    return true;
}

inline bool parse_four_digits(const std::string &s, std::size_t off, int *out) {
    if (off + 4 > s.size()) return false;
    int v = 0;
    for (std::size_t i = 0; i < 4; i++) {
        unsigned char c = (unsigned char)s[off + i];
        if (!std::isdigit(c)) return false;
        v = v * 10 + (c - '0');
    }
    *out = v;
    return true;
}

inline bool parse_daily_filename(const std::string &name, Date *out) {
    if (name.size() != 17) return false;
    if (name[4] != '-' || name[7] != '-' || name.substr(10) != ".ndjson") return false;
    Date d{};
    if (!parse_four_digits(name, 0, &d.year) ||
        !parse_two_digits(name, 5, &d.month) ||
        !parse_two_digits(name, 8, &d.day) ||
        !valid_date(d)) return false;
    if (out) *out = d;
    return true;
}

// Days since civil 1970-01-01. Howard Hinnant's civil calendar algorithm,
// kept inline here to avoid mktime/timezone/DST behavior in retention tests.
inline int days_from_civil(Date d) {
    int y = d.year - (d.month <= 2);
    const int era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned m = (unsigned)(d.month + (d.month > 2 ? -3 : 9));
    const unsigned doy = (153 * m + 2) / 5 + (unsigned)d.day - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (int)doe - 719468;
}

inline bool should_prune(const std::string &name, bool is_regular, const Date &today) {
    if (!is_regular || !valid_date(today)) return false;
    Date d{};
    if (!parse_daily_filename(name, &d)) return false;
    const int file_day = days_from_civil(d);
    const int today_day = days_from_civil(today);
    if (file_day > today_day) return false;
    return file_day < today_day - 6;
}

inline std::string hex_encode(const std::string &s) {
    static const char hex[] = "0123456789abcdef";
    std::string out;
    out.reserve(s.size() * 2);
    for (unsigned char c : s) {
        out.push_back(hex[(c >> 4) & 0xf]);
        out.push_back(hex[c & 0xf]);
    }
    return out;
}

inline int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

inline bool hex_decode(const std::string &s, std::string *out) {
    if (s.size() % 2) return false;
    std::string decoded;
    decoded.reserve(s.size() / 2);
    for (std::size_t i = 0; i < s.size(); i += 2) {
        int hi = hex_value(s[i]);
        int lo = hex_value(s[i + 1]);
        if (hi < 0 || lo < 0) return false;
        decoded.push_back((char)((hi << 4) | lo));
    }
    if (out) *out = std::move(decoded);
    return true;
}

} // namespace dlog
