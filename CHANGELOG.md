# Changelog

## [0.1.0] — 2026-10-16

First release.

### Added
- `GlassTarget`: marks the content a backdrop samples, grouped by `group`.
- `GlassBackdrop`: draws the targets of its `targetGroup` with `blurRadius`, `magnification`, liquid-glass `refraction`, `cornerRadius` and `overlayColor`.
- Android (API 31+): targets are sampled live as RenderNodes on the GPU — `RenderEffect` blur and an AGSL refraction shader (API 33+). No software re-rasterization, so content scrolling under the glass keeps full frame rate and hardware bitmaps render correctly.
- iOS: targets are snapshotted into a Metal texture when `contentKey`, children or size change; the backdrop renders it every frame with MPS Gaussian blur, magnification and the refraction shader ported to MSL. Rendering is deferred to the end of the run-loop pass and presented with the Core Animation transaction, so a lens moved by Reanimated never lags its content. Public APIs only.
- `isGlassBackdropSupported` to pick a fallback on Android below API 31.
