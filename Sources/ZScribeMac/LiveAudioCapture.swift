import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import ZScribeCore

enum LiveAudioSource: String, CaseIterable, Identifiable {
    case microphone = "Microphone"
    case systemAudio = "System Audio"
    case combined = "Mic + System"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .systemAudio: "speaker.wave.2"
        case .combined: "waveform"
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
    private var microphoneConverter: AVAudioConverter?
    private var microphoneSourceFormat: AVAudioFormat?
    private var systemConverter: AVAudioConverter?
    private var systemSourceFormat: AVAudioFormat?
    private var microphonePending = Data()
    private var systemPending = Data()
    private var engine: AVAudioEngine?
    private var screenStream: SCStream?
    private var silenceTimer: DispatchSourceTimer?
    private var lastMicrophoneAudioAt = ContinuousClock.now
    private var lastSystemAudioAt = ContinuousClock.now
    private var combinedReady = false
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
            try await requestMicrophoneAccess()
            try startMicrophone()
        case .systemAudio:
            try await startSystemAudio()
        case .combined:
            try await requestMicrophoneAccess()
            try startMicrophone()
            try await startSystemAudio()
            await processingQueue.asyncResult {
                self.microphonePending.removeAll(keepingCapacity: true)
                self.systemPending.removeAll(keepingCapacity: true)
                self.lastMicrophoneAudioAt = .now
                self.lastSystemAudioAt = .now
                self.combinedReady = true
            }
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
            if self.source == .combined {
                self.drainCombinedAudio()
            }
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

    private func requestMicrophoneAccess() async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw captureError(
                "Microphone access is required. Enable it in System Settings > Privacy & Security > Microphone."
            )
        }
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
            self?.enqueue(buffer, input: .microphone)
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
                process(buffer, input: .system)
            }
        } catch {
            continuation.finish()
        }
    }

    private enum CaptureInput {
        case microphone
        case system
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, input: CaptureInput) {
        let copied = copy(buffer)
        processingQueue.async { [weak self] in
            self?.process(copied, input: input)
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer, input: CaptureInput) {
        guard !stopped,
              source != .combined || combinedReady,
              let data = convertToPCM16(buffer, input: input),
              !data.isEmpty
        else { return }
        switch input {
        case .microphone:
            lastMicrophoneAudioAt = .now
        case .system:
            lastSystemAudioAt = .now
        }
        if source == .combined {
            appendCombined(data, input: input)
        } else {
            emit(data)
        }
    }

    private func emit(_ sourceData: Data) {
        var data = sourceData
        let reading = audioProcessor.process(&data, automaticGain: automaticGain)
        for frame in assembler.append(data) {
            continuation.yield(frame)
        }
        onLevel(reading)
    }

    private func convertToPCM16(
        _ input: AVAudioPCMBuffer,
        input captureInput: CaptureInput
    ) -> Data? {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        switch captureInput {
        case .microphone:
            if microphoneConverter == nil || microphoneSourceFormat != input.format {
                microphoneConverter = AVAudioConverter(from: input.format, to: target)
                microphoneSourceFormat = input.format
            }
        case .system:
            if systemConverter == nil || systemSourceFormat != input.format {
                systemConverter = AVAudioConverter(from: input.format, to: target)
                systemSourceFormat = input.format
            }
        }
        let converter: AVAudioConverter?
        switch captureInput {
        case .microphone:
            converter = microphoneConverter
        case .system:
            converter = systemConverter
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

    private func appendCombined(_ data: Data, input: CaptureInput) {
        switch input {
        case .microphone:
            microphonePending.append(data)
        case .system:
            systemPending.append(data)
        }
        emitAvailableCombinedAudio()
    }

    private func emitAvailableCombinedAudio() {
        let byteCount = min(microphonePending.count, systemPending.count)
        let completeByteCount = byteCount - byteCount % 2
        guard completeByteCount > 0 else { return }
        let microphone = Data(microphonePending.prefix(completeByteCount))
        let system = Data(systemPending.prefix(completeByteCount))
        microphonePending.removeFirst(completeByteCount)
        systemPending.removeFirst(completeByteCount)
        emit(PCM16MonoMixer.mix(microphone, system))
    }

    private func drainCombinedAudio() {
        let byteCount = max(microphonePending.count, systemPending.count)
        guard byteCount > 0 else { return }
        if microphonePending.count < byteCount {
            microphonePending.append(Data(
                repeating: 0,
                count: byteCount - microphonePending.count
            ))
        }
        if systemPending.count < byteCount {
            systemPending.append(Data(
                repeating: 0,
                count: byteCount - systemPending.count
            ))
        }
        emitAvailableCombinedAudio()
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
            guard let self, !self.stopped else { return }
            let silence = Data(
                repeating: 0,
                count: PCM16FrameAssembler.defaultFrameBytes
            )
            if self.source == .combined {
                guard self.combinedReady else { return }
                if self.lastMicrophoneAudioAt.duration(to: .now) >= .milliseconds(150) {
                    self.appendCombined(silence, input: .microphone)
                }
                if self.lastSystemAudioAt.duration(to: .now) >= .milliseconds(150) {
                    self.appendCombined(silence, input: .system)
                }
            } else if self.lastSystemAudioAt.duration(to: .now) >= .milliseconds(150) {
                self.continuation.yield(silence)
                self.onLevel(PCM16LevelReading(
                    peakDBFS: -.infinity,
                    rmsDBFS: -.infinity,
                    isClipping: false,
                    appliedGain: 1
                ))
            }
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
