#!/usr/bin/env python3
"""Verify the exported app without installing or activating system components."""
import argparse
import json
import plistlib
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True)


def info(bundle):
    return plistlib.loads((bundle / "Contents/Info.plist").read_bytes())


def verify(app, version, build):
    expected = {
        app: "ai.kortexa.aicamera",
        app / "Contents/Library/SystemExtensions/ai.kortexa.aicamera.camera-extension.systemextension":
            "ai.kortexa.aicamera.camera-extension",
        app / "Contents/Resources/AICameraAudioDriver.driver": "ai.kortexa.aicamera.audio.driver",
    }
    run("codesign", "--verify", "--deep", "--strict", str(app))
    assert info(app)["CFBundleShortVersionString"] == version, "Wrong app version"
    assert info(app)["CFBundleVersion"] == build, "Wrong host build"
    team = None
    components = []
    for bundle, identifier in expected.items():
        metadata = info(bundle)
        assert metadata["CFBundleIdentifier"] == identifier, "Wrong component identifier"
        assert metadata["CFBundleVersion"].isdigit(), "Invalid component build"
        signature = run("codesign", "-d", "--verbose=4", str(bundle)).stderr
        fields = dict(line.split("=", 1) for line in signature.splitlines() if "=" in line)
        assert "Authority=Developer ID Application:" in signature, "Not Developer ID Application signed"
        assert "Timestamp=" in signature, "Missing secure timestamp"
        team = team or fields["TeamIdentifier"]
        assert fields["TeamIdentifier"] == team, "Signing team mismatch"
        requirement = f'identifier "{identifier}" and anchor apple generic and certificate leaf[subject.OU] = "{team}"'
        run("codesign", "--verify", "--strict", "-R", "=" + requirement, str(bundle))
        if bundle == app or bundle.suffix == ".systemextension":
            assert "runtime" in fields.get("CodeDirectory v", signature), "Missing hardened runtime"
        raw = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(bundle)],
                             capture_output=True, check=True).stdout
        entitlements = plistlib.loads(raw) if raw.strip() else {}
        assert not entitlements.get("com.apple.security.get-task-allow"), "Debug entitlement"
        executable = bundle / "Contents/MacOS" / metadata["CFBundleExecutable"]
        assert set(run("lipo", "-archs", str(executable)).stdout.split()) == {"arm64", "x86_64"}, "Not universal"
        components.append({"identifier": identifier, "version": metadata.get("CFBundleShortVersionString"),
                           "build": metadata["CFBundleVersion"], "cdhash": fields["CDHash"]})
    # Developer ID export must sign every embedded Mach-O, including binary-package runtimes.
    for path in sorted((app / "Contents/Frameworks").rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        if "Mach-O" in run("file", "-b", str(path)).stdout:
            run("codesign", "--verify", "--strict", str(path))
            signature = run("codesign", "-d", "--verbose=4", str(path)).stderr
            assert "Authority=Developer ID Application:" in signature, "Unsigned distribution dependency"
            assert f"TeamIdentifier={team}" in signature, "Dependency team mismatch"
            assert "Timestamp=" in signature, "Dependency timestamp missing"
    resources = app / "Contents/Resources"
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "LLAMA_CPP_LICENSE.txt",
                 "WHISPER_CPP_LICENSE.txt", "HY_MT2_LICENSE.txt", "RF_DETR_LICENSE.txt", "YOLO_LICENSE.txt"):
        assert any(resources.rglob(name)), f"Missing notice: {name}"
    return {"version": version, "build": build, "architectures": ["arm64", "x86_64"], "components": components}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.app, args.version, args.build), indent=2))
