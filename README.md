# react-native-glass-lens

GPU glass backdrops for React Native (New Architecture / Fabric): live blur,
liquid-glass edge refraction and magnifying lenses over **your own views**.

- **Android (API 31+)** — `GlassBackdrop` draws the live RenderNodes of
  `GlassTarget`s through `RenderEffect` blur and an AGSL refraction shader
  (API 33+). No software re-rasterization: scrolling content stays at full
  frame rate and hardware bitmaps just work.
- **iOS** — `GlassTarget`s are snapshotted into a Metal texture when their
  content changes (`contentKey`, children, size); `GlassBackdrop` renders that
  snapshot every frame with Metal: Gaussian blur (MPS), magnification and the
  same refraction shader ported to MSL. Public APIs only.

## Install

```sh
yarn add react-native-glass-lens
cd ios && pod install
```

Requires React Native 0.80+ with the New Architecture.

## Usage

```tsx
import { GlassBackdrop, GlassTarget, isGlassBackdropSupported } from 'react-native-glass-lens';

<View>
  <GlassTarget group="row" contentKey={String(selectedIndex)} style={StyleSheet.absoluteFill}>
    {icons}
  </GlassTarget>

  {/* Sibling of the target, never inside it. */}
  <GlassBackdrop
    targetGroup="row"
    magnification={1.2}
    cornerRadius={31}
    style={lensStyle}
  />
</View>
```

### `GlassTarget`

| Prop | Type | Default | |
| --- | --- | --- | --- |
| `group` | `string` | `'default'` | Backdrops sample targets of their `targetGroup`. |
| `contentKey` | `string` | | iOS only: change it when the content changes to refresh the snapshot. |

### `GlassBackdrop`

| Prop | Type | Default | |
| --- | --- | --- | --- |
| `targetGroup` | `string` | `'default'` | Group of targets to sample. |
| `blurRadius` | `number` | `0` | Blur radius in dp/pt. |
| `magnification` | `number` | `1` | Scale around the view center. |
| `refraction` | `boolean` | `true` | Liquid-glass edge refraction (Android 13+, iOS). |
| `cornerRadius` | `number` | `0` | Clip + lens shape. |
| `overlayColor` | `ColorValue` | transparent | Painted over the sampled content. |

## Rules and limits

- A backdrop must not be a descendant of a target it samples (that would make
  the render tree cyclic); such targets are skipped.
- iOS samples snapshots, not live content: use it for content that changes
  rarely (tab bars, toolbars, controls), not for scrolling pages. Android
  samples live content.
- Android below API 31 has no GPU path; check `isGlassBackdropSupported` and
  render a fallback.
- iOS draws the first matching target of a group; Android draws all of them.

## License

MIT. The refraction shader is derived from
[AndroidLiquidGlassView](https://github.com/QmDeve/AndroidLiquidGlassView)
(MIT, Copyright (c) 2025 QmDeve).
