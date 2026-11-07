import XCTest

@testable import ClassifierPrompt

final class PromptTests: XCTestCase {
  func testTemplateWhitespaceMatchesPythonAndPreservesTheAssistantNewline() throws {
    let template =
      "{% for message in messages %}\n{{ message.role }}:{{ message.content }}\n{% endfor %}\n{% if add_generation_prompt %}\n{{ 'assistant\\n' }}{% endif %}\n"
    let config = try JSONSerialization.data(withJSONObject: ["chat_template": template])
    XCTAssertEqual(
      try PromptTemplate.render(config: config, messages: [["role": "user", "content": "Hello"]]),
      "user:Hello\nassistant\n")
  }
  func testDefaultTemplateSelectionSpecialTokensAndInvalidConfiguration() throws {
    let config: [String: Any] = [
      "chat_template": [
        ["name": "unused", "template": "wrong"],
        ["name": "default", "template": "{{ bos_token }}{{ eos_token }}"],
      ],
      "bos_token": ["content": "<start>"], "eos_token": "<end>", "pad_token": NSNull(),
      "additional_special_tokens": ["a", "b"],
    ]
    XCTAssertEqual(
      try PromptTemplate.render(
        config: JSONSerialization.data(withJSONObject: config), messages: []), "<start><end>")
    for text in [
      "{}", "[]", "bad JSON", "{\"chat_template\":[{\"name\":\"other\",\"template\":\"no\"}]}",
    ] {
      XCTAssertThrowsError(try PromptTemplate.render(config: Data(text.utf8), messages: []))
    }
  }
}
