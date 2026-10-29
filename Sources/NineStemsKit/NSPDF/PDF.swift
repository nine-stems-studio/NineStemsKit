import Foundation
import CoreGraphics
import CoreText
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

/// Supported portrait paper sizes, in PDF points (72 points per inch).
public enum PDFPaper: String, Sendable {
    /// ISO A4, 210 by 297 mm.
    case a4
    /// US Letter, 8.5 by 11 inches.
    case letter
    /// Physical page dimensions in points.
    public var size: CGSize {
        switch self { case .a4: CGSize(width: 595.276, height: 841.890); case .letter: CGSize(width: 612, height: 792) }
    }
}

/// Local image data and its printed caption. Images are embedded, never fetched.
public struct PDFPhoto: Sendable {
    /// Encoded image bytes (such as PNG or JPEG).
    public let data: Data
    /// Caption printed below the image.
    public let caption: String
    /// Creates an image entry.
    public init(data: Data, caption: String) { self.data = data; self.caption = caption }
}

/// App-authored content supported by the template renderer.
public enum PDFBlock: Sendable {
    /// A section title, wrapped as needed and kept with the useful start of the next block when it fits a page.
    case title(String)
    /// A paragraph, flowing over page boundaries.
    case paragraph(String)
    /// One to twelve equal-width columns, with repeated headers. Only rows taller than a fresh table page may split.
    case table(headers: [String], rows: [[String]])
    /// An image grid with one to four columns. Captions may continue onto following pages.
    case photos([PDFPhoto], columns: Int)
    /// A labelled signature line and optional locally supplied signature image.
    case signature(label: String, image: Data?)
    /// Starts a new page. Consecutive or trailing breaks intentionally create empty pages.
    case pageBreak
}

/// A complete, deterministic PDF input. Supply a fixed generatedAt value for snapshots.
public struct PDFDocumentTemplate: Sendable {
    /// Document title printed at the start and stored in PDF metadata.
    public let title: String
    /// Running page header, fitting within two lines at the template's caption size.
    public let header: String
    /// Running page footer, wrapped to two lines and truncated with an ellipsis when longer.
    public let footer: String
    /// Explicit generation timestamp, printed in UTC on each page.
    public let generatedAt: Date
    /// Paper format.
    public let paper: PDFPaper
    /// Content in reading order.
    public let blocks: [PDFBlock]
    /// Creates a document; generation time defaults to now for normal exports.
    public init(title: String, header: String = "", footer: String = "", generatedAt: Date = Date(),
                paper: PDFPaper = .a4, blocks: [PDFBlock]) {
        self.title = title; self.header = header; self.footer = footer
        self.generatedAt = generatedAt; self.paper = paper; self.blocks = blocks
    }
}

/// Input and rendering failures. Invalid content is never silently omitted.
public enum PDFRenderError: Error, Equatable {
    /// Table columns are missing, exceed twelve, or row widths do not match the header.
    case invalidTable
    /// The repeated table header cannot fit on a page.
    case oversizedTableHeader
    /// A running header exceeds its two-line reserved area.
    case oversizedRunningText
    /// A photo grid requires one to four columns.
    case invalidColumns
    /// Supplied image data cannot be decoded.
    case invalidImage
    /// CoreGraphics could not create a PDF context.
    case contextCreationFailed
}

private struct TextStyle {
    var size: CGFloat = 11
    var bold = false
    var grey: CGFloat = 0.15
    var maxWidth: CGFloat?
    var lineHeight: CGFloat { size * 1.4 }
    var font: CTFont { CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil) }
    func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: grey, alpha: 1)
        ])
    }
}

private enum Mark {
    case text(String, CGPoint, TextStyle)
    case fill(CGRect, CGFloat)
    case line(CGPoint, CGPoint)
    case image(CGImage, CGRect)
}

private func wrapped(_ text: String, width: CGFloat, style: TextStyle) -> [String] {
    var lines: [String] = []
    for paragraph in text.components(separatedBy: "\n") {
        if paragraph.isEmpty { lines.append(""); continue }
        let string = paragraph as NSString
        let typesetter = CTTypesetterCreateWithAttributedString(style.attributed(paragraph))
        var index = 0
        while index < string.length {
            let suggested = CTTypesetterSuggestLineBreak(typesetter, index, Double(width))
            let count = suggested > 0 ? suggested : string.rangeOfComposedCharacterSequence(at: index).length
            lines.append(string.substring(with: NSRange(location: index, length: count)))
            index += count
        }
    }
    return lines
}

private func decoded(_ data: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400
          ] as CFDictionary) else { throw PDFRenderError.invalidImage }
    return image
}

/// Shared measurements for drawing tables and keeping a preceding title with the first row.
private struct TableLayout {
    let padding: CGFloat = 6
    let headerStyle = TextStyle(size: 10, bold: true)
    let rowStyle = TextStyle(size: 10)
    let cellWidth: CGFloat
    let headerLines: [[String]]
    let headerHeight: CGFloat
    let pageHeight: CGFloat
    init(headers: [String], rows: [[String]], width: CGFloat, pageHeight: CGFloat) throws {
        guard !headers.isEmpty, headers.count <= 12, rows.allSatisfy({ $0.count == headers.count }) else {
            throw PDFRenderError.invalidTable
        }
        let cellWidth = width / CGFloat(headers.count)
        self.cellWidth = cellWidth
        self.pageHeight = pageHeight
        let textWidth = cellWidth - padding * 2, style = headerStyle
        headerLines = headers.map { wrapped($0, width: textWidth, style: style) }
        headerHeight = CGFloat(headerLines.map(\.count).max() ?? 1) * headerStyle.lineHeight + padding * 2
        guard headerHeight + minimumRowHeight < pageHeight else { throw PDFRenderError.oversizedTableHeader }
    }
    var minimumRowHeight: CGFloat { rowStyle.lineHeight + padding * 2 }
    var rowCapacity: CGFloat { pageHeight - headerHeight }
    func lines(_ row: [String]) -> [[String]] {
        row.map { wrapped($0, width: cellWidth - padding * 2, style: rowStyle) }
    }
    func height(_ columns: [[String]]) -> CGFloat {
        CGFloat(columns.map(\.count).max() ?? 1) * rowStyle.lineHeight + padding * 2
    }
    func startHeight(rows: [[String]]) -> CGFloat {
        guard let first = rows.first else { return headerHeight }
        let firstHeight = height(lines(first))
        return headerHeight + (firstHeight <= rowCapacity ? firstHeight : minimumRowHeight)
    }
}

private struct Layout {
    let document: PDFDocumentTemplate
    var pages: [[Mark]] = [[]]
    var y: CGFloat = 82
    let margin: CGFloat = 40
    var width: CGFloat { document.paper.size.width - margin * 2 }
    var bottom: CGFloat { document.paper.size.height - 76 }
    var pageHeight: CGFloat { bottom - 82 }
    mutating func add(_ mark: Mark) { pages[pages.count - 1].append(mark) }
    mutating func newPage() { pages.append([]); y = 82 }
    mutating func ensure(_ height: CGFloat) { if y + height > bottom { newPage() } }
    mutating func text(_ text: String, style: TextStyle = TextStyle()) {
        for line in wrapped(text, width: width, style: style) {
            ensure(style.lineHeight)
            add(.text(line, CGPoint(x: margin, y: y), style)); y += style.lineHeight
        }
        y += 10
    }
    mutating func table(headers: [String], rows: [[String]]) throws {
        let metrics = try TableLayout(headers: headers, rows: rows, width: width, pageHeight: pageHeight)
        let cellWidth = metrics.cellWidth, padding = metrics.padding
        let headerStyle = metrics.headerStyle, rowStyle = metrics.rowStyle
        let headerLines = metrics.headerLines, headerHeight = metrics.headerHeight
        func cellMarks(_ columns: [[String]], start: Int, count: Int, top: CGFloat, style: TextStyle) -> [Mark] {
            var marks: [Mark] = []
            for (column, lines) in columns.enumerated() {
                // All cells share the tallest cell's offset; exhausted cells stay blank.
                guard start < lines.count else { continue }
                for line in start..<min(start + count, lines.count) {
                    marks.append(.text(lines[line], CGPoint(x: margin + CGFloat(column) * cellWidth + padding,
                                                           y: top + padding + CGFloat(line - start) * style.lineHeight), style))
                }
            }
            return marks
        }
        func headerMarks(top: CGFloat) -> [Mark] {
            [.fill(CGRect(x: margin, y: top, width: width, height: headerHeight), 0.92)]
                + cellMarks(headerLines, start: 0, count: headerLines.map(\.count).max() ?? 1, top: top, style: headerStyle)
        }
        ensure(metrics.startHeight(rows: rows))
        for mark in headerMarks(top: y) { add(mark) }; y += headerHeight
        for row in rows {
            let columns = metrics.lines(row)
            let lineCount = columns.map(\.count).max() ?? 1
            let rowHeight = metrics.height(columns)
            // A fresh table page includes its repeated header. Keep every row that fits
            // that area intact; only intrinsically oversized rows use the line splitter.
            if rowHeight <= metrics.rowCapacity, y + rowHeight > bottom {
                newPage(); for mark in headerMarks(top: y) { add(mark) }; y += headerHeight
            }
            var offset = 0
            while offset < lineCount {
                var available = Int((bottom - y - padding * 2) / rowStyle.lineHeight)
                if available < 1 {
                    newPage(); for mark in headerMarks(top: y) { add(mark) }; y += headerHeight
                    available = Int((bottom - y - padding * 2) / rowStyle.lineHeight)
                }
                let count = min(available, lineCount - offset)
                for mark in cellMarks(columns, start: offset, count: count, top: y, style: rowStyle) { add(mark) }
                y += CGFloat(count) * rowStyle.lineHeight + padding * 2
                add(.line(CGPoint(x: margin, y: y), CGPoint(x: margin + width, y: y)))
                offset += count
            }
        }
        y += 14
    }
    mutating func photos(_ photos: [PDFPhoto], columns: Int) throws {
        guard (1...4).contains(columns) else { throw PDFRenderError.invalidColumns }
        let gap: CGFloat = 10, height: CGFloat = 126
        let cellWidth = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let style = TextStyle(size: 9)
        for start in stride(from: 0, to: photos.count, by: columns) {
            let row = Array(photos[start..<min(start + columns, photos.count)])
            ensure(height + style.lineHeight + 8)
            let top = y
            var captions: [[String]] = []
            for (index, photo) in row.enumerated() {
                let box = CGRect(x: margin + CGFloat(index) * (cellWidth + gap), y: top, width: cellWidth, height: height)
                add(.fill(box, 0.96)); add(.image(try decoded(photo.data), box.insetBy(dx: 4, dy: 4)))
                captions.append(wrapped(photo.caption, width: cellWidth, style: style))
            }
            y += height + 6
            for line in 0..<(captions.map(\.count).max() ?? 0) {
                ensure(style.lineHeight)
                for (index, caption) in captions.enumerated() where caption.indices.contains(line) {
                    add(.text(caption[line], CGPoint(x: margin + CGFloat(index) * (cellWidth + gap), y: y), style))
                }
                y += style.lineHeight
            }
            y += 14
        }
    }
    mutating func signature(label: String, image: Data?) throws {
        let style = TextStyle(size: 10)
        let labelLines = wrapped(label, width: width, style: style)
        // Long labels flow before the bounded signature area rather than being clipped.
        if labelLines.count > 5 { text(label, style: style) }
        let printed = labelLines.count > 5 ? [] : labelLines
        ensure(94 + CGFloat(printed.count) * style.lineHeight)
        for line in printed { add(.text(line, CGPoint(x: margin, y: y), style)); y += style.lineHeight }
        if let image { add(.image(try decoded(image), CGRect(x: margin, y: y + 5, width: 220, height: 64))) }
        y += 78; add(.line(CGPoint(x: margin, y: y), CGPoint(x: margin + 240, y: y))); y += 16
    }
    /// Minimum useful start of the next block, using the same measurements as its renderer.
    func startHeight(of block: PDFBlock) throws -> CGFloat {
        switch block {
        case .title(let value):
            let style = TextStyle(size: 15, bold: true)
            return CGFloat(wrapped(value, width: width, style: style).count) * style.lineHeight + 10
        case .paragraph: return TextStyle().lineHeight
        case .table(let headers, let rows):
            return try TableLayout(headers: headers, rows: rows, width: width, pageHeight: pageHeight).startHeight(rows: rows)
        case .photos(let values, let columns):
            guard (1...4).contains(columns) else { throw PDFRenderError.invalidColumns }
            return values.isEmpty ? 0 : 126 + TextStyle(size: 9).lineHeight + 8
        case .signature(let label, _):
            let count = wrapped(label, width: width, style: TextStyle(size: 10)).count
            return count > 5 ? 14 : 94 + CGFloat(count) * 14
        case .pageBreak: return 0
        }
    }
    mutating func title(_ value: String, followingHeight: CGFloat) {
        let style = TextStyle(size: 15, bold: true)
        let lines = wrapped(value, width: width, style: style)
        let total = CGFloat(lines.count) * style.lineHeight + 10 + followingHeight
        if total <= pageHeight { ensure(total) }
        for (index, line) in lines.enumerated() {
            // Even a title taller than a page keeps its last line with the next block,
            // provided that useful start itself leaves room for a title line.
            let tail = style.lineHeight + 10 + followingHeight
            ensure(index == lines.count - 1 && tail <= pageHeight ? tail : style.lineHeight)
            add(.text(line, CGPoint(x: margin, y: y), style)); y += style.lineHeight
        }
        y += 10
    }
    mutating func build() throws {
        text(document.title, style: TextStyle(size: 22, bold: true))
        for (index, block) in document.blocks.enumerated() {
            switch block {
            case .title(let value):
                var followingHeight: CGFloat = 0
                // Consecutive section headings stay with the useful start of their content.
                for next in document.blocks.dropFirst(index + 1) {
                    followingHeight += try startHeight(of: next)
                    if case .title = next { continue }
                    break
                }
                title(value, followingHeight: followingHeight)
            case .paragraph(let value): text(value)
            case .table(let headers, let rows): try table(headers: headers, rows: rows)
            case .photos(let values, let columns): try photos(values, columns: columns)
            case .signature(let label, let image): try signature(label: label, image: image)
            case .pageBreak: newPage()
            }
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let stamp = "Generated \(formatter.string(from: document.generatedAt))"
        let small = TextStyle(size: 8, grey: 0.4)
        let header = wrapped(document.header, width: width, style: small)
        guard header.count <= 2 else { throw PDFRenderError.oversizedRunningText }
        for index in pages.indices {
            let pageNumber = "\(index + 1) / \(pages.count)"
            let pageNumberWidth = max(48, CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(small.attributed(pageNumber)), nil, nil, nil)))
            let footerWidth = width - pageNumberWidth - 16
            var footerStyle = small; footerStyle.maxWidth = footerWidth
            let lines = wrapped(document.footer, width: footerWidth, style: small)
            let footer = lines.count <= 2 ? lines : [lines[0], lines.dropFirst().joined()]
            for (line, value) in header.enumerated() {
                pages[index].append(.text(value, CGPoint(x: margin, y: 24 + CGFloat(line) * small.lineHeight), small))
            }
            pages[index].append(.line(CGPoint(x: margin, y: 58), CGPoint(x: margin + width, y: 58)))
            for (line, value) in footer.enumerated() {
                pages[index].append(.text(value, CGPoint(x: margin, y: bottom + 16 + CGFloat(line) * small.lineHeight), footerStyle))
            }
            pages[index].append(.text(stamp, CGPoint(x: margin, y: document.paper.size.height - 24), small))
            pages[index].append(.text(pageNumber, CGPoint(x: margin + width - pageNumberWidth, y: bottom + 16), small))
        }
    }
}

/// Stateless template renderer. UIKit is used on iOS; CoreGraphics enables host-side PDF tests on macOS.
public enum PDFRenderer {
    /// Renders local content, with pagination, repeated table headers, page numbers and a UTC timestamp.
    public static func render(_ document: PDFDocumentTemplate) throws -> Data {
        var layout = Layout(document: document)
        try layout.build()
        let bounds = CGRect(origin: .zero, size: document.paper.size)
        #if canImport(UIKit)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: document.title, kCGPDFContextCreator as String: "NineStemsKit"]
        return UIGraphicsPDFRenderer(bounds: bounds, format: format).pdfData { renderer in
            for page in layout.pages { renderer.beginPage(); draw(page, in: renderer.cgContext) }
        }
        #else
        let data = NSMutableData()
        var mediaBox = bounds
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [kCGPDFContextTitle: document.title] as CFDictionary) else {
            throw PDFRenderError.contextCreationFailed
        }
        for page in layout.pages {
            context.beginPDFPage(nil)
            context.saveGState(); context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
            draw(page, in: context)
            context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
        return data as Data
        #endif
    }
    private static func draw(_ marks: [Mark], in context: CGContext) {
        for mark in marks {
            context.saveGState()
            switch mark {
            case .text(let text, let position, let style):
                var line = CTLineCreateWithAttributedString(style.attributed(text))
                if let width = style.maxWidth {
                    context.clip(to: CGRect(x: position.x, y: position.y, width: width, height: style.lineHeight))
                    if CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) {
                        let ellipsis = "…"
                        let tokenWidth = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(style.attributed(ellipsis)), nil, nil, nil)
                        let typesetter = CTTypesetterCreateWithAttributedString(style.attributed(text))
                        let count = CTTypesetterSuggestClusterBreak(typesetter, 0, max(0, Double(width) - tokenWidth))
                        let prefix = (text as NSString).substring(to: count).trimmingCharacters(in: .whitespacesAndNewlines)
                        // Build one attributed string so PDF text extraction preserves the ellipsis too.
                        line = CTLineCreateWithAttributedString(style.attributed(prefix + ellipsis))
                    }
                }
                context.translateBy(x: position.x, y: position.y + style.size)
                context.scaleBy(x: 1, y: -1); context.textMatrix = .identity; context.textPosition = .zero
                CTLineDraw(line, context)
            case .fill(let rect, let grey):
                context.setFillColor(CGColor(gray: grey, alpha: 1)); context.fill(rect)
            case .line(let from, let to):
                context.setStrokeColor(CGColor(gray: 0.80, alpha: 1)); context.setLineWidth(0.5)
                context.move(to: from); context.addLine(to: to); context.strokePath()
            case .image(let image, let box):
                let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
                let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                let rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
                context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(origin: .zero, size: size))
            }
            context.restoreGState()
        }
    }
}
