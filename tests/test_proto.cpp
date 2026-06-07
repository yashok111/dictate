#include "doctest.h"
#include "dictate_proto.h"

TEST_CASE("first_line takes text up to the first newline") {
    CHECK(first_line("ping\n") == "ping");
    CHECK(first_line("accept hi\nmore") == "accept hi");
    CHECK(first_line("no newline") == "no newline");
    CHECK(first_line("\nrest") == "");
    CHECK(first_line("") == "");
}
TEST_CASE("parse_command: bare verb has empty arg") {
    auto c = parse_command("ping");
    CHECK(c.cmd == "ping");
    CHECK(c.arg == "");
}
TEST_CASE("parse_command: splits verb and arg on first space") {
    auto c = parse_command("accept hello");
    CHECK(c.cmd == "accept");
    CHECK(c.arg == "hello");
}
TEST_CASE("parse_command: arg keeps subsequent spaces verbatim") {
    auto c = parse_command("accept hello world  foo");
    CHECK(c.cmd == "accept");
    CHECK(c.arg == "hello world  foo");
}
TEST_CASE("parse_command: leading space → empty verb, rest is arg") {
    auto c = parse_command(" hello");
    CHECK(c.cmd == "");
    CHECK(c.arg == "hello");
}
TEST_CASE("parse_command: empty line → empty verb and arg") {
    auto c = parse_command("");
    CHECK(c.cmd == "");
    CHECK(c.arg == "");
}
TEST_CASE("parse + first_line compose like serve_client (edit verb w/ utf8 arg)") {
    auto c = parse_command(first_line("edit привет мир\n"));
    CHECK(c.cmd == "edit");
    CHECK(c.arg == "привет мир");
}
TEST_CASE("all known verbs split correctly") {
    for (const char* v : {"start","stop","cancel","ping","quit","feedfile",
                          "corr-start","corr-stop","corr-cancel","editor-cancel","axcheck"}) {
        auto c = parse_command(v);
        CHECK(c.cmd == v);
        CHECK(c.arg == "");
    }
    auto f = parse_command("feedfile /tmp/x.wav");
    CHECK(f.cmd == "feedfile"); CHECK(f.arg == "/tmp/x.wav");
}
