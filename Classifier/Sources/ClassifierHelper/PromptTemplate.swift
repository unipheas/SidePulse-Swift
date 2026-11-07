import Foundation
import Jinja

/// Hugging Face's Python renderer trims block whitespace and the template's final
/// newline. Using the Swift tokenizer's default Jinja options changes prompt tokens.
enum PromptTemplate {
  static func render(config: Data, messages: [[String: String]]) throws -> String {
    let values = try JSONSerialization.jsonObject(with: config) as? [String: Any] ?? [:]
    let selected =
      values["chat_template"] as? String
      ?? (values["chat_template"] as? [[String: String]])?.first { $0["name"] == "default" }?[
        "template"]
    guard var template = selected else {
      throw NSError(
        domain: "SidePulseClassifier", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "The model has no default chat template."])
    }
    template = template.replacingOccurrences(of: "\r\n", with: "\n")
    if template.hasSuffix("\n") { template.removeLast() }
    var context: [String: Value] = [
      "messages": try Value(any: messages), "add_generation_prompt": .boolean(true),
    ]
    for key in [
      "bos_token", "eos_token", "unk_token", "sep_token", "pad_token", "cls_token", "mask_token",
      "additional_special_tokens",
    ] {
      guard let value = values[key], !(value is NSNull) else { continue }
      context[key] = try Value(any: (value as? [String: Any])?["content"] ?? value)
    }
    return try Template(template, with: .init(lstripBlocks: true, trimBlocks: true)).render(context)
  }
}
