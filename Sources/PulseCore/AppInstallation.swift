import AppKit
import Foundation

public enum AppInstallation {
  public static func bundle(for executable: URL) throws -> URL {
    var candidate = executable.standardizedFileURL
    while candidate.path != "/" {
      if candidate.pathExtension == "app" { return candidate }
      candidate.deleteLastPathComponent()
    }
    throw PulseError("Install SidePulse.app before managing the app or sleep helper.")
  }
  public static func open(
    executable: URL, run: (String, [String]) throws -> Data = SystemCommand.execute
  ) throws {
    _ = try run("/usr/bin/open", [try bundle(for: executable).path])
  }
  public static func stop(
    bundleIdentifier: String = "com.unipheas.SidePulseSwift",
    terminate: (String) -> Bool = { identifier in
      NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .map { application in
          finishTermination(
            isTerminated: { application.isTerminated }, terminate: { application.terminate() },
            isReady: { application.isFinishedLaunching })
        }.allSatisfy { $0 }
    }
  ) throws {
    guard terminate(bundleIdentifier) else {
      throw PulseError("SidePulse could not quit. Close its windows and try again.")
    }
  }
  /// launchd bootout can begin termination before the app receives this request.
  /// A rejected request only counts as success if that same app actually exits.
  @usableFromInline
  static func finishTermination(
    isTerminated: () -> Bool, terminate: () -> Bool, isReady: () -> Bool = { true },
    wait: (TimeInterval) -> Void = waitForApplicationState
  ) -> Bool {
    if isTerminated() { return true }
    var launchWaits = 0
    while !isReady() {
      if isTerminated() { return true }
      guard launchWaits < 100 else { return false }
      wait(0.05)
      launchWaits += 1
    }
    if terminate() { return true }
    for _ in 0..<20 {
      if isTerminated() { return true }
      wait(0.05)
    }
    return isTerminated()
  }
  /// AppKit refreshes running-application snapshots on main-run-loop turns.
  /// Sleeping alone can leave launch/termination flags stale indefinitely.
  @usableFromInline
  static func waitForApplicationState(_ duration: TimeInterval) {
    let advance = { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
    if Thread.isMainThread { advance() }
    else { DispatchQueue.main.sync(execute: advance) }
  }
  public static func sleepHelper(
    action: String, executable: URL, dryRun: Bool, administratorPrompt: Bool = false,
    run: (String, [String]) throws -> Data = SystemCommand.execute
  ) throws -> String {
    guard ["install", "uninstall", "status"].contains(action) else {
      throw PulseError("Unknown helper action.")
    }
    if action == "status" {
      return FileManager.default.fileExists(
        atPath: "/private/etc/sudoers.d/sidepulse-swift-disablesleep")
        ? "installed" : "not installed"
    }
    let script = try bundle(for: executable).appendingPathComponent(
      "Contents/Resources/sleep-helper.sh")
    if dryRun { return "/usr/bin/sudo /bin/bash " + shellQuote(script.path) + " " + action }
    guard FileManager.default.fileExists(atPath: script.path) else {
      throw PulseError("The bundled sleep helper is missing.")
    }
    if administratorPrompt {
      let command =
        "/usr/bin/env SUDO_USER=" + shellQuote(NSUserName()) + " /bin/bash "
        + shellQuote(script.path) + " " + action
      _ = try run(
        "/usr/bin/osascript",
        [
          "-e", "on run argv", "-e",
          "do shell script (item 1 of argv) with administrator privileges", "-e", "end run", "--",
          command,
        ])
    } else {
      _ = try run("/usr/bin/sudo", ["/bin/bash", script.path, action])
    }
    return action == "install" ? "installed" : "removed"
  }
  /// A Sparkle relaunch replaces the GUI and bundled CLI together. Restart existing
  /// agents once for the new build so they do not keep executing the previous binary.
  public static func refreshServices(
    executable: URL, version: String,
    run: (String, [String]) throws -> Data = SystemCommand.execute
  ) throws {
    try withLock(Paths.support.appendingPathComponent("upgrade.lock")) {
      guard try Settings.read()["installed_build"] as? String != version else { return }
      for job in ["service", "sdejectguard"] {
        let domain = "gui/\(getuid())"
        if (try? run("/bin/launchctl", ["print", domain + "/" + Jobs.prefix + job])) != nil {
          try Jobs.configure(job, executable: executable, start: true, run: run)
        }
      }
      try Settings.update { $0["installed_build"] = version }
    }
  }
}
