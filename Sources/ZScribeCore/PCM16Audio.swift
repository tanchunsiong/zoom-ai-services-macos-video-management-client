import Foundation

public struct PCM16LevelReading: Hashable, Sendable {
    public var peakDBFS: Double
    public var rmsDBFS: Double
    public var isClipping: Bool
    public var appliedGain: Double

    public init(
        peakDBFS: Double,
        rmsDBFS: Double,
        isClipping: Bool,
        appliedGain: Double
    ) {
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
        self.isClipping = isClipping
        self.appliedGain = appliedGain
    }
}

public final class PCM16AudioProcessor {
    private let targetRMS = 0.1259
    private let maximumPeak = 0.8913
    private let silenceFloor = 0.0018
    private let minimumGain = 0.25
    private let maximumGain = 8.0
    private var gain = 1.0

    public init() {}

    public func process(_ data: inout Data, automaticGain: Bool) -> PCM16LevelReading {
        guard !data.isEmpty else {
            return PCM16LevelReading(
                peakDBFS: -.infinity,
                rmsDBFS: -.infinity,
                isClipping: false,
                appliedGain: gain
            )
        }
        precondition(data.count.isMultiple(of: 2), "PCM16 data must contain complete samples.")

        var inputSquares = 0.0
        var inputPeak = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for littleEndianSample in samples {
                let sample = Int(Int16(littleEndian: littleEndianSample))
                inputPeak = max(inputPeak, abs(sample))
                inputSquares += Double(sample * sample)
            }
        }

        let sampleCount = data.count / 2
        let inputRMS = sqrt(inputSquares / Double(sampleCount)) / 32_768
        let inputPeakLinear = Double(inputPeak) / 32_768
        if !automaticGain {
            gain = 1
        } else if inputRMS >= silenceFloor {
            let rmsGain = targetRMS / inputRMS
            let peakGain = inputPeakLinear > 0 ? maximumPeak / inputPeakLinear : maximumGain
            let desired = min(max(min(rmsGain, peakGain), minimumGain), maximumGain)
            let smoothing = desired < gain ? 0.65 : 0.25
            gain += (desired - gain) * smoothing
            gain = min(gain, peakGain)
        } else {
            gain += (1 - gain) * 0.1
        }

        var outputSquares = 0.0
        var outputPeak = 0
        var clipping = inputPeak >= Int(Int16.max)
        data.withUnsafeMutableBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for index in samples.indices {
                let sample = Double(Int16(littleEndian: samples[index]))
                let scaled = Int((sample * gain).rounded())
                clipping = clipping || scaled >= Int(Int16.max) || scaled <= Int(Int16.min)
                let output = min(max(scaled, Int(Int16.min)), Int(Int16.max))
                samples[index] = Int16(output).littleEndian
                outputPeak = max(outputPeak, abs(output))
                outputSquares += Double(output * output)
            }
        }
        clipping = clipping || outputPeak >= Int(Int16.max)
        return PCM16LevelReading(
            peakDBFS: Self.dbfs(Double(outputPeak) / 32_768),
            rmsDBFS: Self.dbfs(sqrt(outputSquares / Double(sampleCount)) / 32_768),
            isClipping: clipping,
            appliedGain: gain
        )
    }

    public static func normalizedMeter(_ peakDBFS: Double) -> Double {
        min(max((peakDBFS + 60) / 60, 0), 1)
    }

    private static func dbfs(_ linear: Double) -> Double {
        linear <= 0 ? -.infinity : 20 * log10(linear)
    }
}

public struct PCM16FrameAssembler: Sendable {
    public static let defaultFrameBytes = 16_000 * 2 / 10
    private let frameBytes: Int
    private var pending = Data()

    public init(frameBytes: Int = Self.defaultFrameBytes) {
        precondition(frameBytes > 0 && frameBytes.isMultiple(of: 2))
        self.frameBytes = frameBytes
        pending.reserveCapacity(frameBytes)
    }

    public mutating func append(_ data: Data) -> [Data] {
        precondition(data.count.isMultiple(of: 2))
        pending.append(data)
        var frames: [Data] = []
        while pending.count >= frameBytes {
            frames.append(pending.prefix(frameBytes))
            pending.removeFirst(frameBytes)
        }
        return frames
    }

    public mutating func drain() -> Data? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
}
