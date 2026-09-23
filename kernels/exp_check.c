// On-device check of exp_ps / softmax_fast against libm. Build like the binaries, run on the Kindle.
#include <stdio.h>
#include "neon_common.h"
int main(void) {
    double worst = 0;
    float wx = 0;
    for (float x = -87.0f; x <= 0.0f; x += 0.0007f) {
        float e = vgetq_lane_f32(exp_ps(vdupq_n_f32(x)), 0), r = expf(x);
        double rel = fabs((double)e - r) / r;
        if (rel > worst) {
            worst = rel;
            wx = x;
        }
    }
    float a[32000], b[32000];
    for (int i = 0; i < 32000; i++) a[i] = b[i] = 12.0f * sinf(i * 0.37f) - (i % 97) * 0.1f;
    softmax_fast(a, 32000);
    float m = b[0], s = 0;
    for (int i = 1; i < 32000; i++)
        if (b[i] > m) m = b[i];
    for (int i = 0; i < 32000; i++) {
        b[i] = expf(b[i] - m);
        s += b[i];
    }
    double pw = 0;
    for (int i = 0; i < 32000; i++) {
        b[i] /= s;
        double d = fabs((double)a[i] - b[i]) / b[i];
        if (d > pw) pw = d;
    }
    printf("exp_ps max rel err %.3g (%.1f ulp) at x=%g; softmax max rel diff %.3g\n", worst, worst / 5.96e-8,
           wx, pw);
    return !(worst < 1e-6 && pw < 1e-5);
}
