# SDKCONF test vectors

Language-agnostic cases exercising [SDKCONF](../README.md). Each SDK's runner translates the
abstract operations below into its own API; the vectors themselves contain no language syntax.

## Vector schema

Every file is a JSON object with `schema_version` (currently `1`) and a `cases` array. Each case
has a `description`, a `document`, an optional `env` mapping of environment variables to set for
the duration of the case, and an `expect` object in one of three shapes.

| `expect` shape | Meaning |
|---|---|
| `{"valid": true}` | Parse succeeds. The resulting model is not inspected. |
| `{"error": {"kind": ..., "pointer": ...}}` | Parse fails. The error identifies `pointer`, and its classification matches `kind`. |
| `{"model": {"<pointer>": <value>, ...}}` | Parse succeeds, and reading each JSON Pointer from the resulting model yields the given value. |

Error kinds:

| `kind` | Raised when |
|---|---|
| `unknown_property` | A property is absent from the schema (Requirement 1.6.2). |
| `missing_required_property` | A required property is absent. |
| `out_of_range` | A numeric value falls outside the schema's bounds (Requirement 1.6.3). |
| `wrong_type` | A value's type does not match the schema's. |
| `pattern_mismatch` | A string value fails the schema's pattern. |
| `not_in_enum` | A value is outside the schema's enumeration. |

## Comparison rules

- **`kind` is advisory; `pointer` is normative.** A runner **must** assert that parse failed and
  that the reported error names `pointer` (Requirement 1.6.4). Matching `kind` is encouraged but
  not required, because JSON Schema implementations classify the same failure differently — a
  closed object may report an unknown property as either an `additionalProperties` violation or
  a failure of the enclosing subschema.
- **A case expecting an error may produce more than one.** The assertion is that at least one
  reported error names `pointer`, not that exactly one error was reported.
- **Absent and null are distinct.** A property absent from a document takes its schema default;
  a property explicitly set to `null` is a type error unless the schema admits `null`.
- **Model pointers address the materialized model, not the document.** Requirement 1.4.3 means
  every absent property is present in the model, so `/events/capacity` resolves even for a
  document that does not mention it.
- **Lists are ordered.** `/data_system/synchronizers/0` and `/1` are not interchangeable;
  Requirement 1.8.2 gives the order meaning.

## Organization

| File | Covers |
|---|---|
| `valid-documents.json` | Documents that parse, including each deployment shape the specification is meant to express. |
| `parse-errors.json` | Section 1.6. One case per error kind, plus the boundary values the surveyed SDKs handle inconsistently. |
| `default-materialization.json` | Requirement 1.4.3, with a case for each default the surveyed SDKs disagree about. |

## Requirements Not Covered

These requirements are not exercised by vectors. Each is expected to be covered by SDK-local
unit tests or by the contract-test suite instead.

- [1.1.2](../README.md#requirement-112), [1.1.3](../README.md#requirement-113),
  [1.1.4](../README.md#requirement-114), [1.5.4](../README.md#requirement-154) — file format,
  encoding, and extension handling. The vectors carry documents as JSON values, not as bytes on
  disk, so they cannot express which encodings or extensions a parser accepts.
- [1.3.x](../README.md#13-environment-variable-substitution) beyond the one case in
  `valid-documents.json` — substitution is exercised only lightly here. The typing rule in
  1.3.5 and the escape in 1.3.8 warrant their own file once the reference implementation settles
  how substitution interacts with YAML tags.
- [1.4.1](../README.md#requirement-141), [1.4.2](../README.md#requirement-142),
  [1.4.4](../README.md#requirement-144) — API shape. Whether parse and create are separate
  operations, and whether a model can be modified between them, is a property of an SDK's public
  interface rather than of any document.
- [1.4.5](../README.md#requirement-145), [1.4.6](../README.md#requirement-146),
  [1.4.7](../README.md#requirement-147), [1.9.x](../README.md#19-environment-variables) —
  environment variable precedence and the curated variable list. These concern behavior in the
  absence of a document, which a document-driven vector cannot set up.
- [1.5.x](../README.md#15-file-discovery) — discovery depends on filesystem and environment
  state outside a vector's reach.
- [1.6.5](../README.md#requirement-165), [1.6.6](../README.md#requirement-166),
  [1.8.4.1](../README.md#conditional-requirement-1841),
  [1.8.5.1](../README.md#conditional-requirement-1851) — ignored-property warnings and the
  FDv2 capability conditions are per-SDK by construction: the same document must warn in Rust
  and not warn in Go, so no shared vector can assert an outcome.
- [1.7.3](../README.md#requirement-173) — endpoint fallback is observable only in the requests
  an SDK actually issues. This belongs in the contract-test suite, and Ryan Lamb's FDv2 endpoint
  audit recommends exactly that test for each SDK.
- [1.10.1](../README.md#requirement-1101) — redaction of sensitive values is observable in log
  and diagnostic output, not in a parsed model.
- [1.10.2](../README.md#requirement-1102), [1.10.3](../README.md#requirement-1103) — reading
  `sdk_key_file` requires a file on disk. Worth adding once vectors can carry fixture files.
- [1.11.x](../README.md#111-schema-versioning) — `file_format` negotiation and the schema
  evolution rules are properties of the schema's history, checked in CI by comparing releases
  rather than by parsing a document.
- [1.12.x](../README.md#112-conformance) — self-referential.

## Not yet expressible in the schema

Three mutual-exclusion rules are normative in the specification but are not yet encoded in
`sdkconf.schema.json`, so no vector can assert them through schema validation alone:

- Requirement 1.7.6 — `relay_proxy` together with an individual endpoint.
- Requirement 1.8.6 — `data_system` together with a deprecated property it supersedes.
- Requirement 1.10.3 — `sdk_key` together with `sdk_key_file`.

All three are expressible as JSON Schema `not`/`dependentSchemas` constructs. They are tracked as
schema work, not as specification changes.
