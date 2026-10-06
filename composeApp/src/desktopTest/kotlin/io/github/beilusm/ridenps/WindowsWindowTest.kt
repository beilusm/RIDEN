package io.github.beilusm.ridenps

import androidx.compose.ui.awt.ComposeWindow
import androidx.compose.ui.window.WindowPlacement
import io.github.beilusm.ridenps.core.PowerController
import io.github.beilusm.ridenps.ui.RidenApp
import kotlinx.coroutines.runBlocking
import org.jetbrains.skiko.GraphicsApi
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.awt.Rectangle
import java.awt.Robot
import java.io.File
import javax.imageio.ImageIO
import javax.swing.SwingUtilities
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WindowsWindowTest {
    @Test fun softwareRendererSurvivesMaximizeFullscreenAndRestore() {
        assumeTrue(System.getProperty("os.name").startsWith("Windows"))
        configureDesktopRendering()
        assertEquals("false", System.getProperty("sun.java2d.d3d"))
        lateinit var window: ComposeWindow
        lateinit var controller: PowerController
        SwingUtilities.invokeAndWait {
            controller = PowerController(DesktopServices())
            controller.setAutoConnect(false)
            window = ComposeWindow().apply {
                title = "RIDEN Windows window verification"
                setSize(1120, 820)
                setContent { RidenApp(controller, desktop = true) }
                isVisible = true
            }
        }
        try {
            val robot = Robot()
            listOf(WindowPlacement.Floating, WindowPlacement.Maximized, WindowPlacement.Fullscreen, WindowPlacement.Floating).forEachIndexed { index, placement ->
                SwingUtilities.invokeAndWait { window.placement = placement }
                robot.delay(1500)
                SwingUtilities.invokeAndWait {
                    assertTrue(window.isShowing)
                    assertTrue(window.renderApi in setOf(GraphicsApi.SOFTWARE_FAST, GraphicsApi.SOFTWARE_COMPAT))
                    assertEquals(placement, window.placement)
                }
                lateinit var bounds: Rectangle
                SwingUtilities.invokeAndWait {
                    bounds = Rectangle(window.contentPane.locationOnScreen, window.contentPane.size)
                }
                val screenshot = robot.createScreenCapture(bounds)
                val colors = mutableSetOf<Int>()
                for (y in 0 until screenshot.height step 8) for (x in 0 until screenshot.width step 8) colors += screenshot.getRGB(x, y)
                assertTrue(colors.size > 20, "Window content is blank after $placement")
                val path = File("build/screenshots/windows-$index-${placement.name.lowercase()}.png")
                path.parentFile.mkdirs()
                ImageIO.write(screenshot, "png", path)
            }
        } finally {
            runBlocking { controller.close() }
            SwingUtilities.invokeAndWait { window.dispose() }
        }
    }
}
