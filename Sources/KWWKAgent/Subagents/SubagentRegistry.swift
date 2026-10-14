import Foundation

internal struct SubagentRegistry: Sendable {
    let names: [String]
    private let definitions: [String: SubagentDefinition]
    private let validationMessage: String?

    init(_ subagents: [SubagentDefinition]) {
        var names: [String] = []
        var definitions: [String: SubagentDefinition] = [:]
        var validationMessage: String?
        for definition in subagents {
            let name = definition.name
            if let problem = validateSubagentName(name) {
                if validationMessage == nil { validationMessage = problem }
                continue
            }
            let key = name.lowercased()
            if definitions[key] != nil {
                if validationMessage == nil {
                    validationMessage = "agent: duplicate subagent name '\(name)' (names are case-insensitive)"
                }
                continue
            }
            names.append(name)
            definitions[key] = definition
        }
        self.names = names
        self.definitions = definitions
        self.validationMessage = validationMessage
    }

    func definition(named name: String) -> SubagentDefinition? {
        definitions[name.lowercased()]
    }

    func validate() throws {
        if let validationMessage {
            throw CodingToolError.invalidArgument(validationMessage)
        }
    }
}

private func validateSubagentName(_ name: String) -> String? {
    guard name == name.trimmingCharacters(in: .whitespacesAndNewlines),
          !name.isEmpty else {
        return "agent: subagent names must not be empty or contain surrounding whitespace"
    }
    guard name.utf8.count <= 64 else {
        return "agent: subagent name '\(name)' exceeds 64 bytes"
    }
    let bytes = Array(name.utf8)
    func isLowerAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }
    guard let first = bytes.first, isLowerAlphaNumeric(first),
          bytes.allSatisfy({ isLowerAlphaNumeric($0) || $0 == 45 || $0 == 95 }) else {
        return "agent: invalid subagent name '\(name)'; expected [a-z0-9][a-z0-9_-]{0,63}"
    }
    return nil
}

/// Validate programmatic definitions before wiring them into a long-lived
/// agent. Factories also fail closed at execution time so callers that cannot
/// throw during construction never route through an ambiguous registry.
public func validateSubagentDefinitions(_ definitions: [SubagentDefinition]) throws {
    try SubagentRegistry(definitions).validate()
}
