from pathlib import Path
import hashlib,json,subprocess,tempfile
root=Path('/Users/nicholaslippa/storage-checker')
out=root/'artifacts/visual-review'
work=Path(tempfile.mkdtemp(prefix='storage-monitor-visual-',dir='/private/tmp'))
source=root/'build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3'
assert not Path(str(source)+'-wal').exists()
subprocess.run(['cp','-c',str(source),str(work/'catalog.sqlite3')],check=True)
files=sorted([*root.glob('SourcesGUI/*.swift'),*root.glob('SourcesShared/*.swift')])
manifest={'qa_source':str(source),'qa_snapshot_mtime':source.stat().st_mtime,'work_dir':str(work),'source_hashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(out/'provenance.json').write_text(json.dumps(manifest,indent=2))
app=(root/'SourcesGUI/StorageMonitorApp.swift').read_text().replace('@main struct StorageMonitorViewerApp','struct StorageMonitorViewerApp').replace('private struct AppearanceSettings','struct AppearanceSettings')
(work/'StorageMonitorApp.swift').write_text(app)
tree=(root/'SourcesGUI/LivingTreeView.swift').read_text()+'\nextension LivingTreeView { var visualReviewHelp: some View { navigationHelp } }\n'
(work/'LivingTreeView.swift').write_text(tree)
cmd=['/usr/bin/xcrun','swiftc','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-target','arm64-apple-macos14.0','-swift-version','5','-Onone','-parse-as-library','-module-cache-path',str(work/'module-cache'),'-framework','SwiftUI','-framework','Charts','-framework','AppKit']
cmd += [str(p) for p in files if p.name not in ['StorageMonitorApp.swift','LivingTreeView.swift']]
cmd += [str(work/'StorageMonitorApp.swift'),str(work/'LivingTreeView.swift'),str(out/'capture-tools/Capture.swift'),'-o',str(work/'visual-capture')]
subprocess.run(cmd,check=True)
print(work,flush=True)
subprocess.run([str(work/'visual-capture'),'--database-path',str(work/'catalog.sqlite3'),'--output',str(out/'source-screenshots')],check=True)
