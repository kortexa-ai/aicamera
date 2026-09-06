#!/usr/bin/env python3
"""Check public source inputs and scan all reachable Git history with Gitleaks."""
import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--gitleaks", default=shutil.which("gitleaks"))
args = parser.parse_args()
if not args.gitleaks:
    parser.error("Install Gitleaks or pass --gitleaks /path/to/verified/gitleaks")
root = Path(__file__).resolve().parent.parent
tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).split(b"\0")
untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=root).split(b"\0")
paths = sorted({p.decode() for p in tracked + untracked if p})
for name in paths:
    assert not re.search(r"(^|/)(\.env(?:\..*)?|auth\.json|Local\.xcconfig)$|\.(p12|pfx|pem|mobileprovision|provisionprofile)$", name), f"Private release input: {name}"
    assert not name.startswith(("build/", ".build/", "artifacts/")), f"Generated release input: {name}"
    assert (root / name).is_file(), f"Unexpected input type: {name}"

with tempfile.TemporaryDirectory(prefix="aicamera-public-audit-") as temporary:
    work = Path(temporary)
    current = work / "current"
    for name in paths:
        dest = current / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / name, dest)
    for mode, extra, target in (("git", ["--log-opts=--all"], root), ("dir", [], current)):
        report = work / f"{mode}.json"
        result = subprocess.run([args.gitleaks, mode, *extra, "--redact=100", "--no-banner",
                                 "--report-format=json", "--report-path", str(report), str(target)],
                                capture_output=True, text=True)
        findings = json.loads(report.read_text()) if report.exists() else []
        # Deliberately emit only locations/rules, never matches or credential values.
        print(json.dumps({"scope": mode, "exit": result.returncode, "findings": [
            {k: f.get(k) for k in ("RuleID", "File", "StartLine", "Commit")} for f in findings]}))
        assert result.returncode == 0 and not findings, "Resolve secret-scan findings before publishing"
print(f"Public input scan passed: {len(paths)} files and all reachable Git history. Manual review is still required.")
