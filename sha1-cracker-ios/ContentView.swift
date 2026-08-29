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
    @State private var showLogs: Bool = false
    @State private var showCopiedAlert: Bool = false

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

                    // 2. Found Match Banner (if discovered)
                    if let candidate = engine.foundCandidate {
                        foundMatchBanner(candidate: candidate)
                    }

                    // 3. Live Telemetry Dashboard
                    telemetryDashboard

                    // 4. Attack Configuration Card
                    attackConfigCard

                    // 5. Action Controls
                    actionButtons

                    // 6. Live Engine Logs
                    engineLogsSection
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("A17 Pro SHA-1 Cracker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { engine.runSelfTest() }) {
                        Label("Self-Test", systemImage: "bolt.shield")
                    }
                }
            }
            .alert("Copied to Clipboard!", isPresented: $showCopiedAlert) {
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
                Text(engine.state == .selfTestPassed ? "Self-Test: PASSED" : (engine.state == .selfTesting ? "Self-Testing..." : "Self-Test: Ready"))
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
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                Text("MATCH CRACKED!")
                    .font(.headline.bold())
                    .foregroundColor(.green)
                Spacer()
            }

            HStack {
                Text(candidate)
                    .font(.system(.title3, design: .monospaced).bold())
                    .foregroundColor(.primary)
                Spacer()
                Button(action: {
                    UIPasteboard.general.string = candidate
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    showCopiedAlert = true
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.15))
                        .foregroundColor(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(16)
        .background(Color.green.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.green.opacity(0.5), lineWidth: 2)
        )
        .cornerRadius(14)
    }

    private var telemetryDashboard: some View {
        VStack(spacing: 12) {
            // Speed Gauge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("GPU THROUGHPUT")
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
                    Text(String(format: "(%.0f MKeys/s)", engine.speedMKeysPerSec))
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

            Divider()

            // Progress Bar
            VStack(spacing: 6) {
                HStack {
                    Text("Progress")
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
                            .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
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

    private var attackConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("TARGET SPECIFICATION")
                .font(.caption.bold())
                .foregroundColor(.secondary)

            // Preset Buttons
            HStack(spacing: 8) {
                presetButton(title: "Target H2 (sadiy 7c)", isH2: true)
                presetButton(title: "Target H1 (sn200)", isH2: false)
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

            // Known Prefix
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
                    Stepper("\(suffixLength) chars", value: $suffixLength, in: 1...12)
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
                    Text("Auto Thermal Throttle")
                        .font(.subheadline.bold())
                    Text("Regulate dispatch rate when device warms up")
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
                        autoThermalThrottle: autoThermalThrottle
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

    private var engineLogsSection: some View {
        DisclosureGroup(isExpanded: $showLogs) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(engine.logs, id: \.self) { log in
                    Text(log)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .cornerRadius(8)
        } label: {
            HStack {
                Text("Engine Execution Logs")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(engine.logs.count)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.gray.opacity(0.2))
                    .clipShape(Capsule())
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
            } else {
                targetHashHex = "824dd5552ec2cc0ccab320198fb47b3b032f2d3f"
                prefix = "sn200"
                suffixLength = 1
                selectedCharsetType = .digits
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

    private func formatElapsed(_ seconds: Double) -> String {
        let sec = Int(seconds)
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }
}
