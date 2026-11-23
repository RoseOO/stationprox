#!/usr/bin/env python3
"""Build dist/stationeers.sh by embedding the panel into the installer."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
installer = (ROOT / "src" / "install.sh").read_text(encoding="utf-8")
panel_py = (ROOT / "src" / "panel.py").read_text(encoding="utf-8").rstrip("\n")
panel_html = (ROOT / "src" / "panel.html").read_text(encoding="utf-8").rstrip("\n")

for marker in ("@@PANEL_PY@@", "@@PANEL_HTML@@"):
    if installer.count(marker) != 1:
        raise SystemExit("marker %s must appear exactly once" % marker)

for name, payload in (("panel.py", panel_py), ("panel.html", panel_html)):
    if "PANEL_PY_EOF" in payload or "PANEL_HTML_EOF" in payload:
        raise SystemExit("payload %s collides with a heredoc terminator" % name)

out = installer.replace("@@PANEL_PY@@", panel_py).replace("@@PANEL_HTML@@", panel_html)
out = out.replace("\r\n", "\n")
if not out.endswith("\n"):
    out += "\n"

dist = ROOT
target = dist / "stationeers.sh"
target.write_text(out, encoding="utf-8", newline="\n")
target.chmod(0o755)
print("wrote %s (%d lines, %d bytes)" % (target, out.count("\n"), len(out.encode())))
