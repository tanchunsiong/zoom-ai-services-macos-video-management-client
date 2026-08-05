import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class ZoomLiveScribeClient {
    public static let endpoint = URL(
        string: "wss://api.zoom.us/v2/aiservices/scribe/live"
    )!
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func stream(
        frames: AsyncStream<Data>,
        options: LiveScribeOptions,
        credentials: APICredentials,
        onEvent: @escaping @Sendable (LiveScribeEvent) -> Void
    ) async throws {
        try options.validate()
        guard credentials.isComplete else {
            throw NSError(
                domain: "ZScribe.Live.Credentials",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Zoom AI Services credentials are incomplete."]
            )
        }

        var request = URLRequest(url: Self.endpoint)
        request.setValue(
            "Bearer \(try ZoomJWT.create(credentials: credentials))",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("live-asr", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(
                with: URLSessionWebSocketTask.CloseCode.goingAway,
                reason: nil
            )
        }

        try await sendText(Self.sessionUpdateJSON(options), over: socket)
        try await awaitSessionReady(socket, onEvent: onEvent)

        let receiver = Task {
            try await Self.receiveEvents(socket, onEvent: onEvent)
        }
        do {
            try await sendAudio(frames, over: socket)
            try await sendText(#"{"type":"session.close"}"#, over: socket)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await receiver.value }
                group.addTask {
                    try await Task.sleep(for: .seconds(15))
                    throw Self.liveError(
                        "Zoom did not close the Live session within 15 seconds."
                    )
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            receiver.cancel()
            throw error
        }
    }

    public static func sessionUpdateJSON(_ options: LiveScribeOptions) throws -> String {
        try options.validate()
        var payload: [String: Any] = [
            "type": "session.update",
            "input_audio_format": "pcm16",
            "language": options.language
        ]
        if let vocabulary = try ScribeVocabularyJSON.parse(options.vocabularyJSON) {
            payload["vocabulary"] = vocabulary
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    public static func parseServerEvent(_ json: String) throws -> LiveScribeEvent {
        guard let root = try JSONSerialization.jsonObject(
            with: Data(json.utf8)
        ) as? [String: Any] else {
            throw NSError(
                domain: "ZScribe.Live.Response",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Zoom Live returned invalid JSON."]
            )
        }
        let type = root["type"] as? String ?? "unknown"
        let error: String? = if let value = root["error"] as? String {
            value
        } else if let value = root["error"] as? [String: Any] {
            value["message"] as? String ?? String(describing: value)
        } else {
            nil
        }
        return LiveScribeEvent(
            type: type,
            transcript: findTranscript(in: root),
            error: error,
            isDelta: type.localizedCaseInsensitiveContains("delta") || root["delta"] != nil
        )
    }

    private func awaitSessionReady(
        _ socket: URLSessionWebSocketTask,
        onEvent: @escaping @Sendable (LiveScribeEvent) -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                while true {
                    let event = try await Self.receiveEvent(socket)
                    onEvent(event)
                    if event.type == "error" {
                        throw Self.liveError(event.error ?? "Zoom Live returned an error.")
                    }
                    if event.type == "session.updated" { return }
                    if event.type == "session.closed" {
                        throw Self.liveError(
                            "The Live session closed before acknowledging its configuration."
                        )
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw Self.liveError(
                    "Zoom did not acknowledge the Live session configuration within 10 seconds."
                )
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func sendAudio(
        _ frames: AsyncStream<Data>,
        over socket: URLSessionWebSocketTask
    ) async throws {
        for await frame in frames {
            try Task.checkCancellation()
            guard !frame.isEmpty else { continue }
            try await socket.send(.data(frame))
        }
    }

    private func sendText(
        _ text: String,
        over socket: URLSessionWebSocketTask
    ) async throws {
        try await socket.send(.string(text))
    }

    private static func receiveEvents(
        _ socket: URLSessionWebSocketTask,
        onEvent: @escaping @Sendable (LiveScribeEvent) -> Void
    ) async throws {
        while !Task.isCancelled {
            let event = try await receiveEvent(socket)
            onEvent(event)
            if event.type == "error" {
                throw liveError(event.error ?? "Zoom Live returned an error.")
            }
            if event.type == "session.closed" { return }
        }
    }

    private static func receiveEvent(
        _ socket: URLSessionWebSocketTask
    ) async throws -> LiveScribeEvent {
        switch try await socket.receive() {
        case .string(let json):
            return try parseServerEvent(json)
        case .data(let data):
            return try parseServerEvent(String(decoding: data, as: UTF8.self))
        @unknown default:
            throw liveError("Zoom Live returned an unsupported WebSocket message.")
        }
    }

    private static func findTranscript(in value: Any, depth: Int = 0) -> String? {
        guard depth <= 4 else { return nil }
        if let object = value as? [String: Any] {
            for key in ["transcript", "text", "delta"] {
                if let text = object[key] as? String { return text }
            }
            for nested in object.values {
                if let text = findTranscript(in: nested, depth: depth + 1),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let text = findTranscript(in: nested, depth: depth + 1),
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private static func liveError(_ message: String) -> NSError {
        NSError(
            domain: "ZScribe.Live",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
