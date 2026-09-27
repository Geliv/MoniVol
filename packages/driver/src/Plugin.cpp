// MoniVol HAL driver implementation.

#include <aspl/Driver.hpp>
#include <aspl/VolumeControl.hpp>
#include <aspl/MuteControl.hpp>
#include "VolumeCurve.hpp"
#include <CoreAudio/AudioServerPlugIn.h>

#include "../include/RFSharedAudio.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <memory>
#include <atomic>
#include <thread>
#include <chrono>
#include <os/log.h>
#include <map>
#include <string>
#include <fstream>
#include <sstream>
#include <vector>
#include <set>
#include <sys/stat.h>
#include <errno.h>
#include <mutex>
#include <algorithm>
#include <cstdarg>
#include <mach/mach_time.h>
#include <notify.h>

// Logging
static os_log_t rf_log = os_log_create("com.monivol.driver", "default");

#define RF_LOG_ERROR(fmt, ...) os_log_error(rf_log, "[MoniVol ERROR] " fmt, ##__VA_ARGS__)
#define RF_LOG_INFO(fmt, ...) os_log_info(rf_log, "[MoniVol INFO] " fmt, ##__VA_ARGS__)
#define RF_LOG_DEBUG(fmt, ...) os_log_debug(rf_log, "[MoniVol DEBUG] " fmt, ##__VA_ARGS__)

// Fallback file logger for debugging when unified logs are unavailable.
static void RF_DebugLog(const char* fmt, ...) {
    static std::mutex log_mutex;
    std::lock_guard<std::mutex> lock(log_mutex);
    FILE* f = fopen("/tmp/monivol-driver-debug.log", "a");
    if (!f) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(f, fmt, args);
    fprintf(f, "\n");
    va_end(args);
    fclose(f);
}

namespace {

// Configuration
constexpr UInt32 DEFAULT_SAMPLE_RATE = 48000;
constexpr UInt32 DEFAULT_CHANNELS = 2;
constexpr UInt32 DEFAULT_RING_DURATION_MS = RF_RING_DURATION_MS_DEFAULT;
// CoreAudio AudioServerPlugIn.h documents a minimum allowed zero timestamp period
// of 10923 frames. Use a conservative ring-sized period common to virtual drivers.
constexpr UInt32 HAL_ZERO_TIMESTAMP_PERIOD_FRAMES = 16384;
constexpr UInt32 HAL_SAFETY_OFFSET_FRAMES = 128;
constexpr UInt32 HAL_PRESENTATION_LATENCY_FRAMES = 512;
static_assert(HAL_ZERO_TIMESTAMP_PERIOD_FRAMES >= 10923,
    "ZeroTimeStampPeriod must satisfy CoreAudio minimum (10923 frames)");
constexpr int ADAPTIVE_FILL_TARGET_DIVISOR = 2;     // Keep ring near 50% full
constexpr int ADAPTIVE_FILL_DEADBAND_PERCENT = 20;  // Ignore fill variance within ±20%
constexpr double ADAPTIVE_MAX_ADJUST_PPM = 1500.0;  // +/-0.15% drift correction

// Health and heartbeat timing constants.
constexpr int HEALTH_CHECK_INTERVAL_SEC = 3;
constexpr int HEARTBEAT_INTERVAL_SEC = 1;
constexpr int STATS_LOG_INTERVAL_SEC = 30;
constexpr int HEARTBEAT_TIMEOUT_SEC = 15;

// Device states
enum class DeviceState {
    Uninitialized,
    Connecting,
    Connected,
    Negotiating,    // Format negotiation in progress
    Error,
    Disconnected
};

const char* StateToString(DeviceState state) {
    switch (state) {
        case DeviceState::Uninitialized: return "Uninitialized";
        case DeviceState::Connecting: return "Connecting";
        case DeviceState::Connected: return "Connected";
        case DeviceState::Negotiating: return "Negotiating";
        case DeviceState::Error: return "Error";
        case DeviceState::Disconnected: return "Disconnected";
        default: return "Unknown";
    }
}

// Sample rate conversion (simple linear interpolation)
class SimpleResampler {
public:
    SimpleResampler(double from_rate, double to_rate, uint32_t channels)
        : from_rate_(from_rate), to_rate_(to_rate), channels_(channels), ratio_(1.0), position_(0.0)
    {
        SetRates(from_rate, to_rate);
        RF_LOG_INFO("Resampler: %.2f -> %.2f Hz (ratio: %.8f)", from_rate_, to_rate_, ratio_);
    }

    void SetRates(double from_rate, double to_rate)
    {
        if (from_rate <= 0.0) from_rate = 48000.0;
        if (to_rate <= 0.0) to_rate = from_rate;
        from_rate_ = from_rate;
        to_rate_ = to_rate;
        ratio_ = from_rate_ / to_rate_;
    }

    void SetChannels(uint32_t channels)
    {
        channels_ = std::max<uint32_t>(1, channels);
    }

    // Resample input to output
    // Returns number of output frames produced
    uint32_t Process(const float* input, uint32_t input_frames,
                     float* output, uint32_t output_capacity)
    {
        uint32_t output_frames = 0;

        while (output_frames < output_capacity && position_ < input_frames) {
            uint32_t idx0 = (uint32_t)position_;
            uint32_t idx1 = std::min(idx0 + 1, input_frames - 1);
            float frac = position_ - idx0;

            for (uint32_t ch = 0; ch < channels_; ch++) {
                float s0 = input[idx0 * channels_ + ch];
                float s1 = input[idx1 * channels_ + ch];
                output[output_frames * channels_ + ch] = s0 + frac * (s1 - s0);
            }

            output_frames++;
            position_ += ratio_;
        }

        position_ -= input_frames;
        if (position_ < 0.0) {
            position_ = 0.0;
        }
        return output_frames;
    }

    void Reset() { position_ = 0.0; }

private:
    double from_rate_;
    double to_rate_;
    uint32_t channels_;
    double ratio_;
    double position_;
};

// Runtime statistics.
struct AudioStats {
    std::atomic<uint64_t> total_writes{0};
    std::atomic<uint64_t> failed_writes{0};
    std::atomic<uint64_t> health_failures{0};
    std::atomic<uint64_t> reconnections{0};
    std::atomic<uint64_t> format_changes{0};
    std::atomic<uint64_t> sample_rate_conversions{0};
    std::atomic<uint64_t> client_starts{0};
    std::atomic<uint64_t> client_stops{0};

    void LogPeriodic() {
        static auto last_log = std::chrono::steady_clock::now();
        auto now = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(now - last_log).count();

        if (elapsed >= STATS_LOG_INTERVAL_SEC) {
            RF_LOG_INFO("╔══════════════ STATS (%llds) ══════════════╗", elapsed);
            RF_LOG_INFO("║ Writes: %llu (failed: %llu)              ", total_writes.load(), failed_writes.load());
            RF_LOG_INFO("║ Clients: starts=%llu stops=%llu          ", client_starts.load(), client_stops.load());
            RF_LOG_INFO("║ Health: failures=%llu reconnects=%llu    ", health_failures.load(), reconnections.load());
            RF_LOG_INFO("║ Format: changes=%llu SRC=%llu            ", format_changes.load(), sample_rate_conversions.load());
            RF_LOG_INFO("╚══════════════════════════════════════════╝");
            last_log = now;
        }
    }
};

// Custom VolumeControl that syncs to shared memory when volume changes.
// This intercepts macOS volume changes (via kAudioLevelControlPropertyScalarValue)
// and writes them to shared memory for the Host process to read.
class MoniVolVolumeControl : public aspl::VolumeControl {
public:
    MoniVolVolumeControl(std::shared_ptr<const aspl::Context> context,
                             const aspl::VolumeControlParameters& params = {})
        : aspl::VolumeControl(context, params)
        , shared_memory_(nullptr)
    {
    }

    void SetSharedMemory(RFSharedAudio* shm) {
        shared_memory_ = shm;
    }

    RFSharedAudio* GetSharedMemory() const {
        return shared_memory_;
    }

protected:
    OSStatus SetRawValueImpl(SInt32 value) override {
        OSStatus status = aspl::VolumeControl::SetRawValueImpl(value);
        if (status == kAudioHardwareNoError && shared_memory_) {
            Float32 scalar = GetScalarValue();
            rf_store_volume_scalar(shared_memory_, scalar);
            RF_DebugLog("MoniVolVolumeControl: volume changed to %.3f (raw=%d)", scalar, value);
        }
        return status;
    }

private:
    RFSharedAudio* shared_memory_;
};

// Custom MuteControl that syncs to shared memory when mute changes.
class MoniVolMuteControl : public aspl::MuteControl {
public:
    MoniVolMuteControl(std::shared_ptr<const aspl::Context> context,
                           const aspl::MuteControlParameters& params = {})
        : aspl::MuteControl(context, params)
        , shared_memory_(nullptr)
    {
    }

    void SetSharedMemory(RFSharedAudio* shm) {
        shared_memory_ = shm;
    }

    RFSharedAudio* GetSharedMemory() const {
        return shared_memory_;
    }

protected:
    OSStatus SetIsMutedImpl(bool isMuted) override {
        OSStatus status = aspl::MuteControl::SetIsMutedImpl(isMuted);
        if (status == kAudioHardwareNoError && shared_memory_) {
            rf_store_mute_state(shared_memory_, isMuted ? 1 : 0);
            RF_DebugLog("MoniVolMuteControl: mute changed to %d", isMuted ? 1 : 0);
        }
        return status;
    }

private:
    RFSharedAudio* shared_memory_;
};

// Custom Device subclass with correct GetZeroTimeStamp implementation.
// libASPL's default GetZeroTimeStampImpl only increments periodCounter_ by 1 per
// call. If the HAL calls GetZeroTimeStamp late, the counter can fall behind and
// never catch up, causing monotonic clock drift that Safari's Web Audio
// drift-compensation interprets as stutter.
// This override computes elapsed periods via integer division from an anchor time.
class MoniVolDevice : public aspl::Device {
public:
    MoniVolDevice(std::shared_ptr<aspl::Context> context,
                    const aspl::DeviceParameters& params)
        : aspl::Device(context, params)
        , anchorTime_(0)
        , periodCounter_(0)
        , hostTicksPerFrame_(0)
        , lastSampleRate_(0)
        , hostClockFreq_(0)
        , clockSeed_(1)
    {
        // Cache mach timebase at construction (non-RT-safe syscall).
        // The ratio is a hardware constant and does not change at runtime.
        struct mach_timebase_info tb = {};
        mach_timebase_info(&tb);
        // Guard against failure (numer==0). Fallback 1e9 = 1ns/tick, correct for Apple Silicon.
        hostClockFreq_ = (tb.numer > 0)
            ? Float64(tb.denom) / Float64(tb.numer) * 1.0e9
            : 1.0e9;
    }

    // Volume/Mute properties are handled entirely by MoniVolVolumeControl
    // and MoniVolMuteControl (added via AddVolumeControlAsync/AddMuteControlAsync).
    // libASPL's base Device class automatically routes volume/mute queries to
    // those control objects — no Device-level overrides needed.

protected:
    // StartIOImpl intentionally not overridden. The anchor is set once lazily in
    // GetZeroTimeStampImpl and never reset, keeping the clock timeline continuous
    // across IO start/stop cycles and preventing the cold-start underrun that
    // triggers Safari's Web Audio stutter.

    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) override
    {
        const UInt64 now = mach_absolute_time();

        // Ensure a deterministic anchor even if StartIOImpl has not run yet.
        if (anchorTime_ == 0) {
            anchorTime_ = now;
            periodCounter_ = 0;
        }

        // Recompute host ticks per frame on sample rate change
        Float64 sampleRate = GetNominalSampleRate();
        if (sampleRate <= 0) {
            sampleRate = (lastSampleRate_ > 0) ? lastSampleRate_ : 48000.0;
        }
        if (hostTicksPerFrame_ <= 0) {
            // First initialization — set rate, no anchor reset needed.
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
        } else if (sampleRate != lastSampleRate_) {
            // Genuine sample-rate change: re-anchor to now so outSampleTime stays
            // monotonic, and bump seed so the HAL knows to re-sync its IO timeline.
            anchorTime_ = now;
            periodCounter_ = 0;
            hostTicksPerFrame_ = hostClockFreq_ / sampleRate;
            lastSampleRate_ = sampleRate;
            ++clockSeed_;
        }

        const Float64 period = GetZeroTimeStampPeriod();
        if (period <= 0 || hostTicksPerFrame_ <= 0) {
            *outSampleTime = 0;
            *outHostTime = anchorTime_;
            *outSeed = clockSeed_;
            return kAudioHardwareNoError;
        }
        const Float64 ticksPerPeriod = hostTicksPerFrame_ * period;

        // Compute elapsed periods from anchor using division (not single increment)
        if (ticksPerPeriod > 0 && now >= anchorTime_) {
            UInt64 elapsed = now - anchorTime_;
            UInt64 periods = (UInt64)(Float64(elapsed) / ticksPerPeriod);
            periodCounter_ = periods;
        }

        *outSampleTime = periodCounter_ * period;
        *outHostTime = anchorTime_ + UInt64(Float64(periodCounter_) * ticksPerPeriod);
        *outSeed = clockSeed_;
        return kAudioHardwareNoError;
    }

private:
    // Thread-safety: libASPL's top-level StartIO()/GetZeroTimeStamp() take
    // Device::ioMutex_ before invoking these Impl overrides, so these fields are
    // serialized by the base class and do not need extra atomics here.
    UInt64 anchorTime_;
    UInt64 periodCounter_;
    Float64 hostTicksPerFrame_;
    Float64 lastSampleRate_;
    Float64 hostClockFreq_;  // (tb.denom/tb.numer)*1e9, cached at construction
    UInt64 clockSeed_;       // increments on sample-rate change to signal HAL re-sync

    // Volume/Mute state is owned by MoniVolVolumeControl/MuteControl objects.
    // No Device-level volume/mute members needed.
};

// IO/control handler for one proxy device.
class UniversalAudioHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    UniversalAudioHandler(const std::string& deviceUID)
        : shared_memory_(nullptr)
        , device_uid_(deviceUID)
        , io_client_count_(0)
        , state_(DeviceState::Uninitialized)
        , last_health_check_(std::chrono::steady_clock::now())
        , last_heartbeat_(std::chrono::steady_clock::now())
        , last_host_hb_(0)
        , last_host_hb_change_(std::chrono::steady_clock::now())
        , current_sample_rate_(DEFAULT_SAMPLE_RATE)
        , current_channels_(DEFAULT_CHANNELS)
        , resampler_(std::make_unique<SimpleResampler>(
            DEFAULT_SAMPLE_RATE, DEFAULT_SAMPLE_RATE, DEFAULT_CHANNELS))
    {
        std::string safe_uid = deviceUID;
        for (char& c : safe_uid) {
            if (c == ':' || c == '/' || c == ' ') c = '_';
        }
        shm_file_path_ = "/tmp/monivol-" + safe_uid;

        RF_LOG_INFO("UniversalAudioHandler created: %s", device_uid_.c_str());
        RF_LOG_INFO("  Supports: 44.1-192kHz, 1-8ch, all formats");
    }

    ~UniversalAudioHandler() {
        RF_LOG_INFO("UniversalAudioHandler destructor: %s", device_uid_.c_str());
        Disconnect();
    }

    // Back-reference to the device for volume/mute sync on IO start
    void SetDevice(MoniVolDevice* device) { device_ = device; }

    // Set custom volume/mute controls for shared memory sync
    void SetVolumeControl(MoniVolVolumeControl* vc) { volumeControl_ = vc; }
    void SetMuteControl(MoniVolMuteControl* mc) { muteControl_ = mc; }

    OSStatus OnStartIO() override {
        std::lock_guard<std::mutex> lock(io_mutex_);

        int32_t count = ++io_client_count_;
        stats_.client_starts++;

        RF_DebugLog("OnStartIO() client #%d (state: %s)", count, StateToString(state_.load()));
        RF_LOG_INFO("OnStartIO() client #%d (state: %s)", count, StateToString(state_.load()));

        if (count == 1) {
            state_ = DeviceState::Connecting;

            // Retry loop with exponential backoff.
            const int MAX_RETRIES = 15;
            const int BASE_DELAY_MS = 30;

            for (int attempt = 1; attempt <= MAX_RETRIES; attempt++) {
                OpenSharedMemory();

                if (shared_memory_) {
                    if (ValidateConnection()) {
                        RF_DebugLog("OnStartIO: Connected on attempt %d (uid=%s)", attempt, device_uid_.c_str());
                        RF_LOG_INFO("✓ Connected on attempt %d", attempt);
                        state_ = DeviceState::Connected;

                        // Pre-allocate conversion buffers
                        ResizeBuffers();

                        // Prebuffer half a ring of silence so the host render callback always has
                        // data to consume before Safari delivers its first real audio buffer.
                        // The two clocks (virtual device and physical hardware) are independent;
                        // without this cushion, the host reads before the driver writes ~50% of
                        // cold starts, causing persistent underruns and Safari stutter.
                        {
                            const uint32_t prefill = shared_memory_->ring_capacity_frames / 2;
                            const uint32_t channels = shared_memory_->channels;
                            std::vector<float> silence(prefill * channels, 0.0f);
                            rf_ring_write(shared_memory_, silence.data(), prefill);
                            RF_LOG_INFO("Prebuffered %u frames of silence (%ums cushion)",
                                prefill, prefill * 1000 / shared_memory_->sample_rate);
                        }

                        last_heartbeat_ = std::chrono::steady_clock::now();

                        // Set shared memory pointer on custom volume/mute controls
                        // so they can sync changes to shared memory in real-time.
                        if (volumeControl_) {
                            volumeControl_->SetSharedMemory(shared_memory_);
                            RF_DebugLog("OnStartIO: set shared memory on VolumeControl");
                        }
                        if (muteControl_) {
                            muteControl_->SetSharedMemory(shared_memory_);
                            RF_DebugLog("OnStartIO: set shared memory on MuteControl");
                        }

                        // Sync current volume/mute state to shared memory.
                        // This handles the case where volume was set before IO started.
                        RF_DebugLog("OnStartIO: device_=%p", (void*)device_);
                        if (volumeControl_) {
                            float vol = volumeControl_->GetScalarValue();
                            rf_store_volume_scalar(shared_memory_, vol);
                            RF_DebugLog("OnStartIO: synced VolumeControl value=%.3f", vol);
                            RF_LOG_INFO("Synced volume=%.3f to shared memory", vol);
                        }
                        if (muteControl_) {
                            bool muted = muteControl_->GetIsMuted();
                            rf_store_mute_state(shared_memory_, muted ? 1 : 0);
                            RF_DebugLog("OnStartIO: synced MuteControl value=%d", muted ? 1 : 0);
                            RF_LOG_INFO("Synced mute=%d to shared memory", muted ? 1 : 0);
                        }

                        return kAudioHardwareNoError;
                    } else {
                        RF_LOG_ERROR("✗ Validation failed");
                        Disconnect();
                    }
                }

                if (attempt < MAX_RETRIES) {
                    int delay = BASE_DELAY_MS * (1 << std::min(attempt - 1, 6));
                    RF_LOG_INFO("Retry %d/%d in %dms...", attempt + 1, MAX_RETRIES, delay);
                    std::this_thread::sleep_for(std::chrono::milliseconds(delay));
                }
            }

            // All retries failed.
            --io_client_count_;
            state_ = DeviceState::Error;
            PrintDetailedError();
            return kAudioHardwareUnspecifiedError;
        }

        // Additional client path intentionally does no recovery work.
        return shared_memory_ ? kAudioHardwareNoError : kAudioHardwareUnspecifiedError;
    }

    void OnStopIO() override {
        std::lock_guard<std::mutex> lock(io_mutex_);

        if (io_client_count_ == 0) {
            RF_LOG_ERROR("OnStopIO() called but count already 0!");
            return;
        }

        int32_t count = --io_client_count_;
        stats_.client_stops++;

        RF_LOG_INFO("OnStopIO() remaining: %d", count);

        if (count == 0) {
            RF_LOG_INFO("Last client stopped - disconnecting");
            Disconnect();
            state_ = DeviceState::Disconnected;
        }
    }

    void OnWriteMixedOutput(
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        stats_.total_writes++;

        if (!shared_memory_) {
            stats_.failed_writes++;
            return;
        }

        // Keep callback RT-safe: avoid filesystem checks/recovery here.
        rf_update_driver_heartbeat(shared_memory_);

        // Get stream format
        AudioStreamBasicDescription fmt = stream->GetPhysicalFormat();

        if (fmt.mBytesPerFrame == 0) {
            stats_.failed_writes++;
            return;
        }

        UInt32 frameCount = bytesCount / fmt.mBytesPerFrame;
        if (frameCount == 0) {
            stats_.failed_writes++;
            return;
        }

        // Check if format change is needed
        if (fmt.mSampleRate != current_sample_rate_ ||
            fmt.mChannelsPerFrame != current_channels_) {

            RF_LOG_INFO("Format change: %.0fHz %uch -> %uHz %uch",
                fmt.mSampleRate, fmt.mChannelsPerFrame,
                current_sample_rate_, current_channels_);

            HandleFormatChange(fmt);
        }

        // Ensure pre-allocated buffer is large enough
        size_t needed = frameCount * fmt.mChannelsPerFrame;
        if (interleaved_buf_.size() < needed) {
            interleaved_buf_.resize(needed);
        }

        // Convert to interleaved float32 using pre-allocated buffer
        if (!ConvertToFloat32Interleaved(bytes, frameCount, fmt, interleaved_buf_)) {
            stats_.failed_writes++;
            return;
        }

        // Compensate callback timestamp discontinuities (gaps/overlaps) to keep
        // a continuous producer timeline for the host reader.
        uint32_t skip_frames = 0;
        uint32_t prepend_silence_frames = 0;
        if (has_last_output_timestamp_) {
            const double delta = timestamp - last_output_timestamp_end_;
            if (delta > 0.5) {
                prepend_silence_frames = static_cast<uint32_t>(
                    std::min<double>(delta, shared_memory_->ring_capacity_frames / 2.0));
            } else if (delta < -0.5) {
                skip_frames = static_cast<uint32_t>(std::min<double>(-delta, frameCount));
            }
        }
        has_last_output_timestamp_ = true;
        last_output_timestamp_end_ = timestamp + frameCount;

        // Handle sample rate conversion if needed
        if (fmt.mSampleRate != shared_memory_->sample_rate) {
            const float* payload = interleaved_buf_.data() + (skip_frames * fmt.mChannelsPerFrame);
            const uint32_t payload_frames = frameCount - skip_frames;
            if (payload_frames > 0) {
                ProcessWithSampleRateConversion(payload, payload_frames,
                                            fmt.mSampleRate, shared_memory_->sample_rate,
                                            fmt.mChannelsPerFrame);
            }
        } else {
            if (prepend_silence_frames > 0) {
                const size_t available_silence_frames =
                    silence_buf_.size() / fmt.mChannelsPerFrame;
                if (prepend_silence_frames > available_silence_frames) {
                    prepend_silence_frames = static_cast<uint32_t>(available_silence_frames);
                }
                const size_t silence_needed = prepend_silence_frames * fmt.mChannelsPerFrame;
                std::fill_n(silence_buf_.begin(), silence_needed, 0.0f);
                WriteWithAdaptiveDriftCompensation(silence_buf_.data(), prepend_silence_frames,
                                                   fmt.mSampleRate, fmt.mChannelsPerFrame);
            }

            const float* payload = interleaved_buf_.data() + (skip_frames * fmt.mChannelsPerFrame);
            const uint32_t payload_frames = frameCount - skip_frames;
            if (payload_frames > 0) {
                WriteWithAdaptiveDriftCompensation(payload, payload_frames,
                                               fmt.mSampleRate, fmt.mChannelsPerFrame);
            }
        }

        stats_.LogPeriodic();
    }

    // Keep proxy volume controls for UI/events, but avoid applying proxy gain in-driver.
    // Volume is forwarded to the physical output device by the host process.
    void OnProcessMixedOutput(
        const std::shared_ptr<aspl::Stream>& stream,
        Float64 zeroTimestamp,
        Float64 timestamp,
        Float32* frames,
        UInt32 frameCount,
        UInt32 channelCount) override
    {
        (void)stream;
        (void)zeroTimestamp;
        (void)timestamp;
        (void)frames;
        (void)frameCount;
        (void)channelCount;
    }

private:
    void OpenSharedMemory() {
        RF_DebugLog("OpenSharedMemory: %s", shm_file_path_.c_str());
        RF_LOG_INFO("Opening: %s", shm_file_path_.c_str());

        struct stat st;
        if (stat(shm_file_path_.c_str(), &st) != 0) {
            RF_DebugLog("OpenSharedMemory: stat failed: %s", strerror(errno));
            RF_LOG_ERROR("File not found: %s", shm_file_path_.c_str());
            return;
        }

        int fd = open(shm_file_path_.c_str(), O_RDWR);
        if (fd == -1) {
            RF_DebugLog("OpenSharedMemory: open failed: %s", strerror(errno));
            RF_LOG_ERROR("open() failed: %s", strerror(errno));
            return;
        }

        // Validate file size before mapping
        size_t min_size = sizeof(RFSharedAudio);
        if ((size_t)st.st_size < min_size) {
            RF_DebugLog("OpenSharedMemory: size too small: %lld < %zu", (long long)st.st_size, min_size);
            RF_LOG_ERROR("File too small: %lld < %zu", (long long)st.st_size, min_size);
            close(fd);
            return;
        }

        void* mem = mmap(nullptr, st.st_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);

        if (mem == MAP_FAILED) {
            RF_DebugLog("OpenSharedMemory: mmap failed: %s", strerror(errno));
            RF_LOG_ERROR("mmap() failed: %s", strerror(errno));
            return;
        }

        shared_memory_ = reinterpret_cast<RFSharedAudio*>(mem);

        RF_DebugLog("OpenSharedMemory: mapped %p size=%lld rate=%u ch=%u fmt=%u",
            mem, (long long)st.st_size, shared_memory_->sample_rate, shared_memory_->channels, shared_memory_->format);
        RF_LOG_INFO("✓ Mapped at %p (size: %lld)", mem, (long long)st.st_size);
        RF_LOG_INFO("  Format: %uHz, %uch, format=%u",
            shared_memory_->sample_rate,
            shared_memory_->channels,
            shared_memory_->format);

        current_sample_rate_ = shared_memory_->sample_rate;
        current_channels_ = shared_memory_->channels;
    }

    void Disconnect() {
        // Clear control shared memory pointers FIRST to prevent writes to dangling memory
        if (volumeControl_) {
            volumeControl_->SetSharedMemory(nullptr);
        }
        if (muteControl_) {
            muteControl_->SetSharedMemory(nullptr);
        }

        if (shared_memory_) {
            RF_LOG_INFO("Disconnecting: %s", device_uid_.c_str());

            // Mark as disconnected
            atomic_store(&shared_memory_->driver_connected, 0);

            // Calculate size for munmap
            size_t size = rf_shared_audio_size(
                shared_memory_->ring_capacity_frames,
                shared_memory_->channels,
                shared_memory_->bytes_per_sample);

            munmap(shared_memory_, size);
            shared_memory_ = nullptr;
        }

        if (resampler_) {
            resampler_->Reset();
        }
    }

    bool ValidateConnection() {
        if (!shared_memory_) return false;

        // Check protocol version
        if (shared_memory_->protocol_version != RF_AUDIO_PROTOCOL_VERSION) {
            RF_DebugLog("ValidateConnection: protocol mismatch 0x%x expected 0x%x",
                shared_memory_->protocol_version, RF_AUDIO_PROTOCOL_VERSION);
            RF_LOG_ERROR("Protocol mismatch: 0x%x (expected 0x%x)",
                shared_memory_->protocol_version, RF_AUDIO_PROTOCOL_VERSION);
            return false;
        }

        // Check sample rate
        if (!rf_is_sample_rate_supported(shared_memory_->sample_rate)) {
            RF_DebugLog("ValidateConnection: unsupported sample rate %u", shared_memory_->sample_rate);
            RF_LOG_ERROR("Unsupported sample rate: %u", shared_memory_->sample_rate);
            return false;
        }

        // Check channels
        if (shared_memory_->channels == 0 || shared_memory_->channels > RF_MAX_CHANNELS) {
            RF_DebugLog("ValidateConnection: invalid channels %u", shared_memory_->channels);
            RF_LOG_ERROR("Invalid channel count: %u", shared_memory_->channels);
            return false;
        }

        // Mark driver as connected
        atomic_store(&shared_memory_->driver_connected, 1);
        RF_DebugLog("ValidateConnection: OK (driver_connected=1)");

        return true;
    }

    bool IsHealthy() {
        if (!shared_memory_) return false;

        // Check file existence
        struct stat st;
        if (stat(shm_file_path_.c_str(), &st) != 0) {
            RF_LOG_ERROR("Health: file vanished");
            return false;
        }

        // Check host connection
        uint32_t host_conn = atomic_load(&shared_memory_->host_connected);
        if (host_conn == 0) {
            RF_LOG_ERROR("Health: host disconnected");
            return false;
        }

        // Check heartbeat timeout (treat a never-started heartbeat as unhealthy after timeout)
        auto now = std::chrono::steady_clock::now();
        uint64_t current_host_hb = atomic_load(&shared_memory_->host_heartbeat);

        if (current_host_hb != last_host_hb_) {
            last_host_hb_ = current_host_hb;
            last_host_hb_change_ = now;
        } else {
            auto hb_age = std::chrono::duration_cast<std::chrono::seconds>(
                now - last_host_hb_change_).count();
            if (hb_age >= HEARTBEAT_TIMEOUT_SEC) {
                RF_LOG_ERROR("Health: host heartbeat timeout (stalled %llds)", (long long)hb_age);
                return false;
            }
        }

        // Check ring buffer integrity
        uint64_t write_idx = atomic_load(&shared_memory_->write_index);
        uint64_t read_idx = atomic_load(&shared_memory_->read_index);

        if (write_idx < read_idx) {
            RF_LOG_ERROR("Health: corruption (write < read)");
            return false;
        }

        uint64_t used = write_idx - read_idx;
        if (used > shared_memory_->ring_capacity_frames) {
            RF_LOG_ERROR("Health: overflow (used > capacity)");
            return false;
        }

        return true;
    }

    void AttemptRecovery() {
        RF_LOG_INFO("Attempting recovery...");
        stats_.reconnections++;

        Disconnect();

        if (io_client_count_ > 0) {
            OpenSharedMemory();
            if (shared_memory_ && ValidateConnection()) {
                RF_LOG_INFO("✓ Recovery successful");
                state_ = DeviceState::Connected;
            } else {
                RF_LOG_ERROR("✗ Recovery failed");
                state_ = DeviceState::Error;
            }
        }
    }

    void ResizeBuffers() {
        if (!shared_memory_) return;

        // Size for max expected callback: 4096 frames at 192kHz, 8 channels
        uint32_t max_frames = 4096;
        uint32_t max_channels = RF_MAX_CHANNELS;

        interleaved_buf_.resize(max_frames * max_channels);
        resampled_buf_.resize(max_frames * 2 * max_channels); // 2x for upsampling headroom
        const uint32_t max_silence_frames = std::max<uint32_t>(
            1, shared_memory_->ring_capacity_frames / 2);
        silence_buf_.resize(max_silence_frames * max_channels, 0.0f);
    }

    void HandleFormatChange(const AudioStreamBasicDescription& new_fmt) {
        stats_.format_changes++;

        current_sample_rate_ = (uint32_t)new_fmt.mSampleRate;
        current_channels_ = new_fmt.mChannelsPerFrame;

        if (shared_memory_ && resampler_) {
            resampler_->SetChannels(new_fmt.mChannelsPerFrame);
            resampler_->SetRates(new_fmt.mSampleRate, shared_memory_->sample_rate);
            RF_LOG_INFO("Configured resampler: %.0f -> %u Hz",
                new_fmt.mSampleRate, shared_memory_->sample_rate);
        }

        ResizeBuffers();
    }

    bool ConvertToFloat32Interleaved(const void* bytes, UInt32 frameCount,
                                     const AudioStreamBasicDescription& fmt,
                                     std::vector<float>& output) {
        output.resize(frameCount * fmt.mChannelsPerFrame);

        if (fmt.mFormatFlags & kAudioFormatFlagIsFloat) {
            const float* input = static_cast<const float*>(bytes);
            if (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) {
                // Non-interleaved to interleaved
                for (UInt32 ch = 0; ch < fmt.mChannelsPerFrame; ch++) {
                    const float* channel = input + (ch * frameCount);
                    for (UInt32 i = 0; i < frameCount; i++) {
                        output[i * fmt.mChannelsPerFrame + ch] = channel[i];
                    }
                }
            } else {
                // Already interleaved
                std::memcpy(output.data(), input, frameCount * fmt.mChannelsPerFrame * sizeof(float));
            }
        } else if (fmt.mFormatFlags & kAudioFormatFlagIsSignedInteger) {
            if (fmt.mBitsPerChannel == 16) {
                const int16_t* input = static_cast<const int16_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    output[i] = (float)input[i] / 32768.0f;
                }
            } else if (fmt.mBitsPerChannel == 32) {
                const int32_t* input = static_cast<const int32_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    output[i] = (float)input[i] / 2147483648.0f;
                }
            } else if (fmt.mBitsPerChannel == 24) {
                const uint8_t* input = static_cast<const uint8_t*>(bytes);
                for (UInt32 i = 0; i < frameCount * fmt.mChannelsPerFrame; i++) {
                    int32_t val = (int32_t)((input[i*3] << 0) | (input[i*3+1] << 8) | (input[i*3+2] << 16));
                    if (val & 0x800000) val |= 0xFF000000;  // Sign extend
                    output[i] = (float)val / 8388608.0f;
                }
            } else {
                return false;
            }
        } else {
            RF_LOG_ERROR("Unsupported format flags: 0x%x", fmt.mFormatFlags);
            return false;
        }

        return true;
    }

    void ProcessWithSampleRateConversion(const float* input, uint32_t input_frames,
                                        double input_rate, double output_rate,
                                        uint32_t channels) {
        if (!resampler_) return;
        resampler_->SetChannels(channels);
        resampler_->SetRates(input_rate, output_rate);

        stats_.sample_rate_conversions++;

        // Calculate output size and ensure buffer is large enough
        uint32_t output_capacity =
            static_cast<uint32_t>((input_frames * output_rate) / input_rate) + 10;
        size_t needed = output_capacity * channels;
        if (resampled_buf_.size() < needed) {
            resampled_buf_.resize(needed);
        }

        uint32_t output_frames = resampler_->Process(
            input, input_frames,
            resampled_buf_.data(), output_capacity);

        if (output_frames > 0) {
            rf_ring_write(shared_memory_, resampled_buf_.data(), output_frames);
        }
    }

    void WriteWithAdaptiveDriftCompensation(const float* input,
                                            uint32_t input_frames,
                                            double sample_rate,
                                            uint32_t channels) {
        if (!shared_memory_) return;

        const uint64_t write_idx = atomic_load(&shared_memory_->write_index);
        const uint64_t read_idx = atomic_load(&shared_memory_->read_index);
        const uint32_t capacity = shared_memory_->ring_capacity_frames;
        const uint64_t used = write_idx - read_idx;

        if (capacity == 0) {
            rf_ring_write(shared_memory_, input, input_frames);
            return;
        }

        const int64_t target_fill = static_cast<int64_t>(capacity / ADAPTIVE_FILL_TARGET_DIVISOR);
        const int64_t error = target_fill - static_cast<int64_t>(used);
        const int64_t deadband = std::max<int64_t>(1,
            (capacity * ADAPTIVE_FILL_DEADBAND_PERCENT) / 100);

        // Within deadband, keep exact nominal rate and avoid extra SRC work.
        if (std::llabs(error) <= deadband) {
            rf_ring_write(shared_memory_, input, input_frames);
            return;
        }

        // Small adaptive ratio correction to keep producer/consumer clocks centered.
        const double normalized_error =
            static_cast<double>(error) / std::max<int64_t>(1, target_fill);
        const double ppm_adjust =
            std::clamp(normalized_error * ADAPTIVE_MAX_ADJUST_PPM,
                       -ADAPTIVE_MAX_ADJUST_PPM, ADAPTIVE_MAX_ADJUST_PPM);
        const double adjusted_output_rate = sample_rate * (1.0 + (ppm_adjust / 1'000'000.0));

        ProcessWithSampleRateConversion(input, input_frames, sample_rate, adjusted_output_rate, channels);
    }

    void PrintDetailedError() {
        RF_LOG_ERROR("╔════════════════════════════════════════════════╗");
        RF_LOG_ERROR("║          OnStartIO FAILED - CRITICAL           ║");
        RF_LOG_ERROR("╚════════════════════════════════════════════════╝");
        RF_LOG_ERROR("Device: %s", device_uid_.c_str());
        RF_LOG_ERROR("File: %s", shm_file_path_.c_str());
        RF_LOG_ERROR("");
        RF_LOG_ERROR("Troubleshooting:");
        RF_LOG_ERROR("  1. Is host application running?");
        RF_LOG_ERROR("  2. Check: ls -la /tmp/monivol-*");
        RF_LOG_ERROR("  3. Check: cat /tmp/monivol-devices.txt");
        RF_LOG_ERROR("  4. Try: sudo killall coreaudiod");
        RF_LOG_ERROR("  5. Check logs: log show --predicate 'subsystem == \"com.monivol.driver\"'");
    }

public:
    // Accessor for shared memory (used by MoniVolDevice for volume sync)
    RFSharedAudio* GetSharedMemory() const { return shared_memory_; }

private:
    // Member variables
    RFSharedAudio* shared_memory_;
    MoniVolDevice* device_ = nullptr;  // back-reference for volume sync on IO start
    MoniVolVolumeControl* volumeControl_ = nullptr;  // custom volume control for shared memory sync
    MoniVolMuteControl* muteControl_ = nullptr;      // custom mute control for shared memory sync
    std::string device_uid_;
    std::string shm_file_path_;

    std::atomic<int32_t> io_client_count_;
    std::mutex io_mutex_;

    std::atomic<DeviceState> state_;

    std::chrono::steady_clock::time_point last_health_check_;
    std::chrono::steady_clock::time_point last_heartbeat_;
    uint64_t last_host_hb_;
    std::chrono::steady_clock::time_point last_host_hb_change_;

    uint32_t current_sample_rate_;
    uint32_t current_channels_;

    std::unique_ptr<SimpleResampler> resampler_;

    // Pre-allocated buffers to avoid heap allocation on the audio thread
    std::vector<float> interleaved_buf_;
    std::vector<float> resampled_buf_;
    std::vector<float> silence_buf_;

    bool has_last_output_timestamp_{false};
    double last_output_timestamp_end_{0.0};

    AudioStats stats_;
};

// Global state
struct MoniVolGlobalState {
    std::shared_ptr<aspl::Context> context;
    std::shared_ptr<aspl::Plugin> plugin;
    std::shared_ptr<aspl::Driver> driver;
    std::map<std::string, std::shared_ptr<aspl::Device>> devices;
    std::mutex sync_mutex;
    std::thread monitor_thread;
    std::atomic<bool> should_stop{false};

    struct HostHeartbeatState {
        uint64_t last_value{0};
        std::chrono::steady_clock::time_point last_change{std::chrono::steady_clock::now()};
    };
    std::map<std::string, HostHeartbeatState> host_hb_cache;
};

static MoniVolGlobalState* g_state = nullptr;

std::shared_ptr<aspl::Device> CreateProxyDevice(const std::string& name, const std::string& uid) {
    if (!g_state) return nullptr;

    aspl::DeviceParameters params;
    params.Name = name + " (MoniVol)";
    params.DeviceUID = uid + "-monivol";
    params.Manufacturer = "MoniVol";
    params.SampleRate = DEFAULT_SAMPLE_RATE;
    params.ChannelCount = DEFAULT_CHANNELS;
    params.EnableMixing = true;
    params.ZeroTimeStampPeriod = HAL_ZERO_TIMESTAMP_PERIOD_FRAMES;
    params.SafetyOffset = HAL_SAFETY_OFFSET_FRAMES;
    params.Latency = HAL_PRESENTATION_LATENCY_FRAMES;

    auto device = std::make_shared<MoniVolDevice>(g_state->context, params);

    // Create stream manually instead of using AddStreamWithControlsAsync
    auto stream = device->AddStreamAsync(aspl::Direction::Output);

    // Create custom VolumeControl and MuteControl that sync to shared memory
    auto volumeControl = std::make_shared<MoniVolVolumeControl>(
        g_state->context, aspl::VolumeControlParameters{});
    auto muteControl = std::make_shared<MoniVolMuteControl>(
        g_state->context, aspl::MuteControlParameters{});

    // Add controls to device
    device->AddVolumeControlAsync(volumeControl);
    device->AddMuteControlAsync(muteControl);

    // Attach controls to stream
    stream->AttachVolumeControl(volumeControl);
    stream->AttachMuteControl(muteControl);

    auto handler = std::make_shared<UniversalAudioHandler>(uid);
    handler->SetVolumeControl(volumeControl.get());
    handler->SetMuteControl(muteControl.get());
    handler->SetDevice(device.get());
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    RF_LOG_INFO("✓ Device created: %s", params.Name.c_str());

    return device;
}

void AddDevice(const std::string& name, const std::string& uid) {
    if (!g_state || g_state->devices.find(uid) != g_state->devices.end()) return;

    auto device = CreateProxyDevice(name, uid);
    if (device) {
        g_state->plugin->AddDevice(device);
        g_state->devices[uid] = device;
        // Preserve any stale heartbeat knowledge; only init if missing.
        if (g_state->host_hb_cache.find(uid) == g_state->host_hb_cache.end()) {
            g_state->host_hb_cache[uid] = MoniVolGlobalState::HostHeartbeatState{};
        }
    }
}

void RemoveDevice(const std::string& uid) {
    if (!g_state) return;

    auto it = g_state->devices.find(uid);
    if (it != g_state->devices.end()) {
        g_state->plugin->RemoveDevice(it->second);
        g_state->devices.erase(it);
    }
}

std::map<std::string, std::string> ParseControlFile() {
    std::map<std::string, std::string> devices;
    std::ifstream file("/tmp/monivol-devices.txt");
    if (!file.is_open()) return devices;

    std::string line;
    while (std::getline(file, line)) {
        size_t sep = line.find('|');
        if (sep != std::string::npos) {
            devices[line.substr(sep + 1)] = line.substr(0, sep);
        }
    }
    return devices;
}

bool HostHeartbeatFresh(const std::string& uid) {
    if (!g_state) return false;

    std::string safe_uid = uid;
    for (char& c : safe_uid) {
        if (c == ':' || c == '/' || c == ' ') c = '_';
    }
    std::string path = "/tmp/monivol-" + safe_uid;

    struct stat st;
    if (stat(path.c_str(), &st) != 0) {
        return false;
    }

    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
        return false;
    }

    void* mem = mmap(nullptr, st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (mem == MAP_FAILED) {
        return false;
    }

    auto shared = reinterpret_cast<RFSharedAudio*>(mem);
    uint64_t hb = atomic_load(&shared->host_heartbeat);

    munmap(mem, st.st_size);

    auto now = std::chrono::steady_clock::now();
    auto& state = g_state->host_hb_cache[uid];

    if (hb != state.last_value) {
        state.last_value = hb;
        state.last_change = now;
    }

    auto age = std::chrono::duration_cast<std::chrono::seconds>(
        now - state.last_change).count();

    // Treat a stalled or never-started heartbeat as stale after the timeout.
    return age < HEARTBEAT_TIMEOUT_SEC;
}

void SyncDevices() {
    if (!g_state) return;
    std::lock_guard<std::mutex> lock(g_state->sync_mutex);

    auto desired_raw = ParseControlFile();
    std::map<std::string, std::string> desired;

    // 显示器重连后会生成新的共享内存和心跳；断开时清除旧心跳状态。
    for (auto it = g_state->host_hb_cache.begin(); it != g_state->host_hb_cache.end();) {
        if (desired_raw.find(it->first) == desired_raw.end()) {
            it = g_state->host_hb_cache.erase(it);
        } else {
            ++it;
        }
    }

    for (const auto& [uid, name] : desired_raw) {
        if (HostHeartbeatFresh(uid)) {
            desired[uid] = name;
        } else {
            RF_LOG_INFO("SyncDevices: skipping stale entry uid=%s (no host heartbeat)", uid.c_str());
        }
    }

    RF_LOG_INFO("SyncDevices: desired=%zu current=%zu", desired.size(), g_state->devices.size());

    for (const auto& [uid, name] : desired) {
        if (g_state->devices.find(uid) == g_state->devices.end()) {
            AddDevice(name, uid);
        }
    }

    std::vector<std::string> to_remove;
    for (const auto& [uid, device] : g_state->devices) {
        if (desired.find(uid) == desired.end()) {
            to_remove.push_back(uid);
        }
    }

    for (const auto& uid : to_remove) {
        RF_LOG_INFO("SyncDevices: removing proxy for uid=%s", uid.c_str());
        RemoveDevice(uid);
    }
}

void MonitorControlFile() {
    // Register Darwin notification listener for immediate device sync
    int notify_token = 0;
    int reg_status = notify_register_dispatch(
        "com.monivol.devices-changed",
        &notify_token,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
        ^(int token) {
            if (g_state && !g_state->should_stop) {
                RF_LOG_INFO("Darwin notification received, syncing devices");
                SyncDevices();
            }
        }
    );

    if (reg_status != NOTIFY_STATUS_OK) {
        RF_LOG_ERROR("Failed to register Darwin notification (status: %d), using polling only", reg_status);
    }

    // Keep existing polling loop as fallback
    while (!g_state->should_stop) {
        SyncDevices();
        for (int i = 0; i < 10 && !g_state->should_stop; i++) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }

    // Cleanup
    if (reg_status == NOTIFY_STATUS_OK) {
        notify_cancel(notify_token);
    }
}

std::shared_ptr<aspl::Driver> CreateMoniVolDriver() {


    g_state = new MoniVolGlobalState();
    g_state->context = std::make_shared<aspl::Context>();
    g_state->plugin = std::make_shared<aspl::Plugin>(g_state->context);

    SyncDevices();

    g_state->monitor_thread = std::thread(MonitorControlFile);
    g_state->driver = std::make_shared<aspl::Driver>(g_state->context, g_state->plugin);

    RF_LOG_INFO("✓ Driver ready - %zu devices", g_state->devices.size());
    RF_LOG_INFO("Features: Multi-rate, Multi-format, SRC, Auto-recovery");

    return g_state->driver;
}

} // namespace

extern "C" void* MoniVolDriverPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    static std::shared_ptr<aspl::Driver> driver = CreateMoniVolDriver();
    return driver->GetReference();
}
