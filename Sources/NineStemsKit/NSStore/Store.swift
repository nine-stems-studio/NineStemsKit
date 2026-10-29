import Foundation
import SwiftData
import Observation

/// Errors in the versioned, app-scoped JSON backup format.
public enum BackupError: Error, Equatable {
    /// The backup belongs to another app or has an unsupported format version.
    case incompatibleBackup
}

private struct BackupEnvelope<Value: Codable>: Codable {
    let version: Int
    let appIdentifier: String
    let value: Value
}

/// A local-only SwiftData container and a versioned DTO backup boundary.
@MainActor
public final class LocalStore {
    /// The container, suitable for SwiftUI's modelContainer modifier.
    public let container: ModelContainer
    private let appIdentifier: String
    private let models: [any PersistentModel.Type]

    /// Builds a container from app-owned models. CloudKit is disabled; URL is optional for in-memory tests.
    public init(models: [any PersistentModel.Type], appIdentifier: String, inMemory: Bool = false,
                url: URL? = nil, migrationPlan: (any SchemaMigrationPlan.Type)? = nil) throws {
        self.appIdentifier = appIdentifier
        self.models = models
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if let url, !inMemory {
            configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        } else {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        }
        container = try ModelContainer(for: schema, migrationPlan: migrationPlan, configurations: [configuration])
    }

    /// Encodes an app-owned Codable DTO, never a SwiftData model or its internal identifiers.
    public func exportJSON<Value: Codable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(BackupEnvelope(version: 1, appIdentifier: appIdentifier, value: value))
    }

    /// Decodes and validates an entire backup before any store changes take place.
    public func decodeJSON<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(BackupEnvelope<Value>.self, from: data)
        guard envelope.version == 1, envelope.appIdentifier == appIdentifier else { throw BackupError.incompatibleBackup }
        return envelope.value
    }

    /// Imports a validated DTO in a fresh context and saves once. Throwing rolls back all changes in that context.
    /// The app decides how to merge or replace models; the closure must use only the supplied context.
    public func importJSON<Value: Codable>(_ type: Value.Type, from data: Data,
                                          apply: (Value, ModelContext) throws -> Void) throws {
        let value = try decodeJSON(type, from: data)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            try apply(value, context)
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Deletes all models in this container. Apps must discard outstanding unsaved edits before calling.
    /// External photo files and preferences belong to the app and are not part of this database operation.
    public func clearAll() throws {
        let context = container.mainContext
        context.rollback()
        do {
            for model in models { try remove(model, from: context) }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    private func remove<Model: PersistentModel>(_ type: Model.Type, from context: ModelContext) throws {
        for value in try context.fetch(FetchDescriptor<Model>()) { context.delete(value) }
    }
}

/// Optional device-only anonymous event counts, disabled until explicitly enabled.
@MainActor @Observable
public final class LocalCounters {
    /// Whether counting has been explicitly enabled on this device.
    public private(set) var isEnabled: Bool
    /// Counts keyed by app-defined event names; no events are uploaded.
    public private(set) var counts: [String: Int]
    private let defaults: UserDefaults
    private let key: String

    /// Restores local preferences in the app's namespace; do not put user data in event names.
    public init(namespace: String, defaults: UserDefaults = .standard) {
        self.defaults = defaults; key = "NineStemsKit.counters.\(namespace)"
        let enabled = defaults.bool(forKey: key + ".enabled")
        isEnabled = enabled
        counts = enabled ? (defaults.dictionary(forKey: key) as? [String: Int] ?? [:]) : [:]
    }
    /// Enables counting or disables it and removes previously recorded counts.
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled; defaults.set(enabled, forKey: key + ".enabled")
        if !enabled { reset() }
    }
    /// Increments a named event when enabled. Empty names are ignored and integers saturate.
    public func record(_ event: String) {
        guard isEnabled, !event.isEmpty else { return }
        let old = counts[event, default: 0]
        counts[event] = old == Int.max ? old : old + 1
        defaults.set(counts, forKey: key)
    }
    /// Removes all local counts without changing the opt-in preference.
    public func reset() { counts = [:]; defaults.removeObject(forKey: key) }
}
