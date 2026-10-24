#!/usr/bin/env python3
"""macmini-000 only: diagnostic check side effects and completed empty-import UI."""
import argparse
import json
import pathlib
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


def launch(*flags):
    subprocess.run(["open", "-n", str(a.app), "--args", "--shell-only", "--no-system-integrations",
                    "--archive-path", str(archive), "--kindle-library-path", str(a.root / "missing"),
                    "--books-data-path", str(a.root / "missing"), "--duration", "120", *flags], check=True)
    for _ in range(60):
        r = subprocess.run(["pgrep", "-f", "^" + str(a.app.resolve() / "Contents/MacOS/Tsundoku")], capture_output=True, text=True)
        if r.stdout.strip():
            return int(r.stdout.split()[0])
        time.sleep(0.1)
    raise AssertionError("Fixture launch failed")


def command(*args):
    return subprocess.check_output([str(a.helper), str(pid), *args], text=True)


def snapshot(name, *expected):
    for _ in range(30):
        text = command()
        if all(x in text for x in expected):
            (a.root / (name + ".txt")).write_text(text)
            checks.append(name)
            return text
        time.sleep(0.1)
    raise AssertionError((name, expected, text))


def quit_app():
    subprocess.run(["osascript", "-e", 'tell application "' + str(a.app) + '" to quit'], check=True)
    for _ in range(50):
        if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode:
            return
        time.sleep(0.1)
    raise AssertionError("Fixture did not quit normally")


pid = launch("--show-onboarding")
try:
    snapshot("setup", "Set Up Tsundoku", "Not checked")
    command("press", "Re-check Library Access")
    snapshot("diagnostic-result", "No local library")
    assert not archive.exists(), "A check must not construct an import model or archive"
    checks.append("check-does-not-create-archive")
    command("press", "Grant Full Disk Access…")
    snapshot("guide-open", "Grant Library Access")
    command("press", "Later")
    command("press", "Re-check Library Access")
    time.sleep(0.3)
    assert "Library Access FRAME" not in command("windows"), "A dismissed child panel must not reappear"
    checks.append("later-stays-dismissed-after-parent-activation")
    command("press", "Grant Full Disk Access…")
    snapshot("guide-reopened", "Grant Library Access")
    command("closeWindow", "Tsundoku")
    time.sleep(0.5)
    assert "Library Access FRAME" not in command("windows")
    checks.append("onboarding-red-close-closes-guide")
    quit_app()
    pid = launch("--open-library")
    text = snapshot("completed-empty-import", "No local Kindle or Apple Books stores found.")
    assert "Import your local Kindle or Apple Books library." not in text
    assert "Set Up Tsundoku" not in text
    checks.append("onboarding-close-cancels-pending-setup")
    (a.root / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(f"{len(checks)} native diagnostic/empty/close checks passed")
finally:
    quit_app()
