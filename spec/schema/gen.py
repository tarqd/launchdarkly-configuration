#!/usr/bin/env python3
"""Generate SDKCONF's JSON Schema and canonical defaults document from the CUE source.

CUE is the single source of truth. Its JSON Schema exporter carries types, constraints,
enums, and doc comments across, but not default values or custom keywords, so this script
injects those from the CUE defaults documents afterwards.

Outputs:
  sdkconf.schema.json  JSON Schema 2020-12, normative for validation
  defaults.json        canonical materialized defaults (decision 4)
"""

import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
SCHEMA_OUT = HERE / "sdkconf.schema.json"
DEFAULTS_OUT = HERE / "defaults.json"

SCHEMA_ID = "https://launchdarkly.com/schemas/sdkconf/v0.1/sdkconf.schema.json"

# Which $defs each defaults document supplies values for. The root `defaults` document covers
# the top-level tree; the rest cover types that only appear inside lists or behind a `type`
# discriminator, where a structural default is not expressible.
DEFS_SOURCES = {
    "source_defaults": {"streaming": "StreamingSource", "polling": "PollingSource", "file": "FileSource"},
    "store_defaults": {
        "redis": "RedisDataStore",
        "dynamodb": "DynamoDbDataStore",
        "consul": "ConsulDataStore",
    },
    "big_segment_store_defaults": {"redis": "RedisStore", "dynamodb": "DynamoDbStore"},
    "hook_defaults": {"tracing": "TracingHook"},
}

# Properties with no default: required, or placeholders that exist only so CUE can vet the
# defaults document against the schema.
NO_DEFAULT = {
    ("FileSource", "paths"),
    ("DynamoDbDataStore", "table_name"),
    ("StreamingSource", "type"),
    ("PollingSource", "type"),
    ("FileSource", "type"),
    ("RedisStore", "type"),
    ("RedisDataStore", "type"),
    ("DynamoDbStore", "type"),
    ("DynamoDbDataStore", "type"),
    ("ConsulStore", "type"),
    ("ConsulDataStore", "type"),
    ("TracingHook", "type"),
}


def expand_const_objects(schema):
    """Rewrite whole-object `const` definitions into ordinary closed object schemas.

    CUE collapses a definition whose only field is a required constant — `#InMemoryDataStore`,
    `#ObservabilityPlugin` — into `{"const": {"type": "..."}}`. That validates the same
    documents, but a validator can then only say the whole object was wrong, never which
    property was at fault, which Requirement 1.6.4 asks implementations to do. Expanding it
    restores property-level errors.
    """
    expanded = 0
    for name, node in schema.get("$defs", {}).items():
        const = node.get("const")
        if not isinstance(const, dict) or set(node) != {"const"}:
            continue
        node.clear()
        node.update(
            {
                "type": "object",
                "additionalProperties": False,
                "properties": {k: {"const": v} for k, v in const.items()},
                "required": sorted(const),
            }
        )
        expanded += 1
    return expanded


def cue(*args):
    out = subprocess.run(
        ["cue", *args], cwd=HERE, capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        sys.exit(f"cue {' '.join(args)} failed:\n{out.stderr}")
    return out.stdout


def inject_defaults(node, values, def_name=None):
    """Recursively copy scalar and empty-collection defaults from `values` into `node`."""
    props = node.get("properties")
    if not props or not isinstance(values, dict):
        return
    for key, value in values.items():
        target = props.get(key)
        if target is None:
            continue
        if isinstance(value, dict):
            # Descend through a $ref into the referenced definition.
            inject_defaults(target, value, def_name)
        elif def_name is None or (def_name, key) not in NO_DEFAULT:
            target["default"] = value


def resolve(schema, node):
    """Follow a single $ref, if present."""
    ref = node.get("$ref")
    if not ref:
        return node
    assert ref.startswith("#/$defs/"), ref
    return schema["$defs"][ref[len("#/$defs/"):]]


def inject_nested(schema, node, values):
    """Walk the root defaults document, following $refs into $defs as it goes."""
    props = node.get("properties", {})
    for key, value in values.items():
        target = props.get(key)
        if target is None:
            continue
        target = resolve(schema, target)
        if isinstance(value, dict) and target.get("properties"):
            inject_nested(schema, target, value)
        elif not isinstance(value, dict):
            target["default"] = value


def main():
    schema = json.loads(cue("def", "-o", "-", "--out", "jsonschema", "-e", "#Config", "."))
    defaults = json.loads(cue("export", "-e", "defaults", "."))
    sensitive = json.loads(cue("export", "-e", "sensitive", "."))

    schema["$id"] = SCHEMA_ID
    schema["title"] = "LaunchDarkly server-side SDK declarative configuration (SDKCONF)"

    expanded = expand_const_objects(schema)
    inject_nested(schema, schema, defaults)

    for expr, mapping in DEFS_SOURCES.items():
        doc = json.loads(cue("export", "-e", expr, "."))
        for key, def_name in mapping.items():
            target = schema["$defs"].get(def_name)
            if target is not None:
                inject_defaults(target, doc[key], def_name)

    bs = json.loads(cue("export", "-e", "big_segments_defaults", "."))
    inject_defaults(schema["$defs"]["BigSegments"], bs, "BigSegments")

    # Decision 10: values at these pointers are redacted from logs, errors, and diagnostics.
    for pointer in sensitive:
        node = schema
        for token in pointer.strip("/").split("/"):
            node = resolve(schema, node.get("properties", {}).get(token, {}))
            if not node:
                break
        if node:
            node["x-ld-sensitive"] = True

    SCHEMA_OUT.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
    DEFAULTS_OUT.write_text(json.dumps(defaults, indent=2, sort_keys=True) + "\n")
    print(
        f"wrote {SCHEMA_OUT.name} ({len(schema['$defs'])} defs, "
        f"{expanded} const objects expanded) and {DEFAULTS_OUT.name}"
    )


if __name__ == "__main__":
    main()
