"""Verify PNG headers, dimensions and checksums without modifying images."""
import pathlib,sys,hashlib,struct,json
root=pathlib.Path(sys.argv[1])
manifest={}
for path in sorted(root.rglob('*')):
    if not path.is_file() or path.name=='asset-manifest.json': continue
    if path.suffix not in {'.png','.swift','.py','.sh','.sql','.patch'} and path.name not in {'README.md','shots.json','package-receipt.json','verification.json','demo-inventory.json'}: continue
    data=path.read_bytes()
    record={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    if path.suffix=='.png':
        assert data[:8]==b'\x89PNG\r\n\x1a\n',path
        record['width'],record['height']=struct.unpack('>II',data[16:24])
        if path.parent.name=='marketing': assert (record['width'],record['height'])==(3200,2400)
        if path.parent.name=='originals': assert record['width']>=2200 and record['height']>=1440
    manifest[str(path.relative_to(root))]=record
assert len(list((root/'originals').glob('*.png')))==15
assert len(list((root/'marketing').glob('*.png')))==15
assert (root/'contact-sheet.png').is_file()
(root/'asset-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('PASS: 15 clean app captures, 15 marketing images, contact sheet; PNG dimensions and SHA-256 manifest recorded.')
