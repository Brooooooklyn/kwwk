import Foundation

extension BackgroundTaskManager {
    private static let promptPatterns: [NSRegularExpression] = {
        let raws = [
            "\\(y/n\\)",
            "\\[y/n\\]",
            "\\(yes/no\\)",
            "password\\s*:",
            "passphrase\\s*:",
            "(Do you|Would you|Shall I|Are you sure|Ready to)\\b.*\\?\\s*$",
            "Press\\s+(any key|Enter|return)",
            "Continue\\?",
            "Overwrite\\?",
            "Proceed\\?",
        ]
        return raws.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static func looksLikePrompt(_ tail: String) -> Bool {
        let trimmed = tail.trimmingCharacters(in: .whitespaces)
        let lastLine = trimmed.split(separator: "\n").last.map(String.init) ?? ""
        let range = NSRange(lastLine.startIndex..., in: lastLine)
        return promptPatterns.contains { regex in
            regex.firstMatch(in: lastLine, options: [], range: range) != nil
        }
    }
}
