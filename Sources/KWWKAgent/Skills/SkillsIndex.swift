import Foundation

/// A publisher-owned index for an immutable skills root. No child paths are
/// touched on read: publishers must replace files and index as one snapshot.
/// Body is retained to preserve Skill's existing eager-body API for SDK users.
enum SkillsIndex {
    static let filename = "skills.index"
    static let maximumBytes = 32 * 1024 * 1024

    struct Document: Codable {
        var version: Int
        var skills: [Entry]
        var diagnostics: [Diagnostic]
    }
    struct Entry: Codable {
        var name: String
        var description: String
        var path: String
        var body: String
        var disableModelInvocation: Bool
    }
    struct Diagnostic: Codable {
        var code: String
        var message: String
        var path: String
    }
    enum Invalid: Error { case format, path, tooLarge }

    static func relative(_ path: String, root: URL) throws -> String {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = root.path + "/"
        guard absolute.hasPrefix(prefix) else { throw Invalid.path }
        let result = String(absolute.dropFirst(prefix.count))
        try validate(result)
        return result
    }

    static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw Invalid.path }
    }

    static func read(directory: String) -> (skills: [Skill]?, diagnostics: [SkillDiagnostic])? {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        let url = root.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else { throw Invalid.tooLarge }
            let doc = try JSONDecoder().decode(Document.self, from: data)
            guard doc.version == 1 else { throw Invalid.format }
            let skills = try doc.skills.map { entry in
                try validate(entry.path)
                guard !entry.name.isEmpty, !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw Invalid.format }
                return Skill(
                    name: entry.name,
                    description: entry.description,
                    path: root.appendingPathComponent(entry.path).path,
                    body: entry.body,
                    disableModelInvocation: entry.disableModelInvocation
                )
            }
            let diagnostics = try doc.diagnostics.map { entry in
                try validate(entry.path)
                guard let code = SkillDiagnostic.Code(rawValue: entry.code) else { throw Invalid.format }
                return SkillDiagnostic(
                    code: code,
                    message: entry.message,
                    path: root.appendingPathComponent(entry.path).path
                )
            }
            return (skills, diagnostics)
        } catch {
            return (nil, [.init(
                code: .invalidMetadata,
                message: "Invalid or unsupported skills.index; falling back to directory scanning",
                path: url.path
            )])
        }
    }
}

extension Skills {
    /// Generate from the actual tree, never from an older index. Call only
    /// while constructing a private snapshot, then publish the whole root.
    public static func writeIndex(directory: String) throws {
        let root = URL(fileURLWithPath: directory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw SkillsIndex.Invalid.path }
        let result = load(directories: [root.path], useIndex: false)
        let doc = try SkillsIndex.Document(
            version: 1,
            skills: result.skills.map {
                SkillsIndex.Entry(
                    name: $0.name,
                    description: $0.description,
                    path: try SkillsIndex.relative($0.path, root: root),
                    body: $0.body,
                    disableModelInvocation: $0.disableModelInvocation
                )
            },
            diagnostics: result.diagnostics.map {
                SkillsIndex.Diagnostic(
                    code: $0.code.rawValue,
                    message: $0.message,
                    path: try SkillsIndex.relative($0.path, root: root)
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        guard data.count <= SkillsIndex.maximumBytes else { throw SkillsIndex.Invalid.tooLarge }
        try data.write(to: root.appendingPathComponent(SkillsIndex.filename), options: .atomic)
    }
}
