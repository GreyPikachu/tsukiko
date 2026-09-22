import unittest
from unittest.mock import patch
from subprocess import CompletedProcess

from version import built_versions, ensure_build_allowed


class BuildVersionTest(unittest.TestCase):
    def test_first_build_and_new_version(self):
        ensure_build_allowed((0, 8, 3), 2, [], "windows")
        ensure_build_allowed((0, 8, 4), 3, [((0, 8, 3), 2)], "windows")

    def test_rejects_reused_or_older_version(self):
        prior = [((0, 8, 3), 2)]
        for name in ((0, 8, 3), (0, 8, 2)):
            with self.subTest(name=name), self.assertRaises(ValueError):
                ensure_build_allowed(name, 3, prior, "windows")

    def test_rejects_reused_build_number(self):
        with self.assertRaises(ValueError):
            ensure_build_allowed((0, 8, 4), 2, [((0, 8, 3), 2)], "macos")

    def test_reads_only_matching_platform_build_tags(self):
        output = (
            "abc\trefs/tags/build/windows/v0.8.3+2\n"
            "def\trefs/tags/build/macos/v0.8.3+2\n"
            "ghi\trefs/tags/build/windows/v0.8.3+2^{}\n"
        )
        with patch("version.subprocess.run", return_value=CompletedProcess([], 0, output, "")):
            self.assertEqual(built_versions("windows"), [((0, 8, 3), 2)])


if __name__ == "__main__":
    unittest.main()
