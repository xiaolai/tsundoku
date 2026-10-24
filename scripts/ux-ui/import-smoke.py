#!/usr/bin/env python3
"""Run on macmini-000 against an owned synthetic import fixture process only."""
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


def command(*args):
    r = subprocess.run([str(a.helper), str(a.pid), *args], capture_output=True, text=True, check=True)
    return r.stdout


def snapshot(name, *expected, absent=()):
    for _ in range(8):
        text = command()
        if all(s in text for s in expected):
            break
        time.sleep(0.2)
    (a.evidence / (name + ".txt")).write_text(text)
    for s in expected:
        assert s in text, (name, s)
    for s in absent:
        assert s not in text, (name, "unexpected", s)
    checks.append(name)


def capture(name):
    text = command("windowIDs")
    window = next(l.split()[1] for l in text.splitlines() if l.startswith("WINDOW_ID"))
    subprocess.run(["screencapture", "-x", "-l", window, str(a.evidence / (name + ".png"))], check=True)


def geometry(name):
    text = command("frame", "Source")
    (a.evidence / (name + ".txt")).write_text(text)
    frame = next(list(map(float, l.split()[1:])) for l in text.splitlines() if l.startswith("FRAME "))
    window = next(list(map(float, l.split()[1:])) for l in text.splitlines() if l.startswith("WINDOW_FRAME "))
    assert 20 <= frame[1] - window[1] <= 120, (name, frame, window)
    checks.append(name)


command("resize", "1920", "1280")
snapshot("denied-empty", "Library Access Needed", "Review Import Error",
         absent=("Showing archived records", "Source | All Sources"))
capture("denied-empty")
command("press", "Review Import Error")
snapshot("denied-details", "Library Import", "Apple Books", "Open Full Disk Access…", "Accessibility and Screen Recording")
capture("denied-details")
command("press", "Done")
(a.sources / "books/Documents/BKLibrary").chmod(0o700)
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
