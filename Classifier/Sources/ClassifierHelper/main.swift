import ClassifierPrompt
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

struct Request: Decodable {
  let model: String
  let messages: [[String: String]]
}
do {
  guard CommandLine.arguments.count == 2 else {
    throw NSError(
      domain: "SidePulseClassifier", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Expected a classifier request."])
  }
  let request = try JSONDecoder().decode(Request.self, from: Data(CommandLine.arguments[1].utf8))
  guard !request.model.isEmpty, !request.messages.isEmpty else {
    throw NSError(
      domain: "SidePulseClassifier", code: 2,
      userInfo: [NSLocalizedDescriptionKey: "The model and messages must not be empty."])
  }
  let configuration: ModelConfiguration
  if request.model.hasPrefix("/") {
    configuration = ModelConfiguration(directory: URL(fileURLWithPath: request.model))
  } else {
    configuration = ModelConfiguration(id: request.model)
  }
  let container = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
  let output = try await container.perform { context in
    let directory = context.configuration.modelDirectory(hub: defaultHubApi)
    let data = try Data(contentsOf: directory.appendingPathComponent("tokenizer_config.json"))
    let rendered = try PromptTemplate.render(config: data, messages: request.messages)
    let input = LMInput(
      tokens: MLXArray(context.tokenizer.encode(text: rendered, addSpecialTokens: false)))
    let stream = try MLXLMCommon.generate(
      input: input,
      parameters: GenerateParameters(maxTokens: 2, temperature: 0), context: context)
    var text = ""
    for await generation in stream {
      if case .chunk(let chunk) = generation { text += chunk }
    }
    return text
  }
  print(String(decoding: try JSONEncoder().encode(["output": output]), as: UTF8.self))
} catch {
  print(
    String(decoding: try JSONEncoder().encode(["error": error.localizedDescription]), as: UTF8.self)
  )
}
