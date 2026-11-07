import Foundation

/// Keep the same five-minute grace period for idle-sleep and closed-lid protection.
struct AgentAwakeRequest {
  private var previous: Mode?
  private var grace: Date?
  mutating func update(mode: Mode, now: Date) -> Bool {
    defer { previous = mode }
    if [.working, .tool, .progress].contains(mode) {
      grace = nil
      return true
    }
    if [.done, .waiting, .blocked].contains(mode), previous != mode || grace == nil {
      grace = now.addingTimeInterval(300)
    }
    return grace.map { now < $0 } ?? false
  }
}

enum LidAnimationPolicy {
  static func shouldClose(settings: JSONObject, agentsActive: Bool) -> Bool {
    let policy = SleepSettings.policy(settings)
    return policy != "always" && !(policy == "agents" && agentsActive)
  }
  static func shouldHold(closed: Bool?, settings: JSONObject, agentsActive: Bool, battery: Battery?)
    -> Bool
  {
    let safeguard =
      battery.map { !$0.plugged && Double($0.percent) < SleepSettings.minimum(settings) } ?? false
    return closed == true
      && (safeguard || shouldClose(settings: settings, agentsActive: agentsActive))
  }
}
