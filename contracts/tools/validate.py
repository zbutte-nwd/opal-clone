"""Validate engine vectors and fixtures against the JSON schemas. Run: python3 contracts/tools/validate.py"""
import json, os, sys
from jsonschema import Draft202012Validator
from referencing import Registry, Resource
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
L = lambda p: json.load(open(os.path.join(D, p)))
pb, ei = L("policy-bundle.schema.json"), L("engine-input.schema.json")
reg = Registry().with_resources([(pb["$id"], Resource.from_contents(pb)), (ei["$id"], Resource.from_contents(ei))])
vb, vi = Draft202012Validator(pb, registry=reg), Draft202012Validator(ei, registry=reg)
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
print("OK" if not bad else f"{bad} schema errors"); sys.exit(1 if bad else 0)
