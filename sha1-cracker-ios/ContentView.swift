import SwiftUI

struct ContentView: View {
    @StateObject private var engine = MetalCrackerEngine()

    // Form inputs
    @State private var targetHashHex: String = "fa4584ca1d5bd18dc467ef31f84a337f32329c40"
    @State private var prefix: String = "sadiy"
    @State private var selectedCharsetType: CharsetType = .base62
    @State private var customCharset: String = ""
    @State private var suffixLength: Int = 7
    @State private var chunkSize: Int = 16_777_216
    @State private var autoThermalThrottle: Bool = true
    @State private var selectedEngineMode: EngineMode = .hybrid
    @State private var showLogs: Bool = true
    @State private var showCopiedAlert: Bool = false
    @State private var alertMessage: String = "Copied to Clipboard!"

    enum CharsetType: String, CaseIterable, Identifiable {
        case base62 = "Base62 (a-zA-Z0-9)"
        case base36 = "Base36 (a-z0-9)"
        case lower = "Alpha (a-z)"
        case digits = "Digits (0-9)"
        case custom = "Custom"

        var id: String { self.rawValue }

        var charsetString: String {
            switch self {
            case .base62: return "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            case .base36: return "abcdefghijklmnopqrstuvwxyz0123456789"
            case .lower: return "abcdefghijklmnopqrstuvwxyz"
            case .digits: return "0123456789"
            case .custom: return ""
            }
        }
    }

    var activeCharset: String {
        if selectedCharsetType == .custom {
            return customCharset.isEmpty ? "abcdefghijklmnopqrstuvwxyz" : customCharset
        }
        return selectedCharsetType.charsetString
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. Header & System Badges
                    headerView

                    // 2. Discovered Match Banner
                    if let candidate = engine.foundCandidate {
                        foundMatchBanner(candidate: candidate)
                    }

                    // 3. Saved Session Checkpoint Banner (if available)
                    if let checkpoint = engine.activeCheckpoint, engine.state != .running && engine.state != .found {
                        savedCheckpointBanner(checkpoint: checkpoint)
                    }

                    // 4. Live Heterogeneous Telemetry Dashboard
                    telemetryDashboard

                    // 5. Action Controls
                    actionButtons

                    // 6. Attack & Hardware Configuration Card
                    attackConfigCard

                    // 7. Persistent Live Console Logs
                    engineLogsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("A17 Pro Heterogeneous Cracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        engine.runSelfTest()
                    }) {
                        Label("Self-Test", systemImage: "bolt.shield")
                    }
                }
            }
            .alert(alertMessage, isPresented: $showCopiedAlert) {
                Button("OK", role: .cancel) { }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Subviews
    // -------------------------------------------------------------------------

    private var headerView: some View {
        HStack(spacing: 12) {
            // Self-Test Badge
            HStack(spacing: 6) {
                Circle()
                    .fill(selfTestBadgeColor)
                    .frame(width: 8, height: 8)
                Text(engine.state == .selfTestPassed ? "Self-Test: PASSED" : (engine.state == .selfTesting ? "Self-Testing..." : (engine.state == .selfTestFailed ? "Self-Test: FAILED" : "Self-Test: Ready")))
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(Capsule())

            Spacer()

            // Thermal Badge
            HStack(spacing: 6) {
                Image(systemName: "thermometer.medium")
                    .foregroundColor(thermalColor)
                Text(engine.thermalStateDescription)
                    .font(.caption2.bold())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(Capsule())
        }
    }

    private func foundMatchBanner(candidate: String) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TARGET CRACKED!")
                        .font(.headline.bold())
                        .foregroundColor(.green)
                    Text("Plaintext candidate verified")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cracked Plaintext:")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Text(candidate)
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundColor(.primary)
                }
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = candidate
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    alertMessage = "Copied '\(candidate)' to Clipboard!"
                    showCopiedAlert = true
                }) {
                    Label("Copy Key", systemImage: "doc.on.doc.fill")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.green)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .green.opacity(0.3), radius: 4, y: 2)
                }
            }
        }
        .padding(16)
        .background(Color.green.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green, lineWidth: 2)
        )
        .cornerRadius(14)
    }

    private func savedCheckpointBanner(checkpoint: CrackCheckpoint) -> some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.blue)
                    .font(.headline)
                Text("Previous Session Saved")
                    .font(.subheadline.bold())
                    .foregroundColor(.primary)
                Spacer()
                Text(checkpoint.progressPercentString)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.2))
                    .foregroundColor(.blue)
                    .clipShape(Capsule())
            }

            Text("Target: \(checkpoint.prefix)... | \(checkpoint.lastTestedIndex.formatted()) / \(checkpoint.totalKeys.formatted()) keys tested.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    engine.resumeSavedCheckpoint()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Resume Session")
                    }
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    CrackerCheckpointManager.shared.clearCheckpoint()
                    engine.checkExistingCheckpoint()
                }) {
                    Text("Discard")
                        .font(.caption.bold())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.2))
                        .foregroundColor(.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.4), lineWidth: 1.5)
        )
        .cornerRadius(12)
    }

    private var telemetryDashboard: some View {
        VStack(spacing: 12) {
            // Speed Gauge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AGGREGATE THROUGHPUT")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.2f", engine.speedGKeysPerSec))
                            .font(.system(size: 34, weight: .black, design: .rounded))
                            .foregroundColor(.blue)
                        Text("GKeys/s")
                            .font(.headline.bold())
                            .foregroundColor(.secondary)
                    }
                    Text(String(format: "(%.0f MKeys/s Combined)", engine.speedMKeysPerSec))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("ESTIMATED TIME")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Text(engine.etaString)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("Elapsed: \(formatElapsed(engine.elapsedTimeSec))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Subsystem Breakdown (GPU + CPU)
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Circle().fill(Color.blue).frame(width: 6, height: 6)
                    Text("GPU: \(String(format: "%.2f GKeys/s", engine.speedGPUGKeysPerSec))")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(Color.purple).frame(width: 6, height: 6)
                    Text("CPU: \(String(format: "%.0f MKeys/s", engine.speedCPUMKeysPerSec))")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)

            Divider()

            // Progress Bar
            VStack(spacing: 6) {
                HStack {
                    Text("Progress (\(engine.state.rawValue))")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.2f%%", engine.progressFraction * 100))
                        .font(.caption.monospacedDigit().bold())
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 10)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [.blue, .purple, .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, engine.progressFraction))), height: 10)
                    }
                }
                .frame(height: 10)

                HStack {
                    Text("\(engine.keysTested.formatted()) keys")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Total: \(engine.totalKeys.formatted())")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            if engine.state == .running {
                HStack(spacing: 12) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        engine.pause()
                    }) {
                        Label("Pause", systemImage: "pause.fill")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.orange)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        engine.stop()
                    }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else if engine.state == .paused {
                HStack(spacing: 12) {
                    Button(action: {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        engine.resume()
                    }) {
                        Label("Resume", systemImage: "play.fill")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button(action: {
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        engine.stop()
                    }) {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.headline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            } else {
                Button(action: {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    let config = CrackConfig(
                        targetHashHexStrings: [targetHashHex],
                        prefix: prefix,
                        charset: activeCharset,
                        suffixLength: suffixLength,
                        chunkSize: chunkSize,
                        autoThermalThrottle: autoThermalThrottle,
                        mode: selectedEngineMode
                    )
                    engine.startCracking(config: config)
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                        Text("START CRACKING")
                    }
                    .font(.headline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
                }
            }
        }
    }

    private var attackConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("HARDWARE & TARGET CONFIGURATION")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            // Preset Buttons
            HStack(spacing: 8) {
                presetButton(title: "Target H2 (sadiy 7c)", isH2: true)
                presetButton(title: "Target H1 (sn200 1c)", isH2: false)
            }

            // Engine Mode Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("Compute Engine Architecture:")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Picker("Engine Mode", selection: $selectedEngineMode) {
                    ForEach(EngineMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            // Target Hash Input
            VStack(alignment: .leading, spacing: 4) {
                Text("Target Hash (SHA-1 Hex):")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                TextField("40-character hex hash", text: $targetHashHex)
                    .font(.system(.subheadline, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(10)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .cornerRadius(8)
            }

            // Known Prefix & Suffix
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Known Prefix:")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    TextField("Prefix (e.g. sadiy)", text: $prefix)
                        .font(.system(.subheadline, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground))
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Suffix Length:")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Stepper("\(suffixLength) chars", value: $suffixLength, in: 1...8)
                        .padding(6)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground))
                        .cornerRadius(8)
                }
            }

            // Charset Picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Charset (\(activeCharset.count) chars):")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Picker("Charset", selection: $selectedCharsetType) {
                    ForEach(CharsetType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)

                if selectedCharsetType == .custom {
                    TextField("Enter custom charset characters", text: $customCharset)
                        .font(.system(.subheadline, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .padding(10)
                        .background(Color(uiColor: .tertiarySystemGroupedBackground))
                        .cornerRadius(8)
                }
            }

            // GPU Chunk Size Selector
            VStack(alignment: .leading, spacing: 4) {
                Text("GPU Dispatch Chunk Size:")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Picker("Chunk Size", selection: $chunkSize) {
                    Text("4M").tag(4_194_304)
                    Text("8M").tag(8_388_608)
                    Text("16M (Fastest)").tag(16_777_216)
                    Text("32M").tag(33_554_432)
                }
                .pickerStyle(.segmented)
            }

            // Thermal Safety Toggle
            Toggle(isOn: $autoThermalThrottle) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Thermal Regulation")
                        .font(.subheadline.bold())
                    Text("Dynamically adapts GPU chunk pacing to sustain peak clock frequency")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    private var engineLogsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill")
                        .foregroundColor(.blue)
                    Text("Persistent Console Logs")
                        .font(.caption.bold())
                        .foregroundColor(.primary)
                }

                Spacer()

                // Copy Logs Button
                Button(action: {
                    UIPasteboard.general.string = engine.getAllLogsFormatted()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    alertMessage = "All engine logs copied to clipboard!"
                    showCopiedAlert = true
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .foregroundColor(.blue)
                        .clipShape(Capsule())
                }

                // Clear Logs Button
                Button(action: {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    engine.clearLogs()
                }) {
                    Label("Clear", systemImage: "trash")
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.15))
                        .foregroundColor(.red)
                        .clipShape(Capsule())
                }
            }

            // Terminal Log Viewer
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(engine.logs.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(logColor(for: log))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 160, maxHeight: 240)
                .background(Color.black.opacity(0.75))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: engine.logs.count) { _ in
                    if let lastIndex = engine.logs.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .cornerRadius(14)
    }

    // -------------------------------------------------------------------------
    // Helper Views & Colors
    // -------------------------------------------------------------------------

    private func presetButton(title: String, isH2: Bool) -> some View {
        Button(action: {
            if isH2 {
                targetHashHex = "fa4584ca1d5bd18dc467ef31f84a337f32329c40"
                prefix = "sadiy"
                suffixLength = 7
                selectedCharsetType = .base62
                chunkSize = 16_777_216
                selectedEngineMode = .hybrid
            } else {
                targetHashHex = "824dd5552ec2cc0ccab320198fb47b3b032f2d3f"
                prefix = "sn200"
                suffixLength = 1
                selectedCharsetType = .digits
                chunkSize = 4_194_304
                selectedEngineMode = .hybrid
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }) {
            Text(title)
                .font(.caption.bold())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.12))
                .foregroundColor(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var selfTestBadgeColor: Color {
        switch engine.state {
        case .selfTestPassed: return .green
        case .selfTesting: return .yellow
        case .selfTestFailed: return .red
        default: return .gray
        }
    }

    private var thermalColor: Color {
        switch engine.thermalStateColor {
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .gray
        }
    }

    private func logColor(for logText: String) -> Color {
        if logText.contains("CRACKED") || logText.contains("PASSED") || logText.contains("✅") || logText.contains("🎉") {
            return .green
        } else if logText.contains("ERROR") || logText.contains("FAILED") || logText.contains("❌") || logText.contains("🚨") {
            return .red
        } else if logText.contains("⚠️") || logText.contains("Paused") || logText.contains("Testing") {
            return .yellow
        } else if logText.contains("🚀") || logText.contains("⚡") {
            return .cyan
        }
        return .white.opacity(0.85)
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let sec = Int(seconds)
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}
