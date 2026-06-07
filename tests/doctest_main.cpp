// doctest entry point. ONE translation unit defines the implementation + main();
// every other tests/*.cpp just #includes "doctest.h" and registers TEST_CASEs.
// Splitting it out keeps the (large) doctest implementation compiled exactly once.
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"
