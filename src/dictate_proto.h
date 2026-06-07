#pragma once
// Pure parsing for the daemon's newline-terminated socket protocol, extracted from
// serve_client so it can be unit-tested without a live socket. first_line() takes the
// command line up to the first '\n'; parse_command() splits it into verb + argument on
// the FIRST space (the arg keeps any further spaces verbatim — e.g. `accept a b c`).
#include <string>

// The command line = everything before the first '\n' (or the whole buffer if none).
inline std::string first_line(const std::string &data) {
    size_t nl = data.find('\n');
    return (nl == std::string::npos) ? data : data.substr(0, nl);
}

struct Command { std::string cmd, arg; };

// Split a single command line into verb + argument on the first space.
// No space → arg is empty. Matches serve_client's inline parse exactly.
inline Command parse_command(const std::string &line) {
    Command c; c.cmd = line; c.arg.clear();
    size_t sp = line.find(' ');
    if (sp != std::string::npos) { c.cmd = line.substr(0, sp); c.arg = line.substr(sp + 1); }
    return c;
}
