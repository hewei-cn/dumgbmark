// The original cznull default kernel: an 8th-power Mandelbulb, 5 iterations.
// This is what produces the "poison mushroom".
//
// Transcribed from livcm/volumeshader-bm/vsbm.js, which is cznull's default.
// The only change is the clamp inside acos(): GLSL leaves acos undefined outside
// [-1, 1] and Metal returns NaN there, so the guard only removes undefined
// behaviour. The original's `e = 1.0/b` is dead and has been dropped.
//
// Sign convention: `4 - |a|^2` is positive while the escape radius is below 2,
// i.e. positive inside the shape.

static inline float sdf(float3 ver) {
    float3 a = ver;
    float b, c, d;
    for (int i = 0; i < 5; i++) {
        b = length(a);
        c = atan2(a.y, a.x) * 8.0f;
        d = acos(clamp(a.z / b, -1.0f, 1.0f)) * 8.0f;
        b = pow(b, 8.0f);
        a = float3(b * sin(d) * cos(c), b * sin(d) * sin(c), b * cos(d)) + ver;
        if (b > 6.0f) {
            break;
        }
    }
    return 4.0f - dot(a, a);
}
