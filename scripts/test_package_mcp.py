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
