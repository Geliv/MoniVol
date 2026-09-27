/**
 * @file MoniVolDSPEngine.mm
 * @brief Objective-C++ implementation wrapping C DSP engine
 */

#import "MoniVolDSPEngine.h"
#import "monivol_dsp.h"
#import <vector>

// ============================================================================
// Error Domain
// ============================================================================

NSErrorDomain const MoniVolDSPErrorDomain = @"com.monivol.dsp";

// ============================================================================
// Helper: Convert C error to NSError
// ============================================================================

static NSError * _Nullable MoniVolErrorFromCError(monivol_error_t cError) {
    if (cError == MONIVOL_OK) {
        return nil;
    }

    MoniVolDSPError errorCode;
    NSString *description;

    switch (cError) {
        case MONIVOL_ERROR_NULL_POINTER:
            errorCode = MoniVolDSPErrorNullPointer;
            description = @"Null pointer error";
            break;
        case MONIVOL_ERROR_INVALID_PARAM:
            errorCode = MoniVolDSPErrorInvalidParameter;
            description = @"Invalid parameter";
            break;
        case MONIVOL_ERROR_OUT_OF_MEMORY:
            errorCode = MoniVolDSPErrorOutOfMemory;
            description = @"Out of memory";
            break;
        default:
            errorCode = MoniVolDSPErrorUnknown;
            description = @"Unknown error";
            break;
    }

    return [NSError errorWithDomain:MoniVolDSPErrorDomain
                               code:errorCode
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

// ============================================================================
// MoniVolBand Implementation
// ============================================================================

@implementation MoniVolBand

- (instancetype)init {
    self = [super init];
    if (self) {
        _frequencyHz = 1000.0f;
        _gainDb = 0.0f;
        _qFactor = 1.0f;
        _filterType = MoniVolFilterTypePeak;
        _enabled = NO;
    }
    return self;
}

- (instancetype)initWithFrequency:(float)frequency
                             gain:(float)gain
                          qFactor:(float)q
                       filterType:(MoniVolFilterType)type {
    self = [super init];
    if (self) {
        _frequencyHz = frequency;
        _gainDb = gain;
        _qFactor = q;
        _filterType = type;
        _enabled = YES;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    MoniVolBand *copy = [[MoniVolBand allocWithZone:zone] init];
    copy.frequencyHz = self.frequencyHz;
    copy.gainDb = self.gainDb;
    copy.qFactor = self.qFactor;
    copy.filterType = self.filterType;
    copy.enabled = self.enabled;
    return copy;
}

@end

// ============================================================================
// MoniVolPreset Implementation
// ============================================================================

@implementation MoniVolPreset

- (instancetype)init {
    self = [super init];
    if (self) {
        _name = @"Unnamed";
        _bands = @[];
        _preampDb = 0.0f;
        _limiterEnabled = NO;
        _limiterThresholdDb = -0.1f;
    }
    return self;
}

+ (instancetype)flatPreset {
    MoniVolPreset *preset = [[MoniVolPreset alloc] init];
    preset.name = @"Flat";

    // Create 10 disabled bands at standard frequencies
    NSMutableArray<MoniVolBand *> *bands = [NSMutableArray arrayWithCapacity:MONIVOL_MAX_BANDS];
    const float frequencies[] = {32.0f, 64.0f, 125.0f, 250.0f, 500.0f,
                                  1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f};

    for (int i = 0; i < MONIVOL_MAX_BANDS; i++) {
        MoniVolBand *band = [[MoniVolBand alloc] init];
        band.frequencyHz = frequencies[i];
        band.gainDb = 0.0f;
        band.qFactor = 1.0f;
        band.filterType = MoniVolFilterTypePeak;
        band.enabled = NO;
        [bands addObject:band];
    }

    preset.bands = bands;
    preset.preampDb = 0.0f;
    preset.limiterEnabled = NO;
    preset.limiterThresholdDb = -0.1f;

    return preset;
}

+ (instancetype)presetWithName:(NSString *)name bands:(NSArray<MoniVolBand *> *)bands {
    MoniVolPreset *preset = [[MoniVolPreset alloc] init];
    preset.name = name;
    preset.bands = [bands copy];
    return preset;
}

- (BOOL)isValid {
    // Check band count
    if (self.bands.count == 0 || self.bands.count > MONIVOL_MAX_BANDS) {
        return NO;
    }

    // Check preamp range
    if (self.preampDb < -12.0f || self.preampDb > 12.0f) {
        return NO;
    }

    // Check limiter threshold
    if (self.limiterThresholdDb < -6.0f || self.limiterThresholdDb > 0.0f) {
        return NO;
    }

    // Check each band
    for (MoniVolBand *band in self.bands) {
        if (band.frequencyHz < 20.0f || band.frequencyHz > 20000.0f) {
            return NO;
        }
        if (band.gainDb < -12.0f || band.gainDb > 12.0f) {
            return NO;
        }
        if (band.qFactor < 0.1f || band.qFactor > 10.0f) {
            return NO;
        }
    }

    return YES;
}

- (id)copyWithZone:(NSZone *)zone {
    MoniVolPreset *copy = [[MoniVolPreset allocWithZone:zone] init];
    copy.name = [self.name copy];
    copy.bands = [[NSArray alloc] initWithArray:self.bands copyItems:YES];
    copy.preampDb = self.preampDb;
    copy.limiterEnabled = self.limiterEnabled;
    copy.limiterThresholdDb = self.limiterThresholdDb;
    return copy;
}

@end

// ============================================================================
// MoniVolStats Implementation
// ============================================================================

@implementation MoniVolStats
@end

// ============================================================================
// MoniVolDSPEngine Implementation
// ============================================================================

@implementation MoniVolDSPEngine {
    monivol_dsp_engine_t *_engine;
    uint32_t _sampleRate;
}

- (nullable instancetype)initWithSampleRate:(uint32_t)sampleRate error:(NSError **)error {
    self = [super init];
    if (self) {
        _engine = monivol_dsp_create(sampleRate);
        if (!_engine) {
            if (error) {
                *error = [NSError errorWithDomain:MoniVolDSPErrorDomain
                                             code:MoniVolDSPErrorInvalidParameter
                                         userInfo:@{NSLocalizedDescriptionKey: @"Invalid sample rate or out of memory"}];
            }
            return nil;
        }
        _sampleRate = sampleRate;
    }
    return self;
}

- (void)dealloc {
    if (_engine) {
        monivol_dsp_destroy(_engine);
        _engine = nullptr;
    }
}

- (uint32_t)sampleRate {
    return _sampleRate;
}

- (BOOL)setSampleRate:(uint32_t)sampleRate error:(NSError **)error {
    monivol_error_t cError = monivol_dsp_set_sample_rate(_engine, sampleRate);
    if (cError != MONIVOL_OK) {
        if (error) {
            *error = MoniVolErrorFromCError(cError);
        }
        return NO;
    }
    _sampleRate = sampleRate;
    return YES;
}

- (BOOL)applyPreset:(MoniVolPreset *)preset error:(NSError **)error {
    // Convert ObjC preset to C preset
    monivol_preset_t cPreset;
    memset(&cPreset, 0, sizeof(cPreset));

    // Copy basic fields
    cPreset.num_bands = (uint32_t)MIN(preset.bands.count, MONIVOL_MAX_BANDS);
    cPreset.preamp_db = preset.preampDb;
    cPreset.limiter_enabled = preset.limiterEnabled;
    cPreset.limiter_threshold_db = preset.limiterThresholdDb;
    const char *nameStr = preset.name.UTF8String ? preset.name.UTF8String : "Unnamed";
    strncpy(cPreset.name, nameStr, sizeof(cPreset.name) - 1);

    // Copy bands
    for (NSUInteger i = 0; i < cPreset.num_bands; i++) {
        MoniVolBand *band = preset.bands[i];
        cPreset.bands[i].frequency_hz = band.frequencyHz;
        cPreset.bands[i].gain_db = band.gainDb;
        cPreset.bands[i].q_factor = band.qFactor;
        cPreset.bands[i].type = (monivol_filter_type_t)band.filterType;
        cPreset.bands[i].enabled = band.enabled;
    }

    // Apply to engine
    monivol_error_t cError = monivol_dsp_apply_preset(_engine, &cPreset);
    if (cError != MONIVOL_OK) {
        if (error) {
            *error = MoniVolErrorFromCError(cError);
        }
        return NO;
    }

    return YES;
}

- (MoniVolPreset *)currentPreset {
    monivol_preset_t cPreset;
    monivol_dsp_get_preset(_engine, &cPreset);

    // Convert C preset to ObjC
    MoniVolPreset *preset = [[MoniVolPreset alloc] init];
    preset.name = [NSString stringWithUTF8String:cPreset.name];
    preset.preampDb = cPreset.preamp_db;
    preset.limiterEnabled = cPreset.limiter_enabled;
    preset.limiterThresholdDb = cPreset.limiter_threshold_db;

    // Convert bands
    NSMutableArray<MoniVolBand *> *bands = [NSMutableArray arrayWithCapacity:cPreset.num_bands];
    for (uint32_t i = 0; i < cPreset.num_bands; i++) {
        MoniVolBand *band = [[MoniVolBand alloc] init];
        band.frequencyHz = cPreset.bands[i].frequency_hz;
        band.gainDb = cPreset.bands[i].gain_db;
        band.qFactor = cPreset.bands[i].q_factor;
        band.filterType = (MoniVolFilterType)cPreset.bands[i].type;
        band.enabled = cPreset.bands[i].enabled;
        [bands addObject:band];
    }
    preset.bands = bands;

    return preset;
}

- (void)processInterleaved:(const float *)inputBuffer
                    output:(float *)outputBuffer
                frameCount:(uint32_t)frameCount {
    monivol_dsp_process_interleaved(_engine, inputBuffer, outputBuffer, frameCount);
}

- (void)processPlanarLeft:(const float *)inputLeft
                    right:(const float *)inputRight
               outputLeft:(float *)outputLeft
              outputRight:(float *)outputRight
               frameCount:(uint32_t)frameCount {
    monivol_dsp_process_planar(_engine, inputLeft, inputRight,
                                  outputLeft, outputRight, frameCount);
}

- (void)updateBandGain:(NSUInteger)bandIndex gainDb:(float)gainDb {
    monivol_dsp_update_band_gain(_engine, (uint32_t)bandIndex, gainDb);
}

- (void)updatePreampGain:(float)gainDb {
    monivol_dsp_update_preamp(_engine, gainDb);
}

- (BOOL)bypass {
    return monivol_dsp_get_bypass(_engine);
}

- (void)setBypass:(BOOL)bypass {
    monivol_dsp_set_bypass(_engine, bypass);
}

- (void)reset {
    monivol_dsp_reset(_engine);
}

- (MoniVolStats *)statistics {
    monivol_stats_t cStats;
    monivol_dsp_get_stats(_engine, &cStats);

    MoniVolStats *stats = [[MoniVolStats alloc] init];
    [stats setValue:@(cStats.frames_processed) forKey:@"framesProcessed"];
    [stats setValue:@(cStats.underrun_count) forKey:@"underrunCount"];
    [stats setValue:@(cStats.cpu_load_percent) forKey:@"cpuLoadPercent"];
    [stats setValue:@(cStats.bypass_active) forKey:@"bypassActive"];
    [stats setValue:@(cStats.sample_rate) forKey:@"sampleRate"];

    return stats;
}

@end
