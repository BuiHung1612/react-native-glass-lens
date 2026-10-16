# react-native-glass-lens

[![npm version](https://img.shields.io/npm/v/react-native-glass-lens.svg)](https://www.npmjs.com/package/react-native-glass-lens)
[![license](https://img.shields.io/npm/l/react-native-glass-lens.svg)](LICENSE)
![platforms](https://img.shields.io/badge/platforms-android%20%7C%20ios-lightgrey.svg)
![new architecture](https://img.shields.io/badge/new%20architecture-fabric-blue.svg)

Liquid-glass for React Native: GPU blur, edge refraction and magnifying
lenses over **your own views**, on Android and iOS, without private APIs.

Built for iOS 26-style floating tab bars — a frosted pill over scrolling
content, and a lens that magnifies and refracts the tab icons while you drag
it — but usable for any glass surface over content you render.

- **Smooth.** Android draws the live content on the GPU every frame
  (RenderNode + RenderEffect); nothing is re-rasterized on the CPU, so content
  scrolling under the glass keeps 120 fps.
- **Real refraction.** A liquid-glass shader bends and splits light along the
  rounded edge (AGSL on Android 13+, Metal on iOS).
- **Lens.** `magnification` scales the sampled content around the view
  center; animate the view with Reanimated and the content stays aligned.
- **Safe for the App Store.** iOS uses Metal, MetalKit and
  MetalPerformanceShaders only.

## Requirements

- React Native **0.80+** with the New Architecture (Fabric)
- Android: GPU path on **API 31+** (refraction on API 33+)
- iOS: any version supported by your React Native

## Installation

```sh
npm install react-native-glass-lens
# or
yarn add react-native-glass-lens
```

```sh
cd ios && pod install
```

Rebuild the native app afterwards; there is no extra setup (autolinking).

## Usage

Wrap the content to sample in a `GlassTarget` and render a `GlassBackdrop`
**next to** it (never inside it). The backdrop draws every target whose
`group` matches its `targetGroup`, positioned where that target really is.

### Frosted glass over a screen (Android)

```tsx
import { GlassBackdrop, GlassTarget } from 'react-native-glass-lens';

export function Screen() {
  return (
    <View style={{ flex: 1 }}>
      <GlassTarget style={{ flex: 1 }}>
        <ScrollView>{/* content */}</ScrollView>
      </GlassTarget>

      <View style={styles.floatingBar}>
        <GlassBackdrop
          style={StyleSheet.absoluteFill}
          blurRadius={20}
          cornerRadius={31}
          overlayColor="rgba(255,255,255,0.5)"
        />
        {/* bar content */}
      </View>
    </View>
  );
}
```

On iOS prefer the system materials (`UIVisualEffectView` / Liquid Glass) for
backdrops over scrolling pages; see [Platform notes](#platform-notes).

### Magnifying lens over tab icons (Android + iOS)

```tsx
import {
  GlassBackdrop,
  GlassTarget,
  isGlassBackdropSupported,
} from 'react-native-glass-lens';

<View style={styles.tabBar}>
  <GlassTarget
    group="tabIcons"
    // iOS re-snapshots the icons when this changes (e.g. active tab colors).
    contentKey={String(activeIndex)}
    style={styles.iconRow}
  >
    {icons}
  </GlassTarget>

  {isGlassBackdropSupported && (
    <Animated.View pointerEvents="none" style={[styles.lens, lensAnimatedStyle]}>
      {/* Opaque base so the unmagnified icons don't show through. */}
      <View style={[StyleSheet.absoluteFill, styles.lensBase]} />
      <GlassBackdrop
        style={StyleSheet.absoluteFill}
        targetGroup="tabIcons"
        magnification={1.2}
        cornerRadius={LENS_HEIGHT / 2}
      />
    </Animated.View>
  )}
</View>
```

Move the lens with a transform (`translateX`, `scaleX`) rather than layout
props: the backdrop resolves the target position through transforms, so the
magnified content stays glued to the icons underneath.

## API

### `<GlassTarget />`

A regular `View` (all View props and styles) whose content backdrops sample.

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `group` | `string` | `'default'` | Backdrops sample targets whose group equals their `targetGroup`. |
| `contentKey` | `string` | — | **iOS.** Change it whenever the content changes to refresh the snapshot. Children mount/unmount and size changes refresh it automatically. Ignored on Android (always live). |

### `<GlassBackdrop />`

A leaf view that renders the sampled content. Accepts View props and styles.

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `targetGroup` | `string` | `'default'` | Group of `GlassTarget`s to sample. |
| `blurRadius` | `number` | `0` | Gaussian blur radius in dp / pt. |
| `magnification` | `number` | `1` | Scale of the content around the view center. |
| `refraction` | `boolean` | `true` | Liquid-glass refraction and dispersion along the edge (Android 13+, iOS). |
| `cornerRadius` | `number` | `0` | Clips the view and shapes the refraction lens. |
| `overlayColor` | `ColorValue` | transparent | Painted over the sampled content (tint). |

### `isGlassBackdropSupported`

`boolean` — `true` on iOS and on Android API 31+. Render a fallback (for
example a plain translucent view) when it is `false`.

## Platform notes

| | Android 12+ | iOS |
| --- | --- | --- |
| Sampling | Live: the target's RenderNode is drawn by the GPU every frame | Snapshot: the target is captured into a Metal texture when its content changes |
| Best for | Anything, including scrolling content | Content that changes rarely (tab bars, toolbars, controls) |
| Blur | `RenderEffect` | MetalPerformanceShaders Gaussian blur, computed once per snapshot |
| Refraction | AGSL `RuntimeShader` (API 33+) | Metal fragment shader |
| Multiple targets per group | All drawn | First match drawn |

**Why snapshots on iOS?** iOS has no public API to sample a live view tree
on the GPU (UIKit's own blur uses the private `CABackdropLayer`). Snapshots
keep everything public and App Store-safe, and are cheap for content that
changes only on interaction.

## Rules and limits

- A backdrop must **not** be a descendant of a target it samples: that would
  create a cyclic render tree. Such targets are skipped.
- On Android below API 31 nothing is drawn except `overlayColor`; check
  `isGlassBackdropSupported`.
- Content outside the target is transparent in the backdrop; put an opaque
  view under a lens if the original content must not show through.

## How it works

**Android.** `GlassTarget` records its children into its own `RenderNode`
and draws that node in place. `GlassBackdrop` re-records a tiny display list
on every window pre-draw — translate to where the target is, scale around the
center, `drawRenderNode(target)` — and applies a `RenderEffect` chain (blur,
then the refraction `RuntimeShader`). The heavy work stays on the
RenderThread/GPU; the UI thread only records a handful of ops.

**iOS.** `GlassTarget` snapshots itself with `drawViewHierarchyInRect` into a
`MTLTexture` a couple of frames after its content changes. `GlassBackdrop`
renders a full-screen triangle into a `CAMetalLayer` from a `CADisplayLink`,
deferred to the end of the run-loop pass and presented inside the Core
Animation transaction, so it always matches the transforms applied in the
same frame. Frames where nothing moved, and hidden or transparent backdrops,
are skipped.

## Contributing

Issues and pull requests are welcome at
[github.com/BuiHung1612/react-native-glass-lens](https://github.com/BuiHung1612/react-native-glass-lens).

## License

MIT © BuiHung1612

The liquid-glass refraction shader is derived from
[AndroidLiquidGlassView](https://github.com/QmDeve/AndroidLiquidGlassView)
(MIT, Copyright (c) 2025 QmDeve).
