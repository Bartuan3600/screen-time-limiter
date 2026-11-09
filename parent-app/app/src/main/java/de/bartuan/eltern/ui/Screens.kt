@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package de.bartuan.eltern.ui

import android.Manifest
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import de.bartuan.eltern.Conn
import de.bartuan.eltern.MainViewModel
import de.bartuan.eltern.UiState
import de.bartuan.eltern.relay.*
import kotlinx.coroutines.delay

private enum class Screen { Dashboard, Plan, Settings }

/** Was nach der PIN-Eingabe gesendet wird. */
private class Pending(val title: String, val text: String, val action: String, val user: String?, val minutes: Int?, val days: List<DayRule>?, val confirmOnly: Boolean)

@Composable
fun AppRoot(vm: MainViewModel) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    if (!ui.paired) { PairScreen(vm); return }

    var screen by remember { mutableStateOf(Screen.Dashboard) }
    var pending by remember { mutableStateOf<Pending?>(null) }
    val snack = remember { SnackbarHostState() }
    val lifecycle = LocalLifecycleOwner.current.lifecycle

    // Abfragen nur, solange die App sichtbar ist (kein Hintergrunddienst)
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { vm.pollLoop() } }
    LaunchedEffect(lifecycle) { lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) { while (true) { vm.tick(System.currentTimeMillis()); delay(1000) } } }
    LaunchedEffect(ui.message) { ui.message?.let { snack.showSnackbar(it, duration = SnackbarDuration.Long); vm.consumeMessage() } }

    fun request(p: Pending) {
        val pin = if (p.confirmOnly) null else vm.savedPin()
        if (pin != null && !p.confirmOnly && p.action != "block_today" && p.action != "unlimited_today") vm.send(p.action, p.user, p.minutes, pin, p.days)
        else pending = p
    }

    BackHandler(enabled = screen != Screen.Dashboard) { screen = Screen.Dashboard }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        snackbarHost = { SnackbarHost(snack) },
        topBar = {
            TopAppBar(
                title = { Text(when (screen) { Screen.Dashboard -> "Bildschirmzeit"; Screen.Plan -> "Wochenplan"; Screen.Settings -> "Einstellungen" }) },
                navigationIcon = {
                    if (screen != Screen.Dashboard) IconButton(onClick = { screen = Screen.Dashboard }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück") }
                },
                actions = {
                    if (screen == Screen.Dashboard) {
                        IconButton(onClick = { vm.refreshWithPing() }) { Icon(Icons.Default.Refresh, "Aktualisieren") }
                        IconButton(onClick = { screen = Screen.Settings }) { Icon(Icons.Default.Settings, "Einstellungen") }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
    ) { pad ->
        Box(Modifier.padding(pad).fillMaxSize()) {
            when (screen) {
                Screen.Dashboard -> Dashboard(ui, onCommand = ::request, onPlan = { screen = Screen.Plan })
                Screen.Plan -> PlanScreen(ui, onSave = { days ->
                    request(Pending("Wochenplan speichern", "Der neue Wochenplan wird an den PC gesendet.", "set_plan", null, null, days, false))
                    screen = Screen.Dashboard
                })
                Screen.Settings -> SettingsScreen(vm, ui)
            }
        }
    }

    pending?.let { p ->
        PinDialog(p, canSave = !ui.hasSavedPin, onDismiss = { pending = null }, onOk = { pin, remember ->
            pending = null
            if (remember) vm.savePin(pin)
            vm.send(p.action, p.user, p.minutes, if (p.confirmOnly) null else pin, p.days)
        })
    }
}

// ------------------------------------------------------------------ Kopplung
@Composable
private fun PairScreen(vm: MainViewModel) {
    var code by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val ctx = LocalContext.current
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp).statusBarsPadding(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Eltern Bildschirmzeit", fontSize = 26.sp, fontWeight = FontWeight.Bold)
        Text("Koppeln Sie dieses Handy mit dem PC Ihres Kindes. Die App zeigt nur, was der Bildschirmzeit-Begrenzer ohnehin weiß " +
            "(heutige Zeit, Regel, Wochenplan, angemeldet/gesperrt) und erlaubt die Elternaktionen. " +
            "Es werden keine Apps, Webseiten, Nachrichten oder Standorte angezeigt.")
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("So geht's", fontWeight = FontWeight.SemiBold)
                Text("1. Am PC: Eltern-Zentrale öffnen → „Handy-App …“ → „Handy-Steuerung einschalten“.\n" +
                    "2. Den angezeigten Kopplungscode (beginnt mit STL1-) hier einfügen oder abtippen.\n" +
                    "3. Der Code ist der geheime Schlüssel – nur für Ihr Handy, nicht weitergeben.")
            }
        }
        OutlinedTextField(
            value = code, onValueChange = { code = it; error = null }, label = { Text("Kopplungscode (STL1-…)") },
            isError = error != null, supportingText = { error?.let { Text(it) } }, minLines = 3,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii), modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = {
                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                code = cm.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString().orEmpty()
                error = null
            }) { Text("Aus Zwischenablage") }
            Button(onClick = { error = vm.pair(code) }, enabled = code.isNotBlank()) { Text("Koppeln") }
        }
    }
}

// ------------------------------------------------------------------ Dashboard
@Composable
private fun Dashboard(ui: UiState, onCommand: (Pending) -> Unit, onPlan: () -> Unit) {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) { while (true) { now = System.currentTimeMillis(); delay(1000) } }
    val st = ui.status

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        ConnectionBanner(ui, now)
        if (st == null) {
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(20.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (ui.conn == Conn.Loading) { CircularProgressIndicator(); Text("Lade Status …") }
                    else Text("Noch keine Daten vom PC.", fontWeight = FontWeight.SemiBold)
                }
            }
        } else {
            val stale = Logic.isStale(st, now)
            st.users.forEach { u -> UserCard(u, st, ui, now, stale, ui.busy, onCommand) }
            Card(Modifier.fillMaxWidth()) {
                Row(Modifier.padding(16.dp).fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Wochenplan", fontWeight = FontWeight.SemiBold)
                        Text("Heute (${st.day}): ${st.plan.getOrNull(st.todayIndex)?.let { ruleText(it) } ?: "–"}", fontSize = 13.sp)
                    }
                    FilledTonalButton(onClick = onPlan, enabled = st.plan.size == 7) { Text("Ansehen / ändern") }
                }
            }
            if (st.lastCmds.isNotEmpty()) {
                Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Letzte Befehle", fontWeight = FontWeight.SemiBold)
                        st.lastCmds.takeLast(5).reversed().forEach {
                            Text((if (it.ok) "✓ " else "✗ ") + it.msg, fontSize = 13.sp, color = if (it.ok) Color(0xFF2E7D32) else MaterialTheme.colorScheme.error)
                        }
                    }
                }
            }
            if (st.lockedUntil != null) {
                Text("Hinweis: Nach mehreren falschen PINs / Passwörtern nimmt der PC Befehle vorübergehend nicht an.", fontSize = 12.sp, color = MaterialTheme.colorScheme.error)
            }
        }
        Spacer(Modifier.height(24.dp))
    }
}

@Composable
private fun ConnectionBanner(ui: UiState, now: Long) {
    val st = ui.status
    val stale = st != null && Logic.isStale(st, now)
    val (text, bad) = when {
        ui.conn == Conn.Offline -> ("Keine Verbindung zum Internet/Server (${ui.connDetail}). Angezeigt wird der letzte bekannte Stand." to true)
        ui.conn == Conn.BadData -> ("Die Daten sind mit diesem Code nicht lesbar. Wurde am PC „Neu koppeln“ gewählt? Dann den neuen Code eingeben (Einstellungen → Kopplung entfernen)." to true)
        ui.conn == Conn.NoData && st == null -> ("Der PC hat noch nichts gemeldet. Ist er eingeschaltet, online und die Handy-Steuerung aktiv?" to true)
        stale -> ("PC nicht erreichbar – letzter Stand ${Logic.ageText(Logic.ageSeconds(st!!, now))}. Der PC muss an und online sein. Befehle werden 10 Minuten lang vorgehalten." to true)
        st != null -> ("Aktualisiert ${Logic.ageText(Logic.ageSeconds(st, now))}" to false)
        else -> return
    }
    if (bad) {
        Card(colors = CardDefaults.cardColors(containerColor = Color(0xFFFFE3E0))) {
            Text(text, Modifier.padding(14.dp), color = Color(0xFF7A1812), fontSize = 14.sp)
        }
    } else {
        Text(text, fontSize = 12.sp, color = MaterialTheme.colorScheme.secondary, modifier = Modifier.padding(start = 4.dp))
    }
}

@Composable
private fun UserCard(u: UserStatus, st: Status, ui: UiState, now: Long, stale: Boolean, busy: Boolean, onCommand: (Pending) -> Unit) {
    val live = Logic.liveRemaining(u, st, ui.fetchedAtMs, now)
    val blocked = u.blockedToday || (u.lockReason != null && live != null && live <= 0) || (u.lockReason != null && !u.unlimitedToday && live == null)
    val unlimited = u.remainingSeconds == null && !blocked
    val ringColor = when {
        stale -> Color(0xFF9AA5B1)
        blocked -> Color(0xFFC62828)
        unlimited -> Color(0xFF2E7D32)
        live != null && live < 600 -> Color(0xFFEF6C00)
        else -> Color(0xFF2F5D9E)
    }
    Card(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp)) {
        Column(Modifier.padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(u.name, fontSize = 20.sp, fontWeight = FontWeight.Bold)
            Box(Modifier.size(210.dp), contentAlignment = Alignment.Center) {
                val frac = Logic.ringFraction(u, live)
                val track = MaterialTheme.colorScheme.surfaceVariant
                Canvas(Modifier.fillMaxSize()) {
                    val sw = 22.dp.toPx()
                    val d = size.minDimension - sw
                    val tl = Offset(sw / 2, sw / 2)
                    drawArc(track, 0f, 360f, false, tl, Size(d, d), style = Stroke(sw))
                    drawArc(ringColor, -90f, 360f * (if (blocked) 1f else frac), false, tl, Size(d, d), style = Stroke(sw, cap = StrokeCap.Round))
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    when {
                        blocked -> { Text("Gesperrt", fontSize = 26.sp, fontWeight = FontWeight.Bold, color = ringColor) }
                        unlimited -> { Text("∞", fontSize = 48.sp, fontWeight = FontWeight.Bold, color = ringColor); Text("unbegrenzt", fontSize = 14.sp) }
                        else -> { Text(Logic.formatRemaining(live ?: 0), fontSize = 30.sp, fontWeight = FontWeight.Bold, color = ringColor); Text("noch heute", fontSize = 14.sp) }
                    }
                }
            }
            Text(Logic.sessionText(u.session) + if (stale) " (Stand veraltet)" else "", fontWeight = FontWeight.Medium)
            Text("Heute genutzt: ${Logic.formatMinutes(u.usedSeconds / 60)}" + if (u.bonusMinutes > 0) "  ·  Zusatz: +${u.bonusMinutes} min" else "", fontSize = 13.sp)
            if (u.rule.isNotBlank()) Text("Regel heute: ${u.rule}", fontSize = 13.sp, textAlign = TextAlign.Center)
            u.lockReason?.let { Text(it, fontSize = 13.sp, color = MaterialTheme.colorScheme.error, textAlign = TextAlign.Center) }

            val enabled = !busy
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(15, 30, 60).forEach { m ->
                    Button(onClick = { onCommand(Pending("+$m Minuten für ${u.name}", "Die Zeit wird um $m Minuten verlängert.", "add_minutes", u.name, m, null, false)) },
                        enabled = enabled, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp)) { Text("+$m min") }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                FilledTonalButton(onClick = { onCommand(Pending("Heute unbegrenzt für ${u.name}?", "Heute gibt es für ${u.name} kein Zeitlimit.", "unlimited_today", u.name, null, null, false)) },
                    enabled = enabled, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp)) { Text("Heute unbegrenzt", maxLines = 1) }
                FilledTonalButton(onClick = { onCommand(Pending("Heute sperren für ${u.name}?", "${u.name} wird abgemeldet und kann sich heute nicht mehr anmelden.", "block_today", u.name, null, null, false)) },
                    enabled = enabled, modifier = Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 4.dp),
                    colors = ButtonDefaults.filledTonalButtonColors(containerColor = Color(0xFFFFDAD6))) { Text("Heute sperren", maxLines = 1) }
            }
            OutlinedButton(onClick = { onCommand(Pending("Freigaben aufheben für ${u.name}?", "Zusatzzeit, „unbegrenzt“ und „gesperrt“ von heute werden zurückgenommen.", "clear_extras", u.name, null, null, false)) },
                enabled = enabled, modifier = Modifier.fillMaxWidth()) { Text("Freigaben aufheben") }
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        }
    }
}

private fun ruleText(r: DayRule): String {
    val base = when (r.mode) { "blocked" -> "gesperrt"; "unlimited" -> "unbegrenzt"; else -> Logic.formatMinutes(r.limitMinutes) }
    return if (r.windowEnabled && r.mode != "blocked") "$base, ${r.windowStart}–${r.windowEnd} Uhr" else base
}

// ------------------------------------------------------------------ PIN-Dialog
@Composable
private fun PinDialog(p: Pending, canSave: Boolean, onDismiss: () -> Unit, onOk: (String, Boolean) -> Unit) {
    var pin by remember { mutableStateOf("") }
    var remember by remember { mutableStateOf(false) }
    var show by remember { mutableStateOf(false) }
    val valid = PinPolicy.isValid(pin)
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(p.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text(p.text)
                OutlinedTextField(pin, { pin = PinPolicy.sanitize(it) }, label = { Text("Eltern-PIN / Passwort (4–32 Zeichen)") }, singleLine = true,
                    visualTransformation = if (show) VisualTransformation.None else PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false),
                    trailingIcon = { TextButton(onClick = { show = !show }) { Text(if (show) "Verbergen" else "Anzeigen", fontSize = 12.sp) } },
                    supportingText = { Text("Buchstaben, Ziffern, Sonderzeichen; keine Leerzeichen", fontSize = 11.sp) })
                if (canSave) Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(remember, { remember = it })
                    Text("PIN / Passwort auf diesem Handy sicher speichern", fontSize = 13.sp)
                }
            }
        },
        confirmButton = { Button(onClick = { onOk(pin, remember) }, enabled = valid) { Text("Senden") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Abbrechen") } },
    )
}

// ------------------------------------------------------------------ Wochenplan
@Composable
private fun PlanScreen(ui: UiState, onSave: (List<DayRule>) -> Unit) {
    val initial = remember { ui.status?.plan.orEmpty() }
    val days = remember { mutableStateListOf<DayRule>().also { it.addAll(initial) } }
    val errors = days.mapIndexed { i, r -> r.validate(DAY_NAMES[i]) }
    val dirty = days.toList() != initial
    val today = ui.status?.todayIndex ?: -1

    if (days.size != 7) { Text("Der Wochenplan ist noch nicht verfügbar.", Modifier.padding(16.dp)); return }
    Column(Modifier.fillMaxSize()) {
        Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            days.forEachIndexed { i, r -> DayEditor(DAY_NAMES[i], i == today, r, errors[i]) { days[i] = it } }
            Spacer(Modifier.height(8.dp))
        }
        Row(Modifier.fillMaxWidth().padding(16.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(onClick = { days.clear(); days.addAll(initial) }, enabled = dirty, modifier = Modifier.weight(1f)) { Text("Zurücksetzen") }
            Button(onClick = { onSave(days.toList()) }, enabled = dirty && errors.all { it == null } && !ui.busy, modifier = Modifier.weight(1f)) { Text("Speichern") }
        }
    }
}

@Composable
private fun DayEditor(name: String, isToday: Boolean, r: DayRule, error: String?, onChange: (DayRule) -> Unit) {
    var picking by remember { mutableStateOf<Boolean?>(null) } // true = Beginn, false = Ende
    Card(Modifier.fillMaxWidth(), colors = CardDefaults.cardColors(containerColor = if (isToday) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surface)) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(name + if (isToday) " (heute)" else "", fontWeight = FontWeight.SemiBold)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("limit" to "Limit", "blocked" to "Gesperrt", "unlimited" to "Unbegrenzt").forEach { (m, label) ->
                    FilterChip(selected = r.mode == m, onClick = {
                        onChange(r.copy(mode = m, limitMinutes = if (m == "limit" && r.limitMinutes < 1) 60 else r.limitMinutes))
                    }, label = { Text(label) })
                }
            }
            if (r.mode == "limit") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    OutlinedButton(onClick = { onChange(r.copy(limitMinutes = (r.limitMinutes - 15).coerceAtLeast(15))) }, enabled = r.limitMinutes > 15) { Text("−15") }
                    Text(Logic.formatMinutes(r.limitMinutes), Modifier.weight(1f), textAlign = TextAlign.Center, fontWeight = FontWeight.Medium)
                    OutlinedButton(onClick = { onChange(r.copy(limitMinutes = (r.limitMinutes + 15).coerceAtMost(1440))) }, enabled = r.limitMinutes < 1440) { Text("+15") }
                }
            }
            if (r.mode != "blocked") {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Nur im Zeitfenster", Modifier.weight(1f))
                    Switch(r.windowEnabled, { onChange(r.copy(windowEnabled = it)) })
                }
                if (r.windowEnabled) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { picking = true }, Modifier.weight(1f)) { Text("von ${r.windowStart}") }
                    OutlinedButton(onClick = { picking = false }, Modifier.weight(1f)) { Text("bis ${r.windowEnd}") }
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp) }
        }
    }
    picking?.let { isStart ->
        val cur = DayRule.minuteOfDay(if (isStart) r.windowStart else r.windowEnd) ?: 16 * 60
        val ts = rememberTimePickerState(initialHour = cur / 60, initialMinute = cur % 60, is24Hour = true)
        AlertDialog(
            onDismissRequest = { picking = null },
            title = { Text(if (isStart) "Beginn" else "Ende") },
            text = { TimePicker(ts) },
            confirmButton = {
                TextButton(onClick = {
                    val t = "%02d:%02d".format(ts.hour, ts.minute)
                    onChange(if (isStart) r.copy(windowStart = t) else r.copy(windowEnd = t)); picking = null
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { picking = null }) { Text("Abbrechen") } },
        )
    }
}

// ------------------------------------------------------------------ Einstellungen
@Composable
private fun SettingsScreen(vm: MainViewModel, ui: UiState) {
    val ctx = LocalContext.current
    var confirmUnpair by remember { mutableStateOf(false) }
    var server by remember(ui.server) { mutableStateOf(ui.server) }
    var db by remember(ui.db) { mutableStateOf(ui.db) }
    var srvError by remember { mutableStateOf<String?>(null) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        vm.setNotifyLimit(granted)
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Kopplung", fontWeight = FontWeight.SemiBold)
                Text("Fingerabdruck: ${ui.fingerprint.chunked(4).joinToString(" ")}", fontSize = 14.sp)
                Text("Derselbe Fingerabdruck steht in der Eltern-Zentrale am PC (Handy-App …). Der Schlüssel selbst wird nie angezeigt.", fontSize = 12.sp)
                OutlinedButton(onClick = { confirmUnpair = true }) { Text("Kopplung entfernen") }
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Hinweis, wenn das Limit erreicht ist", fontWeight = FontWeight.SemiBold)
                        Text("Nur solange die App offen ist (kein Hintergrunddienst).", fontSize = 12.sp)
                    }
                    Switch(ui.notifyLimit, { on ->
                        if (on && Build.VERSION.SDK_INT >= 33 && !de.bartuan.eltern.Notifier.canNotify(ctx)) permission.launch(Manifest.permission.POST_NOTIFICATIONS)
                        else vm.setNotifyLimit(on)
                    })
                }
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("PIN / Passwort merken (optional)", fontWeight = FontWeight.SemiBold)
                Text(if (ui.hasSavedPin) "Die PIN / das Passwort ist verschlüsselt auf diesem Handy gespeichert (Android-Keystore). Wer Ihr entsperrtes Handy hat, kann dann Befehle senden. „Heute sperren/unbegrenzt“ fragt trotzdem nach."
                else "Aus: Sie geben die PIN / das Passwort bei jedem Befehl ein. Sie können es beim Senden speichern lassen.", fontSize = 13.sp)
                if (ui.hasSavedPin) OutlinedButton(onClick = { vm.forgetPin() }) { Text("Gespeicherte PIN / Passwort löschen") }
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Erweitert: Server", fontWeight = FontWeight.SemiBold)
                Text("Nur ändern, wenn Sie am PC eigene Server eingetragen haben (https).", fontSize = 12.sp)
                OutlinedTextField(server, { server = it; srvError = null }, label = { Text("Befehls-Server (ntfy)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(db, { db = it; srvError = null }, label = { Text("Status-Speicher (textdb)") }, singleLine = true, modifier = Modifier.fillMaxWidth(), isError = srvError != null, supportingText = { srvError?.let { Text(it) } })
                OutlinedButton(onClick = { srvError = vm.saveServers(server, db) }) { Text("Übernehmen") }
            }
        }
        Card(Modifier.fillMaxWidth()) {
            Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Datenschutz & Grenzen", fontWeight = FontWeight.SemiBold)
                Text("• Alles ist Ende-zu-Ende verschlüsselt (AES-256-GCM); der Schlüssel liegt nur auf PC und Handy.\n" +
                    "• Der Austausch läuft über die öffentlichen Dienste ntfy.sh und textdb.dev. Dort sind nur verschlüsselte Daten sichtbar, aber Zeitpunkte und Datenmengen schon.\n" +
                    "• Der PC muss eingeschaltet und online sein. Befehle gelten höchstens 10 Minuten.\n" +
                    "• Die App zeigt nichts über Apps, Webseiten, Nachrichten oder Standort Ihres Kindes. Sagen Sie Ihrem Kind, dass es diese Anzeige gibt.", fontSize = 13.sp)
            }
        }
    }
    if (confirmUnpair) AlertDialog(
        onDismissRequest = { confirmUnpair = false },
        title = { Text("Kopplung entfernen?") },
        text = { Text("Schlüssel und gespeichertes PIN / Passwort werden von diesem Handy gelöscht. Danach müssen Sie den Kopplungscode erneut eingeben.") },
        confirmButton = { Button(onClick = { confirmUnpair = false; vm.unpair() }) { Text("Entfernen") } },
        dismissButton = { TextButton(onClick = { confirmUnpair = false }) { Text("Abbrechen") } },
    )
}
