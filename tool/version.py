#!/usr/bin/env python3
"""Validate the app version and reserve each successful CI build version."""

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
VERSION_RE = re.compile(r"^version:\s*(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\+([1-9]\d*)\s*$", re.MULTILINE)


def fail(message: str) -> None:
    raise ValueError(message)


def version() -> tuple[tuple[int, int, int], int]:
    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    matches = VERSION_RE.findall(pubspec)
    if len(matches) != 1:
        fail("pubspec.yaml: expected exactly one version: MAJOR.MINOR.PATCH+BUILD")
    major, minor, patch, build = map(int, matches[0])
    name = f"{major}.{minor}.{patch}"
    dart = (ROOT / "lib/platform/os.dart").read_text(encoding="utf-8")
    if not re.search(rf"^const appVersion = '{re.escape(name)}';$", dart, re.MULTILINE):
        fail(f"lib/platform/os.dart: appVersion must be {name}")
    resource = (ROOT / "windows/runner/Runner.rc").read_text(encoding="utf-8")
    if f'#define VERSION_AS_STRING "{name}"' not in resource:
        fail(f"windows/runner/Runner.rc: fallback string version must be {name}")
    if f"#define VERSION_AS_NUMBER {major},{minor},{patch},{build}" not in resource:
        fail(f"windows/runner/Runner.rc: fallback numeric version must be {major},{minor},{patch},{build}")
    return (major, minor, patch), build


def built_versions(platform: str) -> list[tuple[tuple[int, int, int], int]]:
    prefix = f"refs/tags/build/{platform}/v"
    result = subprocess.run(
        ["git", "ls-remote", "--tags", "origin", f"{prefix}*"],
        cwd=ROOT, text=True, capture_output=True, check=True,
    )
    found = []
    for line in result.stdout.splitlines():
        ref = line.split("\t", 1)[1]
        match = re.fullmatch(rf"{re.escape(prefix)}(\d+)\.(\d+)\.(\d+)\+(\d+)", ref)
        if match:
            major, minor, patch, build = map(int, match.groups())
            found.append(((major, minor, patch), build))
    return found


def ensure_build_allowed(
    name: tuple[int, int, int],
    build: int,
    prior: list[tuple[tuple[int, int, int], int]],
    platform: str,
) -> None:
    if not prior:
        return
    newest_name = max(item[0] for item in prior)
    newest_build = max(item[1] for item in prior)
    if name <= newest_name:
        fail(f"{'.'.join(map(str, name))} was already built or is older on {platform}; bump MAJOR.MINOR.PATCH")
    if build <= newest_build:
        fail(f"build number {build} must exceed {newest_build}; bump +BUILD")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "build", "current", "tag"])
    parser.add_argument("--platform", choices=["windows", "macos"])
    args = parser.parse_args()
    name, build = version()
    text_version = ".".join(map(str, name))
    if args.command == "current":
        print(text_version)
    elif args.command in ("build", "tag"):
        if not args.platform:
            parser.error("--platform is required for build and tag")
        if args.command == "build":
            ensure_build_allowed(name, build, built_versions(args.platform), args.platform)
            print(f"Version {text_version}+{build} may be built for {args.platform}")
        else:
            print(f"build/{args.platform}/v{text_version}+{build}")
    else:
        print(f"Version fields agree: {text_version}+{build}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.CalledProcessError) as error:
        print(f"Version check failed: {error}", file=sys.stderr)
        sys.exit(1)
