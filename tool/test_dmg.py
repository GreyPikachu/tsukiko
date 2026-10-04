"""Сборка DMG при уже смонтированном установщике с тем же именем."""

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


class InstallerTest(unittest.TestCase):
    def test_layout_and_existing_volume(self):
        with tempfile.TemporaryDirectory(prefix="tsukiko-dmg-test-") as directory:
            work = Path(directory)
            app = work / "tsukiko.app"
            binaries = app / "Contents" / "MacOS"
            binaries.mkdir(parents=True)
            (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "org.tsukiko.installer-test",
                "CFBundleExecutable": "tsukiko",
                "CFBundlePackageType": "APPL",
                "CFBundleName": "tsukiko",
            }))
            source = work / "main.c"
            source.write_text("int main(void) { return 0; }\n")
            subprocess.run(["cc", str(source), "-o", str(binaries / "tsukiko")], check=True)
            subprocess.run(["codesign", "--sign", "-", str(app)], check=True)

            existing = work / "existing"
            existing.mkdir()
            (existing / "sentinel").write_text("Этот том нельзя отсоединять при сборке.\n")
            blocker = work / "existing.dmg"
            subprocess.run([
                "hdiutil", "create", "-srcfolder", str(existing), "-volname", "tsukiko",
                "-fs", "HFS+", "-format", "UDRO", str(blocker)], check=True)
            entities = plistlib.loads(subprocess.check_output([
                "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(blocker)
            ]))["system-entities"]
            device = entities[0]["dev-entry"]
            try:
                mount = Path(next(e["mount-point"] for e in entities if "mount-point" in e))
                image = work / "installer.dmg"
                subprocess.run([str(ROOT / "tool" / "dmg.sh")], cwd=ROOT,
                               env={**os.environ, "APP": str(app), "OUT": str(image)}, check=True)
                self.assertTrue((mount / "sentinel").is_file(), "Сборка отсоединила существующий том")
                subprocess.run([
                    str(ROOT / "build" / "dmg-tools-venv" / "bin" / "python3"),
                    str(ROOT / "tool" / "verify-dmg.py"), str(image)], check=True)
                self.assertTrue((mount / "sentinel").is_file(), "Проверка отсоединила существующий том")
            finally:
                subprocess.run(["hdiutil", "detach", device], check=True)


if __name__ == "__main__":
    unittest.main()
