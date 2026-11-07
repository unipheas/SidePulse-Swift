import AppKit
import SwiftUI
import ViewInspector
import XCTest

@testable import PulseCore
@testable import SidePulse

final class HistoryExportActionTests: IsolatedTests {
  @MainActor func testHistoryAndAuditExportButtonsHandleCancellationSuccessAndFailure() throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    try History.record(.working, battery: 73)
    try Audit.record(provider: "codex", row: [
      "hook_event_name": "UserPromptSubmit", "session_id": "export-fixture",
      "message": "Distinct audit payload",
    ], status: nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for audit in [false, true] {
      for format in ["csv", "html"] {
        for outcome in ["cancel", "success", "failure"] {
          model.problem = nil
          let filename = "SidePulse " + (audit ? "Events." : "History.") + format
          let target = directory.appendingPathComponent(filename)
          try? FileManager.default.removeItem(at: target)
          if outcome == "failure" {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
          }
          var calls = 0
          let run: (NSSavePanel) -> URL? = { panel in
            calls += 1
            XCTAssertEqual(panel.nameFieldStringValue, filename)
            panel.directoryURL = directory
            return outcome == "cancel" ? nil : target
          }
          let view = HistoryExportButtons(audit: audit, selectSaveURL: run).environmentObject(model)
          let title = audit ? "Export event " + format.uppercased() + "…" : format.uppercased()
          try view.inspect().find(button: title).tap()
          XCTAssertEqual(calls, 1)
          if outcome == "success" {
            let contents = try String(contentsOf: target)
            XCTAssertTrue(contents.contains(audit ? "Distinct audit payload" : "73"))
            XCTAssertTrue(contents.contains(audit ? "hook_event" : "battery_percent"))
            XCTAssertFalse(contents.contains(audit ? "battery_percent" : "Distinct audit payload"))
            if format == "html" {
              XCTAssertTrue(contents.hasPrefix("<!doctype html>"))
              XCTAssertTrue(contents.contains(audit ? "SidePulse Agent Debug Log" : "SidePulse history"))
            } else {
              XCTAssertTrue(contents.hasPrefix(audit ? "audited_at," : "time_utc,"))
            }
            XCTAssertNil(model.problem)
          } else if outcome == "failure" {
            XCTAssertNotNil(model.problem)
          } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
            XCTAssertNil(model.problem)
          }
        }
      }
    }
  }
}

extension HostedActionTests {
  @MainActor func testHistoryChartsLayOutAllTelemetrySeriesSmoke() async throws {
    let model = Dashboard(discover: { [] }, outputInUse: { true }, poll: false)
    var records = [Change]()
    for enabled in [false, true] {
      let power = try JSONDecoder().decode(PowerSnapshot.self, from: Data("{\"lidClosed\":\(enabled),\"sleepDisabled\":\(enabled)}".utf8))
      records.append(Change(date: Date().addingTimeInterval(enabled ? -10 : -20), mode: .working,
        battery: enabled ? 90 : 80, chargerWatts: 60, batteryWatts: 12,
        keepingAwake: enabled, power: power))
    }
    var data = Data()
    for record in records {
      data.append(try JSONEncoder().encode(record))
      data.append(10)
    }
    try data.write(to: History.file)
    for metric in ["Battery", "Charger and battery power", "Sleep and lid", "Agent state"] {
      // Layout evaluates each ChartContent series without GPU rasterization. Some
      // Intel CI runners expose a Metal device that cannot compile chart shaders.
      let content = NSHostingView(rootView: HistoryView(metric: metric).environmentObject(model))
      content.frame = NSRect(x: 0, y: 0, width: 800, height: 900)
      content.layoutSubtreeIfNeeded()
      await settle()
      XCTAssertGreaterThan(content.fittingSize.width, 0, metric)
      XCTAssertGreaterThan(content.fittingSize.height, 0, metric)
    }
  }
}
