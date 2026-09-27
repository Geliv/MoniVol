import Foundation
import CMoniVolAudio

struct MoniVolConfig {
    /// 采样率的线程安全访问
    private static var _activeSampleRate: UInt32 = 48000
    private static var sampleRateLock = os_unfair_lock()

    static var activeSampleRate: UInt32 {
        get {
            os_unfair_lock_lock(&sampleRateLock)
            defer { os_unfair_lock_unlock(&sampleRateLock) }
            return _activeSampleRate
        }
        set {
            os_unfair_lock_lock(&sampleRateLock)
            _activeSampleRate = newValue
            os_unfair_lock_unlock(&sampleRateLock)
        }
    }
    /// Fallback sample rate if device query fails
    static let defaultSampleRate: UInt32 = 48000
    static let defaultChannels: UInt32 = 2
    static let defaultFormat = RF_FORMAT_FLOAT32
    static let defaultDurationMs: UInt32 = 100

    static var controlFilePath: String {
        return PathManager.controlFilePath
    }

    static let heartbeatInterval: TimeInterval = 1.0
    static let wakeRecoveryDelay: TimeInterval = 1.5
    static let wakeRetryMaxAttempts = 4
    static let wakeRetryDelays: [TimeInterval] = [0, 2.0, 4.0, 8.0]

    // 等待 CoreAudio 在显示器重连后发布新的代理设备。
    static let deviceWaitTimeout: TimeInterval = 15.0
    static let cleanupWaitTimeout: TimeInterval = 1.2
    static let physicalDeviceSwitchDelay: TimeInterval = 0.5
}
