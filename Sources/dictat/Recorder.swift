import AVFoundation

/// Captures microphone audio and resamples it to the 16 kHz mono Float format Parakeet
/// expects. Accumulates samples while recording; `stop()` returns the full take.
final class Recorder {
    private let engine = AVAudioEngine()
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private var converter: AVAudioConverter?
    private let bufferQueue = DispatchQueue(label: "dictat.recorder.buffer")
    private var samples: [Float] = []
    private var currentLevel: Float = 0
    private(set) var isRecording = false

    /// Peak amplitude (0…1) of the most recent captured chunk. Stays at 0 when the
    /// selected input is muted or delivering no audio at all — which is exactly the
    /// case the menu-bar meter needs to make visible.
    var level: Float { bufferQueue.sync { currentLevel } }

    /// Begin capturing. Throws if the audio engine can't start.
    func start() throws {
        guard !isRecording else { return }
        bufferQueue.sync {
            samples.removeAll(keepingCapacity: true)
            currentLevel = 0
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stop capturing and return everything recorded as 16 kHz mono samples.
    @discardableResult
    func stop() -> [Float] {
        guard isRecording else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        converter = nil
        return bufferQueue.sync {
            currentLevel = 0
            return samples
        }
    }

    // MARK: - Private

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }

        // Resample the input chunk to 16 kHz mono.
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        bufferQueue.sync {
            samples.append(contentsOf: chunk)
            currentLevel = peak
        }
    }
}
