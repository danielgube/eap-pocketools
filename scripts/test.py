from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
POCKETOOLS = ROOT / "pocketools"
REQUIRED_MANIFEST_FIELDS = {
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


def run(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        text=True,
        errors="replace",
        capture_output=True,
        check=False,
    )


def powershell(script: Path) -> list[str]:
    return [
        "powershell.exe",
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
    ]


def assert_success(completed: subprocess.CompletedProcess[str], operation: str) -> None:
    if completed.returncode != 0:
        raise RuntimeError(
            f"{operation} falló con código {completed.returncode}:\n"
            + completed.stdout
            + completed.stderr
        )


def validate_manifests() -> dict[str, dict[str, object]]:
    manifests: dict[str, dict[str, object]] = {}
    commands: dict[str, str] = {}
    for manifest_path in sorted(POCKETOOLS.glob("*/pocketool.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        missing = sorted(REQUIRED_MANIFEST_FIELDS - manifest.keys())
        pocketool_id = str(manifest.get("id", ""))
        if missing or pocketool_id != manifest_path.parent.name:
            raise RuntimeError(
                f"Manifiesto no válido en {manifest_path}: "
                + (", ".join(missing) if missing else "id y carpeta no coinciden")
            )
        if manifest["schemaVersion"] != 1:
            raise RuntimeError(f"Schema no soportado en {manifest_path}")
        for relative in manifest["install"]["requiredFiles"]:
            if not (manifest_path.parent / relative).is_file():
                raise RuntimeError(
                    f"Falta el archivo declarado {relative} en {pocketool_id}"
                )
        for command in manifest["commands"]:
            name = str(command["name"]).casefold()
            if name in commands:
                raise RuntimeError(
                    f"Comando duplicado {name}: {commands[name]} y {pocketool_id}"
                )
            commands[name] = pocketool_id
            if not (manifest_path.parent / command["entrypoint"]).is_file():
                raise RuntimeError(
                    f"Entrypoint ausente {command['entrypoint']} en {pocketool_id}"
                )
        manifests[pocketool_id] = manifest
    if not manifests:
        raise RuntimeError("El repositorio no contiene Pocketools")
    return manifests


def test_sessionkeep() -> None:
    sessionkeep = POCKETOOLS / "sessionkeep" / "src" / "sessionkeep.ps1"
    with tempfile.TemporaryDirectory() as temporary:
        environment = dict(os.environ)
        environment["EAP_POCKETOOL_DATA"] = temporary
        environment["EAP_SESSIONKEEP_TEST_MODE"] = "1"
        command = powershell(sessionkeep)
        help_result = run([*command, "--help"], cwd=ROOT, environment=environment)
        assert_success(help_result, "La ayuda de Session Keep")
        if "sessionkeep start" not in help_result.stdout:
            raise RuntimeError("La ayuda de Session Keep no contiene su uso")

        started = run([*command, "start"], cwd=ROOT, environment=environment)
        try:
            status = run([*command, "status"], cwd=ROOT, environment=environment)
            assert_success(started, "El inicio de Session Keep")
            assert_success(status, "El estado de Session Keep")
        finally:
            stopped = run([*command, "stop"], cwd=ROOT, environment=environment)
        assert_success(stopped, "La parada de Session Keep")
    print("Ciclo start/status/stop de Session Keep: OK")


def selected_paths(output: str) -> set[str]:
    lines = [line.strip().replace("\\", "/") for line in output.splitlines()]
    marker = next(
        (index for index, line in enumerate(lines) if line.startswith("Archivos incluidos:")),
        None,
    )
    if marker is None:
        raise RuntimeError("ZipMe no informó de los archivos incluidos:\n" + output)
    return {line for line in lines[marker + 1 :] if line}


def write_project_file(root: Path, relative: str, content: str = "x\n") -> None:
    target = root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")


def find_seven_zip() -> Path | None:
    executable = shutil.which("7z.exe") or shutil.which("7z")
    if executable:
        return Path(executable)
    sibling_eap = ROOT.parent / "eap" / "core" / "tools" / "7zip" / "7z.exe"
    return sibling_eap if sibling_eap.is_file() else None


def test_zipme() -> None:
    zipme = POCKETOOLS / "zipme" / "src" / "zipme.ps1"
    command = powershell(zipme)
    with tempfile.TemporaryDirectory() as temporary:
        temporary_path = Path(temporary)
        state = temporary_path / "state"
        state.mkdir()
        environment = dict(os.environ)
        environment["EAP_POCKETOOL_DATA"] = str(state)

        help_result = run([*command, "--help"], cwd=ROOT, environment=environment)
        assert_success(help_result, "La ayuda de ZipMe")
        if "zipme [ruta]" not in help_result.stdout:
            raise RuntimeError("La ayuda de ZipMe no contiene su uso")

        defaults = temporary_path / "proyecto ágil sin ignore"
        write_project_file(defaults, "pom.xml")
        write_project_file(defaults, "src/main/App.java")
        write_project_file(defaults, "src/debug.log")
        write_project_file(defaults, "target/classes/App.class")
        write_project_file(defaults, "node_modules/lib/index.js")
        write_project_file(defaults, ".svn/entries")
        write_project_file(defaults, ".idea/workspace.xml")
        default_list = run(
            [*command, str(defaults), "-List"],
            cwd=ROOT,
            environment=environment,
        )
        assert_success(default_list, "La selección predeterminada de ZipMe")
        default_paths = selected_paths(default_list.stdout)
        expected_defaults = {"pom.xml", "src/main/App.java"}
        if default_paths != expected_defaults:
            raise RuntimeError(
                "Las exclusiones predeterminadas de ZipMe no coinciden:\n"
                f"esperado={sorted(expected_defaults)}\n"
                f"obtenido={sorted(default_paths)}"
            )

        ignored = temporary_path / "proyecto con ignore sin git"
        write_project_file(
            ignored,
            ".gitignore",
            "target/\ncache/\n*.log\n!important.log\n/generated/\n**/private.txt\n",
        )
        write_project_file(ignored, "src/main.txt")
        write_project_file(ignored, "src/debug.log")
        write_project_file(ignored, "src/important.log")
        write_project_file(ignored, "target/generated.txt")
        write_project_file(ignored, "cache", "archivo, no directorio\n")
        write_project_file(ignored, "generated/root.txt")
        write_project_file(ignored, "docs/private.txt")
        write_project_file(ignored, "docs/public.txt")
        write_project_file(ignored, "docs/.gitignore", "*.tmp\n!keep.tmp\n")
        write_project_file(ignored, "docs/drop.tmp")
        write_project_file(ignored, "docs/keep.tmp")
        write_project_file(ignored, ".svn/entries")
        expected_ignored = {
            ".gitignore",
            "docs/.gitignore",
            "docs/keep.tmp",
            "docs/public.txt",
            "src/important.log",
            "src/main.txt",
            "cache",
        }

        git_list = run(
            [*command, str(ignored), "-List"],
            cwd=ROOT,
            environment=environment,
        )
        assert_success(git_list, "La selección .gitignore de ZipMe")
        if selected_paths(git_list.stdout) != expected_ignored:
            raise RuntimeError(
                "ZipMe no respetó .gitignore en un proyecto sin repositorio:\n"
                + git_list.stdout
            )

        fallback_environment = dict(environment)
        fallback_environment["EAP_ZIPME_NO_GIT"] = "1"
        fallback_list = run(
            [*command, str(ignored), "-List"],
            cwd=ROOT,
            environment=fallback_environment,
        )
        assert_success(fallback_list, "El motor integrado .gitignore de ZipMe")
        if selected_paths(fallback_list.stdout) != expected_ignored:
            raise RuntimeError(
                "El motor integrado de ZipMe no respetó .gitignore:\n"
                + fallback_list.stdout
            )

        seven_zip = find_seven_zip()
        if seven_zip is not None:
            archive = temporary_path / "compartir.7z"
            archive_environment = dict(environment)
            archive_environment["EAP_ZIPME_7Z"] = str(seven_zip)
            archived = run(
                [*command, str(defaults), "-Output", str(archive)],
                cwd=ROOT,
                environment=archive_environment,
            )
            assert_success(archived, "La compresión de ZipMe")
            if not archive.is_file():
                raise RuntimeError("ZipMe no creó el archivo esperado")

            stale = defaults / "stale.txt"
            stale.write_text("obsoleto\n", encoding="utf-8")
            with_stale = run(
                [*command, str(defaults), "-Output", str(archive)],
                cwd=ROOT,
                environment=archive_environment,
            )
            assert_success(with_stale, "La actualización del archivo ZipMe")
            stale.unlink()
            rebuilt = run(
                [*command, str(defaults), "-Output", str(archive)],
                cwd=ROOT,
                environment=archive_environment,
            )
            assert_success(rebuilt, "La reconstrucción del archivo ZipMe")
            listing = run(
                [str(seven_zip), "l", "-slt", str(archive)],
                cwd=ROOT,
                environment=archive_environment,
            )
            assert_success(listing, "La lectura del archivo creado por ZipMe")
            normalized_listing = listing.stdout.replace("\\", "/")
            for included in expected_defaults:
                if f"Path = {included}" not in normalized_listing:
                    raise RuntimeError(f"El archivo no contiene {included}")
            for excluded in ("target/classes/App.class", "node_modules/lib/index.js"):
                if f"Path = {excluded}" in normalized_listing:
                    raise RuntimeError(f"El archivo incluyó indebidamente {excluded}")
            for excluded in ("stale.txt",):
                if f"Path = {excluded}" in normalized_listing:
                    raise RuntimeError(f"El archivo incluyó indebidamente {excluded}")
            print("Creación y contenido del archivo ZipMe: OK")
        else:
            print("Creación del archivo ZipMe: OMITIDA (7z no disponible)")
    print("Selección predeterminada y .gitignore de ZipMe: OK")


def main() -> int:
    manifests = validate_manifests()
    expected = {"sessionkeep", "zipme"}
    if set(manifests) != expected:
        raise RuntimeError(
            f"Pocketools inesperadas: esperado={sorted(expected)}, "
            f"obtenido={sorted(manifests)}"
        )
    print(f"Manifiestos Pocketool válidos: {', '.join(sorted(manifests))}")
    test_sessionkeep()
    test_zipme()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
