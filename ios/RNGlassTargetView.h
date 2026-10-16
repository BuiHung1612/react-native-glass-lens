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

/// Current snapshot, re-taken first if the content changed.
- (nullable id<MTLTexture>)textureWithDevice:(id<MTLDevice>)device;

@end

NS_ASSUME_NONNULL_END
