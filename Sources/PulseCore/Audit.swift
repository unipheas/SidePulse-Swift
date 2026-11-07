import CryptoKit
import Foundation

/// Event-level diagnostics complement the compact state-change history.
public enum Audit {
  public static let columns = [
    "audited_at", "logged_at", "provider", "hook_event", "status", "status_label", "origin",
    "display_name", "session_id", "agent_id", "cwd", "tool_name", "message", "raw_preview",
  ]
  static var file: URL { Paths.support.appendingPathComponent("event-status.jsonl") }
  static func preview(_ text: String, limit: Int) -> String {
    let compact = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard compact.count > limit else { return compact }
    return String(compact.prefix(max(0, limit - 3))).trimmingCharacters(in: .whitespaces) + "..."
  }
  typealias Input = (provider: String, row: JSONObject, status: Session?)
  private static func entry(provider: String, row: JSONObject, status: Session?, now: Date) throws
    -> [String: String]
  {
    let raw = row["event"] as? JSONObject ?? row
    let normalized = HookPayload.normalized(raw, provider: provider) ?? raw
    let serialized = try JSONSerialization.data(
      withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
    let logged = row["logged_at"] as? String ?? raw["timestamp"] as? String ?? ""
    let identity = SHA256.hash(data: Data((provider + logged).utf8) + serialized)
      .map { String(format: "%02x", $0) }.joined()
    let message =
      ["message", "last_assistant_message", "prompt"].compactMap { raw[$0] as? String }
      .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    let record: [String: String] = [
      "id": identity, "audited_at": now.ISO8601Format(), "logged_at": logged, "provider": provider,
      "hook_event": normalized["hook_event_name"] as? String ?? "",
      "status": status?.mode.rawValue ?? "", "status_label": status?.mode.label ?? "",
      "origin": status?.origin ?? normalized["agent_origin"] as? String ?? "",
      "display_name": status?.name ?? "", "session_id": normalized["session_id"] as? String ?? "",
      "agent_id": status?.id ?? "", "cwd": status?.cwd ?? normalized["cwd"] as? String ?? "",
      "tool_name": normalized["tool_name"] as? String ?? "",
      "message": preview(message, limit: 240),
      "raw_preview": preview(String(decoding: serialized, as: UTF8.self), limit: 2000),
    ]
    return record
  }
  static func record(provider: String, row: JSONObject, status: Session?, now: Date = Date()) throws
  {
    try records([(provider, row, status)], now: now)
  }
  static func records(_ incoming: [Input], now: Date = Date()) throws {
    guard !incoming.isEmpty else { return }
    let entries = try incoming.map {
      try entry(provider: $0.provider, row: $0.row, status: $0.status, now: now)
    }
    try withLock(Paths.support.appendingPathComponent("audit.lock")) {
      var data = (try? Data(contentsOf: file)) ?? Data()
      var identities = Set(
        data.split(separator: 10).compactMap {
          ((try? JSONSerialization.jsonObject(with: $0)) as? [String: String])?["id"]
        })
      var changed = false
      for record in entries {
        guard identities.insert(record["id"]!).inserted else { continue }
        if data.count >= 1_048_576 {
          data = Data(data.suffix(524288).drop(while: { $0 != 10 }).dropFirst())
        }
        data.append(try JSONSerialization.data(withJSONObject: record, options: .sortedKeys))
        data.append(10)
        changed = true
      }
      guard changed else { return }
      try data.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
  }
  public static func recent(limit: Int = 200) -> [[String: String]] {
    guard limit > 0, let data = try? Data(contentsOf: file) else { return [] }
    return data.split(separator: 10).suffix(limit).compactMap {
      (try? JSONSerialization.jsonObject(with: $0)) as? [String: String]
    }
  }
  public static func export(to url: URL) throws {
    try TableExport.write(
      title: "SidePulse Agent Debug Log", columns: columns,
      rows: recent(limit: .max).map { row in columns.map { row[$0] ?? "" } }, to: url)
  }
}

public enum TableExport {
  static func html(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
  }
  public static func write(title: String, columns: [String], rows: [[String]], to url: URL) throws {
    let content: String
    if url.pathExtension.lowercased() == "html" {
      let header = columns.map { "<th>\(html($0))</th>" }.joined()
      let body = rows.map { "<tr>" + $0.map { "<td>\(html($0))</td>" }.joined() + "</tr>" }.joined()
      content =
        "<!doctype html><meta charset=utf-8><title>\(html(title))</title>"
        + "<style>body{font:14px system-ui;margin:24px}table{border-collapse:collapse;width:100%}"
        + "th,td{text-align:left;vertical-align:top;padding:8px;border-bottom:1px solid #ddd;overflow-wrap:anywhere}</style>"
        + "<h1>\(html(title))</h1><table><thead><tr>\(header)</tr></thead><tbody>\(body)</tbody></table>"
    } else {
      content =
        ([columns] + rows).map { row in
          row.map { cell in
            cell.rangeOfCharacter(from: CharacterSet(charactersIn: ",\"\r\n")) == nil
              ? cell : "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
          }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }
    try Paths.directory(url.deletingLastPathComponent())
    try Data(content.utf8).write(to: url, options: .atomic)
  }
}
