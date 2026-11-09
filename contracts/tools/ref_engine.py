import json, sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo
def P(s): return datetime.fromisoformat(s.replace("Z","+00:00"))
def hm(s): h,m=map(int,s.split(":")); return h*60+m
def win_active(w, local):
    # local: aware datetime in tz. check window starting today or yesterday
    s,e=hm(w["start"]),hm(w["end"])
    if s==e: return False
    mins=local.hour*60+local.minute+local.second/60
    dow=local.isoweekday(); prev=7 if dow==1 else dow-1
    if e>s:
        return dow in w["days"] and s<=mins<e
    # overnight
    return (dow in w["days"] and mins>=s) or (prev in w["days"] and mins<e)
def evaluate(inp, now, dtz):
    b=inp.get("bundle"); tz=ZoneInfo((b or {}).get("timeZone") or dtz); local=now.astimezone(tz); day=local.date().isoformat()
    groups=[g["id"] for g in (b["groups"] if b else [])]+[g["id"] for g in inp["localGroups"]]
    allow_local = b["settings"]["allowLocalRules"] if b else True
    rules=[r for r in (b["rules"] if b else [])]+([r for r in inp["localRules"]] if allow_local else [])
    def ractive(r):
        if not r["enabled"]: return False
        tr=r["trigger"]
        if tr["type"]=="schedule": return any(win_active(w,local) for w in tr["windows"])
        if tr["type"]=="manual": return tr["active"]
        if tr["type"]=="usageLimit": return local.isoweekday() in tr["days"] and any(h["ruleId"]==r["id"] and h["day"]==day for h in inp["usageLimitHits"])
    out={}
    for g in groups:
        ovs=[o for o in (b["overrides"] if b else []) if g in o["groupIds"] and P(o["startsAt"])<=now and (o.get("endsAt") is None or now<P(o["endsAt"]))]
        if ovs:
            o=max(ovs,key=lambda o:(P(o["issuedAt"]),o["id"]))
            out[g]={"blocked":o["action"]=="block","strict":o["action"]=="block","reason":{"kind":"override","id":o["id"]}}; continue
        ses=[s for s in inp["sessions"] if g in s["groupIds"] and P(s["startsAt"])<=now<P(s["endsAt"]) and (s.get("endedAt") is None or now<P(s["endedAt"]))]
        ar=[r for r in rules if g in r["groupIds"] and ractive(r)]
        cand=None
        rwin=None
        if ar:
            mp=max(r.get("priority",0) for r in ar); top=[r for r in ar if r.get("priority",0)==mp]
            blocks=[r for r in top if r["action"]=="block"]
            rwin=(sorted(blocks,key=lambda r:(r["strictness"]!="strict",r["id"]))[0] if blocks else sorted(top,key=lambda r:r["id"])[0])
        if ses:
            st=[s for s in ses if s["strict"]]
            sid=(sorted(st,key=lambda s:s["id"])[0] if st else min(ses,key=lambda s:(P(s["endsAt"]),s["id"])))["id"]
            strict=bool(st) or (rwin is not None and rwin["action"]=="block" and rwin["strictness"]=="strict")
            cand={"blocked":True,"strict":strict,"reason":{"kind":"session","id":sid}}
        elif rwin is not None:
            if rwin["action"]=="allow":
                out[g]={"blocked":False,"strict":False,"reason":{"kind":"rule","id":rwin["id"]}}; continue
            cand={"blocked":True,"strict":rwin["strictness"]=="strict","reason":{"kind":"rule","id":rwin["id"]}}
        if cand:
            if not cand["strict"]:
                ps=[p for p in inp["pauses"] if g in p["groupIds"] and P(p["startsAt"])<=now<P(p["endsAt"])]
                if ps:
                    pb=sorted(ps,key=lambda p:(-P(p["endsAt"]).timestamp(),p["id"]))[0]
                    out[g]={"blocked":False,"strict":False,"reason":{"kind":"pause","id":pb["id"]}}; continue
            out[g]=cand; continue
        out[g]={"blocked":False,"strict":False,"reason":{"kind":"none","id":None}}
    return out
d=json.load(open(sys.argv[1])); bad=0
for v in d["vectors"]:
    got=evaluate(v["input"],P(v["now"]),v["deviceTimeZone"])
    if got!=v["expect"]:
        bad+=1; print("FAIL",v["name"]); print(" got ",got); print(" want",v["expect"])
print(len(d["vectors"])-bad,"/",len(d["vectors"]),"pass")
