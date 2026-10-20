import XCTest
@testable import MynaCore

/// Vectors generated with PyNaCl (libsodium) crypto_box. `shared` is
/// crypto_scalarmult(recipient_private, sender_public); NaClBox.open takes the
/// shared secret directly. Locks in the XSalsa20-Poly1305 implementation that
/// decrypts Bee's pairing token.
final class NaClBoxTests: XCTestCase {
    private struct V {
        let shared, nonce, ct, msg: [UInt8]
        init(_ shared: String, _ nonce: String, _ ct: String, _ msg: String) {
            self.shared = Self.hex(shared); self.nonce = Self.hex(nonce)
            self.ct = Self.hex(ct); self.msg = Self.hex(msg)
        }
        static func hex(_ s: String) -> [UInt8] {
            var out: [UInt8] = []; var i = s.startIndex
            while i < s.endIndex {
                let j = s.index(i, offsetBy: 2)
                out.append(UInt8(s[i..<j], radix: 16)!); i = j
            }
            return out
        }
    }

    private let vectors: [V] = [
        V("d3b993857592dc2d99d020a5cf51c6d2bab02cd6485c2024de1acb63c7f1fb02","70df069d50236285d298fe369aadcc7777444cfe4c1c47d2","8bfc4a1ddc86c6cccce57b078370c9c5",""),
        V("9cc59fc391a7810003f69bedfb42b06d5d76df5b8fd00b6d50d5bbe3e966c133","bcd00377532a22c3d79499fcf9bde022de3917e79b2aa79d","325a46447fd26e60d83a2c4d7f248768b9a83b","5bd616"),
        V("6507db030823069f582bc9bba688575603db86cdf6a4db07ced087b0e0b38145","19b7d0f0cd7462b2624c39f4ce38e79292464807a5a24d6f","85c5d58e4798e23dfaecda290b4e8767f68690aae3ae4a58260f915019c9112b","e76fc150279088b7a4bb3c7bba1c9e1a"),
        V("ba787ace70eade79443b349e4fba2596e904e047fe138289b980de602dc54d2e","1a169f7f893ce78efd548b85a073a3f350a087de977944c9","418cd6b1ebe4dec65555d57ea26300e147eea7b02c446d94383f68cc40634be84668a238e5745fdb60ff5d0c6aabcf","afb493a9c4e0cced79a837f63123a0f5d53452f82d3eba9d36707dc69733da"),
        V("f35db2a2943a166c872c22f8f346f4f56d465cea4c9ce54f12469e1d7fe7f124","b96c13f3f6826bfc37af0ae50ac4029bf306b8ca3ad735f9","ed29080ba0088982cdea9469e32f65839f2498ebd2b0b51c9fb6381a3aa5a73385c393812e1e6e9723273562f3bc11405227847d3191111e4bee68178db9fe45f941f763e29f7366250a0520c7b72947","f70f3b11e96082723c234edd685f9ca1034654471a4d81a4dd3ba6317012c111a2dd97b1e5974b8de00b0d5aee45385412ce004b83d52eaf503ed28a6565580b"),
        V("7db2dc7b5d3f3bb80864308f3793e5c231dc9e3008523a7902f0446dfbddc205","49cd6e7f58217fa92369e19485f68cc2c41909b8dea4903c","09b4bdc5fb6ca08900fb5ea4102e7f0587709cac54a55e11534f4866dc446d1272296870866e2199f6eb971faee6c7c298c4b74d07267f0db2a5d4614a08ea2eba0b77eb1999752a3b65347a65b83fea627aa32cf7ce391c5347736f53ee91ae2b7e93216f6e20a85c12466af93ed94f9a3b48df","2ebb995102970fa9e5d8a91910140b17f4353e35305e37775f732a06ddbc9468561d2b54d7f9c0677fe2718b2374d55e3bfd398ce74c6ca13f34c106612a616d406778272842ec8e78612428bc53e51e963c0c61407579e261a000739ddd5b9ff280b103"),
    ]

    func testOpensAllVectors() throws {
        for (index, v) in vectors.enumerated() {
            let plain = try NaClBox.open(ciphertext: v.ct, nonce: v.nonce, sharedSecret: v.shared)
            XCTAssertEqual(plain, v.msg, "vector \(index)")
        }
    }

    func testRejectsTamperedCiphertext() {
        for v in vectors {
            var bad = v.ct
            bad[bad.count - 1] ^= 1
            XCTAssertThrowsError(try NaClBox.open(ciphertext: bad, nonce: v.nonce, sharedSecret: v.shared))
        }
    }

    func testRejectsBadSizes() {
        let v = vectors[2]
        XCTAssertThrowsError(try NaClBox.open(ciphertext: v.ct, nonce: Array(v.nonce.dropLast()), sharedSecret: v.shared))
        XCTAssertThrowsError(try NaClBox.open(ciphertext: v.ct, nonce: v.nonce, sharedSecret: Array(v.shared.dropLast())))
        XCTAssertThrowsError(try NaClBox.open(ciphertext: [1, 2, 3], nonce: v.nonce, sharedSecret: v.shared))
    }
}
