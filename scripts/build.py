from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import zipfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
POCKETOOLS = ROOT / "pocketools"
DIST = ROOT / "dist"
CATALOG = ROOT / "pocketools.catalog.json"
REPOSITORY = "https://github.com/danielgube/eap-pocketools"
FIXED_TIMESTAMP = (2026, 1, 1, 0, 0, 0)


def load_manifest(directory: Path) -> dict:
    path = directory / "pocketool.json"
    value = json.loads(path.read_text(encoding="utf-8"))
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
    missing = sorted(required - value.keys())
    if missing:
        raise ValueError(f"{path}: faltan {', '.join(missing)}")
    if value["schemaVersion"] != 1 or value["id"] != directory.name:
        raise ValueError(f"{path}: identidad o schema no válido")
    return value


def package_files(directory: Path) -> list[Path]:
    ignored = {"__pycache__", ".pytest_cache"}
    files = sorted(
        (
            path
            for path in directory.rglob("*")
            if path.is_file()
            and not any(part in ignored for part in path.relative_to(directory).parts)
            and path.suffix.casefold() not in {".pyc", ".pyo"}
        ),
        key=lambda path: path.relative_to(directory).as_posix().casefold(),
    )
    linked = [path for path in files if path.is_symlink()]
    if linked:
        raise ValueError(f"No se admiten enlaces simbólicos: {linked[0]}")
    return files


def build_archive(directory: Path, manifest: dict) -> Path:
    DIST.mkdir(parents=True, exist_ok=True)
    destination = DIST / f"{manifest['id']}-{manifest['version']}.zip"
    temporary = destination.with_suffix(".zip.partial")
    temporary.unlink(missing_ok=True)
    with zipfile.ZipFile(
        temporary,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for source in package_files(directory):
            relative = PurePosixPath(source.relative_to(directory).as_posix())
            info = zipfile.ZipInfo(str(relative), FIXED_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, source.read_bytes(), compresslevel=9)
    temporary.replace(destination)
    return destination


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Construir EAP Pocketools")
    parser.add_argument("--pocketool")
    parser.add_argument("--version")
    arguments = parser.parse_args()
    if arguments.pocketool and not arguments.version:
        parser.error("--pocketool requiere --version")
    DIST.mkdir(parents=True, exist_ok=True)
    if not arguments.pocketool:
        shutil.rmtree(DIST)
        DIST.mkdir(parents=True)
    entries = []
    for directory in sorted(POCKETOOLS.iterdir(), key=lambda path: path.name):
        if not directory.is_dir():
            continue
        manifest = load_manifest(directory)
        archive = build_archive(directory, manifest)
        entries.append(
            {
                **manifest,
                "artifact": {
                    "url": (
                        f"{REPOSITORY}/releases/download/"
                        f"{manifest['id']}-v{manifest['version']}/{archive.name}"
                    ),
                    "fileName": archive.name,
                    "sha256": sha256(archive),
                    "size": archive.stat().st_size,
                },
            }
        )
    catalog = {
        "schemaVersion": 1,
        "repository": {
            "id": "danielgube",
            "name": "DanielGube EAP Pocketools",
            "url": REPOSITORY,
        },
        "pocketools": entries,
    }
    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    if arguments.pocketool:
        selected = next(
            (
                entry
                for entry in entries
                if entry["id"] == arguments.pocketool
                and entry["version"] == arguments.version
            ),
            None,
        )
        if selected is None:
            raise ValueError(
                f"No existe {arguments.pocketool} {arguments.version}"
            )
        print(DIST / selected["artifact"]["fileName"])
    else:
        print(f"{len(entries)} Pocketool(s) construida(s) en {DIST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
