#include "FolioAudioRing.h"
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <math.h>
#include <stdbool.h>

typedef struct {
    uint32_t frames;
    float *samples;
} FolioPCMSlot;

struct FolioPCMQueue {
    uint32_t channels, maximum_frames, slot_count;
    size_t sample_capacity;
    float *storage;
    FolioPCMSlot *slots;
    _Atomic uint64_t write_index;
    _Atomic uint64_t read_index;
    _Atomic uint32_t writers;
    _Atomic uint32_t readers;
    _Atomic bool scrubbing;
    _Atomic int fault;
    _Atomic bool accepting;
};

static void clear_bytes(void *memory, size_t count) {
    volatile unsigned char *p = memory;
    while (count--) *p++ = 0;
}
static void latch_fault(FolioPCMQueue *q, int value) {
    int expected = FOLIO_PCM_OK;
    atomic_compare_exchange_strong_explicit(&q->fault, &expected, value, memory_order_release, memory_order_relaxed);
}
FolioPCMQueue *folio_pcm_create(uint32_t channels, uint32_t maximum_frames, uint32_t slots) {
    if (channels < 1 || channels > 8 || maximum_frames < 1 || maximum_frames > 4096 ||
        (slots != 4 && slots != 8 && slots != 16)) return NULL;
    FolioPCMQueue *q = calloc(1, sizeof(*q)); if (!q) return NULL;
    q->channels = channels; q->maximum_frames = maximum_frames; q->slot_count = slots;
    q->sample_capacity = (size_t)channels * maximum_frames * slots;
    q->storage = calloc(q->sample_capacity, sizeof(float));
    q->slots = calloc(slots, sizeof(FolioPCMSlot));
    if (!q->storage || !q->slots) { folio_pcm_destroy(q); return NULL; }
    for (uint32_t i = 0; i < slots; i++) q->slots[i].samples = q->storage + (size_t)i * channels * maximum_frames;
    atomic_init(&q->write_index, 0); atomic_init(&q->read_index, 0);
    atomic_init(&q->writers, 0); atomic_init(&q->readers, 0); atomic_init(&q->scrubbing, false);
    atomic_init(&q->fault, FOLIO_PCM_OK); atomic_init(&q->accepting, true);
    if (!atomic_is_lock_free(&q->write_index) || !atomic_is_lock_free(&q->read_index) ||
        !atomic_is_lock_free(&q->writers) || !atomic_is_lock_free(&q->readers) ||
        !atomic_is_lock_free(&q->scrubbing) || !atomic_is_lock_free(&q->accepting) || !atomic_is_lock_free(&q->fault)) {
        folio_pcm_destroy(q); return NULL;
    }
    return q;
}
void folio_pcm_destroy(FolioPCMQueue *q) {
    if (!q) return;
    /* Lifetime owner must have stopped/joined producers and consumers first. */
    if (q->storage) { clear_bytes(q->storage, q->sample_capacity * sizeof(float)); free(q->storage); }
    if (q->slots) { clear_bytes(q->slots, (size_t)q->slot_count * sizeof(FolioPCMSlot)); free(q->slots); }
    clear_bytes(q, sizeof(*q)); free(q);
}
static int push(FolioPCMQueue *q, float * const *planes, const float *contiguous, uint32_t frames) {
    if (!q) return FOLIO_PCM_INVALID;
    if (!atomic_load_explicit(&q->accepting, memory_order_acquire)) return FOLIO_PCM_CLOSED;
    uint32_t prior_writers = atomic_fetch_add_explicit(&q->writers, 1, memory_order_acq_rel);
    int result = FOLIO_PCM_OK;
    if (prior_writers != 0) { latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done; }
    if (!atomic_load_explicit(&q->accepting, memory_order_acquire)) { result = FOLIO_PCM_CLOSED; goto done; }
    if (frames == 0 || frames > q->maximum_frames || (!planes && !contiguous)) {
        latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done;
    }
    uint64_t write = atomic_load_explicit(&q->write_index, memory_order_relaxed);
    uint64_t read = atomic_load_explicit(&q->read_index, memory_order_acquire);
    if (write - read >= q->slot_count) {
        latch_fault(q, FOLIO_PCM_OVERFLOW); result = FOLIO_PCM_OVERFLOW; goto done;
    }
    for (uint32_t channel = 0; channel < q->channels; channel++) {
        const float *source = planes ? planes[channel] : contiguous + (size_t)channel * frames;
        if (!source) { latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done; }
        for (uint32_t i = 0; i < frames; i++) {
            if (!isfinite(source[i])) { latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done; }
        }
    }
    FolioPCMSlot *slot = &q->slots[write & (q->slot_count - 1)];
    for (uint32_t channel = 0; channel < q->channels; channel++) {
        const float *source = planes ? planes[channel] : contiguous + (size_t)channel * frames;
        memcpy(slot->samples + (size_t)channel * q->maximum_frames, source, (size_t)frames * sizeof(float));
    }
    slot->frames = frames;
    atomic_store_explicit(&q->write_index, write + 1, memory_order_release);
done:
    atomic_fetch_sub_explicit(&q->writers, 1, memory_order_release);
    return result;
}
int folio_pcm_push_planar(FolioPCMQueue *q, float * const *planes, uint32_t frames) { return push(q, planes, NULL, frames); }
int folio_pcm_push(FolioPCMQueue *q, const float *samples, uint32_t frames) { return push(q, NULL, samples, frames); }
int folio_pcm_pop(FolioPCMQueue *q, float *destination, size_t capacity_samples, uint32_t *frames) {
    if (!q || !destination || !frames) return FOLIO_PCM_INVALID;
    *frames = 0;
    uint32_t prior_readers = atomic_fetch_add_explicit(&q->readers, 1, memory_order_seq_cst);
    int result = FOLIO_PCM_OK;
    if (prior_readers != 0) { latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done; }
    if (atomic_load_explicit(&q->scrubbing, memory_order_seq_cst)) { result = FOLIO_PCM_CLOSED; goto done; }
    uint64_t read = atomic_load_explicit(&q->read_index, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&q->write_index, memory_order_acquire);
    if (read == write) { result = FOLIO_PCM_EMPTY; goto done; }
    FolioPCMSlot *slot = &q->slots[read & (q->slot_count - 1)];
    uint32_t count = slot->frames;
    if (count == 0 || count > q->maximum_frames) { latch_fault(q, FOLIO_PCM_INVALID); result = FOLIO_PCM_INVALID; goto done; }
    if (capacity_samples < (size_t)count * q->channels) { result = FOLIO_PCM_CAPACITY; goto done; }
    for (uint32_t channel = 0; channel < q->channels; channel++) {
        memcpy(destination + (size_t)channel * count, slot->samples + (size_t)channel * q->maximum_frames, (size_t)count * sizeof(float));
        clear_bytes(slot->samples + (size_t)channel * q->maximum_frames, (size_t)count * sizeof(float));
    }
    slot->frames = 0; *frames = count;
    atomic_store_explicit(&q->read_index, read + 1, memory_order_release);
done:
    atomic_fetch_sub_explicit(&q->readers, 1, memory_order_seq_cst);
    return result;
}
void folio_pcm_close(FolioPCMQueue *q) { atomic_store_explicit(&q->accepting, false, memory_order_release); }
void folio_pcm_mark_invalid(FolioPCMQueue *q) { latch_fault(q, FOLIO_PCM_INVALID); folio_pcm_close(q); }
int folio_pcm_is_drained(FolioPCMQueue *q) {
    return !atomic_load_explicit(&q->accepting, memory_order_acquire) &&
           atomic_load_explicit(&q->writers, memory_order_acquire) == 0 &&
           atomic_load_explicit(&q->read_index, memory_order_acquire) == atomic_load_explicit(&q->write_index, memory_order_acquire);
}
int folio_pcm_fault(FolioPCMQueue *q) { return atomic_load_explicit(&q->fault, memory_order_acquire); }
size_t folio_pcm_allocated_bytes(FolioPCMQueue *q) {
    return sizeof(*q) + q->sample_capacity * sizeof(float) + (size_t)q->slot_count * sizeof(FolioPCMSlot);
}
int folio_pcm_scrub_stopped(FolioPCMQueue *q) {
    if (atomic_load_explicit(&q->accepting, memory_order_acquire) || atomic_load_explicit(&q->writers, memory_order_acquire)) return FOLIO_PCM_INVALID;
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(&q->scrubbing, &expected, true, memory_order_seq_cst, memory_order_seq_cst)) return FOLIO_PCM_INVALID;
    if (atomic_load_explicit(&q->readers, memory_order_seq_cst) || atomic_load_explicit(&q->writers, memory_order_acquire)) {
        atomic_store_explicit(&q->scrubbing, false, memory_order_seq_cst); return FOLIO_PCM_INVALID;
    }
    clear_bytes(q->storage, q->sample_capacity * sizeof(float));
    for (uint32_t i = 0; i < q->slot_count; i++) q->slots[i].frames = 0;
    uint64_t write = atomic_load_explicit(&q->write_index, memory_order_acquire);
    atomic_store_explicit(&q->read_index, write, memory_order_release);
    atomic_store_explicit(&q->scrubbing, false, memory_order_seq_cst);
    return FOLIO_PCM_OK;
}
