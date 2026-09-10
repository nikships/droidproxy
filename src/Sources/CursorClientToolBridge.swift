import Foundation

/// Turns the Cursor Agent CLI into a **Droid** tool-calling backend.
///
    /// `cursor-api-proxy` wraps `agent --print`. Cursor `--mode ask` (plus chat-only
    /// cwd) is not enough: `--print` still has Write/Shell, and absolute paths
    /// escape the temp workspace. `CursorAgentSandboxWrapper` forces
    /// `--sandbox enabled`. This injects a system prompt **and** a last-user
    /// reminder so the model emits Factory tool markup (or JSON) that
    /// `GrokNativeToolCallRewriter` lifts into OpenAI `tool_calls` for Droid.
enum CursorClientToolBridge {
    static let marker = "CURSOR_DROID_CLIENT_TOOLS"

    static let systemPrompt = """
    [\(marker)] You are the LLM behind Droid (Factory). Droid is the only process that may create, edit, or delete files or run a shell. Cursor CLI Write/Shell/Delete are sandboxed and must not be used; they are not visible in Droid's session.
    Droid file tools are Create (new file: file_path, content), Edit, and Execute (shell, including rm). There is no Write or Delete tool.
    When you need to act, reply with ONLY Factory native tool markup, then stop. Do not narrate that a file was created.

    <|tool_calls_begin|><|tool_call_begin|>
    Create
    <|tool_sep|>file_path
    /absolute/path
    <|tool_sep|>content
    file body
    <|tool_call_end|><|tool_calls_end|>

    A fenced JSON object {"name":"Create","arguments":{"file_path":"...","content":"..."}} is also accepted. To delete a file, emit Execute with {"command":"rm -f /absolute/path"}. Cursor Write/Delete JSON is remapped, but prefer Create and Execute.
    Never say Ask mode is on. Never tell the user to switch to Agent mode. Never claim you already created or deleted a file. Never paste file contents as a substitute for a tool call.
    """

    static let userReminder = """

    [\(marker)] Reminder: do not use Cursor Write/Shell. They are sandboxed. Reply with Factory Create/Execute markup or JSON for Droid. After tools succeed, stop. Never say Ask mode is on.
    """

    /// Prepends the Droid-client instruction, appends a last-turn reminder, and
    /// pins `mode=ask` so Cursor cannot execute tools. Returns nil when the body
    /// is not a JSON object or the instruction is already fully present.
    static func inject(into jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var messages = normalizedMessages(root["messages"])
        var changed = false

        let hasSystem = messages.first.map {
            $0["role"] as? String == "system" && messageText($0).contains(marker)
        } ?? false
        if !hasSystem {
            messages.insert(
                ["role": "system", "content": systemPrompt],
                at: 0
            )
            changed = true
        }

        if appendReminderIfNeeded(to: &messages) {
            changed = true
        }

        if root["mode"] as? String != "ask" {
            root["mode"] = "ask"
            changed = true
        }

        guard changed else { return nil }
        root["messages"] = messages

        guard let out = try? JSONSerialization.data(withJSONObject: root),
              let str = String(data: out, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    private static func appendReminderIfNeeded(to messages: inout [[String: Any]]) -> Bool {
        guard !messages.isEmpty else { return false }
        var index = messages.count - 1
        while index >= 0, messages[index]["role"] as? String != "user" {
            index -= 1
        }
        guard index >= 0 else { return false }
        var last = messages[index]
        if messageText(last).contains(marker) {
            return false
        }
        if let text = last["content"] as? String {
            last["content"] = text + userReminder
        } else if var parts = last["content"] as? [[String: Any]] {
            parts.append(["type": "text", "text": userReminder])
            last["content"] = parts
        } else if var parts = last["content"] as? [Any] {
            parts.append(["type": "text", "text": userReminder] as [String: Any])
            last["content"] = parts
        } else {
            last["content"] = userReminder
        }
        messages[index] = last
        return true
    }

    private static func normalizedMessages(_ raw: Any?) -> [[String: Any]] {
        guard let rows = raw as? [Any] else { return [] }
        return rows.compactMap { $0 as? [String: Any] }
    }

    private static func messageText(_ message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        guard let parts = message["content"] as? [Any] else { return "" }
        return parts.compactMap { part -> String? in
            if let text = part as? String { return text }
            guard let obj = part as? [String: Any] else { return nil }
            return obj["text"] as? String
        }.joined()
    }
}
