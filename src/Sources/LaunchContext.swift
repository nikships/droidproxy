import Foundation

/// How this launch was started. Droid Office starts DroidProxy with
/// `open -g -a DroidProxy.app --args --launched-by droid-office`; that launch
/// runs normally but puts nothing of its own on screen: no notification
/// prompt or "Server Started" banner, and no Sparkle update window until the
/// owner opens Settings (the office checks for DroidProxy updates itself).
enum LaunchContext {
    static func launchedByDroidOffice(_ arguments: [String]) -> Bool {
        for (index, argument) in arguments.enumerated() {
            if argument == "--launched-by=droid-office" { return true }
            if argument == "--launched-by", index + 1 < arguments.count, arguments[index + 1] == "droid-office" {
                return true
            }
        }
        return false
    }

    static let isDroidOffice = launchedByDroidOffice(CommandLine.arguments)
}
