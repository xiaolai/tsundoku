#!/usr/bin/env python3
"""Run on the dedicated test Mac: diagnostic side effects and empty-import UI."""
import argparse
import json
import pathlib
import re
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("root", type=pathlib.Path)
p.add_argument("app", type=pathlib.Path)
p.add_argument("helper", type=pathlib.Path)
a = p.parse_args()
a.root.mkdir(parents=True, exist_ok=False)
archive = a.root / "archive.sqlite"
checks = []
pid = None

# The fixture is task-owned; clear its preferences so repeated runs start from
# the same ordinary pane and first-launch state.
bundle_id = subprocess.check_output(
    ["plutil", "-extract", "CFBundleIdentifier", "raw",
     str(a.app / "Contents/Info.plist")], text=True).strip()
subprocess.run(["defaults", "delete", bundle_id], check=False)


def executable_pattern():
    return "^" + re.escape(str((a.app / "Contents/MacOS/Tsundoku").resolve())) + "( |$)"


def launch(*flags):
    subprocess.run(
        ["open", "-n", str(a.app), "--args", "--shell-only",
         "--no-system-integrations", "--archive-path", str(archive),
         "--kindle-library-path", str(a.root / "missing"),
         "--books-data-path", str(a.root / "missing"),
         "--duration", "120", *flags],
        check=True)
    for _ in range(60):
        result = subprocess.run(
            ["pgrep", "-f", executable_pattern()],
            capture_output=True, text=True)
        if result.stdout.strip():
            return int(result.stdout.split()[0])
        time.sleep(0.1)
    raise AssertionError("Fixture launch failed")


def command(*args):
    return subprocess.check_output(
        [str(a.helper), str(pid), *args], text=True)


def command_retry(*args):
    """Exit 4 means the AX tree changed mid-read; retry within the deadline."""
    try:
        return command(*args)
    except subprocess.CalledProcessError as error:
        if error.returncode == 4:
            return ""
        raise


def snapshot(name, *expected):
    text = ""
    for _ in range(30):
        text = command_retry() or text
        if all(x in text for x in expected):
            break
        time.sleep(0.1)
    (a.root / (name + ".txt")).write_text(text)
    assert text.strip(), f"{name}: empty AX snapshot"
    for value in expected:
        assert value in text, (name, value)
    checks.append(name)
    return text


def quit_app():
    if pid is None:
        return
    subprocess.run(
        ["osascript", "-e", 'tell application "' + str(a.app) + '" to quit'],
        check=False)
    for _ in range(50):
        if subprocess.run(
            ["kill", "-0", str(pid)], capture_output=True
        ).returncode:
            return
        time.sleep(0.1)
    raise AssertionError("Fixture did not quit normally")


pid = launch("--show-onboarding")
try:
    snapshot("setup", "Set up library imports", "No local library")
    command("press", "Re-check Library Access")
    snapshot("diagnostic-result", "No local library")
    # The unified Settings scene builds the AppModel to render the Access
    # pane, so the archive schema may exist; a permission check must not
    # import records into it.
    if archive.exists():
        import sqlite3
        with sqlite3.connect(archive) as db:
            assert db.execute("select count(*) from books").fetchone()[0] == 0
            assert db.execute("select count(*) from annotations").fetchone()[0] == 0
    checks.append("check-does-not-import")

    # Hiding Settings is not a cancellation: the pending setup survives, so
    # reopening the one Settings window still shows its task.
    command("key", "13", "cmd")
    time.sleep(0.5)
    command("press", "Settings…")
    snapshot("reopened-ordinary-pane", "Companion")
    checks.append("reopen-restores-ordinary-pane")
    command("press", "Access")
    snapshot("reopened-setup", "Set up library imports")
    checks.append("closing-settings-keeps-pending-setup")

    quit_app()
    pid = launch("--open-library")
    text = snapshot(
        "completed-empty-import", "No local Kindle or Apple Books stores found.")
    assert "Import your local Kindle or Apple Books library." not in text
    assert "Set up library imports" not in text
    checks.append("onboarding-close-cancels-pending-setup")
    (a.root / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(f"{len(checks)} native diagnostic/empty/close checks passed")
finally:
    quit_app()
