#include "FolioAudioRing.h"
#include <assert.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

struct Fixture { FolioPCMQueue *queue; uint32_t count; _Atomic int failed; };
static void *produce(void *opaque) {
    struct Fixture *f = opaque;
    for (uint32_t i = 0; i < f->count; i++) {
        float value = (float)i;
        int result;
        while ((result = folio_pcm_push(f->queue, &value, 1)) == FOLIO_PCM_OVERFLOW) {
            if (atomic_load(&f->failed)) { folio_pcm_close(f->queue); return NULL; }
            sched_yield();
        }
        if (result != FOLIO_PCM_OK) { atomic_store(&f->failed, 1); break; }
    }
    folio_pcm_close(f->queue); return NULL;
}
static void *consume(void *opaque) {
    struct Fixture *f = opaque; uint32_t next = 0;
    for (;;) {
        float value = -1; uint32_t frames = 0;
        int result = folio_pcm_pop(f->queue, &value, 1, &frames);
        if (result == FOLIO_PCM_EMPTY) {
            if (folio_pcm_is_drained(f->queue)) break;
            sched_yield(); continue;
        }
        if (result != FOLIO_PCM_OK || frames != 1 || value != (float)next) { atomic_store(&f->failed, 1); break; }
        next++;
    }
    if (next != f->count) atomic_store(&f->failed, 1);
    return NULL;
}
int main(void) {
    int checks = 0;
    assert(!folio_pcm_create(0, 4096, 8)); assert(!folio_pcm_create(9, 4096, 8));
    assert(!folio_pcm_create(1, 4097, 8)); assert(!folio_pcm_create(1, 4096, 7)); checks++;
    for (uint32_t channels = 1; channels <= 8; channels++) {
        FolioPCMQueue *q = folio_pcm_create(channels, 16, 4); assert(q);
        float source[128], output[128];
        for (size_t i = 0; i < channels * 16; i++) source[i] = (float)i / 100;
        for (int repetition = 0; repetition < 3000; repetition++) {
            assert(folio_pcm_push(q, source, 16) == FOLIO_PCM_OK);
            uint32_t frames = 0; assert(folio_pcm_pop(q, output, 128, &frames) == FOLIO_PCM_OK); assert(frames == 16);
            for (size_t i = 0; i < channels * 16; i++) assert(source[i] == output[i]);
        }
        folio_pcm_close(q); assert(folio_pcm_is_drained(q)); assert(folio_pcm_scrub_stopped(q) == FOLIO_PCM_OK);
        folio_pcm_destroy(q);
    }
    checks++;
    FolioPCMQueue *q = folio_pcm_create(1, 8, 4); assert(q);
    float one = 1;
    for (int i = 0; i < 4; i++) assert(folio_pcm_push(q, &one, 1) == FOLIO_PCM_OK);
    assert(folio_pcm_push(q, &one, 1) == FOLIO_PCM_OVERFLOW);
    assert(folio_pcm_fault(q) == FOLIO_PCM_OVERFLOW); folio_pcm_close(q); assert(folio_pcm_scrub_stopped(q) == FOLIO_PCM_OK); folio_pcm_destroy(q); checks++;
    q = folio_pcm_create(1,8,4); float invalid = NAN;
    assert(folio_pcm_push(q,&invalid,1) == FOLIO_PCM_INVALID); assert(folio_pcm_fault(q)==FOLIO_PCM_INVALID);
    folio_pcm_close(q); folio_pcm_destroy(q); checks++;
    q = folio_pcm_create(1,8,4); assert(folio_pcm_scrub_stopped(q)==FOLIO_PCM_INVALID);
    folio_pcm_mark_invalid(q); assert(folio_pcm_fault(q)==FOLIO_PCM_INVALID); assert(folio_pcm_push(q,&one,1)==FOLIO_PCM_CLOSED);
    assert(folio_pcm_scrub_stopped(q)==FOLIO_PCM_OK); folio_pcm_destroy(q); checks++;
    struct Fixture f = { .queue = folio_pcm_create(1,1,16), .count = 100000 };
    assert(f.queue); atomic_init(&f.failed,0);
    pthread_t producer, consumer;
    assert(pthread_create(&producer,NULL,produce,&f)==0); assert(pthread_create(&consumer,NULL,consume,&f)==0);
    assert(pthread_join(producer,NULL)==0); assert(pthread_join(consumer,NULL)==0);
    assert(atomic_load(&f.failed)==0); assert(folio_pcm_is_drained(f.queue));
    assert(folio_pcm_scrub_stopped(f.queue)==FOLIO_PCM_OK); folio_pcm_destroy(f.queue); checks++;
    printf("{\"status\":\"PASS\",\"checks\":%d,\"accepted_threaded_frames\":100000,\"scope\":\"synthetic PCM queue; ASan/UBSan; not microphone or speech recognition\"}\n", checks);
    return 0;
}
