import XCTest
@testable import CLIProxyMenuBar

final class MistralCredentialStoreTests: XCTestCase {
    private var directory: URL!
    private var store: MistralCredentialStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = MistralCredentialStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testSavingTheSameKeyTwiceKeepsOneAccountAndUpdatesTheLabel() {
        XCTAssertTrue(store.save(apiKey: "key-one", label: nil, source: .browser))
        XCTAssertTrue(store.save(apiKey: "  key-one\n", label: "Work", source: .pasted))
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts.first?.label, "Work")
        XCTAssertEqual(store.accounts.first?.source, .pasted)
        XCTAssertEqual(store.accounts.first?.apiKey, "key-one")
        // A later save without a label does not erase it.
        XCTAssertTrue(store.save(apiKey: "key-one", label: "  ", source: .pasted))
        XCTAssertEqual(store.accounts.first?.label, "Work")
    }

    func testDifferentKeysAreDifferentAccounts() {
        XCTAssertTrue(store.save(apiKey: "key-one", label: nil, source: .pasted))
        XCTAssertTrue(store.save(apiKey: "key-two", label: nil, source: .pasted))
        XCTAssertEqual(store.accounts.count, 2)
        XCTAssertEqual(Set(store.accounts.map(\.id)).count, 2)
        XCTAssertEqual(store.accounts.last?.displayName, "Mistral ••••-two")
    }

    func testEmptyKeyIsRejected() {
        XCTAssertFalse(store.save(apiKey: " \n", label: "x", source: .pasted))
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testRemoveAndLastEnabledAccountCannotBeDisabled() throws {
        store.save(apiKey: "a", label: nil, source: .pasted)
        store.save(apiKey: "b", label: nil, source: .pasted)
        let first = try XCTUnwrap(store.accounts.first?.id)
        let second = try XCTUnwrap(store.accounts.last?.id)

        XCTAssertTrue(store.toggleDisabled(id: first))
        XCTAssertFalse(store.toggleDisabled(id: second), "the last enabled account stays on")
        XCTAssertTrue(store.toggleDisabled(id: first), "a disabled account can be enabled again")

        XCTAssertTrue(store.remove(id: first))
        XCTAssertFalse(store.remove(id: first))
        XCTAssertEqual(store.accounts.map(\.id), [second])
    }

    func testFolderAndFilePermissions() throws {
        store.save(apiKey: "a", label: nil, source: .pasted)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let file = try FileManager.default.attributesOfItem(atPath: store.accountsURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(folder, 0o700)
        XCTAssertEqual(file, 0o600)
    }

    func testConfigEntryUsesOnlyEnabledAccountsAndTheProviderSwitch() throws {
        store.save(apiKey: "a", label: nil, source: .pasted)
        store.save(apiKey: "b", label: nil, source: .pasted)
        XCTAssertEqual(store.compatibilityEntry(enabled: true)?.apiKeys, ["a", "b"])
        XCTAssertEqual(store.compatibilityEntry(enabled: true)?.models, MistralCredentialStore.modelIDs)
        XCTAssertEqual(store.compatibilityEntry(enabled: true)?.baseURL, "https://api.mistral.ai/v1")
        XCTAssertNil(store.compatibilityEntry(enabled: false))

        XCTAssertTrue(store.toggleDisabled(id: try XCTUnwrap(store.accounts.first?.id)))
        XCTAssertEqual(store.compatibilityEntry(enabled: true)?.apiKeys, ["b"])
        XCTAssertTrue(store.hasUsableAPIKey)
    }

    func testNoAccountsMeansNoEntry() {
        XCTAssertNil(store.compatibilityEntry(enabled: true))
        XCTAssertFalse(store.hasUsableAPIKey)
    }

    func testPayloadFilterStripsReasoningContentForEveryModelOnlyWhenRouted() {
        XCTAssertEqual(MistralCredentialStore.payloadFilterConfig(accounts: store.accounts, enabled: true), "")
        store.save(apiKey: "a", label: nil, source: .pasted)
        XCTAssertEqual(MistralCredentialStore.payloadFilterConfig(accounts: store.accounts, enabled: false), "")

        let config = MistralCredentialStore.payloadFilterConfig(accounts: store.accounts, enabled: true)
        XCTAssertTrue(config.hasPrefix("\n# Mistral message filter (auto-added by DroidProxy)\npayload:\n  filter:\n    - models:\n"))
        for model in MistralCredentialStore.modelIDs {
            XCTAssertTrue(config.contains("        - name: \"\(model)\"\n          protocol: \"openai\"\n"), model)
        }
        XCTAssertTrue(config.hasSuffix("      params:\n        - 'messages.#(reasoning_content)#.reasoning_content'\n"))
        XCTAssertEqual(config.components(separatedBy: "payload:").count, 2)
    }

    func testAuthAccountsAreNeverExpired() throws {
        store.save(apiKey: "abcd1234", label: nil, source: .browser)
        let account = try XCTUnwrap(store.authAccounts.first)
        XCTAssertEqual(account.type, .mistral)
        XCTAssertFalse(account.isExpired)
        XCTAssertFalse(account.isAccessExpired)
        XCTAssertEqual(account.displayName, "Mistral ••••1234")
        XCTAssertFalse(account.isDisabled)
    }

    func testCorruptStoreIsNotOverwritten() throws {
        store.save(apiKey: "a", label: nil, source: .pasted)
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: store.accountsURL)
        XCTAssertFalse(store.save(apiKey: "b", label: nil, source: .pasted))
        XCTAssertEqual(try Data(contentsOf: store.accountsURL), corrupt)
    }

    func testMutationsNotifyOnTheMainQueue() {
        let changed = expectation(forNotification: .mistralAccountsChanged, object: store) { _ in
            XCTAssertTrue(Thread.isMainThread)
            return true
        }
        store.save(apiKey: "a", label: nil, source: .pasted)
        wait(for: [changed], timeout: 2)
    }
}
