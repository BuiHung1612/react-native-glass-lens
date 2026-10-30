package com.glasslens

import android.content.Context
import android.graphics.Canvas
import android.graphics.RenderNode
import android.os.Build
import com.facebook.react.views.view.ReactViewGroup

/**
 * Wraps content that [GlassBackdropView]s blur. Children are recorded into
 * [contentNode] instead of straight into this view's display list, so a
 * backdrop view can draw the same live RenderNode on the GPU every frame —
 * no software re-rasterization of the view tree.
 *
 * A backdrop view must never be a descendant of the target it samples:
 * that would make the RenderNode tree cyclic.
 */
class GlassTargetView(context: Context) : ReactViewGroup(context) {

  /** Backdrop views only sample targets whose group matches their targetGroup. */
  var group: String = DEFAULT_GROUP

  /** Record children for backdrops but draw nothing on screen. */
  var sampleOnly = false
    set(value) {
      field = value
      invalidate()
    }

  val contentNode: RenderNode? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) RenderNode("GlassTarget") else null

  override fun onAttachedToWindow() {
    super.onAttachedToWindow()
    targets.add(this)
  }

  override fun onDetachedFromWindow() {
    super.onDetachedFromWindow()
    targets.remove(this)
  }

  override fun dispatchDraw(canvas: Canvas) {
    val node = contentNode
    if (node == null || !canvas.isHardwareAccelerated || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
      if (!sampleOnly) super.dispatchDraw(canvas)
      return
    }
    node.setPosition(0, 0, width, height)
    val recording = node.beginRecording(width, height)
    try {
      super.dispatchDraw(recording)
    } finally {
      node.endRecording()
    }
    // Backdrops draw contentNode directly, so skipping it here hides the
    // children on screen without affecting what backdrops sample.
    if (!sampleOnly) canvas.drawRenderNode(node)
  }

  companion object {
    const val DEFAULT_GROUP = "default"

    // UI-thread only, like all view attach/draw callbacks.
    val targets = LinkedHashSet<GlassTargetView>()
  }
}
