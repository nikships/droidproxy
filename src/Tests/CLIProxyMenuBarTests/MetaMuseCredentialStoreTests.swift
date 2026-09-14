import XCTest
@testable import CLIProxyMenuBar

final class MetaMuseCredentialStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MetaMuseCredentialStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MetaMuseCredentialStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func credentials(_ subject: String, key: String = "test-key", revision: Int = 0) throws -> MetaMuseCredentials {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": subject, "iss": "test", "email": "\(subject)@example.test", "iat": revision
        ]).base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return MetaMuseCredentials(identityToken: "header.\(payload).signature", apiKey: key,
                                   apiKeyExpiresAt: Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testLegacyMigrationAndLastRemovalDoNotResurrectAccount() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let legacy = try credentials("alice")
        let legacyURL = directory.appendingPathComponent("credentials.json")
        try encoder.encode(legacy).write(to: legacyURL)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.credentials, legacy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(store.remove(id: try XCTUnwrap(store.accounts.first?.id)))
        XCTAssertTrue(MetaMuseCredentialStore(directory: directory).accounts.isEmpty)
    }

    func testMultipleAccountsReauthenticationAndPermissions() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        XCTAssertTrue(store.save(try credentials("bob")))
        let aliceID = try XCTUnwrap(store.accounts.first?.id)
        XCTAssertTrue(store.toggleDisabled(id: aliceID))
        XCTAssertTrue(store.save(try credentials("alice", key: "new-key", revision: 1)))
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(store.accounts.first?.id, aliceID)
        XCTAssertEqual(store.accounts.first?.credentials.apiKey, "new-key")
        XCTAssertTrue(try XCTUnwrap(store.accounts.first?.disabled))
        XCTAssertEqual(store.authAccounts.first?.displayName, "alice@example.test")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.accountsURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLastEnabledGuardAndRemoval() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        let alice = try XCTUnwrap(store.accounts.first)
        XCTAssertFalse(store.toggleDisabled(id: alice.id))
        XCTAssertTrue(store.save(try credentials("bob")))
        let bob = try XCTUnwrap(store.accounts.last)
        XCTAssertTrue(store.toggleDisabled(id: alice.id))
        XCTAssertFalse(store.toggleDisabled(id: bob.id))
        XCTAssertTrue(store.toggleDisabled(id: alice.id))
        XCTAssertTrue(store.remove(id: bob.id))
        XCTAssertEqual(store.accounts.map(\.id), [alice.id])
    }

    func testRefreshCannotRestoreRemovedAccountOrOverwriteNewLogin() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        let old = try XCTUnwrap(store.accounts.first)
        XCTAssertTrue(store.save(try credentials("alice", key: "new-login", revision: 1)))
        XCTAssertFalse(store.updateKey(for: old, apiKey: "stale", expiresAt: .distantFuture))
        XCTAssertEqual(store.accounts.first?.credentials.apiKey, "new-login")
        let current = try XCTUnwrap(store.accounts.first)
        XCTAssertTrue(store.remove(id: current.id))
        XCTAssertFalse(store.updateKey(for: current, apiKey: "resurrected", expiresAt: .distantFuture))
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRefreshPreservesDisabledStateAndRejectsDuplicateResponse() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        XCTAssertTrue(store.save(try credentials("bob")))
        let snapshot = try XCTUnwrap(store.accounts.first)
        XCTAssertTrue(store.toggleDisabled(id: snapshot.id))
        XCTAssertTrue(store.updateKey(for: snapshot, apiKey: "refreshed", expiresAt: .distantFuture))
        XCTAssertTrue(try XCTUnwrap(store.accounts.first?.disabled))
        XCTAssertFalse(store.updateKey(for: snapshot, apiKey: "stale", expiresAt: .distantFuture))
    }

    func testConfigurationIncludesOnlyEnabledUnexpiredKeysAndEscapesYAML() throws {
        var alice = MetaMuseCredentialStore.account(for: try credentials("alice", key: "quote\"\\\nkey"))
        var bob = MetaMuseCredentialStore.account(for: try credentials("bob", key: "bob-key"))
        let config = MetaMuseCredentialStore.compatibilityConfig(accounts: [alice, bob], enabled: true)
        XCTAssertEqual(config.components(separatedBy: "- api-key:").count - 1, 2)
        XCTAssertTrue(config.contains("quote\\\"\\\\\\nkey"))
        XCTAssertTrue(config.contains("muse-spark-1.3-contributor"))
        alice.disabled = true
        bob.credentials.apiKeyExpiresAt = .distantPast
        XCTAssertEqual(MetaMuseCredentialStore.compatibilityConfig(accounts: [alice, bob], enabled: true), "")
        XCTAssertEqual(MetaMuseCredentialStore.compatibilityConfig(accounts: [alice], enabled: false), "")
    }

    func testCorruptStoreIsNotOverwrittenByNewLogin() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: store.accountsURL)
        XCTAssertFalse(store.save(try credentials("bob")))
        XCTAssertEqual(try Data(contentsOf: store.accountsURL), corrupt)
    }
    func testCatalogEligibilityMatchesConfigurationKeys() throws {
        XCTAssertFalse(store.hasUsableAPIKey)
        var valid = try credentials("valid")
        valid.apiKeyExpiresAt = .distantFuture
        XCTAssertTrue(store.save(valid))
        XCTAssertTrue(store.hasUsableAPIKey)

        var expired = try credentials("expired")
        expired.apiKeyExpiresAt = .distantPast
        XCTAssertTrue(store.save(expired))
        XCTAssertTrue(store.save(try credentials("empty", key: "")))
        XCTAssertTrue(store.toggleDisabled(id: try XCTUnwrap(store.accounts.first?.id)))
        XCTAssertTrue(store.hasCredentials)
        XCTAssertFalse(store.hasUsableAPIKey)
        XCTAssertEqual(MetaMuseCredentialStore.compatibilityConfig(accounts: store.accounts, enabled: true), "")

        XCTAssertTrue(store.toggleDisabled(id: try XCTUnwrap(store.accounts.first?.id)))
        XCTAssertTrue(store.hasUsableAPIKey)
        XCTAssertEqual(MetaMuseCredentialStore.usableAPIKeys(accounts: store.accounts), [valid.apiKey])
        XCTAssertFalse(MetaMuseCredentialStore.compatibilityConfig(accounts: store.accounts, enabled: true).isEmpty)
    }

    func testKeyExpiringExactlyNowIsNotUsable() throws {
        let credentials = try credentials("boundary")
        let account = MetaMuseCredentialStore.account(for: credentials)
        XCTAssertTrue(MetaMuseCredentialStore.usableAPIKeys(
            accounts: [account], now: credentials.apiKeyExpiresAt
        ).isEmpty)
        XCTAssertEqual(MetaMuseCredentialStore.compatibilityConfig(
            accounts: [account], enabled: true, now: credentials.apiKeyExpiresAt
        ), "")
    }

    func testMutationsNotifyUIAndBackendOnMainQueue() throws {
        let changed = expectation(forNotification: .metaAccountsChanged, object: store) { _ in
            XCTAssertTrue(Thread.isMainThread)
            return true
        }
        XCTAssertTrue(store.save(try credentials("alice")))
        wait(for: [changed], timeout: 2)
    }

    func testRefreshContinuesAfterOneAccountFailsAndSkipsDisabledAccount() throws {
        for token in ["bad", "good", "disabled"] {
            XCTAssertTrue(store.save(MetaMuseCredentials(identityToken: token, apiKey: "old-\(token)",
                                                         apiKeyExpiresAt: .distantPast)))
        }
        XCTAssertTrue(store.toggleDisabled(id: try XCTUnwrap(store.accounts.last?.id)))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetaMockProtocol.self]
        let manager = MetaMuseAuthManager(store: store, configuration: configuration)
        let finished = expectation(description: "All account refreshes finish")
        manager.refreshAPIKeyIfNeeded { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .success = result { XCTFail("The failed account must surface an error") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(store.accounts.map(\.credentials.apiKey), ["old-bad", "new-good", "old-disabled"])
        XCTAssertNotNil(manager.lastError)
        XCTAssertFalse(manager.lastError?.contains("sensitive-body") ?? true)
    }

    func testCancelSignInPreservesExistingAccounts() throws {
        XCTAssertTrue(store.save(try credentials("alice")))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MetaMockProtocol.self]
        let manager = MetaMuseAuthManager(store: store, configuration: configuration)
        let unexpected = expectation(description: "Cancelled sign-in has no callbacks")
        unexpected.isInverted = true
        manager.startAuthentication(onDeviceCode: { _, _ in unexpected.fulfill() },
                                    completion: { _ in unexpected.fulfill() })
        manager.cancelAuthentication()
        wait(for: [unexpected], timeout: 0.2)
        XCTAssertEqual(manager.state, .connected)
        XCTAssertEqual(store.accounts.count, 1)
    }
}

private final class MetaMockProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let success = request.value(forHTTPHeaderField: "Authorization") == "Bearer good"
        let response = HTTPURLResponse(url: request.url!, statusCode: success ? 200 : 401,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((success ? #"{"api_key":"new-good"}"# :
            #"{"error_description":"sensitive-body"}"#).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
