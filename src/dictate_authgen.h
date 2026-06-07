#pragma once
// Tiny pure decisions extracted from the daemon's peer-auth and auto-paste paths so they
// can be unit-tested without a live socket / NSPasteboard (`make test`; gotcha #19). The
// syscalls stay in dictate.mm — getpeereid() fetches the peer uid, CGEvent synthesizes ⌘V,
// dispatch_after schedules the clipboard restore — only the equality decisions live here.
#include <cstdint>
#include <sys/types.h>   // uid_t

// Peer authentication: a connected AF_UNIX peer is authorized iff its effective uid equals
// the daemon's (same-user only — the `accept` verb injects keystrokes, so a foreign peer is
// a keystroke-injection sink). Mirrors peer_is_owner's `euid == geteuid()`.
inline bool peer_uid_ok(uid_t peer_euid, uid_t self_euid) {
    return peer_euid == self_euid;
}

// Paste generation token: a queued clipboard-restore should fire only if no newer paste has
// started since it was scheduled (each paste bumps the generation). Mirrors paste_text's
// `if (myGen == pasteGen)` guard against a stale restore clobbering a fresher paste.
inline bool paste_gen_is_current(uint64_t mine, uint64_t latest) {
    return mine == latest;
}
