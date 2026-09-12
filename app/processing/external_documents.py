from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path

from app.runtime import bundle_root

from .structured_documents import rewrite_document


LEGACY_OFFICE_OUTPUTS = {".doc": ".docx", ".xls": ".xlsx"}
HWP5_MAGIC = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"
MAX_DOCUMENT_BYTES = 500 * 1024 * 1024
PROCESS_TIMEOUT_SECONDS = 180


class ExternalDocumentError(RuntimeError):
    pass


class ExternalEngineUnavailableError(ExternalDocumentError):
    pass


class ExternalDocumentProcessError(ExternalDocumentError):
    pass


def process_hwp(path: Path, destination: Path, transform: Callable[[str], str]) -> None:
    """Use Kordoc's markdown round-trip while keeping the source untouched."""
    _check_size(path)
    _require_hwp5(path)
    command = _kordoc_command()
    with tempfile.TemporaryDirectory(prefix="pii-cleaner-kordoc-") as directory:
        work = Path(directory)
        markdown_path = work / "parsed.md"
        edited_path = work / "edited.md"
        verified_path = work / "verified.md"
        _run(command + ["--silent", "--format", "markdown", "--output", str(markdown_path), str(path)])
        markdown = _read_utf8(markdown_path)
        if not markdown.strip():
            raise ExternalDocumentProcessError("HWP에서 검사할 텍스트를 추출하지 못했습니다.")
        edited = transform(markdown)
        if edited == markdown:
            shutil.copyfile(path, destination)
            return
        _write_utf8(edited_path, edited)
        _run(
            command
            + [
                "--silent",
                "patch",
                str(path),
                str(edited_path),
                "--output",
                str(destination),
            ]
        )
        if not destination.is_file() or destination.stat().st_size == 0:
            raise ExternalDocumentProcessError("Kordoc 패치 결과가 생성되지 않았습니다.")
        _run(
            command
            + [
                "--silent",
                "--format",
                "markdown",
                "--output",
                str(verified_path),
                str(destination),
            ]
        )
        if _canonical_markdown(_read_utf8(verified_path)) != _canonical_markdown(edited):
            raise ExternalDocumentProcessError("Kordoc 패치 후 재파싱 검증에 실패했습니다.")


def process_legacy_office(
    path: Path,
    destination: Path,
    transform: Callable[[str], str],
) -> None:
    """Convert legacy Office input to OOXML, then reuse the XML-safe rewriter."""
    _check_size(path)
    output_suffix = LEGACY_OFFICE_OUTPUTS.get(path.suffix.lower())
    if output_suffix is None:
        raise ExternalDocumentProcessError("레거시 Office 형식이 아닙니다.")
    with tempfile.TemporaryDirectory(prefix="pii-cleaner-office-") as directory:
        work = Path(directory)
        source = work / f"source{path.suffix.lower()}"
        converted = work / "converted"
        converted.mkdir()
        shutil.copyfile(path, source)
        _convert_with_libreoffice(source, converted, output_suffix)
        converted_path = converted / f"{source.stem}{output_suffix}"
        if not converted_path.is_file() or converted_path.stat().st_size == 0:
            raise ExternalDocumentProcessError("LibreOffice 변환 결과가 생성되지 않았습니다.")
        rewrite_document(converted_path, destination, transform)


def legacy_output_suffix(suffix: str) -> str:
    return LEGACY_OFFICE_OUTPUTS.get(suffix.lower(), suffix)


def _kordoc_command() -> list[str]:
    configured_cli = _env_file("PII_CLEANER_KORDOC_CLI")
    if configured_cli:
        if configured_cli.suffix.lower() in {".cmd", ".bat", ".exe"}:
            return [str(configured_cli)]
        return [str(_node_executable()), str(configured_cli)]

    for root in _runtime_roots():
        for candidate in (
            root / "engines" / "kordoc" / "node_modules" / "kordoc" / "dist" / "cli.js",
            root / "vendor" / "kordoc" / "node_modules" / "kordoc" / "dist" / "cli.js",
            root / "engines" / "kordoc" / "dist" / "cli.js",
        ):
            if candidate.is_file():
                return [str(_node_executable()), str(candidate)]

    executable = shutil.which("kordoc")
    if executable:
        return [executable]
    raise ExternalEngineUnavailableError("Kordoc 실행 파일을 찾지 못했습니다.")


def _node_executable() -> Path:
    configured = _env_file("PII_CLEANER_NODE")
    if configured:
        return configured
    for root in _runtime_roots():
        for candidate in (
            root / "engines" / "node" / "node.exe",
            root / "engines" / "node" / "node",
            root / "vendor" / "node" / "node.exe",
            root / "vendor" / "node" / "node",
        ):
            if candidate.is_file():
                return candidate
    executable = shutil.which("node")
    if executable:
        return Path(executable)
    raise ExternalEngineUnavailableError("Node.js 실행 파일을 찾지 못했습니다.")


def _convert_with_libreoffice(source: Path, destination: Path, output_suffix: str) -> None:
    executable = _libreoffice_executable()
    profile = destination.parent / "profile"
    profile.mkdir()
    command = [
        str(executable),
        "--headless",
        "--nologo",
        "--nodefault",
        "--norestore",
        "--nofirststartwizard",
        "--nolockcheck",
        f"-env:UserInstallation={profile.resolve().as_uri()}",
        "--convert-to",
        output_suffix.lstrip("."),
        "--outdir",
        str(destination),
        str(source),
    ]
    _run(command)


def _libreoffice_executable() -> Path:
    configured = _env_file("PII_CLEANER_SOFFICE")
    if configured:
        return configured
    for root in _runtime_roots():
        for candidate in (
            root / "engines" / "libreoffice" / "program" / "soffice.com",
            root / "engines" / "libreoffice" / "program" / "soffice.exe",
            root / "engines" / "libreoffice" / "program" / "soffice",
            root / "vendor" / "libreoffice" / "program" / "soffice.com",
            root / "vendor" / "libreoffice" / "program" / "soffice.exe",
            root / "vendor" / "libreoffice" / "program" / "soffice",
        ):
            if candidate.is_file():
                return candidate
    for name in ("soffice.com", "soffice.exe", "soffice"):
        executable = shutil.which(name)
        if executable:
            return Path(executable)
    raise ExternalEngineUnavailableError("LibreOffice 실행 파일을 찾지 못했습니다.")


def _run(command: list[str]) -> None:
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            env={
                **os.environ,
                "KORDOC_OFFLINE": "1",
                "HF_HUB_OFFLINE": "1",
                "TRANSFORMERS_OFFLINE": "1",
            },
            shell=False,
            timeout=PROCESS_TIMEOUT_SECONDS,
        )
    except (FileNotFoundError, PermissionError) as exc:
        raise ExternalEngineUnavailableError("문서 엔진을 실행하지 못했습니다.") from exc
    except subprocess.TimeoutExpired as exc:
        raise ExternalDocumentProcessError("문서 엔진 실행 시간이 제한을 초과했습니다.") from exc
    except OSError as exc:
        raise ExternalDocumentProcessError("문서 엔진을 실행하지 못했습니다.") from exc
    if result.returncode != 0:
        raise ExternalDocumentProcessError("문서 엔진이 파일을 처리하지 못했습니다.")


def _env_file(name: str) -> Path | None:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return None
    path = Path(raw).expanduser()
    if not path.is_file():
        raise ExternalEngineUnavailableError(f"설정된 문서 엔진 경로를 찾지 못했습니다: {name}")
    return path.resolve()


def _runtime_roots() -> tuple[Path, ...]:
    roots = [bundle_root()]
    if getattr(sys, "frozen", False):
        executable_root = Path(sys.executable).resolve().parent
        roots.extend((executable_root, executable_root / "_internal"))
    return tuple(dict.fromkeys(roots))


def _check_size(path: Path) -> None:
    try:
        if path.stat().st_size > MAX_DOCUMENT_BYTES:
            raise ExternalDocumentProcessError("문서 크기가 허용 한도를 초과했습니다.")
    except OSError as exc:
        raise ExternalDocumentProcessError("문서 상태를 확인하지 못했습니다.") from exc


def _require_hwp5(path: Path) -> None:
    try:
        with path.open("rb") as source:
            if source.read(len(HWP5_MAGIC)) != HWP5_MAGIC:
                raise ExternalDocumentProcessError(
                    "HWP 5.x 바이너리만 안전하게 수정할 수 있습니다. HWP 3.x/HWPML은 지원되지 않습니다."
                )
    except ExternalDocumentProcessError:
        raise
    except OSError as exc:
        raise ExternalDocumentProcessError("HWP 문서 형식을 확인하지 못했습니다.") from exc


def _read_utf8(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise ExternalDocumentProcessError("문서 엔진의 텍스트 결과를 읽지 못했습니다.") from exc


def _write_utf8(path: Path, text: str) -> None:
    try:
        with path.open("w", encoding="utf-8", newline="") as handle:
            handle.write(text)
    except OSError as exc:
        raise ExternalDocumentProcessError("문서 엔진 입력을 준비하지 못했습니다.") from exc


def _canonical_markdown(text: str) -> str:
    """Ignore Kordoc's required GFM escaping when comparing a round-trip."""
    return re.sub(r"\\([~*_`|])", r"\1", text)
