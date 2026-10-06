package io.github.beilusm.ridenps

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import io.github.beilusm.ridenps.core.PowerController
import io.github.beilusm.ridenps.ui.RidenApp
import kotlinx.coroutines.*
import java.io.File

class MainActivity : ComponentActivity() {
    private lateinit var controller: PowerController
    private var pendingSave: CompletableDeferred<Uri?>? = null
    private val saveDocument = registerForActivityResult(ActivityResultContracts.CreateDocument("text/csv")) { uri ->
        pendingSave?.complete(uri)
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        controller = PowerController(AndroidServices(applicationContext, ::save))
        if (intent.getBooleanExtra("demo", false)) {
            controller.setAutoConnect(false)
            controller.connect(io.github.beilusm.ridenps.core.SerialDevice("demo", "Demo"), io.github.beilusm.ridenps.core.SerialConfig())
        }
        setContent { RidenApp(controller) }
    }
    private suspend fun save(name: String, file: File): String? {
        check(pendingSave == null) { "Another export is open" }
        val result = CompletableDeferred<Uri?>()
        pendingSave = result
        try {
            saveDocument.launch(name)
            val uri = result.await() ?: return null
            withContext(Dispatchers.IO) {
                val output = contentResolver.openOutputStream(uri) ?: error("Cannot open export destination")
                output.use { stream -> file.inputStream().use { it.copyTo(stream) } }
            }
            return uri.toString()
        } finally { pendingSave = null }
    }
    override fun onDestroy() {
        pendingSave?.cancel()
        CoroutineScope(Dispatchers.Main).launch { runCatching { controller.close(exportRecordings = false) } }
        super.onDestroy()
    }
}
