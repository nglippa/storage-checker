"""Package only verified deliverables; leave databases, binaries, caches and logs out."""
import pathlib,sys,json,hashlib,zipfile
root=pathlib.Path(sys.argv[1])
archive=pathlib.Path(sys.argv[2])
manifest=json.loads((root/'asset-manifest.json').read_text())
prefix='Storage-Monitor-2.3.0-Marketing-Kit/'
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=7) as target:
    for name,record in sorted(manifest.items()):
        source=root/name
        assert hashlib.sha256(source.read_bytes()).hexdigest()==record['sha256'],name
        target.write(source,prefix+name)
    target.write(root/'asset-manifest.json',prefix+'asset-manifest.json')
with zipfile.ZipFile(archive) as target:
    assert target.testzip() is None
    for name,record in manifest.items():
        assert hashlib.sha256(target.read(prefix+name)).hexdigest()==record['sha256'],name
    assert len([name for name in target.namelist() if '/originals/' in name])==15
    assert len([name for name in target.namelist() if '/marketing/' in name])==15
checksum=hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_suffix('.zip.sha256').write_text(checksum+'  '+archive.name+'\n')
print(json.dumps({'zip':str(archive),'bytes':archive.stat().st_size,'sha256':checksum,'integrity':'PASS','assetChecksums':'PASS','cleanImages':15,'marketingImages':15,'entries':len(manifest)+1},indent=2))
