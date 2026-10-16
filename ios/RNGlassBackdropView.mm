#import "RNGlassBackdropView.h"
#import "RNGlassTargetView.h"

#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <QuartzCore/QuartzCore.h>
#import <React/RCTConversions.h>
#import <react/renderer/components/RNGlassLensSpec/ComponentDescriptors.h>
#import <react/renderer/components/RNGlassLensSpec/Props.h>
#import <react/renderer/components/RNGlassLensSpec/RCTComponentViewHelpers.h>
#import <simd/simd.h>

#import "RCTFabricComponentsPlugins.h"

using namespace facebook::react;

// Same softened lens as the Android implementation (values in points).
static const float kRefractionHeight = 16;
static const float kRefractionOffset = 40;
static const float kDepthEffect = 0.3;
static const float kDispersion = 0.35;

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
  simd_float4 tint;
} GlassUniforms;

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
  float4 tint;
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

fragment half4 glassFragment(VertexOut in [[stage_in]],
                             constant GlassUniforms &u [[buffer(0)]],
                             texture2d<half> tex [[texture(0)]]) {
  float2 coord = in.position.xy / u.scale;
  float2 halfSize = u.viewSize * 0.5;
  float2 centered = coord - halfSize;
  float radius = min(u.cornerRadius, min(halfSize.x, halfSize.y));
  float sd = sdRoundedRect(centered, halfSize, radius);

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
  NSString *_targetGroup;
  simd_float4 _tint;

  // Last rendered state, to skip frames where nothing moved.
  BOOL _needsRender;
  BOOL _renderScheduled;
  id<MTLTexture> _lastSource;
  CGPoint _lastOrigin;
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
    _targetGroup = @"default";
    _tint = simd_make_float4(0, 0, 0, 0);
    _needsRender = YES;

    _device = MTLCreateSystemDefaultDevice();
    if (_device != nil) {
      _queue = [_device newCommandQueue];
      _pipeline = [RNGlassBackdropView pipelineForDevice:_device];
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

      MTLTextureDescriptor *descriptor =
          [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                             width:1
                                                            height:1
                                                         mipmapped:NO];
      _emptyTexture = [_device newTextureWithDescriptor:descriptor];
      const uint32_t clear = 0;
      [_emptyTexture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:&clear bytesPerRow:4];
    }
  }
  return self;
}

+ (id<MTLRenderPipelineState>)pipelineForDevice:(id<MTLDevice>)device
{
  static id<MTLRenderPipelineState> pipeline;
  static id<MTLDevice> pipelineDevice;
  if (pipeline != nil && pipelineDevice == device) {
    return pipeline;
  }
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
  pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
  pipelineDevice = device;
  if (pipeline == nil) {
    NSLog(@"[RNGlassBackdropView] Pipeline creation failed: %@", error);
  }
  return pipeline;
}

- (void)updateProps:(Props::Shared const &)props oldProps:(Props::Shared const &)oldProps
{
  const auto &newViewProps = *std::static_pointer_cast<RNGlassBackdropViewProps const>(props);

  _blurRadius = newViewProps.blurRadius;
  _cornerRadius = newViewProps.cornerRadius;
  _magnification = newViewProps.magnification > 0 ? newViewProps.magnification : 1;
  _refraction = newViewProps.refraction;
  _targetGroup = [NSString stringWithUTF8String:newViewProps.targetGroup.c_str()];

  UIColor *overlay = RCTUIColorFromSharedColor(newViewProps.overlayColor);
  CGFloat r = 0, g = 0, b = 0, a = 0;
  if (overlay != nil) {
    [overlay getRed:&r green:&g blue:&b alpha:&a];
  }
  _tint = simd_make_float4(r * a, g * a, b * a, a);

  _metalLayer.cornerRadius = _cornerRadius;
  _needsRender = YES;

  [super updateProps:props oldProps:oldProps];
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
  [CATransaction commit];
  _needsRender = YES;
}

- (void)didMoveToWindow
{
  [super didMoveToWindow];
  [_displayLink invalidate];
  _displayLink = nil;
  if (self.window != nil && _pipeline != nil) {
    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    _needsRender = YES;
  }
}

- (void)prepareForRecycle
{
  [super prepareForRecycle];
  _lastSource = nil;
  _blurredTexture = nil;
  _blurredSource = nil;
  _needsRender = YES;
}

- (RNGlassTargetView *)currentTarget
{
  for (RNGlassTargetView *target in [RNGlassTargetView attachedTargets]) {
    if (target.window == self.window && [target.group isEqualToString:_targetGroup] && ![self isDescendantOfView:target]) {
      return target;
    }
  }
  return nil;
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

- (void)render
{
  RNGlassTargetView *target = [self currentTarget];
  // Always pumped so pending snapshots settle while the backdrop is hidden.
  id<MTLTexture> source = [target textureWithDevice:_device];

  if (![self isEffectivelyVisible] || self.bounds.size.width < 1 || self.bounds.size.height < 1) {
    return;
  }

  CGPoint origin = target != nil ? [target convertPoint:CGPointZero toView:self] : CGPointZero;
  if (!_needsRender && source == _lastSource && CGPointEqualToPoint(origin, _lastOrigin)) {
    return;
  }

  id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
  if (drawable == nil) {
    return;
  }
  id<MTLCommandBuffer> commandBuffer = [_queue commandBuffer];
  id<MTLTexture> sampled = source != nil ? [self blurredTexture:source commandBuffer:commandBuffer] : _emptyTexture;

  CGFloat scale = _metalLayer.contentsScale;
  GlassUniforms uniforms = {
      .viewSize = simd_make_float2(self.bounds.size.width, self.bounds.size.height),
      .targetOrigin = simd_make_float2(origin.x, origin.y),
      .targetSize = simd_make_float2(MAX(target.bounds.size.width, 1), MAX(target.bounds.size.height, 1)),
      .magnification = (float)_magnification,
      .cornerRadius = (float)_cornerRadius,
      .refractionHeight = kRefractionHeight,
      .refractionAmount = -kRefractionOffset,
      .depthEffect = kDepthEffect,
      .chromaticAberration = kDispersion,
      .refraction = _refraction ? 1.0f : 0.0f,
      .scale = (float)scale,
      .tint = _tint,
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

  _lastSource = source;
  _lastOrigin = origin;
  _needsRender = NO;
}

// The target only changes when re-snapshotted, so its blur is computed once
// per snapshot instead of every frame.
- (id<MTLTexture>)blurredTexture:(id<MTLTexture>)source commandBuffer:(id<MTLCommandBuffer>)commandBuffer
{
  if (_blurRadius <= 0 || !MPSSupportsMTLDevice(_device)) {
    return source;
  }
  if (_blurredSource == source && _blurredRadius == _blurRadius && _blurredTexture != nil) {
    return _blurredTexture;
  }
  MTLTextureDescriptor *descriptor =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source.pixelFormat
                                                         width:source.width
                                                        height:source.height
                                                     mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
  id<MTLTexture> destination = [_device newTextureWithDescriptor:descriptor];
  // Same radius -> sigma mapping as Android's RenderEffect blur (Skia).
  float sigma = 0.57735f * _blurRadius * _metalLayer.contentsScale + 0.5f;
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
  [_displayLink invalidate];
}

@end

Class<RCTComponentViewProtocol> RNGlassBackdropViewCls(void)
{
  return RNGlassBackdropView.class;
}
