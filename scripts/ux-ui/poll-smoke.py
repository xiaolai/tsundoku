#!/usr/bin/env python3
"""Verify close/reopen restarts polling and does not duplicate callbacks.

Run only on the dedicated test Mac against a task-owned process launched
without `--shell-only` and with `--diagnostics`. The library must be open at
launch (for example with `--open-library`).
"""
import argparse
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("helper", type=pathlib.Path)
parser.add_argument("evidence", type=pathlib.Path)
parser.add_argument("diagnostics", type=pathlib.Path)
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=True)

checks = []


def call(*items):
    result = subprocess.run(
        [str(args.helper), str(args.pid), *items],
        text=True, capture_output=True, check=True)
    if "TARGET NOT FOUND" in result.stdout:
        raise AssertionError(result.stdout)
    return result.stdout


def call_retry(*items):
    """Exit 4 means the AX tree changed mid-read; retry within the deadline."""
    try:
        return call(*items)
    except subprocess.CalledProcessError as error:
        if error.returncode == 4:
            return ""
        raise


def events(name):
    if not args.diagnostics.exists():
        return 0
    marker = f'"event":"{name}"'
    return sum(
        1 for line in args.diagnostics.read_text().splitlines()
        if marker in line)


def wait_for(predicate, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(0.2)
    raise AssertionError("timed out")


wait_for(lambda: events("live_poll_started") >= 1)
if events("live_poll_started") != 1:
    raise AssertionError("initial polling must start exactly once")
checks.append("initial-polling")

for cycle in range(3):
    call("closeWindow", "Books")
    wait_for(lambda: "WINDOW Books" not in (call_retry("windows") or ""))
    call("pressStatusMenu", "Tsundoku", "Library…")
    wait_for(lambda: "WINDOW Books" in (call_retry("windows") or ""))
    checks.append(f"reopened-{cycle + 1}")

# Exact counts catch duplicated observers: each open logs one shown, each
# close one closed, and each open one live_poll_started.
expected = {
    "live_poll_started": 4,
    "artifacts_window_shown": 4,
    "artifacts_window_closed": 3,
}
for name, count in expected.items():
    actual = events(name)
    if actual != count:
        raise AssertionError(f"{name}: expected {count}, got {actual}")
checks.append("no-duplicate-callbacks")

(args.evidence / "poll-cycles.txt").write_text("\n".join(checks) + "\n")
print(f"{len(checks)} polling checks passed")
