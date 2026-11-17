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

    func testGpt62ReplacementsKeepOptOutsAndCanBeReenabled() {
        let suiteName = "FactoryModelPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([" gpt-6-astra ", "gpt-6.1-sol", "gpt-6.2-sol", "gpt-6-luna"],
                     forKey: FactoryModelPreferences.disabledModelSlugsKey)

        XCTAssertEqual(FactoryModelPreferences.disabledModelSlugs(in: defaults),
                       ["gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"])
        let entries = DroidProxyModelCatalog.settingsModels(
            providerIsEnabled: { $0 == "codex" },
            disabledModelSlugs: FactoryModelPreferences.disabledModelSlugs(in: defaults)
        )
        XCTAssertEqual(entries.compactMap { $0["model"] as? String }, ["gpt-6.1-terra"])

        for slug in ["gpt-6.2-astra", "gpt-6.2-sol"] {
            XCTAssertFalse(FactoryModelPreferences.isEnabled(slug: slug, in: defaults))
            FactoryModelPreferences.setEnabled(true, slug: slug, in: defaults)
            XCTAssertTrue(FactoryModelPreferences.isEnabled(slug: slug, in: defaults))
        }
        XCTAssertEqual(FactoryModelPreferences.disabledModelSlugs(in: defaults), ["gpt-6-luna"])
    }
}
