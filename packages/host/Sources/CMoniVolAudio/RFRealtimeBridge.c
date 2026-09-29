#include "RFRealtimeBridge.h"

#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

struct RFRenderMemorySlot {
    _Atomic(RFSharedAudio*) memory;
    _Atomic uint32_t readers;
    pthread_mutex_t control_lock;
};

static void rf_render_memory_slot_wait_for_readers(RFRenderMemorySlot* slot) {
    while (atomic_load_explicit(&slot->readers, memory_order_acquire) != 0) {
        sched_yield();
    }
}

RFRenderMemorySlot* rf_render_memory_slot_create(void) {
    RFRenderMemorySlot* slot = calloc(1, sizeof(RFRenderMemorySlot));
    if (slot == NULL) {
        return NULL;
    }

    atomic_init(&slot->memory, NULL);
    atomic_init(&slot->readers, 0);
    if (pthread_mutex_init(&slot->control_lock, NULL) != 0) {
        free(slot);
        return NULL;
    }
    return slot;
}

void rf_render_memory_slot_destroy(RFRenderMemorySlot* slot) {
    if (slot == NULL) {
        return;
    }

    pthread_mutex_lock(&slot->control_lock);
    atomic_store_explicit(&slot->memory, NULL, memory_order_release);
    rf_render_memory_slot_wait_for_readers(slot);
    pthread_mutex_unlock(&slot->control_lock);
    pthread_mutex_destroy(&slot->control_lock);
    free(slot);
}

void rf_render_memory_slot_set(RFRenderMemorySlot* slot, RFSharedAudio* memory) {
    if (slot == NULL) {
        return;
    }

    pthread_mutex_lock(&slot->control_lock);
    atomic_store_explicit(&slot->memory, NULL, memory_order_release);
    rf_render_memory_slot_wait_for_readers(slot);
    atomic_store_explicit(&slot->memory, memory, memory_order_release);
    pthread_mutex_unlock(&slot->control_lock);
}

bool rf_render_memory_slot_clear_if(
    RFRenderMemorySlot* slot,
    RFSharedAudio* expected_memory)
{
    if (slot == NULL || expected_memory == NULL) {
        return false;
    }

    pthread_mutex_lock(&slot->control_lock);
    RFSharedAudio* expected = expected_memory;
    if (!atomic_compare_exchange_strong_explicit(
            &slot->memory,
            &expected,
            NULL,
            memory_order_acq_rel,
            memory_order_acquire)) {
        pthread_mutex_unlock(&slot->control_lock);
        return false;
    }

    rf_render_memory_slot_wait_for_readers(slot);
    pthread_mutex_unlock(&slot->control_lock);
    return true;
}

RFSharedAudio* rf_render_memory_slot_acquire(RFRenderMemorySlot* slot) {
    if (slot == NULL) {
        return NULL;
    }

    atomic_fetch_add_explicit(&slot->readers, 1, memory_order_acquire);
    RFSharedAudio* memory = atomic_load_explicit(&slot->memory, memory_order_acquire);
    if (memory == NULL) {
        atomic_fetch_sub_explicit(&slot->readers, 1, memory_order_release);
    }
    return memory;
}

void rf_render_memory_slot_release(RFRenderMemorySlot* slot) {
    if (slot == NULL) {
        return;
    }
    atomic_fetch_sub_explicit(&slot->readers, 1, memory_order_release);
}
