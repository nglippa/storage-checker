from pathlib import Path
import hashlib,json,subprocess,tempfile,sys
root=Path('/Users/nicholaslippa/storage-checker')
out=root/'artifacts/storage-monitor-v2/visual-review'
work=Path(tempfile.mkdtemp(prefix='storage-monitor-v2-visual-',dir='/private/tmp'))
source=root/'build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3'
assert not Path(str(source)+'-wal').exists()
subprocess.run(['cp','-c',str(source),str(work/'catalog.sqlite3')],check=True)
files=sorted([*root.glob('SourcesGUI/*.swift'),*root.glob('SourcesShared/*.swift')])
manifest={'qa_source':str(source),'qa_snapshot_mtime':source.stat().st_mtime,'work_dir':str(work),'method':'prohibited activation; hidden native hosting views; prepared model/disclosure states; no desktop input','source_hashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}}
(out/'provenance.json').write_text(json.dumps(manifest,indent=2))
app=(root/'SourcesGUI/StorageMonitorApp.swift').read_text().replace('@main struct StorageMonitorViewerApp','struct StorageMonitorViewerApp').replace('private struct AppearanceSettings','struct AppearanceSettings').replace('private struct WindowSetup','struct WindowSetup')
# Capture-only preference isolation: never write to the production or common QA preference domain.
app=app.replace('return configuration.isQA ? UserDefaults(suiteName: "local.macbook.storage-monitor.viewer.qa")! : .standard','return .standard')
app=app.replace('preferences.set(chartRange.rawValue,forKey:"chartRange")','/* capture process: do not persist range */')
app=app.replace('private func persist() { if let data = try? JSONEncoder().encode(filters) { preferences.set(data,forKey:"filters") } }','private func persist() { /* capture process: do not persist filters */ }')
(work/'StorageMonitorApp.swift').write_text(app)
tree=(root/'SourcesGUI/LivingTreeView.swift').read_text()+'\nextension LivingTreeView { var visualReviewHelp: some View { navigationHelp } }\n'
(work/'LivingTreeView.swift').write_text(tree)
inspector=(root/'SourcesGUI/InventoryNavigatorView.swift').read_text()
for state,key in [('showingAccounting','visual.capture.inspectorAccounting'),('showingCleanup','visual.capture.inspectorCleanup')]:
 old=f'@ViewState private var {state} = false'
 assert old in inspector,old
 inspector=inspector.replace(old,f'@ViewState private var {state} = UserDefaults.standard.bool(forKey: "{key}")')
(work/'InventoryNavigatorView.swift').write_text(inspector)
cmd=['/usr/bin/xcrun','swiftc','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-target','arm64-apple-macos14.0','-swift-version','5','-Onone','-parse-as-library','-module-cache-path',str(work/'module-cache'),'-framework','SwiftUI','-framework','Charts','-framework','AppKit']
cmd += [str(p) for p in files if p.name not in ['StorageMonitorApp.swift','LivingTreeView.swift','InventoryNavigatorView.swift']]
cmd += [str(work/'StorageMonitorApp.swift'),str(work/'LivingTreeView.swift'),str(work/'InventoryNavigatorView.swift'),str(out/'capture-tools/Capture.swift'),'-o',str(work/'visual-capture-v2')]
subprocess.run(cmd,check=True)
print(work,flush=True)
subprocess.run([str(work/'visual-capture-v2'),'--database-path',str(work/'catalog.sqlite3'),'--output',str(out/'source-screenshots'),*sys.argv[1:]],check=True)
