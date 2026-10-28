import Foundation
import Observation

/// Stable release versions only. Unknown tags never become update links.
struct ReleaseVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    var description: String { "\(major).\(minor).\(patch)" }
    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

struct GitHubRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
}

enum ReleaseCheckError: Error { case invalidResponse, rateLimited(Date) }

struct GitHubReleaseClient {
    static let endpoint = URL(string: "https://api.github.com/repos/ximatai/CodexWatcher/releases/latest")!
    static func fetch() async throws -> GitHubRelease {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexWatcher-UpdateCheck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url == endpoint else { throw ReleaseCheckError.invalidResponse }
        return try decode(data, response: response)
    }
    static func decode(_ data: Data, response: HTTPURLResponse, now: Date = .now) throws -> GitHubRelease {
        if response.statusCode == 403 || response.statusCode == 429 {
            let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init).map { now.addingTimeInterval(max(60, $0)) }
            let reset = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            throw ReleaseCheckError.rateLimited(max(now.addingTimeInterval(60), max(retry ?? now, reset ?? now)))
        }
        guard response.statusCode == 200, data.count <= 512_000 else { throw ReleaseCheckError.invalidResponse }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

@MainActor @Observable
final class ReleaseUpdateChecker {
    enum Result: Equatable { case available, current, failed, busy, skipped, rateLimited }
    private(set) var availableVersion: ReleaseVersion?
    private(set) var isChecking = false
    private let currentVersion: ReleaseVersion?
    private let defaults: UserDefaults
    private let fetch: () async throws -> GitHubRelease
    private let now: () -> Date
    private static let attemptKey = "releaseCheckLastAttempt"
    private static let cachedKey = "releaseCheckAvailableVersion"
    private static let retryKey = "releaseCheckRetryAfter"

    init(version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         defaults: UserDefaults = .standard, now: @escaping () -> Date = { .now },
         fetch: @escaping () async throws -> GitHubRelease = { try await GitHubReleaseClient.fetch() }) {
        self.currentVersion = version.flatMap(ReleaseVersion.init)
        self.defaults = defaults; self.now = now; self.fetch = fetch
        if let currentVersion, let cached = defaults.string(forKey: Self.cachedKey).flatMap(ReleaseVersion.init), cached > currentVersion {
            availableVersion = cached
        }
    }
    var releaseURL: URL? {
        availableVersion.flatMap { URL(string: "https://github.com/ximatai/CodexWatcher/releases/tag/v\($0.description)") }
    }
    var menuTitle: String {
        return availableVersion.map { L10n.text("新版本 \($0.description)…") } ?? L10n.text("检查更新…")
    }
    func check(force: Bool = false) async -> Result {
        guard !isChecking else { return .busy }
        let date = now()
        if let retry = defaults.object(forKey: Self.retryKey) as? Date, retry > date { return .rateLimited }
        if !force, let last = defaults.object(forKey: Self.attemptKey) as? Date,
           date.timeIntervalSince(last) >= 0, date.timeIntervalSince(last) < 24 * 60 * 60 { return .skipped }
        guard let currentVersion else { return .failed }
        // Record attempts, including failures, before the request to avoid relaunch storms.
        defaults.set(date, forKey: Self.attemptKey)
        isChecking = true
        defer { isChecking = false }
        do {
            let release = try await fetch()
            guard !release.draft, !release.prerelease, release.tag_name.hasPrefix("v"),
                  let version = ReleaseVersion(release.tag_name), release.tag_name == "v\(version.description)" else { return .failed }
            availableVersion = version > currentVersion ? version : nil
            defaults.set(availableVersion?.description, forKey: Self.cachedKey)
            defaults.removeObject(forKey: Self.retryKey)
            return availableVersion == nil ? .current : .available
        } catch ReleaseCheckError.rateLimited(let retry) {
            defaults.set(retry, forKey: Self.retryKey)
            return .rateLimited
        } catch { return .failed }
    }
}
