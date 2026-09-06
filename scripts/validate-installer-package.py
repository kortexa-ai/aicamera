#!/usr/bin/env python3
"""Expand and inspect a package; never run its installation scripts."""
import argparse
import importlib.util
import plistlib
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def inspect_package(package, version, build):
    signature = subprocess.run(["pkgutil", "--check-signature", str(package)],
                               check=True, capture_output=True, text=True).stdout
    assert "Developer ID Installer:" in signature, "Wrong package certificate class"
    with tempfile.TemporaryDirectory(prefix="aicamera-package-check-") as temporary:
        expanded = Path(temporary) / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        apps = list(expanded.rglob("AI Camera.app"))
        assert len(apps) == 1, "Expected exactly one application in the script payload"
        app = apps[0]
        scripts = app.parent
        assert (scripts / "postinstall").read_bytes() == (ROOT / "Resources/Installer/postinstall").read_bytes(), "Unexpected installation script"
        assert (scripts / "installer-transaction.applescript").read_bytes() == (ROOT / "scripts/installer-transaction.applescript").read_bytes(), "Unexpected transaction"
        assert not (scripts / "preinstall").exists(), "Unexpected preinstall"
        package_infos = list(expanded.rglob("PackageInfo"))
        assert len(package_infos) == 1, "Unexpected component count"
        component = ET.parse(package_infos[0]).getroot()
        assert component.get("identifier") == "ai.kortexa.aicamera.installer"
        assert component.get("version") == version
        payload = component.find("payload")
        assert payload is None or int(payload.get("numberOfFiles", "0")) == 0, "Package must use the protected transaction only"
        distribution = ET.parse(expanded / "Distribution").getroot()
        domains = distribution.find("domains")
        assert domains.get("enable_anywhere") == "false" and domains.get("enable_currentUserHome") == "false"
        assert distribution.find("allowed-os-versions/os-version").get("min") == "14.0"
        assert component.get("postinstall-action", "none").lower() == "none", "Package must not request a restart"
        spec = importlib.util.spec_from_file_location("verify_release", ROOT / "scripts/verify-release.py")
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        result = verifier.verify(app, version, build)
        # Package and application must belong to the same Developer ID team.
        app_signature = subprocess.run(["codesign", "-d", "--verbose=4", str(app)],
                                       capture_output=True, text=True, check=True).stderr
        team = next(line.split("=", 1)[1] for line in app_signature.splitlines() if line.startswith("TeamIdentifier="))
        assert f"({team})" in signature, "Installer and app team mismatch"
        print(f"Package inspection passed: {result['version']} ({result['build']}), no installation performed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    inspect_package(args.package.resolve(), args.version, args.build)
