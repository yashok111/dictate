#define DOCTEST_CONFIG_IMPLEMENT
#include "../../tests/doctest.h"
#include "../native/speaker_cache.h"
#include "../native/transcript_rows.h"

struct Fixture {
    NSString* root;
    NSString* source;
    NSString* segmentation;
    NSString* embedding;
    Fixture() {
        root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        source = [root stringByAppendingPathComponent:@"source"];
        segmentation = [root stringByAppendingPathComponent:@"segmentation"];
        embedding = [root stringByAppendingPathComponent:@"embedding"];
        [@"audio" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"seg" writeToFile:segmentation atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [@"emb" writeToFile:embedding atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    ~Fixture() { [[NSFileManager defaultManager] removeItemAtPath:root error:nil]; }
    NSString* key(NSString* provider = @"coreml") {
        return speaker_cache_key(source, segmentation, embedding, provider);
    }
};

TEST_CASE("speaker cache reuses turns and rejects changed source models or provider") {
    Fixture f;
    NSString* key = f.key();
    REQUIRE(key.length == 64);
    std::vector<transcriber::Turn> turns{{0, 400, 2}, {400, 1000, 7}}, loaded;
    CHECK(save_speaker_cache(f.root, key, 1000, turns));
    REQUIRE(load_speaker_cache(f.root, f.key(), 1000, loaded));
    REQUIRE(loaded.size() == 2);
    CHECK(loaded[1].speaker == 7);
    CHECK(loaded[1].start_ms == 400);
    CHECK_FALSE(load_speaker_cache(f.root, f.key(), 999, loaded));
    CHECK_FALSE(load_speaker_cache(f.root, f.key(@"cpu"), 1000, loaded));
    for (NSString* path in @[f.source, f.segmentation, f.embedding]) {
        NSData* old = [NSData dataWithContentsOfFile:path];
        [@"changed" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        CHECK_FALSE(load_speaker_cache(f.root, f.key(), 1000, loaded));
        [old writeToFile:path atomically:YES];
    }
    CHECK(load_speaker_cache(f.root, f.key(), 1000, loaded));
}

TEST_CASE("malformed speaker cache is a miss including wrong JSON types and ranges") {
    Fixture f;
    NSString* key = f.key();
    NSString* path = [f.root stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
    std::vector<transcriber::Turn> loaded;
    NSArray* invalidTurns = @[@"bad", @[@{}], @[@{@"startMS": @0, @"endMS": @1001, @"speaker": @0}],
        @[@{@"startMS": @0, @"endMS": @500, @"speaker": @(-1)}],
        @[@{@"startMS": @0, @"endMS": @500, @"speaker": @"0"}],
        @[@{@"startMS": @0, @"endMS": @500, @"speaker": @0.5}],
        @[@{@"startMS": @0, @"endMS": @500, @"speaker": @YES}]];
    for (id turns in invalidTurns) {
        NSDictionary* doc = @{@"schemaVersion": @1, @"key": key, @"durationMS": @1000, @"turns": turns};
        [[NSJSONSerialization dataWithJSONObject:doc options:0 error:nil] writeToFile:path atomically:YES];
        CHECK_FALSE(load_speaker_cache(f.root, key, 1000, loaded));
    }
    [@"{" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CHECK_FALSE(load_speaker_cache(f.root, key, 1000, loaded));
    CHECK_FALSE(save_speaker_cache(f.source, key, 1000, {{0, 500, 0}}));
    CHECK_FALSE(load_speaker_cache(f.root, @"../source", 1000, loaded));
    CHECK(save_speaker_cache(f.root, key, 1000, {}));
    CHECK(load_speaker_cache(f.root, key, 1000, loaded));
    CHECK(loaded.empty());
}

TEST_CASE("speaker cache round trips overlapping turns and exact duration boundaries") {
    Fixture f;
    const std::vector<transcriber::Turn> turns{{0, 1000, 2}, {0, 500, 7}, {500, 1000, 7}};
    REQUIRE(save_speaker_cache(f.root, f.key(), 1000, turns));
    std::vector<transcriber::Turn> loaded;
    REQUIRE(load_speaker_cache(f.root, f.key(), 1000, loaded));
    REQUIRE(loaded.size() == turns.size());
    for (size_t i = 0; i < turns.size(); ++i) {
        CHECK(loaded[i].start_ms == turns[i].start_ms);
        CHECK(loaded[i].end_ms == turns[i].end_ms);
        CHECK(loaded[i].speaker == turns[i].speaker);
    }
}

TEST_CASE("speaker cache reader and writer reject invalid turns without replacing results") {
    Fixture f;
    NSString* key = f.key();
    NSString* path = [f.root stringByAppendingPathComponent:[key stringByAppendingString:@".json"]];
    const std::vector<std::vector<transcriber::Turn>> invalid{
        {{-1, 500, 0}}, {{500, 500, 0}}, {{500, 400, 0}}, {{0, 1001, 0}},
        {{0, 500, -1}}, {{500, 1000, 0}, {0, 500, 1}}
    };
    for (const auto& turns : invalid) {
        REQUIRE(save_speaker_cache(f.root, key, 1000, {{0, 1000, 9}}));
        NSData* existing = [NSData dataWithContentsOfFile:path];
        CHECK_FALSE(save_speaker_cache(f.root, key, 1000, turns));
        CHECK([existing isEqualToData:[NSData dataWithContentsOfFile:path]]);

        NSMutableArray* rows = [NSMutableArray array];
        for (const auto& turn : turns)
            [rows addObject:@{@"startMS": @(turn.start_ms), @"endMS": @(turn.end_ms), @"speaker": @(turn.speaker)}];
        NSDictionary* doc = @{@"schemaVersion": @1, @"key": key, @"durationMS": @1000, @"turns": rows};
        REQUIRE([[NSJSONSerialization dataWithJSONObject:doc options:0 error:nil] writeToFile:path atomically:YES]);
        std::vector<transcriber::Turn> loaded{{100, 200, 9}};
        CHECK_FALSE(load_speaker_cache(f.root, key, 1000, loaded));
        REQUIRE(loaded.size() == 1);
        CHECK(loaded[0].start_ms == 100);
        CHECK(loaded[0].end_ms == 200);
        CHECK(loaded[0].speaker == 9);
    }
}

TEST_CASE("early preview does not merge away word boundaries needed for final speakers") {
    NSArray* words = @[@{@"startMS": @0, @"endMS": @400, @"text": @"Привет"},
                      @{@"startMS": @400, @"endMS": @800, @"text": @"hello"},
                      @{@"startMS": @800, @"endMS": @1200, @"text": @"мир"}];
    auto preview = transcript_rows(words, {});
    REQUIRE(preview.count == 1);
    CHECK([preview[0][@"text"] isEqual:@"Привет hello мир"]);
    CHECK([preview[0][@"speaker"] isEqual:NSNull.null]);
    auto final = transcript_rows(words, {{0, 400, 1}, {400, 1200, 2}});
    REQUIRE(final.count == 2);
    CHECK([final[0][@"text"] isEqual:@"Привет"]);
    CHECK([final[1][@"text"] isEqual:@"hello мир"]);
    CHECK([final[1][@"speaker"] intValue] == 2);
    CHECK(words.count == 3);
    CHECK([preview[0][@"text"] isEqual:@"Привет hello мир"]);
    auto overlap = transcript_rows(words, {{0, 1200, 1}, {0, 1200, 2}});
    CHECK([overlap[0][@"overlap"] boolValue]);
}

int main(int argc, char** argv) {
    @autoreleasepool { return doctest::Context(argc, argv).run(); }
}

TEST_CASE("recognized text without usable timing stays visible without a guessed speaker") {
    NSArray* words = @[@{@"startMS":@1000, @"endMS":@25000, @"text":@"Спасибо.", @"timingUncertain":@YES}];
    auto rows = transcript_rows(words, {{0, 25000, 0}});
    REQUIRE(rows.count == 1);
    CHECK([rows[0][@"text"] isEqual:@"Спасибо."]);
    CHECK([rows[0][@"speaker"] isEqual:NSNull.null]);
}

TEST_CASE("short interior unknown run recovers only with matching uncontested neighbours") {
    NSArray* words = @[
        @{@"startMS":@0, @"endMS":@1000, @"text":@"до"},
        @{@"startMS":@1100, @"endMS":@2200, @"text":@"внутри"},
        @{@"startMS":@2300, @"endMS":@3300, @"text":@"после"}];
    const std::vector<transcriber::Turn> turns{{0,1000,0},{2300,3300,0}};
    auto recovered = transcript_rows(words, turns);
    REQUIRE(recovered.count == 1);
    CHECK([recovered[0][@"speaker"] isEqual:@0]);
    CHECK([recovered[0][@"text"] isEqual:@"до внутри после"]);
    for (auto competing : std::vector<std::vector<transcriber::Turn>>{
        {{0,1000,0},{1600,1700,1},{2300,3300,0}},
        {{0,1000,0},{2300,3300,1}},
        {{0,3300,0},{1600,1700,1}}}) {
        auto rows = transcript_rows(words, competing);
        CHECK(rows.count > 1);
    }
    NSMutableArray* uncertain = [words mutableCopy];
    uncertain[1] = @{@"startMS":@1100,@"endMS":@2200,@"text":@"внутри",@"timingUncertain":@YES};
    auto untouched = transcript_rows(uncertain, turns);
    REQUIRE(untouched.count == 3);
    CHECK([untouched[1][@"speaker"] isEqual:NSNull.null]);
}

TEST_CASE("real meeting short gaps do not fragment a single known voice") {
    NSArray* words = @[
        @{@"startMS":@3880, @"endMS":@4220, @"text":@"Так, будем подбирать"},
        @{@"startMS":@4220, @"endMS":@5660, @"text":@"слова."},
        @{@"startMS":@7620, @"endMS":@8130, @"text":@"Так, нам ещё кто"},
        @{@"startMS":@8130, @"endMS":@9690, @"text":@"нужен?"},
        @{@"startMS":@13890, @"endMS":@14500, @"text":@"Халёв."},
        @{@"startMS":@15440, @"endMS":@16100, @"text":@"Халёв, мы нужен"},
        @{@"startMS":@16100, @"endMS":@17180, @"text":@"Максим."},
        @{@"startMS":@38100, @"endMS":@38290, @"text":@"экстренно"}];
    std::vector<transcriber::Turn> turns{{4601,5993,0},{6520,7063,0},{8285,9694,0},
        {10441,13260,0},{13633,14550,0},{13905,14465,1},{16027,17317,0},{38676,43039,0}};
    auto rows = transcript_rows(words, turns);
    REQUIRE(rows.count == 5);
    CHECK([rows[0][@"text"] isEqual:@"Так, будем подбирать слова."]);
    CHECK([rows[0][@"speaker"] intValue] == 0);
    CHECK([rows[1][@"text"] isEqual:@"Так, нам ещё кто нужен?"]);
    CHECK([rows[1][@"speaker"] intValue] == 0);
    CHECK([rows[2][@"speaker"] isEqual:NSNull.null]);
    CHECK([rows[2][@"overlap"] boolValue]);
    CHECK([rows[3][@"text"] isEqual:@"Халёв, мы нужен Максим."]);
    CHECK([rows[3][@"speaker"] intValue] == 0);
    CHECK([rows[4][@"speaker"] intValue] == 0);
}
