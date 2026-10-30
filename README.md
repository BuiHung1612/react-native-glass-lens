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

### Clear lens over the page

A lens that samples both the page and the active icons is clear glass
rather than an opaque bubble. Wrap the page in a `GlassTarget`, list both
groups and drop the opaque base:

```tsx
<GlassBackdrop
  style={StyleSheet.absoluteFill}
  targetGroup="default,tabIcons"
  magnification={1.2}
  depth={1}
  cornerRadius={LENS_HEIGHT / 2}
  interactive
  pressed={pressed}
/>
```

On iOS the page is a snapshot: `interactive` + `pressed` re-takes it on each
press (a full-screen capture, roughly 10–20 ms on older iPhones), and the
lens shows the page as it was at touch down. Hold before showing the lens so
the capture lands while nothing moves. On iOS 26+ prefer the system Liquid
Glass for the lens.

### Active-colored icons under the lens

Render the icons twice: the inactive set as plain views, and the active set
in a `sampleOnly` target that is invisible on screen but still sampled. The
lens then shows the active colors wherever it slides, with no per-tab color
swap, and the iOS snapshot is taken once instead of on every tab change.

```tsx
<View style={styles.tabBar}>
  <View style={styles.iconRow}>{renderIcons(inactiveColor)}</View>

  <GlassTarget
    group="tabIcons"
    sampleOnly
    pointerEvents="none"
    importantForAccessibility="no-hide-descendants"
    style={[StyleSheet.absoluteFill, styles.iconRow]}
  >
    {renderIcons(activeColor)}
  </GlassTarget>

  {isGlassBackdropSupported && (
    <Animated.View pointerEvents="none" style={[styles.lens, lensAnimatedStyle]}>
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

Without a lens (`isGlassBackdropSupported` is `false`) nothing shows the
active set, so color the active tab in the visible row instead.

## API

### `<GlassTarget />`

A regular `View` (all View props and styles) whose content backdrops sample.

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `group` | `string` | `'default'` | Backdrops sample targets whose group equals their `targetGroup`. |
| `contentKey` | `string` | — | **iOS.** Change it whenever the content changes to refresh the snapshot. Children mount/unmount and size changes refresh it automatically. Ignored on Android (always live). |
| `sampleOnly` | `boolean` | `false` | Hides the target on screen while backdrops keep sampling it. The target's own background is not sampled. On iOS the hidden target also ignores touches and accessibility; on Android pass `pointerEvents="none"` and `importantForAccessibility="no-hide-descendants"`. |

### `<GlassBackdrop />`

A leaf view that renders the sampled content. Accepts View props and styles.

| Prop | Type | Default | Description |
| --- | --- | --- | --- |
| `targetGroup` | `string` | `'default'` | Group of `GlassTarget`s to sample. Several groups, comma-separated (`'page,tabIcons'`), are drawn in order (later on top). |
| `blurRadius` | `number` | `0` | Gaussian blur radius in dp / pt. |
| `magnification` | `number` | `1` | Scale of the content around the view center. |
| `refraction` | `boolean` | `true` | Liquid-glass refraction and dispersion along the edge (Android 13+, iOS). |
| `refractionHeight` | `number` | `16` | Width of the refracting band along the edge, in dp / pt. |
| `refractionAmount` | `number` | `40` | How far content is pulled inward at the edge, in dp / pt. |
| `dispersion` | `number` | `0.35` | Chromatic dispersion (color fringing) at the corners; `0` turns it off and samples the content once instead of seven times. |
| `saturation` | `number` | `1` | Saturation of the sampled content. Apple's glass boosts it (try `1.5`). |
| `highlight` | `number` | `0` | Specular rim light along the edge: a sharp stroke plus a soft inner bloom, bright on the side facing `lightAngle` and weaker on the opposite side. `0`–`1` (try `0.6`). Drawn under `overlayColor`. |
| `lightAngle` | `number` | `-45` | Where the rim light comes from, in degrees clockwise from the top (`-45` = top-left). |
| `depth` | `number` | `0.3` | How much the refraction bulges toward the center: `0` bends only the edge band, `1` reads as a lens. |
| `cornerRadius` | `number` | `0` | Clips the view and shapes the refraction lens. |
| `cornerCurve` | `'circular' \| 'continuous'` | `'circular'` | `'continuous'` gives Apple-style squircle corners (clip follows on Android 13+; pair with `borderCurve: 'continuous'` on iOS wrappers). |
| `overlayColor` | `ColorValue` | transparent | Painted over the sampled content (tint). |
| `liveBlur` | `boolean` | `false` | **iOS.** Live system blur (`blurRadius`, `saturation`) under the glass, so it stays see-through while content scrolls; the snapshot-based refraction hides while the content under the view scrolls and fades back in about 0.1 s after it stops. See [Live blur on iOS](#live-blur-on-ios). Ignored on Android. |
| `interactive` | `boolean` | `false` | Refraction, dispersion and highlight follow `pressed` through a native spring: off while released, full while pressed. |
| `pressed` | `boolean` | `false` | Press state of an `interactive` backdrop. Set it on touch down / up; the spring runs natively. **iOS:** pressing re-snapshots the sampled targets, so a lens over scrolled content shows the current page. |

### `isGlassBackdropSupported`

`boolean` — `true` on iOS and on Android API 31+. Render a fallback (for
example a plain translucent view) when it is `false`.

## Recipes

### Closer to iOS 26 Liquid Glass

Liquid Glass reads as *clear* glass: keep the blur light so the content
behind stays recognizable, and let a wide refraction band bend it at the
edge. Heavy blur plus a strong tint gives frosted glass instead.

```tsx
<GlassBackdrop
  style={StyleSheet.absoluteFill}
  blurRadius={8}
  cornerRadius={31}
  cornerCurve="continuous"
  saturation={1.5}
  highlight={0.6}
  overlayColor="rgba(255,255,255,0.15)"
/>
```

### Press and drag feedback

Animate the glass wrapper's transform; the backdrop resolves its targets
through transforms, so the content underneath stays aligned.

```tsx
const pressed = useSharedValue(0);
const velocityX = useSharedValue(0); // from your pan gesture
const style = useAnimatedStyle(() => {
  const stretch = Math.min(Math.abs(velocityX.value) / 4000, 0.15);
  return {
    transform: [
      { scale: withSpring(pressed.value ? 1.08 : 1) },
      { scaleX: 1 + stretch },
      { scaleY: 1 - stretch / 2 },
    ],
  };
});
```

### Refraction that grows while pressed

Animating `refractionAmount` & co. from Reanimated commits a prop update
every frame. Let the backdrop animate instead: mark it `interactive` and flip
`pressed` on touch down / up. A native critically damped spring (about 0.15 s)
scales refraction, dispersion and highlight from 0 to the values you set.

```tsx
const [pressed, setPressed] = useState(false);
const gesture = Gesture.Pan()
  .onBegin(() => runOnJS(setPressed)(true))
  .onFinalize(() => runOnJS(setPressed)(false));

<GestureDetector gesture={gesture}>
  <Animated.View style={[styles.lens, lensAnimatedStyle]}>
    <GlassBackdrop
      style={StyleSheet.absoluteFill}
      targetGroup="tabIcons"
      cornerRadius={LENS_HEIGHT / 2}
      interactive
      pressed={pressed}
      refractionHeight={10}
      refractionAmount={14}
      dispersion={0.5}
      highlight={1}
    />
  </Animated.View>
</GestureDetector>;
```

### Light that follows the device tilt

```tsx
const rotation = useAnimatedSensor(SensorType.ROTATION);
const [angle, setAngle] = useState(-45);
useAnimatedReaction(
  () => Math.round(-45 + (rotation.sensor.value.roll * 180) / Math.PI / 5) * 5,
  (next, prev) => next !== prev && runOnJS(setAngle)(next),
);
<GlassBackdrop lightAngle={angle} highlight={0.6} /* … */ />;
```

Quantize the angle as above: each change rebuilds the effect (Android) or
re-renders the frame (iOS).

### Shadow

Glass casts a soft shadow on the content below it. Put it on the wrapper
(New Architecture `boxShadow`, both platforms):

```tsx
<View style={{ borderRadius: 31, borderCurve: 'continuous', boxShadow: '0 8px 24px rgba(0,0,0,0.12)' }}>
  <GlassBackdrop style={StyleSheet.absoluteFill} cornerRadius={31} /* … */ />
</View>
```

### Reduce Transparency

Honor the iOS accessibility setting with a solid fallback:

```tsx
const [reduce, setReduce] = useState(false);
useEffect(() => {
  AccessibilityInfo.isReduceTransparencyEnabled().then(setReduce);
  const sub = AccessibilityInfo.addEventListener('reduceTransparencyChanged', setReduce);
  return () => sub.remove();
}, []);

{reduce || !isGlassBackdropSupported
  ? <View style={[StyleSheet.absoluteFill, { backgroundColor: '#f2f2f7', borderRadius: 31 }]} />
  : <GlassBackdrop /* … */ />}
```

### Live blur on iOS

A bar floating over a scrolling page can't follow it with snapshots. With
`liveBlur` the backdrop puts a system blur underneath, tuned to `blurRadius`
and `saturation`, and shows the snapshot glass (refraction, magnification)
only while the content under it is still:

```tsx
<GlassBackdrop
  style={StyleSheet.absoluteFill}
  blurRadius={4}
  saturation={1.5}
  refractionHeight={24}
  refractionAmount={24}
  highlight={0.75}
  liveBlur
/>
```

Scrolling is detected from the `contentOffset` of scroll views inside the
sampled targets that overlap the backdrop. Each time the content settles,
the targets are re-snapshotted once (a full-target capture).

> **App Review note.** `liveBlur` replaces the filters of the backdrop layer
> inside a public `UIVisualEffectView` with Core Animation's `gaussianBlur`
> and `colorSaturate` filters, looked up at runtime. No private symbol is
> linked and nothing is called if the class is missing (it then stays the
> stock system blur), but these filters are not public API: weigh the
> App Store guideline 2.5.1 risk before shipping it. Other React Native blur
> libraries use the same technique.

## Platform notes

| | Android 12+ | iOS |
| --- | --- | --- |
| Sampling | Live: the target's RenderNode is drawn by the GPU every frame | Snapshot: the target is captured into a Metal texture when its content changes |
| Best for | Anything, including scrolling content | Content that changes rarely (tab bars, toolbars, controls) |
| Blur | `RenderEffect` | MetalPerformanceShaders Gaussian blur, computed once per snapshot |
| Refraction | AGSL `RuntimeShader` (API 33+) | Metal fragment shader |
| Several targets / `targetGroup`s | All drawn, in order | All drawn, in order (stacked into one texture first) |

**Why snapshots on iOS?** iOS has no public API to sample a live view tree
on the GPU (UIKit's own blur uses the private `CABackdropLayer`). Snapshots
keep everything public and App Store-safe, and are cheap for content that
changes only on interaction.

## Rules and limits

- A backdrop must **not** be a descendant of a target it samples: that would
  create a cyclic render tree. Such targets are skipped.
- On Android below API 31 nothing is drawn except `overlayColor`; check
  `isGlassBackdropSupported`. `refraction`, `saturation` and `highlight` need
  API 33+ (they run in the AGSL shader) and are ignored below it.
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
