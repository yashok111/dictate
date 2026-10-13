#pragma once
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <cmath>
#include <fstream>
#include "../core/policy.h"

// Content-addressed, versioned cache. A failed read/write is always optional.
// The ASR model is deliberately absent: speaker turns are independent of it.
inline NSString* speaker_cache_key(NSString* source, NSString* segmentation,
                                    NSString* embedding, NSString* configuration) {
    if (!source || !segmentation || !embedding || !configuration) return nil;
    CC_SHA256_CTX identity;
    CC_SHA256_Init(&identity);
    for (NSString* path in @[source, segmentation, embedding]) {
        std::ifstream stream(path.fileSystemRepresentation, std::ios::binary);
        if (!stream) return nil;
        CC_SHA256_CTX file;
        CC_SHA256_Init(&file);
        char buffer[65536];
        while (stream.read(buffer, sizeof(buffer)) || stream.gcount())
            CC_SHA256_Update(&file, buffer, static_cast<CC_LONG>(stream.gcount()));
        if (!stream.eof()) return nil;
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256_Final(digest, &file);
        CC_SHA256_Update(&identity, digest, sizeof(digest));
    }
    NSData* config = [[@"speaker-cache-v1\n" stringByAppendingString:configuration] dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA256_Update(&identity, config.bytes, static_cast<CC_LONG>(config.length));
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &identity);
    NSMutableString* key = [NSMutableString stringWithCapacity:64];
    for (auto byte : digest) [key appendFormat:@"%02x", byte];
    return key;
}

inline bool valid_speaker_cache_key(NSString* key) {
    return key.length == 64 && [key rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

inline bool cache_integer(id value, int64_t minimum, int64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return false;
    const double number = [value doubleValue];
    return std::isfinite(number) && number >= minimum && number <= maximum && std::floor(number) == number;
}

inline constexpr size_t speaker_cache_max_turns = 100000;

// Keep reader and writer on the same interval contract. Simultaneous speakers
// are valid; only start times, not end times, must be ordered.
inline bool valid_speaker_cache_turns(int64_t duration, const std::vector<transcriber::Turn>& turns) {
    if (duration <= 0 || turns.size() > speaker_cache_max_turns) return false;
    int64_t previous = -1;
    for (const auto& turn : turns) {
        if (turn.start_ms < 0 || turn.start_ms < previous || turn.end_ms <= turn.start_ms ||
            turn.end_ms > duration || turn.speaker < 0) return false;
        previous = turn.start_ms;
    }
    return true;
}

inline bool load_speaker_cache(NSString* directory, NSString* key, int64_t duration,
                               std::vector<transcriber::Turn>& turns) {
    if (!directory || !valid_speaker_cache_key(key) || duration <= 0) return false;
    NSString* path = [directory stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
    NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (!attributes || [attributes[NSFileSize] unsignedLongLongValue] > 16 * 1024 * 1024) return false;
    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data) return false;
    id doc = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![doc isKindOfClass:NSDictionary.class] ||
        !cache_integer(doc[@"schemaVersion"], 1, 1) || ![doc[@"key"] isEqual:key] ||
        !cache_integer(doc[@"durationMS"], duration, duration) ||
        ![doc[@"turns"] isKindOfClass:NSArray.class] || [doc[@"turns"] count] > speaker_cache_max_turns) return false;
    std::vector<transcriber::Turn> loaded;
    for (id row in doc[@"turns"]) {
        if (![row isKindOfClass:NSDictionary.class] ||
            !cache_integer(row[@"startMS"], 0, duration - 1) ||
            !cache_integer(row[@"endMS"], 1, duration) ||
            !cache_integer(row[@"speaker"], 0, INT32_MAX)) return false;
        const int64_t start = [row[@"startMS"] longLongValue], end = [row[@"endMS"] longLongValue];
        loaded.push_back({start, end, [row[@"speaker"] intValue]});
    }
    if (!valid_speaker_cache_turns(duration, loaded)) return false;
    turns = std::move(loaded);
    return true;
}

inline bool save_speaker_cache(NSString* directory, NSString* key, int64_t duration,
                               const std::vector<transcriber::Turn>& turns) {
    if (!directory || !valid_speaker_cache_key(key) || !valid_speaker_cache_turns(duration, turns)) return false;
    NSMutableArray* rows = [NSMutableArray array];
    for (const auto& turn : turns) {
        [rows addObject:@{@"startMS": @(turn.start_ms), @"endMS": @(turn.end_ms), @"speaker": @(turn.speaker)}];
    }
    NSDictionary* doc = @{@"schemaVersion": @1, @"key": key, @"durationMS": @(duration), @"turns": rows};
    NSData* data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:nil];
    NSFileManager* manager = NSFileManager.defaultManager;
    if (!data || ![manager createDirectoryAtPath:directory withIntermediateDirectories:YES
                                    attributes:@{NSFilePosixPermissions: @0700} error:nil]) return false;
    NSString* path = [directory stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
    // Atomic replacement keeps interrupted workers and concurrent app instances
    // from publishing a partial cache. The directory is private to this user.
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return false;
    return [manager setAttributes:@{NSFilePosixPermissions: @0600} ofItemAtPath:path error:nil];
}
