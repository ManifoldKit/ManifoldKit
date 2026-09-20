#!/usr/bin/env python3
"""Check active install docs against published companion manifests.

A core release is tagged before its companion pin-bump releases. The lint
check may explicitly defer an unpublished core tag; the nightly --resolve run
fails closed and verifies the published graph after companion tags exist.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAMILIES = ("llama", "mlx")
PIN = re.compile(r'from:\s*"(\d+\.\d+\.\d+)"')
URL = re.compile(r'https://github\.com/ManifoldKit/manifold-(llama|mlx)\.git')
CORE_REQUIREMENT = re.compile(r'\.upToNextMinor\(from:\s*"(\d+\.\d+\.\d+)"\)')
CORE_URL = re.compile(r'https://github\.com/ManifoldKit/ManifoldKit(?:\.git)?(?=")')


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


def core_requirement(manifest: str) -> str:
    """Read the requirement from the ManifoldKit package entry only."""
    for entry in re.finditer(r"\.package\s*\(", manifest):
        depth = 1
        quoted = False
        escaped = False
        end = entry.end()
        for end in range(entry.end(), len(manifest)):
            character = manifest[end]
            if escaped:
                escaped = False
            elif character == "\\" and quoted:
                escaped = True
            elif character == '"':
                quoted = not quoted
            elif not quoted:
                if character == "(":
                    depth += 1
                elif character == ")":
                    depth -= 1
                    if depth == 0:
                        break
        if depth:
            raise PinError("unbalanced .package entry in companion manifest")
        block = manifest[entry.start():end + 1]
        if not CORE_URL.search(block):
            continue
        match = CORE_REQUIREMENT.search(block)
        if match is None:
            raise PinError("ManifoldKit dependency has no upToNextMinor requirement")
        return match.group(1)
    raise PinError("companion manifest has no ManifoldKit package dependency")


def check_requirements(core: str, pins: dict[str, str], fetch=raw_text) -> None:
    core_url = f"https://raw.githubusercontent.com/ManifoldKit/ManifoldKit/v{core}/version.txt"
    tagged_version = fetch(core_url).strip()
    if tagged_version != core:
        raise PinError(f"{core_url} says {tagged_version!r}, expected {core!r}")
    for family, pin in pins.items():
        url = f"https://raw.githubusercontent.com/ManifoldKit/manifold-{family}/v{pin}/Package.swift"
        manifest = fetch(url)
        try:
            minimum = core_requirement(manifest)
        except PinError as exc:
            raise PinError(f"manifold-{family} v{pin}: {exc}") from exc
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
        completed = subprocess.run(
            ["swift", "package", "resolve", "--package-path", directory], check=False, timeout=540
        )
        if completed.returncode:
            raise PinError(f"swift package resolve failed with exit {completed.returncode} for documented pins")


class GuardSabotageTests(unittest.TestCase):
    def test_sabotage_stale_companion_pin_is_rejected(self) -> None:
        def fetch(url: str) -> str:
            if url.endswith("/version.txt"):
                return "0.79.0\n"
            if "manifold-llama" in url:
                return '.package(url: "https://github.com/ManifoldKit/ManifoldKit", .upToNextMinor(from: "0.75.0"))'
            return '.package(url: "https://github.com/ManifoldKit/ManifoldKit", .upToNextMinor(from: "0.79.0"))'

        with self.assertRaisesRegex(PinError, "requires core 0.75.0"):
            check_requirements("0.79.0", {"llama": "0.2.14", "mlx": "0.6.3"}, fetch)

    def test_sabotage_unrelated_requirement_cannot_hide_stale_core(self) -> None:
        manifest = (
            '.package(url: "https://example.com/other", .upToNextMinor(from: "0.79.0")),\n'
            '.package(url: "https://github.com/ManifoldKit/ManifoldKit", '
            '.upToNextMinor(from: "0.75.0"))'
        )
        self.assertEqual(core_requirement(manifest), "0.75.0")
        with self.assertRaisesRegex(PinError, "requires core 0.75.0"):
            check_requirements("0.79.0", {"llama": "0.4.9"},
                               lambda url: "0.79.0" if url.endswith("version.txt") else manifest)

    def test_missing_core_dependency_is_reported(self) -> None:
        with self.assertRaisesRegex(PinError, "no ManifoldKit package dependency"):
            core_requirement('.package(url: "https://example.com/other", .upToNextMinor(from: "0.79.0"))')

    def test_missing_manifest_is_reported(self) -> None:
        def fetch(url: str) -> str:
            if url.endswith("/version.txt"):
                return "0.79.0\n"
            raise PinError("HTTP 404")

        with self.assertRaisesRegex(PinError, "HTTP 404"):
            check_requirements("0.79.0", {"llama": "0.4.9", "mlx": "0.6.3"}, fetch)

    def test_sabotage_nightly_resolve_fails_on_unpublished_core(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "version.txt").write_text("0.80.0\n", encoding="utf-8")
            pins = {family: [("README.md", 1, "0.4.9")] for family in FAMILIES}
            with mock.patch.object(sys.modules[__name__], "ROOT", root), \
                 mock.patch.object(sys.modules[__name__], "collect_pins", return_value=pins), \
                 mock.patch.object(sys.modules[__name__], "check_requirements",
                                   side_effect=UnpublishedCore("core tag is not published yet")), \
                 mock.patch.object(sys.modules[__name__], "resolve_graph") as resolve:
                self.assertEqual(main(["--resolve"]), 1)
                self.assertEqual(main(["--allow-unpublished-core"]), 0)
                self.assertEqual(main(["--resolve", "--allow-unpublished-core"]), 1)
                resolve.assert_not_called()

    def test_unpublished_core_is_reported(self) -> None:
        def fetch(_url: str) -> str:
            raise UnpublishedCore("core tag is not published yet")

        with self.assertRaisesRegex(UnpublishedCore, "not published yet"):
            check_requirements("0.80.0", {"llama": "0.4.9", "mlx": "0.6.3"}, fetch)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolve", action="store_true", help="also resolve the published SwiftPM graph")
    parser.add_argument("--self-test", action="store_true", help="run the guard's sabotage tests")
    parser.add_argument("--allow-unpublished-core", action="store_true",
                        help="defer only the pre-publication release PR check")
    args = parser.parse_args(argv)
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
            if not args.allow_unpublished_core or args.resolve:
                raise
            print(f"DEFERRED: {exc}; companion compatibility will run after core publication")
            return 0
        print(f"PASS: core {core}, llama {pins['llama']}, mlx {pins['mlx']} are tag-compatible")
        if args.resolve:
            resolve_graph(core, pins)
            print("PASS: published core and companion pins resolve in one SwiftPM consumer")
        return 0
    except subprocess.TimeoutExpired as exc:
        print(f"::error::SwiftPM resolution timed out: {exc}", file=sys.stderr)
        return 1
    except (PinError, OSError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
