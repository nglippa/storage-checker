from pathlib import Path
import hashlib,json,struct,zlib
base=Path(__file__).resolve().parents[1];root=base.parents[1]
manifest=json.loads((base/'provenance.json').read_text())
changed=[p for p,h in manifest['source_hashes'].items() if hashlib.sha256((root/p).read_bytes()).hexdigest()!=h]
assert not changed,changed
sheets=json.loads((base/'layout.json').read_text())
expected={t['file'] for s in sheets for r in s['rows'] for t in r['tiles']}
actual={p.name for p in (base/'source-screenshots').glob('*.png')}
assert expected==actual,{'missing':list(expected-actual),'extra':list(actual-expected)}
assert {p.name for p in base.glob('*.png')}=={s['output'] for s in sheets}
def png(path):
    raw=path.read_bytes();assert raw[:8]==b'\x89PNG\r\n\x1a\n'
    offset=8;dimensions=None;ended=False
    while offset<len(raw):
        n=struct.unpack('>I',raw[offset:offset+4])[0];kind=raw[offset+4:offset+8];body=raw[offset+8:offset+8+n];crc=struct.unpack('>I',raw[offset+8+n:offset+12+n])[0]
        assert zlib.crc32(kind+body)&0xffffffff==crc,(path,kind)
        if kind==b'IHDR':dimensions=struct.unpack('>II',body[:8])
        offset+=n+12
        if kind==b'IEND':ended=True;break
    assert ended and offset==len(raw)
    return {'width':dimensions[0],'height':dimensions[1],'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
results={str(p.relative_to(base)):png(p) for p in [*sorted(base.glob('*.png')),*sorted((base/'source-screenshots').glob('*.png'))]}
log=(base/'capture-final.log').read_text()
assert 'COMPLETE activationPolicy=-1 visibleWindows=0' in log
assert log.count('CAPTURE ')==len(expected)
assert all('visible=false' in l for l in log.splitlines() if l.startswith('CAPTURE '))
report={'source_files_unchanged':len(manifest['source_hashes']),'source_screenshots':len(actual),'collages':len(sheets),'png_crc_validation':'passed','hidden_capture_guard':'passed','files':results}
(base/'verification.json').write_text(json.dumps(report,indent=2))
for s in sheets:print(s['output'],results[s['output']])
print('VERIFIED',len(sheets),'collages;',len(actual),'source screenshots;',len(manifest['source_hashes']),'application source hashes unchanged')
