/**
 * @file version.cpp
 * @brief Version information for MoniVol DSP library
 */

#include "monivol_dsp.h"

#ifndef MONIVOL_DSP_VERSION
#define MONIVOL_DSP_VERSION "1.0.0-dev"
#endif

const char* monivol_dsp_get_version(void) {
    return MONIVOL_DSP_VERSION;
}
