# Measured performance

All figures are raw GPU time from `MTLCommandBuffer.gpuStartTime/gpuEndTime`,
rendered offscreen and never presented, so the compositor and vsync are excluded
and the number is pure marcher throughput.

**Test machine**

| | |
| --- | --- |
| Model | Mac16,12 (MacBook Air) |
| Chip | Apple M4, 8-core GPU |
| Memory | unified |
| OS | macOS 27.0 |
| Display | 2560×1664 Retina (1280×832 points) |

Reproduce with:

```sh
swift run -c release vsbm-selfcheck --bench
```

## Mandelbulb-8, the reference kernel

| Configuration | 1024×1024 | 512×512 |
| --- | --- | --- |
| fragment, safe math — **Reference preset** | **136.0 ms / 7.4 FPS** | 43.5 ms / 23.0 FPS |
| fragment, fast math | 109.7 ms / 9.1 FPS | — |
| fragment, safe math + bounding sphere | 99.3 ms / 10.1 FPS | 33.6 ms / 29.8 FPS |
| fragment, fast math + bounding sphere | 79.0 ms / 12.7 FPS | 27.0 ms / 37.0 FPS |
| compute, safe math | 150.7 ms / 6.6 FPS | 46.1 ms / 21.7 FPS |

### What this says

- **The reference configuration really is this slow.** 7.4 FPS at 1024² on an M4
  is the honest cost of 1000 fixed-step field evaluations per pixel with no
  acceleration. That is why the web benchmark is used to make phones stutter.
- **Fast math: 1.24×.** Real, but it reassociates floating point.
- **Bounding sphere: 1.37×**, and on the reference view the image is unchanged to
  the last bit. Most rays miss the Mandelbulb and would otherwise pay for all
  1000 steps.
- **Both: 1.72×** → 12.7 FPS. Still far from smooth, which is the point.
- **Fragment beats compute by 1.09×** here. A first, buggy measurement suggested
  1.58×; that run had a broken vertex uniform binding, so its image was black and
  its rays terminated early. The corrected ranking is much closer, and the
  compute path is kept in the app for A/B testing on other GPUs. The two backends
  are asserted to agree (`mean |delta| 0.000079` over a 72×72 frame).

## Cost scales with pixels

`512²/1024² = 43.5/136.0 = 0.32`, close to the 0.25 of pure area plus a fixed
tail. Resolution is therefore the first-order control, which is exactly what
`AutoResolution` acts on.

To hold a frame budget with the reference kernel at 1024p base:

| Target | Scale | Internal resolution | Implied |
| --- | --- | --- | --- |
| 60 FPS | 0.35 | ≈ 358×358 | 16.7 ms |
| 30 FPS | 0.49 | ≈ 501×501 | 33.3 ms |

These come from the controller's own convergence test in `vsbm-selfcheck`, which
drives a cost model of this exact table.

## Other kernels at the reference settings, 1024×1024

| Kernel | Time | FPS |
| --- | --- | --- |
| `box` | 5.2 ms | 192.3 |
| `sphere` | 16.8 ms | 59.4 |
| `menger` | 44.8 ms | 22.3 |
| `mandelbulb8` | 136.0 ms | 7.4 |

The spread is 26×, which is why adaptive resolution has to be on by default
outside the Reference preset: the same window that is smooth with `box` is a
slideshow with `mandelbulb8`.

## Runtime shader compilation

Assembling and compiling the full kernel plus driver costs **~35 ms** on the M4
(`MTLDevice.makeLibrary(source:options:)`). That is fast enough to apply a kernel
edit from the in-app editor without a hitch, and it is the only option here:
this machine has Command Line Tools but no Xcode, so there is no `metal`
compiler and no `.metallib`.

## macOS-specific measures in the renderer

| Measure | Where |
| --- | --- |
| No CPU stall on the GPU; 3 frames in flight via a semaphore | `RenderView.renderFrame` |
| GPU time read asynchronously, never synchronously | `addCompletedHandler` |
| `framebufferOnly = true`, `maximumDrawableCount = 3`, `presentsWithTransaction = false` | `RenderView.makeBackingLayer` |
| `loadAction = .dontCare` on both passes | `MetalRenderer.encode` |
| Upscale pass skipped when the scale lands exactly on the drawable size | `RenderSizing.canRenderDirectly` |
| Private-storage intermediate textures, no readback in the frame loop | `makeIntermediateTexture` |
| App Nap disabled for the session | `ProcessInfo.beginActivity([.userInitiated, .latencyCritical, .idleSystemSleepDisabled])` |
| Rendering stops entirely when the window is occluded or miniaturised | `NSWindow.didChangeOcclusionStateNotification` |
| Thermal state lowers the maximum render scale | `AutoResolution.setThermalCap` |
| Zero per-frame heap allocation; uniforms go through `setBytes` (96 B, under the 4 KB inline limit) | `MetalRenderer` |
| Two AppKit labels updated at 2 Hz, off the render path | `StatsOverlay`, `AppDelegate.startUITimer` |

## Windowed versus offscreen timings

The HUD's "GPU ms" comes from `MTLCommandBuffer.gpuStartTime/gpuEndTime` of the
command buffer that also **presents** to the drawable, so it includes the
upscale pass and the presentation wait — it is the right number for judging a
frame budget, but it is not the pure marcher cost.

Measured on the same machine with the Reference preset inside the app's window
(2220×1746 drawable, 1024×1024 march, upscale pass):

| | |
| --- | --- |
| Offscreen raw marcher, 1024×1024 | 136.0 ms |
| Windowed GPU time, 1024×1024 + upscale + present | 262.9 ms |

So a 1024×1024 march to a 2220×1746 window costs roughly twice the offscreen
figure. The **Run raw GPU benchmark** button (and the Raw GPU preset) measures
without a drawable and is the number comparable to the table above.

## Windowed, at the display refresh rate

With the Balanced preset in the real window (2220x1746 drawable, adaptive
resolution, target 60 FPS), measured with `--soak 18`:

| | |
| --- | --- |
| Instant FPS | 59.8 |
| Average FPS | 45.6 (includes the convergence ramp) |
| 1 % low | 29.4 |
| GPU median | 16.03 ms (budget 16.7 ms) |
| Internal render | 357x281 at scale 0.274 |

The controller lands on its frame budget and the delivered rate tracks it.

## Methodology notes and corrections

Two bugs found by the app's own soak mode (`--soak <seconds>`, which runs the
real windowed pipeline and prints what it measured) are worth recording, because
both produced plausible-looking but wrong numbers:

1. The Balanced preset enabled the bounding-sphere early-out before any radius
   had been probed. A radius of zero collapses the sphere to a point, rejecting
   every ray: the image went black and frames appeared to take 0.74 ms. Fixed by
   probing on demand and by refusing to enable the early-out with a
   non-positive radius.
2. The frame loop blocked the main thread on the in-flight semaphore. That
   stalls the run loop, so the display link misses its vsync and every frame
   silently costs an extra refresh interval. Measured at target 60 FPS: 20.2
   delivered, with a p99 GPU time of 193 ms. Skipping the tick instead of
   blocking gave 56.5 delivered with a p99 of 31 ms.

An earlier draft of this table reported 1024² at 95.3 ms. That measurement came
from a standalone benchmark that bound the uniform block to the fragment stage
only, leaving the vertex stage reading uninitialised data. The rays were
garbage, they terminated early, and the number was too low. The corrected figure
is 136.0 ms. Every number in the table above is produced by
`vsbm-selfcheck --bench`, which renders through the same `MetalRenderer.encode`
path the window uses.
