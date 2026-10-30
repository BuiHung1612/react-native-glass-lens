#import "RNGlassTargetView.h"

#import <MetalKit/MetalKit.h>
#import <react/renderer/components/RNGlassLensSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNGlassLensSpec/Props.h>
#import <react/renderer/components/RNGlassLensSpec/RCTComponentViewHelpers.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

// A snapshot taken in the same frame as a content change can miss children
// that have not drawn yet, so wait this many display frames after a change.
static const NSInteger kSettleFrames = 2;

// renderInContext draws whatever contents a layer already has; a hidden
// subtree may never have been displayed, so display it first.
static void DisplayLayerTree(CALayer *layer)
{
  [layer displayIfNeeded];
  for (CALayer *sublayer in layer.sublayers) {
    DisplayLayerTree(sublayer);
  }
}

@interface RNGlassTargetView () <RCTRNGlassTargetViewViewProtocol>
@end

@implementation RNGlassTargetView {
  NSString *_group;
  id<MTLTexture> _texture;
  MTKTextureLoader *_loader;
  NSInteger _framesUntilSnapshot;
  CGSize _snapshotSize;
  CGFloat _requestedScale;
  BOOL _sampleOnly;
  // Offsets of the scroll views inside the target when the snapshot was taken.
  NSMapTable<UIScrollView *, NSValue *> *_snapshotOffsets;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RNGlassTargetViewComponentDescriptor>();
}

+ (NSHashTable<RNGlassTargetView *> *)attachedTargets
{
  static NSHashTable *targets;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    targets = [NSHashTable weakObjectsHashTable];
  });
  return targets;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNGlassTargetViewProps>();
    _props = defaultProps;
    _group = @"default";
    _framesUntilSnapshot = kSettleFrames;
  }
  return self;
}

- (NSString *)group
{
  return _group;
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &oldViewProps = *std::static_pointer_cast<RNGlassTargetViewProps const>(_props);
  const auto &newViewProps = *std::static_pointer_cast<RNGlassTargetViewProps const>(props);

  if (oldViewProps.group != newViewProps.group) {
    _group = [NSString stringWithUTF8String:newViewProps.group.c_str()];
  }
  if (oldViewProps.contentKey != newViewProps.contentKey) {
    [self markContentChanged];
  }
  if (oldViewProps.sampleOnly != newViewProps.sampleOnly) {
    _sampleOnly = newViewProps.sampleOnly;
    [self updateHidden];
    [self markContentChanged];
  }

  [super updateProps:props oldProps:oldProps];
}

- (void)updateLayoutMetrics:(LayoutMetrics const &)layoutMetrics
           oldLayoutMetrics:(LayoutMetrics const &)oldLayoutMetrics
{
  [super updateLayoutMetrics:layoutMetrics oldLayoutMetrics:oldLayoutMetrics];
  // super resets `hidden` from display: none.
  [self updateHidden];
}

// A hidden view also drops out of touches and accessibility, which is what a
// sample-only duplicate of visible content wants.
- (void)updateHidden
{
  self.hidden = _sampleOnly || _layoutMetrics.displayType == DisplayType::None;
}

- (void)mountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  [super mountChildComponentView:childComponentView index:index];
  [self markContentChanged];
}

- (void)unmountChildComponentView:(UIView<RCTComponentViewProtocol> *)childComponentView index:(NSInteger)index
{
  [super unmountChildComponentView:childComponentView index:index];
  [self markContentChanged];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  if (!CGSizeEqualToSize(self.bounds.size, _snapshotSize)) {
    [self markContentChanged];
  }
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  if (self.window != nil) {
    [[RNGlassTargetView attachedTargets] addObject:self];
    [self markContentChanged];
  } else {
    [[RNGlassTargetView attachedTargets] removeObject:self];
  }
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  _texture = nil;
  _snapshotSize = CGSizeZero;
  _snapshotScale = 0;
  _requestedScale = 0;
  _group = @"default";
  _sampleOnly = NO;
  _snapshotOffsets = nil;
  [self markContentChanged];
}

- (BOOL)isSampleable
{
  if (self.window == nil || (self.isHidden && !_sampleOnly)) {
    return NO;
  }
  // Inactive tab screens stay attached but hidden; skip them.
  float opacity = 1;
  for (UIView *view = self.superview; view != nil; view = view.superview) {
    if (view.isHidden) {
      return NO;
    }
    opacity *= view.layer.opacity;
  }
  return opacity > 0.01;
}

- (BOOL)hasScrolledSinceSnapshotInWindowRect:(CGRect)windowRect
{
  for (UIScrollView *scrollView in _snapshotOffsets) {
    if (scrollView.window == nil) {
      continue;
    }
    CGRect frame = [scrollView convertRect:scrollView.bounds toView:nil];
    if (!CGRectIntersectsRect(frame, windowRect)) {
      continue;
    }
    if (!CGPointEqualToPoint(scrollView.contentOffset, [_snapshotOffsets objectForKey:scrollView].CGPointValue)) {
      return YES;
    }
  }
  return NO;
}

static void CollectScrollOffsets(UIView *view, NSMapTable<UIScrollView *, NSValue *> *offsets)
{
  if ([view isKindOfClass:UIScrollView.class]) {
    [offsets setObject:[NSValue valueWithCGPoint:((UIScrollView *)view).contentOffset] forKey:(UIScrollView *)view];
  }
  for (UIView *subview in view.subviews) {
    CollectScrollOffsets(subview, offsets);
  }
}

- (void)markContentChanged
{
  _framesUntilSnapshot = kSettleFrames;
}

- (nullable id<MTLTexture>)textureWithDevice:(id<MTLDevice>)device scale:(CGFloat)scale
{
  _requestedScale = MAX(_requestedScale, scale);
  if (_framesUntilSnapshot > 0) {
    _framesUntilSnapshot--;
    if (_framesUntilSnapshot == 0 || _texture == nil) {
      [self snapshotWithDevice:device];
    }
  } else if (_texture != nil && scale > _snapshotScale && _snapshotScale < self.window.screen.scale) {
    // Content is settled but this backdrop needs more detail (e.g. its blur
    // shrank): re-take right away instead of waiting for a content change.
    [self snapshotWithDevice:device];
  }
  return _texture;
}

- (void)snapshotWithDevice:(id<MTLDevice>)device
{
  CGSize size = self.bounds.size;
  if (size.width < 1 || size.height < 1 || self.window == nil) {
    return;
  }

  UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
  CGFloat screenScale = self.window.screen.scale;
  format.scale = _requestedScale > 0 ? MIN(_requestedScale, screenScale) : screenScale;
  format.opaque = NO;
  format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    if (!self->_sampleOnly) {
      [self drawViewHierarchyInRect:CGRectMake(0, 0, size.width, size.height) afterScreenUpdates:NO];
      return;
    }
    // drawViewHierarchyInRect captures what is on screen, i.e. nothing for a
    // hidden view; render the children's layers instead (like Android, the
    // target's own background is not part of the sample).
    // ponytail: frame offset only, children with a transform render untransformed.
    CGContextRef cg = context.CGContext;
    for (CALayer *sublayer in self.layer.sublayers) {
      if (sublayer.hidden) {
        continue;
      }
      DisplayLayerTree(sublayer);
      CGContextSaveGState(cg);
      CGContextTranslateCTM(cg, sublayer.frame.origin.x, sublayer.frame.origin.y);
      [sublayer renderInContext:cg];
      CGContextRestoreGState(cg);
    }
  }];
  if (image.CGImage == nil) {
    return;
  }

  if (_loader == nil || _loader.device != device) {
    _loader = [[MTKTextureLoader alloc] initWithDevice:device];
  }
  NSError *error = nil;
  id<MTLTexture> texture = [_loader newTextureWithCGImage:image.CGImage
                                                  options:@{
                                                    MTKTextureLoaderOptionSRGB : @NO,
                                                    MTKTextureLoaderOptionTextureUsage : @(MTLTextureUsageShaderRead),
                                                  }
                                                    error:&error];
  if (texture == nil) {
    return;
  }
  _texture = texture;
  _snapshotSize = size;
  _snapshotScale = format.scale;
  _requestedScale = 0;
  _snapshotVersion++;
  // Scroll views mounted since the last snapshot are picked up here.
  _snapshotOffsets = [NSMapTable weakToStrongObjectsMapTable];
  CollectScrollOffsets(self, _snapshotOffsets);
}

@end

Class<RCTComponentViewProtocol> RNGlassTargetViewCls(void)
{
  return RNGlassTargetView.class;
}
