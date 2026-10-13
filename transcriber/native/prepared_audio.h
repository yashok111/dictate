#pragma once
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <cmath>
#include <fstream>
#include <stdexcept>
#include "speaker_cache.h"

inline NSString* prepared_path(NSString* directory, NSString* name) {
    return [directory stringByAppendingPathComponent:name];
}
inline NSData* prepared_read(NSString* path, uint64_t limit) {
    auto attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue] > limit)
        throw std::runtime_error("Неверный файл этапа обработки");
    NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data || data.length > limit) throw std::runtime_error("Не удалось прочитать этап обработки");
    return data;
}
inline id prepared_json(NSString* path) {
    id value = [NSJSONSerialization JSONObjectWithData:prepared_read(path, 64 * 1024 * 1024) options:0 error:nil];
    if (!value) throw std::runtime_error("Неверный JSON этапа обработки");
    return value;
}
inline void prepared_write(NSString* path, NSData* data) {
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil] ||
        ![NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil])
        throw std::runtime_error("Не удалось сохранить этап обработки");
}
inline void prepared_write_json(NSString* path, id value) {
    prepared_write(path, [NSJSONSerialization dataWithJSONObject:value options:0 error:nil]);
}
inline NSString* prepared_hash(NSString* path) {
    std::ifstream stream(path.fileSystemRepresentation, std::ios::binary);
    if (!stream) throw std::runtime_error("Не удалось прочитать источник");
    CC_SHA256_CTX state; CC_SHA256_Init(&state);
    char bytes[65536];
    while (stream.read(bytes, sizeof(bytes)) || stream.gcount())
        CC_SHA256_Update(&state, bytes, static_cast<CC_LONG>(stream.gcount()));
    if (!stream.eof()) throw std::runtime_error("Не удалось прочитать источник");
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &state);
    NSMutableString* output = [NSMutableString string];
    for (auto byte : digest) [output appendFormat:@"%02x", byte];
    return output;
}
inline bool prepared_string(id value) { return [value isKindOfClass:NSString.class] && [value length] > 0; }
inline NSDictionary* read_prepared(NSString* directory) {
    id doc = prepared_json(prepared_path(directory, @"prepared.json"));
    if (![doc isKindOfClass:NSDictionary.class] || !cache_integer(doc[@"schemaVersion"], 1, 1) ||
        !cache_integer(doc[@"sampleRate"], 16000, 16000) || !cache_integer(doc[@"sampleCount"], 0, 230400000) ||
        !cache_integer(doc[@"decodeVersion"], 1, 1) || ![doc[@"pcmFormat"] isEqual:@"f32le-mono"] ||
        ![doc[@"pcmFile"] isEqual:@"audio.f32"] || ![doc[@"wordsFile"] isEqual:@"words.json"] ||
        !prepared_string(doc[@"asrModel"]) || !prepared_string(doc[@"sourceSHA256"]) ||
        !valid_speaker_cache_key(doc[@"sourceSHA256"]))
        throw std::runtime_error("Неверный манифест этапа обработки");
    const int64_t count = [doc[@"sampleCount"] longLongValue], duration = count * 1000 / 16000;
    if (!cache_integer(doc[@"durationMS"], duration, duration)) throw std::runtime_error("Неверная длительность");
    NSData* pcm = prepared_read(prepared_path(directory, @"audio.f32"), 921600000);
    if (pcm.length != uint64_t(count) * sizeof(float)) throw std::runtime_error("Неверный размер PCM");
    const auto* samples = static_cast<const float*>(pcm.bytes);
    for (int64_t i = 0; i < count; ++i)
        if (!std::isfinite(samples[i])) throw std::runtime_error("Неверные аудиосэмплы");
    return doc;
}
inline NSArray* read_prepared_words(NSString* directory, int64_t duration) {
    id words = prepared_json(prepared_path(directory, @"words.json"));
    if (![words isKindOfClass:NSArray.class]) throw std::runtime_error("Неверные слова");
    int64_t previous = -1;
    for (id word in words) {
        if (![word isKindOfClass:NSDictionary.class] || !cache_integer(word[@"startMS"], 0, duration - 1) ||
            !cache_integer(word[@"endMS"], 1, duration) || !prepared_string(word[@"text"]))
            throw std::runtime_error("Неверные таймкоды слов");
        const auto start = [word[@"startMS"] longLongValue], end = [word[@"endMS"] longLongValue];
        if (start < previous || end <= start) throw std::runtime_error("Неверный порядок слов");
        previous = start;
    }
    return words;
}
inline NSDictionary* read_prepared_turns(NSString* directory, int64_t duration,
                                        std::vector<transcriber::Turn>& turns) {
    id doc = prepared_json(prepared_path(directory, @"turns.json"));
    if (![doc isKindOfClass:NSDictionary.class] || !cache_integer(doc[@"schemaVersion"], 1, 1) ||
        !cache_integer(doc[@"durationMS"], duration, duration) || ![doc[@"turns"] isKindOfClass:NSArray.class] ||
        [doc[@"turns"] count] > 100000 || ![doc[@"provenance"] isKindOfClass:NSDictionary.class])
        throw std::runtime_error("Неверный результат Community-1");
    NSDictionary* provenance = doc[@"provenance"];
    if (![provenance[@"engine"] isEqual:@"community-1-fluidaudio"])
        throw std::runtime_error("Неверный движок диаризации");
    for (NSString* field in @[@"sdkRevision", @"modelRevision", @"modelManifestSHA256", @"configurationSHA256", @"computeUnits"])
        if (!prepared_string(provenance[field])) throw std::runtime_error("Нет версии диаризации");
    int64_t previous = -1;
    for (id row in doc[@"turns"]) {
        if (![row isKindOfClass:NSDictionary.class] || !cache_integer(row[@"startMS"], 0, duration - 1) ||
            !cache_integer(row[@"endMS"], 1, duration) || !cache_integer(row[@"speaker"], 0, INT32_MAX))
            throw std::runtime_error("Неверные интервалы Community-1");
        transcriber::Turn turn{[row[@"startMS"] longLongValue], [row[@"endMS"] longLongValue], [row[@"speaker"] intValue]};
        if (turn.start_ms < previous || turn.end_ms <= turn.start_ms) throw std::runtime_error("Неверный порядок реплик");
        previous = turn.start_ms; turns.push_back(turn);
    }
    return provenance;
}
