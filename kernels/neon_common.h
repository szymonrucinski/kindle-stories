// Shared NEON helpers for run-fast.c / runq-fast.c (armv7-a Cortex-A9: NEON, no FMA).
#include <arm_neon.h>
#include <math.h>

#ifndef KV_PF
#define KV_PF 2 // prefetch whole K/V cache rows this many timesteps ahead (32B lines = 8 floats)
#endif

// q.k in the same order clang's vectorizer uses for the reference loop:
// 4 lane-wise partial sums, then (l0+l2)+(l1+l3). Keeps attention bit-identical.
static inline float dot_ref_order(const float* q, const float* k, int n) {
    if (n % 4) {
        float s = 0.0f;
        for (int i = 0; i < n; i++) s += q[i] * k[i];
        return s;
    }
    float32x4_t acc = vdupq_n_f32(0.0f);
    for (int i = 0; i < n; i += 4) acc = vaddq_f32(vmulq_f32(vld1q_f32(q + i), vld1q_f32(k + i)), acc);
    float32x2_t r = vadd_f32(vget_low_f32(acc), vget_high_f32(acc));
    return vget_lane_f32(r, 0) + vget_lane_f32(r, 1);
}

// 4-lane expf: Cody-Waite range reduction + Cephes degree-5 polynomial (a few ulp).
// Inputs are clamped to [-87.3, 88.3], so tiny results are ~1e-38 instead of 0/denormal.
static inline float32x4_t exp_ps(float32x4_t x) {
    x = vminq_f32(vmaxq_f32(x, vdupq_n_f32(-87.3f)), vdupq_n_f32(88.3f));
    float32x4_t fx = vmlaq_n_f32(vdupq_n_f32(0.5f), x, 1.44269504088896341f);
    float32x4_t n = vcvtq_f32_s32(vcvtq_s32_f32(fx)); // trunc toward 0 ...
    n = vsubq_f32(n, vreinterpretq_f32_u32(vandq_u32(
                         vcgtq_f32(n, fx), vreinterpretq_u32_f32(vdupq_n_f32(1.0f))))); // ... -> floor
    x = vmlsq_n_f32(x, n, 0.693359375f);
    __asm__("" : "+w"(x)); // barrier: stop -ffast-math from merging the two-step ln2 reduction
    x = vmlsq_n_f32(x, n, -2.12194440e-4f);
    float32x4_t y = vdupq_n_f32(1.9875691500e-4f);
    y = vmlaq_f32(vdupq_n_f32(1.3981999507e-3f), y, x);
    y = vmlaq_f32(vdupq_n_f32(8.3334519073e-3f), y, x);
    y = vmlaq_f32(vdupq_n_f32(4.1665795894e-2f), y, x);
    y = vmlaq_f32(vdupq_n_f32(1.6666665459e-1f), y, x);
    y = vmlaq_f32(vdupq_n_f32(5.0000001201e-1f), y, x);
    y = vaddq_f32(vmlaq_f32(x, y, vmulq_f32(x, x)), vdupq_n_f32(1.0f));
    int32x4_t e = vshlq_n_s32(vaddq_s32(vcvtq_s32_f32(n), vdupq_n_s32(127)), 23);
    return vmulq_f32(y, vreinterpretq_f32_s32(e));
}

// softmax for the 32000 logits in sample() only. Not bit-identical to the libm version
// (probabilities agree to a few ulp), and greedy decoding (-t 0) never calls it.
static void softmax_fast(float* x, int size) {
    if (size % 4) { // not the vocab-sized case; keep the simple path
        float m = x[0], s = 0.0f;
        for (int i = 1; i < size; i++)
            if (x[i] > m) m = x[i];
        for (int i = 0; i < size; i++) {
            x[i] = expf(x[i] - m);
            s += x[i];
        }
        for (int i = 0; i < size; i++) x[i] /= s;
        return;
    }
    float32x4_t mv = vld1q_f32(x);
    for (int i = 4; i < size; i += 4) mv = vmaxq_f32(mv, vld1q_f32(x + i));
    float32x2_t m2 = vpmax_f32(vget_low_f32(mv), vget_high_f32(mv));
    float32x4_t m = vdupq_lane_f32(vpmax_f32(m2, m2), 0);
    float32x4_t sv = vdupq_n_f32(0.0f);
    for (int i = 0; i < size; i += 4) {
        float32x4_t e = exp_ps(vsubq_f32(vld1q_f32(x + i), m));
        vst1q_f32(x + i, e);
        sv = vaddq_f32(sv, e);
    }
    float32x2_t s2 = vpadd_f32(vget_low_f32(sv), vget_high_f32(sv));
    float32x4_t inv = vdupq_n_f32(1.0f / (vget_lane_f32(s2, 0) + vget_lane_f32(s2, 1)));
    for (int i = 0; i < size; i += 4) vst1q_f32(x + i, vmulq_f32(vld1q_f32(x + i), inv));
}
