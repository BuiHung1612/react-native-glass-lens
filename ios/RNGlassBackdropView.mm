#import "RNGlassBackdropView.h"
#import "RNGlassTargetView.h"

#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <react/renderer/components/RNGlassLensSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNGlassLensSpec/Props.h>
#import <react/renderer/components/RNGlassLensSpec/RCTComponentViewHelpers.h>
#import <objc/message.h>
#import <simd/simd.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

// Falloff of the rim light from the edge inward, in points.
static const float kHighlightWidth = 1.5;
// Blur radius, in snapshot pixels, that hides the upsampling of a snapshot
// taken below screen scale. Larger blurs get proportionally smaller snapshots.
static const CGFloat kMinBlurPixels = 8;
// Critically damped press spring (damping ratio 1, stiffness 1000).
static const float kPressStiffness = 1000;
static const float kPressDamping = 63.245553; // 2 * sqrt(stiffness)
// liveBlur: frames the sampled content must stay still before it is
// re-snapshotted, and how long the refreshed glass takes to fade in.
static const NSInteger kStillFrames = 6;
static const float kContentFadeDuration = 0.15;

// Core Animation's backdrop filters, looked up at runtime (the class is not
// public SDK). Same technique as UIKit-adjacent blur libraries: no private
// symbol is linked, and a missing class leaves the plain system blur.
static id CreateBackdropFilter(NSString *type)
{
  Class cls = NSClassFromString([@[ @"CA", @"Filter" ] componentsJoinedByString:@""]);
  SEL sel = NSSelectorFromString([@[ @"filter", @"WithType:" ] componentsJoinedByString:@""]);
  if (cls == nil || ![cls respondsToSelector:sel]) {
    return nil;
  }
  return ((id(*)(id, SEL, NSString *))objc_msgSend)(cls, sel, type);
}

typedef struct {
  simd_float2 viewSize;
  simd_float2 targetOrigin;
  simd_float2 targetSize;
  float magnification;
  float cornerRadius;
  float refractionHeight;
  float refractionAmount;
  float depthEffect;
  float chromaticAberration;
  float refraction;
  float scale;
  float saturation;
  float highlight;
  float highlightWidth;
  float continuousCorners;
  simd_float2 lightDir;
  simd_float4 tint;
  float contentOpacity;
} GlassUniforms;

typedef struct {
  simd_float2 origin;
  simd_float2 size;
  float scale;
} CompositeUniforms;

// Port of the AndroidLiquidGlassView AGSL shader (MIT, Copyright (c) 2025
// QmDeve, https://github.com/QmDeve/AndroidLiquidGlassView), compiled at
// runtime so the pod needs no .metal build step. Coordinates are in points.
static const char *const kShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct GlassUniforms {
  float2 viewSize;
  float2 targetOrigin;
  float2 targetSize;
  float magnification;
  float cornerRadius;
  float refractionHeight;
  float refractionAmount;
  float depthEffect;
  float chromaticAberration;
  float refraction;
  float scale;
  float saturation;
  float highlight;
  float highlightWidth;
  float continuousCorners;
  float2 lightDir;
  float4 tint;
  float contentOpacity;
};

struct VertexOut {
  float4 position [[position]];
};

vertex VertexOut glassVertex(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);
  VertexOut out;
  out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
  return out;
}

static half4 contentAt(float2 p, constant GlassUniforms &u, texture2d<half> tex) {
  constexpr sampler s(address::clamp_to_zero, filter::linear);
  float2 center = u.viewSize * 0.5;
  float2 q = (p - center) / u.magnification + center - u.targetOrigin;
  return tex.sample(s, q / u.targetSize);
}

static float sdRoundedRect(float2 coord, float2 halfSize, float radius) {
  float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
  float outside = length(max(cornerCoord, 0.0)) - radius;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

// Superellipse corners approximating CALayer's continuous curve: the curve
// spans 1.528 r, and its exponent keeps the 45-degree point on the circular
// arc, so a capsule degrades to plain circles.
static float sdSquircle(float2 coord, float2 halfSize, float radius) {
  float big = min(1.528 * radius, min(halfSize.x, halfSize.y));
  float n = radius > 0.0 ? M_LN2_F / -log(1.0 - 0.2929 * min(radius, big) / big) : 2.0;
  float2 cornerCoord = abs(coord) - (halfSize - float2(big));
  float2 o = max(cornerCoord, 0.0);
  float outside = pow(pow(o.x, n) + pow(o.y, n), 1.0 / n) - big;
  float inside = min(max(cornerCoord.x, cornerCoord.y), 0.0);
  return outside + inside;
}

static float safeSign(float value) {
  return value < 0.0 ? -1.0 : 1.0;
}

static float2 safeNormalize(float2 value, float2 fallback) {
  float len = length(value);
  return len > 0.001 ? value / len : fallback;
}

static float2 gradSdRoundedRect(float2 coord, float2 halfSize, float radius) {
  float2 cornerCoord = abs(coord) - (halfSize - float2(radius));
  if (cornerCoord.x >= 0.0 || cornerCoord.y >= 0.0) {
    float2 outside = max(cornerCoord, 0.0);
    float outsideLength = length(outside);
    if (outsideLength > 0.001) {
      return sign(coord) * (outside / outsideLength);
    }
    float useX = step(cornerCoord.y, cornerCoord.x);
    return float2(useX * safeSign(coord.x), (1.0 - useX) * safeSign(coord.y));
  }
  float gradX = step(cornerCoord.y, cornerCoord.x);
  return sign(coord) * float2(gradX, 1.0 - gradX);
}

static float circleMap(float x) {
  return 1.0 - sqrt(1.0 - x * x);
}

struct CompositeUniforms {
  float2 origin;
  float2 size;
  float scale;
};

// Draws one target snapshot at its place in a view-sized texture; blended
// source-over (premultiplied) so several targets stack in order.
fragment half4 compositeFragment(VertexOut in [[stage_in]],
                                 constant CompositeUniforms &u [[buffer(0)]],
                                 texture2d<half> tex [[texture(0)]]) {
  constexpr sampler s(address::clamp_to_zero, filter::linear);
  float2 p = in.position.xy / u.scale - u.origin;
  return tex.sample(s, p / u.size);
}

fragment half4 glassFragment(VertexOut in [[stage_in]],
                             constant GlassUniforms &u [[buffer(0)]],
                             texture2d<half> tex [[texture(0)]]) {
  float2 coord = in.position.xy / u.scale;
  float2 halfSize = u.viewSize * 0.5;
  float2 centered = coord - halfSize;
  float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
  float sd = u.continuousCorners > 0.5 ? sdSquircle(centered, halfSize, radius)
                                       : sdRoundedRect(centered, halfSize, radius);

  half4 color;
  if (u.refraction < 0.5 || -sd >= u.refractionHeight) {
    color = contentAt(coord, u, tex);
  } else {
    sd = min(sd, 0.0);
    float d = circleMap(1.0 - -sd / u.refractionHeight) * u.refractionAmount;
    float smoothRadius = max(radius * 1.5, 30.0 / u.scale);
    float gradRadius = min(smoothRadius, min(halfSize.x, halfSize.y));

    float2 shapeGrad = gradSdRoundedRect(centered, halfSize, gradRadius);
    float2 depthGrad = safeNormalize(centered, shapeGrad);
    float2 grad = safeNormalize(shapeGrad + u.depthEffect * depthGrad, shapeGrad);

    float2 refracted = coord + d * grad;
    float dispersion = u.chromaticAberration * ((centered.x * centered.y) / (halfSize.x * halfSize.y));
    float2 dispersed = d * grad * dispersion;

    color = half4(0.0);
    if (u.chromaticAberration <= 0.0) {
      // No dispersion: one sample instead of seven.
      color = contentAt(refracted, u, tex);
    } else {
    half4 red = contentAt(refracted + dispersed, u, tex);
    color.r += red.r / 3.5h;
    color.a += red.a / 7.0h;
    half4 orange = contentAt(refracted + dispersed * (2.0 / 3.0), u, tex);
    color.r += orange.r / 3.5h;
    color.g += orange.g / 7.0h;
    color.a += orange.a / 7.0h;
    half4 yellow = contentAt(refracted + dispersed * (1.0 / 3.0), u, tex);
    color.r += yellow.r / 3.5h;
    color.g += yellow.g / 3.5h;
    color.a += yellow.a / 7.0h;
    half4 green = contentAt(refracted, u, tex);
    color.g += green.g / 3.5h;
    color.a += green.a / 7.0h;
    half4 cyan = contentAt(refracted - dispersed * (1.0 / 3.0), u, tex);
    color.g += cyan.g / 3.5h;
    color.b += cyan.b / 3.0h;
    color.a += cyan.a / 7.0h;
    half4 blue = contentAt(refracted - dispersed * (2.0 / 3.0), u, tex);
    color.b += blue.b / 3.0h;
    color.a += blue.a / 7.0h;
    half4 purple = contentAt(refracted - dispersed, u, tex);
    color.r += purple.r / 7.0h;
    color.b += purple.b / 3.0h;
    color.a += purple.a / 7.0h;
    }
  }

  // liveBlur shows the system blur underneath while the sampled content is
  // stale; the rim light and tint below stay.
  color *= half(u.contentOpacity);

  // Vibrancy: done in sRGB, which is close enough and skips the pow()s.
  if (u.saturation != 1.0) {
    half luma = dot(color.rgb, half3(0.2126h, 0.7152h, 0.0722h));
    color.rgb = clamp(mix(half3(luma), color.rgb, half3(u.saturation)), half3(0.0h), half3(color.a));
  }

  // Rim light: a sharp stroke plus a soft inner bloom, screened in. The edge
  // facing the light gets the full light, the opposite edge a weaker bounce
  // light, the sides only ambient.
  if (u.highlight > 0.0 && -sd < u.highlightWidth * 18.0) {
    float inset = max(-sd, 0.0);
    float rim = exp(-inset / u.highlightWidth) + 0.35 * exp(-inset / (u.highlightWidth * 3.0));
    float2 normal = gradSdRoundedRect(centered, halfSize, radius);
    float facing = dot(normal, u.lightDir);
    float light = 0.15 + max(facing, 0.0) + 0.4 * max(-facing, 0.0);
    float k = clamp(u.highlight * rim * light, 0.0, 1.0);
    color += (1.0h - color) * half(k);
  }

  // Premultiplied source-over of the overlay color.
  half4 tint = half4(u.tint);
  return tint + color * (1.0h - tint.a);
}
)METAL";

@interface RNGlassBackdropView () <RCTRNGlassBackdropViewViewProtocol>
@end

@implementation RNGlassBackdropView {
  CAMetalLayer *_metalLayer;
  id<MTLDevice> _device;
  id<MTLCommandQueue> _queue;
  id<MTLRenderPipelineState> _pipeline;
  id<MTLTexture> _emptyTexture;
  CADisplayLink *_displayLink;

  CGFloat _blurRadius;
  CGFloat _cornerRadius;
  CGFloat _magnification;
  BOOL _refraction;
  float _refractionHeight;
  float _refractionAmount;
  float _dispersion;
  float _saturation;
  float _highlight;
  simd_float2 _lightDir;
  BOOL _continuousCorners;
  NSArray<NSString *> *_targetGroups;
  simd_float4 _tint;
  float _depth;
  BOOL _liveBlur;
  UIVisualEffectView *_liveBlurView;
  float _contentOpacity;
  BOOL _contentVisible;
  BOOL _snapshotRequested;
  NSUInteger _requestedVersion;
  NSInteger _stillFrames;
  BOOL _interactive;
  BOOL _pressed;
  float _pressProgress;
  float _pressVelocity;

  // Last rendered state, to skip frames where nothing moved.
  BOOL _needsRender;
  BOOL _renderScheduled;
  NSArray<id<MTLTexture>> *_lastSources;
  NSArray<NSValue *> *_lastOrigins;
  id<MTLRenderPipelineState> _compositePipeline;
  id<MTLTexture> _compositeTexture;
  id<MTLTexture> _blurredTexture;
  id<MTLTexture> _blurredSource;
  CGFloat _blurredRadius;
}

+ (ComponentDescriptorProvider)componentDescriptorProvider
{
  return concreteComponentDescriptorProvider<RNGlassBackdropViewComponentDescriptor>();
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if (self = [super initWithFrame:frame]) {
    static const auto defaultProps = std::make_shared<const RNGlassBackdropViewProps>();
    _props = defaultProps;

    _magnification = 1;
    _refraction = YES;
    _refractionHeight = 16;
    _refractionAmount = 40;
    _dispersion = 0.35;
    _saturation = 1;
    _lightDir = simd_make_float2(-M_SQRT1_2, -M_SQRT1_2);
    _targetGroups = @[ @"default" ];
    _depth = 0.3;
    _tint = simd_make_float4(0, 0, 0, 0);
    _needsRender = YES;

    // One queue / empty texture for every backdrop: queues are heavyweight,
    // and a shared queue keeps all backdrops' GPU work in submission order.
    static id<MTLDevice> sharedDevice;
    static id<MTLCommandQueue> sharedQueue;
    static id<MTLTexture> sharedEmptyTexture;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      sharedDevice = MTLCreateSystemDefaultDevice();
      sharedQueue = [sharedDevice newCommandQueue];
      MTLTextureDescriptor *descriptor =
          [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                             width:1
                                                            height:1
                                                         mipmapped:NO];
      sharedEmptyTexture = [sharedDevice newTextureWithDescriptor:descriptor];
      const uint32_t clear = 0;
      [sharedEmptyTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&clear bytesPerRow:4];
    });
    _device = sharedDevice;
    if (_device != nil) {
      _queue = sharedQueue;
      _emptyTexture = sharedEmptyTexture;
      _pipeline = [RNGlassBackdropView pipelineForDevice:_device composite:NO];
      _compositePipeline = [RNGlassBackdropView pipelineForDevice:_device composite:YES];
      _metalLayer = [CAMetalLayer layer];
      _metalLayer.device = _device;
      _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
      _metalLayer.framebufferOnly = YES;
      _metalLayer.opaque = NO;
      _metalLayer.masksToBounds = YES;
      // Present in the same Core Animation transaction as the layout /
      // transform changes that moved this view, so content never lags it.
      _metalLayer.presentsWithTransaction = YES;
      [self.layer addSublayer:_metalLayer];
    }
  }
  return self;
}

// `composite` picks the pass that stacks several target snapshots into one
// texture; otherwise the glass pass. Both come from one compiled library.
+ (id<MTLRenderPipelineState>)pipelineForDevice:(id<MTLDevice>)device composite:(BOOL)composite
{
  static id<MTLRenderPipelineState> glassPipeline;
  static id<MTLRenderPipelineState> compositePipeline;
  static id<MTLDevice> pipelineDevice;
  if (pipelineDevice != device) {
    pipelineDevice = device;
    glassPipeline = nil;
    compositePipeline = nil;
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSource] options:nil error:&error];
    if (library == nil) {
      NSLog(@"[RNGlassBackdropView] Shader compile failed: %@", error);
      return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"glassVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"glassFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    glassPipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (glassPipeline == nil) {
      NSLog(@"[RNGlassBackdropView] Pipeline creation failed: %@", error);
    }
    descriptor.fragmentFunction = [library newFunctionWithName:@"compositeFragment"];
    MTLRenderPipelineColorAttachmentDescriptor *attachment = descriptor.colorAttachments[0];
    attachment.blendingEnabled = YES;
    attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
    attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
    attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    compositePipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (compositePipeline == nil) {
      NSLog(@"[RNGlassBackdropView] Composite pipeline creation failed: %@", error);
    }
  }
  return composite ? compositePipeline : glassPipeline;
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &newViewProps = *std::static_pointer_cast<RNGlassBackdropViewProps const>(props);

  _blurRadius = newViewProps.blurRadius;
  _cornerRadius = newViewProps.cornerRadius;
  _magnification = newViewProps.magnification > 0 ? newViewProps.magnification : 1;
  _refraction = newViewProps.refraction;
  _refractionHeight = newViewProps.refractionHeight;
  _refractionAmount = newViewProps.refractionAmount;
  _dispersion = newViewProps.dispersion;
  _saturation = newViewProps.saturation;
  _highlight = newViewProps.highlight;
  float angle = newViewProps.lightAngle * M_PI / 180;
  _lightDir = simd_make_float2(sinf(angle), -cosf(angle));
  _continuousCorners = newViewProps.cornerCurve == RNGlassBackdropViewCornerCurve::Continuous;
  NSMutableArray<NSString *> *groups = [NSMutableArray new];
  for (NSString *group in [[NSString stringWithUTF8String:newViewProps.targetGroup.c_str()] componentsSeparatedByString:@","]) {
    NSString *trimmed = [group stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length > 0) {
      [groups addObject:trimmed];
    }
  }
  _targetGroups = groups;
  _depth = newViewProps.depth;
  _interactive = newViewProps.interactive;
  if (_interactive && newViewProps.pressed && !_pressed) {
    // Snapshots go stale while content scrolls; a press is when the lens is
    // about to show, so refresh what it samples (one capture per target).
    for (RNGlassTargetView *target in [self currentTargets]) {
      [target markContentChanged];
    }
  }
  _pressed = newViewProps.pressed;
  if (self.window == nil) {
    // Press changes while detached are not animated.
    _pressProgress = _pressed ? 1 : 0;
    _pressVelocity = 0;
  }

  UIColor *overlay = RCTUIColorFromSharedColor(newViewProps.overlayColor);
  CGFloat r = 0, g = 0, b = 0, a = 0;
  if (overlay != nil) {
    [overlay getRed:&r green:&g blue:&b alpha:&a];
  }
  _tint = simd_make_float4(r * a, g * a, b * a, a);

  _metalLayer.cornerRadius = _cornerRadius;
  _metalLayer.cornerCurve = _continuousCorners ? kCACornerCurveContinuous : kCACornerCurveCircular;
  [self setLiveBlur:newViewProps.liveBlur];
  _needsRender = YES;

  [super updateProps:props oldProps:oldProps];
}

// A system blur under the Metal layer keeps the glass see-through while the
// content scrolls (snapshots can't follow it); the snapshot-based glass is
// faded in on top once the content is still.
- (void)setLiveBlur:(BOOL)liveBlur
{
  if (liveBlur != _liveBlur) {
    _liveBlur = liveBlur;
    _contentVisible = NO;
    _contentOpacity = 0;
    _snapshotRequested = NO;
    _stillFrames = 0;
    if (liveBlur) {
      _liveBlurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleLight]];
      _liveBlurView.userInteractionEnabled = NO;
      _liveBlurView.clipsToBounds = YES;
      _liveBlurView.frame = self.bounds;
      [self insertSubview:_liveBlurView atIndex:0];
      [self.layer insertSublayer:_metalLayer above:_liveBlurView.layer];
    } else {
      [_liveBlurView removeFromSuperview];
      _liveBlurView = nil;
    }
  }
  if (_liveBlurView != nil) {
    _liveBlurView.layer.cornerRadius = _cornerRadius;
    _liveBlurView.layer.cornerCurve = _metalLayer.cornerCurve;
    [self applyLiveBlurFilters];
  }
}

// Replaces the effect view's stock blur + tint with a plain blur of
// blurRadius and a saturation boost. UIKit can reset the filters (layout,
// trait or app-state changes), so this is re-applied from those hooks.
- (void)applyLiveBlurFilters
{
  UIView *backdrop = _liveBlurView.subviews.firstObject;
  id blur = CreateBackdropFilter(@"gaussianBlur");
  if (backdrop == nil || blur == nil) {
    return; // stays the stock system blur
  }
  [blur setValue:@(_blurRadius) forKey:@"inputRadius"];
  [blur setValue:@YES forKey:@"inputNormalizeEdges"];
  NSMutableArray *filters = [NSMutableArray arrayWithObject:blur];
  id saturate = CreateBackdropFilter(@"colorSaturate");
  if (saturate != nil && _saturation != 1) {
    [saturate setValue:@(_saturation) forKey:@"inputAmount"];
    [filters addObject:saturate];
  }
  backdrop.layer.filters = filters;
  for (UIView *overlay in _liveBlurView.subviews) {
    if (overlay != backdrop) {
      overlay.alpha = 0;
    }
  }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection
{
  [super traitCollectionDidChange:previousTraitCollection];
  [self applyLiveBlurFilters];
}

- (void)applicationDidBecomeActive
{
  [self applyLiveBlurFilters];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  CGFloat scale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _metalLayer.frame = self.bounds;
  _metalLayer.contentsScale = scale;
  _metalLayer.drawableSize = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
  _liveBlurView.frame = self.bounds;
  [CATransaction commit];
  [self applyLiveBlurFilters];
  _needsRender = YES;
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  [_displayLink invalidate];
  _displayLink = nil;
  [NSNotificationCenter.defaultCenter removeObserver:self
                                                name:UIApplicationDidBecomeActiveNotification
                                              object:nil];
  if (self.window != nil) {
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(applicationDidBecomeActive)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
    [self applyLiveBlurFilters];
  }
  if (self.window != nil && _pipeline != nil) {
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _needsRender = YES;
  }
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  _lastSources = nil;
  _lastOrigins = nil;
  _compositeTexture = nil;
  _blurredTexture = nil;
  _blurredSource = nil;
  _needsRender = YES;
}

// Every visible target of every group, in group order (later on top).
- (NSArray<RNGlassTargetView *> *)currentTargets
{
  NSMutableArray<RNGlassTargetView *> *targets = [NSMutableArray new];
  for (NSString *group in _targetGroups) {
    for (RNGlassTargetView *target in [RNGlassTargetView attachedTargets]) {
      if (target.window == self.window && [target.group isEqualToString:group] && target.isSampleable &&
          ![self isDescendantOfView:target]) {
        [targets addObject:target];
      }
    }
  }
  return targets;
}

// Reanimated drives opacity through layer.opacity; skip GPU work while the
// view (e.g. a lens faded out) cannot be seen.
- (BOOL)isEffectivelyVisible
{
  float opacity = 1;
  for (UIView *view = self; view != nil; view = view.superview) {
    if (view.isHidden) {
      return NO;
    }
    opacity *= view.layer.opacity;
  }
  return opacity > 0.01;
}

// Display-link callbacks (ours and Reanimated's) run in arbitrary order, so
// the actual render is deferred to the end of this run-loop pass: after every
// animation has moved its views, before Core Animation commits the frame.
- (void)tick
{
  [self stepPress];
  [self stepLiveContent];
  if (_renderScheduled) {
    return;
  }
  _renderScheduled = YES;
  __weak RNGlassBackdropView *weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    RNGlassBackdropView *strongSelf = weakSelf;
    if (strongSelf != nil) {
      strongSelf->_renderScheduled = NO;
      [strongSelf render];
    }
  });
}

// liveBlur: hide the snapshot glass as soon as content under this view
// scrolls, re-snapshot once it has been still for kStillFrames, then fade the
// refreshed glass back in.
- (void)stepLiveContent
{
  if (!_liveBlur) {
    return;
  }
  NSArray<RNGlassTargetView *> *targets = [self currentTargets];
  CGRect windowRect = [self convertRect:self.bounds toView:nil];
  BOOL moved = NO;
  NSUInteger version = 0;
  for (RNGlassTargetView *target in targets) {
    moved = moved || [target hasScrolledSinceSnapshotInWindowRect:windowRect];
    version += target.snapshotVersion;
  }
  if (moved) {
    _stillFrames = 0;
    _snapshotRequested = NO;
    if (_contentVisible || _contentOpacity > 0) {
      _contentVisible = NO;
      _contentOpacity = 0;
      _needsRender = YES;
    }
    return;
  }
  if (!_contentVisible) {
    if (!_snapshotRequested && ++_stillFrames >= kStillFrames) {
      for (RNGlassTargetView *target in targets) {
        [target markContentChanged];
      }
      _snapshotRequested = YES;
      _requestedVersion = version;
    } else if (_snapshotRequested && version != _requestedVersion) {
      _contentVisible = YES;
    }
  }
  if (_contentVisible && _contentOpacity < 1) {
    float dt = MAX(_displayLink.targetTimestamp - _displayLink.timestamp, 1.0 / 120);
    _contentOpacity = MIN(_contentOpacity + dt / kContentFadeDuration, 1);
    _needsRender = YES;
  }
}

// Animated on the display link so JS sends one prop per press instead of
// one per frame.
- (void)stepPress
{
  float target = _pressed ? 1 : 0;
  if (_pressProgress == target && _pressVelocity == 0) {
    return;
  }
  float dt = MIN(MAX(_displayLink.targetTimestamp - _displayLink.timestamp, 0), 1.0 / 30);
  // Semi-implicit Euler in small substeps stays stable at any frame rate.
  for (float remaining = dt; remaining > 0; remaining -= 1.0f / 240) {
    float h = MIN(remaining, 1.0f / 240);
    _pressVelocity += (kPressStiffness * (target - _pressProgress) - kPressDamping * _pressVelocity) * h;
    _pressProgress += _pressVelocity * h;
  }
  if (fabsf(target - _pressProgress) < 0.001f && fabsf(_pressVelocity) < 0.01f) {
    _pressProgress = target;
    _pressVelocity = 0;
  }
  if (_interactive) {
    _needsRender = YES;
  }
}

- (void)render
{
  // Always pumped so pending snapshots settle while the backdrop is hidden.
  CGFloat neededScale = [self neededSnapshotScale];
  NSMutableArray<RNGlassTargetView *> *targets = [NSMutableArray new];
  NSMutableArray<id<MTLTexture>> *sources = [NSMutableArray new];
  for (RNGlassTargetView *target in [self currentTargets]) {
    id<MTLTexture> texture = [target textureWithDevice:_device scale:neededScale];
    if (texture != nil) {
      [targets addObject:target];
      [sources addObject:texture];
    }
  }

  if (![self isEffectivelyVisible] || self.bounds.size.width < 1 || self.bounds.size.height < 1) {
    return;
  }

  NSMutableArray<NSValue *> *origins = [NSMutableArray new];
  for (RNGlassTargetView *target in targets) {
    [origins addObject:[NSValue valueWithCGPoint:[target convertPoint:CGPointZero toView:self]]];
  }
  if (!_needsRender && [sources isEqualToArray:_lastSources ?: @[]] && [origins isEqualToArray:_lastOrigins ?: @[]]) {
    return;
  }

  id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
  if (drawable == nil) {
    return;
  }
  id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
  CGFloat scale = _metalLayer.contentsScale;

  // One target is sampled directly; several are stacked into a view-sized
  // texture first, which the glass pass then samples like a single target.
  id<MTLTexture> sampled = _emptyTexture;
  CGPoint origin = CGPointZero;
  CGSize targetSize = self.bounds.size;
  if (targets.count == 1) {
    sampled = [self blurredTexture:sources[0] scale:targets[0].snapshotScale commandBuffer:commandBuffer];
    origin = origins[0].CGPointValue;
    targetSize = targets[0].bounds.size;
  } else if (targets.count > 1) {
    id<MTLTexture> composite = [self compositeSources:sources
                                              targets:targets
                                              origins:origins
                                                scale:scale
                                        commandBuffer:commandBuffer];
    if (composite != nil) {
      _blurredSource = nil; // same texture object, new content
      sampled = [self blurredTexture:composite scale:scale commandBuffer:commandBuffer];
    }
  }
  float press = _interactive ? MAX(_pressProgress, 0) : 1;
  GlassUniforms uniforms = {
      .viewSize = simd_make_float2(self.bounds.size.width, self.bounds.size.height),
      .targetOrigin = simd_make_float2(origin.x, origin.y),
      .targetSize = simd_make_float2(MAX(targetSize.width, 1), MAX(targetSize.height, 1)),
      .magnification = (float)_magnification,
      .cornerRadius = (float)_cornerRadius,
      .refractionHeight = _refractionHeight * press,
      .refractionAmount = -_refractionAmount * press,
      .depthEffect = _depth,
      .chromaticAberration = _dispersion * press,
      .refraction = _refraction && _refractionHeight * press > 0 ? 1.0f : 0.0f,
      .scale = (float)scale,
      .saturation = _saturation,
      .highlight = _highlight * press,
      .highlightWidth = kHighlightWidth,
      .continuousCorners = _continuousCorners ? 1.0f : 0.0f,
      .lightDir = _lightDir,
      .tint = _tint,
      .contentOpacity = _liveBlur ? _contentOpacity : 1.0f,
  };

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;

  id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:_pipeline];
  [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
  [encoder setFragmentTexture:sampled atIndex:0];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [encoder endEncoding];
  [commandBuffer commit];
  // Required by presentsWithTransaction: present after scheduling, on the
  // main thread, inside the current transaction.
  [commandBuffer waitUntilScheduled];
  [drawable present];

  _lastSources = sources;
  _lastOrigins = origins;
  _needsRender = NO;
}

- (nullable id<MTLTexture>)compositeSources:(NSArray<id<MTLTexture>> *)sources
                                    targets:(NSArray<RNGlassTargetView *> *)targets
                                    origins:(NSArray<NSValue *> *)origins
                                      scale:(CGFloat)scale
                              commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
  if (_compositePipeline == nil) {
    return nil;
  }
  NSUInteger width = MAX((NSUInteger)ceil(self.bounds.size.width * scale), 1);
  NSUInteger height = MAX((NSUInteger)ceil(self.bounds.size.height * scale), 1);
  if (_compositeTexture == nil || _compositeTexture.width != width || _compositeTexture.height != height) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    _compositeTexture = [_device newTextureWithDescriptor:descriptor];
  }

  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = _compositeTexture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
  [encoder setRenderPipelineState:_compositePipeline];
  for (NSUInteger i = 0; i < sources.count; i++) {
    CGPoint origin = origins[i].CGPointValue;
    CGSize size = targets[i].bounds.size;
    CompositeUniforms uniforms = {
        .origin = simd_make_float2(origin.x, origin.y),
        .size = simd_make_float2(MAX(size.width, 1), MAX(size.height, 1)),
        .scale = (float)scale,
    };
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:sources[i] atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  }
  [encoder endEncoding];
  return _compositeTexture;
}

- (CGFloat)neededSnapshotScale
{
  CGFloat screenScale = self.window.screen.scale ?: UIScreen.mainScreen.scale;
  if (_blurRadius <= 0 || !MPSSupportsMTLDevice(_device)) {
    return screenScale;
  }
  return MIN(screenScale, kMinBlurPixels / _blurRadius);
}

// The target only changes when re-snapshotted, so its blur is computed once
// per snapshot instead of every frame. `scale` is the snapshot's pixels per point.
- (id<MTLTexture>)blurredTexture:(id<MTLTexture>)source
                           scale:(CGFloat)scale
                   commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
  if (_blurRadius <= 0 || !MPSSupportsMTLDevice(_device)) {
    return source;
  }
  if (_blurredSource == source && _blurredRadius == _blurRadius && _blurredTexture != nil) {
    return _blurredTexture;
  }
  // Same-size snapshots reuse the previous output: the shared queue runs this
  // blur after every earlier frame that sampled it.
  id<MTLTexture> destination = _blurredTexture;
  if (destination == nil || destination.width != source.width || destination.height != source.height ||
      destination.pixelFormat != source.pixelFormat) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                           width:source.width
                                                          height:source.height
                                                       mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    descriptor.storageMode = MTLStorageModePrivate;
    destination = [_device newTextureWithDescriptor:descriptor];
  }
  // Same radius -> sigma mapping as Android's RenderEffect blur (Skia).
  float sigma = 0.57735f * _blurRadius * scale + 0.5f;
  MPSImageGaussianBlur *blur = [[MPSImageGaussianBlur alloc] initWithDevice:_device sigma:sigma];
  blur.edgeMode = MPSImageEdgeModeClamp;
  [blur encodeToCommandBuffer:commandBuffer sourceTexture:source destinationTexture:destination];

  _blurredTexture = destination;
  _blurredSource = source;
  _blurredRadius = _blurRadius;
  return destination;
}

- (void)dealloc
{
  [NSNotificationCenter.defaultCenter removeObserver:self];
  [_displayLink invalidate];
}

@end

Class<RCTComponentViewProtocol> RNGlassBackdropViewCls(void)
{
  return RNGlassBackdropView.class;
}
