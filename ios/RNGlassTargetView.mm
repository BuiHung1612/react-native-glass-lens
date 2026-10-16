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

@interface RNGlassTargetView () <RCTRNGlassTargetViewViewProtocol>
@end

@implementation RNGlassTargetView {
  NSString *_group;
  id<MTLTexture> _texture;
  MTKTextureLoader *_loader;
  NSInteger _framesUntilSnapshot;
  CGSize _snapshotSize;
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

  [super updateProps:props oldProps:oldProps];
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
  _group = @"default";
  [self markContentChanged];
}

- (void)markContentChanged
{
  _framesUntilSnapshot = kSettleFrames;
}

- (nullable id<MTLTexture>)textureWithDevice:(id<MTLDevice>)device
{
  if (_framesUntilSnapshot > 0) {
    _framesUntilSnapshot--;
    if (_framesUntilSnapshot == 0 || _texture == nil) {
      [self snapshotWithDevice:device];
    }
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
  format.scale = self.window.screen.scale;
  format.opaque = NO;
  format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
  UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [self drawViewHierarchyInRect:CGRectMake(0, 0, size.width, size.height) afterScreenUpdates:NO];
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
  _snapshotVersion++;
}

@end

Class<RCTComponentViewProtocol> RNGlassTargetViewCls(void)
{
  return RNGlassTargetView.class;
}
