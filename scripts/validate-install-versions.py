#!/usr/bin/env python3
"""Exercise metadata guards from the rendered installer without running its transaction.

Only the actual source/staged/final version-check fragments run, against temporary plists.
No signing, privileged action, app replacement, process control, or component activation occurs.
"""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


command = Path(sys.argv[1]).read_text()


def section(start, end):
    begin = command.index(start)
    result = command[begin:command.index(end, begin)]
    assert not any(word in result for word in ["codesign", "/bin/mv", "/bin/rm", "sudo", "kill", "chown", "chmod"])
    return result


source = section("version=$(/usr/libexec/PlistBuddy", "; team=")
staged = section('tmp_ext="$tmp/Contents/Library/SystemExtensions/', "; tmp_team=")
final_start = 'verify_product "$dst" "$final_ext"; '
# Exclude signature checks; those remain exercised against real signed products by installation.
start = command.index(final_start) + len(final_start)
final = command[start:command.index("; companion_pids ()", start)]
assert final.startswith('test "$(/usr/libexec/PlistBuddy')
assert not any(word in final for word in ["codesign", "/bin/mv", "/bin/rm", "sudo", "kill", "chown", "chmod"])

project = (Path(__file__).resolve().parent.parent / "project.yml").read_text()
extension_target = re.search(r"^  AICameraCameraExtension:\n(.*?)(?=^  \w+:|\Z)", project, re.M | re.S)
assert extension_target, "Missing camera extension target"
for setting in ["CURRENT_PROJECT_VERSION", "MARKETING_VERSION"]:
    assert re.search(rf"^        {setting}:\s*\S+", extension_target.group(1), re.M), (
        f"Camera extension must explicitly version {setting}, independently of the host"
    )

checks = 0
with tempfile.TemporaryDirectory(prefix="aicamera-version-fixture-") as directory:
    app = Path(directory) / "Test App.app"
    ext = app / "Contents/Library/SystemExtensions/ai.kortexa.aicamera.camera-extension.systemextension"
    (ext / "Contents").mkdir(parents=True)
    environment = dict(os.environ, src=str(app), tmp=str(app), dst=str(app), ext=str(ext),
                       tmp_ext=str(ext), final_ext=str(ext), expected="ai.kortexa.aicamera",
                       expected_ext="ai.kortexa.aicamera.camera-extension", version="45", ext_version="44")

    def write(host="45", camera="44", host_id="ai.kortexa.aicamera",
              camera_id="ai.kortexa.aicamera.camera-extension"):
        for bundle, version, identifier in [(app, host, host_id), (ext, camera, camera_id)]:
            info = {"CFBundleIdentifier": identifier}
            if version is not None:
                info["CFBundleVersion"] = version
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))

    def check(name, fragment, succeeds):
        global checks
        result = subprocess.run(["/bin/sh", "-eu", "-c", fragment], env=environment,
                                capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == succeeds, f"{name}: unexpected exit {result.returncode}: {result.stderr}"
        checks += 1

    for host, camera in [("45", "44"), ("44", "44")]:
        write(host, camera)
        check("source supports independent and matching versions", source, True)
    for invalid in [None, "", "bad", "44.1", "-1", "$(false)"]:
        write(camera=invalid)
        check("source rejects invalid component version", source, False)
    write(host="bad")
    check("source rejects invalid host generation", source, False)

    for name, fragment in [("staged", staged), ("installed", final)]:
        write()
        check(name + " preserves independent versions", fragment, True)
        write(camera="45")
        check(name + " rejects altered component version", fragment, False)
        write(camera=None)
        check(name + " rejects missing component version", fragment, False)
        write(host="46")
        check(name + " rejects altered host version", fragment, False)
        write(host_id="wrong.host")
        check(name + " rejects wrong host identity", fragment, False)
    write(camera_id="wrong.extension")
    check("staged rejects wrong component identity", staged, False)

print(f"Installer version checks passed: {checks} source/staged/installed cases; explicit component versions")
