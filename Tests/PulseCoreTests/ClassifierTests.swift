import XCTest

@testable import PulseCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

final class ClassifierTests: XCTestCase {
  func testClassifierMatchesLegacyLabelParsingAndRejectsAmbiguousOutputs() {
    for (raw, label) in [
      ("0", "NO_REPLY_REQUIRED"), ("1. reply", "REPLY_REQUIRED"), ("2 uncertain", "UNCERTAIN"),
      ("  no_reply_required. ", "NO_REPLY_REQUIRED"),
      ("REPLY_REQUIRED REPLY_REQUIRED", "REPLY_REQUIRED"),
      ("NO_REPLY_REQUIRED or REPLY_REQUIRED", "UNCERTAIN"), ("not a label", "UNCERTAIN"),
      ("XREPLY_REQUIRED", "UNCERTAIN"), ("10", "UNCERTAIN"), ("1\n", "REPLY_REQUIRED"),
    ] { XCTAssertEqual(ReplyClassifier.parse(raw), label, raw) }
  }
  func testStructuredClassificationPreservesRawOutputAndGenerationErrors() async throws {
    let result = try await ReplyClassifier.result("Message") { text in
      XCTAssertEqual(text, "Message")
      return " 1. \n"
    }
    XCTAssertEqual(result.label, "REPLY_REQUIRED")
    XCTAssertEqual(result.rawOutput, "1.")
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: String])
    XCTAssertEqual(json["raw_output"], "1.")
    do {
      _ = try await ReplyClassifier.result(" \n") { _ in
        XCTFail("Empty input must not load a model")
        return ""
      }
      XCTFail("Expected empty message error")
    } catch {}
    do {
      _ = try await ReplyClassifier.result("Message") { _ in throw PulseError("Model unavailable") }
      XCTFail("Expected generation error")
    } catch { XCTAssertEqual(error.localizedDescription, "Model unavailable") }
  }
  func testAvailableOnDeviceModelReturnsAnAllowedLabel() async throws {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *), SystemLanguageModel.default.isAvailable {
        let result = try await ReplyClassifier.classify("The build finished successfully.")
        XCTAssertTrue(["REPLY_REQUIRED", "NO_REPLY_REQUIRED", "UNCERTAIN"].contains(result))
        return
      }
    #endif
    do {
      _ = try await ReplyClassifier.generate("The build finished successfully.")
      XCTFail("Expected unavailable model")
    } catch { XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence")) }
  }
}

final class MLXClassifierTests: IsolatedTests {
  func testMLXRequestPreservesLegacyFewShotPromptAndValidatesResponses() throws {
    let executable = root.appendingPathComponent("sidepulsectl")
    let helper = root.appendingPathComponent("sidepulse-classifier")
    XCTAssertThrowsError(try ReplyClassifier.mlx("message", executable: executable))
    try Data("fixture".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let text = "Should I deploy? 'quoted'\n$HOME"
    let raw = try ReplyClassifier.mlx(text, model: "local/model", executable: executable) {
      binary, arguments in
      XCTAssertEqual(binary, helper.path)
      XCTAssertEqual(arguments.count, 1)
      let request = try XCTUnwrap(
        try JSONSerialization.jsonObject(with: Data(arguments[0].utf8)) as? JSONObject)
      XCTAssertEqual(request["model"] as? String, "local/model")
      let messages = try XCTUnwrap(request["messages"] as? [[String: String]])
      XCTAssertEqual(messages.count, 12)
      XCTAssertEqual(messages.first?["role"], "system")
      XCTAssertEqual(messages.last?["content"], "Message:\n<message>\n" + text + "\n</message>")
      XCTAssertEqual(
        messages.filter { $0["role"] == "assistant" }.compactMap { $0["content"] },
        ["1", "1", "0", "0", "2"])
      return Data("{\"output\":\"1\"}".utf8)
    }
    XCTAssertEqual(raw, "1")
    XCTAssertThrowsError(try ReplyClassifier.mlx("message", model: "", executable: executable))
    for response in ["[]", "{}", "bad JSON", "{\"error\":\"Model unavailable\"}"] {
      XCTAssertThrowsError(
        try ReplyClassifier.mlx(
          "message", executable: executable, run: { _, _ in Data(response.utf8) }))
    }
  }
}
