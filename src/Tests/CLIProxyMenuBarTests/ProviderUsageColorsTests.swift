import XCTest
@testable import CLIProxyMenuBar

final class ProviderUsageColorsTests: XCTestCase {
    func testPopularityListsEveryProviderOnce() {
        XCTAssertEqual(ProviderUsageColors.popularity.count, ServiceType.allCases.count)
        XCTAssertEqual(Set(ProviderUsageColors.popularity), Set(ServiceType.allCases))
    }

    func testCurrentBrandsKeepTheirPrimaryColor() {
        for provider in ServiceType.allCases {
            let primary = ProviderUsageColors.palettes[provider]?.first
            XCTAssertEqual(ProviderUsageColors.swatch(for: provider), primary, "\(provider)")
        }
    }

    func testLessPopularProviderYieldsASharedPrimary() {
        let shared = ProviderBrandSwatch(red: 1, green: 2, blue: 3)
        let claudeSecondary = ProviderBrandSwatch(red: 4, green: 5, blue: 6)
        let assigned = ProviderUsageColors.resolve(
            popularity: [.codex, .claude],
            palettes: [
                .codex: [shared, ProviderBrandSwatch(red: 9, green: 9, blue: 9)],
                .claude: [shared, claudeSecondary],
            ]
        )

        XCTAssertEqual(assigned[.codex], shared)
        XCTAssertEqual(assigned[.claude], claudeSecondary)
    }

    func testCascadeContinuesWhenTheSecondaryIsAlsoTaken() {
        let primary = ProviderBrandSwatch(red: 1, green: 0, blue: 0)
        let secondary = ProviderBrandSwatch(red: 0, green: 1, blue: 0)
        let tertiary = ProviderBrandSwatch(red: 0, green: 0, blue: 1)
        let assigned = ProviderUsageColors.resolve(
            popularity: [.codex, .claude, .grok],
            palettes: [
                .codex: [primary, ProviderBrandSwatch(red: 8, green: 8, blue: 8)],
                .claude: [primary, secondary, ProviderBrandSwatch(red: 7, green: 7, blue: 7)],
                .grok: [secondary, tertiary],
            ]
        )

        XCTAssertEqual(assigned[.codex], primary)
        XCTAssertEqual(assigned[.claude], secondary)
        XCTAssertEqual(assigned[.grok], tertiary)
    }

    func testExhaustedPaletteDoesNotReuseAClaimedColor() {
        let only = ProviderBrandSwatch(red: 200, green: 180, blue: 160)
        let assigned = ProviderUsageColors.resolve(
            popularity: [.codex, .claude],
            palettes: [
                .codex: [only],
                .claude: [only],
            ]
        )

        XCTAssertEqual(assigned[.codex], only)
        XCTAssertNotEqual(assigned[.claude], only)
    }
}
