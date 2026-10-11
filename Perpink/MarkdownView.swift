import QuickLook
import SwiftUI

/// Block-based Markdown renderer for chat answers.
///
/// `AttributedString(markdown:)` only applies inline styling and collapses
/// blank lines, so answers lose their paragraph structure. This view splits
/// the text into blocks (headings, paragraphs, nested lists, images, code
/// blocks, quotes, tables, dividers) and lays each out as its own view, using
/// inline-only Markdown parsing for the text inside each block.
struct MarkdownView: View {
    let text: String

    @State private var cache = ParseCache()

    #if os(macOS)
    @Environment(\.readingScale) private var readingScale
    #else
    @ScaledMetric(relativeTo: .callout) private var scaledColumnFloor: CGFloat = 130
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Rendering

    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .paragraph(let content):
            InlineText(content: inline(content))
                .lineSpacing(3)
                .textSelection(.enabled)

        case .heading(let level, let content):
            InlineText(content: inline(content))
                .readingFont(Self.headingStyle(level).style, weight: Self.headingStyle(level).weight)
                .textSelection(.enabled)

        case .code(let code, _):
            CodeBlock(code: code)

        case .list(let items):
            // Hanging indents, as TextEdit and Pages set lists: markers sit
            // right-aligned in a column as wide as the widest one at their
            // level, so `9.` and `10.` start their text together, and a nested
            // item's marker lines up with its parent's text — the parents'
            // columns are laid out again, invisibly, ahead of it.
            let widest = Self.widestMarkers(items)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        ForEach(0..<item.level, id: \.self) { level in
                            markerColumn(nil, widest: widest[level])
                        }
                        markerColumn(item.marker, widest: widest[item.level])
                        InlineText(content: inline(item.text))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                }
            }

        case .image(let image):
            MarkdownImage(image: image)

        case .media(let path):
            MediaFile(path: path)

        case .quote(let content):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(.secondary)
                    .frame(width: 3)
                InlineText(content: inline(content))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

        case .table(let table):
            // Columns keep their natural width while the table fits; when it
            // doesn't, the widest give way first and their text wraps, down
            // to a dozen characters or so. Only a table still too wide at
            // that scrolls sideways, rather than squeezing columns further —
            // with its scroll bar, and its cut-off edges fading out, so it
            // reads as wider than the screen rather than clipped.
            ViewThatFits(in: .horizontal) {
                tableGrid(table)
                ScrollView(.horizontal) {
                    tableGrid(table)
                }
                .modifier(ScrollEdgeFade())
            }

        case .divider:
            Divider()
        }
    }

    private func tableGrid(_ table: Table) -> some View {
        let columns = table.headers.count
        let rows = [table.headers] + table.rows
        return TableLayout(columns: max(columns, 1), floor: tableColumnFloor) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row, cells in
                ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                    tableCell(cell, alignment: table.alignment(column), isHeader: row == 0)
                        // The gap between columns sits inside the cells, so
                        // the rules under each row run through it.
                        .padding(.trailing, column < columns - 1 ? 14 : 0)
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                            alignment: Alignment(horizontal: table.alignment(column).horizontal, vertical: .top)
                        )
                        .overlay(alignment: .bottom) {
                            if row < rows.count - 1 {
                                Divider().opacity(row == 0 ? 1 : 0.4)
                            }
                        }
                }
            }
        }
    }

    /// How narrow a table column may get before the table scrolls instead:
    /// a dozen characters or so of its text, at the reading size.
    private var tableColumnFloor: CGFloat {
        #if os(macOS)
        120 * readingScale
        #else
        scaledColumnFloor
        #endif
    }

    private func tableCell(_ text: String, alignment: ColumnAlignment, isHeader: Bool) -> some View {
        InlineText(content: inline(text))
            .readingFont(.callout, weight: isHeader ? .semibold : nil)
            .multilineTextAlignment(alignment.text)
            .padding(.vertical, 6)
            .textSelection(.enabled)
    }

    /// One marker's column in a list: as wide as `widest`, the marker set
    /// against its trailing edge; nil leaves the column empty.
    private func markerColumn(_ marker: String?, widest: String) -> some View {
        ZStack(alignment: .trailing) {
            Text(widest).hidden()
            if let marker {
                Text(marker)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityHidden(marker == nil)
    }

    /// The longest marker at each nesting level, which sets that level's column.
    private static func widestMarkers(_ items: [ListItem]) -> [String] {
        let depth = (items.map(\.level).max() ?? 0) + 1
        var widest = Array(repeating: "•", count: depth)
        for item in items where item.marker.count > widest[item.level].count {
            widest[item.level] = item.marker
        }
        return widest
    }

    private static func headingStyle(_ level: Int) -> (style: Font.TextStyle, weight: Font.Weight?) {
        switch level {
        case 1: (.title2, .bold)
        case 2: (.title3, .bold)
        case 3: (.headline, nil)
        default: (.subheadline, .bold)
        }
    }

    /// Parses inline Markdown (bold, italic, links, inline code) while
    /// preserving line breaks and whitespace verbatim. An image that couldn't
    /// be lifted out into its own block (inside a list item or a table cell)
    /// becomes a link to it, and a `MEDIA:` path — a file on the Hermes host —
    /// becomes its file name.
    private func inline(_ text: String) -> AttributedString {
        var source = text.replacingOccurrences(
            of: Self.imagePattern, with: "[🖼 $1]($2)", options: .regularExpression)
        source = source.replacingOccurrences(
            of: Self.mediaPattern, with: "📎 _$2_", options: .regularExpression)
        source = Self.escapingLoneTildes(source)
        var options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true)
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(text)
        return Self.linkingBareAddresses(parsed)
    }

    private static let linkDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Apple's parser only links `[text](url)` and `<url>`; an address written
    /// out bare — `vals.ai/models`, `https://…` — stays plain text. Link those,
    /// except inside code spans and links already there.
    private static func linkingBareAddresses(_ content: AttributedString) -> AttributedString {
        let string = String(content.characters)
        guard string.contains(".") else { return content }
        var linked = content
        for match in linkDetector.matches(in: string, range: NSRange(string.startIndex..., in: string)) {
            guard var url = match.url, url.scheme == "http" || url.scheme == "https",
                  let range = Range(match.range, in: string)
            else { continue }
            let lower = linked.characters.index(
                linked.startIndex, offsetBy: string.distance(from: string.startIndex, to: range.lowerBound))
            let upper = linked.characters.index(
                lower, offsetBy: string.distance(from: range.lowerBound, to: range.upperBound))
            guard !linked[lower..<upper].runs.contains(where: {
                $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true
            }) else { continue }
            // Written without a scheme, the detector assumes http; sites serve https.
            if !string[range].lowercased().hasPrefix("http"),
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "https"
                url = components.url ?? url
            }
            linked[lower..<upper].link = url
        }
        return linked
    }

    /// A lone `~` reads as strikethrough to Apple's parser, but answers use it
    /// for "about" (`~$80`), and two of them strike out everything in between.
    /// Escape lone tildes outside code spans; `~~` still strikes through.
    private static func escapingLoneTildes(_ text: String) -> String {
        guard text.contains("~") else { return text }
        let chars = Array(text)
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                // A code span runs to the next run of as many backticks.
                var run = 1
                while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                var j = i + run
                var end: Int?
                while j < chars.count {
                    if chars[j] == "`" {
                        var closing = 1
                        while j + closing < chars.count, chars[j + closing] == "`" { closing += 1 }
                        if closing == run { end = j + closing; break }
                        j += closing
                    } else {
                        j += 1
                    }
                }
                let stop = end ?? i + run
                result += String(chars[i..<stop])
                i = stop
                continue
            }
            if c == "~",
               i == 0 || (chars[i - 1] != "~" && chars[i - 1] != "\\"),
               i + 1 == chars.count || chars[i + 1] != "~" {
                result += "\\~"
            } else {
                result.append(c)
            }
            i += 1
        }
        return result
    }

    // MARK: - Parsing

    private enum Block {
        case paragraph(String)
        case heading(Int, String)
        case code(String, String?)
        case list([ListItem])
        case image(ImageRef)
        /// A file on the Hermes host, from a `MEDIA:<path>` tag.
        case media(String)
        case quote(String)
        case table(Table)
        case divider
    }

    private struct ListItem {
        /// Nesting depth, 0 for a top-level item.
        let level: Int
        /// The number shown for an ordered item; nil for a bullet.
        let number: Int?
        /// A GitHub task-list item: `[ ]` (false) or `[x]` (true).
        let checked: Bool?
        var text: String

        var marker: String {
            if let checked { return checked ? "☑︎" : "☐" }
            if let number { return "\(number)." }
            return ["•", "◦", "▪︎"][level % 3]
        }
    }

    private struct Table {
        let headers: [String]
        let alignments: [ColumnAlignment]
        let rows: [[String]]

        /// Columns without an explicit alignment (or beyond the delimiter row)
        /// fall back to leading, as in GitHub-flavoured Markdown.
        func alignment(_ column: Int) -> ColumnAlignment {
            column < alignments.count ? alignments[column] : .leading
        }
    }

    private enum ColumnAlignment {
        case leading, center, trailing

        var horizontal: HorizontalAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }

        var text: TextAlignment {
            switch self {
            case .leading: .leading
            case .center: .center
            case .trailing: .trailing
            }
        }
    }

    private var blocks: [Block] {
        cache.blocks(for: text, parse: parse)
    }

    /// Holds the last parse. A view update that doesn't change the text — a
    /// sibling redrawing, the streaming spinner appearing or going away, a
    /// scroll bringing the row back — then costs nothing instead of re-walking
    /// the whole answer.
    private final class ParseCache {
        private var text: String?
        private var parsed: [Block] = []

        func blocks(for text: String, parse: (String) -> [Block]) -> [Block] {
            if self.text == text { return parsed }
            let blocks = parse(text)
            self.text = text
            self.parsed = blocks
            return blocks
        }
    }

    private func parse(_ text: String) -> [Block] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [Block] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            // Indented code block: four spaces in, outside a paragraph or a
            // list. Answers use it to set out a table in lined-up columns.
            if indentWidth(lines[index]) >= 4 {
                let block = parseIndentedBlock(lines, &index)
                blocks.append(alignedTable(block).map(Block.table) ?? .code(block.joined(separator: "\n"), nil))
                continue
            }

            // Fenced code block (tolerates an unterminated fence while streaming)
            if isFence(trimmed) {
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !isFence(lines[index].trimmingCharacters(in: .whitespaces)) {
                    codeLines.append(lines[index])
                    index += 1
                }
                index += 1 // skip closing fence (or end of text)
                blocks.append(.code(codeLines.joined(separator: "\n"), language.isEmpty ? nil : language))
                continue
            }

            // Table: a header row followed by a `|---|:--:|` delimiter row
            if startsTable(lines, index) {
                let headers = splitRow(trimmed)
                let alignments = columnAlignments(lines[index + 1].trimmingCharacters(in: .whitespaces))
                index += 2
                var rows: [[String]] = []
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !next.isEmpty, next.contains("|") else { break }
                    rows.append(normalize(splitRow(next), to: headers.count))
                    index += 1
                }
                blocks.append(.table(Table(headers: headers, alignments: alignments, rows: rows)))
                continue
            }

            let bareRows = bareTableLength(lines, index)
            if bareRows > 0 {
                let rows = lines[index ..< index + bareRows].map { splitRow($0.trimmingCharacters(in: .whitespaces)) }
                blocks.append(.table(Table(headers: rows[0], alignments: [], rows: Array(rows.dropFirst()))))
                index += bareRows
                continue
            }

            if let level = headingLevel(trimmed) {
                let content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level, content))
                index += 1
                continue
            }

            if isDivider(trimmed) {
                blocks.append(.divider)
                index += 1
                continue
            }

            if listMarker(lines[index]) != nil {
                blocks.append(.list(parseList(lines, &index)))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines = [quoteContent(trimmed)]
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix(">") else { break }
                    quoteLines.append(quoteContent(next))
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Paragraph: consecutive lines until a blank line or another block
            var paragraphLines = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty || startsBlock(next) || startsTable(lines, index) || bareTableLength(lines, index) > 0 { break }
                paragraphLines.append(next)
                index += 1
            }
            // Images and the agent's files get a block of their own; whatever
            // text surrounds them stays a paragraph.
            let (withoutImages, images) = extractImages(paragraphLines.joined(separator: "\n"))
            let (remaining, media) = extractMedia(withoutImages)
            if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(remaining.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            blocks.append(contentsOf: images.map(Block.image))
            blocks.append(contentsOf: media)
        }

        return blocks
    }

    // MARK: - Lists

    /// Reads one list, nested levels included, starting at `index`.
    ///
    /// Levels come from indentation, compared with the items before rather
    /// than counted in fixed steps, since answers indent by two, three or four
    /// spaces. The list survives blank lines between its items, which is how
    /// models usually write them. Ordered items keep the number they were
    /// written with, except that a number that doesn't move on from its
    /// predecessor — every item written as `1.` — counts up instead.
    private func parseList(_ lines: [String], _ index: inout Int) -> [ListItem] {
        var items: [ListItem] = []
        var indents: [Int] = []
        var lastNumber: [Int: Int] = [:]
        var afterBlank = false

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count,
                      listMarker(lines[next]) != nil || indentWidth(lines[next]) >= 2
                else { break }
                index = next
                afterBlank = true
                continue
            }

            if let marker = listMarker(line) {
                while let top = indents.last, marker.indent < top { indents.removeLast() }
                if indents.last.map({ marker.indent > $0 }) ?? true { indents.append(marker.indent) }
                let level = indents.count - 1
                lastNumber = lastNumber.filter { $0.key <= level }
                var number = marker.number
                if let written = number {
                    if let previous = lastNumber[level], written <= previous { number = previous + 1 }
                    lastNumber[level] = number
                } else {
                    lastNumber[level] = nil
                }
                let (checked, text) = taskState(marker.text)
                items.append(ListItem(level: level, number: number, checked: checked, text: text))
                index += 1
                afterBlank = false
                continue
            }

            // A continuation of the item above: indented under it, or running
            // straight on from it with no blank line in between.
            let continues = indentWidth(line) >= 2 || (!afterBlank && !startsBlock(trimmed))
            guard let last = items.indices.last, continues, !isFence(trimmed) else { break }
            items[last].text += "\n" + trimmed
            index += 1
            afterBlank = false
        }
        return items
    }

    private func listMarker(_ line: String) -> (indent: Int, number: Int?, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let text = unorderedItem(trimmed) { return (indentWidth(line), nil, text) }
        if let (number, text) = orderedItem(trimmed) { return (indentWidth(line), number, text) }
        return nil
    }

    /// Reads an indented code block from `index`, its lines four columns
    /// shallower. Blank lines stay in it when more indented lines follow.
    private func parseIndentedBlock(_ lines: [String], _ index: inout Int) -> [String] {
        var block: [String] = []
        while index < lines.count {
            if lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                var next = index + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                guard next < lines.count, indentWidth(lines[next]) >= 4 else { break }
                block += Array(repeating: "", count: next - index)
                index = next
                continue
            }
            guard indentWidth(lines[index]) >= 4 else { break }
            var line = Substring(lines[index])
            var width = 0
            while width < 4, let first = line.first {
                width += first == "\t" ? 4 : 1
                line = line.dropFirst()
            }
            block.append(String(line))
            index += 1
        }
        return block
    }

    private func indentWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }

    /// GitHub task-list items: `[ ]` and `[x]` show a box in place of the bullet.
    private func taskState(_ text: String) -> (Bool?, String) {
        if text.hasPrefix("[ ] ") { return (false, String(text.dropFirst(4))) }
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return (true, String(text.dropFirst(4))) }
        return (nil, text)
    }

    // MARK: - Images

    /// `![alt](url)`, with an optional title. Group 1 is the alt text, 2 the URL.
    private static let imagePattern = #"!\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#

    /// `[![alt](url)](link)`: an image that is itself a link.
    private static let linkedImagePattern = #"\[\s*(!\[[^\]]*\]\([^)]*\))\s*\]\(\s*<?([^\s)>]+)>?[^)]*\)"#

    /// Hermes's `MEDIA:<path>` tag for a file it produced on its own host,
    /// tolerating a code span around it. Group 1 is the path (or URL), 2 the
    /// file name.
    private static let mediaPattern = #"`?MEDIA:((?:[^\s`]*/)?([^\s`/]+?))[.,;:!?)\]*_'"]*(?=[\s`]|$)`?"#

    /// Lifts the `MEDIA:` tags out of a paragraph. A path becomes a file block;
    /// a web address, an image like any other.
    private func extractMedia(_ text: String) -> (String, [Block]) {
        guard text.contains("MEDIA:") else { return (text, []) }
        let pattern = try! NSRegularExpression(pattern: Self.mediaPattern)
        var remaining = ""
        var blocks: [Block] = []
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text),
                  let pathRange = Range(match.range(at: 1), in: text),
                  let nameRange = Range(match.range(at: 2), in: text)
            else { continue }
            let path = String(text[pathRange])
            if path.hasPrefix("/") {
                blocks.append(.media(path))
            } else if let url = URL(string: path), url.scheme == "http" || url.scheme == "https" {
                blocks.append(.image(ImageRef(url: url, alt: String(text[nameRange]), link: nil)))
            } else {
                continue
            }
            remaining += text[cursor..<whole.lowerBound]
            cursor = whole.upperBound
        }
        remaining += text[cursor...]
        return (remaining, blocks)
    }

    /// Lifts the images out of a paragraph, returning what text is left and the
    /// images in the order they appeared.
    private func extractImages(_ text: String) -> (String, [ImageRef]) {
        guard text.contains("![") else { return (text, []) }
        // Linked images first in the alternation, so the outer link is taken
        // with its image instead of leaving a stray `[](link)` behind.
        let pattern = try! NSRegularExpression(pattern: "\(Self.linkedImagePattern)|\(Self.imagePattern)")
        var remaining = ""
        var images: [ImageRef] = []
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text) else { continue }
            let image: ImageRef?
            if let inner = Range(match.range(at: 1), in: text), let link = Range(match.range(at: 2), in: text) {
                image = imageRef(String(text[inner]), link: URL(string: String(text[link])))
            } else {
                image = imageRef(String(text[whole]), link: nil)
            }
            guard let image else { continue }
            remaining += text[cursor..<whole.lowerBound]
            images.append(image)
            cursor = whole.upperBound
        }
        remaining += text[cursor...]
        return (remaining, images)
    }

    private func imageRef(_ markdown: String, link: URL?) -> ImageRef? {
        let bare = try! NSRegularExpression(pattern: Self.imagePattern)
        guard let match = bare.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
              let altRange = Range(match.range(at: 1), in: markdown),
              let urlRange = Range(match.range(at: 2), in: markdown),
              let url = URL(string: String(markdown[urlRange]))
        else { return nil }
        return ImageRef(url: url, alt: String(markdown[altRange]), link: link)
    }

    private func startsBlock(_ trimmed: String) -> Bool {
        isFence(trimmed)
            || headingLevel(trimmed) != nil
            || isDivider(trimmed)
            || listMarker(trimmed) != nil
            || trimmed.hasPrefix(">")
    }

    private func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```")
    }

    private func headingLevel(_ trimmed: String) -> Int? {
        var level = 0
        for character in trimmed {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return level
    }

    private func isDivider(_ trimmed: String) -> Bool {
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private func unorderedItem(_ trimmed: String) -> String? {
        for marker in ["- ", "* ", "+ "] where trimmed.hasPrefix(marker) {
            return String(trimmed.dropFirst(marker.count))
        }
        return nil
    }

    private func orderedItem(_ trimmed: String) -> (Int, String)? {
        guard let match = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression),
              let number = Int(trimmed[..<match.upperBound].prefix { $0.isNumber })
        else { return nil }
        return (number, String(trimmed[match.upperBound...]))
    }

    // MARK: - Tables

    /// A table only starts where a row of cells is directly followed by a
    /// delimiter row, so a stray `|` in a sentence is still a paragraph.
    private func startsTable(_ lines: [String], _ index: Int) -> Bool {
        guard index + 1 < lines.count else { return false }
        guard lines[index].contains("|") else { return false }
        return isDelimiterRow(lines[index + 1].trimmingCharacters(in: .whitespaces))
    }

    /// Some answers lay a table out without the delimiter row: a header,
    /// then rows, padded with spaces and split by `|`. Read that as a table
    /// (first line as the header) only when at least three lines in a row
    /// split into the same number of cells, which prose with a stray `|`
    /// doesn't. Returns how many lines it spans, or 0.
    private func bareTableLength(_ lines: [String], _ index: Int) -> Int {
        var count = 0
        var columns: Int?
        while index + count < lines.count {
            let trimmed = lines[index + count].trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("|"), !startsBlock(trimmed) else { break }
            let cells = splitRow(trimmed).count
            guard cells >= 2, columns == nil || columns == cells else { break }
            columns = cells
            count += 1
        }
        return count >= 3 ? count : 0
    }

    /// A table set out in an indented code block, its columns lined up with
    /// spaces instead of split by `|`. A column break is wherever every line
    /// has two spaces or more at the same place; with at least three lines,
    /// two columns or more and no empty cell below the header, the block reads
    /// as a table, its first line the header. Anything else stays code.
    private func alignedTable(_ lines: [String]) -> Table? {
        let rows = lines.map { Array($0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)) }
        guard rows.count >= 3, rows.allSatisfy({ $0.first.map { $0 != " " && $0 != "\t" } ?? false }) else { return nil }

        let width = rows.map(\.count).max() ?? 0
        var starts = [0]
        var gap = 0
        for position in 0..<width {
            if rows.allSatisfy({ position >= $0.count || $0[position] == " " }) {
                gap += 1
            } else {
                if gap >= 2 { starts.append(position) }
                gap = 0
            }
        }
        guard starts.count >= 2 else { return nil }

        let cells = rows.map { row in
            starts.indices.map { column in
                let start = min(starts[column], row.count)
                let end = column + 1 < starts.count ? min(starts[column + 1], row.count) : row.count
                return String(row[start..<end]).trimmingCharacters(in: .whitespaces)
            }
        }
        guard cells.dropFirst().allSatisfy({ !$0.contains("") }) else { return nil }
        return Table(headers: cells[0], alignments: [], rows: Array(cells.dropFirst()))
    }

    private func isDelimiterRow(_ trimmed: String) -> Bool {
        guard trimmed.contains("-"), trimmed.contains("|") else { return false }
        let cells = splitRow(trimmed)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { ":-".contains($0) }
        }
    }

    private func columnAlignments(_ delimiterRow: String) -> [ColumnAlignment] {
        splitRow(delimiterRow).map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    /// Splits a row on unescaped pipes, dropping only the optional outer ones
    /// so that a genuinely empty leading or trailing cell survives.
    private func splitRow(_ trimmed: String) -> [String] {
        var body = Substring(trimmed)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body = body.dropLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Pads short rows and drops extra cells so every row matches the header,
    /// which keeps the grid rectangular while an answer is still streaming.
    private func normalize(_ cells: [String], to count: Int) -> [String] {
        if cells.count < count {
            return cells + Array(repeating: "", count: count - cells.count)
        }
        return Array(cells.prefix(count))
    }

    private func quoteContent(_ trimmed: String) -> String {
        var content = trimmed.dropFirst() // ">"
        if content.hasPrefix(" ") { content = content.dropFirst() }
        return String(content)
    }
}

// MARK: - Table layout

/// Lays a table's cells out row by row, `columns` to a row. Each column is as
/// wide as its widest cell while the table fits the width on offer; when it
/// doesn't, the widest columns are narrowed together and their text wraps,
/// though none below `floor`. Its ideal width is the table at that floor, so
/// a `ViewThatFits` only turns to scrolling when even that is too wide.
private struct TableLayout: Layout {
    let columns: Int
    let floor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(proposal.width, subviews)
        return CGSize(width: widths.reduce(0, +), height: rowHeights(widths, subviews).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in rowHeights(widths, subviews).enumerated() {
            var x = bounds.minX
            for column in 0..<columns {
                let index = row * columns + column
                guard index < subviews.count else { break }
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[column], height: height))
                x += widths[column]
            }
            y += height
        }
    }

    private func columnWidths(_ available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        var natural = Array(repeating: CGFloat(0), count: columns)
        for (index, cell) in subviews.enumerated() {
            natural[index % columns] = max(natural[index % columns], cell.sizeThatFits(.unspecified).width)
        }
        let narrowest = natural.map { min($0, floor) }
        guard let available else { return narrowest }
        if natural.reduce(0, +) <= available { return natural }

        // The widest a column may be for them all to fit, found by halving.
        func widths(cappedAt cap: CGFloat) -> [CGFloat] {
            zip(natural, narrowest).map { natural, narrowest in max(narrowest, min(natural, cap)) }
        }
        var low: CGFloat = 0
        var high = natural.max() ?? 0
        for _ in 0..<20 {
            let cap = (low + high) / 2
            if widths(cappedAt: cap).reduce(0, +) <= available { low = cap } else { high = cap }
        }
        return widths(cappedAt: low)
    }

    private func rowHeights(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            (start..<min(start + columns, subviews.count)).map { index in
                subviews[index].sizeThatFits(ProposedViewSize(width: widths[index - start], height: nil)).height
            }.max() ?? 0
        }
    }
}

/// Fades a horizontal scroll view's edges out wherever there is more to
/// scroll to that side. Without iOS 18 or macOS 15 to report the scroll
/// position, the scroll bar alone has to say so.
private struct ScrollEdgeFade: ViewModifier {
    @State private var moreBefore = false
    @State private var moreAfter = false

    func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onScrollGeometryChange(for: [Bool].self) { geometry in
                    let offset = geometry.contentOffset.x + geometry.contentInsets.leading
                    return [offset > 1, offset + geometry.containerSize.width < geometry.contentSize.width - 1]
                } action: { _, edges in
                    moreBefore = edges[0]
                    moreAfter = edges[1]
                }
                .mask {
                    HStack(spacing: 0) {
                        LinearGradient(colors: [.black.opacity(moreBefore ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(moreAfter ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 28)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: moreBefore)
                .animation(.easeOut(duration: 0.15), value: moreAfter)
        } else {
            content
        }
    }
}

// MARK: - Code blocks

/// A fenced code block, with the copy button such a block always wants — the
/// surrounding answer's Copy takes the whole reply, which is rarely what you
/// are after when the answer contains a command or a snippet.
private struct CodeBlock: View {
    let code: String

    @State private var copied = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .readingFont(.callout, design: .monospaced)
                .textSelection(.enabled)
                .padding(10)
                // Keeps the last column clear of the button parked over it.
                .padding(.trailing, 34)
        }
        .background(Color.raisedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .topTrailing) {
            Button {
                Clipboard.copy(code)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Color.accentColor : .secondary)
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .padding(6)
            .animation(.default, value: copied)
        }
    }
}

// MARK: - Images

private struct ImageRef {
    let url: URL
    let alt: String
    /// Where tapping the image goes, when it was written as a link.
    let link: URL?
}

/// An image in an answer. Web images load from their URL; `data:` URLs — what
/// Hermes inlines for images it made itself — are decoded in place. One that
/// can't be shown (an SVG, a dead link) falls back to its alt text.
private struct MarkdownImage: View {
    let image: ImageRef

    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                let target = image.link ?? image.url
                if target.scheme == "http" || target.scheme == "https" { openURL(target) }
            }
            .accessibilityLabel(image.alt.isEmpty ? "Image" : image.alt)
    }

    @ViewBuilder
    private var content: some View {
        if image.url.scheme == "data" {
            if let decoded = Self.decodeDataURL(image.url) {
                picture(Image(platformImage: decoded))
            } else {
                fallback
            }
        } else {
            AsyncImage(url: image.url) { phase in
                switch phase {
                case .success(let loaded):
                    picture(loaded)
                case .failure:
                    fallback
                default:
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.raisedBackground)
                        .frame(height: 180)
                        .overlay { ProgressView() }
                }
            }
        }
    }

    private func picture(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var fallback: some View {
        Label(image.alt.isEmpty ? (image.url.host() ?? "Image") : image.alt, systemImage: "photo")
            .readingFont(.subheadline)
            .foregroundStyle(.secondary)
    }

    private static func decodeDataURL(_ url: URL) -> PlatformImage? {
        let string = url.absoluteString
        guard let comma = string.firstIndex(of: ","),
              string[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(string[string.index(after: comma)...]))
        else { return nil }
        return PlatformImage(data: data)
    }
}

// MARK: - The agent's files

extension EnvironmentValues {
    /// The client of the thread on screen, which fetches the files answers point to.
    @Entry var hermesClient: HermesClient?
}

/// A file the agent made on its own host and pointed to with `MEDIA:<path>`,
/// fetched with the profile's key. An image shows in place; any other file is
/// a row that opens it in Quick Look, as does tapping the image. A server that
/// doesn't hand out the agent's files, or a file since deleted, leaves its name.
private struct MediaFile: View {
    let path: String

    @Environment(\.hermesClient) private var client
    @State private var image: PlatformImage?
    @State private var isLoading = false
    @State private var isUnavailable = false
    @State private var preview: URL?

    /// Fetched files, so a row scrolled away and back doesn't fetch again.
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic"]

    private var name: String { (path as NSString).lastPathComponent }

    private var isImage: Bool {
        Self.imageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if isUnavailable {
                unavailable
            } else if isImage {
                picture
            } else {
                fileRow
            }
        }
        .quickLookPreview($preview)
        .task(id: path) {
            guard isImage, image == nil else { return }
            if let data = await fetch(), let decoded = PlatformImage(data: data) {
                image = decoded
            } else {
                isUnavailable = true
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let image {
            Image(platformImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, maxHeight: 360, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: open)
                .accessibilityLabel(name)
                .accessibilityAddTraits(.isButton)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.raisedBackground)
                .frame(height: 180)
                .overlay { ProgressView() }
        }
    }

    private var fileRow: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .readingFont(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.raisedBackground, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(name, systemImage: isImage ? "photo" : "doc")
            Text("Not available from this server.")
                .readingFont(.caption)
        }
        .readingFont(.subheadline)
        .foregroundStyle(.secondary)
    }

    /// Writes the file out under its own name, for Quick Look to open.
    private func open() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            guard let data = await fetch() else {
                isUnavailable = true
                return
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Media", isDirectory: true)
            let file = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
                preview = file
            } catch {
                isUnavailable = true
            }
        }
    }

    private func fetch() async -> Data? {
        guard let client else { return nil }
        let key = (client.baseURL.absoluteString + path) as NSString
        if let cached = Self.cache.object(forKey: key) { return cached as Data }
        guard let data = try? await client.file(at: path) else { return nil }
        Self.cache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }
}

// MARK: - Inline text

/// A run of inline Markdown. On the Mac, the pointer turns into a hand over
/// its links, as over any link in AppKit.
///
/// `Text` reports no hover per range, so a text with links is assembled run by
/// run, the links tagged, and a renderer notes where the tagged runs land as it
/// draws them; the hover is checked against that.
private struct InlineText: View {
    let content: AttributedString

    var body: some View {
        #if os(macOS)
        if #available(macOS 15, *), content.runs.contains(where: { $0.link != nil }) {
            LinkHoverText(content: content)
        } else {
            Text(content)
        }
        #else
        Text(content)
        #endif
    }
}

#if os(macOS)
@available(macOS 15, *)
private struct LinkHoverText: View {
    let content: AttributedString

    @State private var frames = LinkFrames()
    @State private var overLink = false

    var body: some View {
        tagged
            .textRenderer(LinkFrameRecorder(frames: frames))
            // Set on every move rather than through `pointerStyle`: selectable
            // text keeps its I-beam over any style a view asks for. AppKit
            // also re-applies the I-beam as the pointer moves, so the hand is
            // set a turn later, after it; and off a link inside the same text,
            // nothing else would bring the I-beam back.
            .onContinuousHover { phase in
                guard case .active(let location) = phase else {
                    overLink = false
                    return
                }
                let isOver = frames.rects.contains { $0.insetBy(dx: -1, dy: -2).contains(location) }
                if isOver {
                    DispatchQueue.main.async { NSCursor.pointingHand.set() }
                } else if overLink {
                    NSCursor.iBeam.set()
                }
                overLink = isOver
            }
    }

    private var tagged: Text {
        content.runs.reduce(Text(verbatim: "")) { text, run in
            let piece = Text(AttributedString(content[run.range]))
            return text + (run.link == nil ? piece : piece.customAttribute(LinkRun()))
        }
    }
}

/// Marks a run of text as a link, for the renderer to find.
@available(macOS 15, *)
private struct LinkRun: TextAttribute {}

/// Where the links were last drawn, in the text's own coordinates. A class, so
/// drawing can update it without invalidating the view it is drawing.
private final class LinkFrames {
    var rects: [CGRect] = []
}

@available(macOS 15, *)
private struct LinkFrameRecorder: TextRenderer {
    let frames: LinkFrames

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var rects: [CGRect] = []
        for line in layout {
            for run in line {
                if run[LinkRun.self] != nil {
                    rects.append(run.typographicBounds.rect)
                }
                context.draw(run)
            }
        }
        frames.rects = rects
    }
}
#endif
