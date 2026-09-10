import Foundation

/// `agent --print` has Write/Shell even in Ask mode, and absolute paths escape
/// the chat-only temp cwd. Point `CURSOR_AGENT_BIN` at this wrapper so the
/// sidecar always passes `--sandbox enabled` and cannot execute Droid's tools.
enum CursorAgentSandboxWrapper {
    static let fileName = "cursor-agent-readonly"

    static func wrapperScript(realAgentPath: String) -> String {
        let escaped = realAgentPath.replacingOccurrences(of: "'", with: "'\\''")
        return """
        #!/bin/sh
        REAL="${CURSOR_AGENT_REAL_BIN:-}"
        if [ -z "$REAL" ]; then
          REAL='\(escaped)'
        fi
        cmd="${1-}"
        case "$cmd" in
          login|logout|status|mcp|plugin|persist|install-shell-integration|uninstall-shell-integration|worker)
            exec "$REAL" "$@"
            ;;
        esac
        sandbox_seen=0
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--sandbox" ]; then
            sandbox_seen=1
            break
          fi
          prev="$arg"
        done
        if [ "$sandbox_seen" -eq 0 ]; then
          exec "$REAL" --sandbox enabled "$@"
        fi
        exec "$REAL" "$@"
        """
    }

    static func install(realAgent: URL) -> URL? {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("DroidProxy", isDirectory: true)
        guard let support else { return nil }
        do {
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            let wrapper = support.appendingPathComponent(fileName)
            let script = wrapperScript(realAgentPath: realAgent.path)
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: wrapper.path
            )
            return wrapper
        } catch {
            NSLog("[CursorAgentProxy] Failed to install sandbox wrapper: %@", error.localizedDescription)
            return nil
        }
    }
}
