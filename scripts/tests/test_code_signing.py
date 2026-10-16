"""Exercise the actual Xcode signing scripts without an Apple signing identity."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2] / "Zotero.xcodeproj/project.pbxproj"


class CodeSigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        scripts = re.findall(r'shellScript = ("(?:[^"\\]|\\.)*");', PROJECT.read_text())
        cls.scripts = [json.loads(script) for script in scripts if "codesign --force" in script]
        if len(cls.scripts) != 2:
            raise AssertionError("Expected both app and share extension signing phases")

    def run_scripts(self, identity, allowed, expected_calls, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            product = root / "Zotero App.app"
            framework = product / "Frameworks/Example Framework.framework"
            framework.mkdir(parents=True)
            log = root / "signing.log"
            codesign = root / "codesign"
            codesign.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" >> "$SIGNING_TEST_LOG"\n'
                'exit "$SIGNING_TEST_EXIT"\n'
            )
            codesign.chmod(0o755)
            for script in self.scripts:
                with self.subTest(script=script[:80], identity=identity, allowed=allowed):
                    log.unlink(missing_ok=True)
                    environment = dict(os.environ)
                    environment.update({
                        "PATH": str(root) + os.pathsep + environment["PATH"],
                        "CODESIGNING_FOLDER_PATH": str(product),
                        "SIGNING_TEST_LOG": str(log),
                        "SIGNING_TEST_EXIT": str(exit_code),
                    })
                    environment.pop("EXPANDED_CODE_SIGN_IDENTITY", None)
                    environment.pop("CODE_SIGNING_ALLOWED", None)
                    if identity is not None:
                        environment["EXPANDED_CODE_SIGN_IDENTITY"] = identity
                    if allowed is not None:
                        environment["CODE_SIGNING_ALLOWED"] = allowed
                    # macOS /bin/sh supports the bash read -d used by the project.
                    result = subprocess.run(
                        ["/bin/bash"], input=script, text=True,
                        env=environment, capture_output=True,
                    )
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    self.assertEqual(log.exists(), expected_calls, result.stderr)
                    if expected_calls:
                        arguments = log.read_text().splitlines()
                        self.assertEqual(arguments[arguments.index("--sign") + 1], identity)
                        self.assertEqual(arguments[-1], str(framework))
                    else:
                        self.assertIn("Skipping framework re-sign", result.stdout)

    def test_simulator_build_without_identity(self):
        self.run_scripts("", "NO", expected_calls=False)

    def test_missing_signing_variables(self):
        self.run_scripts(None, None, expected_calls=False)

    def test_signing_disabled_with_identity(self):
        self.run_scripts("Test Identity", "NO", expected_calls=False)

    def test_signed_build_preserves_identity_and_framework_path(self):
        self.run_scripts("Test Identity", "YES", expected_calls=True)

    def test_codesign_failure_fails_the_phase(self):
        self.run_scripts("Test Identity", "YES", expected_calls=True, exit_code=37)


if __name__ == "__main__":
    unittest.main()
