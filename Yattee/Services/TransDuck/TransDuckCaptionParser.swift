//
//  TransDuckCaptionParser.swift
//  Yattee
//
//  Reads WebVTT captions and writes a local translated SRT track for mpv.
//

import Foundation

enum TransDuckCaptionParser {
    static func parseWebVTT(_ data: Data) throws -> [TransDuckCue] {
        guard let source = String(data: data, encoding: .utf8) else {
            throw TransDuckError.invalidSubtitle
        }

        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var cues: [TransDuckCue] = []
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard line.contains(" --> ") else {
                lineIndex += 1
                continue
            }

            let times = line.components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = timestamp(times[0]),
                  let end = timestamp(times[1].components(separatedBy: .whitespaces).first ?? ""),
                  end > start else {
                lineIndex += 1
                continue
            }

            lineIndex += 1
            var textLines: [String] = []
            while lineIndex < lines.count,
                  !lines[lineIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                textLines.append(lines[lineIndex])
                lineIndex += 1
            }
            let text = cleanText(textLines.joined(separator: " "))
            if !text.isEmpty {
                cues.append(TransDuckCue(index: cues.count, text: text, start: start, end: end))
            }
        }

        guard !cues.isEmpty else { throw TransDuckError.invalidSubtitle }
        return cues
    }

    static func makeSRT(_ translations: [TransDuckTranslation], bilingual: Bool = false) throws -> URL {
        guard !translations.isEmpty else { throw TransDuckError.noCaptions }
        let body = translations.enumerated().map { offset, item in
            let safeText = item.text.replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let subtitleText = bilingual ? "\(safeText)\n\(item.cue.text)" : safeText
            return "\(offset + 1)\n\(srtTime(item.cue.start)) --> \(srtTime(item.cue.end))\n\(subtitleText)\n"
        }.joined(separator: "\n")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yattee-transduck", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString + "_vi.srt")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func timestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0 >= 0 }) else { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }

    private static func srtTime(_ value: TimeInterval) -> String {
        let milliseconds = max(0, Int((value * 1_000).rounded()))
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, remainder)
    }

    private static func cleanText(_ raw: String) -> String {
        let withoutTags = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return withoutTags.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
