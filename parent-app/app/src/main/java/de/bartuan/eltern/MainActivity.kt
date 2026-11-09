package de.bartuan.eltern

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.lightColorScheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.viewmodel.compose.viewModel
import de.bartuan.eltern.ui.AppRoot

private val Colors = lightColorScheme(
    primary = Color(0xFF2F5D9E),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD8E5FA),
    secondary = Color(0xFF4F6B8F),
    background = Color(0xFFF4F7FB),
    surface = Color(0xFFFFFFFF),
    surfaceVariant = Color(0xFFE6ECF4),
    error = Color(0xFFB3261E),
)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = Colors) {
                Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    AppRoot(viewModel())
                }
            }
        }
    }
}
