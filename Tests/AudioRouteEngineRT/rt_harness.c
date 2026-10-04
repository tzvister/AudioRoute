#include "AudioRT.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned allocations = 0, deallocations = 0;
static void *tracked_malloc(size_t n) { allocations++; return malloc(n); }
static void *tracked_calloc(size_t n,size_t s) { allocations++; return calloc(n,s); }
static void tracked_free(void *p) { deallocations++; free(p); }
#define malloc tracked_malloc
#define calloc tracked_calloc
#define free tracked_free
#include "../../Sources/CAudioRT/AudioRT.c"
#undef malloc
#undef calloc
#undef free

int main(void) {
    // Long-running cross-clock fan-out. Each destination is read at its own
    // rate; source production includes deterministic +/-1000 ppm clock drift
    // and jitter. ASan/UBSan guard all callback-buffer and lifetime operations.
    const double source_rate = 44100.0;
    ar_source *source = ar_source_create(2, NULL, source_rate);
    ar_sink *a = ar_sink_create(2, NULL, 48000.0, 0);
    ar_sink *b = ar_sink_create(2, NULL, 44100.0, 0.9f);
    assert(source && a && b);
    const float ma[] = {1, 0, 0, 1}, mb[] = {0, 2, 0.5, 0};
    assert(ar_sink_add_route(a, source, ma)); assert(ar_sink_add_route(b, source, mb));
    float input[2048 * 2], output_a[256 * 2], output_b[256 * 2];
    for (unsigned i = 0; i < 2048; ++i) { input[2*i] = 0.25f; input[2*i+1] = 0.75f; }
    for(unsigned packet=0;packet<8;packet++)ar_source_push(source,input,256);
    double produced_phase = 0, b_phase = 0;
    unsigned produced = 0, crossings = 0, source_position = 0;
    float last = 0;
    const unsigned initial_allocations = allocations, initial_deallocations = deallocations;
    for (unsigned block = 0; block < 12000; ++block) {
        double drift = block < 6000 ? 1.001 : 0.999;
        produced_phase += 256 * source_rate / 48000.0 * drift;
        unsigned n = (unsigned)produced_phase; produced_phase -= n;
        // Alternate a 16-frame production jitter without changing long-term rate.
        if ((block % 8) == 0) n += 16;
        if ((block % 8) == 4) n -= 16;
        for (unsigned f = 0; f < n; ++f) {
            input[2*f] = (float)(0.25 * sin(2 * 3.141592653589793 * 440 * source_position++ / source_rate));
            input[2*f+1] = 0.75f;
        }
        ar_source_push(source, input, n); produced += n;
        ar_sink_render(a, output_a, 256);
        for (unsigned f=0; f<256; ++f) { assert(isfinite(output_a[2*f])); assert(fabsf(output_a[2*f+1]-0.75f)<0.0001f); if(last<0 && output_a[2*f]>=0)crossings++;last=output_a[2*f]; }
        b_phase += 256 * 44100.0 / 48000.0; unsigned bn=(unsigned)b_phase; b_phase-=bn;
        ar_sink_render(b, output_b, bn);
        for(unsigned f=0;f<bn;f++){assert(fabsf(output_b[2*f]-0.9f)<0.0001f);assert(fabsf(output_b[2*f+1])<=0.126f);}
        assert(allocations == initial_allocations && deallocations == initial_deallocations);
    }
    ar_stats sa=ar_sink_stats(a), sb=ar_sink_stats(b), ss=ar_source_stats(source);
    assert(sa.underruns==0 && sb.underruns==0 && ss.overruns==0);
    assert(sb.clipped_samples>0); assert(sa.clipped_samples==0);
    // ~28160 440Hz cycles over 64 seconds; initial priming and clock correction
    // permit <1% error. Both destinations retain independent readers.
    assert(crossings>27900 && crossings<28400);
    printf("RT stress passed: source=%u frames, 44.1->48 kHz crossings=%u, xruns=%llu/%llu/%llu\n",produced,crossings,(unsigned long long)sa.underruns,(unsigned long long)sb.underruns,(unsigned long long)ss.overruns);
    ar_sink_destroy(a);ar_sink_destroy(b);ar_source_destroy(source);
    // Maximum channels and overflow/underflow boundaries.
    source=ar_source_create(64,NULL,48000); a=ar_sink_create(64,NULL,48000,0);
    assert(source&&a);float *matrix=calloc(64*64,sizeof(float)),*many=calloc(20000*64,sizeof(float)),*out=calloc(4096*64,sizeof(float));
    for(unsigned c=0;c<64;c++)matrix[c*64+c]=1;
    assert(ar_sink_add_route(a,source,matrix)); ar_source_push(source,many,20000);
    assert(ar_source_stats(source).overruns==1);
    for(unsigned i=0;i<8;i++)ar_sink_render(a,out,4096);
    assert(ar_sink_stats(a).underruns>0);
    ar_sink_destroy(a);ar_source_destroy(source);free(matrix);free(many);free(out);
    puts("ASan/UBSan boundary test passed");
}
