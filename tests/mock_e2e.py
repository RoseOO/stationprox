#!/usr/bin/env python3
"""End-to-end smoke test for the panel against a fake SSUI API.

Run: py -3 tests/mock_e2e.py
"""
import hashlib
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
import panel  # noqa: E402

SSUI = {
    "setup": True,
    "csrf": "csrf-token",
    "token": "panel-token",
    "running": False,
    "settings": {
        "serverName": "Test Base",
        "saveName": "MyMapName",
        "worldId": "Moon",
        "serverMaxPlayers": "8",
        "serverPassword": "",
        "gamePort": "27016",
        "autoSave": True,
        "saveInterval": "300",
        "autoStartServerOnStartup": False,
        "gameBranch": "public",
    },
}


class MockSSUI(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authed(self):
        if self.headers.get("Authorization") == "Bearer " + SSUI["token"]:
            return True
        return "SSUISession=session1" in (self.headers.get("Cookie") or "")

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api/v3/auth/setup":
            self.send(200, {"data": {"setupRequired": SSUI["setup"]}})
            return
        if not self.authed():
            self.send(401, {"error": {"code": "unauthorized", "message": "no"}})
            return
        if path == "/api/v3":
            self.send(200, {"data": {"apiVersion": "v3", "permissions": [
                "server.control", "server.view", "settings.view", "settings.manage"]}})
        elif path == "/api/v3/server/status":
            self.send(200, {"data": {"running": SSUI["running"], "state": "running" if SSUI["running"] else "stopped",
                                     "uptimeSeconds": 12}})
        elif path == "/api/v3/server/players":
            self.send(200, {"data": {"players": []}})
        elif path == "/api/v3/settings":
            self.send(200, {"data": SSUI["settings"]})
        elif path == "/api/v3/worldgen/catalog":
            self.send(200, {"data": {"worlds": [{"id": "Moon", "name": "Moon"}, {"id": "Mars", "name": "Mars"}]}})
        else:
            self.send(404, {"error": {"message": path}})

    def do_POST(self):
        path = self.path.split("?")[0]
        if path in ("/api/v3/auth/setup/bootstrap", "/api/v3/auth/login"):
            body = self.read_json()
            if body.get("username") != "admin" or body.get("password") != "ownerpass":
                self.send(401, {"error": {"code": "bad", "message": "bad credentials"}})
                return
            SSUI["setup"] = False
            body = json.dumps({"data": {"csrf": SSUI["csrf"], "user": {"username": "admin"}}}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", "SSUISession=session1; Path=/")
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/api/v3/auth/tokens":
            if self.headers.get("X-SSUI-CSRF") != SSUI["csrf"]:
                self.send(403, {"error": {"code": "csrf", "message": "csrf"}})
                return
            self.send(201, {"data": {"secret": SSUI["token"], "token": {"id": "1"}}})
            return
        if not self.authed():
            self.send(401, {"error": {"code": "unauthorized", "message": "no"}})
            return
        if path == "/api/v3/server/start":
            SSUI["running"] = True
            self.send(200, {"data": {}})
        elif path == "/api/v3/server/stop":
            SSUI["running"] = False
            self.send(200, {"data": {}})
        else:
            self.send(404, {"error": {"message": path}})

    def do_PATCH(self):
        if not self.authed():
            self.send(401, {"error": {"code": "unauthorized", "message": "no"}})
            return
        if self.path.split("?")[0] == "/api/v3/settings":
            SSUI["settings"].update(self.read_json())
            self.send(200, {"data": {"message": "ok"}})
        else:
            self.send(404, {"error": {"message": "no"}})


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def wait_for(url, timeout=25):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            urllib.request.urlopen(url, timeout=1)
            return
        except urllib.error.HTTPError:
            return
        except Exception:
            time.sleep(0.25)
    raise RuntimeError("timed out waiting for " + url)


def request(method, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), exc.headers


def main():
    tmp = tempfile.mkdtemp(prefix="stationeers-panel-test-")
    mock_port = free_port()
    panel_port = free_port()
    mock = ThreadingHTTPServer(("127.0.0.1", mock_port), MockSSUI)
    threading.Thread(target=mock.serve_forever, daemon=True).start()

    saves_dir = os.path.join(tmp, "saves")
    os.makedirs(saves_dir)
    config_path = os.path.join(tmp, "config.json")
    config = {
        "panel": {
            "username": "admin",
            "passwordHash": panel.hash_password("panelpass"),
            "port": panel_port,
            "tls": False,
            "tlsCert": "",
            "tlsKey": "",
        },
        "ssui": {
            "url": "http://127.0.0.1:%d" % mock_port,
            "username": "admin",
            "password": "ownerpass",
            "token": "",
            "tokenName": "stationeers-panel",
        },
        "paths": {"ssuiDir": tmp, "savesDir": saves_dir, "service": "ssui"},
    }
    with open(config_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh)

    env = dict(os.environ, STATIONEERS_PANEL_CONFIG=config_path, PYTHONUNBUFFERED="1")
    proc = subprocess.Popen([sys.executable, str(ROOT / "src" / "panel.py")], env=env)
    base = "http://127.0.0.1:%d" % panel_port
    try:
        wait_for(base + "/api/state")
        status, body, _headers = request(
            "POST", base + "/api/login",
            data=json.dumps({"username": "admin", "password": "panelpass"}).encode(),
            headers={"Content-Type": "application/json", "X-Requested-With": "stationeers-panel"},
        )
        assert status == 200, (status, body)
        # Recover the cookie from a fresh login (we need the header).
        req = urllib.request.Request(
            base + "/api/login",
            data=json.dumps({"username": "admin", "password": "panelpass"}).encode(),
            headers={"Content-Type": "application/json", "X-Requested-With": "stationeers-panel"},
        )
        with urllib.request.urlopen(req) as resp:
            cookie = resp.headers.get("Set-Cookie").split(";")[0]
        headers = {"Cookie": cookie, "X-Requested-With": "stationeers-panel"}

        deadline = time.time() + 20
        state = {}
        while time.time() < deadline:
            status, body, _ = request("GET", base + "/api/state", headers=headers)
            assert status == 200, (status, body)
            state = json.loads(body)
            if state.get("connected"):
                break
            time.sleep(0.5)
        assert state.get("connected"), state
        assert state["settings"]["saveName"] == "MyMapName", state

        # Upload a save folder containing world.xml.
        save_zip = os.path.join(tmp, "EuropaBase.zip")
        with zipfile.ZipFile(save_zip, "w") as zf:
            zf.writestr("EuropaBase/world.xml", "<World/>")
            zf.writestr("EuropaBase/world_meta.xml", "<Meta/>")
        payload = open(save_zip, "rb").read()
        status, body, _ = request(
            "POST", base + "/api/saves/upload?name=EuropaBase&overwrite=0",
            data=payload,
            headers=dict(headers, **{"X-Filename": "EuropaBase.zip"}),
        )
        assert status == 200, (status, body)
        assert os.path.isfile(os.path.join(saves_dir, "EuropaBase", "world.xml"))

        status, body, _ = request(
            "POST", base + "/api/saves/EuropaBase/activate",
            data=json.dumps({"launch": True}).encode(),
            headers=dict(headers, **{"Content-Type": "application/json"}),
        )
        assert status == 200, (status, body)
        assert SSUI["settings"]["saveName"] == "EuropaBase"
        assert SSUI["running"] is True

        # Regression: POST bodies must be consumed or keep-alive corrupts the
        # next request into "{}GET" (501 Unsupported method).
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", panel_port, timeout=10)
        conn.request(
            "POST", "/api/server/start", body="{}",
            headers={"Cookie": cookie, "X-Requested-With": "stationeers-panel",
                     "Content-Type": "application/json"},
        )
        first = conn.getresponse()
        first.read()
        assert first.status == 200, first.status
        conn.request("GET", "/api/state", headers={"Cookie": cookie})
        second = conn.getresponse()
        second_body = second.read()
        assert second.status == 200, (second.status, second_body)
        conn.close()

        # New-format upload: a .save file placed as <Station>/<Station>.save
        new_save = os.path.join(tmp, "NewStyle.save")
        with zipfile.ZipFile(new_save, "w") as zf:
            zf.writestr("world.xml", "<World/>")
            zf.writestr("world_meta.xml", "<Meta/>")
            zf.writestr("terrain.dat", b"\0" * 16)
        status, body, _ = request(
            "POST", base + "/api/saves/upload?name=NewStyle",
            data=open(new_save, "rb").read(),
            headers=dict(headers, **{"X-Filename": "NewStyle.save"}),
        )
        assert status == 200, (status, body)
        assert os.path.isfile(os.path.join(saves_dir, "NewStyle", "NewStyle.save"))

        # Zip of a whole station folder (new layout, .save plus autosaves)
        folder_zip = os.path.join(tmp, "FolderSave.zip")
        with zipfile.ZipFile(folder_zip, "w") as zf:
            zf.writestr("FolderSave/FolderSave.save", b"PK-dummy")
            zf.writestr("FolderSave/autosave/240126_120000_auto.save", b"PK-dummy2")
            zf.writestr("FolderSave/world_meta.xml", "<Meta/>")
        status, body, _ = request(
            "POST", base + "/api/saves/upload?name=FolderSave",
            data=open(folder_zip, "rb").read(),
            headers=dict(headers, **{"X-Filename": "FolderSave.zip"}),
        )
        assert status == 200, (status, body)
        assert os.path.isfile(os.path.join(saves_dir, "FolderSave", "FolderSave.save"))
        assert os.path.isfile(
            os.path.join(saves_dir, "FolderSave", "autosave", "240126_120000_auto.save")
        )

        status, body, _ = request("GET", base + "/api/state", headers=headers)
        assert status == 200
        listed = {save["name"]: save for save in json.loads(body)["saves"]}
        assert listed["NewStyle"]["legacy"] is False, listed
        assert listed["FolderSave"]["legacy"] is False, listed

        status, body, _ = request("GET", base + "/api/saves/EuropaBase/download", headers=headers)
        assert status == 200 and body.startswith(b"PK"), (status, body[:20])
        with zipfile.ZipFile(__import__("io").BytesIO(body)) as zf:
            assert "EuropaBase/world.xml" in zf.namelist()

        status, body, _ = request(
            "POST", base + "/api/settings",
            data=json.dumps({"serverName": "Renamed Base", "autoSave": False}).encode(),
            headers=dict(headers, **{"Content-Type": "application/json"}),
        )
        assert status == 200, (status, body)
        assert SSUI["settings"]["serverName"] == "Renamed Base"

        status, body, _ = request("DELETE", base + "/api/saves/EuropaBase", headers=headers)
        assert status == 409, (status, body)  # active save requires force

        print("ALL PANEL TESTS PASSED")
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        mock.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
