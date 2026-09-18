#!/usr/bin/env python3
"""Run the SDKCONF test vectors against the generated JSON Schema and defaults document.

This is the reference runner: it exercises everything a vector can assert without an SDK
present — schema validation and default materialization. Requirements that need a real client
are listed under "Requirements Not Covered" in the vectors' README.
"""

import json
import os
import sys
from pathlib import Path

import jsonschema

HERE = Path(__file__).parent
VECTORS = HERE.parent / "SDKCONF-declarative-configuration" / "test-vectors"

from run_vectors_support import SUBST, pointers_for, substitute  # noqa: F401

def materialize(defaults, doc):
    """Requirement 1.4.3: every absent property takes its schema default."""
    if not isinstance(defaults, dict) or not isinstance(doc, dict):
        return doc
    out = dict(defaults)
    for k, v in doc.items():
        out[k] = materialize(defaults.get(k), v) if isinstance(v, dict) else v
    return out


def pointer(doc, ptr):
    node = doc
    for tok in ptr.strip("/").split("/"):
        tok = tok.replace("~1", "/").replace("~0", "~")
        node = node[int(tok)] if isinstance(node, list) else node[tok]
    return node


def run():
    schema = json.loads((HERE / "sdkconf.schema.json").read_text())
    defaults = json.loads((HERE / "defaults.json").read_text())
    validator = jsonschema.Draft202012Validator(schema)
    passed = failed = 0

    for path in sorted(VECTORS.glob("*.json")):
        data = json.loads(path.read_text())
        for case in data["cases"]:
            desc = case["description"]
            env = {**os.environ, **case.get("env", {})}
            doc = substitute(case["document"], env)
            errors = list(validator.iter_errors(doc))
            expect = case["expect"]
            ok, detail = True, ""

            if "error" in expect:
                want = "/" + "/".join(str(p) for p in ()) if False else expect["error"]["pointer"]
                got = set()
                for e in errors:
                    got |= pointers_for(e)
                if not errors:
                    ok, detail = False, "expected a parse error, got none"
                elif want not in got:
                    ok, detail = False, f"expected error at {want}, got {sorted(got)}"
            elif "model" in expect:
                if errors:
                    ok, detail = False, f"unexpected error: {errors[0].message[:120]}"
                else:
                    model = materialize(defaults, doc)
                    for ptr, want in expect["model"].items():
                        try:
                            got = pointer(model, ptr)
                        except (KeyError, IndexError, TypeError):
                            ok, detail = False, f"{ptr} absent from model"
                            break
                        if got != want:
                            ok, detail = False, f"{ptr}: expected {want!r}, got {got!r}"
                            break
            else:
                if errors:
                    ok, detail = False, f"unexpected error: {errors[0].message[:120]}"

            if ok:
                passed += 1
            else:
                failed += 1
                print(f"FAIL {path.name}: {desc}\n     {detail}")

    print(f"\n{passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(run())
