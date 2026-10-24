import Foundation
import Darwin
import CryptoKit

struct AutomaticHelloConfiguration: Codable, Equatable {
    var enabled = false
    var accountKey: String?
    var windowID: String?
}

struct AutomaticHelloAuthorization: Identifiable {
    let id = UUID()
    let accountKey: String
    let windowID: String
}

struct HelloObservation {
    let accountKey: String
    let window: UsageWindow
    // Captured before the read, so a late response cannot undo a newer claim.
    let startedAt: Date

    var isValid: Bool {
        window.quota.usedPercent.isFinite && (0...100).contains(window.quota.usedPercent)
            && window.quota.resetsAt?.isFinite == true && (window.quota.resetsAt ?? 0) > 0
    }
    var isFull: Bool { window.quota.usedPercent == 0 }
}

struct AutomaticHelloRecord: Codable {
    var armed = true
    var lastObservedAt: Double = 0
    var resetAt: Double?
    var attemptID: String?
    var attemptedAt: Double?
    var outcome: String?
    var baselineUsedPercent: Double?
}

/// A claim is permanent for this full-quota episode, including failures and crashes.
/// Re-arming requires usage beyond the post-hello baseline, then a return to full.
final class AutomaticHelloStore {
    private let directory: URL
    init(directory: URL) { self.directory = directory }
    private var file: URL { directory.appendingPathComponent("automatic-hello.json") }

    private func key(account: String, windowID: String) -> String {
        SHA256.hash(data: Data("\(account.utf8.count):\(account)\(windowID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func record(account: String, windowID: String) throws -> AutomaticHelloRecord? {
        try withEntries { $0[key(account: account, windowID: windowID)] }
    }

    /// Observing is read-only with respect to the service. Claiming persists before inference.
    func observe(_ observation: HelloObservation, claim: Bool) throws -> AutomaticHelloRecord? {
        guard observation.isValid else { return nil }
        return try withEntries { entries in
            let owner = key(account: observation.accountKey, windowID: observation.window.id)
            var record = entries[owner] ?? AutomaticHelloRecord()
            let timestamp = observation.startedAt.timeIntervalSince1970
            guard timestamp.isFinite, timestamp >= record.lastObservedAt else { return nil }
            record.lastObservedAt = timestamp
            record.resetAt = observation.window.quota.resetsAt
            let used = observation.window.quota.usedPercent
            if !record.armed && used > 0 {
                if let baseline = record.baselineUsedPercent {
                    // Ignore the tiny usage from our own request and reporting jitter.
                    if used >= baseline + 1 { record.armed = true }
                } else {
                    // After a crash/unknown result, the next observed usage is the baseline.
                    record.baselineUsedPercent = used
                }
            }
            let eligible = record.armed && observation.isFull
            if claim && eligible {
                record.armed = false
                record.attemptID = UUID().uuidString
                record.attemptedAt = Date().timeIntervalSince1970
                record.outcome = "reserved"
                record.baselineUsedPercent = nil
            }
            entries[owner] = record
            return eligible ? record : nil
        }
    }

    func finish(account: String, windowID: String, attemptID: String, outcome: String,
                baseline: HelloObservation? = nil) throws {
        try withEntries { entries in
            let owner = key(account: account, windowID: windowID)
            guard var record = entries[owner], record.attemptID == attemptID else { return }
            record.outcome = outcome
            if let baseline, baseline.isValid, baseline.accountKey == account, baseline.window.id == windowID,
               baseline.startedAt.timeIntervalSince1970 >= record.lastObservedAt {
                record.lastObservedAt = baseline.startedAt.timeIntervalSince1970
                record.baselineUsedPercent = baseline.window.quota.usedPercent
                record.resetAt = baseline.window.quota.resetsAt
            }
            entries[owner] = record
        }
    }

    private func withEntries<T>(_ body: (inout [String: AutomaticHelloRecord]) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("automatic-hello.lock").path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        var entries = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([String: AutomaticHelloRecord].self, from: Data(contentsOf: file)) : [:]
        let result = try body(&entries)
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return result
    }
}
