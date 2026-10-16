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
  /** Group of RNGlassTargetViews to sample. */
  targetGroup?: CodegenTypes.WithDefault<string, 'default'>;
  /** Scales the sampled content around the view center (lens). */
  magnification?: CodegenTypes.WithDefault<CodegenTypes.Float, 1>;
}

export default codegenNativeComponent<NativeProps>('RNGlassBackdropView');
