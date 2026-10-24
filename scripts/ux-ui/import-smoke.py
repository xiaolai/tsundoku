#!/usr/bin/env python3
"""Run on the dedicated test Mac against an owned synthetic import fixture.

Launch the app with `--open-library --section annotations`, the fixture
`sources/books` as `--books-data-path`, and its `BKLibrary` directory denied
(`chmod 000`) so the first import reports a library-access failure.
"""
import argparse
import json
import pathlib
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument("pid", type=int)
p.add_argument("helper", type=pathlib.Path)
p.add_argument("sources", type=pathlib.Path)
p.add_argument("evidence", type=pathlib.Path)
a = p.parse_args()
a.evidence.mkdir(parents=True, exist_ok=True)
checks = []
library = a.sources / "books/Documents/BKLibrary"
if not library.is_dir():
    raise SystemExit(f"Missing owned fixture: {library}")
original_mode = library.stat().st_mode & 0o777


def command(*args):
    return subprocess.run(
        [str(a.helper), str(a.pid), *args],
        capture_output=True, text=True, check=True).stdout


def command_retry(*args):
    """Exit 4 means the AX tree changed mid-read; retry within the deadline."""
    try:
        return command(*args)
    except subprocess.CalledProcessError as error:
        if error.returncode == 4:
            return ""
        raise


def snapshot(name, *expected, absent=()):
    text = ""
    for _ in range(20):
        text = command_retry() or text
        if all(value in text for value in expected):
            break
        time.sleep(0.2)
    (a.evidence / (name + ".txt")).write_text(text)
    assert text.strip(), f"{name}: empty AX snapshot"
    for value in expected:
        assert value in text, (name, value)
    for value in absent:
        assert value not in text, (name, "unexpected", value)
    checks.append(name)


def capture(name):
    text = command("windowIDs")
    windows = [
        line.split()[1] for line in text.splitlines()
        if line.startswith("WINDOW_ID")
    ]
    assert windows, f"{name}: no task-owned window ID"
    subprocess.run(
        ["screencapture", "-x", "-l", windows[0],
         str(a.evidence / (name + ".png"))],
        check=True)


def geometry(name):
    text = command("frame", "Source")
    (a.evidence / (name + ".txt")).write_text(text)
    frame = next(list(map(float, line.split()[1:]))
                 for line in text.splitlines() if line.startswith("FRAME "))
    window = next(list(map(float, line.split()[1:]))
                  for line in text.splitlines()
                  if line.startswith("WINDOW_FRAME "))
    assert 20 <= frame[1] - window[1] <= 120, (name, frame, window)
    checks.append(name)


try:
    initial = command_retry() or ""
    assert "AXWindow | Annotations" in initial, (
        "Launch the fixture at --section annotations")

    command("resize", "1920", "1280")
    snapshot("denied-empty", "Library Access Needed", "Review Import Error",
             absent=("Showing archived records", "Source | All Sources"))
    capture("denied-empty")
    command("press", "Review Import Error")
    snapshot("denied-details", "Library Import", "Apple Books",
             "Grant Full Disk Access…", "Accessibility and Screen Recording")
    capture("denied-details")
    command("press", "Done")
    library.chmod(0o700)
    command("press", "Retry Import")
    snapshot("retry-imported", "1 results", "A passage from the first import.",
             absent=("Library Access Needed", "Review Import Error"))
    geometry("populated-large-top")
    capture("retry-imported")
    command("press", "Edit")
    command("press", "Find…")
    command("key", "0", "cmd")
    command("type", "definitely-no-fixture-match")
    snapshot("no-matches-large", "No Matches", "0 results")
    geometry("no-matches-large-top")
    capture("no-matches-large")
    command("resize", "760", "600")
    snapshot("no-matches-narrow", "No Matches", "0 results")
    geometry("no-matches-narrow-top")
    capture("no-matches-narrow")
    (a.evidence / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
    print(f"{len(checks)} native import/geometry checks passed")
finally:
    library.chmod(original_mode)
