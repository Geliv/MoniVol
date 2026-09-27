import Foundation
import CoreAudio
import AudioToolbox
import CMoniVolAudio
import os.log

private let logger = Logger(subsystem: "com.monivol.host", category: "AudioRenderer")

class AudioRenderer {
    private let memoryManager: SharedMemoryManager
    private let proxyManager: ProxyDeviceManager
    private var didLogRenderInfo = false
    private var testTonePhase: Float = 0
    private var tempBuffer: [Float] = []
    private let useTestTone: Bool

    // Gain Stage state
    private var currentGain: Float = -1.0  // negative = uninitialized, snap on first frame
    private let smoothingCoeff: Float = 0.995  // ~10ms at 48kHz

    init(
        memoryManager: SharedMemoryManager,
        proxyManager: ProxyDeviceManager
    ) {
        self.memoryManager = memoryManager
        self.proxyManager = proxyManager
        self.useTestTone = (ProcessInfo.processInfo.environment["RF_TEST_TONE"] == "1")
    }

    func createRenderCallback() -> AURenderCallback {
        return { (
            inRefCon,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            ioData
        ) -> OSStatus in
            guard let bufferList = ioData else {
                return noErr
            }

            let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
            renderer.render(bufferList: bufferList, frameCount: inNumberFrames)

            return noErr
        }
    }

    private func render(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        if !didLogRenderInfo {
            didLogRenderInfo = true
            let numBuffers = Int(bufferList.pointee.mNumberBuffers)
            var sizes: [UInt32] = []
            for i in 0..<numBuffers {
                let buf = UnsafeMutableAudioBufferListPointer(bufferList)[i]
                sizes.append(buf.mDataByteSize)
            }
            print("[AudioRenderer] First render: frames=\(frameCount) buffers=\(numBuffers) sizes=\(sizes)")
        }

        let sharedMem: UnsafeMutablePointer<RFSharedAudio>?

        if let activeUID = proxyManager.activeProxyUID {
            sharedMem = memoryManager.getMemory(for: activeUID)
        } else {
            sharedMem = memoryManager.getFirstMemory()
        }

        guard let mem = sharedMem else {
            outputSilence(bufferList: bufferList, frameCount: frameCount)
            return
        }

        let channelCount = Int(bufferList.pointee.mNumberBuffers)
        let needed = Int(frameCount) * channelCount
        if tempBuffer.count < needed {
            tempBuffer = [Float](repeating: 0, count: needed)
        } else {
            for i in 0..<needed {
                tempBuffer[i] = 0
            }
        }
        let framesRead: UInt32

        if useTestTone {
            let sampleRate = Float(MoniVolConfig.activeSampleRate)
            let freq: Float = 440.0
            let phaseInc = (2.0 * Float.pi * freq) / sampleRate
            for i in 0..<Int(frameCount) {
                let sample = sin(testTonePhase) * 0.2
                for ch in 0..<channelCount {
                    tempBuffer[i * channelCount + ch] = sample
                }
                testTonePhase += phaseInc
                if testTonePhase > 2.0 * Float.pi {
                    testTonePhase -= 2.0 * Float.pi
                }
            }
            framesRead = frameCount
        } else {
            framesRead = rf_ring_read(mem, &tempBuffer, frameCount)
        }

        // === Gain Stage (Linear Passthrough) ===
        // macOS volumeScalar is already perceptually mapped (Weber-Fechner),
        // so we use it directly as the physical gain — no additional curve.
        let volumeScalar = rf_load_volume_scalar(mem)
        let isMuted = rf_load_mute_state(mem) != 0
        let sampleCount = Int(framesRead) * channelCount

        let targetGain: Float = (isMuted || volumeScalar <= 0.0) ? 0.0 : volumeScalar

        // Snap to target on first frame to avoid startup fade artifact
        if currentGain < 0.0 {
            currentGain = targetGain
        }

        if targetGain == 0.0 {
            // Mute / zero volume: hard silence, no smoothing tail
            currentGain = 0.0
            for i in 0..<sampleCount {
                tempBuffer[i] = 0
            }
        } else if targetGain == 1.0 && currentGain > 0.999 {
            // Full volume: bit-perfect passthrough
            currentGain = 1.0
        } else {
            for i in 0..<Int(framesRead) {
                currentGain = currentGain * smoothingCoeff + targetGain * (1.0 - smoothingCoeff)
                // Kill denormals / near-zero residue
                if currentGain < 1.0e-6 { currentGain = 0.0 }
                for ch in 0..<channelCount {
                    tempBuffer[i * channelCount + ch] *= currentGain
                }
            }
        }

        deinterleave(
            source: tempBuffer,
            bufferList: bufferList,
            framesRead: framesRead,
            totalFrames: frameCount
        )
    }

    private func outputSilence(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buf in buffers {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            for i in 0..<min(count, Int(frameCount)) {
                data[i] = 0
            }
        }
    }

    private func deinterleave(
        source: [Float],
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        framesRead: UInt32,
        totalFrames: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.count

        for (ch, buf) in buffers.enumerated() {
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let capacity = Int(buf.mDataByteSize) / MemoryLayout<Float>.size

            // 写入已读帧
            for i in 0..<min(Int(framesRead), capacity) {
                let srcIndex = i * channelCount + ch
                data[i] = srcIndex < source.count ? source[srcIndex] : 0
            }

            // 剩余帧填零
            for i in Int(framesRead)..<min(Int(totalFrames), capacity) {
                data[i] = 0
            }
        }
    }
}
