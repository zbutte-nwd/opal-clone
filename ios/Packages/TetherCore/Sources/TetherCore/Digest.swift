import Foundation

public enum TetherDigest {
    /// SHA-256 as lowercase hex (pure Swift, same implementation the PIN hasher uses; builds on Linux).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash([UInt8](data)).map { String(format: "%02x", $0) }.joined()
    }
}
