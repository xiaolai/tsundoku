#!/usr/bin/env python3
"""Native fixture smoke test. Run only on the dedicated test Mac against a task-owned PID."""
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
        # Opening the menu is best-effort: its items are exposed in the AX
        # tree and the item press below is the action under test. A failed
        # menu-title press must not fail the check.
        subprocess.run(
            [str(args.helper), str(args.pid), "press", menu],
            text=True, capture_output=True, check=False)
    command("press", label)


def press_status_menu(label):
    """MenuBarExtra content exists only while its menu is open."""
    command("pressStatusMenu", "Tsundoku", label)


def snapshot(name, *expected, absent=()):
    text = ""
    for _ in range(6):
        text = command()
        if all(value in text for value in expected) and not any(
                value in text for value in absent):
            break
        time.sleep(0.2)
    (args.evidence / f"{name}.txt").write_text(text)
    if not text.strip():
        raise AssertionError(f"{name}: empty AX snapshot")
    for value in expected:
        if value not in text:
            raise AssertionError(f"{name}: expected {value!r}")
    for value in absent:
        if value in text:
            raise AssertionError(f"{name}: still present {value!r}")
    checks.append({"check": name, "passed": True, "expected": expected})


def expect_window_absent(name, title):
    """Direct window-enumeration check; an empty tree means no windows."""
    text = command("windows")
    (args.evidence / f"{name}.txt").write_text(text)
    if f"WINDOW {title}" in text:
        raise AssertionError(f"{name}: window {title!r} still present")
    checks.append({"check": name, "passed": True, "expected": None})


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


press_status_menu("Library…")
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
snapshot("separate-settings", "Companion", "Access", "AI Provider", "Library Data", "About")
command("key", "13", "cmd")
# The library text is behind Settings; the pane tabs prove it actually closed.
snapshot("settings-keeps-library", "Annotations", "6 results",
         absent=("AI Provider", "Library Data"))
expect_window_absent("settings-window-closed", "Companion")
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
press_status_menu("Library…")
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
if not window_ids:
    raise AssertionError("no library window ID for screenshots")
subprocess.run(["screencapture", "-x", "-l", window_ids[0], str(args.evidence / "cards-800.png")], check=True)
command("resize", "1280", "820")
subprocess.run(["screencapture", "-x", "-l", window_ids[0], str(args.evidence / "cards-1280.png")], check=True)

# Native close/reopen path: the window must disappear, then the status menu
# must bring it back. The app runs with --shell-only, so polling is disabled;
# this verifies the scene/window lifecycle, not live reader polling.
command("closeWindow", "Annotations")
expect_window_absent("library-closed", "Annotations")
press_status_menu("Library…")
snapshot("library-reopened", "2 books")
(args.evidence / "smoke-results.json").write_text(json.dumps(checks, indent=2) + "\n")
print(f"{len(checks)} native fixture checks passed")
