package de.bartuan.eltern

import de.bartuan.eltern.relay.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.util.Base64

private fun vectors(): JSONObject =
    JSONObject(object {}.javaClass.classLoader!!.getResourceAsStream("relay_vectors.json")!!.readBytes().toString(Charsets.UTF_8))

private fun testKey(): ByteArray = Base64.getDecoder().decode(vectors().getString("key_b64"))

/** Gemeinsame Vektoren mit dem PowerShell-Teil (tests/vectors/relay_vectors.json) – Test-Schlüssel 0..31, nie produktiv. */
class VectorsTest {
    @Test fun derivation_matches_powershell() {
        val v = vectors(); val p = Pairing(testKey())
        assertEquals(v.getString("topic"), p.topic)
        assertEquals(v.getString("db_key"), p.dbKey)
        assertEquals(v.getString("fingerprint"), p.fingerprint)
        assertEquals(v.getString("pairing_code"), p.code)
    }

    @Test fun envelopes_decrypt_and_reproduce_exactly() {
        val v = vectors(); val key = testKey(); val arr = v.getJSONArray("envelopes")
        assertTrue(arr.length() >= 3)
        for (i in 0 until arr.length()) {
            val e = arr.getJSONObject(i)
            assertEquals(e.getString("plaintext"), StlCrypto.open(key, e.getString("envelope")))
            val iv = Base64.getDecoder().decode(e.getString("iv_b64"))
            assertEquals(e.getString("envelope"), StlCrypto.seal(key, e.getString("plaintext"), iv))
        }
    }

    @Test fun wrong_key_and_tampering_are_rejected() {
        val key = testKey(); val env = StlCrypto.seal(key, "{\"a\":1}")
        assertNull(StlCrypto.open(ByteArray(32) { 7 }, env))
        val o = JSONObject(env); val d = Base64.getDecoder().decode(o.getString("data")); d[0] = (d[0].toInt() xor 1).toByte()
        o.put("data", Base64.getEncoder().encodeToString(d))
        assertNull(StlCrypto.open(key, o.toString()))
        assertNull(StlCrypto.open(key, "kein json"))
        assertNull(StlCrypto.open(key, "{\"enc\":\"anders\",\"iv\":\"\",\"data\":\"\"}"))
    }

    @Test fun iv_is_fresh_every_time() {
        val key = testKey()
        assertNotEquals(StlCrypto.seal(key, "x"), StlCrypto.seal(key, "x"))
    }
}

class PairingTest {
    @Test fun base32_known_values() {
        assertEquals("", Base32.encode(ByteArray(0)))
        assertEquals("MZXW6YTBOI", Base32.encode("foobar".toByteArray()))
        assertArrayEquals("foobar".toByteArray(), Base32.decode("MZXW6YTBOI"))
        assertNull(Base32.decode("MZXW1"))
    }

    @Test fun roundtrip_random_keys() {
        val rnd = java.util.Random(1)
        repeat(50) {
            val key = ByteArray(32).also { rnd.nextBytes(it) }
            val r = PairingCode.parse(PairingCode.format(key))
            assertTrue(r is CodeResult.Ok)
            assertArrayEquals(key, (r as CodeResult.Ok).pairing.key)
        }
    }

    @Test fun parse_is_lenient_about_case_and_spaces() {
        val code = vectors().getString("pairing_code")
        for (variant in listOf(code.lowercase(), code.replace("-", " "), "  $code\n", code.replace("-", "")))
            assertTrue(variant, PairingCode.parse(variant) is CodeResult.Ok)
    }

    @Test fun errors_are_reported_in_german() {
        val code = vectors().getString("pairing_code")
        assertTrue((PairingCode.parse("hallo") as CodeResult.Error).message.contains("STL1"))
        assertTrue((PairingCode.parse(code.dropLast(5)) as CodeResult.Error).message.contains("unvollständig"))
        val typo = code.substring(0, 7) + (if (code[7] == 'B') 'C' else 'B') + code.substring(8)
        assertTrue((PairingCode.parse(typo) as CodeResult.Error).message.contains("Tippfehler"))
        assertTrue((PairingCode.parse(code.replace('A', '1')) as CodeResult.Error).message.contains("ungültiges Zeichen"))
    }

    @Test fun code_has_expected_shape() {
        assertTrue(Regex("^STL1(-[A-Z2-7]{4}){14}$").matches(Pairing(ByteArray(32) { it.toByte() }).code))
    }
}

private const val STATUS_JSON = """{"v":1,"t":"2026-10-25T12:00:00.0000000Z","day":"Sonntag","today_index":6,
"users":[{"name":"Max","session":"active","used_seconds":1800,"remaining_seconds":3600,"bonus_minutes":15,"unlimited_today":false,"blocked_today":false,"rule":"60 Min.","lock_reason":null},
{"name":"Lea","session":"none","used_seconds":0,"remaining_seconds":null,"bonus_minutes":0,"unlimited_today":true,"blocked_today":false,"rule":"unbegrenzt","lock_reason":null}],
"plan":[{"mode":"limit","limit_minutes":60,"window_enabled":true,"window_start":"16:00","window_end":"20:00"},{"mode":"blocked","limit_minutes":0,"window_enabled":false,"window_start":"16:00","window_end":"20:00"},
{"mode":"unlimited","limit_minutes":0,"window_enabled":false,"window_start":"16:00","window_end":"20:00"},{"mode":"limit","limit_minutes":90,"window_enabled":false,"window_start":"16:00","window_end":"20:00"},
{"mode":"limit","limit_minutes":90,"window_enabled":false,"window_start":"16:00","window_end":"20:00"},{"mode":"limit","limit_minutes":120,"window_enabled":false,"window_start":"16:00","window_end":"20:00"},
{"mode":"limit","limit_minutes":120,"window_enabled":false,"window_start":"16:00","window_end":"20:00"}],
"last_cmds":[{"id":"abc","ok":false,"msg":"Falsche PIN (1 von 3).","t":"2026-10-25T11:59:00.0000000Z"}],"locked_until":null}"""

class StatusTest {
    @Test fun parses_full_status() {
        val s = StatusParser.parse(STATUS_JSON)!!
        assertEquals("Sonntag", s.day); assertEquals(6, s.todayIndex)
        assertEquals(2, s.users.size); assertEquals(7, s.plan.size)
        val max = s.users[0]
        assertEquals(3600, max.remainingSeconds); assertEquals(15, max.bonusMinutes); assertNull(max.lockReason)
        assertNull(s.users[1].remainingSeconds); assertTrue(s.users[1].unlimitedToday)
        assertEquals(DayRule("limit", 60, true, "16:00", "20:00"), s.plan[0])
        assertEquals("blocked", s.plan[1].mode)
        assertEquals(false, s.lastCmds[0].ok); assertEquals("Falsche PIN (1 von 3).", s.lastCmds[0].msg)
        assertNull(s.lockedUntil)
        assertEquals(java.time.Instant.parse("2026-10-25T12:00:00Z"), s.t)
    }

    @Test fun tolerates_powershell_single_element_objects_and_offsets() {
        val j = JSONObject(STATUS_JSON)
        j.put("users", j.getJSONArray("users").getJSONObject(0)); j.put("last_cmds", JSONObject())
        j.put("t", "2026-10-25T14:00:00.1234567+02:00")
        val s = StatusParser.parse(j.toString())!!
        assertEquals(1, s.users.size)
        assertEquals(java.time.Instant.parse("2026-10-25T12:00:00.123Z").toEpochMilli() / 1000, s.t.toEpochMilli() / 1000)
    }

    @Test fun rejects_garbage_and_wrong_version() {
        assertNull(StatusParser.parse("nope"))
        assertNull(StatusParser.parse("{\"v\":2,\"t\":\"2026-10-25T12:00:00Z\"}"))
        assertNull(StatusParser.parse("{\"v\":1}"))
    }
}

class LogicTest {
    private val st = StatusParser.parse(STATUS_JSON)!!
    private val t0 = st.t.toEpochMilli()

    @Test fun live_countdown_only_while_active() {
        val max = st.users[0]
        assertEquals(3599, Logic.liveRemaining(max, st, t0 + 1000, t0 + 1000))
        assertEquals(3589, Logic.liveRemaining(max, st, t0 + 1000, t0 + 11_000))
        assertEquals(0, Logic.liveRemaining(max.copy(remainingSeconds = 5), st, t0, t0 + 60_000))
        assertEquals(3600, Logic.liveRemaining(max.copy(session = "locked"), st, t0, t0 + 60_000))
        assertNull(Logic.liveRemaining(st.users[1], st, t0, t0))
    }

    @Test fun staleness() {
        assertFalse(Logic.isStale(st, t0 + 200_000))
        assertTrue(Logic.isStale(st, t0 + 300_000))
        // veraltete Daten werden nicht weitergezählt
        assertEquals(3600, Logic.liveRemaining(st.users[0], st, t0, t0 + 600_000))
        assertEquals(0, Logic.ageSeconds(st, t0 - 5000)) // Uhr geht nach: nie negativ
    }

    @Test fun formatting() {
        assertEquals("1:23 h", Logic.formatRemaining(3600 + 23 * 60 + 59))
        assertEquals("23:45 min", Logic.formatRemaining(23 * 60 + 45))
        assertEquals("0:00 min", Logic.formatRemaining(-3))
        assertEquals("1 h 30 min", Logic.formatMinutes(90)); assertEquals("2 h", Logic.formatMinutes(120)); assertEquals("45 min", Logic.formatMinutes(45))
        assertEquals("vor 5 Min.", Logic.ageText(300))
    }

    @Test fun ring_fraction() {
        val u = st.users[0]
        assertEquals(1f, Logic.ringFraction(u, 3600 + 1800), 0.01f)   // 5400 gesamt, 5400 übrig
        assertEquals(0.5f, Logic.ringFraction(u.copy(usedSeconds = 3600, remainingSeconds = 3600), 3600), 0.01f)
        assertEquals(1f, Logic.ringFraction(st.users[1], null), 0.01f)
        assertEquals(0f, Logic.ringFraction(u.copy(usedSeconds = 0, remainingSeconds = 0), 0), 0.01f)
    }

    @Test fun limit_watcher_fires_once_when_active_session_hits_zero() {
        val w = LimitWatcher()
        assertTrue(w.check(mapOf("Max" to ("active" to 5))).isEmpty())
        assertEquals(listOf("Max"), w.check(mapOf("Max" to ("active" to 0))))
        assertTrue(w.check(mapOf("Max" to ("active" to 0))).isEmpty())            // nicht erneut
        assertTrue(w.check(mapOf("Max" to ("none" to 0))).isEmpty())
        w.check(mapOf("Max" to ("active" to 600)))                                  // +10 Min. -> wieder scharf
        assertEquals(listOf("Max"), w.check(mapOf("Max" to ("active" to 0))))
        val w2 = LimitWatcher()                                                      // App öffnet mit bereits 0: keine Meldung
        assertTrue(w2.check(mapOf("Lea" to ("active" to 0))).isEmpty())
        assertTrue(w2.check(mapOf("Lea" to ("active" to null))).isEmpty())
    }

    @Test fun day_rule_validation_matches_pc_rules() {
        assertNull(DayRule("limit", 60, false, "16:00", "20:00").validate("Montag"))
        assertNotNull(DayRule("limit", 0, false, "16:00", "20:00").validate("Montag"))
        assertNotNull(DayRule("limit", 1441, false, "16:00", "20:00").validate("Montag"))
        assertNotNull(DayRule("limit", 60, true, "16:00", "16:00").validate("Montag"))
        assertNotNull(DayRule("limit", 60, true, "25:00", "16:00").validate("Montag"))
        assertNull(DayRule("blocked", 0, true, "16:00", "16:00").validate("Montag"))  // Fenster bei gesperrt egal
        assertNull(DayRule("unlimited", 0, true, "22:00", "06:00").validate("Montag")) // über Mitternacht erlaubt
    }
}

/** Ein Relay-Server im Speicher (ntfy POST + textdb GET/POST) zum Prüfen von Client-Ablauf und Wire-Format. */
private class FakeHttp : Http {
    val requests = ArrayList<Triple<String, String, Map<String, String>>>()
    var posted: String? = null
    var statusBody: String? = null
    var statusCode = 200
    var fail: IOException? = null
    override fun request(method: String, url: String, headers: Map<String, String>, body: ByteArray?): HttpResult {
        requests.add(Triple(method, url, headers))
        fail?.let { throw it }
        if (method == "POST") { posted = body!!.toString(Charsets.UTF_8); return HttpResult(200, "{}".toByteArray()) }
        return HttpResult(statusCode, (statusBody ?: "").toByteArray())
    }
}

class RelayClientTest {
    private val pairing = Pairing(testKey())
    private val http = FakeHttp()
    private val client = RelayClient(pairing, "https://ntfy.example", "https://db.example/api/data", http) { 1_700_000_000_000L }

    @Test fun fetch_decrypts_status() {
        http.statusBody = StlCrypto.seal(pairing.key, STATUS_JSON)
        val r = client.fetchStatus()
        assertTrue(r is Fetch.Ok)
        assertEquals("Max", (r as Fetch.Ok).status.users[0].name)
        assertEquals(1_700_000_000_000L, r.fetchedAtMs)
        val (m, url, h) = http.requests.single()
        assertEquals("GET", m)
        assertEquals("https://db.example/api/data/${pairing.dbKey}?t=1700000000000", url)
        assertEquals("no-cache", h["Cache-Control"])
    }

    @Test fun fetch_states() {
        http.statusBody = ""; assertTrue(client.fetchStatus() is Fetch.NoData)
        http.statusCode = 404; assertTrue(client.fetchStatus() is Fetch.NoData)
        http.statusCode = 200; http.statusBody = StlCrypto.seal(ByteArray(32) { 9 }, STATUS_JSON); assertTrue(client.fetchStatus() is Fetch.BadData)
        http.statusBody = StlCrypto.seal(pairing.key, "{\"v\":9}"); assertTrue(client.fetchStatus() is Fetch.BadData)
        http.statusCode = 503; assertTrue(client.fetchStatus() is Fetch.Unreachable)
        http.fail = IOException("down"); assertTrue(client.fetchStatus() is Fetch.Unreachable)
    }

    @Test fun send_posts_encrypted_command_with_tag_to_topic() {
        val r = client.send("add_minutes", "Max", 15, "1234", null, id = "cmd-1")
        assertTrue(r is SendResult.Sent); assertEquals("cmd-1", (r as SendResult.Sent).id)
        val (m, url, h) = http.requests.single()
        assertEquals("POST", m); assertEquals("https://ntfy.example/${pairing.topic}", url)
        assertEquals("stl-cmd", h["Tags"])
        val body = http.posted!!
        assertFalse("PIN darf nicht im Klartext übertragen werden", body.contains("1234"))
        assertTrue(body.toByteArray().size < 4096)
        val c = JSONObject(StlCrypto.open(pairing.key, body)!!)
        assertEquals(1, c.getInt("v")); assertEquals("cmd-1", c.getString("id")); assertEquals("add_minutes", c.getString("action"))
        assertEquals("Max", c.getString("user")); assertEquals(15, c.getInt("minutes")); assertEquals("1234", c.getString("pin"))
        assertFalse(c.has("days"))
    }

    @Test fun password_with_letters_and_symbols_survives_encryption_unchanged() {
        for (pw in listOf("Gut3s!Passwort", "a\"b\\c'd\$e/f#g", "S3cret!Pa\$\$w0rd#2026", "x".repeat(32))) {
            client.send("add_minutes", "Max", 5, pw, null, id = "pw-1")
            val body = http.posted!!
            assertFalse("Passwort darf nicht im Klartext übertragen werden", body.contains(pw))
            assertTrue(body.toByteArray().size < 4096)
            assertEquals(pw, JSONObject(StlCrypto.open(pairing.key, body)!!).getString("pin"))
        }
    }

    @Test fun set_plan_with_longest_password_stays_below_ntfy_limit() {
        val days = (0 until 7).map { DayRule("limit", 120, true, "16:00", "20:00") }
        client.send("set_plan", null, null, "Z9!".repeat(10) + "ab", days, id = "0123456789abcdef0123456789abcdef")
        assertTrue(http.posted!!.toByteArray().size < 4096)
    }

    @Test fun set_plan_command_has_seven_days_with_boolean_window_flag() {
        val days = (0 until 7).map { DayRule("limit", 60 + it, it % 2 == 0, "16:00", "20:00") }
        client.send("set_plan", null, null, "4321", days, id = "p1")
        val c = JSONObject(StlCrypto.open(pairing.key, http.posted!!)!!)
        val arr = c.getJSONArray("days")
        assertEquals(7, arr.length())
        assertTrue(arr.getJSONObject(0).get("window_enabled") is Boolean)
        assertEquals(61, arr.getJSONObject(1).getInt("limit_minutes"))
        assertFalse(c.has("user"))
        assertTrue(http.posted!!.toByteArray().size < 4096)
    }

    @Test fun refresh_has_no_pin_and_send_failure_is_reported() {
        client.send("refresh", null, null, null, null, id = "r1")
        assertFalse(JSONObject(StlCrypto.open(pairing.key, http.posted!!)!!).has("pin"))
        http.fail = IOException("x")
        assertTrue(client.send("refresh", null, null, null, null) is SendResult.Failed)
    }

    @Test fun command_ids_match_pc_pattern_and_differ() {
        val a = Commands.newId(); val b = Commands.newId()
        assertTrue(Regex("^[A-Za-z0-9_-]{1,64}$").matches(a)); assertNotEquals(a, b)
    }

    @Test fun http_implementation_refuses_cleartext() {
        try { UrlConnectionHttp.request("GET", "http://example.org/", emptyMap(), null); fail() } catch (e: IllegalArgumentException) { }
    }
}

class PinPolicyTest {
    @Test fun old_digit_pins_stay_valid() {
        for (p in listOf("1234", "00000000", "12345678")) assertTrue(p, PinPolicy.isValid(p))
    }
    @Test fun letters_digits_and_symbols_are_valid() {
        for (p in listOf("Abcd1234", "Gut3s!Passwort", "p@ss-w0rd_#", "a\"b\\c'd", "x".repeat(32), "abcd")) assertTrue(p, PinPolicy.isValid(p))
    }
    @Test fun invalid_values_are_rejected() {
        for (p in listOf("", "123", "abc", "x".repeat(33), "ab cd", " 1234", "1234 ", "pässwort", "pass\nwort", "pass\u0000word", "\uD83D\uDE00abcd")) assertFalse(p, PinPolicy.isValid(p))
    }
    @Test fun sanitize_drops_forbidden_characters_and_limits_length() {
        assertEquals("Gut3s!Pss", PinPolicy.sanitize("Gut3s! Pä ss"))
        assertEquals(32, PinPolicy.sanitize("y".repeat(50)).length)
        assertEquals("", PinPolicy.sanitize(" äöü "))
    }
}
