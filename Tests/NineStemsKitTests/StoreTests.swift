import XCTest
import SwiftData
import NSStore
import NSCompliance
import NSExport

@Model private final class Note {
    var text: String
    init(_ text: String) { self.text = text }
}

final class StoreTests: XCTestCase {
    @MainActor func testBackupRoundTripAndClear() throws {
        let store = try LocalStore(models: [Note.self], appIdentifier: "test", inMemory: true)
        let data = try store.exportJSON(["One", "Two"])
        try store.importJSON([String].self, from: data) { values, context in values.forEach { context.insert(Note($0)) } }
        XCTAssertEqual(try store.container.mainContext.fetchCount(FetchDescriptor<Note>()), 2)
        XCTAssertEqual(try store.decodeJSON([String].self, from: data), ["One", "Two"])
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let decodedDate = try store.decodeJSON(Date.self, from: store.exportJSON(timestamp))
        XCTAssertEqual(decodedDate.timeIntervalSince1970, timestamp.timeIntervalSince1970, accuracy: 0.000_001)
        try store.clearAll()
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<Note>()), 0)
        store.container.mainContext.insert(Note("After clear")); try store.container.mainContext.save()
        XCTAssertEqual(try ModelContext(store.container).fetchCount(FetchDescriptor<Note>()), 1)
    }
    @MainActor func testInvalidBackupNeverInvokesImportAndWrongAppIsRejected() throws {
        let store = try LocalStore(models: [Note.self], appIdentifier: "test", inMemory: true)
        let other = try LocalStore(models: [Note.self], appIdentifier: "other", inMemory: true)
        var invoked = false
        XCTAssertThrowsError(try store.importJSON([String].self, from: Data("bad".utf8)) { _, _ in invoked = true })
        XCTAssertFalse(invoked)
        XCTAssertThrowsError(try other.decodeJSON([String].self, from: store.exportJSON(["Private"]))) {
            XCTAssertEqual($0 as? BackupError, .incompatibleBackup)
        }
        let future = Data("{\"version\":2,\"appIdentifier\":\"test\",\"value\":[]}".utf8)
        XCTAssertThrowsError(try store.decodeJSON([String].self, from: future))
    }
    @MainActor func testImportFailureRollsBackDeleteAndInsert() throws {
        enum Abort: Error { case requested }
        let store = try LocalStore(models: [Note.self], appIdentifier: "test", inMemory: true)
        let context = store.container.mainContext
        context.insert(Note("Original")); try context.save()
        let data = try store.exportJSON(["Replacement"])
        XCTAssertThrowsError(try store.importJSON([String].self, from: data) { values, importing in
            for note in try importing.fetch(FetchDescriptor<Note>()) { importing.delete(note) }
            values.forEach { importing.insert(Note($0)) }
            throw Abort.requested
        })
        let stored = try ModelContext(store.container).fetch(FetchDescriptor<Note>())
        XCTAssertEqual(stored.map(\.text), ["Original"])
    }
    @MainActor func testLocalCountersAreOptInPersistentAndEraseOnDisable() {
        let defaults = UserDefaults(suiteName: "NSKitTests.\(UUID().uuidString)")!
        let counters = LocalCounters(namespace: "test", defaults: defaults)
        counters.record("export"); XCTAssertTrue(counters.counts.isEmpty)
        counters.setEnabled(true); counters.record("export"); counters.record("export")
        XCTAssertEqual(LocalCounters(namespace: "test", defaults: defaults).counts["export"], 2)
        counters.setEnabled(false)
        XCTAssertTrue(LocalCounters(namespace: "test", defaults: defaults).counts.isEmpty)
    }
    func testCitationsRejectUnsafeLinksAndRetainDate() throws {
        for url in ["http://www.gov.uk", "file:///tmp/source", "javascript:alert(1)", "https://user:pass@example.com"] {
            XCTAssertThrowsError(try DataSource(title: "Source", url: URL(string: url)!, checkedAt: .distantPast))
        }
        let source = try DataSource(title: "Source", url: URL(string: "https://www.gov.uk/")!, checkedAt: .distantPast)
        XCTAssertEqual(source.checkedAt, .distantPast)
    }
    func testAtomicExportAndFilenameValidation() throws {
        XCTAssertTrue(ExportDocument.readableContentTypes.contains(.pdf))
        XCTAssertTrue(ExportDocument.readableContentTypes.contains(.json))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data("PDF".utf8)
        let url = try ExportFile.write(data, filename: "sample.pdf", directory: directory)
        XCTAssertEqual(try Data(contentsOf: url), data)
        for name in ["", "..", "../escape", "nested/file", "nested\\file"] {
            XCTAssertThrowsError(try ExportFile.write(data, filename: name, directory: directory))
        }
    }
}
