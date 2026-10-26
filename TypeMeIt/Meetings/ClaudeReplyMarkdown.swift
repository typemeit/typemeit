import Foundation

/// Claude's reply as Markdown for `ClaudeMarkdown`. A table Claude drew in
/// ASCII or box-drawing characters, fenced or not, becomes a Markdown table.
/// Any other drawing without a ``` fence, lines that start with `|` or `+-`
/// or hold box-drawing characters, is fenced, so it stays fixed-width and
/// unwrapped.
enum ClaudeReplyMarkdown {
    static func markdown(_ reply: String) -> String {
        var lines: [Substring] = []
        var drawn: [Substring] = []
        /// The open fence's own line and what it holds so far.
        var fence: (opening: Substring, body: [Substring])?
        func startBlock() {
            // A block needs a blank line to start after a paragraph.
            if let last = lines.last, !last.allSatisfy(\.isWhitespace) { lines.append("") }
        }
        func appendTable(_ table: [Substring]) {
            startBlock()
            // Without one after it, the next paragraph's line would read as a row.
            lines += table + [""]
        }
        func endDrawing() {
            guard !drawn.isEmpty else { return }
            defer { drawn = [] }
            if let table = table(drawn) {
                appendTable(table)
            } else if isMarkdownTable(drawn) {
                startBlock()
                lines += drawn
            } else {
                startBlock()
                lines += ["```"] + drawn + ["```"]
            }
        }
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.drop(while: \.isWhitespace).hasPrefix("```")
            if let open = fence {
                if isFence {
                    if let table = table(open.body) { appendTable(table) } else { lines += [open.opening] + open.body + [line] }
                    fence = nil
                } else {
                    fence?.body.append(line)
                }
            } else if isFence {
                endDrawing()
                fence = (line, [])
            } else if isDrawn(line) {
                drawn.append(line)
            } else {
                endDrawing()
                lines.append(line)
            }
        }
        endDrawing()
        if let open = fence { lines += [open.opening] + open.body }
        return lines.joined(separator: "\n")
    }

    private static func isDrawn(_ line: Substring) -> Bool {
        let start = line.drop(while: \.isWhitespace)
        return start.hasPrefix("|") || start.hasPrefix("+-") || line.unicodeScalars.contains(where: isBoxDrawing)
    }

    /// U+2500–U+257F is Unicode's Box Drawing block.
    private static func isBoxDrawing(_ scalar: Unicode.Scalar) -> Bool { (0x2500...0x257F).contains(scalar.value) }

    /// Rows of `|` cells whose second row is the `|---|` line under the header.
    private static func isMarkdownTable(_ drawn: [Substring]) -> Bool {
        guard drawn.count > 1, drawn.allSatisfy({ $0.drop(while: \.isWhitespace).hasPrefix("|") }) else { return false }
        let delimiter = drawn[1]
        return delimiter.contains("-") && delimiter.allSatisfy { "|:- ".contains($0) }
    }

    /// The characters a rule is drawn with between its column joins.
    private static let ruleStrokes: Set<Character> = ["-", "=", ":", "─", "━", "═"]
    /// The characters a row's cells are walled with.
    private static let walls: Set<Character> = ["|", "│", "┃", "║"]

    /// A grid table drawn with rules (`+----+`, `├────┤`) and walled rows, as
    /// a Markdown table. The rows above the second rule are its header, or
    /// the first row when there is no second rule. Nil for anything else,
    /// such as a diagram, or a row whose walls are not under the first
    /// rule's joins.
    static func table(_ drawn: [Substring]) -> [Substring]? {
        let grid = drawn.map { Array($0.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()) }.filter { !$0.isEmpty }
        guard let top = grid.first, isRule(top) else { return nil }
        let joins = top.indices.filter { !ruleStrokes.contains(top[$0]) }
        guard joins.count > 1 else { return nil }
        var rows: [[String]] = []
        /// How many rows were above each rule after the top one.
        var rowsAboveRules: [Int] = []
        for line in grid.dropFirst() {
            if isRule(line) {
                rowsAboveRules.append(rows.count)
                continue
            }
            guard line.count == top.count, joins.allSatisfy({ walls.contains(line[$0]) }) else { return nil }
            rows.append(zip(joins, joins.dropFirst()).map { start, end in
                String(line[(start + 1)..<end]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|")
            })
        }
        guard !rows.isEmpty else { return nil }
        // Markdown has one header row; a header drawn over several lines joins them per column.
        let headerCount = rowsAboveRules.first { $0 > 0 && $0 < rows.count } ?? 1
        let header = rows[0].indices.map { column in rows[..<headerCount].map { $0[column] }.filter { !$0.isEmpty }.joined(separator: " ") }
        let body = rows[headerCount...]
        let markdownRows = [header, header.map { _ in "---" }] + body
        return markdownRows.map { "| " + $0.joined(separator: " | ") + " |" }.map { Substring($0) }
    }

    /// A rule: column joins and strokes only, starting and ending with a join.
    private static func isRule(_ line: [Character]) -> Bool {
        guard let first = line.first, let last = line.last, !ruleStrokes.contains(first), !ruleStrokes.contains(last),
              line.contains(where: { ruleStrokes.contains($0) }) else { return false }
        return line.allSatisfy { ruleStrokes.contains($0) || $0 == "+" || $0.unicodeScalars.allSatisfy(isBoxDrawing) }
    }
}
