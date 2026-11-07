import Foundation

/// Normalize provider-specific spellings at the boundary so transitions see one event vocabulary.
enum HookPayload {
  private static let aliases: [String: String] = {
    let all = Hooks.events.filter { $0.key != "cursor" }.values.flatMap { $0 }
    var result = Dictionary(all.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    result.merge([
      "subagentend": "SubagentStop", "beforesubmitprompt": "UserPromptSubmit",
      "beforeshellexecution": "PreToolUse", "aftershellexecution": "PostToolUse",
      "afterfileedit": "PostToolUse",
    ]) { _, b in b }
    return result
  }()
  static func normalized(_ source: JSONObject, provider: String) -> JSONObject? {
    var raw = source
    let fields = [
      "agentId": "agent_id", "sessionId": "session_id", "workspaceRoot": "cwd",
      "toolName": "tool_name", "toolInput": "tool_input", "toolResponse": "tool_response",
      "lastAssistantMessage": "last_assistant_message", "notificationType": "notification_type",
      "agentOrigin": "agent_origin",
    ]
    for (source, target) in fields where raw[target] == nil { raw[target] = raw[source] }
    let spelling =
      ["hook_event_name", "hookEventName", "event_name", "eventName"]
      .compactMap { raw[$0] as? String }.first ?? ""
    let key = spelling.lowercased().filter { $0.isLetter || $0.isNumber }
    guard var event = aliases[key] else { return nil }
    if provider == "cursor" {
      if event == "PostToolUseFailure" { event = "StopFailure" }
      raw["session_id"] = raw["conversation_id"] ?? raw["conversationId"] ?? raw["session_id"]
      let roots = (raw["workspace_roots"] ?? raw["workspaceRoots"]) as? [String]
      raw["cwd"] = roots?.first ?? raw["workspace_root"] ?? raw["cwd"]
      raw["agent_origin"] = "Cursor"
      if event == "PostToolUse", let code = raw["exit_code"] {
        raw["tool_response"] = ["exit_code": code]
      }
    }
    raw["hook_event_name"] = event
    return raw
  }
  static func failed(_ value: Any?) -> Bool {
    if let result = value as? JSONObject {
      return result["success"] as? Bool == false || result["interrupted"] as? Bool == true
        || result["is_error"] as? Bool == true || (result["exit_code"] as? Int ?? 0) != 0
    }
    let text = (value as? String ?? "").lowercased()
    return text.contains("traceback") || text.contains("exit code: 1")
  }
  static func asksQuestion(_ message: String) -> Bool {
    let plain = message.replacingOccurrences(
      of: #"(?s)```.*?```|`[^`\n]*`"#, with: "", options: .regularExpression)
    let direct = [
      "please confirm", "please choose", "choose ", "need me to ", "want me to ",
      "should i ", "should we ", "do you want me to ",
    ]
    let questions =
      direct + [
        "which ", "what ", "where ", "when ", "who ", "why ", "how ",
        "can you ", "could you ", "shall i ",
      ]
    let ignored = [
      "* cogitated ", "* recap:", "※ recap:", "recap:", "anything else", "any other",
      "all good", "need anything else", "want anything else", "anything you want",
      "anything you'd like",
    ]
    let lines = plain.lowercased().components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(8)
    return lines.contains { line in
      guard !line.hasSuffix(":"), !ignored.contains(where: line.hasPrefix) else { return false }
      return direct.contains(where: line.hasPrefix)
        || (line.hasSuffix("?") && questions.contains(where: line.hasPrefix))
        || line.range(
          of: #"(?:^|[.!?]\s+)(?:want me to|need me to|should i|should we|do you want me to)\b"#,
          options: .regularExpression) != nil
    }
  }
}
