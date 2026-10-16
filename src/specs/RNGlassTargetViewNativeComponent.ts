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
}

export default codegenNativeComponent<NativeProps>('RNGlassTargetView');
