import XCTest
@testable import CLIProxyMenuBar

final class ControlDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-discovery-\(UUID().uuidString)")
            .appendingPathComponent(".droidproxy")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testTokenIs64HexCharactersAndNewEachTime() throws {
        let first = try XCTUnwrap(ControlDiscovery.makeToken())
        let second = try XCTUnwrap(ControlDiscovery.makeToken())
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(first.allSatisfy { "0123456789abcdef".contains($0) })
        XCTAssertNotEqual(first, second)
    }

    func testWritesThePrivateDiscoveryFile() throws {
        let url = try ControlDiscovery.write(directory: directory, port: 8317, token: "t0k3n", version: "1.8.180", pid: 4242)
        XCTAssertEqual(url, directory.appendingPathComponent("control.json"))
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(url), 0o600)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["api"] as? Int, 1)
        XCTAssertEqual(json["port"] as? Int, 8317)
        XCTAssertEqual(json["token"] as? String, "t0k3n")
        XCTAssertEqual(json["version"] as? String, "1.8.180")
        XCTAssertEqual(json["pid"] as? Int, 4242)
        XCTAssertEqual(json.count, 5)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["control.json"])
    }

    func testTightensAnExistingFolderAndReplacesTheFile() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let target = directory.appendingPathComponent("control.json")
        FileManager.default.createFile(atPath: target.path, contents: Data("old".utf8), attributes: [.posixPermissions: 0o644])

        try ControlDiscovery.write(directory: directory, port: 8317, token: "new", version: "1", pid: 1)
        XCTAssertEqual(try mode(directory), 0o700)
        XCTAssertEqual(try mode(target), 0o600)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        XCTAssertEqual(json["token"] as? String, "new")
    }

    func testRemovesOnlyItsOwnFile() throws {
        let url = try ControlDiscovery.write(directory: directory, port: 8317, token: "t", version: "1", pid: 10)
        ControlDiscovery.remove(directory: directory, pid: 11)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        ControlDiscovery.remove(directory: directory, pid: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

final class FactoryModelsTests: XCTestCase {
    private var directory: URL!
    private var settings: URL!
    private let catalogIDs: Set<String> = ["custom:droidproxy:opus-5-5", "custom:droidproxy:gpt-6.1-sol"]
    private let expected: [[String: Any]] = [
        ["id": "custom:droidproxy:opus-5-5", "model": "claude-opus-5-5"],
        ["id": "custom:droidproxy:gpt-6.1-sol", "model": "gpt-6.1-sol"]
    ]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("factory-models-\(UUID().uuidString)")
        settings = directory.appendingPathComponent("settings.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: settings)
    }

    func testMissingSettingsAreStale() {
        let status = FactoryModels.status(settingsAt: settings, expected: expected, catalogIDs: catalogIDs)
        XCTAssertEqual(status, FactoryModels.Status(installed: 0, available: 2, stale: true))
        XCTAssertFalse(status.isApplied)
    }

    func testStaleWhenAModelIsMissingOrRetired() throws {
        try writeSettings(["customModels": [
            ["id": "custom:droidproxy:opus-5-5"],
            ["id": "custom:droidproxy:grok-4.6"],
            ["id": "mine"]
        ]])
        let status = FactoryModels.status(settingsAt: settings, expected: expected, catalogIDs: catalogIDs)
        XCTAssertEqual(status, FactoryModels.Status(installed: 2, available: 2, stale: true))
    }

    func testApplyKeepsOtherModelsAndBacksUp() throws {
        try writeSettings([
            "theme": "dark",
            "customModels": [
                ["id": "mine", "model": "x"],
                ["id": "custom:droidproxy:grok-4.6"],
                ["id": "custom:CC:old"],
                ["id": "custom:droidproxy:opus-5-5", "model": "stale"]
            ]
        ])
        let result = try FactoryModels.apply(settingsAt: settings, models: expected, catalogIDs: catalogIDs)
        XCTAssertEqual(result.installed, 2)
        let backup = try XCTUnwrap(result.backup)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("settings.json.droidproxy-"))
        XCTAssertTrue(backup.lastPathComponent.hasSuffix(".bak"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual(json["theme"] as? String, "dark")
        let models = try XCTUnwrap(json["customModels"] as? [[String: Any]])
        XCTAssertEqual(models.compactMap { $0["id"] as? String }, ["mine", "custom:droidproxy:opus-5-5", "custom:droidproxy:gpt-6.1-sol"])
        XCTAssertEqual(models.compactMap { $0["index"] as? Int }, [1, 2])

        let status = FactoryModels.status(settingsAt: settings, expected: expected, catalogIDs: catalogIDs)
        XCTAssertEqual(status, FactoryModels.Status(installed: 2, available: 2, stale: false))
        XCTAssertTrue(status.isApplied)
    }

    func testApplyWithoutSettingsHasNoBackup() throws {
        let result = try FactoryModels.apply(settingsAt: settings, models: expected, catalogIDs: catalogIDs)
        XCTAssertNil(result.backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
    }
}
