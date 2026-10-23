#!/usr/bin/env python3
"""Create an explicitly named synthetic archive; refuses an existing target."""
import pathlib
import sqlite3
import sys

path = pathlib.Path(sys.argv[1])
if path.exists():
    raise SystemExit("Refusing to replace an existing archive")
path.parent.mkdir(parents=True, exist_ok=True)
with sqlite3.connect(path) as db:
    db.executescript("""
    CREATE TABLE books (asin TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL,
        book_type INTEGER NOT NULL, read_state INTEGER NOT NULL, last_view REAL,
        current_position TEXT, max_position TEXT, downloaded INTEGER NOT NULL,
        source TEXT NOT NULL, imported_at REAL NOT NULL, progress REAL);
    CREATE TABLE annotations (id TEXT PRIMARY KEY, asin TEXT NOT NULL, kind TEXT NOT NULL,
        provenance TEXT NOT NULL, start_pos TEXT, end_pos TEXT, text TEXT, note TEXT, color TEXT,
        created_at REAL, modified_at REAL, source TEXT NOT NULL, archived_at REAL NOT NULL,
        book_source TEXT NOT NULL DEFAULT 'Kindle');
    CREATE TABLE ai_notes (id INTEGER PRIMARY KEY, asin TEXT, position TEXT, kind TEXT NOT NULL,
        prompt TEXT NOT NULL, answer TEXT NOT NULL, provider TEXT NOT NULL, created_at REAL NOT NULL,
        book_source TEXT);
    """)
    books = [("K1", "Learning Through Small Experiments", "Alex Example", "Kindle"),
             ("A1", "观察与思考 — A Book with a Long Bilingual Title", "Robin Sample", "Apple Books")]
    for asin, title, author, source in books:
        db.execute("INSERT INTO books VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
                   (asin, title, author, 10, 0, 1792500000, None, None, 1, source, 1792500000, 0.42))
    entries = [
        ("a1", "A1", "highlight", "Notice what changes when you ask a different question.",
         "Try a prediction before the next experiment.", "Apple Books", 1792500000),
        ("a2", "A1", "note", None, "只有笔记，没有引文。This standalone note must remain visible.", "Apple Books", None),
        ("a3", "A1", "bookmark", None, None, "Apple Books", 1792400000),
        ("k1", "K1", "highlight", None, None, "Kindle", 1792300000),
        ("k2", "K1", "note", "Kindle note stored in the text field.", None, "Kindle", 1792200000),
        ("k3", "K1", "highlight", "A long passage tests wrapping and a bounded preview. " * 25,
         "An attached note should be visible below the passage.", "Kindle", 1792100000),
    ]
    for ident, asin, kind, text, note, source, created in entries:
        db.execute("INSERT INTO annotations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   (ident, asin, kind, "user", "1234", "1240", text, note, None, created, None,
                    "synthetic fixture", 1792500000, source))
    db.execute("INSERT INTO ai_notes VALUES (1, 'A1', NULL, 'explain', 'Synthetic question', 'A saved AI-generated answer, separate from imported quotations.', 'Fixture provider', 1792500000, 'Apple Books')")
print(f"Synthetic fixture: {path}; 2 books, 6 annotations, 1 saved AI note")
