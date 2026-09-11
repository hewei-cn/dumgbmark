// Default kernel of the volumeshader-simulator fork.
//
// Positive inside the unit box, negative outside, exactly as the original:
// `length(max(d, 0))` is zero anywhere inside the box and positive outside, so
// subtracting it from the tiny epsilon inverts the sign convention.
//
// Useful for checking the marcher itself: this is the cheapest field of the
// built-ins, so it isolates the loop from the field cost.

static inline float sdf(float3 p) {
    float3 d = abs(p) - float3(1.0f);
    return 0.0000001f - length(max(d, 0.0f));
}
