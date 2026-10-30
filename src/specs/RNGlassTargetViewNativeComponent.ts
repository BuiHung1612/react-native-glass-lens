import { codegenNativeComponent } from 'react-native';
import type { CodegenTypes, ViewProps } from 'react-native';

export interface NativeProps extends ViewProps {
  /** Backdrops sample only targets whose group matches their targetGroup. */
  group?: CodegenTypes.WithDefault<string, 'default'>;
  /**
   * iOS snapshots targets instead of sampling them live; change this key
   * whenever the target's content changes so the snapshot is refreshed.
   * Android ignores it (targets are always live).
   */
  contentKey?: string;
  /**
   * Hides the target on screen while backdrops keep sampling it, e.g. the
   * active-colored copy of tab icons that only shows through a lens.
   */
  sampleOnly?: CodegenTypes.WithDefault<boolean, false>;
}

export default codegenNativeComponent<NativeProps>('RNGlassTargetView');
