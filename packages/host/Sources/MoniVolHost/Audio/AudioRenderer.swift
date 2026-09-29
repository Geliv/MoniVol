import AudioToolbox
import CMoniVolAudio
import CoreAudio
import Darwin
import Foundation

final class AudioRenderer {
    private let memorySlot: OpaquePointer
    private var testTonePhase: Float = 0
    private var tempBuffer: [Float] = []
    private var preparedChannelCount = 0
    private let useTestTone: Bool

    // Gain state is owned exclusively by the AudioUnit render thread.
    private var currentGain: Float = -1.0
    private let smoothingCoeff: Float = 0.995

    init() {
        guard let memorySlot = rf_render_memory_slot_create() else {
            fatalError("Failed to create realtime shared-memory slot")
        }
        self.memorySlot = memorySlot
        self.useTestTone = ProcessInfo.processInfo.environment["RF_TEST_TONE"] == "1"
    }

    deinit {
        rf_render_memory_slot_destroy(memorySlot)
    }

    /// Called while the AudioUnit is stopped, before render callbacks can run.
    func prepare(maxFrames: UInt32, channelCount: UInt32) {
        preparedChannelCount = Int(channelCount)
        tempBuffer = [Float](
            repeating: 0,
            count: Int(maxFrames) * preparedChannelCount
        )
    }

    /// Publishes a mapping from a control thread without blocking the render thread.
    func setSharedMemory(_ memory: UnsafeMutablePointer<RFSharedAudio>?) {
        rf_render_memory_slot_set(memorySlot, memory)
    }

    /// Stops new render callbacks from acquiring a mapping and waits for any callback
    /// already using it to finish before the caller unmaps it.
    func clearSharedMemory(_ memory: UnsafeMutablePointer<RFSharedAudio>) {
        _ = rf_render_memory_slot_clear_if(memorySlot, memory)
    }

    func createRenderCallback() -> AURenderCallback {
        return { inRefCon, _, _, _, inNumberFrames, ioData in
            guard let bufferList = ioData else {
                return noErr
            }

            let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
            renderer.render(bufferList: bufferList, frameCount: inNumberFrames)
            return noErr
        }
    }

    private func render(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: UInt32
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channelCount = buffers.count
        let needed = Int(frameCount) * channelCount

        guard channelCount == preparedChannelCount,
              needed <= tempBuffer.count,
              let memory = rf_render_memory_slot_acquire(memorySlot) else {
            outputSilence(buffers: buffers, frameCount: frameCount)
            return
        }
        defer { rf_render_memory_slot_release(memorySlot) }

        guard memory.pointee.channels == UInt32(channelCount) else {
            outputSilence(buffers: buffers, frameCount: frameCount)
            return
        }

        tempBuffer.withUnsafeMutableBufferPointer { samples in
            guard let sampleBase = samples.baseAddress else {
                outputSilence(buffers: buffers, frameCount: frameCount)
                return
            }

            if useTestTone {
                renderTestTone(
                    into: sampleBase,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sampleRate: memory.pointee.sample_rate
                )
            } else {
                _ = rf_ring_read(memory, sampleBase, frameCount)
            }

            applyGain(
                to: sampleBase,
                frameCount: frameCount,
                channelCount: channelCount,
                memory: memory
            )
            deinterleave(
                source: sampleBase,
                buffers: buffers,
                frameCount: frameCount,
                channelCount: channelCount
            )
        }
    }

    private func renderTestTone(
        into samples: UnsafeMutablePointer<Float>,
        frameCount: UInt32,
        channelCount: Int,
        sampleRate: UInt32
    ) {
        let frequency: Float = 440.0
        let phaseIncrement = (2.0 * Float.pi * frequency) / Float(sampleRate)

        for frame in 0..<Int(frameCount) {
            let sample = sinf(testTonePhase) * 0.2
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = sample
            }
            testTonePhase += phaseIncrement
            if testTonePhase > 2.0 * Float.pi {
                testTonePhase -= 2.0 * Float.pi
            }
        }
    }

    private func applyGain(
        to samples: UnsafeMutablePointer<Float>,
        frameCount: UInt32,
        channelCount: Int,
        memory: UnsafeMutablePointer<RFSharedAudio>
    ) {
        let volumeScalar = rf_load_volume_scalar(memory)
        let isMuted = rf_load_mute_state(memory) != 0
        let targetGain: Float = (isMuted || volumeScalar <= 0.0) ? 0.0 : volumeScalar
        let sampleCount = Int(frameCount) * channelCount

        if currentGain < 0.0 {
            currentGain = targetGain
        }

        if targetGain == 0.0 {
            currentGain = 0.0
            samples.update(repeating: 0, count: sampleCount)
        } else if targetGain == 1.0 && currentGain > 0.999 {
            currentGain = 1.0
        } else {
            for frame in 0..<Int(frameCount) {
                currentGain = currentGain * smoothingCoeff
                    + targetGain * (1.0 - smoothingCoeff)
                if currentGain < 1.0e-6 {
                    currentGain = 0.0
                }
                for channel in 0..<channelCount {
                    samples[frame * channelCount + channel] *= currentGain
                }
            }
        }
    }

    private func deinterleave(
        source: UnsafePointer<Float>,
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: UInt32,
        channelCount: Int
    ) {
        for channel in 0..<buffers.count {
            let buffer = buffers[channel]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let framesToWrite = min(Int(frameCount), capacity)
            for frame in 0..<framesToWrite {
                data[frame] = source[frame * channelCount + channel]
            }
        }
    }

    private func outputSilence(
        buffers: UnsafeMutableAudioBufferListPointer,
        frameCount: UInt32
    ) {
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                continue
            }
            let capacity = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            data.update(repeating: 0, count: min(capacity, Int(frameCount)))
        }
    }
}
