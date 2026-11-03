# Builds the headless navigation benchmark against the CURRENT working-tree sources (-O, as scripts/build-gui.sh),
# on a fresh APFS clone of the preserved QA catalog. Usage: prepare.py <label> [samples]
from pathlib import Path
import hashlib,json,subprocess,sys,tempfile
root=Path('/Users/nicholaslippa/storage-checker')
here=root/'artifacts/storage-monitor-v2/performance'
label=sys.argv[1]; samples=sys.argv[2] if len(sys.argv)>2 else '7'
work=Path(tempfile.mkdtemp(prefix=f'storage-monitor-perf-{label}-',dir='/private/tmp'))
source=root/'build/inventory-fresh-20261023T031313Z/previous-catalog.sqlite3'
assert not Path(str(source)+'-wal').exists()
subprocess.run(['cp','-c',str(source),str(work/'catalog.sqlite3')],check=True)
files=sorted([*root.glob('SourcesGUI/*.swift'),*root.glob('SourcesShared/*.swift')])
(here/f'provenance-{label}.json').write_text(json.dumps({'qa_source':str(source),'work_dir':str(work),'source_hashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}},indent=2))
app=(root/'SourcesGUI/StorageMonitorApp.swift').read_text().replace('@main struct StorageMonitorViewerApp','struct StorageMonitorViewerApp')
app=app.replace('return configuration.isQA ? UserDefaults(suiteName: "local.macbook.storage-monitor.viewer.qa")! : .standard','return .standard')
# Since the release-readiness milestone, view preferences go through ViewerStore.viewPreferences; keep the bench's own domain.
app=app.replace('nonisolated(unsafe) static let viewPreferences = preferences(for: .current)','nonisolated(unsafe) static let viewPreferences = UserDefaults.standard')
# --live-loop: the viewer's 2-second refresh loop runs only while the app is active; the bench app never is.
old='guard NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) else { continue }'
assert old in app
app=app.replace(old,'guard BenchHooks.liveLoop || (NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) })) else { continue }')
app=app.replace('preferences.set(chartRange.rawValue,forKey:"chartRange")','/* bench: not persisted */')
app=app.replace('private func persist() { if let data = try? JSONEncoder().encode(filters) { preferences.set(data,forKey:"filters") } }','private func persist() { }')
# The bench drives the section through a shared object instead of the toolbar picker; no other change.
inv=(root/'SourcesGUI/InventoryView.swift').read_text()
old='@State private var section = ViewerConfiguration.current.isQA && CommandLine.arguments.contains("--open-monitoring") ? "history" : "inventory"'
assert old in inv
inv=inv.replace(old,'@ObservedObject private var benchSection = BenchSection.shared\n    private var section: String { get { benchSection.value } nonmutating set { benchSection.value = newValue } }')
inv=inv.replace('Picker("Section", selection: $section)','Picker("Section", selection: $benchSection.value)')
old='_inventory = StateObject(wrappedValue: InventoryBrowserModel(database: store.configuration.database, readiness: store.readiness))'
assert old in inv
inv=inv.replace(old,'let model = InventoryBrowserModel(database: store.configuration.database, readiness: store.readiness); BenchHooks.inventory = model; _inventory = StateObject(wrappedValue: model)')
(work/'StorageMonitorApp.swift').write_text(app); (work/'InventoryView.swift').write_text(inv)
cmd=['/usr/bin/xcrun','swiftc','-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-target','arm64-apple-macos14.0','-swift-version','5','-O','-g','-parse-as-library','-module-cache-path',str(root/'build/module-cache'),'-framework','SwiftUI','-framework','Charts','-framework','AppKit']
cmd += [str(p) for p in files if p.name not in ['StorageMonitorApp.swift','InventoryView.swift']]
cmd += [str(work/'StorageMonitorApp.swift'),str(work/'InventoryView.swift'),str(here/'bench/Bench.swift'),'-o',str(work/'navigation-bench')]
subprocess.run(cmd,check=True)
print(work,flush=True)
