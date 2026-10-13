import Foundation
import Crypto

/// The signed-in Qoder account a COSY envelope is built for.
struct QoderAccount: Sendable, Equatable {
    /// The Qoder user id (`Cosy-User`).
    var uid: String
    /// Display name and email, either may be empty.
    var name: String
    var email: String
    /// The `jt-` job token (or, for a Qoder CN account that chats the CLI's
    /// way, the `dt-` device token).
    var token: String
    /// Generated once at sign-in and kept with the account.
    var machineId: String
}

/// The COSY envelope Qoder's client signs every `/algo` request with: the
/// account (token included) AES-encrypted under a per-request key, that key
/// RSA-encrypted to Qoder's public key, and an MD5 over the payload, the key,
/// the time, the wire body and the path. Ported from magpie
/// `internal/qoder/cosy.go`.
enum QoderCosy {
    /// The client version the envelope and the chat body both name.
    static let clientVersion = "1.1.49"

    /// Every header of a Qoder call to `url` whose body, already in its wire
    /// (encoded) form, is `body`. `timestamp` is Unix seconds.
    static func headers(
        url: String, account: QoderAccount, body: String, timestamp: Int64
    ) throws -> [String: String] {
        guard !account.machineId.isEmpty else {
            throw ProviderFailure(message: "Qoder: missing account machine id (run /login again)")
        }
        // The AES key is the first 16 hex chars of a UUID, and doubles as
        // the IV.
        let key = Array(compactUUID().utf8.prefix(16))
        let info = Data(try userBlob(account, key: key)).base64EncodedString()
        let wrappedKey = Data(QoderRSA.encrypt(key)).base64EncodedString()
        // `info` is base64 and holds `/`: it goes bare, as the client's JSON
        // has it, not as the `\/` JSONSerialization writes by default.
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "version": "v1",
                "requestId": compactUUID(),
                "info": info,
                "cosyVersion": clientVersion,
                "ideVersion": "",
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        ).base64EncodedString()
        let sig = signature(
            payload: payload, key: wrappedKey, timestamp: timestamp, body: body, path: signedPath(url)
        )
        return [
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Content-Type": "application/json",
            "Authorization": "Bearer COSY.\(payload).\(sig)",
            "Cosy-Business-Product": "app",
            "Cosy-Business-Type": "agent",
            "Cosy-ClientIp": account.machineId,
            "Cosy-ClientType": "10",
            "Cosy-Data-Policy": "disagree",
            "Cosy-Date": String(timestamp),
            "Cosy-Key": wrappedKey,
            "Cosy-MachineId": account.machineId,
            "Cosy-MachineToken": account.machineId,
            "Cosy-MachineType": "5",
            "Cosy-MachineOS": machineOS,
            "Cosy-Scene": "app",
            "Cosy-User": account.uid,
            "Cosy-Version": clientVersion,
            "Login-Version": "v2",
        ]
    }

    /// The account as the envelope carries it: JSON, AES-128-CBC under `key`
    /// with the key as its own IV.
    static func userBlob(_ account: QoderAccount, key: [UInt8]) throws -> [UInt8] {
        let blob = try JSONSerialization.data(
            withJSONObject: [
                "uid": account.uid,
                "aid": "",
                "name": account.name,
                "email": account.email,
                "security_oauth_token": account.token,
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return QoderAES.encryptCBC(Array(blob), key: key, iv: key)
    }

    /// MD5 over the five newline-separated fields, hex.
    static func signature(payload: String, key: String, timestamp: Int64, body: String, path: String) -> String {
        let signed = "\(payload)\n\(key)\n\(timestamp)\n\(body)\n\(path)"
        return Insecure.MD5.hash(data: Data(signed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What of the request's URL is signed: its path, without the `/algo`
    /// prefix or the query.
    static func signedPath(_ url: String) -> String {
        guard let path = URLComponents(string: url)?.path else {
            return url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return path.hasPrefix("/algo") ? String(path.dropFirst("/algo".count)) : path
    }

    /// `<arch>_<os>` in the names desktop clients use. kwwk also runs where
    /// Qoder's client does not (iOS); those say `darwin`.
    static let machineOS: String = {
        #if arch(arm64)
        let arch = "aarch64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "x86"
        #endif
        #if os(Linux)
        let os = "linux"
        #elseif os(Windows)
        let os = "win32"
        #else
        let os = "darwin"
        #endif
        return "\(arch)_\(os)"
    }()

    /// A UUID without dashes, the shape Qoder's request ids and tool-call
    /// ids use.
    static func compactUUID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}

// The envelope needs AES-128-CBC and RSA PKCS#1 v1.5 encryption to a 1024-bit
// key. swift-crypto's `Crypto` has neither (its RSA refuses keys this short
// and pads with OAEP only), so both are written out here; each is checked
// against OpenSSL's answer in QoderCosyTests.

/// AES-128 encryption (FIPS 197), CBC mode with PKCS#7 padding.
enum QoderAES {
    private static let sbox: [UInt8] = [
        0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
        0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0, 0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
        0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
        0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
        0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0, 0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
        0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
        0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
        0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5, 0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
        0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
        0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
        0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c, 0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
        0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
        0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
        0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e, 0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
        0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
        0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
    ]

    static func encryptCBC(_ plaintext: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8] {
        precondition(key.count == 16 && iv.count == 16, "AES-128 takes a 16-byte key and IV")
        let roundKeys = expand(key)
        let padding = 16 - plaintext.count % 16
        let padded = plaintext + [UInt8](repeating: UInt8(padding), count: padding)
        var out: [UInt8] = []
        out.reserveCapacity(padded.count)
        var previous = iv
        for start in stride(from: 0, to: padded.count, by: 16) {
            var block = [UInt8](padded[start..<(start + 16)])
            for i in 0..<16 { block[i] ^= previous[i] }
            previous = encryptBlock(block, roundKeys: roundKeys)
            out += previous
        }
        return out
    }

    /// The eleven round keys, 16 bytes each.
    static func expand(_ key: [UInt8]) -> [[UInt8]] {
        var words = stride(from: 0, to: 16, by: 4).map { Array(key[$0..<($0 + 4)]) }
        var rcon: UInt8 = 1
        for i in 4..<44 {
            var word = words[i - 1]
            if i % 4 == 0 {
                word = [sbox[Int(word[1])] ^ rcon, sbox[Int(word[2])], sbox[Int(word[3])], sbox[Int(word[0])]]
                rcon = xtime(rcon)
            }
            words.append((0..<4).map { words[i - 4][$0] ^ word[$0] })
        }
        return stride(from: 0, to: 44, by: 4).map { Array(words[$0..<($0 + 4)].joined()) }
    }

    static func encryptBlock(_ block: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
        var state = zip(block, roundKeys[0]).map { $0 ^ $1 }
        for round in 1...10 {
            // SubBytes and ShiftRows: byte (row r, column c) comes from
            // column c + r. The state is column-major.
            var shifted = [UInt8](repeating: 0, count: 16)
            for column in 0..<4 {
                for row in 0..<4 {
                    shifted[column * 4 + row] = sbox[Int(state[((column + row) % 4) * 4 + row])]
                }
            }
            if round < 10 {
                for column in 0..<4 {
                    let a = Array(shifted[(column * 4)..<(column * 4 + 4)])
                    let all = a[0] ^ a[1] ^ a[2] ^ a[3]
                    for row in 0..<4 {
                        shifted[column * 4 + row] = a[row] ^ all ^ xtime(a[row] ^ a[(row + 1) % 4])
                    }
                }
            }
            state = zip(shifted, roundKeys[round]).map { $0 ^ $1 }
        }
        return state
    }

    /// Multiplication by x in GF(2^8).
    private static func xtime(_ value: UInt8) -> UInt8 {
        (value << 1) ^ (value & 0x80 != 0 ? 0x1b : 0)
    }
}

/// RSA encryption to Qoder's embedded 1024-bit public key (from the client's
/// cosy source), which wraps the per-request AES key:
///
///     -----BEGIN PUBLIC KEY-----
///     MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDA8iMH5c02LilrsERw9t6Pv5Nc
///     4k6Pz1EaDicBMpdpxKduSZu5OANqUq8er4GM95omAGIOPOh+Nx0spthYA2BqGz+l
///     6HRkPJ7S236FZz73In/KVuLnwI8JJ2CbuJap8kvheCCZpmAWpb/cPx/3Vr/J6I17
///     XcW+ML9FoCI6AOvOzwIDAQAB
///     -----END PUBLIC KEY-----
enum QoderRSA {
    /// The key's modulus, big-endian; its exponent is 65537.
    static let modulus: [UInt8] = bytes(
        "c0f22307e5cd362e296bb04470f6de8fbf935ce24e8fcf511a0e2701329769c4"
            + "a76e499bb938036a52af1eaf818cf79a2600620e3ce87e371d2ca6d85803606a"
            + "1b3fa5e874643c9ed2db7e85673ef7227fca56e2e7c08f0927609bb896a9f24b"
            + "e1782099a66016a5bfdc3f1ff756bfc9e88d7b5dc5be30bf45a0223a00ebcecf"
    )

    /// PKCS#1 v1.5 (type 2) encryption of `message`.
    static func encrypt(_ message: [UInt8]) -> [UInt8] {
        let padding = (0..<(modulus.count - 3 - message.count)).map { _ in UInt8.random(in: 1...255) }
        return raw([0x00, 0x02] + padding + [0x00] + message)
    }

    /// `block ^ 65537 mod n`, for a block as long as the modulus.
    static func raw(_ block: [UInt8]) -> [UInt8] {
        let n = montgomery
        let base = n.multiply(Limbs(block), n.rSquared)
        var result = base
        for _ in 0..<16 { result = n.multiply(result, result) }
        return n.multiply(n.multiply(result, base), .one).bytes
    }

    private static let montgomery = Montgomery(Limbs(modulus))

    private static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count, by: 2).map {
            UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
        }
    }

    /// A 1024-bit unsigned integer, least significant limb first.
    private struct Limbs {
        static let count = 16
        var limbs: [UInt64]

        static let one = Limbs(limbs: [1] + [UInt64](repeating: 0, count: count - 1))

        init(limbs: [UInt64]) { self.limbs = limbs }

        init(_ bigEndian: [UInt8]) {
            precondition(bigEndian.count == 128, "a 1024-bit value is 128 bytes")
            limbs = stride(from: 120, through: 0, by: -8).map { offset in
                bigEndian[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
        }

        var bytes: [UInt8] {
            limbs.reversed().flatMap { limb in (0..<8).reversed().map { UInt8(truncatingIfNeeded: limb >> UInt64($0 * 8)) } }
        }

        /// Doubles in place; true when a bit fell off the top.
        mutating func shiftLeft() -> Bool {
            var carry: UInt64 = 0
            for i in limbs.indices {
                let next = limbs[i] >> 63
                limbs[i] = limbs[i] << 1 | carry
                carry = next
            }
            return carry == 1
        }

        /// Subtracts in place, wrapping: the caller subtracts `n` only from
        /// a value in [n, 2n), whose lost top bit the wrap restores.
        mutating func subtract(_ other: Limbs) {
            var borrow = false
            for i in limbs.indices {
                let (first, under) = limbs[i].subtractingReportingOverflow(other.limbs[i])
                let (second, underAgain) = first.subtractingReportingOverflow(borrow ? 1 : 0)
                limbs[i] = second
                borrow = under || underAgain
            }
        }

        static func >= (lhs: Limbs, rhs: Limbs) -> Bool {
            for i in lhs.limbs.indices.reversed() where lhs.limbs[i] != rhs.limbs[i] {
                return lhs.limbs[i] > rhs.limbs[i]
            }
            return true
        }
    }

    /// Montgomery multiplication modulo the key's modulus. Shift-and-add
    /// took a second for seventeen products in an unoptimised build, which
    /// every signed request pays; this takes them in microseconds.
    private struct Montgomery {
        let n: Limbs
        /// `-n⁻¹ mod 2⁶⁴`.
        let nPrime: UInt64
        /// `(2¹⁰²⁴)² mod n`, which carries a value into Montgomery form.
        let rSquared: Limbs

        init(_ n: Limbs) {
            self.n = n
            // Newton's iteration doubles the correct low bits of n⁻¹ each
            // round, from the three an odd n gives for free.
            var inverse = n.limbs[0]
            for _ in 0..<6 { inverse = inverse &* (2 &- n.limbs[0] &* inverse) }
            nPrime = 0 &- inverse
            var power = Limbs.one
            for _ in 0..<(2 * 64 * Limbs.count) {
                if power.shiftLeft() || power >= n { power.subtract(n) }
            }
            rSquared = power
        }

        /// `a · b · 2⁻¹⁰²⁴ mod n`, for operands below `n` (coarsely
        /// integrated operand scanning).
        func multiply(_ a: Limbs, _ b: Limbs) -> Limbs {
            let k = Limbs.count
            var t = [UInt64](repeating: 0, count: k + 2)
            for i in 0..<k {
                var carry: UInt64 = 0
                for j in 0..<k {
                    let product = a.limbs[j].multipliedFullWidth(by: b.limbs[i])
                    let (sum, over) = product.low.addingReportingOverflow(t[j])
                    let (total, overAgain) = sum.addingReportingOverflow(carry)
                    t[j] = total
                    carry = product.high &+ (over ? 1 : 0) &+ (overAgain ? 1 : 0)
                }
                let (top, over) = t[k].addingReportingOverflow(carry)
                t[k] = top
                t[k + 1] = over ? 1 : 0

                let m = t[0] &* nPrime
                let first = m.multipliedFullWidth(by: n.limbs[0])
                carry = first.high &+ (first.low.addingReportingOverflow(t[0]).overflow ? 1 : 0)
                for j in 1..<k {
                    let product = m.multipliedFullWidth(by: n.limbs[j])
                    let (sum, over) = product.low.addingReportingOverflow(t[j])
                    let (total, overAgain) = sum.addingReportingOverflow(carry)
                    t[j - 1] = total
                    carry = product.high &+ (over ? 1 : 0) &+ (overAgain ? 1 : 0)
                }
                let (last, overLast) = t[k].addingReportingOverflow(carry)
                t[k - 1] = last
                t[k] = t[k + 1] &+ (overLast ? 1 : 0)
            }
            var result = Limbs(limbs: Array(t[0..<k]))
            if t[k] != 0 || result >= n { result.subtract(n) }
            return result
        }
    }
}
