import Foundation
import MoniVolCore
import os.log

private let logger = Logger(subsystem: "com.monivol.host", category: "VolumePersistence")

/// Persisted volume state for a single physical device.
struct DeviceVolumeState: Codable {
    var volumeScalar: Float  // 0.0 - 1.0
    var isMuted: Bool
    /// 写入时间，用于同一显示器的多个 UID 别名之间挑选最新状态。
    /// 旧版本文件没有该字段，解码为 nil。
    var updatedAt: Date?
}

/// Persists per-device volume and mute state to disk.
///
/// Storage: `~/Library/Application Support/MoniVol/volume-state.json`
/// - In-memory cache for fast reads
/// - 500ms debounce on writes to avoid excessive I/O during slider drag
/// - Atomic write (.tmp + rename) to prevent corruption
class VolumePersistence {
    static let defaultVolume: Float = 0.35

    private let fileURL: URL
    private let legacyFileURL: URL?
    private var cache: [String: DeviceVolumeState] = [:]
    private let queue = DispatchQueue(label: "com.monivol.volume-persistence")
    private var pendingWrite: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.5  // 500ms

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? PathManager.appSupportDir.appendingPathComponent("volume-state.json")
        self.legacyFileURL = fileURL == nil
            ? PathManager.appSupportDir.deletingLastPathComponent()
                .appendingPathComponent("SoundBridge/volume-state.json") : nil
        loadFromDisk()
    }

    /// Save volume and mute state for a device UID.
    /// Writes are debounced (500ms) and performed atomically.
    func save(uid: String, volume: Float, muted: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cache[uid] = DeviceVolumeState(
                volumeScalar: volume,
                isMuted: muted,
                updatedAt: Date()
            )
            self.scheduleDebouncedWrite()
        }
    }

    /// Load volume state for a device UID.
    /// 先按完整 UID 精确匹配；显示器 UID 的 `_XXXXXXXX` 后缀在重启或重连后
    /// 可能变化，此时退回匹配相同 base UID 的旧记录。
    /// Returns cached value if available, otherwise defaults (volume=0.35, muted=false).
    func load(uid: String) -> DeviceVolumeState {
        return queue.sync {
            if let exact = cache[uid] {
                return exact
            }
            if let alias = newestAlias(for: uid) {
                return alias
            }
            return DeviceVolumeState(volumeScalar: Self.defaultVolume, isMuted: false)
        }
    }

    /// 同一物理显示器可能以多个 UID 出现在状态文件中，取最近写入的一条。
    private func newestAlias(for uid: String) -> DeviceVolumeState? {
        let base = DeviceIdentity.baseUID(uid)
        let aliases = cache.filter { DeviceIdentity.baseUID($0.key) == base }
        return aliases.values.max {
            ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast)
        }
    }

    // MARK: - Private

    private func scheduleDebouncedWrite() {
        // Cancel any pending write
        pendingWrite?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.writeToDisk()
        }
        pendingWrite = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func loadFromDisk() {
        queue.sync { [self] in
            let sourceURL = FileManager.default.fileExists(atPath: self.fileURL.path)
                ? self.fileURL : self.legacyFileURL
            guard let sourceURL, FileManager.default.fileExists(atPath: sourceURL.path) else {
                logger.info("No existing state file, starting fresh")
                return
            }
            do {
                let data = try Data(contentsOf: sourceURL)
                let decoded = try JSONDecoder().decode([String: DeviceVolumeState].self, from: data)
                self.cache = decoded
                logger.info("Loaded state for \(decoded.count) device(s)")
            } catch {
                logger.error("Failed to load state: \(error.localizedDescription)")
            }
        }
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(cache)

            // Atomic write: write to .tmp first, then rename
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [.atomic])

            // Rename .tmp → final path
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
            try fm.moveItem(at: tmpURL, to: fileURL)

            logger.info("Saved state for \(self.cache.count) device(s)")
        } catch {
            logger.error("Failed to save state: \(error.localizedDescription)")
        }
    }
}
