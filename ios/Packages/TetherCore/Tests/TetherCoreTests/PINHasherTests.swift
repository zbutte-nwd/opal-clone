import XCTest
@testable import TetherCore

final class PINHasherTests: XCTestCase {
    private func sha(_ s: String) -> String { T.hex(SHA256.hash(Array(s.utf8))) }

    func testSHA256KnownAnswers() {
        XCTAssertEqual(sha(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(sha("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(sha("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(T.hex(SHA256.hash([UInt8](repeating: 0x61, count: 1_000_000))),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testHMACRFC4231() {
        let h1 = HMACSHA256(key: [UInt8](repeating: 0x0b, count: 20))
        XCTAssertEqual(T.hex(h1.mac(bytes: Array("Hi There".utf8))), "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        let h2 = HMACSHA256(key: Array("Jefe".utf8))
        XCTAssertEqual(T.hex(h2.mac(bytes: Array("what do ya want for nothing?".utf8))), "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        // Key longer than the block size is hashed first (RFC 4231 test case 6).
        let h6 = HMACSHA256(key: [UInt8](repeating: 0xaa, count: 131))
        XCTAssertEqual(T.hex(h6.mac(bytes: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }

    func testPBKDF2RFC7914Vectors() {
        let v1 = PINHasher.pbkdf2Pure(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, keyLength: 64)
        XCTAssertEqual(T.hex(v1), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
        let v2 = PINHasher.pbkdf2Pure(password: Array("Password".utf8), salt: Array("NaCl".utf8), iterations: 80000, keyLength: 64)
        XCTAssertEqual(T.hex(v2), "4ddcd8f60b98be21830cee5ef22701f9641a4418d04c0414aeff08876b34ab56a1d425a1225833549adb841b51c9b3176a272bdebba1d078478f62b397f33c8d")
    }

    func testPBKDF2ShortVectors() {
        func k(_ c: Int) -> String { T.hex(PINHasher.pbkdf2Pure(password: Array("password".utf8), salt: Array("salt".utf8), iterations: c, keyLength: 32)) }
        XCTAssertEqual(k(1), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        XCTAssertEqual(k(2), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        XCTAssertEqual(k(4096), "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
    }

    func testPublicDispatchMatchesPure() {
        let salt = Data((0..<16).map { UInt8($0) })
        let a = PINHasher.hash(pin: "123456", salt: salt, iterations: 1000)
        let b = PINHasher.pbkdf2Pure(password: Array("123456".utf8), salt: Array(salt), iterations: 1000, keyLength: 32)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 32)
    }

    func testRecordVerify() {
        let rec = PINHasher.makeRecord(pin: "246810", iterations: 50)
        XCTAssertEqual(rec.salt.count, 16)
        XCTAssertEqual(rec.iterations, 50)
        XCTAssertEqual(rec.hash.count, 32)
        XCTAssertTrue(PINHasher.verify(pin: "246810", record: rec))
        XCTAssertFalse(PINHasher.verify(pin: "246811", record: rec))
        XCTAssertFalse(PINHasher.verify(pin: "", record: rec))
        // Different salts => different hashes for the same PIN.
        XCTAssertNotEqual(PINHasher.makeRecord(pin: "246810", iterations: 50).hash, rec.hash)
    }

    func testRecordCodableRoundTrip() throws {
        let rec = PINHasher.makeRecord(pin: "13572468", iterations: 10)
        let back = try JSONDecoder().decode(PINRecord.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(back, rec)
        XCTAssertTrue(PINHasher.verify(pin: "13572468", record: back))
    }

    func testVerifyRejectsTamperedRecord() {
        var rec = PINHasher.makeRecord(pin: "123456", iterations: 10)
        rec.hash = Data(rec.hash.dropLast())
        XCTAssertFalse(PINHasher.verify(pin: "123456", record: rec))
        rec.iterations = 0
        XCTAssertFalse(PINHasher.verify(pin: "123456", record: rec))
    }

    func testIsValidPIN() {
        for ok in ["123456", "1234567", "12345678", "000000"] { XCTAssertTrue(PINHasher.isValidPIN(ok), ok) }
        for bad in ["", "12345", "123456789", "12345a", "12 456", "١٢٣٤٥٦", "1234.6"] { XCTAssertFalse(PINHasher.isValidPIN(bad), bad) }
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PINHasher.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(PINHasher.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(PINHasher.constantTimeEqual([1, 2, 3], [1, 2]))
    }
}
