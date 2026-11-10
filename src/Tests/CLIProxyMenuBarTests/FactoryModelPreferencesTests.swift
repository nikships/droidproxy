import XCTest
@testable import CLIProxyMenuBar

final class FactoryModelPreferencesTests: XCTestCase {
    func testDisabledModelSlugsPersistAndCanBeReenabled() {
        let suiteName = "FactoryModelPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(FactoryModelPreferences.isEnabled(slug: "opus-5-5", in: defaults))

        FactoryModelPreferences.setEnabled(false, slug: "opus-5-5", in: defaults)
        XCTAssertFalse(FactoryModelPreferences.isEnabled(slug: "opus-5-5", in: defaults))
        XCTAssertEqual(FactoryModelPreferences.disabledModelSlugs(in: defaults), ["opus-5-5"])

        FactoryModelPreferences.setEnabled(true, slug: "opus-5-5", in: defaults)
        XCTAssertTrue(FactoryModelPreferences.isEnabled(slug: "opus-5-5", in: defaults))
        XCTAssertTrue(FactoryModelPreferences.disabledModelSlugs(in: defaults).isEmpty)
    }

    func testSettingsModelsExcludeDisabledModelSlugs() {
        let entries = DroidProxyModelCatalog.settingsModels(
            providerIsEnabled: { $0 == "claude" },
            disabledModelSlugs: ["opus-5-5"]
        )
        let ids = Set(entries.compactMap { $0["id"] as? String })

        XCTAssertFalse(ids.contains("custom:droidproxy:opus-5-5"))
        XCTAssertTrue(ids.contains("custom:droidproxy:fable-5-2"))
    }
}
