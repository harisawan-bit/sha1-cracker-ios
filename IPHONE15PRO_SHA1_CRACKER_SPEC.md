# iPhone 15 Pro — Unsalted SHA-1 Mask Cracker (Metal-accelerated IPA)

> Handoff spec for an iOS build agent (Antigravity / similar). Goal: produce a
> sideloadable, unsigned IPA that cracks two unsalted SHA-1 hashes on an iPhone 15 Pro
> using the A17 Pro GPU via Metal, as FAST as possible. No jailbreak. Free 7-day Apple-ID signing.

---

## 1. Problem being solved (context)

We are cracking unsalted SHA-1 password hashes where only a **prefix** is known
(mask attack). Two targets:

| Label | Hash (SHA-1) | Known | Status |
|-------|--------------|-------|--------|
| H1 | `824dd5552ec2cc0ccab320198fb47b3b032f2d3f` | prefix `sn200` | **CRACKED = `sn2005`** |
| H2 | `fa4584ca1d5bd18dc467ef31f84a337f32329c40` | prefix `sadiy` | **NOT CRACKED** |

H2 was tested and failed on:
- `sadiy` + 1..6 chars `[a-z0-9]` brute (CPU, 2.24B keys) → NOT FOUND
- `sadiy` + 14.3M rockyou words (+36 suffix rules, both orders) → NOT FOUND
- `sadiy` + 14.3M rockyou words with leet/case/symbol rules → NOT FOUND
- `sadiy` + 7 chars `[a-zA-Z0-9]` brute on laptop i5-8365U → stopped at 11.1% (too slow)

**The last remaining high-value attack is the 7-char base62 brute (`[a-zA-Z0-9]`),
which is 3.52 trillion keys.** A laptop i5 does ~15 M/s → ~2.7 days. The A17 Pro
GPU via Metal should do ~1–3 G/s → **~30–60 min** (throttled maybe 2–4 hrs).

## 2. Architecture (fastest possible on A17 Pro)

```
┌─────────────────────────────────────────────────────────┐
│  SwiftUI / UIKit app (host)                               │
│   - UI: enter hash(es), prefix, charset, min/max len      │
│   - Splits key-space into chunks                          │
│   - Dispatches chunks to Metal compute pipeline           │
│   - Shows live speed + progress + FOUND result            │
└───────────────┬───────────────────────────────────────────┘
                │ MTLComputeCommandEncoder
┌───────────────▼───────────────────────────────────────────┐
│  Metal Compute Shader (sha1_mask.metal)                   │
│   - Each GPU thread = ONE candidate                      │
│   - Reconstructs candidate = prefix + base62(idx)        │
│   - Computes SHA-1 (single block, len<=55)               │
│   - Compares 5×uint32 to target                          │
│   - If match: atomic write match to output buffer        │
└───────────────────────────────────────────────────────────┘
```

**Why GPU not CPU:** A17 Pro has 6 GPU cores. SHA-1 has no Apple "crypto"
instruction on GPU (those are CPU ARMv8.2 `SHA1C` only), BUT a hand-written
Metal SHA-1 kernel runs >1000× the CPU single-thread and ~100× the whole laptop.
GPU parallelism is the win, not a crypto instruction.

## 3. The Metal SHA-1 kernel (core speed)

Key performance points:
- Process candidates in **batches of N threads per kernel launch** (e.g. 256k–1M
  threads), loop over chunks on the CPU side.
- SHA-1 single-block path only (all candidates < 55 bytes: prefix ≤ ~48 chars +
  7 suffix). Precompute the message-schedule loop fully unrolled.
- Pack the target hash into a `constant` buffer (5× uint32).
- Use `simdgroup` / no atomics in the hot path; only the rare matching thread does
  an atomic store to a 1-slot result buffer + a flag.
- Launch with `threadsPerThreadgroup` = 256 or 1024 (tune), grid = total keys in
  chunk.
- Prefer `MTLStorageModeShared` for the tiny result buffer; staging buffers reused.

Reference single-block SHA-1 in the kernel (pseudo, unrolled):

```
constant uint4 TARGET[5];          // target hash words
constant char CHARSET[62];         // a-zA-Z0-9
constant char PREFIX[64]; uint PREFIX_LEN;
constant uint MIN_IDX; uint MAX_IDX; // chunk bounds (base62 index space)

kernel void crack(uint gid [[thread_position_in_grid]]) {
    uint idx = MIN_IDX + gid;
    if (idx >= MAX_IDX) return;
    // build candidate = PREFIX + base62(idx)  (7 suffix chars)
    char cand[64]; int cl = PREFIX_LEN;
    memcpy(cand, PREFIX, cl);
    uint v = idx;
    for (int i=0;i<7;i++){ cand[cl+6-i] = CHARSET[v%62]; v/=62; }
    cl += 7;
    // SHA-1 single block over cand[0..cl)
    uint w[16]; /* bytes -> big-endian words, pad 0x80, len bits in w[14..15] */
    ... unrolled compression 80 rounds ...
    uint a0..e0 = init; /* 5 rounds functions */
    // compare
    if (a0==TARGET[0]&&b0==TARGET[1]&&c0==TARGET[2]&&d0==TARGET[3]&&e0==TARGET[4]) {
        result.found = 1;
        // write candidate bytes to result buffer
        atomic_store_explicit(&done, 1, memory_order_relaxed);
    }
}
```

(Tip: the host can pre-encode the prefix block bytes so the kernel only fills the
7 suffix bytes — saves ALU.)

## 4. Charset / chunking strategy

- Charset = `abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789` (62).
- Suffix length = 7 (start with this; expose UI to change).
- Total keys = 62^7 = 3,521,614,606,208.
- Host splits into chunks of, say, 4,194,304 (2^22) keys per dispatch, loops until
  found or exhausted. Show ETA from measured speed.
- Optional: also expose a **dictionary mode** (load a wordlist, same kernel with
  variable-length candidates) — but GPU brute is the priority.

## 5. GitHub setup (using the user's existing auth)

The user (`harisawan-bit`) is already authenticated locally via `gh` on their
machine. To create the repo and ship source:

```bash
# on the user's machine, gh is already logged in as harisawan-bit
gh repo create sha1-cracker-ios --public --description "Metal-accelerated SHA-1 mask cracker for iPhone 15 Pro"
git clone https://github.com/harisawan-bit/sha1-cracker-ios
# copy the Xcode project + this spec in, then:
git add -A && git commit -m "Initial: Metal SHA-1 mask cracker for A17 Pro" && git push -u origin main
```

**CI build (GitHub Actions, no Mac needed for the *repo*; Mac runner to build IPA):**
Add `.github/workflows/build-ios.yml` using `macos-14` + `actions/checkout` +
`xcodebuild archive` + `xcodebuild -exportArchive` with an **ad-hoc / free
provisioning** export (no paid cert). The unsigned IPA is then an artifact.

```
# build-ios.yml (key steps)
- uses: actions/checkout@v4
- uses: maxim-lobanov/setup-xcode@v1  (Xcode 15)
- run: xcodebuild -scheme sha1-cracker-ios -archivePath build/app.xcarchive archive
- run: xcodebuild -exportArchive -archivePath build/app.xcarchive -exportPath build -exportOptionsPlist ExportOptions.plist
# ExportOptions.plist: method = "development", signin... free team
- uses: actions/upload-artifact@v4
  with: { name: sha1-cracker-ios.ipa, path: build/*.ipa }
```

User sideloads the IPA with **3uTools** (their existing flow) using a free Apple ID.

## 6. Project layout (Xcode, Swift + Metal)

```
sha1-cracker-ios/
├── sha1-cracker-ios.xcodeproj
├── sha1-cracker-ios/
│   ├── AppDelegate.swift / ContentView.swift   (SwiftUI UI)
│   ├── Cracker.swift                           (Metal setup, dispatch loop)
│   ├── sha1_mask.metal                         (the kernel above)
│   └── Info.plist
├── ExportOptions.plist
└── .github/workflows/build-ios.yml
```

API surface the agent should expose in the UI:
- Target hash(es) text field (comma/space separated, multiple OK).
- Prefix input.
- Charset selector (a-z0-9 / a-zA-Z0-9 / custom).
- Min/max suffix length.
- Start / Stop buttons, live MKeys/s, progress %, ETA, result box.

## 7. Performance targets (acceptance)

| Metric | Target |
|--------|--------|
| Sustained GPU speed | ≥ 1 G candidate/s (peak), ≥ 300 M/s sustained after thermal throttle |
| Full 62^7 space | ≤ 60 min peak / ≤ 4 hrs throttled |
| Correctness | Must reproduce `sn2005` for H1 as a built-in self-test on launch |
| Battery/heat | Show thermal state; throttle chunk size if device gets hot |

**Self-test requirement:** on app launch, kernel must crack a known vector
(`sn200` + 7-char brute includes `sn2005` → `824dd5552ec2cc0ccab320198fb47b3b032f2d3f`)
to prove the pipeline is correct before real work.

## 8. Out-of-scope / notes

- No network exfiltration; everything is local. This is for cracking hashes the
  user is authorized to test (own accounts / authorized targets).
- No Apple crypto-instruction dependency on GPU; pure Metal SHA-1 compute.
- If a word-based attack is later wanted, add a dictionary kernel variant.
- The `sadiy……` hash may still not crack if it is >7 random chars or contains
  symbols — extend charset/length in UI if needed.

## 9. Exact deliverable asked of the build agent

1. Xcode project that builds for iPhone 15 Pro (iOS 17).
2. Metal kernel implementing §3 at the stated speed.
3. SwiftUI UI per §6.
4. GitHub repo under `harisawan-bit/sha1-cracker-ios` with the Actions workflow.
5. Produces a sideloadable IPA via the workflow artifact (3uTools path for user).
6. Built-in self-test (§7) proving correctness before use.
