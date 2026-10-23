#!/usr/bin/env python3
"""UI-only appearance/tooltips checks against an isolated preview on macmini-000."""
import argparse
import json
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("helper", type=pathlib.Path)
parser.add_argument("evidence", type=pathlib.Path)
parser.add_argument("domain")
args = parser.parse_args()
if not args.domain.startswith("com.lixiaolai.tsundoku.uxui-"):
    raise SystemExit("Use a task-owned preview preferences domain")
args.evidence.mkdir(parents=True, exist_ok=True)
checks = []


def call(*items):
    return subprocess.run([str(args.helper), str(args.pid), *items], text=True,
                          capture_output=True, check=True).stdout


def press(label, menu=None):
    if menu:
        call("press", menu)
    call("press", label)


def snapshot(name, *expected):
    text = call()
    (args.evidence / (name + ".txt")).write_text(text)
    for value in expected:
        assert value in text, (name, value)
    checks.append({"check": name, "passed": True})
    return text


def preference(key):
    result = subprocess.run(["defaults", "read", args.domain, key], text=True, capture_output=True)
    return int(result.stdout.strip()) if result.returncode == 0 else 0


def capture(name):
    ids = [line.split()[-1] for line in call("windowIDs").splitlines() if line.startswith("WINDOW_ID")]
    assert ids, "Task-owned app window is missing"
    subprocess.run(["screencapture", "-x", "-l", ids[0], str(args.evidence / name)], check=True)


press("Cards", "View")
text = snapshot("icon-card-actions", "6 results", "Show Details")
assert "HELP Show Details" in call("help", "Show Details")
assert "HELP View options" in call("help", "Options")
assert " |  |  | Show Details" not in text
assert "annotations |" not in text.splitlines()[1]
checks.append({"check": "icon-actions-retain-help-and-accessible-names", "passed": True})
if preference("browser.randomBorders"):
    press("Options")
    press("Random Border Colors")
capture("cards-neutral.png")
press("Options")
press("Random Border Colors")
assert preference("browser.randomBorders") == 1
snapshot("random-border-option", "6 results")
capture("cards-colored.png")
old_seed = preference("browser.borderSeed")
press("Options")
press("Shuffle Border Colors")
assert preference("browser.borderSeed") != old_seed
snapshot("shuffled-border-option", "6 results")
capture("cards-shuffled.png")
press("List")
press("Cards", "View")
assert preference("browser.randomBorders") == 1
snapshot("appearance-survives-presentation-change", "6 results")
press("Options")
press("Random Border Colors")
assert preference("browser.randomBorders") == 0
snapshot("neutral-borders-restored", "6 results")
press("Library…")
press("Open Book Annotations", "File")
text = snapshot("scoped-card-metadata", "3 results", "Open in Annotations")
title = "Learning Through Small Experiments"
visible_titles = [line for line in text.splitlines() if "AXStaticText" in line and line.endswith("| " + title)]
assert len(visible_titles) <= 1, "Book title repeats on scoped cards"
checks.append({"check": "scoped-book-title-is-not-repeated", "passed": True})
press("Open in Annotations")
press("Options")
press("Reset Filters")
press("Settings…")
press("AI Provider")
snapshot("ai-settings-icons", "Test Provider")
assert "HELP Test Provider" in call("help", "Test Provider")
press("Library Data")
snapshot("data-settings-icons", "Import Now")
assert "HELP Choose export folder" in call("help", "Choose…")
call("key", "13", "cmd")
call("select", "Exports")
snapshot("capture-icons", "Start Capture", "Advanced Capture Options")
assert "HELP Start capture" in call("help", "Start Capture")
call("select", "History")
snapshot("history-icons", "Track Reading", "Sessions are recorded only while tracking is on.")
assert "HELP Track reading" in call("help", "Track Reading")
(args.evidence / "results.json").write_text(json.dumps(checks, indent=2) + "\n")
print(f"{len(checks)} appearance and icon checks passed")
