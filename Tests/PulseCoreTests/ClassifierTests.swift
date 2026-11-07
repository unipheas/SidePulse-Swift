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
