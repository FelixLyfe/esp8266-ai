#!/usr/bin/env python3
"""Validate every release-facing version field against VERSION."""

from __future__ import annotations

import argparse
import plistlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SEMVER = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")


def fail(message: str) -> None:
    print(f"release version check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def firmware_version() -> str:
    text = (ROOT / "firmware/include/config.h").read_text(encoding="utf-8")
    match = re.search(r'^#define\s+FW_VERSION\s+"([^"]+)"', text, re.MULTILINE)
    if match is None:
        fail("FW_VERSION is missing from firmware/include/config.h")
    return match.group(1)


def windows_versions() -> dict[str, str]:
    root = ET.parse(ROOT / "windows-app/AIClockBridge/AIClockBridge.csproj").getroot()
    fields = ("Version", "AssemblyVersion", "FileVersion")
    values = {field: root.findtext(f".//{field}") or "" for field in fields}
    missing = [field for field, value in values.items() if not value]
    if missing:
        fail(f"missing Windows version fields: {', '.join(missing)}")
    return values


def macos_version() -> str:
    with (ROOT / "mac-app/Packaging/Info.plist").open("rb") as plist_file:
        value = plistlib.load(plist_file).get("CFBundleShortVersionString")
    if not isinstance(value, str) or not value:
        fail("CFBundleShortVersionString is missing from mac-app/Packaging/Info.plist")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", help="release tag to compare, for example v0.5.0")
    args = parser.parse_args()

    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    if SEMVER.fullmatch(version) is None:
        fail(f"VERSION must be X.Y.Z, got {version!r}")

    expected_windows_file_version = f"{version}.0"
    actual = {
        "firmware FW_VERSION": firmware_version(),
        "macOS CFBundleShortVersionString": macos_version(),
        **{f"Windows {name}": value for name, value in windows_versions().items()},
    }
    expected = {
        "firmware FW_VERSION": version,
        "macOS CFBundleShortVersionString": version,
        "Windows Version": version,
        "Windows AssemblyVersion": expected_windows_file_version,
        "Windows FileVersion": expected_windows_file_version,
    }
    mismatches = [
        f"{name}: expected {expected[name]!r}, got {value!r}"
        for name, value in actual.items()
        if value != expected[name]
    ]
    if mismatches:
        fail("; ".join(mismatches))

    if args.tag is not None and args.tag != f"v{version}":
        fail(f"tag must be v{version}, got {args.tag!r}")

    print(version)


if __name__ == "__main__":
    main()
