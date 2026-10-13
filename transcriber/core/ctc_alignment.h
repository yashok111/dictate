#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace transcriber {
struct CtcSpan { int start{-1}; int end{0}; double score{0}; };
// Bounded Viterbi over blank-interleaved CTC states; blank frames never extend tokens.
inline std::vector<CtcSpan> ctc_align(const float* logits, int frames, int classes,
                                     const std::vector<int>& tokens) {
    if (!logits || frames <= 0 || frames > 2000 || classes <= 1 || classes > 256 ||
        tokens.empty() || tokens.size() > 1000 || tokens.size() > static_cast<size_t>(frames)) return {};
    for (int token : tokens) if (token <= 0 || token >= classes) return {};
    const int states = static_cast<int>(tokens.size())*2+1;
    const float negative = -std::numeric_limits<float>::infinity();
    std::vector<float> previous(states,negative), current(states), probabilities(static_cast<size_t>(frames)*classes);
    std::vector<uint8_t> back(static_cast<size_t>(frames)*states);
    for (int t=0; t<frames; ++t) {
        const auto* row = logits+static_cast<size_t>(t)*classes;
        float maximum = negative;
        for (int c=0;c<classes;++c) { if (!std::isfinite(row[c])) return {}; maximum=std::max(maximum,row[c]); }
        double sum=0; for (int c=0;c<classes;++c) sum+=std::exp(double(row[c]-maximum));
        for (int c=0;c<classes;++c) probabilities[static_cast<size_t>(t)*classes+c]=row[c]-maximum-static_cast<float>(std::log(sum));
    }
    previous[0]=0;
    for (int t=0;t<frames;++t) {
        for (int s=0;s<states;++s) {
            const int label=s%2 ? tokens[s/2] : 0;
            float best=previous[s]; uint8_t step=0;
            if (s>0 && previous[s-1]>best) {best=previous[s-1];step=1;}
            if (s>1 && s%2 && tokens[s/2]!=tokens[s/2-1] && previous[s-2]>best) {best=previous[s-2];step=2;}
            current[s]=best+probabilities[static_cast<size_t>(t)*classes+label];
            back[static_cast<size_t>(t)*states+s]=step;
        }
        previous.swap(current);
    }
    int state=previous[states-1]>previous[states-2] ? states-1 : states-2;
    if (!std::isfinite(previous[state])) return {};
    std::vector<CtcSpan> result(tokens.size()); std::vector<int> counts(tokens.size());
    for (int t=frames-1;t>=0;--t) {
        if (state%2) {
            const int index=state/2; auto& span=result[index];
            if (!counts[index]) span.end=t+1;
            span.start=t; span.score+=std::exp(probabilities[static_cast<size_t>(t)*classes+tokens[index]]); ++counts[index];
        }
        state-=back[static_cast<size_t>(t)*states+state];
    }
    for (size_t i=0;i<result.size();++i) { if (!counts[i]) return {}; result[i].score/=counts[i]; }
    return result;
}
}
