from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    manifest_path = ROOT / "pocketools" / "sessionkeep" / "pocketool.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    required = {
        "schemaVersion",
        "id",
        "name",
        "version",
        "description",
        "license",
        "platform",
        "help",
        "commands",
        "requires",
        "install",
    }
    missing = sorted(required - manifest.keys())
    if missing or manifest.get("id") != "sessionkeep":
        raise RuntimeError(
            "Manifiesto Session Keep no válido: " + ", ".join(missing)
        )
    for relative in manifest["install"]["requiredFiles"]:
        if not (manifest_path.parent / relative).is_file():
            raise RuntimeError(f"Falta el archivo declarado {relative}")
    sessionkeep = ROOT / "pocketools" / "sessionkeep" / "src" / "sessionkeep.ps1"
    with tempfile.TemporaryDirectory() as temporary:
        environment = dict(__import__("os").environ)
        environment["EAP_POCKETOOL_DATA"] = temporary
        environment["EAP_SESSIONKEEP_TEST_MODE"] = "1"
        command = [
            "powershell.exe",
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(sessionkeep),
        ]
        completed = subprocess.run(
            [*command, "--help"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0 or "sessionkeep start" not in completed.stdout:
            raise RuntimeError(
                "La ayuda de sessionkeep falló:\n"
                + completed.stdout
                + completed.stderr
            )
        started = subprocess.run(
            [*command, "start"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        try:
            status = subprocess.run(
                [*command, "status"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            if started.returncode != 0 or status.returncode != 0:
                raise RuntimeError(
                    "El ciclo start/status de sessionkeep falló:\n"
                    + started.stdout
                    + started.stderr
                    + status.stdout
                    + status.stderr
                )
        finally:
            stopped = subprocess.run(
                [*command, "stop"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
        if stopped.returncode != 0:
            raise RuntimeError(
                "La parada de sessionkeep falló:\n"
                + stopped.stdout
                + stopped.stderr
            )
    print("Manifiesto y ciclo start/status/stop de Session Keep: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
