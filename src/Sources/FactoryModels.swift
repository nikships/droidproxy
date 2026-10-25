import Foundation

/// DroidProxy's entries in the `customModels` of Factory's `~/.factory/settings.json`.
/// The Settings window's Apply button and `POST /droidproxy/control/factory-models`
/// both go through here, so the two always write and judge the same thing.
enum FactoryModels {
    struct Status: Equatable {
        /// DroidProxy models in Droid's settings now.
        let installed: Int
        /// DroidProxy models Apply would write now.
        let available: Int
        /// Droid's settings differ from what Apply would write now.
        let stale: Bool

        var isApplied: Bool { available > 0 && !stale }
    }

    struct ApplyResult: Equatable {
        let installed: Int
        let backup: URL?
    }

    /// Ids retired by prior releases. Removed from `customModels` during Apply/Re-apply
    /// so users don't end up with stale entries next to the current ones.
    static let legacyIDs: Set<String> = [
        "custom:droidproxy:grok-4.5",
        "custom:droidproxy:grok-4.6",
        "custom:droidproxy:cursor-composer-2.5",
        "custom:droidproxy:cursor-grok-4.5",
        "custom:droidproxy:cursor-grok-4.5-fast",
        "custom:droidproxy:cursor-grok-4.6",
        "custom:droidproxy:cursor-grok-4.6-fast",
        "custom:droidproxy:cursor-small"
    ]

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".factory")
            .appendingPathComponent("settings.json")
    }

    static func isDroidProxyID(_ id: String, catalogIDs: Set<String>) -> Bool {
        catalogIDs.contains(id)
            || legacyIDs.contains(id)
            || id.hasPrefix("custom:droidproxy:")
            || id.hasPrefix("custom:CC:")
    }

    static func status(settingsAt url: URL, expected: [[String: Any]], catalogIDs: Set<String>) -> Status {
        let expectedIDs = Set(expected.compactMap { $0["id"] as? String })
        let installedIDs: Set<String>
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["customModels"] as? [[String: Any]] {
            installedIDs = Set(models.compactMap { $0["id"] as? String }.filter { isDroidProxyID($0, catalogIDs: catalogIDs) })
        } else {
            installedIDs = []
        }
        return Status(installed: installedIDs.count, available: expectedIDs.count, stale: installedIDs != expectedIDs)
    }

    /// Replaces every earlier DroidProxy entry with `models`, keeps the user's
    /// other custom models, and copies the old file to a timestamped backup first.
    static func apply(
        settingsAt url: URL,
        models enabledModels: [[String: Any]],
        catalogIDs: Set<String>,
        now: Date = Date()
    ) throws -> ApplyResult {
        let factoryDir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: factoryDir, withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var models = (settings["customModels"] as? [[String: Any]]) ?? []
        models.removeAll { item in
            guard let id = item["id"] as? String else { return false }
            return isDroidProxyID(id, catalogIDs: catalogIDs)
        }

        let startIndex = models.count
        for (offset, var model) in enabledModels.enumerated() {
            model["index"] = startIndex + offset
            models.append(model)
        }
        settings["customModels"] = models

        let backup = backupIfPresent(url, now: now)

        var data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        if var jsonString = String(data: data, encoding: .utf8) {
            jsonString = jsonString.replacingOccurrences(of: "\\/", with: "/")
            data = jsonString.data(using: .utf8) ?? data
        }
        try data.write(to: url, options: .atomic)
        NSLog("[FactoryModels] Factory custom models applied to %@", url.path)
        return ApplyResult(installed: enabledModels.count, backup: backup)
    }

    private static func backupIfPresent(_ url: URL, now: Date) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let backupURL = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.droidproxy-\(formatter.string(from: now)).bak")

        do {
            try FileManager.default.copyItem(at: url, to: backupURL)
            NSLog("[FactoryModels] Backed up Factory settings to %@", backupURL.path)
            return backupURL
        } catch {
            NSLog("[FactoryModels] Failed to back up Factory settings before applying custom models: %@", error.localizedDescription)
            return nil
        }
    }
}
