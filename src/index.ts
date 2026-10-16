import { Platform } from 'react-native';

export { default as GlassTarget } from './specs/RNGlassTargetViewNativeComponent';
export type { NativeProps as GlassTargetProps } from './specs/RNGlassTargetViewNativeComponent';
export { default as GlassBackdrop } from './specs/RNGlassBackdropViewNativeComponent';
export type { NativeProps as GlassBackdropProps } from './specs/RNGlassBackdropViewNativeComponent';

/**
 * Android samples targets live on the GPU (RenderEffect, API 31+).
 * iOS samples snapshots of targets with Metal (any supported version), so
 * targets there should hold content that changes rarely (see contentKey).
 */
export const isGlassBackdropSupported: boolean =
  Platform.OS === 'ios' ||
  (Platform.OS === 'android' && Platform.Version >= 31);
