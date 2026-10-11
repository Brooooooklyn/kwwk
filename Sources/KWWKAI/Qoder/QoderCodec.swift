import Foundation

/// The body codec of Qoder's `Encode=1` requests: the client base64-encodes
/// the plaintext with a shuffled alphabet, then swaps the first and last
/// thirds of the result. Ported from magpie `internal/qoder/codec.go`, whose
/// alphabet CLIProxyAPI dumped from a live Qoder client and checked against
/// captured traffic.
///
/// Grouping is standard base64 (four chars = three bytes). `!` is the 64th
/// char and encodes the 6-bit value 63; `$` is the pad.
enum QoderCodec {
    static let alphabet = Array("_doRTgHZBKcGVjlvpC,@aFSx#DPuNJme&i*MzLOEn)sUrthbf%Y^w.(kIQyXqWA!".utf8)
    static let pad = UInt8(ascii: "$")

    /// Custom base64, without the swap.
    static func encode(_ data: Data) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((data.count + 2) / 3 * 4)
        var acc = 0
        var bits = 0
        for byte in data {
            acc = (acc << 8) | Int(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                out.append(alphabet[(acc >> bits) & 0x3F])
            }
            acc &= (1 << bits) - 1
        }
        if bits > 0 {
            out.append(alphabet[(acc << (6 - bits)) & 0x3F])
        }
        while out.count % 4 != 0 { out.append(pad) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Exchanges the first and last thirds of an encoded string; the middle
    /// stays put. Every char is ASCII, so thirds are counted in bytes.
    static func swapOuterThirds(_ encoded: String) -> String {
        let bytes = Array(encoded.utf8)
        let third = bytes.count / 3
        guard third > 0 else { return encoded }
        let swapped = bytes[(bytes.count - third)...] + bytes[third..<(bytes.count - third)] + bytes[..<third]
        return String(decoding: swapped, as: UTF8.self)
    }

    /// The wire body of an `agent_chat_generation` request.
    static func encodeRequestBody(_ plaintext: Data) -> String {
        swapOuterThirds(encode(plaintext))
    }
}
