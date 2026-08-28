from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build.py")],
        cwd=ROOT,
        check=True,
    )
    catalog = json.loads(
        (ROOT / "pocketools.catalog.json").read_text(encoding="utf-8")
    )
    if catalog.get("schemaVersion") != 1 or not catalog.get("pocketools"):
        raise RuntimeError("El catálogo generado no contiene Pocketools")
    for entry in catalog["pocketools"]:
        archive = ROOT / "dist" / entry["artifact"]["fileName"]
        with zipfile.ZipFile(archive) as package:
            package.testzip()
            manifest = json.loads(package.read("pocketool.json"))
        if manifest != {
            key: value for key, value in entry.items() if key != "artifact"
        }:
            raise RuntimeError(
                f"El manifiesto empaquetado diverge para {entry['id']}"
            )
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
    print("Contrato, artefactos y ayuda de Session Keep: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
