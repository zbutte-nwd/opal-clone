import json, copy, sys
from datetime import datetime, timedelta, date
from zoneinfo import ZoneInfo

OUT = sys.argv[1] if len(sys.argv) > 1 else "contracts/engine-vectors.json"
LA = "America/Los_Angeles"

GROUPS = [
  {"id":"grp_social","name":"Social","webDomains":["tiktok.com","instagram.com"],"colorHex":"#FF5A5F","source":"server"},
  {"id":"grp_games","name":"Games","webDomains":[],"source":"server"},
  {"id":"grp_news","name":"News","webDomains":["news.ycombinator.com"],"source":"server"},
]
SETTINGS = {"protectionLock":"partnerPIN","allowLocalRules":True,"denyAppRemoval":True}

def bundle(rules=(), overrides=(), tz=None, settings=None):
    b = {"version":1,"generatedAt":"2026-11-01T00:00:00Z","groups":copy.deepcopy(GROUPS),
         "rules":list(rules),"overrides":list(overrides),"settings":settings or dict(SETTINGS)}
    if tz: b["timeZone"]=tz
    return b

def rule(id, groups, trigger, action="block", strictness="flexible", priority=0, enabled=True, source="server", maxp=None):
    r = {"id":id,"name":id,"groupIds":groups,"enabled":enabled,"action":action,"trigger":trigger,
         "strictness":strictness,"priority":priority,"source":source}
    if maxp is not None: r["maxPausesPerDay"]=maxp
    return r

def sched(*wins): return {"type":"schedule","windows":[{"days":d,"start":s,"end":e} for d,s,e in wins]}
WEEKDAYS=[1,2,3,4,5]
SCHOOL = sched((WEEKDAYS,"08:00","15:00"))

def inp(b=None, localGroups=(), localRules=(), sessions=(), pauses=(), hits=()):
    return {"bundle":b,"localGroups":list(localGroups),"localRules":list(localRules),
            "sessions":list(sessions),"pauses":list(pauses),"usageLimitHits":list(hits)}

def t(s, tz=LA):  # local wall clock -> RFC3339 UTC
    return datetime.fromisoformat(s).replace(tzinfo=ZoneInfo(tz)).astimezone(ZoneInfo("UTC")).strftime("%Y-%m-%dT%H:%M:%SZ")

# Mon 2026-11-09 (PST)
MON="2026-11-09"; TUE="2026-11-10"; SAT="2026-11-14"; SUN="2026-11-08"
assert date.fromisoformat(MON).isoweekday()==1

V=[]
def vec(name, now, input, expect, deviceTz=LA, note=None):
    v={"name":name,"now":now,"deviceTimeZone":deviceTz,"input":input,"expect":expect}
    if note: v["note"]=note
    V.append(v)

def E(**kw):
    """expect only lists non-default groups; all others must be blocked=false reason none"""
    return kw

B=lambda kind,id,strict=False: {"blocked":True,"strict":strict,"reason":{"kind":kind,"id":id}}
U=lambda kind,id: {"blocked":False,"strict":False,"reason":{"kind":kind,"id":id}}

vec("empty input: nothing blocked", t(f"{MON}T09:00"), inp(bundle()), E())
vec("no bundle, no local state", t(f"{MON}T09:00"), inp(None), E())
vec("schedule active on weekday", t(f"{MON}T09:00"), inp(bundle([rule("rule_school",["grp_social","grp_games"],SCHOOL)])),
    E(grp_social=B("rule","rule_school"), grp_games=B("rule","rule_school")))
vec("schedule end is exclusive", t(f"{MON}T15:00"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL)])), E())
vec("schedule start is inclusive", t(f"{MON}T08:00"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL)])), E(grp_social=B("rule","rule_school")))
vec("before schedule start", t(f"{MON}T07:59"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL)])), E())
vec("weekend day not in schedule", t(f"{SAT}T09:00"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL)])), E())
NIGHT_SUN = sched(([7],"22:00","06:00"))
vec("overnight window started previous day is active", t(f"{MON}T05:00"), inp(bundle([rule("rule_night",["grp_games"],NIGHT_SUN)])), E(grp_games=B("rule","rule_night")))
vec("overnight window ends exclusive next morning", t(f"{MON}T06:00"), inp(bundle([rule("rule_night",["grp_games"],NIGHT_SUN)])), E())
vec("overnight window not yet started", t(f"{SUN}T21:59"), inp(bundle([rule("rule_night",["grp_games"],NIGHT_SUN)])), E())
vec("overnight window active before midnight", t(f"{SUN}T23:30"), inp(bundle([rule("rule_night",["grp_games"],NIGHT_SUN)])), E(grp_games=B("rule","rule_night")))
vec("overnight window for Monday is not active early Monday", t(f"{MON}T05:00"), inp(bundle([rule("rule_night",["grp_games"],sched(([1],"22:00","06:00")))])), E(),
    note="days lists the day the window STARTS")
EVE = sched(([1],"20:00","24:00"))
vec("end 24:00 active at 23:59", t(f"{MON}T23:59"), inp(bundle([rule("rule_eve",["grp_news"],EVE)])), E(grp_news=B("rule","rule_eve")))
vec("end 24:00 inactive at next midnight", t(f"{TUE}T00:00"), inp(bundle([rule("rule_eve",["grp_news"],EVE)])), E())
vec("start equals end is never active", t(f"{MON}T09:00"), inp(bundle([rule("rule_bad",["grp_news"],sched(([1],"09:00","09:00")))])), E())
vec("strict rule marks strict", t(f"{MON}T09:00"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL,strictness="strict")])), E(grp_social=B("rule","rule_school",True)))
vec("disabled rule ignored", t(f"{MON}T09:00"), inp(bundle([rule("rule_school",["grp_social"],SCHOOL,enabled=False)])), E())
vec("manual rule active", t(f"{SAT}T12:00"), inp(bundle([rule("rule_hw",["grp_games"],{"type":"manual","active":True})])), E(grp_games=B("rule","rule_hw")))
vec("manual rule inactive", t(f"{SAT}T12:00"), inp(bundle([rule("rule_hw",["grp_games"],{"type":"manual","active":False})])), E())
UL={"type":"usageLimit","dailyMinutes":30,"days":[1,2,3,4,5,6,7]}
vec("usage limit hit today blocks", t(f"{MON}T18:00"), inp(bundle([rule("rule_lim",["grp_social"],UL)]),hits=[{"ruleId":"rule_lim","day":MON}]), E(grp_social=B("rule","rule_lim")))
vec("usage limit hit yesterday does not block", t(f"{MON}T18:00"), inp(bundle([rule("rule_lim",["grp_social"],UL)]),hits=[{"ruleId":"rule_lim","day":SUN}]), E())
vec("usage limit day computed in local tz", t(f"{MON}T23:30"), inp(bundle([rule("rule_lim",["grp_social"],UL)]),hits=[{"ruleId":"rule_lim","day":MON}]), E(grp_social=B("rule","rule_lim")),
    note="23:30 PST is already Tuesday in UTC; the day must be the local day")
vec("usage limit not on listed day", t(f"{SAT}T18:00"), inp(bundle([rule("rule_lim",["grp_social"],{"type":"usageLimit","dailyMinutes":30,"days":WEEKDAYS})]),hits=[{"ruleId":"rule_lim","day":SAT}]), E())
ALLWEEK = sched(([1,2,3,4,5,6,7],"00:00","24:00"))
vec("higher-priority allow beats block", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_all",["grp_social","grp_news"],ALLWEEK), rule("rule_news_ok",["grp_news"],SCHOOL,action="allow",priority=10)])),
    E(grp_social=B("rule","rule_all"), grp_news=U("rule","rule_news_ok")))
vec("equal priority: block beats allow", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_all",["grp_news"],ALLWEEK), rule("rule_news_ok",["grp_news"],SCHOOL,action="allow")])),
    E(grp_news=B("rule","rule_all")))
vec("higher-priority block beats lower allow", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_all",["grp_news"],ALLWEEK,priority=5), rule("rule_news_ok",["grp_news"],SCHOOL,action="allow",priority=1)])),
    E(grp_news=B("rule","rule_all")))
S = lambda id, groups, start, end, strict=False, endedAt=None: {k:v for k,v in {"id":id,"groupIds":groups,"startsAt":start,"endsAt":end,"strict":strict,"endedAt":endedAt}.items() if v is not None or k in()} 
vec("focus session blocks", t(f"{SAT}T10:10"), inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"))]), E(grp_social=B("session","ses_1")))
vec("focus session end exclusive", t(f"{SAT}T10:25"), inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"))]), E())
vec("focus session ended early", t(f"{SAT}T10:10"), inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"),endedAt=t(f"{SAT}T10:05"))]), E())
vec("strict session marks strict", t(f"{SAT}T10:10"), inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"),strict=True)]), E(grp_social=B("session","ses_1",True)))
vec("session reason prefers strict session", t(f"{SAT}T10:10"), inp(bundle(),sessions=[
      S("ses_a",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:20")),
      S("ses_b",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T11:00"),strict=True)]), E(grp_social=B("session","ses_b",True)))
vec("session reason earliest-ending when none strict", t(f"{SAT}T10:10"), inp(bundle(),sessions=[
      S("ses_a",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T11:00")),
      S("ses_b",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:20"))]), E(grp_social=B("session","ses_b")))
vec("session beats allow rule", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_news_ok",["grp_news"],SCHOOL,action="allow",priority=100)]),sessions=[S("ses_1",["grp_news"],t(f"{MON}T08:30"),t(f"{MON}T09:30"))]),
    E(grp_news=B("session","ses_1")))
vec("session + strict rule: reason session, strict from rule", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL,strictness="strict")]),sessions=[S("ses_1",["grp_social"],t(f"{MON}T08:30"),t(f"{MON}T09:30"))]),
    E(grp_social=B("session","ses_1",True)))
P = lambda id, groups, start, end, ruleId=None: {k:v for k,v in {"id":id,"groupIds":groups,"startsAt":start,"endsAt":end,"ruleId":ruleId}.items() if v is not None}
vec("pause lifts flexible rule block", t(f"{MON}T09:02"),
    inp(bundle([rule("rule_school",["grp_social","grp_games"],SCHOOL)]),pauses=[P("pau_1",["grp_social"],t(f"{MON}T09:00"),t(f"{MON}T09:05"),"rule_school")]),
    E(grp_social=U("pause","pau_1"), grp_games=B("rule","rule_school")))
vec("expired pause has no effect", t(f"{MON}T09:05"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL)]),pauses=[P("pau_1",["grp_social"],t(f"{MON}T09:00"),t(f"{MON}T09:05"),"rule_school")]),
    E(grp_social=B("rule","rule_school")))
vec("pause cannot lift strict rule", t(f"{MON}T09:02"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL,strictness="strict")]),pauses=[P("pau_1",["grp_social"],t(f"{MON}T09:00"),t(f"{MON}T09:05"))]),
    E(grp_social=B("rule","rule_school",True)))
vec("pause lifts flexible session", t(f"{SAT}T10:10"),
    inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"))],pauses=[P("pau_1",["grp_social"],t(f"{SAT}T10:09"),t(f"{SAT}T10:14"))]),
    E(grp_social=U("pause","pau_1")))
vec("pause cannot lift strict session", t(f"{SAT}T10:10"),
    inp(bundle(),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"),strict=True)],pauses=[P("pau_1",["grp_social"],t(f"{SAT}T10:09"),t(f"{SAT}T10:14"))]),
    E(grp_social=B("session","ses_1",True)))
vec("pause with nothing to lift reports none", t(f"{SAT}T10:10"),
    inp(bundle(),pauses=[P("pau_1",["grp_social"],t(f"{SAT}T10:09"),t(f"{SAT}T10:14"))]), E())
O = lambda id, groups, action, start, issued, end=None: {k:v for k,v in {"id":id,"groupIds":groups,"action":action,"startsAt":start,"endsAt":end,"issuedAt":issued}.items() if v is not None}
vec("override block with no end", t(f"{SAT}T12:00"), inp(bundle(overrides=[O("ovr_1",["grp_games"],"block",t(f"{SAT}T11:00"),t(f"{SAT}T11:00"))])), E(grp_games=B("override","ovr_1",True)))
vec("override block beats allow rule", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_news_ok",["grp_news"],SCHOOL,action="allow",priority=100)], overrides=[O("ovr_1",["grp_news"],"block",t(f"{MON}T08:00"),t(f"{MON}T08:00"))])),
    E(grp_news=B("override","ovr_1",True)))
vec("override block cannot be paused", t(f"{SAT}T12:00"),
    inp(bundle(overrides=[O("ovr_1",["grp_games"],"block",t(f"{SAT}T11:00"),t(f"{SAT}T11:00"))]),pauses=[P("pau_1",["grp_games"],t(f"{SAT}T11:59"),t(f"{SAT}T12:04"))]),
    E(grp_games=B("override","ovr_1",True)))
vec("override unblock beats strict rule", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL,strictness="strict")], overrides=[O("ovr_1",["grp_social"],"unblock",t(f"{MON}T08:50"),t(f"{MON}T08:50"),t(f"{MON}T09:20"))])),
    E(grp_social=U("override","ovr_1")))
vec("override unblock beats strict session", t(f"{SAT}T10:10"),
    inp(bundle(overrides=[O("ovr_1",["grp_social"],"unblock",t(f"{SAT}T10:05"),t(f"{SAT}T10:05"))]),sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"),strict=True)]),
    E(grp_social=U("override","ovr_1")))
vec("expired timed unblock: block restored offline", t(f"{MON}T09:20"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL)], overrides=[O("ovr_1",["grp_social"],"unblock",t(f"{MON}T08:50"),t(f"{MON}T08:50"),t(f"{MON}T09:20"))])),
    E(grp_social=B("rule","rule_school")))
vec("future override not yet active", t(f"{SAT}T10:00"), inp(bundle(overrides=[O("ovr_1",["grp_games"],"block",t(f"{SAT}T11:00"),t(f"{SAT}T09:00"))])), E())
vec("latest issued override wins", t(f"{SAT}T12:00"),
    inp(bundle(overrides=[O("ovr_b",["grp_games"],"block",t(f"{SAT}T09:00"),t(f"{SAT}T09:00")),
                          O("ovr_a",["grp_games"],"unblock",t(f"{SAT}T11:00"),t(f"{SAT}T11:00"),t(f"{SAT}T13:00"))])),
    E(grp_games=U("override","ovr_a")))
vec("override issuedAt tie broken by larger id", t(f"{SAT}T12:00"),
    inp(bundle(overrides=[O("ovr_a",["grp_games"],"unblock",t(f"{SAT}T11:00"),t(f"{SAT}T11:00")),
                          O("ovr_b",["grp_games"],"block",t(f"{SAT}T11:00"),t(f"{SAT}T11:00"))])),
    E(grp_games=B("override","ovr_b",True)))
LG={"id":"lgrp_yt","name":"YouTube","webDomains":["youtube.com"],"source":"local"}
vec("local group + local rule", t(f"{MON}T09:00"),
    inp(bundle(),localGroups=[LG],localRules=[rule("lrule_1",["lgrp_yt"],SCHOOL,source="local")]),
    E(lgrp_yt=B("rule","lrule_1")))
vec("local rules ignored when allowLocalRules is false", t(f"{MON}T09:00"),
    inp(bundle(settings={"protectionLock":"remoteApproval","allowLocalRules":False,"denyAppRemoval":True}),localGroups=[LG],
        localRules=[rule("lrule_1",["grp_social","lgrp_yt"],SCHOOL,source="local")]),
    E(), note="local groups still appear in output (unblocked); local sessions are still honored")
vec("local session honored even when allowLocalRules is false", t(f"{SAT}T10:10"),
    inp(bundle(settings={"protectionLock":"remoteApproval","allowLocalRules":False,"denyAppRemoval":True}),
        sessions=[S("ses_1",["grp_social"],t(f"{SAT}T10:00"),t(f"{SAT}T10:25"))]),
    E(grp_social=B("session","ses_1")))
vec("rules referencing unknown groups are ignored", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_x",["grp_unknown","grp_news"],SCHOOL)])), E(grp_news=B("rule","rule_x")),
    note="output contains only known groups; grp_unknown must not appear")
vec("bundle timeZone pins evaluation", "2026-11-09T14:00:00Z",
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL)], tz="America/New_York")),
    E(grp_social=B("rule","rule_school")), note="14:00Z = 09:00 New York = 06:00 Los Angeles")
vec("device timeZone used when bundle has none", "2026-11-09T14:00:00Z",
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL)])), E(), note="06:00 Los Angeles")
vec("multiple windows in one rule", t(f"{TUE}T19:30"),
    inp(bundle([rule("rule_multi",["grp_games"],sched((WEEKDAYS,"08:00","15:00"),([2,4],"19:00","21:00")))])),
    E(grp_games=B("rule","rule_multi")))

# DST: 2026-03-08 02:00 PST -> 03:00 PDT (Sunday). Window Sun 01:00-04:00 at 03:30 PDT.
vec("DST spring-forward window still evaluated by wall clock", "2026-03-08T10:30:00Z",
    inp(bundle([rule("rule_dst",["grp_games"],sched(([7],"01:00","04:00")))])), E(grp_games=B("rule","rule_dst")),
    note="10:30Z = 03:30 PDT on Sunday 2026-03-08")


vec("tie among equal-priority block rules: strict first", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_a",["grp_social"],ALLWEEK), rule("rule_b",["grp_social"],SCHOOL,strictness="strict")])),
    E(grp_social=B("rule","rule_b",True)))
vec("tie among equal-priority block rules: smallest id", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_z",["grp_social"],ALLWEEK), rule("rule_m",["grp_social"],SCHOOL)])),
    E(grp_social=B("rule","rule_m")))
vec("tie among equal-priority allow rules: smallest id", t(f"{MON}T09:00"),
    inp(bundle([rule("rule_z",["grp_social"],ALLWEEK,action="allow"), rule("rule_m",["grp_social"],SCHOOL,action="allow")])),
    E(grp_social=U("rule","rule_m")))
vec("multiple pauses: latest-ending pause is the reason", t(f"{MON}T09:02"),
    inp(bundle([rule("rule_school",["grp_social"],SCHOOL)]),pauses=[P("pau_b",["grp_social"],t(f"{MON}T09:00"),t(f"{MON}T09:05")),P("pau_a",["grp_social"],t(f"{MON}T09:01"),t(f"{MON}T09:10"))]),
    E(grp_social=U("pause","pau_a")))

# fill defaults: every known group appears
for v in V:
    b=v["input"]["bundle"]; known=[g["id"] for g in (b["groups"] if b else [])]+[g["id"] for g in v["input"]["localGroups"]]
    exp={}
    for gid in known:
        exp[gid]=v["expect"].get(gid, {"blocked":False,"strict":False,"reason":{"kind":"none","id":None}})
    extra=set(v["expect"])-set(known); assert not extra,(v["name"],extra)
    v["expect"]=exp

doc={"description":"Golden vectors for PolicyEngine.evaluate. See docs/ARCHITECTURE.md §3. Each vector: evaluate input at `now` with device time zone `deviceTimeZone` (bundle.timeZone overrides it). `expect` lists EVERY known group (bundle groups + local groups) with blocked/strict/reason. Implementations in Swift (TetherCore) and TypeScript (server) must pass all vectors.",
     "vectors":V}
json.dump(doc,open(OUT,"w"),indent=2)
print(len(V),"vectors")
