package com.glasslens

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Outline
import android.graphics.Path
import android.graphics.RenderEffect
import android.graphics.RenderNode
import android.graphics.RuntimeShader
import android.graphics.Shader
import android.os.Build
import android.view.View
import android.view.ViewOutlineProvider
import android.view.ViewTreeObserver
import androidx.annotation.RequiresApi
import com.facebook.react.uimanager.PixelUtil
import com.glasslens.R
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.pow
import kotlin.math.sin
import kotlin.properties.Delegates

/**
 * GPU glass: draws the live RenderNodes of every visible [GlassTargetView]
 * behind this view, through a blur (API 31+) and the liquid-glass
 * refraction shader (API 33+). Below API 31 it only paints [overlayColor];
 * JS renders a CPU blur fallback there instead.
 */
class GlassBackdropView(context: Context) : View(context) {

  var blurRadius = 0f
    set(value) {
      field = value
      effectDirty = true
      invalidate()
    }

  var cornerRadius = 0f
    set(value) {
      field = value
      effectDirty = true
      invalidateOutline()
      invalidate()
    }

  var overlayColor = Color.TRANSPARENT
    set(value) {
      field = value
      invalidate()
    }

  var targetGroup = GlassTargetView.DEFAULT_GROUP
    set(value) {
      field = value
      invalidate()
    }

  /** Scales the sampled content around this view's center (lens effect). */
  var magnification = 1f
    set(value) {
      field = value
      invalidate()
    }

  var refraction = true
    set(value) {
      field = value
      effectDirty = true
      invalidate()
    }

  // Shader-only settings (API 33+); changing one rebuilds the effect.
  var refractionHeight by effectProp(PixelUtil.toPixelFromDIP(16f))
  var refractionAmount by effectProp(PixelUtil.toPixelFromDIP(40f))
  var dispersion by effectProp(0.35f)
  var saturation by effectProp(1f)
  var highlight by effectProp(0f)
  var lightAngle by effectProp(-45f)

  /** Apple-style continuous corners; the clip follows them on API 33+. */
  var continuousCorners = false
    set(value) {
      field = value
      effectDirty = true
      invalidateOutline()
      invalidate()
    }

  private fun <T> effectProp(initial: T) = Delegates.observable(initial) { _, _, _ ->
    effectDirty = true
    invalidate()
  }

  private val backdropNode: RenderNode? =
    if (isSupported) RenderNode("GlassBackdrop") else null
  private var refractionShader: RuntimeShader? = null
  private var effectDirty = true
  private val ownLocation = IntArray(2)
  private val targetLocation = IntArray(2)
  private val targetOffset = FloatArray(2)

  // Scrolling re-records only the scrolled RenderNode, never this view, so
  // re-record on every window traversal. invalidate() inside pre-draw joins
  // the current traversal (ViewRootImpl.mWillDrawSoon) instead of scheduling
  // another one, so an idle screen stays idle.
  private val preDrawListener = ViewTreeObserver.OnPreDrawListener {
    invalidate()
    true
  }

  init {
    outlineProvider = object : ViewOutlineProvider() {
      override fun getOutline(view: View, outline: Outline) {
        if (continuousCorners && cornerRadius > 0f && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          outline.setPath(squirclePath(view.width.toFloat(), view.height.toFloat(), cornerRadius))
        } else {
          outline.setRoundRect(0, 0, view.width, view.height, cornerRadius)
        }
      }
    }
    clipToOutline = true
  }

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    viewTreeObserver.addOnPreDrawListener(preDrawListener)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    viewTreeObserver.removeOnPreDrawListener(preDrawListener)
  }

  override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
    super.onSizeChanged(w, h, oldw, oldh)
    effectDirty = true
  }

  override fun onDraw(canvas: Canvas) {
    val node = backdropNode
    if (node != null && canvas.isHardwareAccelerated && width > 0 && height > 0 && isSupported) {
      recordBackdrop(node)
      canvas.drawRenderNode(node)
    }
    canvas.drawColor(overlayColor)
  }

  @RequiresApi(Build.VERSION_CODES.S)
  private fun recordBackdrop(node: RenderNode) {
    node.setPosition(0, 0, width, height)
    if (effectDirty) {
      node.setRenderEffect(buildEffect())
      effectDirty = false
    }

    val recording = node.beginRecording(width, height)
    try {
      if (magnification != 1f) {
        val cx = width / 2f
        val cy = height / 2f
        recording.translate(cx, cy)
        recording.scale(magnification, magnification)
        recording.translate(-cx, -cy)
      }
      for (target in GlassTargetView.targets) {
        val content = target.contentNode ?: continue
        if (target.group != targetGroup || !target.isShown || isDescendantOf(target)) continue
        offsetOf(target, targetOffset)
        recording.save()
        recording.translate(targetOffset[0], targetOffset[1])
        recording.drawRenderNode(content)
        recording.restore()
      }
    } finally {
      node.endRecording()
    }
  }

  /**
   * Target position in this view's unscaled coordinates. When the target's
   * parent is one of our ancestors, layout + translation are summed up to it,
   * which stays exact while a shared ancestor or our own wrapper is scaled
   * (window coordinates would bake those scales into the offset).
   */
  private fun offsetOf(target: View, out: FloatArray) {
    val commonParent = target.parent
    var x = 0f
    var y = 0f
    var view: View = this
    while (true) {
      x += view.left + view.translationX
      y += view.top + view.translationY
      val next = view.parent
      if (next === commonParent) {
        out[0] = target.left + target.translationX - x
        out[1] = target.top + target.translationY - y
        return
      }
      view = next as? View ?: break
    }
    getLocationInWindow(ownLocation)
    target.getLocationInWindow(targetLocation)
    out[0] = (targetLocation[0] - ownLocation[0]).toFloat()
    out[1] = (targetLocation[1] - ownLocation[1]).toFloat()
  }

  private fun isDescendantOf(ancestor: View): Boolean {
    var current = parent
    while (current != null) {
      if (current === ancestor) return true
      current = current.parent
    }
    return false
  }

  @RequiresApi(Build.VERSION_CODES.S)
  private fun buildEffect(): RenderEffect? {
    val blur =
      if (blurRadius > 0f) {
        RenderEffect.createBlurEffect(blurRadius, blurRadius, Shader.TileMode.CLAMP)
      } else {
        null
      }
    val needsShader = refraction || saturation != 1f || highlight > 0f
    if (!needsShader || Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return blur

    val refractionEffect = buildRefractionEffect()
    return if (blur == null) refractionEffect else RenderEffect.createChainEffect(refractionEffect, blur)
  }

  @RequiresApi(Build.VERSION_CODES.TIRAMISU)
  private fun buildRefractionEffect(): RenderEffect {
    val source = shaderSource
      ?: resources.openRawResource(R.raw.glasslens_refraction).bufferedReader().use { it.readText() }
        .also { shaderSource = it }
    val shader = refractionShader ?: RuntimeShader(source).also { refractionShader = it }

    val w = width.toFloat()
    val h = height.toFloat()
    val radius = cornerRadius.coerceIn(0f, minOf(w, h) / 2f)
    shader.setFloatUniform("size", w, h)
    shader.setFloatUniform("cornerRadius", radius)
    shader.setFloatUniform("continuousCorners", if (continuousCorners) 1f else 0f)
    shader.setFloatUniform("refractionHeight", if (refraction) refractionHeight else 0f)
    shader.setFloatUniform("refractionAmount", -refractionAmount)
    shader.setFloatUniform("depthEffect", DEPTH_EFFECT)
    shader.setFloatUniform("chromaticAberration", dispersion)
    shader.setFloatUniform("saturation", saturation)
    shader.setFloatUniform("highlight", highlight)
    shader.setFloatUniform("highlightWidth", PixelUtil.toPixelFromDIP(HIGHLIGHT_WIDTH_DP))
    val angle = Math.toRadians(lightAngle.toDouble())
    shader.setFloatUniform("lightDir", sin(angle).toFloat(), -cos(angle).toFloat())
    return RenderEffect.createRuntimeShaderEffect(shader, "content")
  }

  companion object {
    private val isSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S

    // Read once per process; every backdrop compiles the same source. UI thread only.
    private var shaderSource: String? = null

    private const val DEPTH_EFFECT = 0.3f
    // Falloff of the rim light from the edge inward.
    private const val HIGHLIGHT_WIDTH_DP = 1.5f

    /**
     * Superellipse corners approximating CALayer's continuous curve, matching
     * sdSquircle in the shader: the curve spans 1.528 r (clamped to the half
     * size) and its exponent keeps the 45° point on the circular arc, so a
     * capsule degrades to plain circles.
     */
    private fun squirclePath(w: Float, h: Float, r: Float): Path {
      val big = minOf(1.528f * r, w / 2f, h / 2f)
      val exp = (ln(2.0) / -ln(1.0 - 0.2929 * minOf(r, big) / big)).toFloat()
      val path = Path()
      // Corner centers and their quadrant directions, clockwise from top-right.
      val corners = arrayOf(
        floatArrayOf(w - big, big, 1f, -1f),
        floatArrayOf(w - big, h - big, 1f, 1f),
        floatArrayOf(big, h - big, -1f, 1f),
        floatArrayOf(big, big, -1f, -1f),
      )
      for ((i, c) in corners.withIndex()) {
        for (step in 0..CORNER_STEPS) {
          // Odd corners run from the x axis to the y axis, even ones back.
          val t = (if (i % 2 == 0) CORNER_STEPS - step else step) * (PI / 2) / CORNER_STEPS
          val x = c[0] + c[2] * big * cos(t).toFloat().pow(2f / exp)
          val y = c[1] + c[3] * big * sin(t).toFloat().pow(2f / exp)
          if (i == 0 && step == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
      }
      path.close()
      return path
    }

    private const val CORNER_STEPS = 12
  }
}
