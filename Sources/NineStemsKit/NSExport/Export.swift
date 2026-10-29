import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
import MessageUI
#endif

/// An in-memory document for SwiftUI's system fileExporter flow.
public struct ExportDocument: FileDocument {
    /// PDF, JSON and generic bytes supported by the system document import/export panels.
    public static let readableContentTypes: [UTType] = [.pdf, .json, .data]
    /// Original document bytes.
    public var data: Data
    /// Creates a file document for PDF or JSON bytes.
    public init(data: Data) { self.data = data }
    /// Loads document bytes from a system file reader.
    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    /// Supplies document bytes to the system save panel.
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// Safe local file output for an app-supplied destination directory.
public enum ExportFile {
    /// Writes atomically, rejecting filenames that could escape the supplied directory.
    /// Files already at the destination are replaced; use a user-chosen URL via fileExporter for interactive saves.
    public static func write(_ data: Data, filename: String, directory: URL) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.contains("/"),
              !filename.contains("\\"), !filename.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: .atomic)
        return url
    }
}

#if canImport(UIKit)
/// The iOS share sheet for local files. Keep the files alive until dismissal.
public struct SystemShareSheet: UIViewControllerRepresentable {
    private let files: [URL]
    /// Creates a system share sheet from app-owned local URLs.
    public init(files: [URL]) { self.files = files }
    /// Creates the activity controller.
    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: files, applicationActivities: nil)
    }
    /// Share items are fixed for this presentation.
    public func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// An email attachment with an app-provided MIME type and filename.
public struct MailAttachment: Sendable {
    /// Attachment bytes.
    public let data: Data
    /// MIME type such as application/pdf.
    public let mimeType: String
    /// Display filename.
    public let filename: String
    /// Creates a mail attachment.
    public init(data: Data, mimeType: String, filename: String) { self.data = data; self.mimeType = mimeType; self.filename = filename }
}

/// A system mail composer. Present only when canSendMail is true; sharing remains an alternative.
public struct SystemMailSheet: UIViewControllerRepresentable {
    private let subject: String
    private let attachments: [MailAttachment]
    @Environment(\.dismiss) private var dismiss
    /// Whether the device has a configured mail account.
    public static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }
    /// Creates an unsent email for user review. The kit never sends it automatically.
    public init(subject: String, attachments: [MailAttachment]) { self.subject = subject; self.attachments = attachments }
    /// Creates the delegate that closes the composer after the user's action.
    public func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    /// Creates and populates the native composer.
    public func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(subject)
        for item in attachments { controller.addAttachmentData(item.data, mimeType: item.mimeType, fileName: item.filename) }
        return controller
    }
    /// Attachments are fixed for this presentation.
    public func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}
    /// Mail delegate used by the representable.
    public final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let completion: () -> Void
        fileprivate init(completion: @escaping () -> Void) { self.completion = completion }
        /// Dismisses after sending, saving, cancellation or failure; errors remain the system composer's responsibility.
        public func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) { completion() }
    }
}
#endif
