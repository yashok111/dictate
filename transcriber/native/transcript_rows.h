#pragma once
#import <Foundation/Foundation.h>
#include "../core/policy.h"

// Attribute original words before grouping. Preview grouping must never mutate
// or replace these timestamps, otherwise later speaker changes would be lost.
inline NSMutableArray* transcript_rows(NSArray* words, const std::vector<transcriber::Turn>& turns) {
    NSMutableArray* rows = [NSMutableArray array];
    std::vector<transcriber::Attribution> assigned;
    for (NSDictionary* word in words) {
        assigned.push_back([word[@"timingUncertain"] boolValue] ? transcriber::Attribution{} :
            transcriber::attribute_word([word[@"startMS"] longLongValue], [word[@"endMS"] longLongValue], turns));
    }
    const auto original = assigned;
    for (size_t begin = 0; begin < original.size();) {
        if (original[begin].speaker >= 0) { ++begin; continue; }
        size_t end = begin;
        while (end < original.size() && original[end].speaker < 0) ++end;
        if (begin > 0 && end < original.size() && original[begin-1].speaker == original[end].speaker) {
            const int64_t start = [words[begin][@"startMS"] longLongValue];
            const int64_t finish = [words[end-1][@"endMS"] longLongValue];
            const int64_t left = [words[begin-1][@"endMS"] longLongValue];
            const int64_t right = [words[end][@"startMS"] longLongValue];
            const auto speaker = original[end].speaker;
            bool safe = finish > start && finish-start <= 1200 && start >= left && start-left <= 250 &&
                right >= finish && right-finish <= 250 && !original[begin-1].overlap && !original[end].overlap;
            for (size_t i = begin; i < end; ++i)
                if (original[i].overlap || [words[i][@"timingUncertain"] boolValue]) safe = false;
            for (const auto& turn : turns)
                if (turn.speaker != speaker && turn.start_ms < right && turn.end_ms > left) safe = false;
            // Require directly covered anchors; recovered/proximity-only words are not evidence.
            if (safe) safe = transcriber::attribute([words[begin-1][@"startMS"] longLongValue],left,turns).speaker == speaker &&
                             transcriber::attribute(right,[words[end][@"endMS"] longLongValue],turns).speaker == speaker;
            if (safe) for (size_t i = begin; i < end; ++i) assigned[i] = {speaker,false};
        }
        begin = end;
    }
    size_t index = 0;
    for (NSDictionary* word in words) {
        const int64_t start = [word[@"startMS"] longLongValue], end = [word[@"endMS"] longLongValue];
        const auto who = assigned[index++];
        id speaker = who.speaker >= 0 ? static_cast<id>(@(who.speaker)) : static_cast<id>(NSNull.null);
        NSMutableDictionary* last = rows.lastObject;
        if (last && [last[@"speaker"] isEqual:speaker] && [last[@"overlap"] boolValue] == who.overlap &&
            start - [last[@"endMS"] longLongValue] < 1000 && end - [last[@"startMS"] longLongValue] < 20000) {
            last[@"text"] = [last[@"text"] stringByAppendingFormat:@" %@", word[@"text"]];
            last[@"endMS"] = @(std::max(end, [last[@"endMS"] longLongValue]));
        } else {
            [rows addObject:[@{@"id": NSUUID.UUID.UUIDString, @"startMS": @(start), @"endMS": @(end),
                @"speaker": speaker, @"overlap": @(who.overlap), @"text": word[@"text"]} mutableCopy]];
        }
    }
    return rows;
}
