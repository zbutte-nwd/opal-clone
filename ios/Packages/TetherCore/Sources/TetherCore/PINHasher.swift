// PINHasher.swift — partner PIN hashing: PBKDF2-HMAC-SHA256.
//
// Apple platforms use CommonCrypto's `CCKeyDerivationPBKDF`; everywhere else (Linux CI) a
// pure-Swift SHA-256 / HMAC / PBKDF2 is used. The pure implementation is always compiled so
// tests can cross-check both against RFC 7914 §11 vectors. The hash is stored in the
// Keychain (TetherKit), never in state.json.

import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Salt + iteration count + derived key. Codable so it can be stored as JSON in the Keychain.
public struct PINRecord: Codable, Sendable, Hashable {
    public var salt: Data
    public var iterations: Int
    public var hash: Data
    public init(salt: Data, iterations: Int, hash: Data) {
        self.salt = salt; self.iterations = iterations; self.hash = hash
    }
}

public enum PINHasher {
    public static let defaultIterations = 200_000
    public static let saltLength = 16
    public static let hashLength = 32

    /// 6–8 ASCII digits.
    public static func isValidPIN(_ pin: String) -> Bool {
        let n = pin.utf8.count
        return (6...8).contains(n) && pin.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// PBKDF2-HMAC-SHA256(pin, salt, iterations) → 32 bytes.
    public static func hash(pin: String, salt: Data, iterations: Int) -> Data {
        pbkdf2(password: Array(pin.utf8), salt: Array(salt), iterations: iterations, keyLength: hashLength)
    }

    /// New record with a random 16-byte salt.
    public static func makeRecord(pin: String, iterations: Int = defaultIterations) -> PINRecord {
        var rng = SystemRandomNumberGenerator()
        let salt = Data((0..<saltLength).map { _ in UInt8.random(in: 0...255, using: &rng) })
        return PINRecord(salt: salt, iterations: iterations, hash: hash(pin: pin, salt: salt, iterations: iterations))
    }

    /// Constant-time comparison of the derived key.
    public static func verify(pin: String, record: PINRecord) -> Bool {
        guard record.iterations > 0 else { return false }
        let candidate = hash(pin: pin, salt: record.salt, iterations: record.iterations)
        return constantTimeEqual(Array(candidate), Array(record.hash))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        for i in 0..<min(a.count, b.count) { diff |= a[i] ^ b[i] }
        return diff == 0
    }

    // MARK: PBKDF2 dispatch

    /// PBKDF2-HMAC-SHA256 (CommonCrypto when available, pure Swift otherwise).
    public static func pbkdf2(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> Data {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = password.withUnsafeBufferPointer { pw in
            salt.withUnsafeBufferPointer { sl in
                let pwPtr = pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: Int8.self) }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, password.count,
                    sl.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(max(iterations, 1)), &out, keyLength)
            }
        }
        if status == Int32(kCCSuccess) { return Data(out) }
        #endif
        return pbkdf2Pure(password: password, salt: salt, iterations: iterations, keyLength: keyLength)
    }

    /// Pure-Swift PBKDF2-HMAC-SHA256 (always available; exposed for cross-checking in tests).
    static func pbkdf2Pure(password: [UInt8], salt: [UInt8], iterations: Int, keyLength: Int) -> Data {
        let hmac = HMACSHA256(key: password)
        let iters = max(iterations, 1)
        var result = [UInt8](); result.reserveCapacity(keyLength)
        var blockIndex: UInt32 = 1
        var w = [UInt32](repeating: 0, count: 64)
        while result.count < keyLength {
            var first = salt
            first += [UInt8(blockIndex >> 24 & 0xff), UInt8(blockIndex >> 16 & 0xff),
                      UInt8(blockIndex >> 8 & 0xff), UInt8(blockIndex & 0xff)]
            var u = hmac.mac(first)                       // U1 as 8 words
            var t = u
            if iters > 1 {
                for _ in 2...iters {
                    u = hmac.mac32(u, scratch: &w)
                    for i in 0..<8 { t[i] ^= u[i] }
                }
            }
            for word in t {
                result += [UInt8(word >> 24 & 0xff), UInt8(word >> 16 & 0xff), UInt8(word >> 8 & 0xff), UInt8(word & 0xff)]
            }
            blockIndex += 1
        }
        return Data(result.prefix(keyLength))
    }
}

// MARK: - SHA-256 / HMAC (pure Swift, FIPS 180-4)

struct SHA256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    /// One compression round. `w[0..<16]` must hold the block as big-endian words; `w` is scratch (64 words).
    static func compress(_ h: inout [UInt32], _ w: inout [UInt32]) {
        for i in 16..<64 {
            let a = w[i - 15], b = w[i - 2]
            let s0 = rotr(a, 7) ^ rotr(a, 18) ^ (a >> 3)
            let s1 = rotr(b, 17) ^ rotr(b, 19) ^ (b >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        k.withUnsafeBufferPointer { kk in
            for i in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ kk[i] &+ w[i]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }

    /// Absorbs whole 64-byte blocks of `bytes` into `state`.
    static func absorb(_ state: inout [UInt32], blocks bytes: [UInt8], scratch w: inout [UInt32]) {
        var off = 0
        while off + 64 <= bytes.count {
            for i in 0..<16 {
                let j = off + i * 4
                w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j + 1]) << 16 | UInt32(bytes[j + 2]) << 8 | UInt32(bytes[j + 3])
            }
            compress(&state, &w)
            off += 64
        }
    }

    /// Full hash of `message` starting from `state` having already absorbed `prefixBytes` bytes.
    static func finish(state initial: [UInt32], prefixBytes: Int, message: [UInt8]) -> [UInt32] {
        var state = initial
        var w = [UInt32](repeating: 0, count: 64)
        let total = UInt64(prefixBytes + message.count) * 8
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for i in (0..<8).reversed() { padded.append(UInt8(truncatingIfNeeded: total >> UInt64(i * 8))) }
        absorb(&state, blocks: padded, scratch: &w)
        return state
    }

    static func bytes(_ words: [UInt32]) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(32)
        for x in words { out += [UInt8(x >> 24 & 0xff), UInt8(x >> 16 & 0xff), UInt8(x >> 8 & 0xff), UInt8(x & 0xff)] }
        return out
    }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        bytes(finish(state: initialState, prefixBytes: 0, message: message))
    }
}

/// HMAC-SHA256 with the inner/outer pad blocks pre-absorbed, so each PBKDF2 iteration
/// costs exactly two compressions.
struct HMACSHA256 {
    private let innerState: [UInt32]
    private let outerState: [UInt32]

    init(key: [UInt8]) {
        var k = key.count > 64 ? SHA256.hash(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        var w = [UInt32](repeating: 0, count: 64)
        var inner = SHA256.initialState, outer = SHA256.initialState
        SHA256.absorb(&inner, blocks: k.map { $0 ^ 0x36 }, scratch: &w)
        SHA256.absorb(&outer, blocks: k.map { $0 ^ 0x5c }, scratch: &w)
        innerState = inner; outerState = outer
    }

    /// HMAC of an arbitrary message; result as 8 big-endian words.
    func mac(_ message: [UInt8]) -> [UInt32] {
        let innerDigest = SHA256.finish(state: innerState, prefixBytes: 64, message: message)
        return SHA256.finish(state: outerState, prefixBytes: 64, message: SHA256.bytes(innerDigest))
    }

    func mac(bytes message: [UInt8]) -> [UInt8] { SHA256.bytes(mac(message)) }

    /// HMAC of a 32-byte message given as 8 words (fast path for PBKDF2 iterations).
    func mac32(_ msg: [UInt32], scratch w: inout [UInt32]) -> [UInt32] {
        var h = innerState
        for i in 0..<8 { w[i] = msg[i] }
        w[8] = 0x8000_0000
        for i in 9..<15 { w[i] = 0 }
        w[15] = (64 + 32) * 8
        SHA256.compress(&h, &w)
        var o = outerState
        for i in 0..<8 { w[i] = h[i] }
        w[8] = 0x8000_0000
        for i in 9..<15 { w[i] = 0 }
        w[15] = (64 + 32) * 8
        SHA256.compress(&o, &w)
        return o
    }
}
