# Changelog

## [0.2.0] — 2026-10-19

### Added
- `GlassBackdrop` `highlight`: specular rim light along the edge, brightest on the top-left and bottom-right.
- `GlassBackdrop` `saturation`: vibrancy boost of the sampled content.
- `GlassBackdrop` `lightAngle`: direction of the rim light.
- `GlassBackdrop` `cornerCurve="continuous"`: Apple-style squircle corners in the shader and the clip (Android clip on API 33+).
- README recipes: Liquid Glass preset, press/drag feedback, tilt-driven light, shadow, Reduce Transparency.
- `GlassBackdrop` `refractionHeight`, `refractionAmount`, `dispersion`: tune the refraction lens (defaults keep the previous look).

## [0.1.1] — 2026-10-19

### Performance
- Android: the refraction shader no longer runs its identity color stages (two sRGB↔linear conversions per pixel); the shader source is read once per process.
- iOS: blurred backdrops ask for lower-resolution snapshots (blur radius ≥ 8 snapshot pixels), cutting snapshot and blur cost several-fold; a target shared by several backdrops snapshots at the highest scale any of them needs.
- iOS: backdrops share one Metal command queue, and the blur output texture is reused across same-size snapshots.

## [0.1.0] — 2026-10-16

First release.

### Added
- `GlassTarget`: marks the content a backdrop samples, grouped by `group`.
- `GlassBackdrop`: draws the targets of its `targetGroup` with `blurRadius`, `magnification`, liquid-glass `refraction`, `cornerRadius` and `overlayColor`.
- Android (API 31+): targets are sampled live as RenderNodes on the GPU — `RenderEffect` blur and an AGSL refraction shader (API 33+). No software re-rasterization, so content scrolling under the glass keeps full frame rate and hardware bitmaps render correctly.
- iOS: targets are snapshotted into a Metal texture when `contentKey`, children or size change; the backdrop renders it every frame with MPS Gaussian blur, magnification and the refraction shader ported to MSL. Rendering is deferred to the end of the run-loop pass and presented with the Core Animation transaction, so a lens moved by Reanimated never lags its content. Public APIs only.
- `isGlassBackdropSupported` to pick a fallback on Android below API 31.
