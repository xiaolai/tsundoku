#!/usr/bin/env python3
"""Run on the dedicated test Mac: FDA request and resumed import with owned stores."""
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
library = a.root / "sources/books/Documents/BKLibrary"
if not library.is_dir():
    raise SystemExit(f"Missing owned fixture: {library}")
original_mode = library.stat().st_mode & 0o777
checks = []
pid = None

# The fixture is task-owned; clear its preferences so repeated runs start from
# the same ordinary pane and first-launch state.
bundle_id = subprocess.check_output(
    ["plutil", "-extract", "CFBundleIdentifier", "raw",
     str(app / "Contents/Info.plist")], text=True).strip()
subprocess.run(["defaults", "delete", bundle_id], check=False)


def executable_pattern():
    return "^" + re.escape(str((app / "Contents/MacOS/Tsundoku").resolve())) + "( |$)"


def launch(stage, *flags):
    subprocess.run(
        ["open", "-n", str(app), "--args", "--shell-only",
         "--no-system-integrations", "--archive-path", str(archive),
         "--kindle-library-path", str(a.root / "absent"),
         "--books-data-path", str(a.root / "sources/books"),
         "--diagnostics", str(a.root / (stage + ".jsonl")),
         "--duration", "300", *flags],
        check=True)
    for _ in range(60):
        result = subprocess.run(
            ["pgrep", "-f", executable_pattern()],
            capture_output=True, text=True)
        if result.stdout.strip():
            return int(result.stdout.strip().splitlines()[0])
        time.sleep(0.1)
    raise AssertionError("Fixture did not launch")


def command(process, *args):
    return subprocess.run(
        [str(a.helper), str(process), *args],
        capture_output=True, text=True, check=True).stdout


def command_retry(process, *args):
    """Exit 4 means the AX tree changed mid-read; retry within the deadline."""
    try:
        return command(process, *args)
    except subprocess.CalledProcessError as error:
        if error.returncode == 4:
            return ""
        raise


def snapshot(process, name, *expected):
    text = ""
    for _ in range(30):
        text = command_retry(process) or text
        if all(value in text for value in expected):
            break
        time.sleep(0.2)
    (evidence / (name + ".txt")).write_text(text)
    assert text.strip(), f"{name}: empty AX snapshot"
    for value in expected:
        assert value in text, (name, value)
    checks.append(name)
    return text


def capture(process, name):
    text = command(process, "windowIDs")
    windows = [
        line.split()[1] for line in text.splitlines()
        if line.startswith("WINDOW_ID")
    ]
    assert windows, f"{name}: no task-owned window ID"
    subprocess.run(
        ["screencapture", "-x", "-l", windows[0],
         str(evidence / (name + ".png"))],
        check=True)


def wait_for_replacement(old_pid):
    for _ in range(150):
        result = subprocess.run(
            ["pgrep", "-f", executable_pattern()],
            capture_output=True, text=True)
        new_pids = [int(value) for value in result.stdout.split()
                    if int(value) != old_pid]
        if new_pids and subprocess.run(
            ["kill", "-0", str(old_pid)], capture_output=True
        ).returncode:
            return new_pids[0]
        time.sleep(0.1)
    raise AssertionError("Quit and Reopen did not replace the fixture process")


def quit_app():
    if pid is None:
        return
    subprocess.run(
        ["osascript", "-e", 'tell application "' + str(app) + '" to quit'],
        check=False)
    for _ in range(50):
        if subprocess.run(
            ["kill", "-0", str(pid)], capture_output=True
        ).returncode:
            return
        time.sleep(0.1)
    raise AssertionError("Fixture did not quit normally")


def wait_for_imported_archive():
    for _ in range(150):
        if archive.exists():
            with sqlite3.connect(archive) as db:
                if db.execute("select count(*) from books").fetchone()[0] == 1:
                    return
        time.sleep(0.1)
    raise AssertionError("Access verification did not continue import")


try:
    # Block the owned store so the request action is present: the Access pane
    # only offers Full Disk Access when a source is blocked or unready.
    library.chmod(0o000)
    pid = launch("initial", "--show-onboarding")
    snapshot(
        pid, "setup-before-check", "Set up library imports", "Library Imports",
        "Request Full Disk Access…", "Access blocked")
    capture(pid, "setup-before-check")

    command(pid, "press", "Request Full Disk Access…")
    snapshot(
        pid, "request-opened", "Set up library imports",
        "Re-check Library Access")
    settings = int(subprocess.check_output(
        ["pgrep", "-x", "System Settings"], text=True).strip().splitlines()[0])
    settings_text = ""
    for _ in range(30):
        settings_text = command_retry(settings) or settings_text
        if "Full Disk Access" in settings_text:
            break
        time.sleep(0.2)
    assert "Full Disk Access" in settings_text, (
        "Request must navigate to the actual FDA pane")
    # Do not retain other apps/account data from System Settings.
    (evidence / "pane-navigation.txt").write_text(
        "Observed Full Disk Access pane navigation after Request. The harness "
        "performs no grant/revocation action; real TCC grant acceptance is not "
        "covered.\n")

    rows = [json.loads(line) for line in
            (a.root / "initial.jsonl").read_text().splitlines()]
    events = [row.get("event") for row in rows]
    assert "library_registration_attempted" in events
    attempt = next(
        row for row in rows if row.get("event") == "library_registration_attempted")
    fields = attempt.get("fields", attempt)
    assert "directory_reads" in fields and "header_bytes_read" in fields, attempt
    assert 0 <= fields["header_bytes_read"] <= 2, attempt
    assert events.index("library_registration_attempted") < events.index(
        "library_access_settings_opened")
    checks.append("registration-attempt-precedes-settings")
    checks.append("direct-full-disk-pane")
    capture(pid, "access-request")

    library.chmod(0o000)
    command(pid, "press", "Re-check Library Access")
    snapshot(pid, "blocked-access", "Access blocked", "Set up library imports")
    checks.append("blocked-source-is-explicit")

    # The Settings window is the guide. Closing it must leave no orphan panel.
    command(pid, "key", "13", "cmd")
    time.sleep(0.5)
    assert "WINDOW Access" not in (command_retry(pid, "windows") or "")
    assert "WINDOW Companion" not in (command_retry(pid, "windows") or "")
    checks.append("settings-close-leaves-no-guide")

    command(pid, "press", "Settings…")
    command(pid, "press", "Access")
    snapshot(pid, "settings-reopened", "Set up library imports")

    old_pid = pid
    # The action is only offered while the status is blocked; restore the
    # store as the replacement process starts so it can read and import.
    # The app can terminate before AXPress returns, so the replacement
    # process below is the real assertion, not the press result.
    try:
        command(pid, "press", "Quit and Reopen Tsundoku")
    except subprocess.CalledProcessError as error:
        if error.returncode != 3:
            raise
    library.chmod(original_mode)
    pid = wait_for_replacement(old_pid)
    checks.append("quit-and-reopen-action")
    text = ""
    for _ in range(30):
        text = command_retry(pid) or text
        if "Libraries readable" in text:
            break
        time.sleep(0.2)
    assert "Libraries readable" in text, "resumed access did not become readable"
    (evidence / "resumed-setup.txt").write_text(text)
    checks.append("resume-without-onboarding-flag")

    wait_for_imported_archive()
    with sqlite3.connect(archive) as db:
        assert db.execute("select count(*) from annotations").fetchone()[0] == 1
    checks.append("automatic-import-after-resume")

    command(pid, "press", "Return to Library")
    snapshot(pid, "library-opened-after-setup", "First Import Fixture", "1 books")
    capture(pid, "library-opened-after-setup")

    rows = [json.loads(line) for line in
            (a.root / "initial.jsonl").read_text().splitlines()]
    started = [row for row in rows if row.get("event") == "library_import_started"]
    assert len(started) == 1, f"first import ran {len(started)} times"
    checks.append("no-duplicate-first-import")

    # A request from an already-open Settings must not leave a child panel.
    library.chmod(0o000)
    command(pid, "press", "Settings…")
    snapshot(pid, "settings-shown", "Companion", "Access", "AI Provider",
             "Library Data", "About")
    command(pid, "press", "Access")
    command(pid, "press", "Re-check Library Access")
    snapshot(pid, "settings-blocked", "Access blocked")
    command(pid, "press", "Request Full Disk Access…")
    snapshot(pid, "settings-request", "Set up library imports",
             "Access blocked")
    command(pid, "key", "13", "cmd")
    time.sleep(0.5)
    assert "WINDOW Access" not in (command_retry(pid, "windows") or "")
    checks.append("settings-request-close-leaves-no-guide")

    quit_app()
    pid = launch("after-cancel", "--open-library")
    time.sleep(1)
    text = command(pid)
    assert "Set up library imports" not in text
    assert "Request Full Disk Access…" not in text
    checks.append("cancelled-setup-does-not-resume")

    (evidence / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(f"{len(checks)} native setup/request/resume checks passed")
finally:
    library.chmod(original_mode)
    quit_app()
