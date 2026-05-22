import Foundation

enum AuthPaths {
    static var authDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cli-proxy-api")
    }
}
