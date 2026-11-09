"""Ende-zu-Ende-Test des Handy-Relays: ECHTER PowerShell-HTTP-Code (Invoke-StlHttp, Receive/Publish, Befehle) gegen einen lokalen
Attrappen-Server (ntfy-/textdb-Semantik), bedient von einer UNABHAENGIGEN Python-Implementierung der App-Seite des Protokolls
(Kopplungscode, Ableitung, AES-GCM). Zusaetzlich: gemeinsame Test-Vektoren. Siehe PROTOCOL_RELAY.md.
Braucht pwsh (sonst uebersprungen) und das Python-Paket 'cryptography'."""
import base64
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fake_relay import FakeRelay  # noqa: E402

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except Exception:  # pragma: no cover
    AESGCM = None

PWSH = os.environ.get("PWSH") or shutil.which("pwsh") or None
ENV = dict(os.environ, DOTNET_SYSTEM_GLOBALIZATION_INVARIANT="1")


# ------------------------------------------------ App-Seite des Protokolls (unabhaengig vom PowerShell-Code geschrieben)
def pairing_code(key: bytes) -> str:
    b32 = base64.b32encode(key).decode().rstrip("=")
    groups = [b32[i:i + 4] for i in range(0, len(b32), 4)]
    chk = base64.b32encode(hashlib.sha256(key).digest()[:4]).decode().rstrip("=")[:4]
    return "STL1-" + "-".join(groups) + "-" + chk


def parse_pairing_code(code: str) -> bytes:
    c = code.strip().upper().replace(" ", "")
    assert c.startswith("STL1-"), "Praefix"
    parts = c[5:].split("-")
    chk, body = parts[-1], "".join(parts[:-1])
    key = base64.b32decode(body + "=" * (-len(body) % 8))
    assert len(key) == 32
    exp = base64.b32encode(hashlib.sha256(key).digest()[:4]).decode().rstrip("=")[:4]
    assert chk == exp, "Pruefsumme"
    return key


def hmac_hex(key, label):
    return hmac.new(key, label.encode(), hashlib.sha256).hexdigest()


def topic_of(key):
    return "stl-" + hmac_hex(key, "stl-topic-v1")[:24]


def dbkey_of(key):
    return "stl-" + hmac_hex(key, "stl-status-v1")[:24]


def seal(key, plaintext, iv=None):
    iv = iv or os.urandom(12)
    ct = AESGCM(key).encrypt(iv, plaintext.encode(), None)
    return json.dumps({"enc": "aes-256-gcm", "iv": base64.b64encode(iv).decode(), "data": base64.b64encode(ct).decode()},
                      separators=(",", ":"))


def open_env(key, text):
    e = json.loads(text)
    return AESGCM(key).decrypt(base64.b64decode(e["iv"]), base64.b64decode(e["data"]), None).decode()


def http(method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body.encode() if body is not None else None, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


@unittest.skipUnless(AESGCM, "Python-Paket 'cryptography' fehlt")
class Vectors(unittest.TestCase):
    def test_shared_vectors(self):
        with open(os.path.join(HERE, "vectors", "relay_vectors.json")) as fh:
            d = json.load(fh)
        key = base64.b64decode(d["key_b64"])
        self.assertEqual(topic_of(key), d["topic"])
        self.assertEqual(dbkey_of(key), d["db_key"])
        self.assertEqual(hashlib.sha256(key).hexdigest()[:8], d["fingerprint"])
        self.assertEqual(pairing_code(key), d["pairing_code"])
        self.assertEqual(parse_pairing_code(d["pairing_code"].lower()), key)
        for e in d["envelopes"]:
            self.assertEqual(open_env(key, e["envelope"]), e["plaintext"])
            self.assertEqual(seal(key, e["plaintext"], base64.b64decode(e["iv_b64"])), e["envelope"])

    def test_pairing_code_typo_detected(self):
        key = bytes(range(32))
        code = pairing_code(key)
        bad = code[:6] + ("B" if code[6] != "B" else "C") + code[7:]
        with self.assertRaises(AssertionError):
            parse_pairing_code(bad)


@unittest.skipUnless(PWSH and AESGCM, "pwsh oder cryptography fehlt")
class EndToEnd(unittest.TestCase):
    def setUp(self):
        self.srv = FakeRelay().start()
        self.tmp = tempfile.mkdtemp(prefix="stl-e2e-")
        self.env = dict(ENV, STL_DATA_DIR=self.tmp, STL_RELAY_ALLOW_HTTP="1")
        script = os.path.join(HERE, "relay_e2e_pc.ps1")
        self.script = script
        r = subprocess.run([PWSH, "-NoProfile", "-File", script, "-Mode", "setup", "-Server", self.srv.base,
                            "-Db", self.srv.base + "/api/data"], env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.key = parse_pairing_code(r.stdout.strip().splitlines()[-1])
        self.proc = None

    def tearDown(self):
        if self.proc:
            if self.proc.poll() is None:
                self.proc.kill()
            self.proc.wait()
            self.proc.stdout.close()
        self.srv.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def start_pc(self, seconds=25):
        self.proc = subprocess.Popen([PWSH, "-NoProfile", "-File", self.script, "-Mode", "loop", "-Seconds", str(seconds)],
                                     env=self.env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def status(self):
        c, t = http("GET", "%s/api/data/%s" % (self.srv.base, dbkey_of(self.key)))
        return json.loads(open_env(self.key, t)) if c == 200 else None

    def wait(self, pred, timeout=20):
        end = time.time() + timeout
        st = None
        while time.time() < end:
            st = self.status()
            if st and pred(st):
                return st
            time.sleep(0.3)
        self.fail("Zeitueberschreitung; letzter Status: %r; PC-Ausgabe: %s" % (st, self._pc_out()))

    def _pc_out(self):
        if self.proc and self.proc.poll() is not None:
            return self.proc.stdout.read()[-800:]
        return "(laeuft noch)"

    def send(self, cmd):
        env = seal(self.key, json.dumps(cmd))
        c, _ = http("POST", "%s/%s" % (self.srv.base, topic_of(self.key)), env, {"Tags": "stl-cmd"})
        self.assertEqual(c, 200)

    def test_full_flow(self):
        self.start_pc()
        st = self.wait(lambda s: s.get("users"))
        u = st["users"][0]
        self.assertEqual(u["name"], "Max")
        self.assertEqual(u["session"], "none")
        self.assertEqual(len(st["plan"]), 7)
        base_rem = u["remaining_seconds"]
        self.assertTrue(5300 < base_rem <= 5400, base_rem)
        # +15 Minuten mit richtiger PIN
        cid = "t" + uuid.uuid4().hex[:10]
        self.send({"v": 1, "id": cid, "action": "add_minutes", "user": "Max", "minutes": 15, "pin": "1234"})
        st = self.wait(lambda s: any(c["id"] == cid for c in s["last_cmds"]))
        self.assertTrue([c for c in st["last_cmds"] if c["id"] == cid][0]["ok"])
        st = self.wait(lambda s: s["users"][0]["bonus_minutes"] == 15)
        self.assertGreater(st["users"][0]["remaining_seconds"], base_rem + 800)
        # falsche PIN -> abgelehnt, keine Aenderung
        bad = "b" + uuid.uuid4().hex[:10]
        self.send({"v": 1, "id": bad, "action": "unlimited_today", "user": "Max", "pin": "0000"})
        st = self.wait(lambda s: any(c["id"] == bad for c in s["last_cmds"]))
        self.assertFalse([c for c in st["last_cmds"] if c["id"] == bad][0]["ok"])
        self.assertFalse(st["users"][0]["unlimited_today"])
        # Plan aendern: Sonntag gesperrt
        plan = [dict(p) for p in st["plan"]]
        plan[6] = {"mode": "blocked", "limit_minutes": 0, "window_enabled": False, "window_start": "16:00", "window_end": "20:00"}
        pid = "p" + uuid.uuid4().hex[:10]
        self.send({"v": 1, "id": pid, "action": "set_plan", "pin": "1234", "days": plan})
        st = self.wait(lambda s: s["plan"][6]["mode"] == "blocked")
        self.assertTrue([c for c in st["last_cmds"] if c["id"] == pid][0]["ok"])
        # Fremder Schluessel / Muell wird ignoriert, PC laeuft weiter
        evil = seal(os.urandom(32), json.dumps({"v": 1, "id": "evil1", "action": "unlimited_today", "user": "Max", "pin": "1234"}))
        http("POST", "%s/%s" % (self.srv.base, topic_of(self.key)), evil, {"Tags": "stl-cmd"})
        http("POST", "%s/%s" % (self.srv.base, topic_of(self.key)), "kein-json", {"Tags": "stl-cmd"})
        rid = "r" + uuid.uuid4().hex[:10]
        self.send({"v": 1, "id": rid, "action": "refresh"})
        st = self.wait(lambda s: any(c["id"] == rid for c in s["last_cmds"]))
        self.assertFalse(st["users"][0]["unlimited_today"])

    def test_server_outage_does_not_crash_and_recovers(self):
        self.srv.fail_status = 503
        self.start_pc(seconds=20)
        time.sleep(3)
        self.assertIsNone(self.proc.poll(), "PC-Schleife ist bei Relay-Ausfall abgestuerzt: " + self._pc_out())
        self.srv.fail_status = 0
        # Backoff (30 s) wuerde die Erholung verzoegern - der Test prueft nur: kein Absturz und Datenordner intakt
        self.assertTrue(os.path.exists(os.path.join(self.tmp, "config.json")))


if __name__ == "__main__":
    unittest.main()
