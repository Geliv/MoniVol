#ifndef RF_REALTIME_BRIDGE_H
#define RF_REALTIME_BRIDGE_H

#include <stdbool.h>

#include "RFSharedAudio.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RFRenderMemorySlot RFRenderMemorySlot;

RFRenderMemorySlot* rf_render_memory_slot_create(void);
void rf_render_memory_slot_destroy(RFRenderMemorySlot* slot);

// Control-thread operations. Replacing or clearing the pointer waits until
// callbacks that acquired the previous mapping have finished using it.
void rf_render_memory_slot_set(RFRenderMemorySlot* slot, RFSharedAudio* memory);
bool rf_render_memory_slot_clear_if(
    RFRenderMemorySlot* slot,
    RFSharedAudio* expected_memory);

// Realtime-thread operations. Every successful acquire must be paired with a
// release before the callback returns.
RFSharedAudio* rf_render_memory_slot_acquire(RFRenderMemorySlot* slot);
void rf_render_memory_slot_release(RFRenderMemorySlot* slot);

#ifdef __cplusplus
}
#endif

#endif // RF_REALTIME_BRIDGE_H
