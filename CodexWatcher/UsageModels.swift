import Foundation

struct AccountResponse: Decodable { let account: WatcherAccount? }

struct WatcherAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?

    var planDisplayName: String {
        switch planType {
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "free": return "Free"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "team": return "Team"
        case "edu": return "Edu"
        case .some(let name): return name
        case nil: return "ChatGPT"
        }
    }
}

struct UsageSnapshot: Codable {
    let accountId: String?
    let rateLimits: LimitBucket
    let rateLimitsByLimitId: [String: LimitBucket]?
    let rateLimitResetCredits: ResetCredits?

    var windows: [UsageWindow] {
        let buckets = rateLimitsByLimitId.flatMap { $0.isEmpty ? nil : $0 }
            ?? [rateLimits.limitId ?? "codex": rateLimits]
        return buckets.sorted { $0.key < $1.key }.flatMap { key, bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { kind, window in
                window.map { UsageWindow(id: "\(key).\(kind)", bucketID: key,
                                         name: bucket.limitName ?? key, quota: $0) }
            }
        }
    }
}

struct LimitBucket: Codable {
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
}

struct QuotaWindow: Codable {
    let usedPercent: Double
    let windowDurationMins: Double?
    let resetsAt: Double?

    var resetDate: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }

    func standardPercent(at date: Date) -> Double? {
        guard let minutes = windowDurationMins, minutes > 0,
              let end = resetDate, date < end else { return nil }
        let start = end.addingTimeInterval(-minutes * 60)
        return min(100, max(0, date.timeIntervalSince(start) / (minutes * 60) * 100))
    }

    func deviation(at date: Date) -> Double? {
        standardPercent(at: date).map { usedPercent - $0 }
    }

    var durationLabel: String {
        PresentationFormat().quotaDuration(windowDurationMins)
    }
}

struct UsageWindow: Identifiable {
    let id: String
    let bucketID: String
    let name: String
    let quota: QuotaWindow
}

struct ResetCredits: Codable {
    let availableCount: Int
    let credits: [ResetCredit]?
}

struct ResetCredit: Codable, Identifiable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Double
    let expiresAt: Double?
    let title: String?
    let description: String?

    var expiryDate: Date? { expiresAt.map(Date.init(timeIntervalSince1970:)) }
    func isUsable(at date: Date) -> Bool {
        status == "available" && resetType == "codexRateLimits"
            && (expiryDate.map { $0 > date } ?? true)
    }
}

struct ResetResult: Decodable { let outcome: String }
struct LoginResult: Decodable {
    let loginId: String?
    let authUrl: String?
}
struct PendingRedemption: Codable {
    let creditID: String
    let idempotencyKey: String
}
