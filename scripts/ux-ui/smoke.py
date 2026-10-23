#!/usr/bin/env python3
"""Native fixture smoke test. Run only on macmini-000 against a task-owned PID."""
import argparse
import json
import pathlib
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("helper", type=pathlib.Path)
parser.add_argument("evidence", type=pathlib.Path)
args = parser.parse_args()
args.evidence.mkdir(parents=True, exist_ok=True)
checks = []


def command(*arguments):
    result = subprocess.run([str(args.helper), str(args.pid), *arguments], text=True, capture_output=True, check=True)
    if "TARGET NOT FOUND" in result.stdout:
        raise AssertionError(result.stdout)
    return result.stdout


def press(label, menu=None):
    if menu:
        command("press", menu)
    command("press", label)


def snapshot(name, *expected):
    text = ""
    for _ in range(6):
        text = command()
        if all(value in text for value in expected):
            break
        time.sleep(0.2)
    (args.evidence / f"{name}.txt").write_text(text)
    for value in expected:
        if value not in text:
            raise AssertionError(f"{name}: expected {value!r}")
    checks.append({"check": name, "passed": True, "expected": expected})


def panel_snapshot(name, *expected, absent=()):
    text = command()
    (args.evidence / f"{name}.txt").write_text(text)
    marker = "AXWindow | Annotation Inspector"
    if marker not in text:
        raise AssertionError(f"{name}: annotation inspector missing")
    panel = text.split(marker, 1)[1].split("\nAXWindow", 1)[0]
    for value in expected:
        if value not in panel:
            raise AssertionError(f"{name}: inspector missing {value!r}")
    for value in absent:
        if value in panel:
            raise AssertionError(f"{name}: inspector retained stale {value!r}")
    checks.append({"check": name, "passed": True, "expected": expected})


press("Library…")
if "Open in Annotations" in command():
    press("Back to Books", "View")
snapshot("books", "2 books", "Open Annotations")
press("Open Book Annotations", "File")
snapshot("book-workspace", "3 results", "Open in Annotations")
press("Cards", "View")
command("focus", "Highlight, Learning Through Small Experiments, Kindle")
command("key", "124")
snapshot("grid-first-arrow", "Selected, Highlight, Learning Through Small Experiments, Kindle", "3 results · 1 selected")
command("key", "124", "shift")
snapshot("grid-shift-arrow", "3 results · 2 selected")
command("key", "124", "shift")
snapshot("grid-repeated-shift-arrow", "3 results · 3 selected")
press("Select All", "Edit")
snapshot("cards-select-all", "3 results · 3 selected")
press("List")
snapshot("list-keeps-selection", "3 results · 3 selected", "Passage / Note")
press("Open in Annotations")
snapshot("global-book-scope", "3 results", "Source | Kindle", "All Books")
press("Options")
press("Reset Filters")
snapshot("reset-every-filter", "6 results", "Source | All Sources")
press("Cards", "View")
press("Find…", "Edit")
command("key", "0", "cmd")
command("type", "standalone")
snapshot("find-standalone-note", "1 results", "This standalone note must remain visible.", "Date unavailable")
command("key", "3", "cmd")
command("key", "0", "cmd")
command("key", "51")
snapshot("clear-search", "6 results")
press("Source")
press("Apple Books")
snapshot("apple-source", "3 results", "Source | Apple Books")
press("Kind")
press("Notes")
snapshot("apple-notes", "2 results", "Try a prediction", "This standalone note must remain visible.")
press("Options")
press("Reset Filters")
snapshot("reset-source-and-kind", "6 results", "Kind | All Kinds", "Source | All Sources")
press("Saved AI Notes…", "File")
snapshot("saved-ai-note", "AI-generated · Fixture provider", "A saved AI-generated answer")
press("Done")
press("Settings…")
snapshot("separate-settings", "Tsundoku Settings", "Companion")
command("key", "13", "cmd")
snapshot("settings-keeps-library", "Annotations", "6 results")
press("Show / Hide Inspector", "View")
snapshot("modeless-annotation-inspector", "Annotation Inspector", "Choose an Annotation")
command("resize", "800", "600")
snapshot("narrow-with-inspector", "Annotation Inspector", "6 results")
command("resize", "760", "600")
snapshot("minimum-with-inspector", "Annotation Inspector", "6 results")
command("resize", "1280", "820")
press("Highlight + Note, 观察与思考 — A Book with a Long Bilingual Title, Apple Books")
panel_snapshot("inspector-attached-note", "Notice what changes", "Try a prediction")
press("Note, Learning Through Small Experiments, Kindle")
panel_snapshot("inspector-follows-selection", "Kindle note stored in the text field.", absent=("Notice what changes",))
press("Show / Hide Inspector", "View")
press("Library…")
press("Show / Hide Inspector", "View")
snapshot("modeless-book-inspector", "Book Inspector", "2 books")
command("resize", "760", "600")
snapshot("minimum-book-inspector", "Book Inspector", "2 books")
press("Show / Hide Inspector", "View")
press("Saved AI Notes…", "File")
press("Done")
command("resize", "800", "600")
snapshot("narrow-cards", "6 results", "Passage text unavailable")
window_ids = [line.split()[-1] for line in command("windowIDs").splitlines() if line.startswith("WINDOW_ID")]
if window_ids:
    subprocess.run(["screencapture", "-x", "-l", window_ids[0], str(args.evidence / "cards-800.png")], check=True)
command("resize", "1280", "820")
if window_ids:
    subprocess.run(["screencapture", "-x", "-l", window_ids[0], str(args.evidence / "cards-1280.png")], check=True)
(args.evidence / "smoke-results.json").write_text(json.dumps(checks, indent=2) + "\n")
print(f"{len(checks)} native fixture checks passed")
