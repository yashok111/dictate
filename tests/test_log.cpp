#include "doctest.h"
#include "dictate_log.h"

TEST_CASE("log feature flag is opt-in") {
    CHECK_FALSE(dlog::flag_enabled(nullptr));
    CHECK_FALSE(dlog::flag_enabled(""));
    CHECK_FALSE(dlog::flag_enabled("0"));
    CHECK_FALSE(dlog::flag_enabled("false"));
    CHECK_FALSE(dlog::flag_enabled("off"));

    CHECK(dlog::flag_enabled("1"));
    CHECK(dlog::flag_enabled("true"));
    CHECK(dlog::flag_enabled("YES"));
    CHECK(dlog::flag_enabled(" on "));
}

TEST_CASE("json_escape handles control characters and preserves UTF-8") {
    std::string input = "quote=\" slash=\\ line=\n tab=\t ";
    input.push_back('\x01');
    input += " Привет";
    CHECK(dlog::json_escape(input)
          == "quote=\\\" slash=\\\\ line=\\n tab=\\t \\u0001 Привет");
}

TEST_CASE("serialize_event produces one deterministic NDJSON line") {
    dlog::Event e{
        "2026-06-08T12:34:56+04:00",
        "take-1",
        "main",
        "transcript",
        {
            dlog::text_field("raw_text", "hello\nworld"),
            dlog::text_field("normalized_text", "Hello\nworld"),
            dlog::number_field("duration_sec", 1.25),
            dlog::integer_field("segment_count", 2),
        },
    };
    CHECK(dlog::serialize_event(e)
          == "{\"schema\":1,\"timestamp\":\"2026-06-08T12:34:56+04:00\","
             "\"take_id\":\"take-1\",\"kind\":\"main\",\"event\":\"transcript\","
             "\"raw_text\":\"hello\\nworld\",\"normalized_text\":\"Hello\\nworld\","
             "\"duration_sec\":1.25,\"segment_count\":2}\n");
}

TEST_CASE("parse_daily_filename accepts only real calendar dates") {
    dlog::Date d{};
    CHECK(dlog::parse_daily_filename("2026-06-08.ndjson", &d));
    CHECK(d.year == 2026);
    CHECK(d.month == 6);
    CHECK(d.day == 8);

    CHECK_FALSE(dlog::parse_daily_filename("2026-6-08.ndjson", &d));
    CHECK_FALSE(dlog::parse_daily_filename("2026-06-08.json", &d));
    CHECK_FALSE(dlog::parse_daily_filename("x2026-06-08.ndjson", &d));
    CHECK_FALSE(dlog::parse_daily_filename("2026-02-30.ndjson", &d));
    CHECK(dlog::parse_daily_filename("2024-02-29.ndjson", &d));
    CHECK_FALSE(dlog::parse_daily_filename("2025-02-29.ndjson", &d));
}

TEST_CASE("retention keeps today and previous six local dates") {
    const dlog::Date today{2026, 6, 8};
    CHECK_FALSE(dlog::should_prune("2026-06-08.ndjson", true, today));
    CHECK_FALSE(dlog::should_prune("2026-06-02.ndjson", true, today));
    CHECK(dlog::should_prune("2026-06-01.ndjson", true, today));
    CHECK(dlog::should_prune("2025-12-31.ndjson", true, today));
}

TEST_CASE("retention ignores non-regular invalid and future entries") {
    const dlog::Date today{2026, 1, 3};
    CHECK_FALSE(dlog::should_prune("2025-12-27.ndjson", false, today));
    CHECK_FALSE(dlog::should_prune("notes.txt", true, today));
    CHECK_FALSE(dlog::should_prune("2026-02-30.ndjson", true, today));
    CHECK_FALSE(dlog::should_prune("2026-01-04.ndjson", true, today));
    CHECK_FALSE(dlog::should_prune("2025-12-28.ndjson", true, today));
    CHECK(dlog::should_prune("2025-12-27.ndjson", true, today));
}

TEST_CASE("hex codec round-trips arbitrary transcript bytes") {
    std::string input = "replace\tline one\nстрока два";
    input.push_back('\0');
    input += "tail";
    std::string encoded = dlog::hex_encode(input);
    CHECK(encoded == "7265706c616365096c696e65206f6e650ad181d182d180d0bed0bad0b020d0b4d0b2d0b0007461696c");

    std::string decoded;
    REQUIRE(dlog::hex_decode(encoded, &decoded));
    CHECK(decoded == input);
    CHECK_FALSE(dlog::hex_decode("0", &decoded));
    CHECK_FALSE(dlog::hex_decode("zz", &decoded));
}
