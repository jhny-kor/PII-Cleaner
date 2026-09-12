from __future__ import annotations

import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZIP_DEFLATED, ZipFile

from app.processing.external_documents import (
    ExternalDocumentProcessError,
    process_hwp,
    process_legacy_office,
)


HWP5_HEADER = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


class ExternalDocumentTests(unittest.TestCase):
    def test_hwp_roundtrip_verifies_the_edited_markdown_and_uses_offline_environment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.hwp"
            destination = root / "result.hwp"
            source.write_bytes(HWP5_HEADER + b"original")
            calls = 0

            def fake_run(command: list[str], **kwargs: object) -> object:
                nonlocal calls
                calls += 1
                output = Path(command[command.index("--output") + 1])
                if calls == 1:
                    output.write_text("phone=010-1234-5678", encoding="utf-8")
                elif calls == 2:
                    output.write_bytes(HWP5_HEADER + b"patched")
                else:
                    output.write_text("phone=[PHONE_1]", encoding="utf-8")
                self.assertFalse(kwargs["shell"])
                self.assertEqual(kwargs["env"]["KORDOC_OFFLINE"], "1")
                return type("Completed", (), {"returncode": 0})()

            with patch("app.processing.external_documents._kordoc_command", return_value=["node", "kordoc"]), patch(
                "app.processing.external_documents.subprocess.run", side_effect=fake_run
            ):
                process_hwp(source, destination, lambda text: text.replace("010-1234-5678", "[PHONE_1]"))

            self.assertEqual(calls, 3)
            self.assertEqual(destination.read_bytes(), HWP5_HEADER + b"patched")
            self.assertEqual(source.read_bytes(), HWP5_HEADER + b"original")

    def test_hwp_rejects_non_hwp5_before_starting_kordoc(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "old.hwp"
            source.write_bytes(b"HWP Document File V3.00")
            with patch("app.processing.external_documents._kordoc_command") as command, self.assertRaises(
                ExternalDocumentProcessError
            ):
                process_hwp(source, Path(directory) / "result.hwp", lambda text: text)
            command.assert_not_called()

    def test_legacy_office_conversion_reuses_xml_rewriter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.xls"
            destination = root / "result.xlsx"
            source.write_bytes(b"legacy xls")
            before = hashlib.sha256(source.read_bytes()).hexdigest()

            def fake_convert(_source: Path, output: Path, _suffix: str) -> None:
                with ZipFile(output / "source.xlsx", "w", compression=ZIP_DEFLATED) as package:
                    package.writestr(
                        "xl/worksheets/sheet1.xml",
                        '<sheet><t>phone=010-1234-5678</t></sheet>',
                    )

            with patch("app.processing.external_documents._convert_with_libreoffice", side_effect=fake_convert):
                process_legacy_office(
                    source,
                    destination,
                    lambda text: text.replace("010-1234-5678", "[PHONE_1]"),
                )

            with ZipFile(destination) as package:
                self.assertIn(b"[PHONE_1]", package.read("xl/worksheets/sheet1.xml"))
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), before)


if __name__ == "__main__":
    unittest.main()
