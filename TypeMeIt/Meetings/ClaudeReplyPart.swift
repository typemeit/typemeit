import Foundation

/// A stretch of Claude's reply: prose, or a drawing (a table or diagram)
/// that only lines up in a fixed-width face and must not wrap. A drawing is
/// what sits in a ``` block, or lines that start with a table's `|` or `+-`
/// or hold box-drawing characters.
enum ClaudeReplyPart: Equatable {
    case prose(String)
    case drawing(String)

    static func parts(of reply: String) -> [ClaudeReplyPart] {
        var parts: [ClaudeReplyPart] = []
        var lines: [Substring] = []
        var linesAreDrawing = false
        var fenced = false
        func endLines() {
            defer { lines = [] }
            if linesAreDrawing {
                if !lines.isEmpty { parts.append(.drawing(lines.joined(separator: "\n"))) }
            } else {
                let prose = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !prose.isEmpty { parts.append(.prose(prose)) }
            }
        }
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.drop(while: \.isWhitespace).hasPrefix("```") {
                endLines()
                fenced.toggle()
                linesAreDrawing = fenced
                continue
            }
            let isDrawing = fenced || isDrawn(line)
            if isDrawing != linesAreDrawing {
                endLines()
                linesAreDrawing = isDrawing
            }
            lines.append(line)
        }
        endLines()
        return parts
    }

    private static func isDrawn(_ line: Substring) -> Bool {
        let start = line.drop(while: \.isWhitespace)
        // U+2500–U+257F is Unicode's Box Drawing block.
        return start.hasPrefix("|") || start.hasPrefix("+-") || line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }
}
