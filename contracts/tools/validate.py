"""Validate engine vectors and fixtures against the JSON schemas. Run: python3 contracts/tools/validate.py"""
import json, os, sys
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
L = lambda p: json.load(open(os.path.join(D, p)))
pb, ei, dl = L("policy-bundle.schema.json"), L("engine-input.schema.json"), L("device-local.schema.json")
reg = Registry().with_resources([(s["$id"], Resource.from_contents(s)) for s in (pb, ei, dl)])
vb, vi, vd = (Draft202012Validator(s, registry=reg) for s in (pb, ei, dl))
bad = 0
for v in L("engine-vectors.json")["vectors"]:
    for e in vi.iter_errors(v["input"]):
        bad += 1; print("vector:", v["name"], "->", e.message)
for f in ["fixtures/policy-bundle.example.json"]:
    for e in vb.iter_errors(L(f)):
        bad += 1; print(f, "->", e.message)
b = L("fixtures/push-silent-inline-bundle.json")["tether"]["bundle"]
for e in vb.iter_errors(b):
    bad += 1; print("push inline bundle ->", e.message)
for e in vd.iter_errors(L("fixtures/device-local.example.json")):
    bad += 1; print("device-local fixture ->", e.message)

# Negative checks: these must be REJECTED.
import copy
ex = L("fixtures/policy-bundle.example.json")
allow_guarded = copy.deepcopy(ex)
allow_guarded["rules"][0].update(action="allow", strictness="guarded")
snap_tokens = L("fixtures/device-local.example.json")
snap_tokens["groups"][0]["appTokens"] = ["opaque"]
for name, validator, doc in [("guarded allow rule", vb, allow_guarded), ("snapshot group with appTokens", vd, snap_tokens)]:
    if validator.is_valid(doc):
        bad += 1; print("negative check not rejected:", name)

print("OK" if not bad else f"{bad} schema errors"); sys.exit(1 if bad else 0)
