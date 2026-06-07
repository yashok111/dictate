// Smoke test: proves the doctest harness compiles, links, and runs under the host
// compiler (g++ on Linux, clang++ on macOS). Real coverage lives in the test_*.cpp
// units that #include the extracted src/dictate_*.h headers.
#include "doctest.h"

TEST_CASE("doctest harness is alive") {
    CHECK(1 + 1 == 2);
    CHECK_FALSE(false);
}
