import Foundation

public struct CrackCheckpoint: Codable, Equatable {
    public var targetHashHex: String
    public var prefix: String
    public var charset: String
    public var suffixLength: Int
    public var lastTestedIndex: UInt64
    public var totalKeys: UInt64
    public var elapsedTimeSec: Double
    public var timestamp: Date

    public var progressFraction: Double {
        guard totalKeys > 0 else { return 0.0 }
        return min(1.0, Double(lastTestedIndex) / Double(totalKeys))
    }

    public var progressPercentString: String {
        return String(format: "%.2f%%", progressFraction * 100.0)
    }
}

public final class CrackerCheckpointManager {
    public static let shared = CrackerCheckpointManager()

    private let userDefaultsKey = "com.harisawan.sha1cracker.active_checkpoint"
    private let lock = NSLock()

    private init() {}

    public func saveCheckpoint(
        targetHashHex: String,
        prefix: String,
        charset: String,
        suffixLength: Int,
        lastTestedIndex: UInt64,
        totalKeys: UInt64,
        elapsedTimeSec: Double
    ) {
        lock.lock()
        defer { lock.unlock() }

        let checkpoint = CrackCheckpoint(
            targetHashHex: targetHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            prefix: prefix,
            charset: charset,
            suffixLength: suffixLength,
            lastTestedIndex: lastTestedIndex,
            totalKeys: totalKeys,
            elapsedTimeSec: elapsedTimeSec,
            timestamp: Date()
        )

        if let encoded = try? JSONEncoder().encode(checkpoint) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    public func loadCheckpoint() -> CrackCheckpoint? {
        lock.lock()
        defer { lock.unlock() }

        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let checkpoint = try? JSONDecoder().decode(CrackCheckpoint.self, from: data) else {
            return nil
        }

        // Validate checkpoint integrity
        guard checkpoint.lastTestedIndex < checkpoint.totalKeys, checkpoint.lastTestedIndex > 0 else {
            return nil
        }

        return checkpoint
    }

    public func clearCheckpoint() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }

    public func matchesCurrentConfig(
        checkpoint: CrackCheckpoint,
        targetHashHex: String,
        prefix: String,
        charset: String,
        suffixLength: Int
    ) -> Bool {
        return checkpoint.targetHashHex == targetHashHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() &&
               checkpoint.prefix == prefix &&
               checkpoint.charset == charset &&
               checkpoint.suffixLength == suffixLength
    }
}
