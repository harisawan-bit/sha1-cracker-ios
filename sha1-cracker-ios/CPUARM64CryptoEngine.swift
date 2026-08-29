import Foundation

// -----------------------------------------------------------------------------
// CPU ARM64 High-Throughput SHA-1 Cracking Engine (Multi-Core Worker Pool)
// -----------------------------------------------------------------------------

public final class CPUARM64CryptoEngine {
    private var isCancelled: Bool = false
    private let lock = NSLock()

    public init() {}

    public func stop() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        isCancelled = false
        lock.unlock()
    }

    /// Crack a single chunk on the CPU across available CPU cores
    /// Returns the cracked candidate string if discovered
    public func crackChunk(
        startIdx: UInt64,
        count: UInt32,
        prefix: String,
        suffixLength: Int,
        charset: String,
        targetWords: [UInt32],
        onProgress: ((UInt32) -> Void)? = nil
    ) -> String? {
        guard count > 0, targetWords.count >= 5 else { return nil }

        lock.lock()
        isCancelled = false
        lock.unlock()

        let prefixBytes = Array(prefix.utf8)
        let prefixLen = prefixBytes.count
        let charsetBytes = Array(charset.utf8)
        let base = UInt64(max(1, charsetBytes.count))
        let totalLen = prefixLen + suffixLength

        let targetA = targetWords[0]
        let targetB = targetWords[1]
        let targetC = targetWords[2]
        let targetD = targetWords[3]
        let targetE = targetWords[4]

        let numCores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let itemsPerCore = Int(count) / numCores
        var foundMatch: String? = nil
        let matchLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: numCores) { coreIdx in
            let coreStart = UInt64(coreIdx * itemsPerCore)
            let coreCount = (coreIdx == numCores - 1) ? UInt64(count) - coreStart : UInt64(itemsPerCore)

            var localW = [UInt32](repeating: 0, count: 16)
            var suffBuf = [UInt8](repeating: 0, count: 16)

            for i in 0..<coreCount {
                if coreIdx == 0 && (i & 0x7FFF) == 0 {
                    self.lock.lock()
                    let cancelled = self.isCancelled
                    self.lock.unlock()
                    if cancelled { break }
                    onProgress?(0x8000)
                }

                matchLock.lock()
                let alreadyFound = (foundMatch != nil)
                matchLock.unlock()
                if alreadyFound { break }

                let candidateIdx = startIdx + coreStart + i

                // Reconstruct suffix characters
                var rem = candidateIdx
                for s in (0..<suffixLength).reversed() {
                    suffBuf[s] = charsetBytes[Int(rem % base)]
                    rem /= base
                }

                // Clear message schedule block
                for wIdx in 0..<16 { localW[wIdx] = 0 }

                // Pack prefix bytes (big-endian)
                for p in 0..<prefixLen {
                    let wPos = p >> 2
                    let bPos = 3 - (p & 3)
                    localW[wPos] |= UInt32(prefixBytes[p]) << (bPos * 8)
                }

                // Pack suffix bytes (big-endian)
                for s in 0..<suffixLength {
                    let pos = prefixLen + s
                    let wPos = pos >> 2
                    let bPos = 3 - (pos & 3)
                    localW[wPos] |= UInt32(suffBuf[s]) << (bPos * 8)
                }

                // Append mandatory 0x80 padding byte
                let padWord = totalLen >> 2
                let padByte = 3 - (totalLen & 3)
                localW[padWord] |= 0x80 << (padByte * 8)

                // Length in bits in final word
                localW[15] = UInt32(totalLen * 8)

                // Execute SHA-1 compression function
                var a: UInt32 = 0x67452301
                var b: UInt32 = 0xEFCDAB89
                var c: UInt32 = 0x98BADCFE
                var d: UInt32 = 0x10325476
                var e: UInt32 = 0xC3D2E1F0

                var w = localW

                // Helper macros via inline closures
                @inline(__always) func rol(_ val: UInt32, _ n: UInt32) -> UInt32 {
                    return (val << n) | (val >> (32 - n))
                }

                // Rounds 0..15
                for t in 0..<16 {
                    let f = (b & c) | ((~b) & d)
                    let temp = rol(a, 5) &+ f &+ e &+ 0x5A827999 &+ w[t]
                    e = d
                    d = c
                    c = rol(b, 30)
                    b = a
                    a = temp
                }

                // Rounds 16..19
                for t in 16..<20 {
                    let expanded = rol(w[(t - 3) & 15] ^ w[(t - 8) & 15] ^ w[(t - 14) & 15] ^ w[(t - 16) & 15], 1)
                    w[t & 15] = expanded
                    let f = (b & c) | ((~b) & d)
                    let temp = rol(a, 5) &+ f &+ e &+ 0x5A827999 &+ expanded
                    e = d
                    d = c
                    c = rol(b, 30)
                    b = a
                    a = temp
                }

                // Rounds 20..39
                for t in 20..<40 {
                    let expanded = rol(w[(t - 3) & 15] ^ w[(t - 8) & 15] ^ w[(t - 14) & 15] ^ w[(t - 16) & 15], 1)
                    w[t & 15] = expanded
                    let f = b ^ c ^ d
                    let temp = rol(a, 5) &+ f &+ e &+ 0x6ED9EBA1 &+ expanded
                    e = d
                    d = c
                    c = rol(b, 30)
                    b = a
                    a = temp
                }

                // Rounds 40..59
                for t in 40..<60 {
                    let expanded = rol(w[(t - 3) & 15] ^ w[(t - 8) & 15] ^ w[(t - 14) & 15] ^ w[(t - 16) & 15], 1)
                    w[t & 15] = expanded
                    let f = (b & c) | (b & d) | (c & d)
                    let temp = rol(a, 5) &+ f &+ e &+ 0x8F1BBCDC &+ expanded
                    e = d
                    d = c
                    c = rol(b, 30)
                    b = a
                    a = temp
                }

                // Rounds 60..79
                for t in 60..<80 {
                    let expanded = rol(w[(t - 3) & 15] ^ w[(t - 8) & 15] ^ w[(t - 14) & 15] ^ w[(t - 16) & 15], 1)
                    w[t & 15] = expanded
                    let f = b ^ c ^ d
                    let temp = rol(a, 5) &+ f &+ e &+ 0xCA62C1D6 &+ expanded
                    e = d
                    d = c
                    c = rol(b, 30)
                    b = a
                    a = temp
                }

                let finalA = 0x67452301 &+ a
                let finalB = 0xEFCDAB89 &+ b
                let finalC = 0x98BADCFE &+ c
                let finalD = 0x10325476 &+ d
                let finalE = 0xC3D2E1F0 &+ e

                if finalA == targetA && finalB == targetB && finalC == targetC && finalD == targetD && finalE == targetE {
                    var fullCandidate = prefixBytes
                    fullCandidate.append(contentsOf: suffBuf[0..<suffixLength])
                    let resultString = String(decoding: fullCandidate, as: UTF8.self)

                    matchLock.lock()
                    foundMatch = resultString
                    matchLock.unlock()
                    break
                }
            }
        }

        return foundMatch
    }
}
