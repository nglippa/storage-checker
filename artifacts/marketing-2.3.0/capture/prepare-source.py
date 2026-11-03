"""Capture-only application wiring. Candidate view sources remain unchanged."""
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
assert source.count('@main struct StorageMonitorViewerApp')==1
source=source.replace('@main struct StorageMonitorViewerApp','struct StorageMonitorViewerApp')
original='let live = LiveCapacityMonitor()'
replacement='let live = LiveCapacityMonitor(source: { LiveCapacityReading(timestamp: Date(), free: 154_800_000_000, total: 1_000_000_000_000, dataVolumeUUID: "DEMO-DATA") })'
assert source.count(original)==1
source=source.replace(original,replacement)
pathlib.Path(sys.argv[2]).write_text(source)
