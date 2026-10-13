#pragma once
#include <onnxruntime_cxx_api.h>
#include "prepared_audio.h"
#include "../core/ctc_alignment.h"

// Independent process stage: ASR is already unloaded. No model/network discovery.
inline void align_prepared(NSString* directory, const char* model) {
    NSDictionary* manifest = read_prepared(directory);
    const int64_t duration = [manifest[@"durationMS"] longLongValue];
    NSArray* original = read_prepared_words(directory,duration);
    NSData* data = prepared_read(prepared_path(directory,@"audio.f32"),921600000);
    const auto* pcm = static_cast<const float*>(data.bytes);
    Ort::Env environment(ORT_LOGGING_LEVEL_WARNING,"transcriber-alignment");
    environment.DisableTelemetryEvents();
    Ort::SessionOptions options;
    options.SetIntraOpNumThreads(4); options.SetInterOpNumThreads(1);
    options.DisableCpuMemArena(); options.DisableMemPattern();
    Ort::Session session(environment,model,options);
    auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
    NSMutableArray* output = [NSMutableArray array];
    NSUInteger aligned=0, fallback=0;
    // Indices match the pinned 39-label vocabulary. Blank=0; word delimiter=4.
    NSString* alphabet = @"ёабвгдежзийклмнопрстуфхцчшщъыьэюя";
    for (NSUInteger begin=0;begin<original.count;) {
        @autoreleasepool {
            NSUInteger end=begin+1;
            while (end<original.count && ![original[begin][@"timingUncertain"] boolValue] &&
                   ![original[end][@"timingUncertain"] boolValue] &&
                   ![original[end-1][@"text"] hasSuffix:@"."] && ![original[end-1][@"text"] hasSuffix:@"?"] &&
                   ![original[end-1][@"text"] hasSuffix:@"!"] &&
                   [original[end][@"endMS"] longLongValue]-[original[begin][@"startMS"] longLongValue]<=15000 &&
                   [original[end][@"startMS"] longLongValue]-[original[end-1][@"endMS"] longLongValue]<=1000) ++end;
            NSArray* group = [original subarrayWithRange:NSMakeRange(begin,end-begin)];
            NSMutableArray* lexical = [NSMutableArray array];
            std::vector<int> tokens;
            std::vector<std::pair<size_t,size_t>> tokenRanges;
            bool usable=![original[begin][@"timingUncertain"] boolValue];
            for (NSDictionary* word in group) {
                for (NSString* text in [word[@"text"] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
                    if (!text.length) continue;
                    if (!tokens.empty()) tokens.push_back(4);
                    const auto first=tokens.size();
                    NSString* lower=text.lowercaseString;
                    for (NSUInteger i=0;i<lower.length;++i) {
                        NSString* character=[lower substringWithRange:NSMakeRange(i,1)];
                        auto location=[alphabet rangeOfString:character].location;
                        if (location!=NSNotFound) tokens.push_back(static_cast<int>(location)+6);
                        else if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:[lower characterAtIndex:i]]) usable=false;
                    }
                    if (first==tokens.size()) usable=false;
                    tokenRanges.push_back({first,tokens.size()});
                    [lexical addObject:@{@"text":text,@"sourceStart":word[@"startMS"],@"sourceEnd":word[@"endMS"]}];
                }
            }
            int64_t start=std::max<int64_t>(0,[original[begin][@"startMS"] longLongValue]-800);
            int64_t finish=std::min<int64_t>(duration,[original[end-1][@"endMS"] longLongValue]+800);
            if (begin) start=std::max(start,([original[begin-1][@"endMS"] longLongValue]+[original[begin][@"startMS"] longLongValue])/2);
            if (end<original.count) finish=std::min(finish,([original[end-1][@"endMS"] longLongValue]+[original[end][@"startMS"] longLongValue])/2);
            usable=usable && finish>start && finish-start<=17000 && tokens.size()<=1000;
            NSMutableArray* replacement=[NSMutableArray array];
            if (usable) {
                try {
                    std::vector<float> samples(pcm+start*16,pcm+finish*16);
                    double mean=0,variance=0;
                    for (float value:samples) mean+=value;
                    mean/=samples.size();
                    for (float value:samples) variance+=(value-mean)*(value-mean);
                    variance=std::sqrt(variance/samples.size()+1e-7);
                    for (float& value:samples) value=static_cast<float>((value-mean)/variance);
                    const int64_t shape[]={1,static_cast<int64_t>(samples.size())};
                    auto input=Ort::Value::CreateTensor<float>(memory,samples.data(),samples.size(),shape,2);
                    const char* names[]={"input_values"}; const char* outputs[]={"logits"};
                    auto result=session.Run(Ort::RunOptions{nullptr},names,&input,1,outputs,1);
                    auto dims=result[0].GetTensorTypeAndShapeInfo().GetShape();
                    if (dims.size()!=3 || dims[0]!=1 || dims[1]<=0 || dims[1]>2000 || dims[2]!=39) throw std::runtime_error("Invalid alignment model output");
                    auto spans=transcriber::ctc_align(result[0].GetTensorData<float>(),static_cast<int>(dims[1]),39,tokens);
                    usable=spans.size()==tokens.size();
                    for (NSUInteger i=0;usable && i<lexical.count;++i) {
                        const auto [a,b]=tokenRanges[i];
                        double confidence=0;
                        for (auto k=a;k<b;++k) confidence+=spans[k].score;
                        confidence/=b-a;
                        const int64_t wordStart=start+spans[a].start*(finish-start)/dims[1];
                        const int64_t wordEnd=start+spans[b-1].end*(finish-start)/dims[1];
                        usable=confidence>=.15 && wordEnd>wordStart &&
                            wordStart>=[lexical[i][@"sourceStart"] longLongValue]-3000 &&
                            wordEnd<=[lexical[i][@"sourceEnd"] longLongValue]+3000;
                        [replacement addObject:@{@"text":lexical[i][@"text"],@"startMS":@(wordStart),@"endMS":@(wordEnd),@"timingUncertain":@NO}];
                    }
                } catch (const std::exception& error) {
                    fprintf(stderr,"alignment window fallback: %s\n",error.what()); usable=false;
                }
            }
            if (usable) { [output addObjectsFromArray:replacement]; aligned+=group.count; }
            else { [output addObjectsFromArray:group]; fallback+=group.count; }
            begin=end;
            printf("{\"stage\":\"aligning\",\"progress\":%.4f}\n",double(begin)/std::max<NSUInteger>(1,original.count)); fflush(stdout);
        }
    }
    int64_t previous=-1;
    for (NSDictionary* word in output) {
        const int64_t start=[word[@"startMS"] longLongValue],end=[word[@"endMS"] longLongValue];
        if (start<previous || start<0 || end<=start || end>duration) throw std::runtime_error("Alignment order invalid; original timings retained");
        previous=start;
    }
    prepared_write_json(prepared_path(directory,@"words.json"),output);
    fprintf(stderr,"alignment-ru-v1: aligned-source-records=%lu fallback-source-records=%lu\n",(unsigned long)aligned,(unsigned long)fallback);
}
