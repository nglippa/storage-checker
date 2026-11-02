import sqlite3, random, sys, collections
OLD="SELECT kind,status,COALESCE(reason,''),COUNT(*) FROM inventory_nodes WHERE generation_id=?1 AND status IN ('unknown','excluded') GROUP BY kind,status,reason"
NEW="WITH RECURSIVE kinds(kind) AS (SELECT (SELECT MIN(kind) FROM inventory_nodes WHERE generation_id=?1) UNION ALL SELECT (SELECT MIN(kind) FROM inventory_nodes WHERE generation_id=?1 AND kind>kinds.kind) FROM kinds WHERE kinds.kind IS NOT NULL) SELECT kind,status,COALESCE(reason,''),COUNT(*) FROM inventory_nodes WHERE generation_id=?1 AND kind IN (SELECT kind FROM kinds WHERE kind IS NOT NULL) AND status IN ('unknown','excluded') GROUP BY kind,status,reason"
SCHEMA="""CREATE TABLE inventory_nodes(id INTEGER PRIMARY KEY, generation_id INTEGER NOT NULL, parent_id INTEGER, name TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, reason TEXT);
CREATE INDEX inventory_nodes_status ON inventory_nodes(generation_id,kind,status);
CREATE INDEX inventory_nodes_kind_id ON inventory_nodes(generation_id,kind,id);"""
KINDS=["directory","file","symlink","other","Directory","dir ectory","","é","0","10","9"]
STATUS=["unknown","excluded","complete","pending","stale","Unknown","excluded ",""]
REASONS=[None,"","consent","privacy","metadata:privacy","permission","io","CONSENT"]
def fold(rows):  # what the app does with the rows
    r=collections.Counter()
    for k,s,re,c in rows:
        if s=="excluded": r["excluded"]+=c
        elif k!="directory": r["unreadable"]+=c
        elif re in("consent","privacy","metadata:privacy"): r["protected"]+=c
        else: r["unavailable"]+=c
    return r
random.seed(int(sys.argv[1]) if len(sys.argv)>1 else 1)
trials=int(sys.argv[2]) if len(sys.argv)>2 else 2000
for t in range(trials):
    db=sqlite3.connect(":memory:"); db.executescript(SCHEMA)
    n=random.choice([0,1,2,5,50,500]); gens=random.randint(1,3)
    kinds=random.sample(KINDS,random.randint(1,len(KINDS)))
    rows=[(g:=random.randint(1,gens), None, f"n{i}", random.choice(kinds), random.choice(STATUS), random.choice(REASONS)) for i in range(n)]
    db.executemany("INSERT INTO inventory_nodes(generation_id,parent_id,name,kind,status,reason) VALUES(?,?,?,?,?,?)",rows)
    if random.random()<.3: db.execute("ANALYZE")
    for g in range(0,gens+2):
        a=sorted(db.execute(OLD,(g,)).fetchall()); b=sorted(db.execute(NEW,(g,)).fetchall())
        if a!=b or fold(a)!=fold(b): print("MISMATCH",t,g,a,b); sys.exit(1)
print("ok",trials,"trials sqlite",sqlite3.sqlite_version)
