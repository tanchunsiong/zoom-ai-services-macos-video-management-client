import Foundation

public enum WebVTT {
    public static func write(_ cues: [TranscriptCue]) -> String {
        var output = "WEBVTT\n\n"
        for cue in cues.sorted(by: { $0.start < $1.start }) {
            output += "\(cue.index)\n"
            output += "\(format(cue.start)) --> \(format(cue.end))\n"
            output += cue.text.replacingOccurrences(of: "-->", with: "->").trimmingCharacters(in: .whitespacesAndNewlines)
            output += "\n\n"
        }
        return output
    }

    public static func parse(_ text: String) -> [TranscriptCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let parsed: [TranscriptCue] = normalized.components(separatedBy: "\n\n").compactMap { block -> TranscriptCue? in
            let lines = block.components(separatedBy: "\n")
            guard let timeIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[timeIndex].components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = parseTimestamp(times[0].components(separatedBy: " ").first ?? ""),
                  let end = parseTimestamp(times[1].components(separatedBy: " ").first ?? "")
            else { return nil }
            let body = lines.dropFirst(timeIndex + 1).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return TranscriptCue(index: 0, start: start, end: end, text: body)
        }
        return parsed.enumerated().map {
            TranscriptCue(index: $0.offset + 1, start: $0.element.start,
                          end: $0.element.end, text: $0.element.text)
        }
    }

    public static func format(_ interval: TimeInterval) -> String {
        let milliseconds = max(0, Int((interval * 1000).rounded()))
        return String(format: "%02d:%02d:%02d.%03d",
                      milliseconds / 3_600_000,
                      milliseconds / 60_000 % 60,
                      milliseconds / 1000 % 60,
                      milliseconds % 1000)
    }

    public static func parseTimestamp(_ value: String) -> TimeInterval? {
        let pieces = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
