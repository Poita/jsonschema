#!/usr/bin/env python3
"""Generate the large-instance valid/invalid datasets deterministically.

Run from the repo root: python3 bench/workloads/large-instance/gen.py
The output is committed so cross-language runs share identical bytes; only
re-run when changing the record count or shape.
"""
import json
import os

N = 5000
ROLES = ["admin", "editor", "viewer", "guest"]
HERE = os.path.dirname(os.path.abspath(__file__))


def record(i: int, valid: bool) -> dict:
    r = {
        "id": i,
        "name": f"user-{i:05d}",
        "active": (i % 2 == 0),
        "balance": round((i * 7.0) % 1000 - 250, 2),
        "roles": [ROLES[i % 4], ROLES[(i + 1) % 4]] if i % 3 else [ROLES[i % 4]],
    }
    # Seed a single deep violation so invalid validation still traverses far.
    if not valid and i == N - 1:
        r["active"] = "no"          # boolean expected
        r["roles"] = ["root"]       # not in enum
        r["unexpected"] = True      # additionalProperties:false
    return r


def write(name: str, valid: bool):
    doc = {
        "generatedAt": "2026-06-13T00:00:00Z",
        "records": [record(i, valid) for i in range(N)],
    }
    path = os.path.join(HERE, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(doc, f)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


if __name__ == "__main__":
    write("valid/dataset.json", valid=True)
    write("invalid/dataset.json", valid=False)
