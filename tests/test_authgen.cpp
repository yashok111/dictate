// Unit tests for the daemon's pure auth + paste-gen decisions (src/dictate_authgen.h).
// The syscalls (getpeereid, CGEvent ⌘V, dispatch_after) stay in dictate.mm and are
// exercised by the live socket / e2e paths; here we pin the equality decisions.
#include "doctest.h"
#include "dictate_authgen.h"

TEST_CASE("peer_uid_ok: only the same effective uid is authorized") {
    CHECK(peer_uid_ok(501, 501));          // same user → ok
    CHECK(peer_uid_ok(0, 0));              // root daemon, root peer → ok
    CHECK_FALSE(peer_uid_ok(0, 501));      // root peer connecting to a user daemon → rejected
    CHECK_FALSE(peer_uid_ok(501, 0));      // user peer to a root daemon → rejected
    CHECK_FALSE(peer_uid_ok(502, 501));    // a different user → rejected
}

TEST_CASE("paste_gen_is_current: a restore fires only for the latest generation") {
    CHECK(paste_gen_is_current(5, 5));          // no newer paste since → restore the prior clipboard
    CHECK(paste_gen_is_current(0, 0));
    CHECK_FALSE(paste_gen_is_current(5, 6));     // a newer paste bumped the gen → skip the stale restore
    CHECK_FALSE(paste_gen_is_current(4, 6));
}
