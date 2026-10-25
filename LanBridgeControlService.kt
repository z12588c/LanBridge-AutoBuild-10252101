package com.lanbridge.app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Build
import android.view.accessibility.AccessibilityEvent
import androidx.annotation.RequiresApi

/**
 * LanBridge 安卓端免 Root 反控核心服务 (AccessibilityService)
 * 作用：接收 Windows 电脑发来的归一化坐标指令（点击 TAP、滑动 SWIPE、导航键 BACK/HOME/RECENTS），
 *       通过 Android 7.0+ 原生 dispatchGesture 接口注入全局手势，无需 Root 即可让电脑鼠标反控手机。
 */
class LanBridgeControlService : AccessibilityService() {

    companion object {
        var instance: LanBridgeControlService? = null
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        super.onDestroy()
        if (instance == this) instance = null
    }

    @RequiresApi(Build.VERSION_CODES.N)
    fun performTap(normX: Float, normY: Float) {
        val dm = resources.displayMetrics
        val x = (normX * dm.widthPixels).coerceIn(1f, dm.widthPixels - 1f)
        val y = (normY * dm.heightPixels).coerceIn(1f, dm.heightPixels - 1f)

        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 60)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, null, null)
    }

    @RequiresApi(Build.VERSION_CODES.N)
    fun performSwipe(normX1: Float, normY1: Float, normX2: Float, normY2: Float, durationMs: Long = 260L) {
        val dm = resources.displayMetrics
        val x1 = (normX1 * dm.widthPixels).coerceIn(1f, dm.widthPixels - 1f)
        val y1 = (normY1 * dm.heightPixels).coerceIn(1f, dm.heightPixels - 1f)
        val x2 = (normX2 * dm.widthPixels).coerceIn(1f, dm.widthPixels - 1f)
        val y2 = (normY2 * dm.heightPixels).coerceIn(1f, dm.heightPixels - 1f)

        val path = Path().apply {
            moveTo(x1, y1)
            lineTo(x2, y2)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        dispatchGesture(gesture, null, null)
    }

    fun performSystemNav(key: String) {
        when (key) {
            "BACK" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "HOME" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "RECENTS" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
        }
    }
}