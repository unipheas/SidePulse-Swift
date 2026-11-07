import Foundation

extension Terminal {
  static func title(for session: Session) -> String {
    let title =
      "SidePulse " + session.provider.capitalized + " " + session.name
      + " (" + String((session.threadID ?? session.session).prefix(8)) + ")"
    return String(
      title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(160))
  }
  static func focus(_ session: Session, app: String, run: (String, [String]) throws -> Data) -> Bool
  {
    guard let id = session.threadID, !id.isEmpty else { return false }
    let name = URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent.lowercased()
    let script: String
    if name == "terminal" {
      script = """
        on run argv
          if application "Terminal" is not running then return "0"
          tell application "Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                set titleText to custom title of t
                set bodyText to contents of t
                repeat with marker in argv
                  if titleText contains (marker as text) or bodyText contains (marker as text) then
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return "1"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "0"
        end run
        """
    } else if name.contains("iterm") {
      script = """
        on run argv
          if application "iTerm" is not running then return "0"
          tell application "iTerm"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  set titleText to name of s
                  set bodyText to contents of s
                  repeat with marker in argv
                    if titleText contains (marker as text) or bodyText contains (marker as text) then
                      tell w to select t
                      select s
                      set index of w to 1
                      activate
                      return "1"
                    end if
                  end repeat
                end repeat
              end repeat
            end repeat
          end tell
          return "0"
        end run
        """
    } else if name == "ghostty" {
      script = """
        on run argv
          if application "Ghostty" is not running then return "0"
          tell application "Ghostty"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in terminals of t
                  set titleText to (name of w) & " " & (name of t) & " " & (name of s)
                  repeat with marker in argv
                    if titleText contains (marker as text) then
                      select tab t
                      focus s
                      activate window w
                      activate
                      return "1"
                    end if
                  end repeat
                end repeat
              end repeat
            end repeat
          end tell
          return "0"
        end run
        """
    } else {
      return false
    }
    guard let data = try? run("/usr/bin/osascript", ["-e", script, "--", id, title(for: session)])
    else { return false }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      == "1"
  }
  static func titledCommand(_ command: String, session: Session?) -> String {
    guard let session else { return command }
    return "printf '\\033]0;%s\\007' " + shellQuote(title(for: session)) + "; " + command
  }
}
