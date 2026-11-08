import Foundation
import PulseCore

extension CLI {
  static func localAgentEvent() throws {
    let source = try Args.option("--source")
    let run = try Args.option("--run")
    let state = try Args.option("--state")
    let sequence = try Args.option("--sequence")
    let started = try Args.option("--started-at")
    let lease = try Args.option("--lease-seconds") ?? "60"
    try Args.end()
    guard let source, let run, let state = state.flatMap(Mode.init(rawValue:)),
      let sequence = sequence.flatMap(UInt64.init), let lease = Double(lease),
      let started = started.flatMap(Double.init), started.isFinite
    else {
      throw PulseError(
        "Supply --source, --run, --started-at (Unix seconds), --state and a positive --sequence. States: "
          + Mode.allCases.map(\.rawValue).joined(separator: ", "))
    }
    let accepted = try LocalAgentEvents.record(
      source: source, run: run, state: state, sequence: sequence,
      startedAt: Date(timeIntervalSince1970: started), leaseSeconds: lease)
    print(accepted ? "{\"accepted\":true}" : "{\"accepted\":false}")
  }
}
