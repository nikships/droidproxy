import XCTest
@testable import CLIProxyMenuBar

final class AppPreferencesFastModeDefaultsTests: XCTestCase {
    /// Fast Mode is opt-in. Absent keys must read as false so the Settings
    /// checkboxes start unchecked.
    func testAllFastModeDefaultsAreOff() {
        XCTAssertFalse(AppPreferences.defaultGpt6AstraFastMode)
        XCTAssertFalse(AppPreferences.defaultGpt61SolFastMode)
        XCTAssertFalse(AppPreferences.defaultGpt6LunaFastMode)
    }

    func testUnsetFastModeKeysReadAsFalse() {
        let defaults = UserDefaults.standard
        let keys = [
            AppPreferences.gpt6AstraFastModeKey,
            AppPreferences.gpt61SolFastModeKey,
            AppPreferences.gpt6LunaFastModeKey
        ]
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        XCTAssertFalse(AppPreferences.gpt6AstraFastMode)
        XCTAssertFalse(AppPreferences.gpt61SolFastMode)
        XCTAssertFalse(AppPreferences.gpt6LunaFastMode)
    }
}
