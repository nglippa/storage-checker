#!/usr/bin/env python3
"""Bounded-memory, read-only table fingerprints for disposable history clones."""
import hashlib
import json
import pathlib
import sqlite3
import sys
import urllib.parse

path = pathlib.Path(sys.argv[1])
if not str(path).startswith('/private/tmp/storage-apfs-acceptance-') or path.resolve() != path:
    raise SystemExit('Expected an unaliased disposable history clone')
database = sqlite3.connect('file:' + urllib.parse.quote(str(path), safe='/') + '?mode=ro', uri=True)
database.execute('BEGIN')
tables = {}
for name, schema in database.execute("SELECT name,sql FROM sqlite_master WHERE type='table' ORDER BY name").fetchall():
    digest = hashlib.sha256()
    escaped = name.replace('"', '""')
    ordering = '' if 'WITHOUT ROWID' in (schema or '').upper() else ' ORDER BY rowid'
    count = 0
    for row in database.execute('SELECT * FROM "' + escaped + '"' + ordering):
        count += 1
        for cell in row:
            if cell is None:
                value = b'n'
            elif isinstance(cell, bytes):
                value = b'b' + cell
            elif isinstance(cell, int):
                value = b'i' + str(cell).encode()
            elif isinstance(cell, float):
                value = b'f' + cell.hex().encode()
            else:
                value = b's' + cell.encode('utf-8')
            digest.update(len(value).to_bytes(8, 'big'))
            digest.update(value)
        digest.update(b'\n')
    tables[name] = {'rows': count, 'sha256': digest.hexdigest(), 'schema': schema}
    print(name + ': ' + str(count) + ' rows', file=sys.stderr, flush=True)
result = {'tables': tables, 'user_version': database.execute('PRAGMA user_version').fetchone()[0]}
database.rollback()
database.close()
print(json.dumps(result, sort_keys=True, indent=2))
