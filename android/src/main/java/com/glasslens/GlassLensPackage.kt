package com.glasslens

import android.graphics.Color
import com.facebook.react.ReactPackage
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.uimanager.PixelUtil
import com.facebook.react.uimanager.SimpleViewManager
import com.facebook.react.uimanager.ThemedReactContext
import com.facebook.react.uimanager.ViewManager
import com.facebook.react.uimanager.ViewManagerDelegate
import com.facebook.react.uimanager.annotations.ReactProp
import com.facebook.react.viewmanagers.RNGlassBackdropViewManagerDelegate
import com.facebook.react.viewmanagers.RNGlassBackdropViewManagerInterface
import com.facebook.react.views.view.ReactViewGroup
import com.facebook.react.views.view.ReactViewManager

class GlassLensPackage : ReactPackage {
  override fun createViewManagers(
    reactContext: ReactApplicationContext,
  ): List<ViewManager<*, *>> = listOf(GlassTargetViewManager(), GlassBackdropViewManager())
}

// Extends ReactViewManager so the wrapper keeps every regular View style prop.
class GlassTargetViewManager : ReactViewManager() {
  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): ReactViewGroup =
    GlassTargetView(context)

  @ReactProp(name = "group")
  fun setGroup(view: ReactViewGroup, value: String?) {
    (view as? GlassTargetView)?.group = value ?: GlassTargetView.DEFAULT_GROUP
  }

  // Android targets are sampled live; the snapshot key only matters on iOS.
  @ReactProp(name = "contentKey")
  fun setContentKey(view: ReactViewGroup, value: String?) = Unit

  companion object {
    const val NAME = "RNGlassTargetView"
  }
}

class GlassBackdropViewManager :
  SimpleViewManager<GlassBackdropView>(),
  RNGlassBackdropViewManagerInterface<GlassBackdropView> {

  private val delegate = RNGlassBackdropViewManagerDelegate(this)

  override fun getDelegate(): ViewManagerDelegate<GlassBackdropView> = delegate

  override fun getName(): String = NAME

  override fun createViewInstance(context: ThemedReactContext): GlassBackdropView =
    GlassBackdropView(context)

  override fun setBlurRadius(view: GlassBackdropView, value: Float) {
    view.blurRadius = PixelUtil.toPixelFromDIP(value)
  }

  override fun setCornerRadius(view: GlassBackdropView, value: Float) {
    view.cornerRadius = PixelUtil.toPixelFromDIP(value)
  }

  override fun setOverlayColor(view: GlassBackdropView, value: Int?) {
    view.overlayColor = value ?: Color.TRANSPARENT
  }

  override fun setRefraction(view: GlassBackdropView, value: Boolean) {
    view.refraction = value
  }

  override fun setTargetGroup(view: GlassBackdropView, value: String?) {
    view.targetGroup = value ?: GlassTargetView.DEFAULT_GROUP
  }

  override fun setMagnification(view: GlassBackdropView, value: Float) {
    view.magnification = value
  }

  companion object {
    const val NAME = "RNGlassBackdropView"
  }
}
