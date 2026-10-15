import Foundation
import Testing
@testable import KWWKAgent

@Suite("Skills index")
struct SkillsIndexTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let skill = root.appendingPathComponent("example")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\nname: example\ndescription: Example skill\ndisable-model-invocation: true\n---\nBody".write(
            to: skill.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return root
    }

    @Test func roundTripWithoutReadingChildren() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Skills.load(directories: [root.path])
        try Skills.writeIndex(directory: root.path)
        try FileManager.default.removeItem(at: root.appendingPathComponent("example"))
        let indexed = Skills.load(directories: [root.path])
        #expect(indexed.skills == expected.skills)
        #expect(indexed.diagnostics == expected.diagnostics)
        #expect(Skills.load(directories: [root.path], useIndex: false).skills.isEmpty)
    }

    @Test(arguments: [
        "../outside/SKILL.md", "/etc/passwd", "example/../../secret", "example\\SKILL.md", "example//SKILL.md"
    ])
    func unsafePathFallsBack(path: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Skills.load(directories: [root.path]).skills
        try Skills.writeIndex(directory: root.path)
        let file = root.appendingPathComponent("skills.index")
        var doc = try JSONDecoder().decode(SkillsIndex.Document.self, from: Data(contentsOf: file))
        doc.skills[0].path = path
        try JSONEncoder().encode(doc).write(to: file)
        let result = Skills.load(directories: [root.path])
        #expect(result.skills == expected)
        #expect(result.diagnostics.contains { $0.path == file.path })
    }

    @Test(arguments: ["not json", "{\"version\":999,\"skills\":[],\"diagnostics\":[]}"])
    func invalidIndexFallsBack(json: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Skills.load(directories: [root.path]).skills
        try json.write(to: root.appendingPathComponent("skills.index"), atomically: true, encoding: .utf8)
        let result = Skills.load(directories: [root.path])
        #expect(result.skills == expected)
        #expect(!result.diagnostics.isEmpty)
    }

    @Test func relocationRegenerationAndPrecedence() throws {
        let root = try fixture()
        let other = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: other) }
        try Skills.writeIndex(directory: root.path)
        let relocated = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("skills.index"),
            to: relocated.appendingPathComponent("skills.index")
        )
        #expect(Skills.load(directories: [relocated.path]).skills.first?.path == relocated.appendingPathComponent("example/SKILL.md").path)
        let result = Skills.load(directories: [root.path, other.path])
        #expect(result.skills.map(\.path) == [root.appendingPathComponent("example/SKILL.md").path])
        try FileManager.default.removeItem(at: root.appendingPathComponent("example"))
        try FileManager.default.removeItem(at: relocated)
        try Skills.writeIndex(directory: root.path)
        #expect(Skills.load(directories: [root.path]).skills.isEmpty)
    }
}
