# Summarizes a PerformanceTrace log: per step, time from the change to its first committed frame, to data-ready,
# and main-thread time blocked in passes over 50 ms within 1.5 s of the change. Usage: analyze.py log [log...]
import re,sys,statistics as st,json
def parse(path):
    rows=[l.split(' ',2) for l in open(path).read().splitlines() if l.strip()]
    ev=[(float(t),n,(rest[0] if rest else '')) for t,n,*rest in rows]
    steps=[]
    for i,(t,n,d) in enumerate(ev):
        if n=='script.step' and d.endswith(tuple(['active=true','active=false'])) and ' begin ' in d:
            name=d.split(' ')[0]; first=ready=None; blocked=0; longest=0; loads=[]
            for t2,n2,d2 in ev[i+1:]:
                if n2=='script.step' and ' begin ' in d2: break
                if n2=='frame.committed' and first is None: first=t2-t
                if n2=='script.step' and ' ready +' in d2: ready=float(d2.split('+')[1].rstrip('ms'))
                if n2=='main.stall' and t2-t<=1.5: v=float(d2.split()[0].rstrip('ms')); blocked+=v; longest=max(longest,v)
                if n2 in('inventory.load','livingTree.read','livingTree.layout','explorer.children','explorer.span','history.load') and t2-t<=3: loads.append(f"{n2} {d2.split()[0]}")
            steps.append(dict(name=name,active='active=true' in d,first_frame_ms=None if first is None else first*1000,ready_ms=ready,blocked_ms=blocked,longest_stall_ms=longest,work=loads))
    return steps,ev
for path in sys.argv[1:]:
    steps,ev=parse(path)
    print(f"== {path}")
    launch=[d for t,n,d in ev if n=='script.launchReady']
    print("launch ready:",launch, "| first inventory.load:", next((d for t,n,d in ev if n=='inventory.load'),None))
    names=list(dict.fromkeys(s['name'] for s in steps))
    print(f"{'transition':32} n  first-frame ms (med/min/max)   ready ms (med/min/max)   main blocked ms (med/max)  longest stall")
    for name in names:
        g=[s for s in steps if s['name']==name]
        ff=[s['first_frame_ms'] for s in g if s['first_frame_ms'] is not None]; rd=[s['ready_ms'] for s in g if s['ready_ms'] is not None]
        # the user-visible completion: the later of the first frame and data-ready
        bl=[s['blocked_ms'] for s in g]
        f=lambda xs: f"{st.median(xs):6.0f}/{min(xs):5.0f}/{max(xs):5.0f}" if xs else "   n/a"
        print(f"{name:32} {len(g)}  {f(ff):26} {f(rd):24} {st.median(bl):5.0f}/{max(bl):5.0f}           {max(s['longest_stall_ms'] for s in g):5.0f}   active={sum(s['active'] for s in g)}/{len(g)}")
    json.dump(steps,open(path.replace('.log','.summary.json'),'w'),indent=1)
