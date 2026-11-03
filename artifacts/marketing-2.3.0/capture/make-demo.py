"""Build a fictional marketing inventory in a disposable clone. No filesystem scan."""
import sqlite3, json, time, sys, math
db = sqlite3.connect(sys.argv[1])
db.execute('PRAGMA foreign_keys=OFF')
now = int(time.time())
for (name,) in db.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
    if not name.startswith('sqlite_'):
        db.execute('DELETE FROM "' + name + '"')
db.execute("INSERT INTO inventory_generations(id,root_path,root_device,root_inode,root_birth_ns,state,operational_path,created_at,updated_at,active,volume_uuid,event_availability,initial_completion,initial_completed_at) VALUES(1,'/System/Volumes/Data',1,1,1,'complete',?, ?, ?,1,'DEMO-DATA','available','complete',?)", (sys.argv[1].rsplit('/',1)[0],now,now,now))
db.execute('INSERT INTO inventory_stats(generation_id) VALUES(1)')
db.execute("INSERT INTO inventory_change_clock(id,sequence,signals_generation,journal_id,version,created_at) VALUES(1,0,1,'MARKETING-DEMO',1,?)",(now,))
nodes=[]
def folder(name, children): return (name, children)
def file(name, gb): return (name, gb)
tree=folder('',[
 folder('Users',[folder('Studio',[
  folder('Projects',[
   folder('Aurora Website',[folder('assets',[file('brand-film.mov',12.8),file('campaign-photos.zip',6.4),file('product-shots.psd',2.3),file('logo-master.ai',0.04)]),folder('dependencies',[folder('packages',[file('package-archive.tar',2.6),file('documentation.zip',0.3)]),file('lockfile.json',0.003)]),folder('build',[file('production.bundle',1.5),file('source-maps.zip',0.7)]),file('README.md',0.0001)]),
   folder('Mobile App',[folder('Design',[file('interface.sketch',3.2),file('prototype.mov',1.8)]),folder('Builds',[file('release-archive.zip',4.6),file('test-archive.zip',2.1)]),folder('Source',[file('app-source.zip',0.12),file('resources.zip',0.42)])]),
   folder('Client Archive',[file('autumn-campaign.zip',9.6),file('spring-redesign.zip',5.2),file('handoff-assets.zip',2.1)]),
   folder('Research',[file('reference-library.pdf',0.72),file('interviews.wav',1.8),file('notes.md',0.001)])]),
  folder('Movies',[
   folder('Coastline Film',[folder('Camera Originals',[file('coastline-001.mov',24.6),file('coastline-002.mov',18.2),file('coastline-003.mov',14.8)]),folder('Exports',[file('coastline-master.mov',16.4),file('coastline-social.mp4',2.4),file('coastline-preview.mp4',0.8)]),folder('Audio',[file('field-recordings.wav',4.2),file('soundtrack.wav',1.6)])]),
   folder('Tutorials',[file('color-grading.mp4',3.8),file('editing-workflow.mp4',2.2)]),file('showreel-2026.mov',6.8)]),
  folder('Pictures',[folder('Photo Library',[folder('Travel',[file('coastline-raw.zip',22.4),file('mountains-raw.zip',14.8)]),folder('Studio Shoots',[file('portraits-raw.zip',18.6),file('products-raw.zip',9.2)]),folder('Exports',[file('portfolio-jpegs.zip',3.4),file('print-masters.tif',5.6)])]),folder('Design Assets',[file('textures.zip',4.8),file('illustrations.zip',2.1)])]),
  folder('Downloads',[file('macOS-installer.dmg',12.1),file('camera-backup.zip',8.4),file('design-tool.dmg',1.9),file('project-handoff.zip',4.2),file('typefaces.zip',0.18),file('invoice.pdf',0.002)]),
  folder('Documents',[folder('Work',[file('presentations.zip',1.2),file('reports.zip',0.43)]),folder('Personal',[file('documents.zip',0.24)]),file('reading-library.zip',0.68)]),
  folder('Music',[file('sample-library.zip',16.8),file('recordings.wav',4.4)]),
  folder('Library',[folder('Application Support',[folder('Video Editor',[file('media-cache.bin',14.2),file('render-cache.bin',6.8)]),folder('Design Tools',[file('asset-library.bin',7.2)])]),folder('Caches',[file('preview-cache.bin',4.8),file('thumbnail-cache.bin',2.6)])])
 ])]),
 folder('Applications',[file('Video Editor.app',9.8),file('Design Studio.app',5.6),file('Developer Tools.app',12.4),file('Music Studio.app',4.1),file('Photo Editor.app',3.6)]),
 folder('Library',[folder('Audio',[file('sound-library.pkg',8.8)]),folder('Application Support',[file('shared-resources.bin',6.4)])]),
 folder('private',[folder('var',[folder('vm',[file('swapfile0',2.1)]),folder('folders',[file('temporary-assets.bin',3.2)])])])])
def add(item,parent=None,path='/System/Volumes/Data'):
    name,value=item; idx=len(nodes)+1; directory=isinstance(value,list)
    node={'id':idx,'parent':parent,'name':name,'path':path+('/'+name if name else ''),'dir':directory,'children':[],'bytes':0}
    nodes.append(node)
    if directory:
        for child in value: node['children'].append(add(child,idx,node['path']))
        node['bytes']=sum(n['bytes'] for n in node['children'])
    else: node['bytes']=int(value*1_000_000_000)
    node['files']=sum(n['files'] for n in node['children']) if directory else 1
    node['dirs']=sum(n['dirs']+int(n['dir']) for n in node['children'])
    return node
add(tree)
for n in nodes:
    b=n['bytes']; idx=n['id']; kind='directory' if n['dir'] else 'file'
    db.execute('INSERT INTO inventory_objects VALUES(?,?,?,?,?,?,?,?,?,?,?)',(idx,1,idx,1,kind,b,b,1,now,1,idx))
    db.execute("INSERT INTO inventory_nodes(id,generation_id,parent_id,object_id,name,kind,status,direct_logical,direct_allocated,total_logical,total_allocated,child_count,descendant_files,descendant_directories,descendant_entries,measured_at,seen_token) VALUES(?,1,?,?,?,?, 'complete',?,?,?,?,?,?,?,?,?,1)",(idx,n['parent'],idx,n['name'],kind,0 if n['dir'] else b,0 if n['dir'] else b,b,b,len(n['children']),n['files'] if n['dir'] else 0,n['dirs'],n['files']+n['dirs'] if n['dir'] else 0,now))
for i in range(49):
    # One day of recorded observations with an identifiable large import and later cleanup.
    free=162.4-i*.25
    if i>=20: free-=18.2
    if i>=33: free+=29.4
    if i>=42: free-=6.8
    ts=now-(48-i)*1800
    used=1_000_000_000_000-int(free*1e9)
    vols=json.dumps([{'APFSVolumeUUID':'DEMO-DATA','Name':'Data','CapacityInUse':used-18_000_000_000,'Roles':['Data']},{'APFSVolumeUUID':'DEMO-SYSTEM','Name':'System','CapacityInUse':18_000_000_000,'Roles':['System']}])
    db.execute('INSERT INTO readings VALUES(?,?,?,?,?,?)',(i+1,ts,'DEMO-CONTAINER',int(free*1e9),used,vols))
db.execute('DELETE FROM inventory_changed_directories')
db.execute('DELETE FROM inventory_size_signals')
db.commit()
print(json.dumps({'nodes':len(nodes),'allocated':nodes[0]['bytes'],'fixtureRoot':'/private/tmp/Storage Monitor Demo 230','data':'Fictional historical sizes and names; empty disposable placeholders provide real fixture identities.','paths':{n['path'].replace('/System/Volumes/Data','/private/tmp/Storage Monitor Demo 230',1):n['id'] for n in nodes}},indent=2))
