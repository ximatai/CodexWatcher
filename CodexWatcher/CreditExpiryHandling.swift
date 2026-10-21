import Foundation
import Darwin
import CryptoKit

enum CreditExpiryMode: String, Codable, CaseIterable, Identifiable {
    case off, remind, automatic
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "关闭"
        case .remind: return "提醒后确认"
        case .automatic: return "自动使用"
        }
    }
}

struct CreditExpiryConfiguration: Codable, Equatable {
    var mode: CreditExpiryMode = .off
    var accountKey: String?
}

struct CreditExpiryReminder: Equatable {
    let accountKey: String
    let creditID: String
    let expiresAt: Date

    var identifier: String {
        let value = "\(accountKey.utf8.count):\(accountKey)\(creditID)"
        return "credit-expiry-" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct CreditExpiryReview: Equatable {
    let id = UUID()
    let accountKey: String
    let creditID: String
}

enum CreditExpiryPolicy {
    static let leadTime: TimeInterval = 15 * 60
    static let maximumAttempts = 3
    static let retryInterval: TimeInterval = 30
    // Longer than the production RPC timeout (30s); a crashed process cannot hold a permanent lock.
    static let attemptLease: TimeInterval = 90

    static func candidate(in credits: [ResetCredit], at date: Date) -> ResetCredit? {
        credits.filter { credit in
            guard credit.isUsable(at: date), let expiry = credit.expiryDate,
                  expiry.timeIntervalSince1970.isFinite else { return false }
            return expiry.timeIntervalSince(date) <= leadTime
        }.min { ($0.expiresAt ?? .infinity) < ($1.expiresAt ?? .infinity) }
    }
}

/// Per-account/card claims survive restarts and serialize multiple app instances.
/// An automatic claim is never cleared; retries belong to the original pending request.
final class CreditExpiryActionStore {
    private let directory: URL
    private var file: URL { directory.appendingPathComponent("expiry-actions.json") }
    init(directory: URL) { self.directory = directory }

    private func key(_ reminder: CreditExpiryReminder, mode: CreditExpiryMode) -> String {
        mode.rawValue + ":" + reminder.identifier
    }

    func contains(_ reminder: CreditExpiryReminder, mode: CreditExpiryMode) throws -> Bool {
        try withEntries { $0.contains(key(reminder, mode: mode)) }
    }

    func claim(_ reminder: CreditExpiryReminder, mode: CreditExpiryMode) throws -> Bool {
        try withEntries { entries in
            let value = key(reminder, mode: mode)
            guard !entries.contains(value) else { return false }
            entries.insert(value)
            return true
        }
    }

    func releaseReminder(_ reminder: CreditExpiryReminder) throws {
        try withEntries { _ = $0.remove(key(reminder, mode: .remind)) }
    }

    private func withEntries<T>(_ body: (inout Set<String>) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.appendingPathComponent("expiry-actions.lock").path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        var entries = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode(Set<String>.self, from: Data(contentsOf: file)) : []
        let original = entries
        let result = try body(&entries)
        if entries != original {
            try JSONEncoder().encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        return result
    }
}
