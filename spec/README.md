# Specification

| File | What it is |
|---|---|
| [`SDKCONF-declarative-configuration/`](SDKCONF-declarative-configuration/) | The specification, in `sdk-specs` SPEC format. Status DRAFT. |
| [`SDKCONF-declarative-configuration/test-vectors/`](SDKCONF-declarative-configuration/test-vectors/) | Language-agnostic conformance vectors, plus the requirements they deliberately do not cover. |
| [`schema/`](schema/) | CUE source, generated JSON Schema, canonical defaults, validator CLI, vector runner. |
| [`examples/`](examples/) | Illustrative configuration documents. Non-normative. |
| [`DECISIONS.md`](DECISIONS.md) | The 23 design decisions the specification implements, with rationale, consequences, and implementation notes. |
| [`NAMING.md`](NAMING.md) | Derivation of every property name from the Go SDK's public API. |

## Working on the schema

`spec/schema/sdkconf.cue` and `spec/schema/defaults.cue` are the only hand-edited files.
`sdkconf.schema.json` and `defaults.json` are generated.

```
cd spec/schema
make          # vet, regenerate, run vectors, validate the example
make check    # CI: fail if the generated artifacts are stale, then verify
```

Requires the [CUE](https://cuelang.org) CLI and Python with `jsonschema` and `PyYAML`.

Validate a document:

```
spec/schema/validate.py path/to/launchdarkly.yaml
```
