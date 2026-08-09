#!/usr/bin/env bash
#
# Parse-check every `run:` block in the GitHub Actions workflow.
#
#   ./Scripts/check-workflow.sh
#
# Why this exists: a shell syntax error inside a `run:` block is invisible until the step executes, and
# a step that only runs on failure is invisible until something *else* fails. Exactly that happened — a
# diagnostic block written to explain a hanging test suite was missing its `fi`, so the one run that
# would have printed the explanation died with "unexpected end of file" instead, and the information was
# lost for another full CI cycle.
#
# `bash -n` parses without executing, which is all that is needed to catch it.
#
# Actions expressions (${{ ... }}) are substituted by the runner before bash sees the script, so they are
# replaced with a literal here. That means this checks *syntax*, not that the expressions are correct.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

WORKFLOW=".github/workflows/build.yml"

if [ ! -f "$WORKFLOW" ]; then
    echo "No workflow at $WORKFLOW"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is needed to read the workflow YAML."
    exit 1
fi

python3 - "$WORKFLOW" <<'PY'
import re
import subprocess
import sys

path = sys.argv[1]

try:
    import yaml
except ImportError:
    print("PyYAML is not installed — skipping (pip install pyyaml to enable).")
    sys.exit(0)

with open(path) as handle:
    workflow = yaml.safe_load(handle)

failures = 0
checked = 0

for job in workflow.get("jobs", {}).values():
    for step in job.get("steps", []):
        script = step.get("run")
        if not script:
            continue
        checked += 1
        # A literal stand-in: the runner substitutes these before bash parses the script, and an
        # unsubstituted `${{ }}` is not valid shell.
        substituted = re.sub(r"\$\{\{[^}]*\}\}", "placeholder", script)
        result = subprocess.run(
            ["bash", "-n"], input=substituted, text=True, capture_output=True
        )
        name = step.get("name", "(unnamed step)")
        if result.returncode == 0:
            print(f"  ok    {name}")
        else:
            failures += 1
            print(f"  FAIL  {name}")
            for line in result.stderr.strip().splitlines():
                print(f"          {line}")

print()
if failures:
    print(f"==> {failures} of {checked} run blocks have syntax errors")
    sys.exit(1)

print(f"==> All {checked} run blocks parse")
PY
