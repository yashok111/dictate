#pragma once
// Tiny RIFF/WAVE PCM16 reader (downmix → mono float). Extracted from dictate.mm so it
// can be unit-tested without AppKit/AVFoundation/whisper. Opens NON-BLOCKING then requires
// a regular file, so a FIFO/device path returns false instead of hanging in open().
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <memory>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

inline bool load_wav_pcm16(const char *path, std::vector<float> &out, uint32_t *rate) {
    // Open NON-BLOCKING so a FIFO/device path can't block in open() itself (a `feedfile` DoS —
    // O_RDONLY on a writer-less FIFO blocks forever), THEN require a regular file before reading.
    // fdopen adopts the fd, so fclose (RAII) closes it on every path.
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat fst;
    if (fstat(fd, &fst)!=0 || !S_ISREG(fst.st_mode)) { close(fd); return false; }   // reject FIFO/device/dir
    std::unique_ptr<FILE, int(*)(FILE*)> fp(fdopen(fd, "rb"), fclose);
    if (!fp) { close(fd); return false; }
    FILE *f = fp.get();   // non-owning view; fp closes it (and the fd) on every return path (RAII, R.1)
    char riff[4], wave[4]; uint32_t riffsz = 0;
    if (fread(riff,1,4,f)!=4 || fread(&riffsz,4,1,f)!=1 || fread(wave,1,4,f)!=4 ||
        memcmp(riff,"RIFF",4) || memcmp(wave,"WAVE",4)) return false;
    uint16_t channels=1, bits=16; uint32_t srate=0; bool got_fmt=false, ok=false;
    for (;;) {
        char id[4]; uint32_t csz;
        if (fread(id,1,4,f)!=4 || fread(&csz,4,1,f)!=1) break;
        if (!memcmp(id,"fmt ",4)) {
            uint8_t b[16]={0}; uint32_t n = csz<16?csz:16;
            if (fread(b,1,n,f)!=n) break;
            channels=(uint16_t)(b[2]|(b[3]<<8));
            srate=(uint32_t)(b[4]|(b[5]<<8)|(b[6]<<16)|((uint32_t)b[7]<<24));
            bits=(uint16_t)(b[14]|(b[15]<<8));
            got_fmt=true;
            if (csz>n) fseek(f,(long)(csz-n)+(csz&1),SEEK_CUR);
        } else if (!memcmp(id,"data",4)) {
            if (!got_fmt || bits!=16 || channels==0) break;
            if (csz > 256u*1024*1024) break;   // refuse an absurd data chunk (>256 MB) → no huge alloc / bad_alloc abort
            std::vector<int16_t> pcm(csz/2);
            if (fread(pcm.data(),2,pcm.size(),f)!=pcm.size()) break;
            out.clear(); out.reserve(pcm.size()/channels);
            for (size_t i=0; i+channels<=pcm.size(); i+=channels) {
                int acc=0; for (int c=0;c<channels;c++) acc+=pcm[i+c];
                out.push_back((float)acc/((float)channels*32768.0f));   // average in float (no integer truncation)
            }
            ok=true; break;
        } else fseek(f,(long)csz+(csz&1),SEEK_CUR);
    }
    if (rate) *rate=srate;
    return ok;
}
