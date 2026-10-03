import Foundation
import CMoniVolAudio

struct MoniVolConfig {
    /// 共享内存和 AudioUnit 输入固定使用代理设备的采样率（驱动只提供 48 kHz）。
    /// 显示器采样率不同时，由 AUHAL 在输出端完成采样率转换。
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
