#ifndef TRANSCRIBER_POLICY_H
#define TRANSCRIBER_POLICY_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t peak_bytes;
    int32_t quality_rank;
    int32_t installed;
} tr_profile;
// Borrows profiles for this call. Returns an index, or -1 when no model fits.
// Thread-safe; no exceptions cross this C boundary.
int32_t tr_select_profile(const tr_profile* profiles, size_t count,
                         uint64_t headroom, uint64_t reserve, int32_t pressure);
#ifdef __cplusplus
}
#endif
#endif
