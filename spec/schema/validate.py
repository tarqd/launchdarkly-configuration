#!/usr/bin/env python3
"""Validate a configuration document against SDKCONF's JSON Schema.

The reference validator (Requirement 1.6.1). Reads YAML or JSON, selects the parser by file
extension per Requirement 1.5.4, applies environment variable substitution, and reports each
failure by JSON Pointer per Requirement 1.6.4.

    ./validate.py path/to/launchdarkly.yaml
"""

import json
import sys
from pathlib import Path

import jsonschema

sys.path.insert(0, str(Path(__file__).parent))
from run_vectors_support import pointers_for, substitute  # noqa: E402

SCHEMA = Path(__file__).parent / "sdkconf.schema.json"


def load(path: Path):
    if path.suffix == ".json":
        return json.loads(path.read_text())
    if path.suffix in (".yaml", ".yml"):
        import yaml

        return yaml.safe_load(path.read_text())
    sys.exit(f"{path.name}: unrecognized extension; expected .yaml, .yml, or .json")


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    path = Path(argv[1])
    import os

    doc = substitute(load(path), dict(os.environ))
    schema = json.loads(SCHEMA.read_text())
    errors = sorted(
        jsonschema.Draft202012Validator(schema).iter_errors(doc),
        key=lambda e: list(e.absolute_path),
    )
    if not errors:
        print(f"{path}: valid")
        return 0
    for e in errors:
        for ptr in sorted(pointers_for(e)):
            print(f"{path}:{ptr or '/'}: {e.message}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
