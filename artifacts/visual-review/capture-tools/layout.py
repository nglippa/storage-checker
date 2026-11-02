import json
from pathlib import Path
base=Path(__file__).resolve().parents[1]
def tile(file,title,note): return dict(file=file+'.png',title=title,note=note)
def row(heading,*tiles): return dict(heading=heading,tiles=tiles)
a=[
row('01 / Storage landing and compact layout',
tile('i01-storage-default-atlas-light','01  Default Storage landing','Light · 1440 × 840 pt content · Atlas and Navigator'),
tile('i02-storage-minimum-atlas-dark','02  Compact Storage','Dark · 1000 × 640 pt content · 1000 × 700 window equivalent')),
row('02 / Follow the folder hierarchy',
tile('i03-expanded-hierarchy-folder-details-light','03  Expanded folder and Inspector','Light · expanded Users branch · selection and folder details'),
tile('i09-atlas-open-home-light','04  Atlas inside a folder','Light · nested treemap and breadcrumb navigation')),
row('03 / Living Tree — overview, depth and selection',
tile('i04-living-tree-overview-dark','05  Living Tree overview','Dark · 2D · controls, Navigator and Inspector'),
tile('i05-living-tree-3d-dark','06  Living Tree in 3D','Dark · same indexed hierarchy · depth mode')),
row(None,
tile('i06-living-tree-selected-folder-dark','07  Selected folder in 3D','Dark · selection indicator and Inspector'),
tile('i07-living-tree-selection-light','08  Selection in a light window','Light window · the Living Tree canvas intentionally remains dark')),
row('04 / Ranked storage lists',
tile('i10-largest-files-dark','09  Largest files','Dark · populated ranking with selected file details'),
tile('i11-largest-folders-light','10  Largest folders','Light · folder ranking and indexed measurement qualifications')),
row('05 / Cleanup review — candidates and evidence',
tile('i12-cleanup-review-candidates-dark','11  Review-candidate filter, empty','Dark · actual empty state: this stale snapshot needs revalidation'),
tile('i13-cleanup-candidate-selected-dark','12  Populated review list, item selected','Dark · all assessments · current read-only evidence from real paths')),

row('06 / Detail reading — no removal performed',
tile('i08-living-tree-navigation-help-component','13  Living Tree help','Standalone actual help content · 460 × 570 pt · not a popover capture'),
tile('i14-cleanup-item-full-details-light','14  Cleanup Inspector','Light · standalone Inspector · eligibility and evidence · QA removal disabled'),
tile('i16-cleanup-other-item-details-dark','15  Another item assessment','Dark · standalone Inspector · actual current filesystem evidence'),
tile('i15-cleanup-all-assessments-dark','16  Informational review plan','Dark · standalone plan component · excluded selections remain visible'))]
b=[
row('01 / Monitoring overview and expanded event context',
tile('m01-monitoring-default-large-dark','01  Default Monitoring overview','Dark · 1440 × 840 pt content · capacity, latest change, chart and events'),
tile('m04-monitoring-selected-event-large-light','02  Event selected at desktop size','Light · 1440 × 840 pt content · explanation panel open')),
row('02 / Minimum window — 1000 × 700 equivalent',
tile('m02-monitoring-minimum-dark','03  Minimum size, dark','1000 × 640 pt content · native title bar/toolbar allowance: 60 pt'),
tile('m03-monitoring-minimum-light','04  Minimum size, light','Same content size · event list retains space below summary')),
row(None,
tile('m05-monitoring-selected-event-minimum-dark','05  Minimum size with an event selected','Dark · offscreen inspector text is black; native appearance unverified (readable panel: 07)'),
tile('m10-monitoring-minimum-summary-scrolled-light','06  Compact summary scrolled to the chart','Light · real scroll-view position · event list remains visible')),
row('03 / Read the explanations and application controls',
tile('m06-explanation-complete-dark','07  Explanation panel','Dark · actual component, 440 × 1050 pt · all plain-language sections'),
tile('m08-latest-notable-explanation-light','08  Latest notable change','Light · another recorded event and its explanation'),
tile('m09-settings-dark','09  Settings','Dark · actual Settings component · QA actions disabled')),
row('04 / Details and evidence — one expanded panel, three overlapping crops',
dict(file='m07-details-and-evidence-expanded-light.png',title='10A  Explanation and measured changes',note='Light · expanded actual component · top crop, pixels 0–1900',crop=[0,0,1040,1900]),
dict(file='m07-details-and-evidence-expanded-light.png',title='10B  Supporting evidence',note='Same panel continued · pixels 1800–3600 · overlap retains complete lines',crop=[0,1800,1040,1800]),
dict(file='m07-details-and-evidence-expanded-light.png',title='10C  Technical details and copy controls',note='Same panel continued · pixels 3500–4700 · full original supplied',crop=[0,3500,1040,1200]))]
sheets=[dict(title='01  Storage Inventory & Cleanup',subtitle='Discover → expand → visualize → compare → review',output='storage-monitor-collage-1-inventory-cleanup.png',rows=a),dict(title='02  Monitoring & Application Experience',subtitle='Capacity → change → history → explanation → evidence',output='storage-monitor-collage-2-monitoring-experience.png',rows=b)]
# Crop only standalone capture canvases, retaining the complete component content.
# Full application frames, including empty review states and clipping, remain intact.
crops={'i08-living-tree-navigation-help-component.png':[40,230,840,680],
'i14-cleanup-item-full-details-light.png':[0,0,960,1900],
'i16-cleanup-other-item-details-dark.png':[0,0,960,2000],
'm06-explanation-complete-dark.png':[0,0,880,1000],
'm08-latest-notable-explanation-light.png':[0,0,880,1000]}
for sheet in sheets:
    for r in sheet['rows']:
        for t in r['tiles']:
            if t['file'] in crops:
                t['crop']=crops[t['file']]
                t['note']='Component crop · '+t['note']
(base/'layout.json').write_text(json.dumps(sheets,indent=2))
