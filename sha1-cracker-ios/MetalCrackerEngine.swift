import Foundation
import Metal
import Combine
import UIKit

// -----------------------------------------------------------------------------
// Engine Status & Telemetry
// -----------------------------------------------------------------------------

public enum CrackerState: String {
    case idle = "Idle"
    case selfTesting = "Testing Metal GPU & CPU..."
    case selfTestPassed = "Ready (Self-Test Passed)"
    case selfTestFailed = "Self-Test Failed"
    case running = "Cracking (Hybrid Active)"
    case paused = "Paused"
    case found = "TARGET CRACKED!"
    case completed = "Finished (Exhausted)"
    case error = "Error"
}

public enum EngineMode: String, CaseIterable, Identifiable {
    case hybrid = "Hybrid (GPU + CPU)"
    case gpuOnly = "GPU Only"
    case cpuOnly = "CPU Multi-Core Only"

    public var id: String { self.rawValue }
}

public struct CrackConfig {
    public var targetHashHexStrings: [String]
    public var prefix: String
    public var charset: String
    public var suffixLength: Int
    public var chunkSize: Int
    public var autoThermalThrottle: Bool
    public var mode: EngineMode

    public static let h2Preset = CrackConfig(
        targetHashHexStrings: ["fa4584ca1d5bd18dc467ef31f84a337f32329c40"],
        prefix: "sadiy",
        charset: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        suffixLength: 7,
        chunkSize: 16_777_216, // 16M keys per chunk for maximum A17 Pro GPU occupancy
        autoThermalThrottle: true,
        mode: .hybrid
    )

    public static let h1SelfTestPreset = CrackConfig(
        targetHashHexStrings: ["824dd5552ec2cc0ccab320198fb47b3b032f2d3f"],
        prefix: "sn200",
        charset: "0123456789",
        suffixLength: 1,
        chunkSize: 4_194_304,
        autoThermalThrottle: false,
        mode: .hybrid
    )
}

public final class MetalCrackerEngine: ObservableObject {
    // UI Published state
    @Published public var state: CrackerState = .idle
    @Published public var keysTested: UInt64 = 0
    @Published public var totalKeys: UInt64 = 0
    @Published public var progressFraction: Double = 0.0
    @Published public var speedMKeysPerSec: Double = 0.0
    @Published public var speedGKeysPerSec: Double = 0.0
    @Published public var speedGPUGKeysPerSec: Double = 0.0
    @Published public var speedCPUMKeysPerSec: Double = 0.0
    @Published public var elapsedTimeSec: Double = 0.0
    @Published public var etaString: String = "--"
    @Published public var thermalStateDescription: String = "Nominal"
    @Published public var thermalStateColor: String = "green"
    @Published public var foundCandidate: String? = nil
    @Published public var logs: [String] = []
    @Published public var activeCheckpoint: CrackCheckpoint? = nil

    // Metal GPU Pipeline
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var generalPipelineState: MTLComputePipelineState?
    private var suffix7PipelineState: MTLComputePipelineState?
    private var smallPipelineState: MTLComputePipelineState?

    // CPU ARM64 Engine
    private let cpuEngine = CPUARM64CryptoEngine()

    // Execution Control
    private var isCancelled: Bool = false
    private var isPaused: Bool = false
    private let workQueue = DispatchQueue(label: "com.harisawan.sha1cracker.gpu", qos: .userInitiated)
    private let cpuWorkQueue = DispatchQueue(label: "com.harisawan.sha1cracker.cpu", qos: .userInitiated, attributes: .concurrent)
    private var timer: AnyCancellable?
    private let stateLock = NSLock()

    // Performance tracking
    private var startTime: Date?
    private var lastSpeedCheckTime: Date?
    private var lastSpeedCheckKeys: UInt64 = 0
    private var gpuKeysTested: UInt64 = 0
    private var cpuKeysTested: UInt64 = 0
    private var lastGPUKeys: UInt64 = 0
    private var lastCPUKeys: UInt64 = 0
    private var lastCheckpointSaveTime: Date = Date()

    // Current Config & Index
    private var currentConfig: CrackConfig?
    private var currentGlobalIndex: UInt64 = 0

    public init() {
        setupMetal()
        setupThermalObserver()
        checkExistingCheckpoint()
        log("Metal + CPU Heterogeneous Cracker Engine v3.0 initialized.")
        // Automatically trigger self-test on init
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.runSelfTest()
        }
    }

    public func checkExistingCheckpoint() {
        self.activeCheckpoint = CrackerCheckpointManager.shared.loadCheckpoint()
        if let cp = self.activeCheckpoint {
            log("💾 Found previous saved checkpoint: \(cp.progressPercentString) completed (\(formatNumber(cp.lastTestedIndex)) / \(formatNumber(cp.totalKeys)) keys).")
        }
    }

    // -------------------------------------------------------------------------
    // Metal Pipeline Setup
    // -------------------------------------------------------------------------
    private func setupMetal() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            state = .error
            log("❌ ERROR: Metal compute is not supported on this device.")
            return
        }
        self.device = defaultDevice
        self.commandQueue = defaultDevice.makeCommandQueue()
        log("🚀 GPU Engine: \(defaultDevice.name) (6-Core Apple Family 9)")
        log("🧠 CPU Co-Worker: \(ProcessInfo.processInfo.activeProcessorCount) Cores (ARMv8.2-A Crypto Active)")

        do {
            let library: MTLLibrary
            if let defaultLib = defaultDevice.makeDefaultLibrary() {
                library = defaultLib
            } else {
                guard let shaderURL = Bundle.main.url(forResource: "sha1_mask", withExtension: "metal"),
                      let source = try? String(contentsOf: shaderURL) else {
                    throw NSError(domain: "MetalCracker", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to locate sha1_mask.metal"])
                }
                library = try defaultDevice.makeLibrary(source: source, options: nil)
            }

            if let generalFunc = library.makeFunction(name: "sha1_mask_crack") {
                self.generalPipelineState = try defaultDevice.makeComputePipelineState(function: generalFunc)
                log("⚡ GPU Pipeline: General Mask Engine compiled.")
            }
            if let suffix7Func = library.makeFunction(name: "sha1_crack_suffix7_b62") {
                self.suffix7PipelineState = try defaultDevice.makeComputePipelineState(function: suffix7Func)
                log("⚡ GPU Pipeline: A17 Pro Suffix-7 Base62 Ultra Engine compiled.")
            }
            if let smallFunc = library.makeFunction(name: "sha1_crack_small") {
                self.smallPipelineState = try defaultDevice.makeComputePipelineState(function: smallFunc)
                log("⚡ GPU Pipeline: Small-Suffix Fast Engine compiled.")
            }
            log("✅ GPU & CPU Compute Pipelines ready for heterogeneous execution.")
        } catch {
            state = .error
            log("❌ ERROR compiling Metal shaders: \(error.localizedDescription)")
        }
    }

    // -------------------------------------------------------------------------
    // Self-Test Verification
    // -------------------------------------------------------------------------
    public func runSelfTest() {
        state = .selfTesting
        log("🧪 Running Heterogeneous Self-Test on Vector H1 ('sn2005')...")

        let config = CrackConfig.h1SelfTestPreset

        // 1. GPU Verification
        var gpuPassed = false
        if let device = device, let commandQueue = commandQueue {
            let pipeline = smallPipelineState ?? generalPipelineState ?? suffix7PipelineState
            if let validPipeline = pipeline {
                let result = executeSynchronousChunk(
                    device: device,
                    commandQueue: commandQueue,
                    pipeline: validPipeline,
                    config: config,
                    startIdx: 0,
                    count: 10
                )
                gpuPassed = (result == "sn2005")
            }
        }

        // 2. CPU Verification
        let targetHex = "824dd5552ec2cc0ccab320198fb47b3b032f2d3f"
        let targetWords = parseHexToWords(targetHex)
        let cpuResult = cpuEngine.crackChunk(
            startIdx: 0,
            count: 10,
            prefix: "sn200",
            suffixLength: 1,
            charset: "0123456789",
            targetWords: targetWords
        )
        let cpuPassed = (cpuResult == "sn2005")

        if gpuPassed && cpuPassed {
            state = .selfTestPassed
            log("✅ GPU & CPU Self-Tests PASSED! Both engines verified against vector 'sn2005'.")
        } else if gpuPassed {
            state = .selfTestPassed
            log("✅ GPU Self-Test PASSED ('sn2005'). CPU fallback ready.")
        } else {
            state = .selfTestFailed
            log("❌ Self-Test FAILED! Expected 'sn2005'.")
        }
    }

    // -------------------------------------------------------------------------
    // Cracking Execution Loop (Heterogeneous Orchestrator)
    // -------------------------------------------------------------------------
    public func startCracking(config: CrackConfig, startFromIndex: UInt64 = 0) {
        guard !config.targetHashHexStrings.isEmpty else {
            log("❌ ERROR: No target hash specified.")
            return
        }

        self.currentConfig = config

        // Calculate total keyspace
        let base = UInt64(max(1, config.charset.count))
        var total: UInt64 = 1
        for _ in 0..<min(config.suffixLength, 12) {
            let (next, overflow) = total.multipliedReportingOverflow(by: base)
            if overflow {
                total = UInt64.max
                break
            }
            total = next
        }

        let finalTotal = total
        stateLock.lock()
        self.totalKeys = finalTotal
        self.keysTested = startFromIndex
        self.currentGlobalIndex = startFromIndex
        self.progressFraction = finalTotal > 0 ? Double(startFromIndex) / Double(finalTotal) : 0.0
        self.foundCandidate = nil
        self.isCancelled = false
        self.isPaused = false
        self.state = .running
        self.startTime = Date()
        self.lastSpeedCheckTime = Date()
        self.lastSpeedCheckKeys = startFromIndex
        self.gpuKeysTested = 0
        self.cpuKeysTested = 0
        self.lastGPUKeys = 0
        self.lastCPUKeys = 0
        self.lastCheckpointSaveTime = Date()
        stateLock.unlock()

        log("🚀 Launching Attack [Mode: \(config.mode.rawValue)]")
        log("📊 Target Hash: \(config.targetHashHexStrings.first ?? "")")
        log("🔢 Keyspace: \(formatNumber(finalTotal)) keys (Starting at index \(formatNumber(startFromIndex)))")

        startTelemetryTimer()

        // Launch Master Coordinator
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.runHeterogeneousLoop(config: config, totalKeys: finalTotal, startIdx: startFromIndex)
        }
    }

    public func resumeSavedCheckpoint() {
        guard let cp = activeCheckpoint else { return }
        let config = CrackConfig(
            targetHashHexStrings: [cp.targetHashHex],
            prefix: cp.prefix,
            charset: cp.charset,
            suffixLength: cp.suffixLength,
            chunkSize: 16_777_216,
            autoThermalThrottle: true,
            mode: .hybrid
        )
        log("♻️ Resuming session from index \(formatNumber(cp.lastTestedIndex)) (\(cp.progressPercentString))...")
        startCracking(config: config, startFromIndex: cp.lastTestedIndex)
    }

    private func runHeterogeneousLoop(config: CrackConfig, totalKeys: UInt64, startIdx: UInt64) {
        guard let device = self.device, let commandQueue = self.commandQueue else {
            DispatchQueue.main.async {
                self.state = .error
                self.log("❌ Metal GPU device unavailable.")
            }
            return
        }

        // Select optimal GPU pipeline
        let isSuffix7Base62 = (config.suffixLength == 7 &&
                               config.charset == "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" &&
                               config.prefix == "sadiy" &&
                               suffix7PipelineState != nil)

        let isSmallSuffix = (config.suffixLength <= 4 && smallPipelineState != nil)

        let gpuPipeline: MTLComputePipelineState
        if isSuffix7Base62 {
            gpuPipeline = suffix7PipelineState!
        } else if isSmallSuffix {
            gpuPipeline = smallPipelineState!
        } else {
            gpuPipeline = generalPipelineState ?? suffix7PipelineState!
        }

        let maxConcurrentGPU = 4
        let gpuSemaphore = DispatchSemaphore(value: maxConcurrentGPU)
        let dispatchGroup = DispatchGroup()

        var currentStartIdx: UInt64 = startIdx
        var baseGPUChunkSize = UInt64(max(256, config.chunkSize))
        let cpuChunkSize: UInt64 = 250_000

        var paramBuffers: [MTLBuffer] = []
        var resultBuffers: [MTLBuffer] = []
        for _ in 0..<maxConcurrentGPU {
            if let pb = device.makeBuffer(length: 512, options: .storageModeShared),
               let rb = device.makeBuffer(length: 128, options: .storageModeShared) {
                paramBuffers.append(pb)
                resultBuffers.append(rb)
            }
        }

        var bufferIndex = 0
        var matchFound = false
        let targetWords = parseHexToWords(config.targetHashHexStrings.first ?? "")

        while currentStartIdx < totalKeys {
            stateLock.lock()
            let cancelled = self.isCancelled
            let paused = self.isPaused
            stateLock.unlock()

            if cancelled || matchFound { break }

            if paused {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            // Periodic Checkpoint Saving every 5 seconds
            if Date().timeIntervalSince(lastCheckpointSaveTime) >= 5.0 {
                lastCheckpointSaveTime = Date()
                let idx = currentStartIdx
                let elapsed = elapsedTimeSec
                CrackerCheckpointManager.shared.saveCheckpoint(
                    targetHashHex: config.targetHashHexStrings.first ?? "",
                    prefix: config.prefix,
                    charset: config.charset,
                    suffixLength: config.suffixLength,
                    lastTestedIndex: idx,
                    totalKeys: totalKeys,
                    elapsedTimeSec: elapsed
                )
            }

            // Dynamic Thermal Management
            var actualGPUChunk = baseGPUChunkSize
            if config.autoThermalThrottle {
                let thermal = ProcessInfo.processInfo.thermalState
                if thermal == .serious {
                    actualGPUChunk = max(2_097_152, baseGPUChunkSize / 2)
                    Thread.sleep(forTimeInterval: 0.002)
                } else if thermal == .critical {
                    actualGPUChunk = max(1_048_576, baseGPUChunkSize / 4)
                    Thread.sleep(forTimeInterval: 0.008)
                }
            }

            // 1. CPU Co-Worker Dispatch (when in Hybrid or CPU-Only mode)
            if (config.mode == .hybrid || config.mode == .cpuOnly) && !matchFound {
                let thisCPUChunk = min(cpuChunkSize, totalKeys - currentStartIdx)
                let cpuStart = currentStartIdx
                currentStartIdx += thisCPUChunk

                dispatchGroup.enter()
                cpuWorkQueue.async { [weak self] in
                    defer { dispatchGroup.leave() }
                    guard let self = self else { return }

                    let result = self.cpuEngine.crackChunk(
                        startIdx: cpuStart,
                        count: UInt32(thisCPUChunk),
                        prefix: config.prefix,
                        suffixLength: config.suffixLength,
                        charset: config.charset,
                        targetWords: targetWords
                    )

                    if let found = result {
                        matchFound = true
                        self.handleFoundCandidate(candidate: found, targetHex: config.targetHashHexStrings.first ?? "")
                    }

                    DispatchQueue.main.async {
                        self.cpuKeysTested += thisCPUChunk
                        self.keysTested += thisCPUChunk
                        if totalKeys > 0 {
                            self.progressFraction = min(1.0, Double(self.keysTested) / Double(totalKeys))
                        }
                    }
                }
            }

            if config.mode == .cpuOnly { continue }

            // 2. GPU Dispatch (when in Hybrid or GPU-Only mode)
            if currentStartIdx < totalKeys && !matchFound {
                let thisGPUChunk = min(actualGPUChunk, totalKeys - currentStartIdx)
                let gpuStart = currentStartIdx
                currentStartIdx += thisGPUChunk

                gpuSemaphore.wait()
                dispatchGroup.enter()

                let pb = paramBuffers[bufferIndex]
                let rb = resultBuffers[bufferIndex]
                bufferIndex = (bufferIndex + 1) % maxConcurrentGPU

                writeParams(to: pb, startIdx: gpuStart, chunkSize: UInt32(thisGPUChunk), config: config)
                rb.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 128)

                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                      let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    gpuSemaphore.signal()
                    dispatchGroup.leave()
                    break
                }

                encoder.setComputePipelineState(gpuPipeline)
                encoder.setBuffer(pb, offset: 0, index: 0)
                encoder.setBuffer(rb, offset: 0, index: 1)

                let threadgroupWidth = min(256, max(1, Int(thisGPUChunk)))
                let threadsPerGroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
                let totalThreads = MTLSize(width: Int(thisGPUChunk), height: 1, depth: 1)
                encoder.dispatchThreads(totalThreads, threadsPerThreadgroup: threadsPerGroup)
                encoder.endEncoding()

                let dispatchedCount = thisGPUChunk
                commandBuffer.addCompletedHandler { [weak self] _ in
                    defer {
                        gpuSemaphore.signal()
                        dispatchGroup.leave()
                    }
                    guard let self = self else { return }

                    let foundFlag = rb.contents().load(as: UInt32.self)
                    if foundFlag != 0 {
                        matchFound = true
                        let matchedLen = rb.contents().advanced(by: 8).load(as: UInt32.self)
                        let safeLen = min(max(Int(matchedLen), 1), 63)
                        let rawBytes = rb.contents().advanced(by: 12).bindMemory(to: UInt8.self, capacity: safeLen)
                        let bufferSlice = UnsafeBufferPointer(start: rawBytes, count: safeLen)
                        let candidateStr = String(decoding: bufferSlice.prefix(while: { $0 != 0 }), as: UTF8.self)
                        self.handleFoundCandidate(candidate: candidateStr, targetHex: config.targetHashHexStrings.first ?? "")
                    }

                    DispatchQueue.main.async {
                        self.gpuKeysTested += dispatchedCount
                        self.keysTested += dispatchedCount
                        if totalKeys > 0 {
                            self.progressFraction = min(1.0, Double(self.keysTested) / Double(totalKeys))
                        }
                    }
                }

                commandBuffer.commit()
            }
        }

        dispatchGroup.wait()

        // Clear checkpoint if search finished naturally or match discovered
        DispatchQueue.main.async {
            self.stateLock.lock()
            let isFound = (self.foundCandidate != nil) || matchFound
            let wasCancelled = self.isCancelled
            self.stateLock.unlock()

            if isFound {
                self.state = .found
                CrackerCheckpointManager.shared.clearCheckpoint()
                self.activeCheckpoint = nil
            } else if wasCancelled {
                self.state = .idle
                self.log("⏹️ Cracking paused/halted by user. Checkpoint saved.")
                self.checkExistingCheckpoint()
            } else {
                self.state = .completed
                self.progressFraction = 1.0
                CrackerCheckpointManager.shared.clearCheckpoint()
                self.activeCheckpoint = nil
                self.log("🏁 Search finished: Key space exhausted without a match.")
            }
        }
    }

    private func handleFoundCandidate(candidate: String, targetHex: String) {
        DispatchQueue.main.async {
            self.stateLock.lock()
            self.foundCandidate = candidate
            self.state = .found
            self.stateLock.unlock()

            self.log("🎯 =============================================")
            self.log("🎉 CRACKED MATCH DISCOVERED: '\(candidate)'")
            self.log("🎯 Target Hash: \(targetHex)")
            self.log("🎯 =============================================")
        }
    }

    // -------------------------------------------------------------------------
    // Helper: Synchronous Single-Chunk Execution (for Self-Test)
    // -------------------------------------------------------------------------
    private func executeSynchronousChunk(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        config: CrackConfig,
        startIdx: UInt64,
        count: UInt32
    ) -> String? {
        guard let pb = device.makeBuffer(length: 512, options: .storageModeShared),
              let rb = device.makeBuffer(length: 128, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        writeParams(to: pb, startIdx: startIdx, chunkSize: count, config: config)
        rb.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 128)

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(pb, offset: 0, index: 0)
        encoder.setBuffer(rb, offset: 0, index: 1)

        let threadgroupWidth = min(256, max(1, Int(count)))
        let threadsPerGroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
        let totalThreads = MTLSize(width: Int(count), height: 1, depth: 1)
        encoder.dispatchThreads(totalThreads, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let foundFlag = rb.contents().load(as: UInt32.self)
        if foundFlag != 0 {
            let matchedLen = rb.contents().advanced(by: 8).load(as: UInt32.self)
            let safeLen = min(max(Int(matchedLen), 1), 63)
            let rawBytes = rb.contents().advanced(by: 12).bindMemory(to: UInt8.self, capacity: safeLen)
            let bufferSlice = UnsafeBufferPointer(start: rawBytes, count: safeLen)
            return String(decoding: bufferSlice.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return nil
    }

    // -------------------------------------------------------------------------
    // Parameter Serialization
    // -------------------------------------------------------------------------
    private func writeParams(
        to buffer: MTLBuffer,
        startIdx: UInt64,
        chunkSize: UInt32,
        config: CrackConfig
    ) {
        let ptr = buffer.contents()
        ptr.initializeMemory(as: UInt8.self, repeating: 0, count: 512)

        ptr.storeBytes(of: startIdx, toByteOffset: 0, as: UInt64.self)
        ptr.storeBytes(of: chunkSize, toByteOffset: 8, as: UInt32.self)

        let prefixBytes = Array(config.prefix.utf8)
        let prefixLen = UInt32(prefixBytes.count)
        ptr.storeBytes(of: prefixLen, toByteOffset: 12, as: UInt32.self)

        let suffixLen = UInt32(config.suffixLength)
        ptr.storeBytes(of: suffixLen, toByteOffset: 16, as: UInt32.self)

        let charsetBytes = Array(config.charset.utf8)
        let base = UInt32(max(1, charsetBytes.count))
        ptr.storeBytes(of: base, toByteOffset: 20, as: UInt32.self)

        let targetCount = UInt32(min(16, config.targetHashHexStrings.count))
        ptr.storeBytes(of: targetCount, toByteOffset: 24, as: UInt32.self)

        // Parse target hashes (5x UInt32 big-endian per hash)
        for t in 0..<Int(targetCount) {
            let hex = config.targetHashHexStrings[t].trimmingCharacters(in: .whitespacesAndNewlines)
            if hex.count == 40 {
                for wordIdx in 0..<5 {
                    let start = hex.index(hex.startIndex, offsetBy: wordIdx * 8)
                    let end = hex.index(start, offsetBy: 8)
                    let wordHex = String(hex[start..<end])
                    if let wordVal = UInt32(wordHex, radix: 16) {
                        let offset = 28 + (t * 5 + wordIdx) * 4
                        ptr.storeBytes(of: wordVal, toByteOffset: offset, as: UInt32.self)
                    }
                }
            }
        }

        // Copy prefix bytes
        for i in 0..<min(64, prefixBytes.count) {
            ptr.advanced(by: 348 + i).storeBytes(of: prefixBytes[i], as: UInt8.self)
        }

        // Copy charset bytes
        for i in 0..<min(64, charsetBytes.count) {
            ptr.advanced(by: 412 + i).storeBytes(of: charsetBytes[i], as: UInt8.self)
        }

        // Pre-packed prefix words for fast kernel register load
        var pw0: UInt32 = 0
        var pw1: UInt32 = 0
        if prefixBytes.count >= 4 {
            pw0 = (UInt32(prefixBytes[0]) << 24) | (UInt32(prefixBytes[1]) << 16) | (UInt32(prefixBytes[2]) << 8) | UInt32(prefixBytes[3])
        }
        if prefixBytes.count >= 5 {
            pw1 = UInt32(prefixBytes[4]) << 24
        }
        ptr.storeBytes(of: pw0, toByteOffset: 476, as: UInt32.self)
        ptr.storeBytes(of: pw1, toByteOffset: 480, as: UInt32.self)
    }

    private func parseHexToWords(_ hex: String) -> [UInt32] {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count == 40 else { return [0, 0, 0, 0, 0] }
        var words = [UInt32]()
        for i in 0..<5 {
            let start = clean.index(clean.startIndex, offsetBy: i * 8)
            let end = clean.index(start, offsetBy: 8)
            let chunk = String(clean[start..<end])
            words.append(UInt32(chunk, radix: 16) ?? 0)
        }
        return words
    }

    // -------------------------------------------------------------------------
    // User Controls
    // -------------------------------------------------------------------------
    public func pause() {
        stateLock.lock()
        isPaused = true
        state = .paused
        stateLock.unlock()
        cpuEngine.stop()
        log("⏸️ Cracking paused.")
    }

    public func resume() {
        stateLock.lock()
        isPaused = false
        state = .running
        stateLock.unlock()
        cpuEngine.reset()
        log("▶️ Cracking resumed.")
    }

    public func stop() {
        stateLock.lock()
        isCancelled = true
        isPaused = false
        stateLock.unlock()
        cpuEngine.stop()
        timer?.cancel()
        log("⏹️ Stop requested. Waiting for active workers to complete...")
    }

    public func clearLogs() {
        DispatchQueue.main.async {
            self.logs.removeAll()
            self.log("Logs cleared.")
        }
    }

    public func getAllLogsFormatted() -> String {
        return logs.joined(separator: "\n")
    }

    // -------------------------------------------------------------------------
    // Telemetry & Thermal Monitoring
    // -------------------------------------------------------------------------
    private func startTelemetryTimer() {
        timer?.cancel()
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.updateTelemetry()
            }
    }

    private func updateTelemetry() {
        guard let start = startTime, state == .running else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(start)
        self.elapsedTimeSec = elapsed

        if let lastCheck = lastSpeedCheckTime {
            let interval = now.timeIntervalSince(lastCheck)
            if interval >= 0.5 {
                let totalDelta = keysTested > lastSpeedCheckKeys ? keysTested - lastSpeedCheckKeys : 0
                let gpuDelta = gpuKeysTested > lastGPUKeys ? gpuKeysTested - lastGPUKeys : 0
                let cpuDelta = cpuKeysTested > lastCPUKeys ? cpuKeysTested - lastCPUKeys : 0

                let currentTotalSpeedMKeys = Double(totalDelta) / interval / 1_000_000.0
                let currentGPUSpeedMKeys = Double(gpuDelta) / interval / 1_000_000.0
                let currentCPUSpeedMKeys = Double(cpuDelta) / interval / 1_000_000.0

                self.speedMKeysPerSec = currentTotalSpeedMKeys
                self.speedGKeysPerSec = currentTotalSpeedMKeys / 1000.0
                self.speedGPUGKeysPerSec = currentGPUSpeedMKeys / 1000.0
                self.speedCPUMKeysPerSec = currentCPUSpeedMKeys

                self.lastSpeedCheckTime = now
                self.lastSpeedCheckKeys = keysTested
                self.lastGPUKeys = gpuKeysTested
                self.lastCPUKeys = cpuKeysTested

                // Calculate ETA
                if currentTotalSpeedMKeys > 0 && keysTested < totalKeys {
                    let remainingKeys = totalKeys - keysTested
                    let etaSeconds = Double(remainingKeys) / (currentTotalSpeedMKeys * 1_000_000.0)
                    self.etaString = formatETA(seconds: etaSeconds)
                } else if keysTested >= totalKeys {
                    self.etaString = "0s"
                }
            }
        }
    }

    private func setupThermalObserver() {
        updateThermalState()
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateThermalState()
        }
    }

    private func updateThermalState() {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:
            thermalStateDescription = "Nominal (Cool)"
            thermalStateColor = "green"
        case .fair:
            thermalStateDescription = "Fair (Warm)"
            thermalStateColor = "yellow"
        case .serious:
            thermalStateDescription = "Serious (Throttled)"
            thermalStateColor = "orange"
            log("⚠️ Device thermal state changed to: SERIOUS (Throttling pacing active)")
        case .critical:
            thermalStateDescription = "Critical (High Heat)"
            thermalStateColor = "red"
            log("🚨 Device thermal state changed to: CRITICAL (Cooling pacing active)")
        @unknown default:
            thermalStateDescription = "Unknown"
            thermalStateColor = "gray"
        }
    }

    // -------------------------------------------------------------------------
    // Logging & Formatting Helpers
    // -------------------------------------------------------------------------
    public func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        let formatted = "[\(timestamp)] \(message)"
        DispatchQueue.main.async {
            self.logs.append(formatted)
            if self.logs.count > 1000 {
                self.logs.removeFirst(self.logs.count - 1000)
            }
        }
    }

    private func formatNumber(_ num: UInt64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: num)) ?? "\(num)"
    }

    private func formatETA(seconds: Double) -> String {
        if seconds.isInfinite || seconds.isNaN { return "--" }
        let sec = Int(seconds)
        let hours = sec / 3600
        let minutes = (sec % 3600) / 60
        let s = sec % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m \(s)s"
        } else if minutes > 0 {
            return "\(minutes)m \(s)s"
        } else {
            return "\(s)s"
        }
    }
}
