import Foundation
import Metal
import Combine
import UIKit

// -----------------------------------------------------------------------------
// Engine Status & Telemetry
// -----------------------------------------------------------------------------

public enum CrackerState: String {
    case idle = "Idle"
    case selfTesting = "Testing Metal GPU..."
    case selfTestPassed = "Ready (Self-Test Passed)"
    case selfTestFailed = "Self-Test Failed"
    case running = "Cracking (GPU Active)"
    case paused = "Paused"
    case found = "TARGET CRACKED!"
    case completed = "Finished (Exhausted)"
    case error = "Error"
}

public struct CrackConfig {
    public var targetHashHexStrings: [String]
    public var prefix: String
    public var charset: String
    public var suffixLength: Int
    public var chunkSize: Int
    public var autoThermalThrottle: Bool

    public static let h2Preset = CrackConfig(
        targetHashHexStrings: ["fa4584ca1d5bd18dc467ef31f84a337f32329c40"],
        prefix: "sadiy",
        charset: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        suffixLength: 7,
        chunkSize: 16_777_216, // 16M keys per chunk for maximum GPU occupancy
        autoThermalThrottle: true
    )

    public static let h1SelfTestPreset = CrackConfig(
        targetHashHexStrings: ["824dd5552ec2cc0ccab320198fb47b3b032f2d3f"],
        prefix: "sn200",
        charset: "0123456789",
        suffixLength: 1,
        chunkSize: 64,
        autoThermalThrottle: false
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
    @Published public var elapsedTimeSec: Double = 0.0
    @Published public var etaString: String = "--"
    @Published public var thermalStateDescription: String = "Nominal"
    @Published public var thermalStateColor: String = "green"
    @Published public var foundCandidate: String? = nil
    @Published public var logs: [String] = []

    // Metal Pipeline
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var generalPipelineState: MTLComputePipelineState?
    private var suffix7PipelineState: MTLComputePipelineState?

    // Execution Control
    private var isCancelled: Bool = false
    private var isPaused: Bool = false
    private let workQueue = DispatchQueue(label: "com.harisawan.sha1cracker.gpu", qos: .userInitiated)
    private var timer: AnyCancellable?

    // Performance tracking
    private var startTime: Date?
    private var lastSpeedCheckTime: Date?
    private var lastSpeedCheckKeys: UInt64 = 0

    public init() {
        setupMetal()
        setupThermalObserver()
        log("Metal Cracker Engine initialized.")
        // Automatically trigger self-test on init
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.runSelfTest()
        }
    }

    // -------------------------------------------------------------------------
    // Metal Pipeline Setup
    // -------------------------------------------------------------------------
    private func setupMetal() {
        guard let defaultDevice = MTLCreateSystemDefaultDevice() else {
            state = .error
            log("ERROR: Metal is not supported on this device.")
            return
        }
        self.device = defaultDevice
        self.commandQueue = defaultDevice.makeCommandQueue()
        log("Metal Device: \(defaultDevice.name)")

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
            }
            if let suffix7Func = library.makeFunction(name: "sha1_crack_suffix7_b62") {
                self.suffix7PipelineState = try defaultDevice.makeComputePipelineState(function: suffix7Func)
                log("Specialized A17 Pro Suffix-7 pipeline compiled.")
            }
            log("Compute Pipelines compiled successfully.")
        } catch {
            state = .error
            log("ERROR compiling Metal shader: \(error.localizedDescription)")
        }
    }

    // -------------------------------------------------------------------------
    // Self-Test Verification
    // -------------------------------------------------------------------------
    public func runSelfTest() {
        guard let device = device, let commandQueue = commandQueue, let pipeline = generalPipelineState else {
            state = .selfTestFailed
            log("Self-test aborted: Metal pipeline not ready.")
            return
        }

        state = .selfTesting
        log("Running GPU Self-Test with known vector: sn2005 (H1)...")

        let config = CrackConfig.h1SelfTestPreset
        let result = executeSynchronousChunk(
            device: device,
            commandQueue: commandQueue,
            pipeline: pipeline,
            config: config,
            startIdx: 0,
            count: 10
        )

        if let candidate = result, candidate == "sn2005" {
            state = .selfTestPassed
            log("Self-Test PASSED! Correctly cracked: \(candidate)")
        } else {
            state = .selfTestFailed
            log("Self-Test FAILED! Expected 'sn2005', got \(result ?? "nil")")
        }
    }

    // -------------------------------------------------------------------------
    // Cracking Execution Loop
    // -------------------------------------------------------------------------
    public func startCracking(config: CrackConfig) {
        guard let device = device, let commandQueue = commandQueue else {
            log("ERROR: Metal device or queue unavailable.")
            return
        }

        guard !config.targetHashHexStrings.isEmpty else {
            log("ERROR: No target hashes provided.")
            return
        }

        // Select optimal pipeline: specialized suffix-7 for base62 target H2
        let useSpecializedSuffix7 = (config.suffixLength == 7 &&
                                    config.charset == "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" &&
                                    config.prefix == "sadiy" &&
                                    suffix7PipelineState != nil)

        let pipeline = useSpecializedSuffix7 ? suffix7PipelineState! : (generalPipelineState ?? suffix7PipelineState!)

        // Calculate total keyspace: base ^ suffixLength
        let base = UInt64(config.charset.count)
        var total: UInt64 = 1
        for _ in 0..<config.suffixLength {
            let (next, overflow) = total.multipliedReportingOverflow(by: base)
            if overflow {
                total = UInt64.max
                break
            }
            total = next
        }

        let finalTotal = total
        self.totalKeys = finalTotal
        self.keysTested = 0
        self.progressFraction = 0.0
        self.foundCandidate = nil
        self.isCancelled = false
        self.isPaused = false
        self.state = .running
        self.startTime = Date()
        self.lastSpeedCheckTime = Date()
        self.lastSpeedCheckKeys = 0

        log("Starting crack: prefix='\(config.prefix)', suffixLen=\(config.suffixLength), base=\(base)")
        log("Pipeline: \(useSpecializedSuffix7 ? "A17 Pro Suffix-7 Ultra-Fast" : "General Mask Engine")")
        log("Total keyspace: \(formatNumber(finalTotal)) candidates.")

        // Start UI Telemetry Timer
        startTelemetryTimer()

        // Launch background work on dedicated GCD queue
        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.runCrackingLoop(
                device: device,
                commandQueue: commandQueue,
                pipeline: pipeline,
                config: config,
                totalKeys: finalTotal
            )
        }
    }

    private func runCrackingLoop(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        pipeline: MTLComputePipelineState,
        config: CrackConfig,
        totalKeys: UInt64
    ) {
        let maxConcurrentBuffers = 4
        let semaphore = DispatchSemaphore(value: maxConcurrentBuffers)
        var currentStartIdx: UInt64 = 0
        let chunkSize = UInt64(config.chunkSize)

        // Allocate reusable double/triple/quad buffers
        var paramBuffers: [MTLBuffer] = []
        var resultBuffers: [MTLBuffer] = []
        for _ in 0..<maxConcurrentBuffers {
            if let pb = device.makeBuffer(length: 512, options: .storageModeShared),
               let rb = device.makeBuffer(length: 128, options: .storageModeShared) {
                paramBuffers.append(pb)
                resultBuffers.append(rb)
            }
        }

        guard paramBuffers.count == maxConcurrentBuffers else {
            DispatchQueue.main.async {
                self.state = .error
                self.log("Failed to allocate Metal buffers.")
            }
            return
        }

        var bufferIndex = 0
        var foundPlaintext: String? = nil

        while currentStartIdx < totalKeys && !isCancelled && foundPlaintext == nil {
            if isPaused {
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }

            // Adaptive thermal throttle if device is hot
            if config.autoThermalThrottle {
                let thermal = ProcessInfo.processInfo.thermalState
                if thermal == .serious {
                    Thread.sleep(forTimeInterval: 0.01)
                } else if thermal == .critical {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            semaphore.wait()

            let thisChunkSize = min(chunkSize, totalKeys - currentStartIdx)
            let pb = paramBuffers[bufferIndex]
            let rb = resultBuffers[bufferIndex]
            bufferIndex = (bufferIndex + 1) % maxConcurrentBuffers

            // Write parameters to buffer
            writeParams(
                to: pb,
                startIdx: currentStartIdx,
                chunkSize: UInt32(thisChunkSize),
                config: config
            )

            // Reset result buffer found_flag to 0
            rb.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 128)

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder() else {
                semaphore.signal()
                break
            }

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(pb, offset: 0, index: 0)
            encoder.setBuffer(rb, offset: 0, index: 1)

            let threadgroupWidth = min(512, Int(thisChunkSize))
            let threadsPerGroup = MTLSize(width: threadgroupWidth, height: 1, depth: 1)
            let totalThreads = MTLSize(width: Int(thisChunkSize), height: 1, depth: 1)
            encoder.dispatchThreads(totalThreads, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            let dispatchedCount = thisChunkSize
            commandBuffer.addCompletedHandler { [weak self] _ in
                defer { semaphore.signal() }
                guard let self = self else { return }

                // Check if result was found
                let foundFlag = rb.contents().load(as: UInt32.self)
                if foundFlag != 0 {
                    let candPtr = rb.contents().advanced(by: 12).bindMemory(to: CChar.self, capacity: 64)
                    let text = String(cString: candPtr)
                    foundPlaintext = text
                }

                DispatchQueue.main.async {
                    self.keysTested += dispatchedCount
                    if self.totalKeys > 0 {
                        self.progressFraction = Double(self.keysTested) / Double(self.totalKeys)
                    }
                }
            }

            commandBuffer.commit()
            currentStartIdx += thisChunkSize
        }

        // Wait for all in-flight command buffers to finish
        for _ in 0..<maxConcurrentBuffers {
            semaphore.wait()
        }

        // Final result handling
        let finalCandidate = foundPlaintext
        let wasCancelled = self.isCancelled

        DispatchQueue.main.async {
            if let found = finalCandidate {
                self.state = .found
                self.foundCandidate = found
                self.log("FOUND TARGET MATCH: \(found)")
            } else if wasCancelled {
                self.state = .idle
                self.log("Cracking stopped by user.")
            } else {
                self.state = .completed
                self.log("Cracking completed. Key space exhausted without match.")
            }
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

        let threadsPerGroup = MTLSize(width: min(256, Int(count)), height: 1, depth: 1)
        let totalThreads = MTLSize(width: Int(count), height: 1, depth: 1)
        encoder.dispatchThreads(totalThreads, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let foundFlag = rb.contents().load(as: UInt32.self)
        if foundFlag != 0 {
            let candPtr = rb.contents().advanced(by: 12).bindMemory(to: CChar.self, capacity: 64)
            return String(cString: candPtr)
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

        // struct CrackParams layout:
        // offset 0:   ulong chunk_start_idx (8 bytes)
        // offset 8:   uint chunk_size (4 bytes)
        // offset 12:  uint prefix_len (4 bytes)
        // offset 16:  uint suffix_len (4 bytes)
        // offset 20:  uint base (4 bytes)
        // offset 24:  uint target_count (4 bytes)
        // offset 28:  uint target_hashes[16 * 5] (320 bytes)
        // offset 348: uchar prefix[64] (64 bytes)
        // offset 412: uchar charset[64] (64 bytes)
        // offset 476: uint prefix_words[4] (16 bytes)

        ptr.storeBytes(of: startIdx, toByteOffset: 0, as: UInt64.self)
        ptr.storeBytes(of: chunkSize, toByteOffset: 8, as: UInt32.self)

        let prefixBytes = Array(config.prefix.utf8)
        let prefixLen = UInt32(prefixBytes.count)
        ptr.storeBytes(of: prefixLen, toByteOffset: 12, as: UInt32.self)

        let suffixLen = UInt32(config.suffixLength)
        ptr.storeBytes(of: suffixLen, toByteOffset: 16, as: UInt32.self)

        let charsetBytes = Array(config.charset.utf8)
        let base = UInt32(charsetBytes.count)
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

        // Compute pre-packed prefix words (e.g. for "sadiy": word0 = 'sadi', word1 = 'y' << 24)
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

    // -------------------------------------------------------------------------
    // User Controls
    // -------------------------------------------------------------------------
    public func pause() {
        isPaused = true
        state = .paused
        log("Paused.")
    }

    public func resume() {
        isPaused = false
        state = .running
        log("Resumed.")
    }

    public func stop() {
        isCancelled = true
        timer?.cancel()
        state = .idle
        log("Stopped.")
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
                let keysDelta = keysTested > lastSpeedCheckKeys ? keysTested - lastSpeedCheckKeys : 0
                let currentSpeedMKeys = Double(keysDelta) / interval / 1_000_000.0
                self.speedMKeysPerSec = currentSpeedMKeys
                self.speedGKeysPerSec = currentSpeedMKeys / 1000.0

                self.lastSpeedCheckTime = now
                self.lastSpeedCheckKeys = keysTested

                // Calculate ETA
                if currentSpeedMKeys > 0 && keysTested < totalKeys {
                    let remainingKeys = totalKeys - keysTested
                    let etaSeconds = Double(remainingKeys) / (currentSpeedMKeys * 1_000_000.0)
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
            thermalStateDescription = "Serious (Throttling)"
            thermalStateColor = "orange"
        case .critical:
            thermalStateDescription = "Critical (High Heat)"
            thermalStateColor = "red"
        @unknown default:
            thermalStateDescription = "Unknown"
            thermalStateColor = "gray"
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------
    public func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        DispatchQueue.main.async {
            self.logs.append("[\(timestamp)] \(message)")
            if self.logs.count > 100 {
                self.logs.removeFirst(self.logs.count - 100)
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
