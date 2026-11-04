import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("package_mcp", Path(__file__).with_name("package-mcp.py"))
package_mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_mcp)


class PackageMCPTests(unittest.TestCase):
    def fixture(self, root):
        bundle = root / "LAB.app"
        binaries = bundle / "Contents/MacOS"
        binaries.mkdir(parents=True)
        (binaries / "LAB").write_bytes(b"app before final package signing")
        (binaries / "lab-mcp").write_bytes(b"helper before final package signing")
        catalog = {"catalog_version": 1, "schema_fingerprint": "sha256:contract",
                   "tools": [{"name": "form_status", "inputSchema": {"type": "object"}}]}
        return bundle, catalog

    def test_bundle_records_exact_offline_catalog_and_deterministic_build_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, catalog = self.fixture(root)
            replies = [json.dumps(catalog).encode(), "0123456789abcdef\n", " M Sources/Test.swift\n"]
            with patch.object(package_mcp.subprocess, "check_output", side_effect=replies) as calls:
                package_mcp.package(bundle, "release", root)
                self.assertEqual(calls.call_args_list[0].args[0],
                                 [str((bundle / "Contents/MacOS/lab-mcp").resolve()), "--catalog"])
            resources = bundle / "Contents/Resources"
            self.assertEqual(json.loads((resources / "MCP-CATALOG.json").read_bytes()), catalog)
            manifest = json.loads((resources / "LABBuild.json").read_text())
            self.assertEqual(manifest["source_revision"], "0123456789abcdef")
            self.assertTrue(manifest["source_dirty"])
            self.assertEqual(manifest["app_pre_package_signing_sha256"],
                             hashlib.sha256((bundle / "Contents/MacOS/LAB").read_bytes()).hexdigest())
            self.assertEqual(manifest["schema_fingerprint"], catalog["schema_fingerprint"])
            expected = manifest.pop("build_id")
            encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
            self.assertEqual(expected, "sha256:" + hashlib.sha256(encoded).hexdigest())

    def test_missing_git_metadata_is_explicit(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, catalog = self.fixture(root)
            with patch.object(package_mcp.subprocess, "check_output",
                              side_effect=[json.dumps(catalog).encode(), OSError("no git")]):
                package_mcp.package(bundle, "debug", root)
            manifest = json.loads((bundle / "Contents/Resources/LABBuild.json").read_text())
            self.assertIsNone(manifest["source_revision"])
            self.assertIsNone(manifest["source_dirty"])

    def test_pretty_catalog_over_limit_preserves_complete_compact_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, catalog = self.fixture(root)
            properties = {f"control_{i}": {"type": "number", "minimum": 0,
                                         "maximum": 1, "default": 0} for i in range(6000)}
            catalog["tools"].append({"name": "form_construction", "description": "Physical dimensions · mm",
                                     "inputSchema": {"type": "object", "additionalProperties": False,
                                                     "properties": properties, "required": ["control_0"]}})
            pretty = json.dumps(catalog, indent=4).encode()
            self.assertGreater(len(pretty), 1024 * 1024)
            replies = [pretty, "0123456789abcdef\n", ""]
            with patch.object(package_mcp.subprocess, "check_output", side_effect=replies):
                package_mcp.package(bundle, "release", root)
            data = (bundle / "Contents/Resources/MCP-CATALOG.json").read_bytes()
            self.assertLessEqual(len(data), 1024 * 1024)
            self.assertEqual(json.loads(data), catalog)
            manifest = json.loads((bundle / "Contents/Resources/LABBuild.json").read_text())
            self.assertEqual(manifest["schema_fingerprint"], catalog["schema_fingerprint"])

    def test_genuinely_oversized_compact_catalog_rejects_before_publication(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bundle, catalog = self.fixture(root)
            catalog["tools"][0]["description"] = "x" * (1024 * 1024)
            raw = json.dumps(catalog, separators=(",", ":")).encode()
            self.assertGreater(len(raw), 1024 * 1024)
            with patch.object(package_mcp.subprocess, "check_output", return_value=raw):
                with self.assertRaisesRegex(RuntimeError, "exceeds 1 MiB"):
                    package_mcp.package(bundle, "release", root)
            self.assertFalse((bundle / "Contents/Resources/MCP-CATALOG.json").exists())
            self.assertFalse((bundle / "Contents/Resources/LABBuild.json").exists())

    def test_oversized_or_missing_catalog_contract_rejects_before_publication(self):
        for data in [b" " * (1024 * 1024 + 1), b'{"tools": []}']:
            with self.subTest(bytes=len(data)), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                bundle, _ = self.fixture(root)
                with patch.object(package_mcp.subprocess, "check_output", return_value=data):
                    with self.assertRaises(RuntimeError):
                        package_mcp.package(bundle, "release", root)
                self.assertFalse((bundle / "Contents/Resources/LABBuild.json").exists())


if __name__ == "__main__":
    unittest.main()
