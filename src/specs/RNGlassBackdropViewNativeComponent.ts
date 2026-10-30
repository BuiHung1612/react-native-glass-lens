import { codegenNativeComponent } from 'react-native';
import type { CodegenTypes, ColorValue, ViewProps } from 'react-native';

export interface NativeProps extends ViewProps {
  /** Gaussian blur of the sampled content, in dp/pt. */
  blurRadius?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Corner radius used for clipping and the refraction lens shape. */
  cornerRadius?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Color painted over the sampled content. */
  overlayColor?: ColorValue;
  /** Liquid-glass edge refraction (Android 13+, iOS). */
  refraction?: CodegenTypes.WithDefault<boolean, true>;
  /** Width of the refracting band along the edge, in dp/pt. */
  refractionHeight?: CodegenTypes.WithDefault<CodegenTypes.Float, 16>;
  /** How far content is pulled inward at the edge, in dp/pt. */
  refractionAmount?: CodegenTypes.WithDefault<CodegenTypes.Float, 40>;
  /** Chromatic dispersion at the corners (0 = none). */
  dispersion?: CodegenTypes.WithDefault<CodegenTypes.Float, 0.35>;
  /** Saturation of the sampled content (1 = unchanged; Apple glass ≈ 1.5). */
  saturation?: CodegenTypes.WithDefault<CodegenTypes.Float, 1>;
  /** Intensity of the specular rim light along the edge (0 = off, 1 = full). */
  highlight?: CodegenTypes.WithDefault<CodegenTypes.Float, 0>;
  /** Where the rim light comes from, in degrees clockwise from the top (-45 = top-left). */
  lightAngle?: CodegenTypes.WithDefault<CodegenTypes.Float, -45>;
  /** Corner shape: plain circular arcs, or Apple's continuous (squircle) corners. */
  cornerCurve?: CodegenTypes.WithDefault<'circular' | 'continuous', 'circular'>;
  /**
   * Group of RNGlassTargetViews to sample. Android also accepts several,
   * comma-separated, drawn in order (later on top).
   */
  targetGroup?: CodegenTypes.WithDefault<string, 'default'>;
  /** Bulge of the refraction toward the center (0 = flat edge band, 1 = lens). */
  depth?: CodegenTypes.WithDefault<CodegenTypes.Float, 0.3>;
  /** Scales the sampled content around the view center (lens). */
  magnification?: CodegenTypes.WithDefault<CodegenTypes.Float, 1>;
  /**
   * Refraction, dispersion and highlight follow `pressed` through a native
   * spring: off while released, full while pressed.
   */
  interactive?: CodegenTypes.WithDefault<boolean, false>;
  /**
   * iOS: a live system blur (blurRadius, saturation) under the glass, so it
   * stays see-through while content scrolls; the snapshot-based refraction
   * fades in once the content is still. Android ignores it (always live).
   */
  liveBlur?: CodegenTypes.WithDefault<boolean, false>;
  /** Press state of an `interactive` backdrop; animated natively. */
  pressed?: CodegenTypes.WithDefault<boolean, false>;
}

export default codegenNativeComponent<NativeProps>('RNGlassBackdropView');
