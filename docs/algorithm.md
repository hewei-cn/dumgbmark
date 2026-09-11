# Algorithm notes

This document records exactly what was ported, what was changed, and why each
change is safe.

## Reference sources

| What | Where |
| --- | --- |
| cznull's original renderer (fork) | `Hotment/volumeshader-simulator/js/Raymarcher.js` |
| cznull's original page + default kernel | `livcm/volumeshader-bm/vsbm.js` |

The two fragment shaders are equivalent line for line; the fork only renames
`kernel` to `kernal` and changes the default camera distance from `1.6` to
`2.6`. The default kernel in `vsbm.js` is the original one and is the kernel this
app ships as `mandelbulb8`.

## The reference algorithm

A single pass over a six-vertex full-screen quad. For every pixel:

1. **Build the ray.** The vertex stage produces
   `dir = forward + right·(p.x·x) + up·(p.y·y)` and
   `localdir = (p.x·x, p.y·y, −1)`, where `x = 2w/(w+h)` and `y = 2h/(w+h)` are
   aspect terms (not pixel coordinates) and `p` is the NDC position.

2. **March at a fixed step.** `step = 0.002`, and sample positions are
   `origin + dir·(step·len·k)` for `k = 2 … 1001`. With the reference `len = 1.6`
   the step is `0.0032` and the march reaches `3.2032`. There is **no** distance
   field acceleration and **no** early-out: a ray that misses evaluates the field
   1000 times. That is the entire point of the benchmark.

3. **Detect a hit two ways.**
   - *Sign change.* If `v > 0 && v1 < 0`, refine with 8 bisection steps, then
     accept if `r3 < 2·len`.
   - *Grazing pass.* If `v < v1 && v1 > v2 && v1 < 0 && (v1·2 > v ‖ v1·2 > v2)` —
     a local minimum that stays below zero — refine with 8 golden-section steps
     (`M_L = 0.3819660113`, `M_R = 0.6180339887`), then 8 bisection steps, then
     accept if `2·len > r3 > step·len`.

4. **Shade.** Six more field evaluations give a central-difference normal. The
   reflection uses the **unnormalised object-space `localdir`**, not the world
   ray. The ramp is
   `r3 = max(0, dot(reflect, (0.276, 0.920, 0.276)))`, raised to the 4th power,
   then `r3·0.45 + N·L·0.25 + 0.3`; the colour is
   `sin(dot(ver,ver)·10 + phase)·0.5 + 0.5` per channel — the rainbow banding
   that gives the shape its nickname. Output alpha is 1; nothing accumulates.

## Deliberate deviations

### 1. Bit-exact: redundant field evaluations removed

The reference recomputes values it already holds. Because the sample positions
are recomputed from the same expressions with the same rounding, each of these
substitutions is bit-identical, not merely close:

| Reference | Replacement | Why it is identical |
| --- | --- | --- |
| `m1 = kernel(origin + dir·r1)` with `r1 = step·len·(k−1)` | `m1` omitted | equals `v1`, and `m1` is never read |
| `m2 = kernel(origin + dir·r2)` with `r2 = step·len·k` | `m2 = v` | same expression as produced `v` |
| `m1 = kernel(origin + dir·(step·len·(k−2)))` | omitted | equals `v2`, never read |
| `m2 = kernel(origin + dir·r2)` after the golden loop | omitted | `r2` is untouched since `m2` was last set from it |
| `m1`,`m2` in the `m3 > 0` tail | `m2 = m3` | `r2 = r3`, so `m2 = kernel(origin + dir·r3) = m3` |

Up to six field evaluations per hit are removed. The `m1` accumulator is dead in
the original too — it is written and never read — so it is dropped from both the
shader and the oracle.

`renderToRGB` output versus `CPUReference` (a *literal* transcription that keeps
every redundant call) measures **mean |delta| 0.000809**, **max 0.007145**, with
**0.098 %** of pixels differing by more than one 8-bit step. That residual is
rounding in the transcendental functions, not a behavioural difference.

### 2. Guarded transcendentals in the Mandelbulb kernel

The original computes `acos(a.z/b)` unguarded. GLSL leaves `acos` undefined
outside `[−1, 1]`, and Metal returns NaN there, so the port writes
`acos(clamp(a.z / b, -1.0f, 1.0f))`. This only changes inputs on which the
reference had no defined behaviour. The dead `e = 1.0/b` in the original kernel
is also dropped.

### 3. Uniform-driven knobs (not bit-faithful, off by default)

| Knob | Effect | Why it is not faithful |
| --- | --- | --- |
| `mathMode = .fast` | **1.24×** on the same image | reassociates floating point; the reference relies on `1e-7` epsilons and an exact comparison chain |
| bounding-sphere early-out | **1.37×**, measured bit-identical on the default view | bounds the field empirically on a lattice, so it is not provably exact for every kernel or camera |
| `stepScale > 1` | proportional to the scale | marches the same sample count over a longer distance and can tunnel through thin features |
| compute backend | 0.92×, i.e. **slower** | same maths, different stage; measured worse on Apple GPUs |

The app reports the pixel difference against the faithful configuration on
demand ("Compare with faithful reference"), so every one of these is a visible
trade rather than a hidden one.

### 4. Bounding-sphere early-out

Sample positions are `P(k) = o + (dir·dstep)·k`, so the sphere `|P| = R` gives a
quadratic in `k`. A ray that never enters the sphere has every sample outside it,
so it can produce neither a sign change nor a local minimum, and the whole march
is skipped. `R` comes from a GPU probe that samples the field on a `96³` lattice
and takes the largest radius where `sdf(p) > −delta`, plus a margin of two
lattice spacings.

For the default Mandelbulb this yields `R ≈ 1.29`. The camera sits at `1.6`, so
it is outside the sphere and most rays are rejected outright. On the reference
view at 512×512 the early-out is **1.29× faster** with a **mean difference of
exactly 0.000000**.

`R` is a lattice-derived heuristic, not a proof about the continuum, so the
feature stays opt-in and its cost is measurable in the app.

### 5. Engine-level changes

- The reference calls `gl.finish()` after **every** frame, fully stalling the CPU
  on the GPU. The native renderer never blocks: queue depth is bounded to three
  frames by a semaphore, and GPU time comes from
  `MTLCommandBuffer.gpuStartTime/gpuEndTime` read asynchronously in a completion
  handler. FPS here therefore measures actual GPU throughput rather than
  including a forced round trip.
- Both passes use `loadAction = .dontCare`: the marcher writes every pixel
  unconditionally, so clearing first is pure bandwidth waste.
- When the render scale puts the marcher target at the drawable size, the
  upscale pass is skipped entirely and the marcher writes straight into the
  drawable.

## Fidelity testing in one paragraph

`CPUReference.march` is a literal transcription of the original GLSL, keeping the
redundant calls. `vsbm-selfcheck` renders the same uniforms on both the GPU and
the CPU and compares. If the bit-exact rewrites above were wrong, the GPU would
diverge from the literal oracle; the measured 0.0008 mean delta says they are not.
