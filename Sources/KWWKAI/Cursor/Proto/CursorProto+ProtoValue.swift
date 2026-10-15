import Foundation

extension CursorProto {
    // MARK: - google.protobuf.Value

    /// Encode a `JSONValue` as a `google.protobuf.Value` message
    /// (`null_value=1(enum), number_value=2(double), string_value=3,
    /// bool_value=4, struct_value=5, list_value=6`). Used for
    /// `McpToolDefinition.input_schema`.
    static func encodeProtoValue(_ value: JSONValue) -> Data {
        var w = ProtoWriter()
        switch value {
        case .null:
            w.varintField(1, 0)
        case .bool(let b):
            w.boolField(4, b)
        case .int(let i):
            w.doubleField(2, Double(i))
        case .double(let d):
            w.doubleField(2, d)
        case .string(let s):
            w.stringField(3, s)
        case .object(let obj):
            // Struct { fields=1: map<string, Value> } — deterministic key order
            // so identical schemas produce identical bytes.
            w.messageField(5) { s in
                for key in obj.keys.sorted() {
                    s.messageField(1) { entry in
                        entry.stringField(1, key)
                        entry.bytesField(2, encodeProtoValue(obj[key]!))
                    }
                }
            }
        case .array(let items):
            // ListValue { values=1: repeated Value }
            w.messageField(6) { l in
                for item in items { l.bytesField(1, encodeProtoValue(item)) }
            }
        }
        return w.data
    }

    /// Strictly decode a `google.protobuf.Value` message. Returns nil unless
    /// the buffer is exactly one well-formed Value field with the right wire
    /// type — strictness is what lets callers distinguish a protobuf Value from
    /// raw JSON text sharing the same bytes.
    static func decodeProtoValue(_ data: Data) -> JSONValue? {
        // An empty Value message is proto3's encoding of explicit null.
        if data.isEmpty { return .null }
        var reader = ProtoReader(data)
        guard let field = reader.next(), reader.isAtEnd else { return nil }
        switch (field.number, field.value) {
        case (1, .varint):
            return .null
        case (2, .fixed64(let bits)):
            let d = Double(bitPattern: bits)
            if d == d.rounded(), abs(d) < 1e15 { return .int(Int(d)) }
            return .double(d)
        case (3, .bytes(let bytes)):
            guard let s = String(data: bytes, encoding: .utf8) else { return nil }
            return .string(s)
        case (4, .varint(let v)):
            return .bool(v != 0)
        case (5, .bytes(let structBytes)):
            // Struct { fields=1: map entries { key=1, value=2 } }
            var obj: [String: JSONValue] = [:]
            var s = ProtoReader(structBytes)
            while let f = s.next() {
                guard f.number == 1, let entry = f.value.asData else { return nil }
                var e = ProtoReader(entry)
                var key: String?
                var value: JSONValue = .null
                while let ef = e.next() {
                    if ef.number == 1 { key = ef.value.asString }
                    if ef.number == 2, let bytes = ef.value.asData {
                        guard let decoded = decodeProtoValue(bytes) else { return nil }
                        value = decoded
                    }
                }
                guard let key else { return nil }
                obj[key] = value
            }
            return .object(obj)
        case (6, .bytes(let listBytes)):
            // ListValue { values=1: repeated Value }
            var items: [JSONValue] = []
            var l = ProtoReader(listBytes)
            while let f = l.next() {
                guard f.number == 1, let bytes = f.value.asData,
                      let decoded = decodeProtoValue(bytes) else { return nil }
                items.append(decoded)
            }
            return .array(items)
        default:
            return nil
        }
    }
}
