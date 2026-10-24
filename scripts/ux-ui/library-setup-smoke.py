#!/usr/bin/env python3
"""macmini-000 only: direct FDA navigation and resumed import with owned synthetic stores."""
import argparse
import json
import pathlib
import re
import sqlite3
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("root", type=pathlib.Path)
p.add_argument("helper", type=pathlib.Path)
a = p.parse_args()
app = a.root / "Fixture.app"
evidence = a.root / "evidence"
evidence.mkdir(exist_ok=True)
archive = a.root / "flow.sqlite"
if archive.exists():
    raise SystemExit("Refusing to reuse an existing flow archive")
checks = []


def launch(stage, onboarding=False):
    args = ["open", "-n", str(app), "--args", "--shell-only", "--no-system-integrations",
            "--archive-path", str(archive), "--kindle-library-path", str(a.root / "absent"),
            "--books-data-path", str(a.root / "sources/books"),
            "--diagnostics", str(a.root / (stage + ".jsonl")), "--duration", "300"]
    if onboarding:
        args += ["--show-onboarding"]
    subprocess.run(args, check=True)
    for _ in range(50):
        r = subprocess.run(["pgrep", "-f", "^" + str(app.resolve()) + "/Contents/MacOS/Tsundoku"], capture_output=True, text=True)
        if r.stdout.strip():
            return int(r.stdout.strip().splitlines()[0])
        time.sleep(0.1)
    raise AssertionError("Fixture did not launch")


def command(pid, *args):
    return subprocess.run([str(a.helper), str(pid), *args], capture_output=True, text=True, check=True).stdout


def snapshot(pid, name, *expected):
    for _ in range(20):
        text = command(pid)
        if all(s in text for s in expected):
            break
        time.sleep(0.2)
    (evidence / (name + ".txt")).write_text(text)
    for s in expected:
        assert s in text, (name, s)
    checks.append(name)
    return text


def capture(pid, name):
    text = command(pid, "allWindowIDs")
    window = next(l.split()[1] for l in text.splitlines() if l.startswith("WINDOW_ID"))
    subprocess.run(["screencapture", "-x", "-l", window, str(evidence / (name + ".png"))], check=True)


pid = launch("initial", onboarding=True)
snapshot(pid, "setup-before-check", "Set Up Tsundoku", "Library Access", "Grant Full Disk Access…", "Not checked")
capture(pid, "setup-before-check")
command(pid, "press", "Grant Full Disk Access…")
snapshot(pid, "grant-guide", "Grant Library Access", "Drag into", "imported automatically")
settings = int(subprocess.check_output(["pgrep", "-x", "System Settings"], text=True).strip().splitlines()[0])
settings_text = command(settings)
assert "Full Disk Access" in settings_text, "Request must navigate to the actual FDA pane"
# Do not retain other apps/account data from System Settings.
(evidence / "pane-navigation.txt").write_text("Observed Full Disk Access pane navigation after Grant without a prior Check. The harness performs no grant/revocation action; real TCC grant acceptance is not covered.\n")
checks.append("direct-full-disk-pane")
capture(pid, "grant-guide") # Activation verifies the deliberately blocked fixture.
snapshot(pid, "blocked-guide", "Access blocked", "Grant Library Access")
# Record only geometry, without retaining account or other application names.
def frames(process):
    text = command(process, "windows")
    return [(line.split(" FRAME ")[0].removeprefix("WINDOW "),
             list(map(float, line.split(" FRAME ")[1].split())))
            for line in text.splitlines() if " FRAME " in line]

def overlaps(a, b):
    return a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]

time.sleep(1)
guide = next(frame for title, frame in frames(pid) if title == "Library Access")
settings_frames = [frame for _, frame in frames(settings)]
assert settings_frames and not any(overlaps(guide, f) for f in settings_frames), (guide, settings_frames)
(evidence / "panel-placement.json").write_text(json.dumps({"guide": guide, "settings_frames": settings_frames}, indent=2))
checks.append("guide-does-not-cover-settings")
old_pid = pid
command(pid, "press", "Quit and Reopen Tsundoku")
(a.root / "sources/books/Documents/BKLibrary").chmod(0o700)
for _ in range(150):
    r = subprocess.run(["pgrep", "-f", "^" + str(app.resolve()) + "/Contents/MacOS/Tsundoku"], capture_output=True, text=True)
    new_pids = [int(x) for x in r.stdout.split() if int(x) != old_pid]
    if new_pids and subprocess.run(["kill", "-0", str(old_pid)], capture_output=True).returncode:
        pid = new_pids[0]
        break
    time.sleep(0.1)
else:
    raise AssertionError("Quit and Reopen did not replace the fixture process")
checks.append("quit-and-reopen-action")
text = snapshot(pid, "resumed-setup", "Set Up Tsundoku", "Libraries readable")
checks.append("resume-without-onboarding-flag")
for _ in range(100):
    if archive.exists():
        with sqlite3.connect(archive) as db:
            if db.execute("select count(*) from books").fetchone()[0] == 1:
                break
    time.sleep(0.1)
else:
    raise AssertionError("Access verification did not continue import")
with sqlite3.connect(archive) as db:
    assert db.execute("select count(*) from annotations").fetchone()[0] == 1
checks.append("automatic-import-after-resume")
if "Drag into" in text:
    command(pid, "press", "Done")
command(pid, "press", "Continue Anyway")
snapshot(pid, "library-opened-after-setup", "First Import Fixture", "1 books")
capture(pid, "library-opened-after-setup")
rows = [json.loads(s) for s in (a.root / "initial.jsonl").read_text().splitlines()]
assert len([r for r in rows if r.get("event") == "library_import_started"]) == 1
checks.append("no-duplicate-first-import")
# A parent red-close must cancel setup and dispose its guide, not carry intent to launch.
(a.root / "sources/books/Documents/BKLibrary").chmod(0o000)
command(pid, "press", "Settings…")
snapshot(pid, "settings-shown", "Tsundoku Settings")
command(pid, "press", "Full Disk Access…")
snapshot(pid, "settings-guide", "Grant Library Access")
command(pid, "closeWindow", "Tsundoku Settings")
time.sleep(0.5)
assert not any(title == "Library Access" for title, _ in frames(pid)), "Closing Settings must close its guide"
checks.append("parent-close-disposes-guide")
subprocess.run(["osascript", "-e", 'tell application "' + str(app) + '" to quit'], check=True)
for _ in range(50):
    if subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode: break
    time.sleep(0.1)
pid = launch("after-cancel")
time.sleep(1)
text = command(pid)
assert "Set Up Tsundoku" not in text and "Grant Library Access" not in text
checks.append("cancelled-setup-does-not-resume")
(evidence / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
print(f"{len(checks)} native setup/request/resume checks passed")
# Stop only the explicitly owned fixture.
subprocess.run(["kill", "-TERM", str(pid)], check=True)
