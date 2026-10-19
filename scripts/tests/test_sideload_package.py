"""Validate install-relevant IPA structure using a minimal Mach-O fixture."""

import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import struct
import tempfile
import unittest
import zipfile


SOURCE = Path(__file__).resolve().parents[1] / "package_sideload_ipa.py"
SPEC = importlib.util.spec_from_file_location("package_sideload_ipa", SOURCE)
PACKAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGE)


class SideloadPackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.app = self.root / "Zotero.app"
        self.app.mkdir()
        self.output = self.root / "output/Translate.ipa"
        self.info = {
            "CFBundleIdentifier": "org.zotero.ios.Zotero",
            "CFBundleExecutable": "Zotero",
            "MinimumOSVersion": "16.6",
        }
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.write_executable()

    def write_executable(self, platform=2, minimum=0x100600, cpu=0x0100000C):
        header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 1, 24, 0, 0)
        command = struct.pack("<6I", 0x32, 24, platform, minimum, 0x1A0500, 0)
        executable = self.app / "Zotero"
        executable.write_bytes(header + command)
        executable.chmod(0o755)

    def package(self, bundle_id="org.example.ZoteroTranslate"):
        return PACKAGE.package_app(self.app, self.output, bundle_id, "18.7.8", "source-sha")

    def test_device_package_is_independent_unsigned_and_keeps_executable_mode(self):
        for name in ("PlugIns/ZShare.appex/Info.plist", "_CodeSignature/CodeResources", "embedded.mobileprovision"):
            path = self.app / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"excluded")
        framework = self.app / "Frameworks/Example.framework"
        framework.mkdir(parents=True)
        (framework / "Example").write_bytes(b"framework")
        manifest = self.package()
        with zipfile.ZipFile(self.output) as archive:
            names = archive.namelist()
            self.assertFalse(any("PlugIns" in name or "_CodeSignature" in name or "mobileprovision" in name for name in names))
            self.assertIn("Payload/Zotero.app/Frameworks/Example.framework/Example", names)
            info = plistlib.loads(archive.read("Payload/Zotero.app/Info.plist"))
            self.assertEqual(info["CFBundleIdentifier"], "org.example.ZoteroTranslate")
            self.assertEqual(info["CFBundleDisplayName"], "Zotero Translate")
            mode = archive.getinfo("Payload/Zotero.app/Zotero").external_attr >> 16
            self.assertTrue(mode & stat.S_IXUSR)
        self.assertEqual(plistlib.loads((self.app / "Info.plist").read_bytes()), self.info)
        self.assertEqual(manifest, json.loads(self.output.with_suffix(".json").read_text()))

    def test_rejects_arm64_simulator_binary(self):
        self.write_executable(platform=7)
        with self.assertRaisesRegex(ValueError, "physical iOS"):
            self.package()

    def test_rejects_binary_requiring_newer_ios(self):
        self.write_executable(minimum=0x130000)
        with self.assertRaisesRegex(ValueError, "newer"):
            self.package()

    def test_rejects_newer_plist_minimum_even_when_binary_is_compatible(self):
        self.info["MinimumOSVersion"] = "19.0"
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        with self.assertRaisesRegex(ValueError, "newer"):
            self.package()

    def test_rejects_official_bundle_identifier(self):
        with self.assertRaisesRegex(ValueError, "independent"):
            self.package("org.zotero.ios.Zotero")

    def test_rejects_intel_executable(self):
        self.write_executable(cpu=0x01000007)
        with self.assertRaisesRegex(ValueError, "arm64"):
            self.package()

    def test_preserves_internal_framework_symlink(self):
        (self.app / "Resource").write_bytes(b"resource")
        (self.app / "ResourceLink").symlink_to("Resource")
        self.package()
        with zipfile.ZipFile(self.output) as archive:
            info = archive.getinfo("Payload/Zotero.app/ResourceLink")
            self.assertTrue(stat.S_ISLNK(info.external_attr >> 16))
            self.assertEqual(archive.read(info), b"Resource")


if __name__ == "__main__":
    unittest.main()
