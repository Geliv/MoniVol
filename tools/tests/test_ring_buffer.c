// test_ring_buffer.c — Unit tests for the RFSharedAudio ring buffer protocol.
//
// Pure C11, no frameworks. Compiled and run by `make test` against the
// driver-side header (packages/driver/include/RFSharedAudio.h); `make test`
// separately verifies the host-side copy is byte-identical, so testing one
// copy covers both.
//
// Coverage:
//   - write/read roundtrip in every RFAudioFormat
//   - wrap-around across the capacity boundary
//   - overrun (write more than capacity -> partial write + counter)
//   - underrun (read from empty / partial -> silence fill + counter)
//   - sizing helpers, EQ SeqLock, volume/mute accessors, heartbeats

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "RFSharedAudio.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond)                                                          \
    do {                                                                     \
        checks++;                                                            \
        if (!(cond)) {                                                       \
            failures++;                                                      \
            printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);           \
        }                                                                    \
    } while (0)

#define CHECK_NEAR(a, b, eps) CHECK(fabs((double)(a) - (double)(b)) <= (eps))

// Round-trip tolerance per format. Integer formats quantize (write truncates
// scaled by N-1, read divides by N), so allow 2 LSBs of the stored format.
static double tolerance_for(RFAudioFormat format) {
    switch (format) {
        case RF_FORMAT_FLOAT32: return 1e-6;
        case RF_FORMAT_FLOAT64: return 1e-6;
        case RF_FORMAT_INT16:   return 2.0 / 32768.0;
        case RF_FORMAT_INT24:   return 2.0 / 8388608.0;
        case RF_FORMAT_INT32:   return 2.0 / 2147483648.0;
        default:                return 1e-6;
    }
}

static RFSharedAudio* make_memory(uint32_t sample_rate, uint32_t channels,
                                  RFAudioFormat format, uint32_t duration_ms) {
    uint32_t capacity = rf_frames_for_duration(sample_rate, duration_ms);
    size_t size = rf_shared_audio_size(capacity, channels, rf_bytes_per_sample(format));
    RFSharedAudio* mem = (RFSharedAudio*)calloc(1, size);
    if (!mem) { printf("FAIL: out of memory\n"); exit(1); }
    rf_shared_audio_init(mem, sample_rate, channels, format, duration_ms);
    return mem;
}

static void free_memory(RFSharedAudio* mem) { free(mem); }

// frame value at index i is (start + i * step). Both the fill and the
// verification compute this the same way, so float rounding cancels out.
static void fill_frames(float* buf, uint32_t frames, uint32_t channels,
                        float start, float step) {
    for (uint32_t i = 0; i < frames; i++) {
        for (uint32_t ch = 0; ch < channels; ch++) {
            buf[i * channels + ch] = start + (float)i * step;
        }
    }
}

static void check_frames_equal(const float* buf, uint32_t frames, uint32_t channels,
                               float start, float step, double eps, const char* label) {
    for (uint32_t i = 0; i < frames; i++) {
        for (uint32_t ch = 0; ch < channels; ch++) {
            float expected = start + (float)i * step;
            float actual = buf[i * channels + ch];
            checks++;
            if (fabs((double)actual - (double)expected) > eps) {
                failures++;
                printf("FAIL %s: frame %u ch %u expected %f got %f\n",
                       label, i, ch, expected, actual);
                return; // one report per test is enough
            }
        }
    }
}

// ---------- sizing helpers ----------

static void test_sizing_helpers(void) {
    CHECK(rf_frames_for_duration(48000, 100) == 4800);
    CHECK(rf_frames_for_duration(44100, 20) == 882);
    CHECK(rf_frames_for_duration(192000, 20) == 3840);

    CHECK(rf_is_sample_rate_supported(48000));
    CHECK(rf_is_sample_rate_supported(192000));
    CHECK(!rf_is_sample_rate_supported(47999));
    CHECK(!rf_is_sample_rate_supported(0));

    CHECK(rf_bytes_per_sample(RF_FORMAT_FLOAT32) == 4);
    CHECK(rf_bytes_per_sample(RF_FORMAT_FLOAT64) == 8);
    CHECK(rf_bytes_per_sample(RF_FORMAT_INT16) == 2);
    CHECK(rf_bytes_per_sample(RF_FORMAT_INT24) == 3);
    CHECK(rf_bytes_per_sample(RF_FORMAT_INT32) == 4);

    size_t size = rf_shared_audio_size(4800, 2, 4);
    CHECK(size == sizeof(RFSharedAudio) + (size_t)4800 * 2 * 4);
    CHECK(size > sizeof(RFSharedAudio)); // flexible audio_data[] is present
}

// ---------- init defaults ----------

static void test_init_defaults(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    CHECK(mem->protocol_version == RF_AUDIO_PROTOCOL_VERSION);
    CHECK(mem->header_size == sizeof(RFSharedAudio));
    CHECK(mem->sample_rate == 48000);
    CHECK(mem->channels == 2);
    CHECK(mem->format == RF_FORMAT_FLOAT32);
    CHECK(mem->bytes_per_sample == 4);
    CHECK(mem->bytes_per_frame == 8);
    CHECK(mem->ring_capacity_frames == 4800);
    CHECK(mem->ring_duration_ms == 100);

    CHECK(atomic_load(&mem->write_index) == 0);
    CHECK(atomic_load(&mem->read_index) == 0);
    CHECK(atomic_load(&mem->overrun_count) == 0);
    CHECK(atomic_load(&mem->underrun_count) == 0);

    // Host creates the memory, driver starts disconnected
    CHECK(atomic_load(&mem->host_connected) == 1);
    CHECK(atomic_load(&mem->driver_connected) == 0);

    // Heartbeats start at zero -> connection not healthy yet
    CHECK(!rf_is_connection_healthy(mem));

    // Default volume 0.35, unmuted
    CHECK_NEAR(rf_load_volume_scalar(mem), 0.35f, 1e-6);
    CHECK(rf_load_mute_state(mem) == 0);

    free_memory(mem);
}

// ---------- heartbeats / connection health ----------

static void test_connection_health(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    CHECK(!rf_is_connection_healthy(mem));
    rf_update_driver_heartbeat(mem);
    CHECK(!rf_is_connection_healthy(mem)); // host heartbeat still zero
    rf_update_host_heartbeat(mem);
    CHECK(rf_is_connection_healthy(mem));

    free_memory(mem);
}

// ---------- roundtrip in every format ----------

static void test_roundtrip_format(RFAudioFormat format, uint32_t sample_rate) {
    uint32_t channels = 2;
    RFSharedAudio* mem = make_memory(sample_rate, channels, format, 100);

    const uint32_t n = 1000;
    float* in = (float*)malloc(sizeof(float) * n * channels);
    float* out = (float*)malloc(sizeof(float) * n * channels);
    if (!in || !out) { printf("FAIL: out of memory\n"); exit(1); }

    // Slope ramp inside [-0.5, 0.5): integer formats clamp to [-1, 1] on
    // write, so test data must stay in range for the roundtrip to hold.
    fill_frames(in, n, channels, -0.5f, 0.001f);

    uint32_t written = rf_ring_write(mem, in, n);
    CHECK(written == n);
    CHECK(atomic_load(&mem->overrun_count) == 0);

    uint32_t read = rf_ring_read(mem, out, n);
    CHECK(read == n);
    CHECK(atomic_load(&mem->underrun_count) == 0);

    check_frames_equal(out, n, channels, -0.5f, 0.001f, tolerance_for(format),
                       "roundtrip");

    CHECK(atomic_load(&mem->total_frames_written) == n);
    CHECK(atomic_load(&mem->total_frames_read) == n);

    free(in);
    free(out);
    free_memory(mem);
}

static void test_roundtrip_all_formats(void) {
    test_roundtrip_format(RF_FORMAT_FLOAT32, 48000);
    test_roundtrip_format(RF_FORMAT_FLOAT64, 48000);
    test_roundtrip_format(RF_FORMAT_INT16, 48000);
    test_roundtrip_format(RF_FORMAT_INT24, 48000);
    test_roundtrip_format(RF_FORMAT_INT32, 48000);
    test_roundtrip_format(RF_FORMAT_FLOAT32, 96000);
}

// ---------- wrap-around ----------

static void test_wrap_around(void) {
    // Real ring duration is 960 frames @48kHz/20ms; shrink the logical
    // capacity to 8 frames to exercise wrap-around quickly. The allocation
    // (made for the full duration) stays larger than needed, which is safe.
    uint32_t channels = 1;
    RFSharedAudio* mem = make_memory(48000, channels, RF_FORMAT_FLOAT32, 100);
    mem->ring_capacity_frames = 8;

    float in[20];
    float out[16];

    // Write 6, read 4, write 6 more -> write passes the boundary
    fill_frames(in, 6, channels, 1.0f, 1.0f);
    CHECK(rf_ring_write(mem, in, 6) == 6);

    fill_frames(in, 6, channels, 7.0f, 1.0f); // values 7..12

    // Drain 4 (values 1..4) so the next write has room to wrap
    CHECK(rf_ring_read(mem, out, 4) == 4);
    check_frames_equal(out, 4, channels, 1.0f, 1.0f, 1e-6, "wrap first read");

    CHECK(rf_ring_write(mem, in, 6) == 6); // exactly fills 8 - 2 used
    CHECK(atomic_load(&mem->overrun_count) == 0);

    CHECK(rf_ring_read(mem, out, 8) == 8);
    check_frames_equal(out, 8, channels, 5.0f, 1.0f, 1e-6, "wrap second read");

    CHECK(atomic_load(&mem->write_index) == 12);
    CHECK(atomic_load(&mem->read_index) == 12);
    CHECK(atomic_load(&mem->underrun_count) == 0);

    free_memory(mem);
}

// ---------- overrun ----------

static void test_overrun(void) {
    uint32_t channels = 1;
    RFSharedAudio* mem = make_memory(48000, channels, RF_FORMAT_FLOAT32, 100);
    mem->ring_capacity_frames = 8;

    float in[20];
    float out[8];

    // Write 20 into capacity 8: only the first 8 land, overrun counted once
    fill_frames(in, 20, channels, 1.0f, 1.0f);
    CHECK(rf_ring_write(mem, in, 20) == 8);
    CHECK(atomic_load(&mem->overrun_count) == 1);
    CHECK(atomic_load(&mem->total_frames_written) == 8);

    // The surviving frames are the first 8 of the input (values 1..8)
    CHECK(rf_ring_read(mem, out, 8) == 8);
    check_frames_equal(out, 8, channels, 1.0f, 1.0f, 1e-6, "overrun read");

    free_memory(mem);
}

// ---------- underrun ----------

static void test_underrun(void) {
    uint32_t channels = 1;
    RFSharedAudio* mem = make_memory(48000, channels, RF_FORMAT_FLOAT32, 100);
    mem->ring_capacity_frames = 8;

    float in[4];
    float out[4];

    // Read from empty ring: requested frames come back as silence
    CHECK(rf_ring_read(mem, out, 4) == 4);
    CHECK(atomic_load(&mem->underrun_count) == 1);
    for (uint32_t i = 0; i < 4; i++) {
        CHECK(out[i] == 0.0f);
    }

    // Partial underrun: 2 available, 4 requested -> data then zeros
    fill_frames(in, 2, channels, 1.0f, 1.0f);
    CHECK(rf_ring_write(mem, in, 2) == 2);
    CHECK(rf_ring_read(mem, out, 4) == 4);
    CHECK(atomic_load(&mem->underrun_count) == 2);
    CHECK(out[0] == 1.0f && out[1] == 2.0f);
    CHECK(out[2] == 0.0f && out[3] == 0.0f);
    // total_frames_read counts only frames actually consumed (0 + 2)
    CHECK(atomic_load(&mem->total_frames_read) == 2);

    free_memory(mem);
}

// ---------- degenerate inputs ----------

static void test_degenerate_inputs(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    // 4 帧双声道数据需要 8 个采样值。
    float in[8] = {0};
    float out[8] = {0};

    CHECK(rf_ring_write(mem, in, 0) == 0);

    // Note: rf_ring_write/read dereference mem before validating capacity,
    // so NULL is not a supported input and is intentionally not tested here.

    mem->ring_capacity_frames = 0; // simulate uninitialized capacity
    CHECK(rf_ring_write(mem, in, 4) == 0);
    CHECK(rf_ring_read(mem, out, 4) == 4); // still returns requested count
    mem->ring_capacity_frames = rf_frames_for_duration(48000, 100);

    // Zero-channel memory must not write
    RFSharedAudio* bad = make_memory(48000, 0, RF_FORMAT_FLOAT32, 100);
    CHECK(rf_ring_write(bad, in, 4) == 0);
    free_memory(bad);

    free_memory(mem);
}

// ---------- EQ SeqLock ----------

static void test_eq_seqlock(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    RFEQSnapshot snap;
    memset(&snap, 0, sizeof(snap));
    for (int i = 0; i < 10; i++) snap.bands[i] = (float)i * 0.5f - 6.0f;
    snap.preamp = -3.5f;
    snap.bypass = true;

    rf_store_eq_snapshot(mem, &snap);

    RFEQSnapshot out;
    CHECK(rf_load_eq_snapshot_safe(mem, &out));
    for (int i = 0; i < 10; i++) {
        CHECK_NEAR(out.bands[i], snap.bands[i], 1e-6);
    }
    CHECK_NEAR(out.preamp, -3.5f, 1e-6);
    CHECK(out.bypass == true);

    // Sequence must be back to even (idle) after a complete write
    CHECK((atomic_load(&mem->eq_sequence) & 1) == 0);

    free_memory(mem);
}

// ---------- volume / mute accessors ----------

static void test_volume_accessors(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    rf_store_volume_scalar(mem, 0.8f);
    CHECK_NEAR(rf_load_volume_scalar(mem), 0.8f, 1e-6);

    rf_store_mute_state(mem, 1);
    CHECK(rf_load_mute_state(mem) == 1);
    rf_store_mute_state(mem, 0);
    CHECK(rf_load_mute_state(mem) == 0);

    free_memory(mem);
}

// ---------- format change detection ----------

static void test_format_change(void) {
    RFSharedAudio* mem = make_memory(48000, 2, RF_FORMAT_FLOAT32, 100);

    CHECK(!rf_needs_format_change(mem, 48000, 2, RF_FORMAT_FLOAT32));
    CHECK(rf_needs_format_change(mem, 96000, 2, RF_FORMAT_FLOAT32));
    CHECK(rf_needs_format_change(mem, 48000, 1, RF_FORMAT_FLOAT32));
    CHECK(rf_needs_format_change(mem, 48000, 2, RF_FORMAT_INT16));

    free_memory(mem);
}

int main(void) {
    test_sizing_helpers();
    test_init_defaults();
    test_connection_health();
    test_roundtrip_all_formats();
    test_wrap_around();
    test_overrun();
    test_underrun();
    test_degenerate_inputs();
    test_eq_seqlock();
    test_volume_accessors();
    test_format_change();

    printf("%s: %d checks, %d failures\n",
           failures == 0 ? "PASS" : "FAIL", checks, failures);
    return failures == 0 ? 0 : 1;
}
