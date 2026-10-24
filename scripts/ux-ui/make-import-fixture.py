#!/usr/bin/env python3
"""Synthetic source stores for native first-import and permission-retry checks."""
import pathlib
import sqlite3
import sys

root = pathlib.Path(sys.argv[1])
if root.exists():
    raise SystemExit("Refusing to replace an existing fixture")
library = root / "books/Documents/BKLibrary"
notes = root / "books/Documents/AEAnnotation"
library.mkdir(parents=True)
notes.mkdir(parents=True)
with sqlite3.connect(library / "BKLibrary-test.sqlite") as db:
    db.execute("CREATE TABLE ZBKLIBRARYASSET (ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZCONTENTTYPE INTEGER,ZREADINGPROGRESS REAL,ZLASTOPENDATE REAL,ZDATEFINISHED REAL,ZISFINISHED INTEGER,ZPATH TEXT)")
    db.execute("INSERT INTO ZBKLIBRARYASSET VALUES ('FIXTURE','First Import Fixture','Example Author',1,0.3,NULL,NULL,0,NULL)")
with sqlite3.connect(notes / "AEAnnotation-test.sqlite") as db:
    db.execute("CREATE TABLE ZAEANNOTATION (Z_PK INTEGER,ZANNOTATIONUUID TEXT,ZANNOTATIONASSETID TEXT,ZANNOTATIONTYPE INTEGER,ZANNOTATIONSELECTEDTEXT TEXT,ZANNOTATIONNOTE TEXT,ZANNOTATIONLOCATION TEXT,ZANNOTATIONCREATIONDATE REAL,ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONDELETED INTEGER)")
    db.execute("INSERT INTO ZAEANNOTATION VALUES (1,'fixture-note','FIXTURE',2,'A passage from the first import.',NULL,'123',NULL,NULL,0)")
print("Created synthetic book and annotation stores")
