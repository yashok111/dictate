#include "include/transcriber_policy.h"
#include "policy.h"
#include <limits>

int32_t tr_select_profile(const tr_profile* profiles, size_t count,
                         uint64_t headroom, uint64_t reserve, int32_t pressure) {
    if (!profiles || count > 64) return -1;
    try {
        std::vector<transcriber::Profile> items;
        for (size_t i = 0; i < count; ++i)
            items.push_back({std::to_string(i), profiles[i].peak_bytes, profiles[i].quality_rank,
                             profiles[i].installed != 0});
        const auto selected = transcriber::select_profile(items, headroom, reserve, pressure != 0);
        for (size_t i = 0; i < count; ++i) if (selected == items[i].id) return static_cast<int32_t>(i);
        return -1;
    } catch (...) { return -1; }
}
