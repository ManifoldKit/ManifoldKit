#!/usr/bin/env python3
"""Check active install docs against published companion manifests.

A core release is tagged before its companion pin-bump releases. An unpublished
version.txt is reported as a deferred check; the nightly --resolve run verifies
the published graph after the companion tags exist.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAMILIES = ("llama", "mlx")
PIN = re.compile(r'from:\s*"(\d+\.\d+\.\d+)"')
URL = re.compile(r'https://github\.com/ManifoldKit/manifold-(llama|mlx)\.git')
CORE_REQUIREMENT = re.compile(r'\.upToNextMinor\(from:\s*"(\d+\.\d+\.\d+)"\)')


class PinError(Exception):
    pass


class UnpublishedCore(PinError):
    pass


def version(value: str) -> tuple[int, int, int]:
    parts = value.split(".")
    if len(parts) != 3 or any(not part.isdecimal() for part in parts):
        raise PinError(f"invalid version: {value!r}")
    return tuple(map(int, parts))  # type: ignore[return-value]


def collect_pins(root: Path) -> dict[str, list[tuple[str, int, str]]]:
    pins: dict[str, list[tuple[str, int, str]]] = {family: [] for family in FAMILIES}
    files = [root / "README.md", *sorted((root / "docs").glob("QUICKSTART*.md"))]
    for path in files:
        if not path.is_file():
            raise PinError(f"missing install document: {path}")
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            found = URL.search(line)
            if not found:
                continue
            family = found.group(1)
            pin_found = False
            for offset in range(4):
                if index + offset >= len(lines):
                    break
                candidate = lines[index + offset]
                if offset and ".package(" in candidate:
                    break
                match = PIN.search(candidate)
                if match:
                    pins[family].append((str(path.relative_to(root)), index + 1, match.group(1)))
                    pin_found = True
                    break
            if not pin_found:
                raise PinError(f"{path.relative_to(root)}:{index + 1}: companion URL has no version pin")
    for family in FAMILIES:
        if not pins[family]:
            raise PinError(f"no active manifold-{family} install pin found")
        values = {pin for _, _, pin in pins[family]}
        if len(values) != 1:
            locations = ", ".join(f"{path}:{line}={pin}" for path, line, pin in pins[family])
            raise PinError(f"manifold-{family} install pins disagree: {locations}")
    return pins


def raw_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "ManifoldKit-doc-pin-check"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and "/ManifoldKit/v" in url:
            raise UnpublishedCore(f"core tag v{url.split('/v', 1)[1].split('/', 1)[0]} is not published yet") from exc
        raise PinError(f"cannot fetch {url}: HTTP {exc.code}") from exc
    except (urllib.error.URLError, TimeoutError, UnicodeError) as exc:
        raise PinError(f"cannot fetch {url}: {exc}") from exc


def check_requirements(core: str, pins: dict[str, str], fetch=raw_text) -> None:
    core_url = f"https://raw.githubusercontent.com/ManifoldKit/ManifoldKit/v{core}/version.txt"
    tagged_version = fetch(core_url).strip()
    if tagged_version != core:
        raise PinError(f"{core_url} says {tagged_version!r}, expected {core!r}")
    for family, pin in pins.items():
        url = f"https://raw.githubusercontent.com/ManifoldKit/manifold-{family}/v{pin}/Package.swift"
        manifest = fetch(url)
        match = CORE_REQUIREMENT.search(manifest)
        if match is None:
            raise PinError(f"manifold-{family} v{pin} has no readable core upToNextMinor requirement")
        minimum = match.group(1)
        actual = version(core)
        floor = version(minimum)
        if actual[:2] != floor[:2] or actual < floor:
            raise PinError(
                f"manifold-{family} v{pin} requires core {minimum}..<"
                f"{floor[0]}.{floor[1] + 1}.0; docs advertise core {core}"
            )


def resolve_graph(core: str, pins: dict[str, str]) -> None:
    with tempfile.TemporaryDirectory(prefix="mk-companion-doc-pins-") as directory:
        package = Path(directory) / "Package.swift"
        package.write_text(
            "// swift-tools-version: 6.1\n"
            "import PackageDescription\n"
            "let package = Package(name: \"CompanionDocPinCheck\", dependencies: [\n"
            f"  .package(url: \"https://github.com/ManifoldKit/ManifoldKit.git\", exact: \"{core}\"),\n"
            f"  .package(url: \"https://github.com/ManifoldKit/manifold-llama.git\", exact: \"{pins['llama']}\"),\n"
            f"  .package(url: \"https://github.com/ManifoldKit/manifold-mlx.git\", exact: \"{pins['mlx']}\"),\n"
            "], targets: [.target(name: \"PinCheck\", dependencies: [\n"
            "  .product(name: \"ManifoldInference\", package: \"ManifoldKit\"),\n"
            "  .product(name: \"ManifoldLlama\", package: \"manifold-llama\"),\n"
            "  .product(name: \"ManifoldMLX\", package: \"manifold-mlx\"),\n"
            "])])\n",
            encoding="utf-8",
        )
        (Path(directory) / "Sources" / "PinCheck").mkdir(parents=True)
        (Path(directory) / "Sources" / "PinCheck" / "PinCheck.swift").write_text("public struct PinCheck {}\n")
        completed = subprocess.run(["swift", "package", "resolve", "--package-path", directory], check=False)
        if completed.returncode:
            raise PinError(f"swift package resolve failed with exit {completed.returncode} for documented pins")


class GuardSabotageTests(unittest.TestCase):
    def test_sabotage_stale_companion_pin_is_rejected(self) -> None:
        def fetch(url: str) -> str:
            if url.endswith("/version.txt"):
                return "0.79.0\n"
            if "manifold-llama" in url:
                return '.package(url: "core", .upToNextMinor(from: "0.75.0"))'
            return '.package(url: "core", .upToNextMinor(from: "0.79.0"))'

        with self.assertRaisesRegex(PinError, "requires core 0.75.0"):
            check_requirements("0.79.0", {"llama": "0.2.14", "mlx": "0.6.3"}, fetch)

    def test_missing_manifest_is_reported(self) -> None:
        def fetch(url: str) -> str:
            if url.endswith("/version.txt"):
                return "0.79.0\n"
            raise PinError("HTTP 404")

        with self.assertRaisesRegex(PinError, "HTTP 404"):
            check_requirements("0.79.0", {"llama": "0.4.9", "mlx": "0.6.3"}, fetch)

    def test_unpublished_core_is_reported(self) -> None:
        def fetch(_url: str) -> str:
            raise UnpublishedCore("core tag is not published yet")

        with self.assertRaisesRegex(UnpublishedCore, "not published yet"):
            check_requirements("0.80.0", {"llama": "0.4.9", "mlx": "0.6.3"}, fetch)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolve", action="store_true", help="also resolve the published SwiftPM graph")
    parser.add_argument("--self-test", action="store_true", help="run the guard's sabotage tests")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(GuardSabotageTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    try:
        core = (ROOT / "version.txt").read_text(encoding="utf-8").strip()
        version(core)
        found = collect_pins(ROOT)
        pins = {family: found[family][0][2] for family in FAMILIES}
        try:
            check_requirements(core, pins)
        except UnpublishedCore as exc:
            print(f"DEFERRED: {exc}; companion compatibility will run after core publication")
            return 0
        print(f"PASS: core {core}, llama {pins['llama']}, mlx {pins['mlx']} are tag-compatible")
        if args.resolve:
            resolve_graph(core, pins)
            print("PASS: published core and companion pins resolve in one SwiftPM consumer")
        return 0
    except (PinError, OSError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
