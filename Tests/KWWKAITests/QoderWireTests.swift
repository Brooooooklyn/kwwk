import Foundation
import Testing
@testable import KWWKAI

// Ported from magpie's `internal/qoder/codec_test.go`.

/// Reverses `QoderCodec.encode`: each four-char group back to its bytes, `$`
/// holding a slot but carrying no data.
func qoderDecode(_ encoded: String) -> Data {
    var out = Data()
    let chars = Array(encoded.utf8)
    for start in stride(from: 0, to: chars.count - 3, by: 4) {
        let values = chars[start..<(start + 4)].compactMap { QoderCodec.alphabet.firstIndex(of: $0) }
        let bits = values.reduce(0) { $0 << 6 | $1 }
        for byte in 0..<(6 * values.count / 8) {
            out.append(UInt8(bits >> (6 * values.count - 8 * (byte + 1)) & 0xFF))
        }
    }
    return out
}

/// What a request's wire body says, once the swap and the codec are undone.
func qoderDecodeRequestBody(_ wire: String) -> Data {
    qoderDecode(QoderCodec.swapOuterThirds(wire))
}

private func bytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.utf8)
    return stride(from: 0, to: digits.count, by: 2).map {
        UInt8(String(decoding: digits[$0..<($0 + 2)], as: UTF8.self), radix: 16)!
    }
}

@Suite("Qoder body codec")
struct QoderCodecTests {
    // RFC 4648 base64 with the client's alphabet substituted, then its
    // outer-third swap. The JSON vector is CLIProxyAPI's worker fixture.
    @Test("Known answers", arguments: [
        ("", "", ""),
        ("66", "D&$$", "$&$D"),
        ("666f", "DOq$", "$OqD"),
        ("666f6f", "DOWb", "bOWD"),
        ("666f6f626172", "DOWb#OgY", "gYWb#ODO"),
        ("00ff3f7f", "_vq!ef$$", "$$q!ef_v"),
        ("e4b8ade69687", "QG*tQ)PZ", "PZ*tQ)QG"),
        ("7b226d65737361676573223a5b5d7d", "mYKtDxj^#SJLNYByS..W", "ByS..Wj^#SJLNYmYKtDx"),
    ])
    func knownAnswers(hex: String, encoded: String, wire: String) {
        let plain = Data(bytes(hex))
        #expect(QoderCodec.encode(plain) == encoded)
        #expect(qoderDecode(encoded) == plain)
        #expect(QoderCodec.encodeRequestBody(plain) == wire)
        #expect(qoderDecodeRequestBody(wire) == plain)
    }

    @Test("A body of any length survives the wire: the partial last group, the padding and the swap")
    func roundTrip() {
        for length in 0..<200 {
            let plain = Data((0..<length).map { _ in UInt8.random(in: 0...255) })
            let wire = QoderCodec.encodeRequestBody(plain)
            #expect(qoderDecodeRequestBody(wire) == plain, "length \(length)")
            #expect(wire.utf8.count % 4 == 0)
        }
    }
}

// Ported from magpie's `internal/qoder/codec_test.go` (the COSY cases).
@Suite("Qoder COSY envelope")
struct QoderCosyTests {
    private let chatURL = "https://api3.qoder.sh" + QoderChatProvider.chatPath

    @Test("The signature is the MD5 of the five newline-separated fields")
    func signatureKnownAnswer() {
        let path = "/api/v2/service/pro/sse/agent_chat_generation"
        #expect(QoderCosy.signature(
            payload: "cGF5bG9hZA==", key: "c2VjcmV0", timestamp: 1_700_000_000,
            body: "ByS..Wj^#SJLNYmYKtDx", path: path
        ) == "da9dbed272847ea4664dd7ae8bf82575")
        // The signed path drops the /algo prefix and the query.
        #expect(QoderCosy.signedPath(chatURL) == path)
        #expect(QoderCosy.signedPath("https://gateway.qoder.com.cn" + QoderModels.listPath) == "/api/v2/model/list")
    }

    @Test("Authorization is Bearer COSY.<payload>.<md5>, signed over the body, and never shows the token")
    func headersStructure() throws {
        let account = QoderAccount(uid: "uid-1", name: "N", email: "e@x", token: "jt-abc", machineId: "machine-test")
        let body = #"{"messages":[]}"#
        let headers = try QoderCosy.headers(url: chatURL, account: account, body: body, timestamp: 1_700_000_000)

        let authorization = try #require(headers["Authorization"])
        #expect(authorization.hasPrefix("Bearer COSY."))
        let parts = authorization.dropFirst("Bearer COSY.".count).split(separator: ".").map(String.init)
        #expect(parts.count == 2)
        let decoded = try #require(Data(base64Encoded: parts[0]))
        let payload = try #require(JSONSerialization.jsonObject(with: decoded) as? [String: String])
        #expect(payload["version"] == "v1")
        #expect(payload["cosyVersion"] == "1.1.49")
        #expect(payload["ideVersion"] == "")
        #expect(payload["requestId"]?.count == 32)
        #expect(Set(payload.keys) == ["version", "requestId", "info", "cosyVersion", "ideVersion"])
        #expect(!String(decoding: decoded, as: UTF8.self).contains("jt-abc"))
        // Byte for byte what Go's json.Marshal of the map writes: keys
        // sorted, and the base64 `info` with its slashes bare.
        #expect(String(decoding: decoded, as: UTF8.self) == "{\"cosyVersion\":\"1.1.49\",\"ideVersion\":\"\","
            + "\"info\":\"\(payload["info"] ?? "")\",\"requestId\":\"\(payload["requestId"] ?? "")\",\"version\":\"v1\"}")

        // The account blob is AES-encrypted; its key rides RSA-encrypted.
        #expect(Data(base64Encoded: try #require(payload["info"]))?.count == 96)
        let key = try #require(headers["Cosy-Key"])
        #expect(Data(base64Encoded: key)?.count == 128)
        #expect(parts[1] == QoderCosy.signature(
            payload: parts[0], key: key, timestamp: 1_700_000_000, body: body,
            path: "/api/v2/service/pro/sse/agent_chat_generation"
        ))

        var rest = headers
        for name in ["Authorization", "Cosy-Key"] { rest[name] = nil }
        #expect(rest == [
            "Accept": "application/json",
            "Accept-Encoding": "identity",
            "Content-Type": "application/json",
            "Cosy-Business-Product": "app",
            "Cosy-Business-Type": "agent",
            "Cosy-ClientIp": "machine-test",
            "Cosy-ClientType": "10",
            "Cosy-Data-Policy": "disagree",
            "Cosy-Date": "1700000000",
            "Cosy-MachineId": "machine-test",
            "Cosy-MachineToken": "machine-test",
            "Cosy-MachineType": "5",
            "Cosy-MachineOS": QoderCosy.machineOS,
            "Cosy-Scene": "app",
            "Cosy-User": "uid-1",
            "Cosy-Version": "1.1.49",
            "Login-Version": "v2",
        ])
    }

    @Test("The payload never escapes the slashes of its base64 blob")
    func payloadSlashes() throws {
        let account = QoderAccount(uid: "uid-1", name: "N", email: "e@x", token: "jt-abc", machineId: "machine-test")
        // The blob's bytes are random per request (its key is); enough
        // envelopes hold a `/` that one escaped would show.
        var sawSlash = false
        for _ in 0..<8 {
            let headers = try QoderCosy.headers(url: chatURL, account: account, body: "", timestamp: 1)
            let payload = try #require(headers["Authorization"]).dropFirst("Bearer COSY.".count).split(separator: ".")[0]
            let text = String(decoding: try #require(Data(base64Encoded: String(payload))), as: UTF8.self)
            #expect(!text.contains("\\"))
            sawSlash = sawSlash || text.contains("/")
        }
        #expect(sawSlash)
    }

    @Test("Every request of an account names the machine id its sign-in made, and this platform")
    func machineIdentity() throws {
        let account = QoderAccount(uid: "uid", name: "", email: "", token: "jt", machineId: "fixed-machine")
        for _ in 0..<2 {
            let headers = try QoderCosy.headers(url: chatURL, account: account, body: "", timestamp: 1)
            for name in ["Cosy-MachineId", "Cosy-MachineToken", "Cosy-ClientIp"] {
                #expect(headers[name] == "fixed-machine")
            }
        }
        #expect(["aarch64_darwin", "x86_64_darwin", "aarch64_linux", "x86_64_linux"].contains(QoderCosy.machineOS))
        #expect(throws: ProviderFailure.self) {
            _ = try QoderCosy.headers(
                url: chatURL, account: QoderAccount(uid: "uid", name: "", email: "", token: "jt", machineId: ""),
                body: "", timestamp: 1
            )
        }
    }

    // The three answers below are OpenSSL's (`openssl enc -aes-128-ecb|cbc`,
    // and Python's `pow(m, 65537, n)` over the embedded modulus).

    @Test("AES-128 encrypts the FIPS 197 example block")
    func aesBlock() {
        let roundKeys = QoderAES.expand(bytes("000102030405060708090a0b0c0d0e0f"))
        #expect(QoderAES.encryptBlock(bytes("00112233445566778899aabbccddeeff"), roundKeys: roundKeys)
            == bytes("69c4e0d86a7b0430d8cdb78070b4c55a"))
    }

    @Test("The account blob is its sorted JSON under AES-128-CBC with PKCS#7 padding, the key as its own IV")
    func userBlob() throws {
        let account = QoderAccount(uid: "uid-1", name: "N", email: "e@x", token: "jt-abc", machineId: "m")
        let key = Array("0123456789abcdef".utf8)
        let blob = try QoderCosy.userBlob(account, key: key)
        #expect(Data(blob).base64EncodedString()
            == "wZsT3ir5jRksz+JtQn7lUGIbQJJvzF6+yAJO71qqJWSkzfE2ChzPZC6JU3Lt2ylOTV40+0pN9tHDn6o4jJIkEiNKEocspXlTkdtND3ZmWLJmdogm4fWabkottjofnMgU")
        // A plaintext of a whole number of blocks still gets a block of padding.
        #expect(QoderAES.encryptCBC([UInt8](repeating: 7, count: 16), key: key, iv: key).count == 32)
    }

    @Test("RSA raises a padded block to 65537 modulo Qoder's key")
    func rsa() {
        var block: [UInt8] = [0x00, 0x02]
        block += (0..<109).map { UInt8($0 % 255 + 1) }
        block.append(0x00)
        block += Array("0123456789abcdef".utf8)
        #expect(QoderRSA.raw(block) == bytes(
            "0a3df0703dc7572dd84ad3fd6ac2be99a534c5a789fb48be00916fcba8be437f55827b897b41a7a8953431aca2f97a45"
                + "58263333b45308121f075f1cf6b2830fe3e42659f9547a1ffe4eca279ca6040b0237e01f0c5014903147ecc7333c37ea"
                + "11fb67839ddbeca6d231870d8b59a485334d110abc7b962d3b01cddaf3ef8901"
        ))
        // PKCS#1 v1.5 padding is random, so two wraps of one key differ.
        let key = Array("0123456789abcdef".utf8)
        let first = QoderRSA.encrypt(key)
        #expect(first.count == 128)
        #expect(first != QoderRSA.encrypt(key))
    }
}
