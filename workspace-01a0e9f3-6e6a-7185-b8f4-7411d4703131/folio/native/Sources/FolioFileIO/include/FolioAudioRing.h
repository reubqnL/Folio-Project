#ifndef FOLIO_AUDIO_RING_H
#define FOLIO_AUDIO_RING_H
#include <stddef.h>
#include <stdint.h>

#if defined(__clang__)
#define FOLIO_NONNULL _Nonnull
#define FOLIO_NULLABLE _Nullable
#else
#define FOLIO_NONNULL
#define FOLIO_NULLABLE
#endif

typedef struct FolioPCMQueue FolioPCMQueue;
enum FolioPCMResult { FOLIO_PCM_OK=0, FOLIO_PCM_EMPTY=1, FOLIO_PCM_CLOSED=2, FOLIO_PCM_OVERFLOW=3, FOLIO_PCM_INVALID=4, FOLIO_PCM_CAPACITY=5 };

/* Single producer, single consumer only. Allocation happens at creation, not
   in push/pop. Float32 PCM; one fixed channel count for the entire capture. */
FolioPCMQueue * FOLIO_NULLABLE folio_pcm_create(uint32_t channels, uint32_t maximum_frames, uint32_t slots);
void folio_pcm_destroy(FolioPCMQueue * FOLIO_NULLABLE queue);
int folio_pcm_push_planar(FolioPCMQueue * FOLIO_NONNULL queue,
                          float * FOLIO_NONNULL const * FOLIO_NONNULL planes,
                          uint32_t frames);
/* Contiguous planar data, each channel occupying `frames` samples. */
int folio_pcm_push(FolioPCMQueue * FOLIO_NONNULL queue, const float * FOLIO_NONNULL samples, uint32_t frames);
int folio_pcm_pop(FolioPCMQueue * FOLIO_NONNULL queue, float * FOLIO_NONNULL destination,
                 size_t capacity_samples, uint32_t * FOLIO_NONNULL frames);
void folio_pcm_close(FolioPCMQueue * FOLIO_NONNULL queue);
void folio_pcm_mark_invalid(FolioPCMQueue * FOLIO_NONNULL queue);
int folio_pcm_is_drained(FolioPCMQueue * FOLIO_NONNULL queue);
int folio_pcm_fault(FolioPCMQueue * FOLIO_NONNULL queue);
size_t folio_pcm_allocated_bytes(FolioPCMQueue * FOLIO_NONNULL queue);
/* Call only after the producer callback and consumer have both stopped. */
int folio_pcm_scrub_stopped(FolioPCMQueue * FOLIO_NONNULL queue);
#endif
