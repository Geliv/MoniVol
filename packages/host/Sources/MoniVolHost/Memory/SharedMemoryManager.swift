import Foundation
import Darwin
import CMoniVolAudio
import os.log

private let logger = Logger(subsystem: "com.monivol.host", category: "SharedMemoryManager")

class SharedMemoryManager {
    private var deviceMemory: [String: UnsafeMutablePointer<RFSharedAudio>] = [:]
    private var heartbeatTimer: DispatchSourceTimer?
    private var lock = os_unfair_lock()

    // Telemetry: track last-seen underrun/overrun counts for delta logging
    private var lastUnderrunCounts: [String: UInt64] = [:]
    private var lastOverrunCounts: [String: UInt64] = [:]
    private var telemetryCounter: Int = 0

    func createMemory(for devices: [PhysicalDevice]) {
        logger.info("Creating shared memory for \(devices.count) devices")

        for device in devices {
            if createMemory(for: device.uid) {
                logger.info("Shared memory created for \(device.name)")
            } else {
                logger.error("Failed to create shared memory for \(device.name)")
            }
        }

        logger.info("Shared memory creation complete")
    }

    func createMemory(for uid: String) -> Bool {
        print("[MoniVolHost] Creating shared memory for: \(uid)")

        let shmPath = PathManager.sharedMemoryPath(uid: uid)
        print("[MoniVolHost] File: \(shmPath)")

        unlink(shmPath)

        let fd = open(shmPath, O_CREAT | O_RDWR, 0o666)
        guard fd >= 0 else {
            logger.error("Failed to create file: \(String(cString: strerror(errno)))")
            return false
        }

        fchmod(fd, 0o666)

        let sampleRate = MoniVolConfig.activeSampleRate
        let frames = rf_frames_for_duration(
            sampleRate,
            MoniVolConfig.defaultDurationMs
        )
        let bytesPerSample = rf_bytes_per_sample(MoniVolConfig.defaultFormat)
        let shmSize = rf_shared_audio_size(
            frames,
            MoniVolConfig.defaultChannels,
            bytesPerSample
        )

        print("[MoniVolHost] Size: \(shmSize) bytes (\(frames) frames @ \(sampleRate)Hz)")

        guard ftruncate(fd, Int64(shmSize)) == 0 else {
            logger.error("Failed to set size: \(String(cString: strerror(errno)))")
            close(fd)
            return false
        }

        let mem = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
        close(fd)

        guard mem != MAP_FAILED else {
            logger.error("mmap failed: \(String(cString: strerror(errno)))")
            return false
        }

        let sharedMem = mem!.assumingMemoryBound(to: RFSharedAudio.self)

        rf_shared_audio_init(
            sharedMem,
            sampleRate,
            MoniVolConfig.defaultChannels,
            MoniVolConfig.defaultFormat,
            MoniVolConfig.defaultDurationMs
        )

        os_unfair_lock_lock(&lock)
        deviceMemory[uid] = sharedMem
        os_unfair_lock_unlock(&lock)

        logger.info("Shared memory created successfully for \(uid)")
        print("[MoniVolHost]   Protocol: current")
        print("[MoniVolHost]   Format: \(sampleRate)Hz, \(MoniVolConfig.defaultChannels)ch, float32")
        print("[MoniVolHost]   Buffer: \(MoniVolConfig.defaultDurationMs)ms (\(frames) frames)")
        print("[MoniVolHost]   Capabilities: Multi-rate, Multi-format, Heartbeat")

        return true
    }

    func removeMemory(for uid: String) {
        os_unfair_lock_lock(&lock)
        let sharedMem = deviceMemory[uid]
        if sharedMem != nil {
            deviceMemory.removeValue(forKey: uid)
        }
        os_unfair_lock_unlock(&lock)

        guard let sharedMem = sharedMem else { return }

        let shmSize = rf_shared_audio_size(
            sharedMem.pointee.ring_capacity_frames,
            sharedMem.pointee.channels,
            sharedMem.pointee.bytes_per_sample
        )

        munmap(sharedMem, shmSize)

        let shmPath = PathManager.sharedMemoryPath(uid: uid)
        unlink(shmPath)
    }

    func getMemory(for uid: String) -> UnsafeMutablePointer<RFSharedAudio>? {
        os_unfair_lock_lock(&lock)
        let mem = deviceMemory[uid]
        os_unfair_lock_unlock(&lock)
        return mem
    }

    func getFirstMemory() -> UnsafeMutablePointer<RFSharedAudio>? {
        os_unfair_lock_lock(&lock)
        let mem = deviceMemory.values.first
        os_unfair_lock_unlock(&lock)
        return mem
    }

    func startHeartbeat() {
        heartbeatTimer = DispatchSource.makeTimerSource(queue: .global())
        heartbeatTimer?.schedule(
            deadline: .now(),
            repeating: MoniVolConfig.heartbeatInterval
        )

        heartbeatTimer?.setEventHandler { [weak self] in
            guard let self = self else { return }
            os_unfair_lock_lock(&self.lock)
            let mems = Array(self.deviceMemory)
            os_unfair_lock_unlock(&self.lock)
            for (_, mem) in mems {
                rf_update_host_heartbeat(mem)
            }

            // Telemetry: log underrun/overrun deltas every 5 seconds (non-RT safe)
            self.telemetryCounter += 1
            if self.telemetryCounter % 5 == 0 {
                for (uid, mem) in mems {
                    let underruns = rf_get_underrun_count(mem)
                    let overruns = rf_get_overrun_count(mem)
                    let lastU = self.lastUnderrunCounts[uid] ?? 0
                    let lastO = self.lastOverrunCounts[uid] ?? 0
                    if underruns > lastU {
                        logger.warning("⚠️ Buffer underrun: +\(underruns - lastU) (total: \(underruns)) [\(uid)]")
                    }
                    if overruns > lastO {
                        logger.warning("⚠️ Buffer overrun: +\(overruns - lastO) (total: \(overruns)) [\(uid)]")
                    }
                    self.lastUnderrunCounts[uid] = underruns
                    self.lastOverrunCounts[uid] = overruns
                }
            }
        }

        heartbeatTimer?.resume()
        logger.info("Started heartbeat - updating every second")
    }

    func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    func cleanup() {
        print("[Cleanup] Unmapping shared memory...")
        os_unfair_lock_lock(&lock)
        let entries = deviceMemory
        deviceMemory.removeAll()
        os_unfair_lock_unlock(&lock)

        for (uid, mem) in entries {
            let size = rf_shared_audio_size(
                mem.pointee.ring_capacity_frames,
                mem.pointee.channels,
                mem.pointee.bytes_per_sample
            )
            munmap(mem, size)
            unlink(PathManager.sharedMemoryPath(uid: uid))
        }
    }
}
