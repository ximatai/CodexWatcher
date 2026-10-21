import Foundation
import Darwin

/// An atomic disk write must complete before an irreversible redemption is sent.
final class ResetAttemptStore {
    private let file: URL

    init(directory: URL) {
        file = directory.appendingPathComponent("pending-resets.json")
    }

    func pending(for owner: String) throws -> PendingRedemption? {
        try withLock { try all()[owner] }
    }

    func prepare(creditID: String, owner: String) throws -> PendingRedemption {
        try withLock {
            var entries = try all()
            if let existing = entries[owner] { return existing }
            let attempt = PendingRedemption(creditID: creditID, idempotencyKey: UUID().uuidString)
            entries[owner] = attempt
            try write(entries)
            return attempt
        }
    }

    func clear(owner: String, idempotencyKey: String) throws {
        try withLock {
            var entries = try all()
            // A late result from another instance must not erase a newer operation.
            guard entries[owner]?.idempotencyKey == idempotencyKey else { return }
            entries.removeValue(forKey: owner)
            try write(entries)
        }
    }

    /// A newly confirmed operation must not silently adopt another instance's retry key.
    func prepareNew(creditID: String, owner: String, automaticExpiresAt: Double? = nil) throws -> PendingRedemption? {
        try withLock {
            var entries = try all()
            guard entries[owner] == nil else { return nil }
            let attempt = PendingRedemption(creditID: creditID, idempotencyKey: UUID().uuidString,
                automatic: automaticExpiresAt.map { AutomaticRedemption(expiresAt: $0) })
            entries[owner] = attempt
            try write(entries)
            return attempt
        }
    }

    /// Reserve a write attempt and its budget under the same cross-process lock.
    /// The account, credit, original expiry and idempotency key can never change.
    func reserveAutomaticAttempt(owner: String, expected: PendingRedemption, clock: () -> Date = Date.init) throws -> PendingRedemption? {
        try withLock {
            var entries = try all()
            let now = clock().timeIntervalSince1970
            guard var current = entries[owner], current.creditID == expected.creditID,
                  current.idempotencyKey == expected.idempotencyKey,
                  var automatic = current.automatic,
                  automatic.expiresAt == expected.automatic?.expiresAt,
                  automatic.expiresAt.isFinite, now.isFinite,
                  automatic.expiresAt > now, automatic.expiresAt - now <= CreditExpiryPolicy.leadTime,
                  automatic.attempts >= 0, automatic.attempts < CreditExpiryPolicy.maximumAttempts,
                  automatic.nextAttemptAt <= now, (automatic.leaseUntil ?? 0) <= now else { return nil }
            automatic.attempts += 1
            automatic.nextAttemptAt = now + CreditExpiryPolicy.retryInterval
            automatic.leaseUntil = now + CreditExpiryPolicy.attemptLease
            current.automatic = automatic
            entries[owner] = current
            try write(entries)
            return current
        }
    }

    func finishAutomaticAttempt(owner: String, expected: PendingRedemption, clock: () -> Date = Date.init) throws {
        try withLock {
            var entries = try all()
            guard var current = entries[owner], current.creditID == expected.creditID,
                  current.idempotencyKey == expected.idempotencyKey,
                  var automatic = current.automatic,
                  automatic.expiresAt == expected.automatic?.expiresAt,
                  automatic.attempts == expected.automatic?.attempts else { return }
            automatic.leaseUntil = nil
            automatic.nextAttemptAt = clock().timeIntervalSince1970 + CreditExpiryPolicy.retryInterval
            current.automatic = automatic
            entries[owner] = current
            try write(entries)
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lockFile = file.deletingLastPathComponent().appendingPathComponent("pending-resets.lock")
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func all() throws -> [String: PendingRedemption] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: PendingRedemption].self, from: Data(contentsOf: file))
    }

    private func write(_ entries: [String: PendingRedemption]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                               withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(entries).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
