import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import SwiftUI
import NSPDF
import NSDesign

private func png(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

private func photo() throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 640,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.08, green: 0.4, blue: 0.34, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
    context.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 10, y: 10, width: 60, height: 80))
    return try png(XCTUnwrap(context.makeImage()))
}

private func pixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try bytes.withUnsafeMutableBytes { buffer in
        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                           bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return bytes
}

private func raster(_ data: Data, page index: Int = 1) throws -> CGImage {
    let document = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: data as CFData)!))
    let page = try XCTUnwrap(document.page(at: index))
    let bounds = page.getBoxRect(.mediaBox)
    let context = try XCTUnwrap(CGContext(data: nil, width: Int(ceil(bounds.width)), height: Int(ceil(bounds.height)),
                                       bitsPerComponent: 8, bytesPerRow: Int(ceil(bounds.width)) * 4,
                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
    context.drawPDFPage(page)
    return try XCTUnwrap(context.makeImage())
}

final class PDFTests: XCTestCase {
    private func example(paper: PDFPaper = .a4) throws -> PDFDocumentTemplate {
        PDFDocumentTemplate(title: "Sample record", header: "NINE STEMS / TEMPLATE DEMO", footer: "Local sample - for review",
                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), paper: paper, blocks: [
            .paragraph("A local document with a table, embedded images and a signature area."),
            .title("Recorded items"), .table(headers: ["Item", "Description"], rows: [["01", "First example"], ["02", "A second example with wrapping text for the template engine."]]),
            .title("Photo grid"), .photos([PDFPhoto(data: try photo(), caption: "Original test illustration A"),
                                           PDFPhoto(data: try photo(), caption: "Original test illustration B")], columns: 2),
            .signature(label: "Reviewed by", image: nil)
        ])
    }
    private func compare(_ image: CGImage, fixture: String) throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(fixture).png")
        if ProcessInfo.processInfo.environment["NSKIT_RECORD_FIXTURES"] == "1" {
            try png(image).write(to: path); return
        }
        let url = try XCTUnwrap(Bundle.module.url(forResource: fixture, withExtension: "png", subdirectory: "Fixtures"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let reference = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, reference.width); XCTAssertEqual(image.height, reference.height)
        guard image.width == reference.width, image.height == reference.height else { return }
        let actual = try pixels(image), expected = try pixels(reference)
        let meanError = zip(actual, expected).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(actual.count * 255)
        XCTAssertLessThan(meanError, 0.002, "Pixel regression against reviewed \(fixture).png")
    }
    func testExamplePDFMatchesReviewedPixels() throws {
        let data = try PDFRenderer.render(example())
        if ProcessInfo.processInfo.environment["NSKIT_RECORD_FIXTURES"] == "1" {
            try data.write(to: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Example.pdf"))
        }
        try compare(raster(data), fixture: "Example")
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 1)
        XCTAssertTrue(document.string?.contains("2023-11-14T22:13:20Z") == true)
    }
    func testBothPaperSizesAndLongTablePaginationPreserveAllContent() throws {
        for paper in [PDFPaper.a4, .letter] {
            let rows = (0..<100).map { ["Row \($0)", String(repeating: "Wrapped content ", count: 8)] }
            let input = PDFDocumentTemplate(title: "Multipage", header: "Repeated header", footer: "Repeated footer",
                                            paper: paper, blocks: [.table(headers: ["Number", "Details"], rows: rows), .signature(label: "Final signature", image: nil)])
            let document = try XCTUnwrap(PDFDocument(data: PDFRenderer.render(input)))
            XCTAssertGreaterThan(document.pageCount, 2)
            XCTAssertEqual(try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).width, paper.size.width, accuracy: 0.02)
            for index in 0..<100 { XCTAssertTrue(document.string?.contains("Row \(index)") == true) }
            XCTAssertTrue(document.string?.contains("Final signature") == true)
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index)?.string)
                XCTAssertTrue(page.contains("Repeated header")); XCTAssertTrue(page.contains("\(index + 1) / \(document.pageCount)"))
            }
        }
    }
    func testOneOversizeRowAndParagraphFlowAcrossPages() throws {
        let long = String(repeating: "content ", count: 1500) + "ENDMARKER"
        let input = PDFDocumentTemplate(title: "Long content", blocks: [.paragraph(long), .table(headers: ["Text"], rows: [[long]])])
        let document = try XCTUnwrap(PDFDocument(data: PDFRenderer.render(input)))
        XCTAssertGreaterThan(document.pageCount, 3)
        XCTAssertEqual(document.string?.components(separatedBy: "ENDMARKER").count, 3)
    }
    private func pageTexts(_ document: PDFDocument) throws -> [String] {
        try (0..<document.pageCount).map { try XCTUnwrap(document.page(at: $0)?.string) }
    }
    private func writeValidation(_ data: Data, name: String, pageCount: Int) throws {
        guard let output = ProcessInfo.processInfo.environment["NSKIT_PDF_VALIDATION_DIR"] else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).pdf"))
        for index in 1...pageCount {
            try png(raster(data, page: index)).write(to: directory.appendingPathComponent("\(name)-\(index).png"))
        }
    }
    func testRoomReportKeepsRowsAndRoomTitlesTogether() throws {
        for paper in [PDFPaper.a4, .letter] {
            var blocks: [PDFBlock] = [.paragraph("Local room observations with multiline condition cells.")]
            var rowTokens: [[String]] = []
            for room in 1...6 {
                blocks.append(.title("Room-\(room)"))
                let rows = (1...7).map { item -> [String] in
                    let tokens = (0..<(2 + item % 4)).map { "R\(room)-I\(item)-L\($0)" }
                    rowTokens.append(tokens)
                    return ["Item-\(room)-\(item)", tokens.joined(separator: "\n"), "Not checked\nNot checked", "Recorded"]
                }
                blocks.append(.table(headers: ["Item", "Condition", "Comparison", "Notes"], rows: rows))
            }
            blocks += [.pageBreak, .title("Review appendix"), .paragraph("APPENDIX-BEGIN"),
                       .signature(label: "Reviewed locally", image: nil)]
            let input = PDFDocumentTemplate(title: "Room report pagination", header: "ROOM REPORT / LAYOUT REVIEW",
                                            footer: "Local generated test content", generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                            paper: paper, blocks: blocks)
            let data = try PDFRenderer.render(input)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let pages = try pageTexts(document)
            XCTAssertGreaterThanOrEqual(pages.count, 3)
            for tokens in rowTokens {
                let startPage = try XCTUnwrap(pages.firstIndex { $0.contains(tokens[0]) })
                for token in tokens {
                    XCTAssertEqual(pages.filter { $0.contains(token) }.count, 1, "Each row line must occur exactly once")
                    XCTAssertTrue(pages[startPage].contains(token), "\(paper): \(token) continued onto a different page")
                }
            }
            for room in 1...6 {
                let titlePage = try XCTUnwrap(pages.firstIndex { $0.contains("Room-\(room)") })
                XCTAssertTrue(pages[titlePage].contains("R\(room)-I1-L0"), "Room title must stay with the first complete row")
            }
            for page in pages where page.contains("-L") {
                for header in ["Item", "Condition", "Comparison", "Notes"] { XCTAssertTrue(page.contains(header)) }
                let lines = page.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("R") && $0.contains("-L") }
                XCTAssertTrue(try XCTUnwrap(lines.first).hasSuffix("-L0"), "Page must start with a row's first line")
            }
            XCTAssertTrue(try XCTUnwrap(pages.last).contains("APPENDIX-BEGIN"))
            XCTAssertFalse(try XCTUnwrap(pages.last).contains("R6-I7"), "Explicit break must put the appendix on its own page")
            try writeValidation(data, name: "RoomReport-\(paper.rawValue)", pageCount: document.pageCount)
        }
    }
    func testTitleReservesCompleteFirstTableRowIncludingWrappedHeader() throws {
        for paper in [PDFPaper.a4, .letter] {
            // Sweep the boundary where the title and a header/one text line fit,
            // but the complete multiline row does not. Include consecutive headings.
            for count in 25...39 {
                let input = PDFDocumentTemplate(title: "Boundary", paper: paper, blocks: [
                    .paragraph(Array(repeating: "Filler", count: count).joined(separator: "\n")),
                    .title("Room boundary"), .title("Condition details"),
                    .table(headers: ["Item\nreference", "Condition\nrecord"],
                           rows: [["FIRST-ROW", "ROW-START\nNot checked\nNot checked\nROW-END"]])
                ])
                let pages = try pageTexts(XCTUnwrap(PDFDocument(data: PDFRenderer.render(input))))
                let titlePage = try XCTUnwrap(pages.firstIndex { $0.contains("Room boundary") })
                for token in ["Condition details", "reference", "FIRST-ROW", "ROW-START", "ROW-END"] {
                    XCTAssertTrue(pages[titlePage].contains(token), "\(paper), filler \(count): orphaned \(token)")
                }
            }
        }
    }
    func testTitleStaysWithParagraphAndPhotoRow() throws {
        let image = try photo()
        for paper in [PDFPaper.a4, .letter] {
            let paragraphLines = paper == .a4 ? 39 : 35
            for next in [PDFBlock.paragraph("CONTENT-START\nSecond line"),
                         .photos([PDFPhoto(data: image, caption: "CONTENT-START")], columns: 1)] {
                let input = PDFDocumentTemplate(title: "Boundary", paper: paper, blocks: [
                    .paragraph(Array(repeating: "Filler", count: paragraphLines).joined(separator: "\n")),
                    .title("Room heading"), next
                ])
                let data = try PDFRenderer.render(input)
                let document = try XCTUnwrap(PDFDocument(data: data))
                let pages = try pageTexts(document)
                let titlePage = try XCTUnwrap(pages.firstIndex { $0.contains("Room heading") })
                XCTAssertEqual(titlePage, 1, "Title must move from the page tail with its content")
                XCTAssertTrue(pages[titlePage].contains("CONTENT-START"))
            }
        }
    }
    func testPageBreakStartsNewPageAndPreservesIntentionalEmptyPages() throws {
        for paper in [PDFPaper.a4, .letter] {
            let input = PDFDocumentTemplate(title: "Explicit breaks", generatedAt: Date(timeIntervalSince1970: 1_700_000_000), paper: paper, blocks: [
                .paragraph("BEFORE-BREAK"), .pageBreak, .title("After explicit break"), .paragraph("AFTER-BREAK"),
                .pageBreak, .pageBreak, .paragraph("AFTER-EMPTY-PAGE"), .pageBreak
            ])
            let data = try PDFRenderer.render(input)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let pages = try pageTexts(document)
            XCTAssertEqual(pages.count, 5)
            XCTAssertTrue(pages[0].contains("BEFORE-BREAK")); XCTAssertFalse(pages[0].contains("AFTER-BREAK"))
            XCTAssertTrue(pages[1].contains("After explicit break")); XCTAssertTrue(pages[1].contains("AFTER-BREAK"))
            XCTAssertFalse(pages[2].contains("AFTER-EMPTY-PAGE")); XCTAssertTrue(pages[3].contains("AFTER-EMPTY-PAGE"))
            XCTAssertFalse(pages[4].contains("AFTER-EMPTY-PAGE"))
            try writeValidation(data, name: "PageBreak-\(paper.rawValue)", pageCount: document.pageCount)
        }
    }
    func testTallButFittingRowMovesWholeToFreshTablePage() throws {
        for paper in [PDFPaper.a4, .letter] {
            // Fits under a repeated header on a fresh page, but not after the document title.
            let count = paper == .a4 ? 45 : 41
            let lines = (0..<count).map { String(format: "Tall-%03d", $0) }
            let input = PDFDocumentTemplate(title: "Tall row", paper: paper, blocks: [
                .table(headers: ["Column A", "Column B"], rows: [["Short", lines.joined(separator: "\n")]])
            ])
            let pages = try pageTexts(XCTUnwrap(PDFDocument(data: PDFRenderer.render(input))))
            XCTAssertEqual(pages.count, 2)
            XCTAssertFalse(pages[0].contains("Column A"), "Do not strand an empty table header")
            for line in lines { XCTAssertTrue(pages[1].contains(line)) }
            XCTAssertTrue(pages[1].contains("Short")); XCTAssertTrue(pages[1].contains("Column A"))
        }
    }
    func testUnevenFourColumnRowPreservesEveryLineAcrossPages() throws {
        let lines = (0..<100).map { String(format: "Line-%03d", $0) }
        let headers = ["Column A", "Column B", "Column C", "Column D"]
        for paper in [PDFPaper.a4, .letter] {
            // One-line title/header, 14 pt row lines and 6 pt cell padding:
            // A4 fits 43/46/11 lines; Letter fits 39/42/19 lines.
            let pageLineCounts = paper == .a4 ? [43, 46, 11] : [39, 42, 19]
            for longColumn in headers.indices {
                var row = headers.indices.map { "Short-\($0)" }
                row[longColumn] = lines.joined(separator: "\n")
                let input = PDFDocumentTemplate(title: "Uneven row", header: "TABLE PAGINATION REVIEW",
                                                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                paper: paper, blocks: [.table(headers: headers, rows: [row])])
                let data = try PDFRenderer.render(input)
                let document = try XCTUnwrap(PDFDocument(data: data))
                XCTAssertEqual(document.pageCount, 3, "\(paper), long column \(longColumn)")
                var offset = 0
                for (index, count) in pageLineCounts.enumerated() {
                    let page = try XCTUnwrap(document.page(at: index)?.string)
                    let actualLines = page.components(separatedBy: .whitespacesAndNewlines).filter { $0.hasPrefix("Line-") }
                    XCTAssertEqual(actualLines, Array(lines[offset..<(offset + count)]), "\(paper), column \(longColumn), page \(index + 1)")
                    offset += count
                    for header in headers { XCTAssertTrue(page.contains(header)) }
                    for column in headers.indices where column != longColumn {
                        XCTAssertEqual(page.components(separatedBy: "Short-\(column)").count - 1, index == 0 ? 1 : 0,
                                       "Exhausted cells must stay empty on continuation pages")
                    }
                    XCTAssertTrue(page.contains("\(index + 1) / 3"))
                }
                if longColumn == 3, let output = ProcessInfo.processInfo.environment["NSKIT_PDF_VALIDATION_DIR"] {
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = "UnevenRow-\(paper.rawValue)"
                    try data.write(to: directory.appendingPathComponent("\(name).pdf"))
                    for index in 1...document.pageCount {
                        try png(raster(data, page: index)).write(to: directory.appendingPathComponent("\(name)-\(index).png"))
                    }
                }
            }
        }
    }
    func testLongFooterWrapsAndTruncatesBeforePageNumber() throws {
        for paper in [PDFPaper.a4, .letter] {
            let input = PDFDocumentTemplate(title: "Footer sample", header: "NINE STEMS / FOOTER REVIEW",
                                            footer: "FOOTERSTART " + String(repeating: "Long footer content without overlapping the page number. ", count: 20),
                                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), paper: paper,
                                            blocks: [.paragraph("A deliberately long footer is limited to two lines, with room for the page number.")])
            let data = try PDFRenderer.render(input)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(document.pageCount, 1)
            XCTAssertTrue(page.string?.contains("FOOTERSTART") == true)
            XCTAssertTrue(page.string?.contains("…") == true, "Make the omitted footer text visible to the reader")
            let pageNumber = try XCTUnwrap(document.findString("1 / 1", withOptions: []).first)
            let numberBounds = pageNumber.bounds(for: page)
            for word in ["FOOTERSTART", "Long", "footer", "content", "without", "overlapping", "the", "page", "number.", "…"] {
                for selection in document.findString(word, withOptions: []) where selection.bounds(for: page).minY < 70 {
                    XCTAssertLessThan(selection.bounds(for: page).maxX, numberBounds.minX - 8, "Footer text must leave a gap before the page number")
                }
            }
            if let output = ProcessInfo.processInfo.environment["NSKIT_PDF_VALIDATION_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("Footer-\(paper.rawValue).pdf"))
                try png(raster(data)).write(to: directory.appendingPathComponent("Footer-\(paper.rawValue).png"))
            }
        }
    }
    func testInvalidContentFailsInsteadOfSilentlyOmittingIt() throws {
        let cases: [(PDFBlock, PDFRenderError)] = [(.table(headers: [], rows: []), .invalidTable),
            (.table(headers: ["A"], rows: [["A", "B"]]), .invalidTable), (.photos([], columns: 0), .invalidColumns),
            (.photos([PDFPhoto(data: Data(), caption: "Bad")], columns: 1), .invalidImage)]
        for (block, expected) in cases {
            XCTAssertThrowsError(try PDFRenderer.render(PDFDocumentTemplate(title: "Invalid", blocks: [block]))) {
                XCTAssertEqual($0 as? PDFRenderError, expected)
            }
        }
        XCTAssertThrowsError(try PDFRenderer.render(PDFDocumentTemplate(title: "Header", header: String(repeating: "Long header ", count: 100), blocks: []))) {
            XCTAssertEqual($0 as? PDFRenderError, .oversizedRunningText)
        }
    }
    @MainActor func testDesignComponentsMatchReviewedSnapshot() throws {
        let view = VStack(spacing: DesignTokens.medium) {
            ListCard { Text("Sample card").font(DesignTokens.heading) }
            StatusBadge("Needs review")
            EmptyState(title: "No records yet", message: "Create a local sample to begin.")
        }.padding(24).frame(width: 390, height: 460).background(.white).foregroundStyle(.black)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: "en_GB"))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        try compare(XCTUnwrap(renderer.cgImage), fixture: "Design")
    }
}
