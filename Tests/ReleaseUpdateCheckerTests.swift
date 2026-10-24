import XCTest
@testable import WatcherCore

@MainActor
final class ReleaseUpdateCheckerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ReleaseUpdateTests-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func release(_ tag: String = "v0.3.2", draft: Bool = false, prerelease: Bool = false) -> GitHubRelease {
        GitHubRelease(tag_name: tag, draft: draft, prerelease: prerelease)
    }
    func testNumericOrderingAndRejectsUnsupportedVersions() {
        XCTAssertGreaterThan(ReleaseVersion("v0.3.10")!, ReleaseVersion("0.3.9")!)
        XCTAssertGreaterThan(ReleaseVersion("1.0.0")!, ReleaseVersion("0.99.99")!)
        for value in ["0.3", "v0.3.2-beta.1", "0.-1.2", "https://evil.test", "0.3.2/other", "０.3.2", "0.3.99999999999999999999999"] {
            XCTAssertNil(ReleaseVersion(value), value)
        }
    }
    func testNewReleaseCachesOnlyCanonicalRepositoryLink() async {
        let storage = defaults()
        let checker = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, fetch: { self.release() })
        let result = await checker.check()
        XCTAssertEqual(result, .available)
        XCTAssertEqual(checker.menuTitle, "新版本 0.3.2…")
        XCTAssertEqual(checker.releaseURL?.absoluteString, "https://github.com/ximatai/CodexWatcher/releases/tag/v0.3.2")
        let restarted = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, fetch: { XCTFail("Cache must not fetch"); return self.release() })
        XCTAssertEqual(restarted.availableVersion, ReleaseVersion("0.3.2"))
        let skipped = await restarted.check()
        XCTAssertEqual(skipped, .skipped)
        let upgraded = ReleaseUpdateChecker(version: "0.3.2", defaults: storage)
        XCTAssertNil(upgraded.releaseURL)
    }
    func testCurrentOrNewerInstalledVersionDoesNotOfferDowngrade() async {
        for version in ["0.3.2", "0.4.0"] {
            let checker = ReleaseUpdateChecker(version: version, defaults: defaults(), fetch: { self.release() })
            let result = await checker.check(force: true)
            XCTAssertEqual(result, .current)
            XCTAssertNil(checker.releaseURL)
        }
    }
    func testDraftPrereleaseAndInvalidTagsNeverBecomeLinks() async {
        for item in [release(draft: true), release(prerelease: true), release("v0.4.0-beta.1"), release("v00.4.0"), release("v0.4.0/evil"), release("0.4.0")] {
            let checker = ReleaseUpdateChecker(version: "0.3.1", defaults: defaults(), fetch: { item })
            let result = await checker.check(force: true)
            XCTAssertEqual(result, .failed)
            XCTAssertNil(checker.releaseURL)
        }
    }
    func testFailedAutomaticAttemptIsThrottledAcrossRestartsButManualCanRetry() async {
        let storage = defaults()
        let first = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, fetch: { throw URLError(.notConnectedToInternet) })
        let failed = await first.check()
        XCTAssertEqual(failed, .failed)
        let next = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, fetch: { self.release() })
        let skipped = await next.check()
        XCTAssertEqual(skipped, .skipped)
        let manual = await next.check(force: true)
        XCTAssertEqual(manual, .available)
    }
    func testDailyScheduleAndClockMovingBackwards() async {
        let storage = defaults()
        var now = Date(timeIntervalSince1970: 1_000_000)
        var calls = 0
        let checker = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, now: { now }, fetch: { calls += 1; return self.release() })
        _ = await checker.check()
        now += 86399
        let skipped = await checker.check()
        XCTAssertEqual(skipped, .skipped)
        now += 1
        _ = await checker.check()
        XCTAssertEqual(calls, 2)
        now -= 100_000
        _ = await checker.check()
        XCTAssertEqual(calls, 3)
    }
    func testRateLimitSurvivesRestartAndBlocksManualUntilRetryTime() async {
        let storage = defaults()
        var now = Date(timeIntervalSince1970: 1_000_000)
        let first = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, now: { now }, fetch: { throw ReleaseCheckError.rateLimited(now + 3600) })
        let limited = await first.check()
        XCTAssertEqual(limited, .rateLimited)
        let next = ReleaseUpdateChecker(version: "0.3.1", defaults: storage, now: { now }, fetch: { self.release() })
        let manual = await next.check(force: true)
        XCTAssertEqual(manual, .rateLimited)
        now += 3601
        let retried = await next.check(force: true)
        XCTAssertEqual(retried, .available)
    }
    func testConcurrentCheckDoesNotStartSecondRequest() async {
        var continuation: CheckedContinuation<GitHubRelease, Never>?
        let checker = ReleaseUpdateChecker(version: "0.3.1", defaults: defaults(), fetch: {
            await withCheckedContinuation { continuation = $0 }
        })
        let task = Task { await checker.check() }
        while continuation == nil { await Task.yield() }
        let busy = await checker.check(force: true)
        XCTAssertEqual(busy, .busy)
        continuation?.resume(returning: release())
        let result = await task.value
        XCTAssertEqual(result, .available)
        XCTAssertFalse(checker.isChecking)
    }
    func testFailedRefreshRetainsKnownUpdateButSuccessfulCurrentClearsIt() async {
        var fail = false
        var tag = "v0.3.2"
        let checker = ReleaseUpdateChecker(version: "0.3.1", defaults: defaults(), fetch: {
            if fail { throw URLError(.timedOut) }
            return self.release(tag)
        })
        _ = await checker.check()
        fail = true
        let result = await checker.check(force: true)
        XCTAssertEqual(result, .failed)
        XCTAssertNotNil(checker.releaseURL)
        fail = false; tag = "v0.3.1"
        _ = await checker.check(force: true)
        XCTAssertNil(checker.releaseURL)
    }
    func testUnknownInstalledVersionDoesNotRequestOrClaimUpToDate() async {
        let checker = ReleaseUpdateChecker(version: nil, defaults: defaults(), fetch: {
            XCTFail("Unknown installed version must not fetch")
            return self.release()
        })
        let result = await checker.check(force: true)
        XCTAssertEqual(result, .failed)
        XCTAssertNil(checker.releaseURL)
    }
    func testHTTPFailureMalformedPayloadAndRateLimitHeaders() throws {
        let url = GitHubReleaseClient.endpoint
        let valid = Data(#"{"tag_name":"v0.3.2","draft":false,"prerelease":false}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(try GitHubReleaseClient.decode(valid, response: response).tag_name, "v0.3.2")
        XCTAssertThrowsError(try GitHubReleaseClient.decode(Data("{}".utf8), response: response))
        for status in [404, 500] {
            XCTAssertThrowsError(try GitHubReleaseClient.decode(valid, response: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!))
        }
        let now = Date(timeIntervalSince1970: 1000)
        let limited = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120", "X-RateLimit-Reset": "1300"])!
        XCTAssertThrowsError(try GitHubReleaseClient.decode(valid, response: limited, now: now)) { error in
            guard case ReleaseCheckError.rateLimited(let retry) = error else { return XCTFail("Expected rate limit") }
            XCTAssertEqual(retry, now + 300)
        }
    }
}
