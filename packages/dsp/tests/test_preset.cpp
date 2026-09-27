/**
 * @file test_preset.cpp
 * @brief Tests for preset validation and initialization
 */

#include "test_utils.h"
#include "monivol_dsp.h"

TEST(preset_init_flat) {
    monivol_preset_t preset;
    monivol_dsp_preset_init_flat(&preset);

    // Check preset is initialized
    ASSERT_EQ(preset.num_bands, MONIVOL_MAX_BANDS);
    ASSERT_EQ(preset.preamp_db, 0.0f);
    ASSERT(!preset.limiter_enabled); // Flat preset has limiter disabled for transparency

    // Check all bands are disabled and at 0dB
    for (uint32_t i = 0; i < MONIVOL_MAX_BANDS; i++) {
        ASSERT_EQ(preset.bands[i].gain_db, 0.0f);
        ASSERT_EQ(preset.bands[i].enabled, false);
    }

    PASS();
}

TEST(preset_validate_valid) {
    monivol_preset_t preset;
    monivol_dsp_preset_init_flat(&preset);

    // Valid preset should pass
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_OK);

    PASS();
}

TEST(preset_validate_invalid_frequency) {
    monivol_preset_t preset;
    monivol_dsp_preset_init_flat(&preset);

    // Invalid frequency (too low)
    preset.bands[0].frequency_hz = 10.0f; // Below 20 Hz
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    // Invalid frequency (too high)
    preset.bands[0].frequency_hz = 25000.0f; // Above 20 kHz
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    PASS();
}

TEST(preset_validate_invalid_gain) {
    monivol_preset_t preset;
    monivol_dsp_preset_init_flat(&preset);

    // Invalid gain (too negative)
    preset.bands[0].gain_db = -15.0f; // Below -12 dB
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    // Invalid gain (too positive)
    preset.bands[0].gain_db = 15.0f; // Above +12 dB
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    PASS();
}

TEST(preset_validate_invalid_q) {
    monivol_preset_t preset;
    monivol_dsp_preset_init_flat(&preset);

    // Invalid Q (too low)
    preset.bands[0].q_factor = 0.05f; // Below 0.1
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    // Invalid Q (too high)
    preset.bands[0].q_factor = 15.0f; // Above 10.0
    ASSERT_EQ(monivol_dsp_preset_validate(&preset), MONIVOL_ERROR_INVALID_PARAM);

    PASS();
}
