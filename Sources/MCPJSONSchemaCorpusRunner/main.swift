import Foundation
import MCP

struct CorpusFailure: CustomStringConvertible {
  let file: String
  let group: String
  let test: String
  let expected: Bool
  let actual: Bool
  let error: String?

  var description: String {
    let detail = error.map { " error=\($0)" } ?? ""
    return "FAIL \(file) / \(group) / \(test): expected=\(expected) actual=\(actual)\(detail)"
  }
}

func object(_ value: MCPJSONValue, context: String) throws -> [String: MCPJSONValue] {
  guard case .object(let value) = value else {
    throw NSError(
      domain: "MCPJSONSchemaCorpusRunner",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "expected object at \(context)"]
    )
  }
  return value
}

func string(_ value: MCPJSONValue?, context: String) throws -> String {
  guard case .string(let value) = value else {
    throw NSError(
      domain: "MCPJSONSchemaCorpusRunner",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "expected string at \(context)"]
    )
  }
  return value
}

func bool(_ value: MCPJSONValue?, context: String) throws -> Bool {
  guard case .bool(let value) = value else {
    throw NSError(
      domain: "MCPJSONSchemaCorpusRunner",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "expected boolean at \(context)"]
    )
  }
  return value
}

func isUnsupportedProfile(_ error: Error) -> Bool {
  guard case .invalidSchema(let issues) = error as? MCPJSONSchemaError, !issues.isEmpty else {
    return false
  }
  return issues.allSatisfy { issue in
    issue.message.contains("external reference")
      || issue.message.contains("unsupported JSON Schema dialect")
      || issue.message.contains("requires a custom schema validator")
  }
}

func fail(_ message: String, exitCode: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(exitCode)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let rootPath = arguments.first else {
  fail(
    "usage: mcp-json-schema-corpus <JSON-Schema-Test-Suite root> [excluded-file ...]", exitCode: 2)
}

let root = URL(fileURLWithPath: rootPath, isDirectory: true)
let suiteDirectory = root.appendingPathComponent("tests/draft2020-12", isDirectory: true)
let excludedFiles = Set(arguments.dropFirst())
let fileManager = FileManager.default
guard
  let urls = try? fileManager.contentsOfDirectory(
    at: suiteDirectory,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
  )
else {
  fail("corpus directory does not exist: \(suiteDirectory.path)", exitCode: 2)
}

let files =
  urls
  .filter { $0.pathExtension == "json" }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !files.isEmpty else { fail("corpus contains no draft2020-12 JSON files", exitCode: 2) }

let validator = MCPJSONSchemaValidator()
var failures: [CorpusFailure] = []
var skippedFiles = 0
var skippedGroups = 0
var groupCount = 0
var validatedGroupCount = 0
var testCount = 0

for file in files {
  let fileName = file.lastPathComponent
  if excludedFiles.contains(fileName) {
    skippedFiles += 1
    print("SKIP \(fileName)")
    continue
  }

  let document: MCPJSONValue
  do {
    document = try MCPJSONValue.parse(Data(contentsOf: file))
  } catch {
    fail("cannot parse \(fileName): \(error)")
  }

  let groups: [MCPJSONValue]
  do {
    guard case .array(let values) = document else {
      throw NSError(
        domain: "MCPJSONSchemaCorpusRunner",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "top-level value is not an array"]
      )
    }
    groups = values
  } catch {
    fail("invalid corpus file \(fileName): \(error)")
  }

  for (groupIndex, groupValue) in groups.enumerated() {
    let group: [String: MCPJSONValue]
    let groupDescription: String
    let schema: MCPJSONValue
    let tests: [MCPJSONValue]
    do {
      group = try object(groupValue, context: "\(fileName)[\(groupIndex)]")
      groupDescription = try string(
        group["description"], context: "\(fileName)[\(groupIndex)].description")
      schema = group["schema"] ?? .null
      guard case .array(let values) = group["tests"] else {
        throw NSError(
          domain: "MCPJSONSchemaCorpusRunner",
          code: 1,
          userInfo: [NSLocalizedDescriptionKey: "tests must be an array"]
        )
      }
      tests = values
    } catch {
      fail("invalid corpus group in \(fileName)[\(groupIndex)]: \(error)")
    }

    groupCount += 1
    let plan: any MCPJSONSchemaValidationPlan
    do {
      plan = try validator.compile(schema)
    } catch {
      if isUnsupportedProfile(error) {
        skippedGroups += 1
        print("SKIP \(fileName) / \(groupDescription): \(error)")
        continue
      }
      let compilationError = String(describing: error)
      for testValue in tests {
        let test: [String: MCPJSONValue]
        do { test = try object(testValue, context: "\(fileName).tests") } catch {
          fail("invalid corpus test in \(fileName): \(error)")
        }
        let testDescription: String
        do {
          testDescription = try string(test["description"], context: "\(fileName).test.description")
        } catch { fail("invalid corpus test in \(fileName): \(error)") }
        let expected: Bool
        do { expected = try bool(test["valid"], context: "\(fileName).test.valid") } catch {
          fail("invalid corpus test in \(fileName): \(error)")
        }
        testCount += 1
        failures.append(
          CorpusFailure(
            file: fileName,
            group: groupDescription,
            test: testDescription,
            expected: expected,
            actual: false,
            error: "schema compilation failed: \(compilationError)"
          ))
      }
      continue
    }

    validatedGroupCount += 1
    for testValue in tests {
      let test: [String: MCPJSONValue]
      do { test = try object(testValue, context: "\(fileName).tests") } catch {
        fail("invalid corpus test in \(fileName): \(error)")
      }
      let testDescription: String
      let expected: Bool
      do {
        testDescription = try string(test["description"], context: "\(fileName).test.description")
        expected = try bool(test["valid"], context: "\(fileName).test.valid")
      } catch {
        fail("invalid corpus test in \(fileName): \(error)")
      }
      testCount += 1

      let instance = test["data"] ?? .null
      var actual = true
      var validationError: String?
      do {
        try plan.validate(instance)
      } catch {
        actual = false
        validationError = String(describing: error)
      }

      if actual != expected {
        failures.append(
          CorpusFailure(
            file: fileName,
            group: groupDescription,
            test: testDescription,
            expected: expected,
            actual: actual,
            error: validationError
          ))
      }
    }
  }
}

print(
  "corpus files=\(files.count - skippedFiles) groups=\(validatedGroupCount)/\(groupCount) "
    + "tests=\(testCount) skippedFiles=\(skippedFiles) skippedGroups=\(skippedGroups)"
)
if !failures.isEmpty {
  for failure in failures.prefix(50) { print(failure.description) }
  if failures.count > 50 { print("... and \(failures.count - 50) more failures") }
  fail("FAIL JSON Schema corpus: \(failures.count) failures")
}
print("PASS JSON Schema 2020-12 corpus")
