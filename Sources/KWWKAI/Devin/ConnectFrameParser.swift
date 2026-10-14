import Foundation

// MARK: - Connect frame parser

/// Incremental parser for Connect streaming frames: 1 flag byte, 4-byte
/// big-endian length, payload.
struct ConnectFrameParser {
    struct Frame {
        let flags: UInt8
        let payload: Data
    }

    enum ParseError: Error, LocalizedError {
        case frameTooLarge(Int, limit: Int)
        var errorDescription: String? {
            switch self {
            case .frameTooLarge(let len, let limit): return "Devin Connect frame length \(len) exceeds \(limit)-byte cap"
            }
        }
    }

    let maxPayload: Int
    private var buffer = Data()

    init(maxPayload: Int) {
        self.maxPayload = maxPayload
    }

    mutating func append(_ chunk: Data) throws -> [Frame] {
        buffer.append(chunk)
        var frames: [Frame] = []
        while buffer.count >= 5 {
            let start = buffer.startIndex
            let flags = buffer[start]
            let length = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
                | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            if length > maxPayload { throw ParseError.frameTooLarge(length, limit: maxPayload) }
            guard buffer.count >= 5 + length else { break }
            let payload = Data(buffer[(start + 5)..<(start + 5 + length)])
            buffer = Data(buffer[(start + 5 + length)...])
            frames.append(Frame(flags: flags, payload: payload))
        }
        return frames
    }
}
