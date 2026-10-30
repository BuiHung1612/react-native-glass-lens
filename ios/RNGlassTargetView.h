#import <React/RCTViewComponentView.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Content that RNGlassBackdropViews sample. iOS has no public API to sample
/// a live view tree on the GPU, so the target is snapshotted into a Metal
/// texture whenever its contentKey, children or size change.
@interface RNGlassTargetView : RCTViewComponentView

@property (nonatomic, readonly, copy) NSString *group;
/// Bumped every time a new snapshot is taken.
@property (nonatomic, readonly) NSUInteger snapshotVersion;

/// Attached targets, UI thread only.
+ (NSHashTable<RNGlassTargetView *> *)attachedTargets;

/// Whether backdrops can sample this target now: in a window, with no hidden
/// or transparent ancestor. A sampleOnly target counts despite being hidden.
@property (nonatomic, readonly) BOOL isSampleable;

/// Re-snapshots a couple of frames from now.
- (void)markContentChanged;

/// YES when a scroll view inside the target that overlaps `windowRect` has
/// scrolled since the last snapshot, i.e. the snapshot no longer matches the
/// screen there.
- (BOOL)hasScrolledSinceSnapshotInWindowRect:(CGRect)windowRect;

/// Pixels per point of the current snapshot.
@property (nonatomic, readonly) CGFloat snapshotScale;

/// Current snapshot, re-taken first if the content changed. `scale` is the
/// pixels per point the caller needs; the target snapshots at the largest
/// scale requested by its backdrops (capped at the screen scale), so heavily
/// blurred backdrops can share a cheap low-resolution snapshot.
- (nullable id<MTLTexture>)textureWithDevice:(id<MTLDevice>)device scale:(CGFloat)scale;

@end

NS_ASSUME_NONNULL_END
