import Foundation

/// Reading the arguments a stream gave a tool call.
///
/// The contract is one JSON object sent in pieces. Relays and decoders in
/// front of a model do not always keep to it, and each shape here is one a
/// stream has sent: an object followed by the rest of its keys as a second
/// object, the whole arguments again after a first object that held only
/// the first key, or the rest of the first object's keys after it closed
/// (`{"a":1}` then `,"b":2}`). All of them are merged in order, a later
/// value winning, so the call runs with every key the stream gave it.
enum StreamedToolArguments {
    /// The arguments as an object, or nil when the text is not one in any
    /// of the shapes above. Empty text is an empty object.
    static func object(_ text: String) -> [String: JSONValue]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        if let value = parseJSONObject(trimmed) {
            if case .object(let object) = value { return object }
            return nil
        }
        // Not one value: read the first complete object and merge the rest
        // over it.
        guard let end = endOfFirstObject(trimmed),
              case .object(let first)? = parseJSONObject(String(trimmed[..<end]))
        else { return nil }
        return merging(start: first, streamed: String(trimmed[end...]))
    }

    /// `start` with the keys `streamed` adds, or nil when `streamed` is
    /// neither more objects nor the rest of `start`'s object. Nothing
    /// streamed leaves `start` as it is.
    static func merging(start: [String: JSONValue], streamed: String) -> [String: JSONValue]? {
        let rest = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty { return start }
        if rest.hasPrefix("{"), let more = object(rest) {
            return start.merging(more) { _, new in new }
        }
        guard let data = try? JSONEncoder().encode(JSONValue.object(start)) else { return nil }
        let head = String(decoding: data, as: UTF8.self).dropLast() // drop "}"
        let separator = start.isEmpty || rest.hasPrefix(",") ? "" : ","
        if case .object(let joined)? = parseJSONObject(head + separator + rest) {
            return start.merging(joined) { _, new in new }
        }
        return nil
    }

    /// What a finished call's arguments decode to: the object, or an empty
    /// one and the text it could not read.
    static func decode(_ text: String) -> (arguments: JSONValue, unparsed: String?) {
        if let object = object(text) { return (.object(object), nil) }
        return (.object([:]), text)
    }

    /// The index just past the first top-level JSON object in `text`, which
    /// starts with `{`, or nil when it never closes.
    private static func endOfFirstObject(_ text: String) -> String.Index? {
        guard text.first == "{" else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return text.index(after: index) }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
