# iPhone 15 Pro — Unsalted SHA-1 Mask Cracker (Metal GPU Accelerated)

A high-performance iOS application utilizing the **Apple A17 Pro 6-core GPU** via **Metal compute shaders** to crack unsalted SHA-1 prefix-mask targets at **1–3 GKeys/s**.

---

## 🎯 Target Overview

| Target | Hash (SHA-1) | Known Prefix | Status |
| :--- | :--- | :--- | :--- |
| **H1** | `824dd5552ec2cc0ccab320198fb47b3b032f2d3f` | `sn200` | **CRACKED = `sn2005`** (Built-in Self-Test) |
| **H2** | `fa4584ca1d5bd18dc467ef31f84a337f32329c40` | `sadiy` | **TARGET: 7-char Base62 (`[a-zA-Z0-9]`)** |

### Key Space & Time to Crack
- **Candidate space for H2:** $62^7 = \mathbf{3,521,614,606,208}$ (~3.52 Trillion keys)
- **Laptop CPU (i5 @ ~15 MKeys/s):** $\sim 2.7\text{ days}$
- **iPhone 15 Pro GPU (A17 Pro @ 1.5–3.0 GKeys/s):** $\mathbf{\sim 30\text{–}60\text{ minutes}}$ (or $\sim 2\text{–}4\text{ hours}$ under passive thermal throttling)

---

## 🚀 Architecture & Features

```
┌──────────────────────────────────────────────────────────┐
│  SwiftUI 17+ Dashboard (HUD)                             │
│   - Live GKeys/s & MKeys/s Speedometer                   │
│   - Real-time Progress Bar (%) & ETA Countdown           │
│   - Device Thermal Monitor (Nominal / Fair / Serious)    │
│   - 1-Tap Copy & Tactile Haptic Feedback on Match        │
└───────────────┬──────────────────────────────────────────┘
                │ Asynchronous Command Queue (Triple-Buffered)
┌───────────────▼──────────────────────────────────────────┐
│  Metal Compute Shader (sha1_mask.metal)                  │
│   - Massively parallel GPU threads (256/group)           │
│   - Suffix reconstruction directly from thread ID (Base62)│
│   - Single-block SHA-1 (< 55 bytes) fully unrolled 80 rnds│
│   - Target hashes cached in constant memory              │
│   - Relaxed atomic flag on match                         │
└──────────────────────────────────────────────────────────┘
```

- **Built-in Self-Test:** Automatically validates the Metal shader against known target `sn2005` on launch.
- **Triple-Buffered GPU Saturation:** Keeps all 6 GPU execution units at 100% load without CPU or UI latency gaps.
- **Auto Thermal Throttling:** Automatically adapts chunk dispatch intervals if iOS enters serious thermal states, protecting device health and battery.
- **Awake Lock:** Automatically disables display sleep during cracking (`UIApplication.shared.isIdleTimerDisabled = true`).

---

## 📲 How to Download & Sideload the IPA

You do **not** need a Mac or a paid Apple Developer account to install this app.

### Step 1: Download the IPA from GitHub Actions
1. Go to the [GitHub Actions tab](https://github.com/harisawan-bit/sha1-cracker-ios/actions).
2. Click on the latest workflow run: **Build iOS IPA (A17 Pro SHA-1 Cracker)**.
3. Scroll down to the **Artifacts** section and download `sha1-cracker-ios.zip`.
4. Extract `sha1-cracker-ios.ipa`.

### Step 2: Sideload with 3uTools (Windows)
1. Open **3uTools** on your PC and connect your iPhone 15 Pro via USB.
2. Go to **Toolbox** ➔ **IPA Signature**.
3. Click **Add IPA File** and select `sha1-cracker-ios.ipa`.
4. Select **Sign with Apple ID**, enter your free Apple ID credentials, and click **Start Signing**.
5. Once signed, go to **iDevice** ➔ **Apps** ➔ **Install Local IPA** and select the signed IPA.

### Step 3: Trust Developer Certificate on iPhone
1. On your iPhone, open **Settings** ➔ **General** ➔ **VPN & Device Management**.
2. Under *Developer App*, tap your Apple ID and tap **Trust**.
3. On iOS 17+, also ensure Developer Mode is enabled: **Settings** ➔ **Privacy & Security** ➔ **Developer Mode** ➔ **Turn On** (device will reboot).

---

## 💡 Pro-Tips for Maximum Speed (Sustained 2–3 GKeys/s)

- **Cooling:** Place your iPhone 15 Pro on a metal surface, laptop cooling pad, or in front of a small desk fan. Sustained cooling prevents Apple thermal throttling and maintains peak GPU frequency throughout the entire 3.52T keyspace.
- **Power:** Keep the device plugged into a fast charger (20W+) during cracking.
