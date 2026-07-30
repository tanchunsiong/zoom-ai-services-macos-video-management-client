import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import ZScribeCore

enum LiveAudioSource: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        }
    }
}

final class LiveAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    let frames: AsyncStream<Data>

    private let source: LiveAudioSource
    private let automaticGain: Bool
    private let processingQueue = DispatchQueue(
        label: "com.tanchunsiong.ZScribeMac.live-audio",
        qos: .userInitiated
    )
    private let audioProcessor = PCM16AudioProcessor()
    private var assembler = PCM16FrameAssembler()
    private var continuation: AsyncStream<Data>.Continuation
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var engine: AVAudioEngine?
    private var screenStream: SCStream?
    private var silenceTimer: DispatchSourceTimer?
    private var lastAudioAt = ContinuousClock.now
    private var stopped = false
    private let onLevel: @Sendable (PCM16LevelReading) -> Void

    init(
        source: LiveAudioSource,
        automaticGain: Bool,
        onLevel: @escaping @Sendable (PCM16LevelReading) -> Void
    ) {
        var capturedContinuation: AsyncStream<Data>.Continuation?
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(50)) {
            capturedContinuation = $0
        }
        continuation = capturedContinuation!
        self.source = source
        self.automaticGain = automaticGain
        self.onLevel = onLevel
        super.init()
    }

    func start() async throws {
        switch source {
        case .microphone:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw captureError(
                    "Microphone access is required. Enable it in System Settings > Privacy & Security > Microphone."
                )
            }
            try startMicrophone()
        case .systemAudio:
            try await startSystemAudio()
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        silenceTimer?.cancel()
        silenceTimer = nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let screenStream {
            try? await screenStream.stopCapture()
            self.screenStream = nil
        }
        await processingQueue.asyncResult {
            if let remainder = self.assembler.drain() {
                self.continuation.yield(remainder)
            }
            self.continuation.finish()
        }
        resetMeter()
    }

    func abort() {
        guard !stopped else { return }
        stopped = true
        silenceTimer?.cancel()
        silenceTimer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let screenStream {
            Task { try? await screenStream.stopCapture() }
        }
        screenStream = nil
        continuation.finish()
        resetMeter()
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw captureError("The default microphone does not provide an audio format.")
        }
        input.installTap(
            onBus: 0,
            bufferSize: 4_096,
            format: format
        ) { [weak self] buffer, _ in
            self?.enqueue(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    private func startSystemAudio() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw captureError(
                "Screen Recording permission is required for system audio. Enable Z Scribe in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
        guard let display = content.displays.first else {
            throw captureError("No display is available for system-audio capture.")
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.capturesAudio = true
        configuration.sampleRate = 16_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: processingQueue
        )
        do {
            try await stream.startCapture()
            screenStream = stream
            startSilenceTimer()
        } catch {
            try? stream.removeStreamOutput(self, type: .audio)
            throw error
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio,
              sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer),
              let formatDescription = sampleBuffer.formatDescription
        else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }
                buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                process(buffer)
            }
        } catch {
            continuation.finish()
        }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        let copied = copy(buffer)
        processingQueue.async { [weak self] in
            self?.process(copied)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard !stopped, let data = convertToPCM16(buffer), !data.isEmpty else { return }
        lastAudioAt = .now
        emit(data)
    }

    private func emit(_ sourceData: Data) {
        var data = sourceData
        let reading = audioProcessor.process(&data, automaticGain: automaticGain)
        for frame in assembler.append(data) {
            continuation.yield(frame)
        }
        onLevel(reading)
    }

    private func convertToPCM16(_ input: AVAudioPCMBuffer) -> Data? {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        if converter == nil || converterSourceFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
            converterSourceFormat = input.format
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(
            ceil(Double(input.frameLength) * 16_000 / input.format.sampleRate) + 32
        )
        guard let output = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: max(capacity, 1)
        ) else { return nil }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            guard !supplied else {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0 else {
            return nil
        }
        let audioBuffer = output.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        )!
        result.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for index in 0..<min(source.count, destination.count) {
            guard let sourceData = source[index].mData,
                  let destinationData = destination[index].mData else { continue }
            memcpy(
                destinationData,
                sourceData,
                Int(min(source[index].mDataByteSize, destination[index].mDataByteSize))
            )
        }
        return result
    }

    private func startSilenceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped,
                  self.lastAudioAt.duration(to: .now) >= .milliseconds(150)
            else { return }
            self.continuation.yield(
                Data(repeating: 0, count: PCM16FrameAssembler.defaultFrameBytes)
            )
            self.onLevel(PCM16LevelReading(
                peakDBFS: -.infinity,
                rmsDBFS: -.infinity,
                isClipping: false,
                appliedGain: 1
            ))
        }
        silenceTimer = timer
        timer.resume()
    }

    private func resetMeter() {
        onLevel(PCM16LevelReading(
            peakDBFS: -.infinity,
            rmsDBFS: -.infinity,
            isClipping: false,
            appliedGain: 1
        ))
    }

    private func captureError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live.Capture",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension DispatchQueue {
    func asyncResult(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            async {
                work()
                continuation.resume()
            }
        }
    }
}
