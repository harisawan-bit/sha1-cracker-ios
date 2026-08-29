#include <metal_stdlib>
using namespace metal;

// -----------------------------------------------------------------------------
// Data structures exchanged between Swift (Host) and Metal (GPU)
// -----------------------------------------------------------------------------

struct CrackParams {
    ulong chunk_start_idx;      // 64-bit starting index for this dispatch chunk
    uint chunk_size;            // Number of candidate keys in this dispatch
    uint prefix_len;            // Length of the known prefix (0..48)
    uint suffix_len;            // Length of the suffix to brute force (1..15)
    uint base;                  // Charset base (e.g. 62 for [a-zA-Z0-9])
    uint target_count;          // Number of target hashes (up to 16)
    uint target_hashes[16 * 5]; // 5x uint32 big-endian words per target hash
    uchar prefix[64];           // Known prefix bytes
    uchar charset[64];          // Charset lookup table
    uint prefix_words[4];       // Pre-packed prefix big-endian words
};

struct CrackResult {
    atomic_uint found_flag;     // 1 if a match was discovered, 0 otherwise
    uint matched_target_index;  // Index of the matching target hash (0..target_count-1)
    uint matched_length;        // Total candidate length (prefix_len + suffix_len)
    uchar matched_candidate[64];// Plaintext matching candidate string (null terminated)
};

// -----------------------------------------------------------------------------
// Unrolled SHA-1 Round Functions & Message Schedule Macros
// -----------------------------------------------------------------------------

#define SHA1_ROL(x, n) metal::rotate((uint)(x), (uint)(n))

// Non-linear round functions
#define SHA1_F0(b, c, d) ((d) ^ ((b) & ((c) ^ (d))))
#define SHA1_F1(b, c, d) ((b) ^ (c) ^ (d))
#define SHA1_F2(b, c, d) (((b) & (c)) | ((d) & ((b) | (c))))
#define SHA1_F3(b, c, d) ((b) ^ (c) ^ (d))

#define SHA1_ROUND_0_19(a, b, c, d, e, w) \
    e += SHA1_ROL(a, 5) + SHA1_F0(b, c, d) + 0x5A827999u + (w); \
    b = SHA1_ROL(b, 30);

#define SHA1_ROUND_20_39(a, b, c, d, e, w) \
    e += SHA1_ROL(a, 5) + SHA1_F1(b, c, d) + 0x6ED9EBA1u + (w); \
    b = SHA1_ROL(b, 30);

#define SHA1_ROUND_40_59(a, b, c, d, e, w) \
    e += SHA1_ROL(a, 5) + SHA1_F2(b, c, d) + 0x8F1BBCDCu + (w); \
    b = SHA1_ROL(b, 30);

#define SHA1_ROUND_60_79(a, b, c, d, e, w) \
    e += SHA1_ROL(a, 5) + SHA1_F3(b, c, d) + 0xCA62C1D6u + (w); \
    b = SHA1_ROL(b, 30);

#define SHA1_EXPAND(w, t) \
    w[(t) & 15] = SHA1_ROL(w[((t) - 3) & 15] ^ w[((t) - 8) & 15] ^ w[((t) - 14) & 15] ^ w[((t) - 16) & 15], 1)

constant uchar B62_LUT[64] = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

// -----------------------------------------------------------------------------
// 1. ULTRA-FAST SPECIALIZED KERNEL FOR SUFFIX LENGTH 7 (Target H2: sadiy + 7c)
// -----------------------------------------------------------------------------

kernel void sha1_crack_suffix7_b62(
    constant CrackParams &params [[buffer(0)]],
    device CrackResult &result   [[buffer(1)]],
    uint gid                     [[thread_position_in_grid]])
{
    if (gid >= params.chunk_size) return;
    if (atomic_load_explicit(&result.found_flag, memory_order_relaxed) != 0) return;

    ulong idx = params.chunk_start_idx + (ulong)gid;

    // Fast 32-bit split Base62 decoding:
    // 62^5 = 916132832 fits in uint32
    uint hi = (uint)(idx / 916132832ul);
    uint lo = (uint)(idx % 916132832ul);

    uchar s0 = B62_LUT[hi / 62u];
    uchar s1 = B62_LUT[hi % 62u];

    uchar s6 = B62_LUT[lo % 62u]; lo /= 62u;
    uchar s5 = B62_LUT[lo % 62u]; lo /= 62u;
    uchar s4 = B62_LUT[lo % 62u]; lo /= 62u;
    uchar s3 = B62_LUT[lo % 62u]; lo /= 62u;
    uchar s2 = B62_LUT[lo];

    // For prefix "sadiy" (5 bytes) + 7 suffix bytes = 12 bytes
    // Word 0: 's','a','d','i' -> 0x73616469
    // Word 1: 'y', s0,  s1,  s2
    // Word 2:  s3,  s4,  s5,  s6
    // Word 3:  0x80000000
    // Word 15: 12 * 8 = 96
    uint w[16];
    w[0] = params.prefix_words[0]; // 0x73616469 for "sadi"
    w[1] = params.prefix_words[1] | (((uint)s0) << 16) | (((uint)s1) << 8) | ((uint)s2); // "y" + s0..s2
    w[2] = (((uint)s3) << 24) | (((uint)s4) << 16) | (((uint)s5) << 8) | ((uint)s6); // s3..s6
    w[3] = 0x80000000u;
    w[4] = 0; w[5] = 0; w[6] = 0; w[7] = 0;
    w[8] = 0; w[9] = 0; w[10] = 0; w[11] = 0;
    w[12] = 0; w[13] = 0; w[14] = 0;
    w[15] = 96u; // 12 bytes * 8 bits

    // Initial SHA-1 state
    uint a = 0x67452301u;
    uint b = 0xEFCDAB89u;
    uint c = 0x98BADCFEu;
    uint d = 0x10325476u;
    uint e = 0xC3D2E1F0u;

    // Rounds 0 - 15
    SHA1_ROUND_0_19(a, b, c, d, e, w[0]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[1]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[2]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[3]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[4]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[5]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[6]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[7]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[8]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[9]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[10]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[11]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[12]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[13]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[14]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[15]);

    // Rounds 16 - 19
    SHA1_EXPAND(w, 16); SHA1_ROUND_0_19(e, a, b, c, d, w[0]);
    SHA1_EXPAND(w, 17); SHA1_ROUND_0_19(d, e, a, b, c, w[1]);
    SHA1_EXPAND(w, 18); SHA1_ROUND_0_19(c, d, e, a, b, w[2]);
    SHA1_EXPAND(w, 19); SHA1_ROUND_0_19(b, c, d, e, a, w[3]);

    // Rounds 20 - 39
    SHA1_EXPAND(w, 20); SHA1_ROUND_20_39(a, b, c, d, e, w[4]);
    SHA1_EXPAND(w, 21); SHA1_ROUND_20_39(e, a, b, c, d, w[5]);
    SHA1_EXPAND(w, 22); SHA1_ROUND_20_39(d, e, a, b, c, w[6]);
    SHA1_EXPAND(w, 23); SHA1_ROUND_20_39(c, d, e, a, b, w[7]);
    SHA1_EXPAND(w, 24); SHA1_ROUND_20_39(b, c, d, e, a, w[8]);
    SHA1_EXPAND(w, 25); SHA1_ROUND_20_39(a, b, c, d, e, w[9]);
    SHA1_EXPAND(w, 26); SHA1_ROUND_20_39(e, a, b, c, d, w[10]);
    SHA1_EXPAND(w, 27); SHA1_ROUND_20_39(d, e, a, b, c, w[11]);
    SHA1_EXPAND(w, 28); SHA1_ROUND_20_39(c, d, e, a, b, w[12]);
    SHA1_EXPAND(w, 29); SHA1_ROUND_20_39(b, c, d, e, a, w[13]);
    SHA1_EXPAND(w, 30); SHA1_ROUND_20_39(a, b, c, d, e, w[14]);
    SHA1_EXPAND(w, 31); SHA1_ROUND_20_39(e, a, b, c, d, w[15]);
    SHA1_EXPAND(w, 32); SHA1_ROUND_20_39(d, e, a, b, c, w[0]);
    SHA1_EXPAND(w, 33); SHA1_ROUND_20_39(c, d, e, a, b, w[1]);
    SHA1_EXPAND(w, 34); SHA1_ROUND_20_39(b, c, d, e, a, w[2]);
    SHA1_EXPAND(w, 35); SHA1_ROUND_20_39(a, b, c, d, e, w[3]);
    SHA1_EXPAND(w, 36); SHA1_ROUND_20_39(e, a, b, c, d, w[4]);
    SHA1_EXPAND(w, 37); SHA1_ROUND_20_39(d, e, a, b, c, w[5]);
    SHA1_EXPAND(w, 38); SHA1_ROUND_20_39(c, d, e, a, b, w[6]);
    SHA1_EXPAND(w, 39); SHA1_ROUND_20_39(b, c, d, e, a, w[7]);

    // Rounds 40 - 59
    SHA1_EXPAND(w, 40); SHA1_ROUND_40_59(a, b, c, d, e, w[8]);
    SHA1_EXPAND(w, 41); SHA1_ROUND_40_59(e, a, b, c, d, w[9]);
    SHA1_EXPAND(w, 42); SHA1_ROUND_40_59(d, e, a, b, c, w[10]);
    SHA1_EXPAND(w, 43); SHA1_ROUND_40_59(c, d, e, a, b, w[11]);
    SHA1_EXPAND(w, 44); SHA1_ROUND_40_59(b, c, d, e, a, w[12]);
    SHA1_EXPAND(w, 45); SHA1_ROUND_40_59(a, b, c, d, e, w[13]);
    SHA1_EXPAND(w, 46); SHA1_ROUND_40_59(e, a, b, c, d, w[14]);
    SHA1_EXPAND(w, 47); SHA1_ROUND_40_59(d, e, a, b, c, w[15]);
    SHA1_EXPAND(w, 48); SHA1_ROUND_40_59(c, d, e, a, b, w[0]);
    SHA1_EXPAND(w, 49); SHA1_ROUND_40_59(b, c, d, e, a, w[1]);
    SHA1_EXPAND(w, 50); SHA1_ROUND_40_59(a, b, c, d, e, w[2]);
    SHA1_EXPAND(w, 51); SHA1_ROUND_40_59(e, a, b, c, d, w[3]);
    SHA1_EXPAND(w, 52); SHA1_ROUND_40_59(d, e, a, b, c, w[4]);
    SHA1_EXPAND(w, 53); SHA1_ROUND_40_59(c, d, e, a, b, w[5]);
    SHA1_EXPAND(w, 54); SHA1_ROUND_40_59(b, c, d, e, a, w[6]);
    SHA1_EXPAND(w, 55); SHA1_ROUND_40_59(a, b, c, d, e, w[7]);
    SHA1_EXPAND(w, 56); SHA1_ROUND_40_59(e, a, b, c, d, w[8]);
    SHA1_EXPAND(w, 57); SHA1_ROUND_40_59(d, e, a, b, c, w[9]);
    SHA1_EXPAND(w, 58); SHA1_ROUND_40_59(c, d, e, a, b, w[10]);
    SHA1_EXPAND(w, 59); SHA1_ROUND_40_59(b, c, d, e, a, w[11]);

    // Rounds 60 - 79
    SHA1_EXPAND(w, 60); SHA1_ROUND_60_79(a, b, c, d, e, w[12]);
    SHA1_EXPAND(w, 61); SHA1_ROUND_60_79(e, a, b, c, d, w[13]);
    SHA1_EXPAND(w, 62); SHA1_ROUND_60_79(d, e, a, b, c, w[14]);
    SHA1_EXPAND(w, 63); SHA1_ROUND_60_79(c, d, e, a, b, w[15]);
    SHA1_EXPAND(w, 64); SHA1_ROUND_60_79(b, c, d, e, a, w[0]);
    SHA1_EXPAND(w, 65); SHA1_ROUND_60_79(a, b, c, d, e, w[1]);
    SHA1_EXPAND(w, 66); SHA1_ROUND_60_79(e, a, b, c, d, w[2]);
    SHA1_EXPAND(w, 67); SHA1_ROUND_60_79(d, e, a, b, c, w[3]);
    SHA1_EXPAND(w, 68); SHA1_ROUND_60_79(c, d, e, a, b, w[4]);
    SHA1_EXPAND(w, 69); SHA1_ROUND_60_79(b, c, d, e, a, w[5]);
    SHA1_EXPAND(w, 70); SHA1_ROUND_60_79(a, b, c, d, e, w[6]);
    SHA1_EXPAND(w, 71); SHA1_ROUND_60_79(e, a, b, c, d, w[7]);
    SHA1_EXPAND(w, 72); SHA1_ROUND_60_79(d, e, a, b, c, w[8]);
    SHA1_EXPAND(w, 73); SHA1_ROUND_60_79(c, d, e, a, b, w[9]);
    SHA1_EXPAND(w, 74); SHA1_ROUND_60_79(b, c, d, e, a, w[10]);
    SHA1_EXPAND(w, 75); SHA1_ROUND_60_79(a, b, c, d, e, w[11]);
    SHA1_EXPAND(w, 76); SHA1_ROUND_60_79(e, a, b, c, d, w[12]);
    SHA1_EXPAND(w, 77); SHA1_ROUND_60_79(d, e, a, b, c, w[13]);
    SHA1_EXPAND(w, 78); SHA1_ROUND_60_79(c, d, e, a, b, w[14]);
    SHA1_EXPAND(w, 79); SHA1_ROUND_60_79(b, c, d, e, a, w[15]);

    // Check target match
    if ((0x67452301u + a) == params.target_hashes[0] &&
        (0xEFCDAB89u + b) == params.target_hashes[1] &&
        (0x98BADCFEu + c) == params.target_hashes[2] &&
        (0x10325476u + d) == params.target_hashes[3] &&
        (0xC3D2E1F0u + e) == params.target_hashes[4])
    {
        atomic_store_explicit(&result.found_flag, 1, memory_order_relaxed);
        result.matched_target_index = 0;
        result.matched_length = 12;

        for (uint k = 0; k < 5; ++k) {
            result.matched_candidate[k] = params.prefix[k];
        }
        result.matched_candidate[5] = s0;
        result.matched_candidate[6] = s1;
        result.matched_candidate[7] = s2;
        result.matched_candidate[8] = s3;
        result.matched_candidate[9] = s4;
        result.matched_candidate[10] = s5;
        result.matched_candidate[11] = s6;
        result.matched_candidate[12] = 0;
    }
}

// -----------------------------------------------------------------------------
// 2. GENERAL MASK KERNEL (for arbitrary prefix / suffix combinations)
// -----------------------------------------------------------------------------

kernel void sha1_mask_crack(
    constant CrackParams &params [[buffer(0)]],
    device CrackResult &result   [[buffer(1)]],
    uint gid                     [[thread_position_in_grid]])
{
    if (gid >= params.chunk_size) return;
    if (atomic_load_explicit(&result.found_flag, memory_order_relaxed) != 0) return;

    ulong idx = params.chunk_start_idx + (ulong)gid;
    uint suff_len = params.suffix_len;
    uint pref_len = params.prefix_len;
    uint base = params.base;

    uchar suff[16];
    ulong rem = idx;
    for (int i = (int)suff_len - 1; i >= 0; --i) {
        suff[i] = params.charset[rem % base];
        rem /= base;
    }

    uint total_len = pref_len + suff_len;
    uint w[16];
    #pragma unroll
    for (int i = 0; i < 16; ++i) {
        w[i] = 0;
    }

    for (uint i = 0; i < pref_len; ++i) {
        uint word_idx = i >> 2;
        uint byte_pos = 3 - (i & 3);
        w[word_idx] |= ((uint)params.prefix[i]) << (byte_pos * 8);
    }

    for (uint i = 0; i < suff_len; ++i) {
        uint pos = pref_len + i;
        uint word_idx = pos >> 2;
        uint byte_pos = 3 - (pos & 3);
        w[word_idx] |= ((uint)suff[i]) << (byte_pos * 8);
    }

    {
        uint word_idx = total_len >> 2;
        uint byte_pos = 3 - (total_len & 3);
        w[word_idx] |= 0x80u << (byte_pos * 8);
    }

    w[15] = total_len * 8;

    uint a = 0x67452301u;
    uint b = 0xEFCDAB89u;
    uint c = 0x98BADCFEu;
    uint d = 0x10325476u;
    uint e = 0xC3D2E1F0u;

    // Rounds 0 - 15
    SHA1_ROUND_0_19(a, b, c, d, e, w[0]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[1]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[2]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[3]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[4]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[5]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[6]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[7]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[8]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[9]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[10]);
    SHA1_ROUND_0_19(e, a, b, c, d, w[11]);
    SHA1_ROUND_0_19(d, e, a, b, c, w[12]);
    SHA1_ROUND_0_19(c, d, e, a, b, w[13]);
    SHA1_ROUND_0_19(b, c, d, e, a, w[14]);
    SHA1_ROUND_0_19(a, b, c, d, e, w[15]);

    // Rounds 16 - 19
    SHA1_EXPAND(w, 16); SHA1_ROUND_0_19(e, a, b, c, d, w[0]);
    SHA1_EXPAND(w, 17); SHA1_ROUND_0_19(d, e, a, b, c, w[1]);
    SHA1_EXPAND(w, 18); SHA1_ROUND_0_19(c, d, e, a, b, w[2]);
    SHA1_EXPAND(w, 19); SHA1_ROUND_0_19(b, c, d, e, a, w[3]);

    // Rounds 20 - 39
    SHA1_EXPAND(w, 20); SHA1_ROUND_20_39(a, b, c, d, e, w[4]);
    SHA1_EXPAND(w, 21); SHA1_ROUND_20_39(e, a, b, c, d, w[5]);
    SHA1_EXPAND(w, 22); SHA1_ROUND_20_39(d, e, a, b, c, w[6]);
    SHA1_EXPAND(w, 23); SHA1_ROUND_20_39(c, d, e, a, b, w[7]);
    SHA1_EXPAND(w, 24); SHA1_ROUND_20_39(b, c, d, e, a, w[8]);
    SHA1_EXPAND(w, 25); SHA1_ROUND_20_39(a, b, c, d, e, w[9]);
    SHA1_EXPAND(w, 26); SHA1_ROUND_20_39(e, a, b, c, d, w[10]);
    SHA1_EXPAND(w, 27); SHA1_ROUND_20_39(d, e, a, b, c, w[11]);
    SHA1_EXPAND(w, 28); SHA1_ROUND_20_39(c, d, e, a, b, w[12]);
    SHA1_EXPAND(w, 29); SHA1_ROUND_20_39(b, c, d, e, a, w[13]);
    SHA1_EXPAND(w, 30); SHA1_ROUND_20_39(a, b, c, d, e, w[14]);
    SHA1_EXPAND(w, 31); SHA1_ROUND_20_39(e, a, b, c, d, w[15]);
    SHA1_EXPAND(w, 32); SHA1_ROUND_20_39(d, e, a, b, c, w[0]);
    SHA1_EXPAND(w, 33); SHA1_ROUND_20_39(c, d, e, a, b, w[1]);
    SHA1_EXPAND(w, 34); SHA1_ROUND_20_39(b, c, d, e, a, w[2]);
    SHA1_EXPAND(w, 35); SHA1_ROUND_20_39(a, b, c, d, e, w[3]);
    SHA1_EXPAND(w, 36); SHA1_ROUND_20_39(e, a, b, c, d, w[4]);
    SHA1_EXPAND(w, 37); SHA1_ROUND_20_39(d, e, a, b, c, w[5]);
    SHA1_EXPAND(w, 38); SHA1_ROUND_20_39(c, d, e, a, b, w[6]);
    SHA1_EXPAND(w, 39); SHA1_ROUND_20_39(b, c, d, e, a, w[7]);

    // Rounds 40 - 59
    SHA1_EXPAND(w, 40); SHA1_ROUND_40_59(a, b, c, d, e, w[8]);
    SHA1_EXPAND(w, 41); SHA1_ROUND_40_59(e, a, b, c, d, w[9]);
    SHA1_EXPAND(w, 42); SHA1_ROUND_40_59(d, e, a, b, c, w[10]);
    SHA1_EXPAND(w, 43); SHA1_ROUND_40_59(c, d, e, a, b, w[11]);
    SHA1_EXPAND(w, 44); SHA1_ROUND_40_59(b, c, d, e, a, w[12]);
    SHA1_EXPAND(w, 45); SHA1_ROUND_40_59(a, b, c, d, e, w[13]);
    SHA1_EXPAND(w, 46); SHA1_ROUND_40_59(e, a, b, c, d, w[14]);
    SHA1_EXPAND(w, 47); SHA1_ROUND_40_59(d, e, a, b, c, w[15]);
    SHA1_EXPAND(w, 48); SHA1_ROUND_40_59(c, d, e, a, b, w[0]);
    SHA1_EXPAND(w, 49); SHA1_ROUND_40_59(b, c, d, e, a, w[1]);
    SHA1_EXPAND(w, 50); SHA1_ROUND_40_59(a, b, c, d, e, w[2]);
    SHA1_EXPAND(w, 51); SHA1_ROUND_40_59(e, a, b, c, d, w[3]);
    SHA1_EXPAND(w, 52); SHA1_ROUND_40_59(d, e, a, b, c, w[4]);
    SHA1_EXPAND(w, 53); SHA1_ROUND_40_59(c, d, e, a, b, w[5]);
    SHA1_EXPAND(w, 54); SHA1_ROUND_40_59(b, c, d, e, a, w[6]);
    SHA1_EXPAND(w, 55); SHA1_ROUND_40_59(a, b, c, d, e, w[7]);
    SHA1_EXPAND(w, 56); SHA1_ROUND_40_59(e, a, b, c, d, w[8]);
    SHA1_EXPAND(w, 57); SHA1_ROUND_40_59(d, e, a, b, c, w[9]);
    SHA1_EXPAND(w, 58); SHA1_ROUND_40_59(c, d, e, a, b, w[10]);
    SHA1_EXPAND(w, 59); SHA1_ROUND_40_59(b, c, d, e, a, w[11]);

    // Rounds 60 - 79
    SHA1_EXPAND(w, 60); SHA1_ROUND_60_79(a, b, c, d, e, w[12]);
    SHA1_EXPAND(w, 61); SHA1_ROUND_60_79(e, a, b, c, d, w[13]);
    SHA1_EXPAND(w, 62); SHA1_ROUND_60_79(d, e, a, b, c, w[14]);
    SHA1_EXPAND(w, 63); SHA1_ROUND_60_79(c, d, e, a, b, w[15]);
    SHA1_EXPAND(w, 64); SHA1_ROUND_60_79(b, c, d, e, a, w[0]);
    SHA1_EXPAND(w, 65); SHA1_ROUND_60_79(a, b, c, d, e, w[1]);
    SHA1_EXPAND(w, 66); SHA1_ROUND_60_79(e, a, b, c, d, w[2]);
    SHA1_EXPAND(w, 67); SHA1_ROUND_60_79(d, e, a, b, c, w[3]);
    SHA1_EXPAND(w, 68); SHA1_ROUND_60_79(c, d, e, a, b, w[4]);
    SHA1_EXPAND(w, 69); SHA1_ROUND_60_79(b, c, d, e, a, w[5]);
    SHA1_EXPAND(w, 70); SHA1_ROUND_60_79(a, b, c, d, e, w[6]);
    SHA1_EXPAND(w, 71); SHA1_ROUND_60_79(e, a, b, c, d, w[7]);
    SHA1_EXPAND(w, 72); SHA1_ROUND_60_79(d, e, a, b, c, w[8]);
    SHA1_EXPAND(w, 73); SHA1_ROUND_60_79(c, d, e, a, b, w[9]);
    SHA1_EXPAND(w, 74); SHA1_ROUND_60_79(b, c, d, e, a, w[10]);
    SHA1_EXPAND(w, 75); SHA1_ROUND_60_79(a, b, c, d, e, w[11]);
    SHA1_EXPAND(w, 76); SHA1_ROUND_60_79(e, a, b, c, d, w[12]);
    SHA1_EXPAND(w, 77); SHA1_ROUND_60_79(d, e, a, b, c, w[13]);
    SHA1_EXPAND(w, 78); SHA1_ROUND_60_79(c, d, e, a, b, w[14]);
    SHA1_EXPAND(w, 79); SHA1_ROUND_60_79(b, c, d, e, a, w[15]);

    uint out_a = 0x67452301u + a;
    uint out_b = 0xEFCDAB89u + b;
    uint out_c = 0x98BADCFEu + c;
    uint out_d = 0x10325476u + d;
    uint out_e = 0xC3D2E1F0u + e;

    for (uint t = 0; t < params.target_count; ++t) {
        uint offset = t * 5;
        if (out_a == params.target_hashes[offset] &&
            out_b == params.target_hashes[offset + 1] &&
            out_c == params.target_hashes[offset + 2] &&
            out_d == params.target_hashes[offset + 3] &&
            out_e == params.target_hashes[offset + 4])
        {
            atomic_store_explicit(&result.found_flag, 1, memory_order_relaxed);
            result.matched_target_index = t;
            result.matched_length = total_len;

            for (uint k = 0; k < pref_len; ++k) {
                result.matched_candidate[k] = params.prefix[k];
            }
            for (uint k = 0; k < suff_len; ++k) {
                result.matched_candidate[pref_len + k] = suff[k];
            }
            result.matched_candidate[total_len] = 0;
            break;
        }
    }
}
