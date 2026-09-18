# OpenTelemetry Declarative Configuration — Prior Art Study

Sources studied (cloned locally):

- `opentelemetry-configuration` @ `0d50980` (2026-09-16) — the JSON Schema repo
- `opentelemetry-specification` @ `specification/configuration/*.md` — `README.md`, `data-model.md`, `sdk.md`, `api.md`, `common.md`, `sdk-environment-variables.md`, `supplementary-guidelines.md`
- opentelemetry.io docs + GitHub issues (see "Pain points")

Status: the **data model and the `ConfigProperties` API are Stable**; `ConfigProvider`, instrumentation config, and some `create` behaviours are still **Development**. `opentelemetry-configuration` itself has shipped `v1.0`, `v1.1.0`, `v1.2.0` (latest 2026-09-11).

---

## 0. The three-interface framing (worth copying verbatim)

`specification/configuration/README.md` splits configuration into three interfaces and states an ordering rule that resolves most arguments before they start:

> The SDK MUST provide a programmatic interface for all configuration. This interface SHOULD be written in the language of the SDK itself. **All other configuration mechanisms SHOULD be built on top of this interface.**

1. **Programmatic** — the ground truth; everything else is a lowering onto it.
2. **Environment variables** — the old flat `OTEL_*` scheme.
3. **Declarative configuration** — data model (+ file representation), an instrumentation-facing read API, and an SDK `parse`/`create` contract.

The key architectural decision: declarative config is *not* a new configuration surface with its own semantics, it is a **serialization of the programmatic builder surface**. That is why `parse` and `create` are separate (see §5).

---

## 1. The file data model

### 1.1 YAML is the file format; JSON Schema is the normative schema

From `data-model.md`:

- The data model is "an abstraction with multiple built-in representations": the **file-based** representation and the **SDK in-memory** representation.
- "Configuration files SHOULD use one the following serialization formats: YAML file format." (Only YAML is currently defined; JSON is implicitly a subset.)
- YAML files "SHOULD follow YAML spec revision >= 1.2" and "SHOULD be parsed using **v1.2 YAML core schema**".
- File extension MUST be `.yaml` or `.yml`.
- The schema is JSON Schema **draft 2020-12** (`"$schema": "https://json-schema.org/draft/2020-12/schema"`).

Rationale from the `opentelemetry-configuration` README:

> JSON schema was chosen in part because of the large ecosystem of tools for things like code generation, validation, IDE integration, etc.

### 1.2 Source-in-YAML, publish-as-one-JSON

The schema **source** lives as ~8 YAML files under `schema/` (`opentelemetry_configuration.yaml`, `common.yaml`, `tracer_provider.yaml`, `meter_provider.yaml`, `logger_provider.yaml`, `propagator.yaml`, `resource.yaml`, `instrumentation.yaml`) and is compiled by `make compile-schema` (a Node script) into a **single** `opentelemetry_configuration.json`.

Two reasons given in `CONTRIBUTING.md`:

- YAML source makes multi-line `description` blocks (which they lean on heavily) writable.
- A single compiled output file "simplifies integration with tooling, as there eliminates the need to resolve external `$ref`s."

They also smuggle **non-JSON-Schema metadata** through the YAML source, which the compile step folds into `description` for codegen tools:

- `isSdkExtensionPlugin: boolean` — marks a plugin/extension point type
- `defaultBehavior: string` — prose describing behaviour when the property is **omitted**; *required on every non-required property*
- `nullBehavior: string` — prose describing behaviour when present but **null**; required on required-and-nullable properties
- `enumDescriptions: map<string,string>` — one entry per enum value, enforced

### 1.3 `$defs`, refs, subschemas

Modelling rules (all machine-enforced by `compile-schema`):

- Every `object`/`enum` type must be a top-level entry in `$defs` or its own schema document. **No inline subschemas.** ("Validate there are no subschemas (i.e. all types are defined at the top level of in `$defs`).")
- `title` is deliberately **omitted**; the `$defs` key *is* the type name, so codegen gets stable class names. (`OpenTelemetryConfiguration` root is the one exception with an explicit `title`.)
- Type names PascalCase matching `^[A-Z][A-Za-z0-9]*$`; property names and enum values lower_snake_case matching `^[A-Za-z_][A-Za-z0-9_]*$` — explicitly "facilitates usage as identifiers in generated code."
- `allOf`/`anyOf`/`oneOf` are discouraged: "JSON schema code generation tools may struggle or not support these keywords… should not be used to extend `object` types." `oneOf` is tolerated only for scalar unions (e.g. attribute `value` being primitive-or-array-of-primitive).
- Every property MUST have a `description` (enforced).
- `additionalProperties: false` by default; `true` only when a component maintainer asks for it (this is how language-specific extras get in).
- Arrays typically get `minItems: 1`, because "properties of type `array` are not candidates for env var substitution" so an empty array is almost always a misconfiguration.
- Pattern matching uses glob wildcards `*`/`?`, **not** regex, and a standard `included`/`excluded` string-array pair when one pattern isn't enough.

### 1.4 Nullability vs requiredness — the single most useful idea here

JSON Schema's `required` and `"type": [..., "null"]` are used for two *different* jobs:

- `"type": ["integer", "null"]` → "the key may be present with no value". Used (a) so a file stays valid when a substituted env var is undefined, and (b) so objects with no properties don't have to be written as `{}`.
- `required` → key must be present; used only "when there is no well-known default semantic".

The canonical example from `CONTRIBUTING.md`:

```yaml
tracer_provider:
  processors:
   - simple:
       exporter:
         console:            # console: type ["object","null"] -> no need to write `console: {}`
  limits:
    attribute_value_length_limit: ${OTEL_SPAN_ATTRIBUTE_VALUE_LENGTH_LIMIT}   # may resolve to null
```

And `parse` is required to preserve the distinction (`sdk.md`):

> Parse MUST differentiate between properties that are missing and properties that are present but null.

```yaml
meter_provider:
  views:
    - selector:
        name: some.metric.name
      stream:
        aggregation:
          drop:        # present-but-null == "use the drop aggregation"
```

This is a real constraint on implementation languages: you need a tri-state (absent / null / value) in your in-memory model.

### 1.5 WYSIWYG philosophy

> The schema semantics should follow a "what you see is what you get" … implementations should minimize the amount of magic that occurs as a result of the absence of an optional property.

If `.meter_provider` is absent you get a **noop** meter provider, not a default OTLP pipeline. They acknowledge the tension (attribute limits default to 128, not "no limit") and the verbosity cost, and explicitly push terseness up a layer:

> A terse user experience can be achieved by leveraging a higher order templating tool like helm…

### 1.6 Versioning: `file_format` + semver on the schema

`file_format` is the only **required** top-level property. It is a *string* holding major.minor (+ optional pre-release tag): `"0.4"`, `"1.0-rc.2"`, `"1.2"`.

`VERSIONING.md` gives a precise compatibility matrix:

| Situation | Implementation behaviour |
|---|---|
| Same MAJOR, file MINOR ≤ impl MINOR | ideal; impl may still not support every property |
| Same MAJOR, file MINOR > impl MINOR | **warn** (file may use unknown properties) |
| Different MAJOR | **error** |

The validator implements exactly this (`validator/shelltests/`):

```
$ otel_config_validator shelltests/unsupported_file_format.yaml
Unsupported file_format "0.4": this validator embeds the schema for version 1.x   # exit 1

$ otel_config_validator shelltests/newer_minor_file_format.yaml
Warning: file_format "1.99" is newer than the schema this validator embeds ("1.2"), ...  # exit 0
```

**Stability guarantees on MINOR bumps** (abridged from `VERSIONING.md`): property names don't change; property `type` doesn't change except adding `null`; no type or property is deleted; validation only ever gets *looser* (enumerated keyword-by-keyword: `minLength` won't increase, `maxLength` won't decrease, `pattern` won't tighten, `required` won't gain entries, `enum` won't lose stable values, `additionalProperties` won't go `true`→`false`, `uniqueItems` won't go `false`→`true`, …). Allowed: new properties, new types, looser validation, removing from `required`, editing `description`/`defaultBehavior`/`nullBehavior`/`enumDescriptions` "as long as the updated semantics do not break users", adding/removing `deprecated`.

Note the explicit escape valve, important if you plan codegen:

> **NOTE**: There is _no_ guarantee that the output of off-the-shelf code generation tools will be stable when allowed changes are made.

**Deprecation instead of deletion**: set `deprecated: true`, put a bold `**Deprecated** as of v1.2.0, may be removed in v2.0.0` notice in `description` with the reason and a link, add a CHANGELOG entry. Nothing is deleted before a MAJOR.

### 1.7 Two carve-outs from the versioning policy

1. **Experimental features** — properties/enum values suffixed `/development`, `/alpha`, `/beta` (e.g. `instrumentation/development`, `detection/development`), types prefixed `Experimental*` (`ExperimentalInstrumentation`). Exempt from all guarantees; breakable in MINOR.
2. **Extension points** — any type with `additionalProperties: true`. "The versioning policy guarantees surrounding properties not explicitly defined in this repository are out of scope."

---

## 2. Environment variable substitution

Defined normatively in ABNF in `data-model.md`:

```abnf
SUBSTITUTION-REF = "${" [PREFIX ":"] GENERIC-SUBSTITUTION "}"
ENV-SUBSTITUTION = ENV-NAME [":-" DEFAULT-VALUE]
PREFIX   = ALPHA *(ALPHA / DIGIT / "_")
ENV-NAME = (ALPHA / "_") *(ALPHA / DIGIT / "_")
DEFAULT-VALUE = *(VCHAR-WSP-NO-RBRACE)
VCHAR-WSP-NO-RBRACE = %x21-7C / "~" / WSP   ; printable + whitespace, except }
```

Non-normative PCRE2 equivalent they publish for convenience:

```regexp
\$\{(?:(?<PREFIX>[a-zA-Z][a-zA-Z0-9_]*):)?(?<GENERIC_SUBSTITUTION>[^}]+)\}
(?<ENV_NAME>[a-zA-Z_][a-zA-Z0-9_]*)(:-(?<DEFAULT_VALUE>[^\n]*))?
```

### 2.1 Where it's allowed

- **Scalar values only.** "Environment variable substitution MUST only apply to scalar values. **Mapping keys are not candidates for substitution.**" (`${STRING_VALUE}: value` is left literally alone.)
- Not in arrays-as-a-whole — hence `minItems: 1` and hence the `*_list` alternative properties (§2.5).
- Multiple refs per scalar and refs embedded in surrounding text are fine: `endpoint: ${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4318}/v1/traces`.

### 2.2 Typing rules — substitute first, then let YAML tag it

> Node types MUST be interpreted **after** environment variable substitution takes place. This ensures the environment string representation of boolean, integer, or floating point properties can be properly converted to expected types.

So typing is *delegated to the YAML core schema*, and quoting is the user's type-coercion lever:

| Input | Post-substitution | Resolved tag |
|---|---|---|
| `key: ${BOOL_VALUE}` (`"true"`) | `key: true` | `bool` |
| `key: "${BOOL_VALUE}"` | `key: "true"` | `str` |
| `key: ${INT_VALUE}` (`"1"`) | `key: 1` | `int` |
| `key: ${HEX_VALUE}` (`"0xdeadbeef"`) | `key: 0xdeadbeef` | `int` **3735928559** |
| `key: ${UNDEFINED_KEY}` | `key:` | **null** |
| `key: ${UNDEFINED_KEY:-fallback}` | `key: fallback` | `str` |
| `key: foo ${STRING_VALUE} ${FLOAT_VALUE}` | `key: foo value 1.1` | `str` |

The hex case is a real, tested behaviour (`validator/shelltests/hex_integer.test` asserts `0xdeadbeef` → `3735928559`). This is a **footgun inherited from YAML** rather than a designed feature — a string env var can silently become a giant integer. Note also `string_for_int.test`: a quoted `"1"` where an integer is expected is a *validation error*, not a coercion:

```
jsonschema: '/attribute_limits/attribute_value_length_limit' does not validate ...: expected integer or null, but got string
```

### 2.3 Undefined / empty / defaults

- `:-DEFAULT` fires if the env var is "null, empty, or undefined".
- No default and undefined → replaced with **empty string**, which YAML then resolves to `null` — which is why so many scalar properties are typed `["integer","null"]`.

### 2.4 Escaping and anti-injection rules

- `$$` → literal `$`. Parsers consume left-to-right, finding the next escape, and match only the span since the previous escape. The spec walks the pseudocode for `$${FOO} ${BAR} $${BAZ}` → `${FOO} b ${BAZ}`.
- **No structure injection**: "It MUST NOT be possible to inject YAML structures by environment variables." `INVALID_MAP_VALUE="value\nkey:value"` stays a single string.
- **No recursive substitution**: neither env-var-value-containing-`${...}` (`REPLACE_ME='${DO_NOT_REPLACE_ME}'` stays literal) nor default values containing `${...}` (`${UNDEFINED_KEY:-${STRING_VALUE}}` → the literal string `${STRING_VALUE}`).
- **Malformed refs are fatal, not ignored**: `${STRING_VALUE:?error}` → parse error. "the parser must return an **empty result (no partial results are allowed)** and an error describing the parse failure." This was a deliberate future-proofing move (spec issue [#3981](https://github.com/open-telemetry/opentelemetry-specification/issues/3981)): reserve the whole `${...}` space by erroring now, so new syntax later isn't a breaking change.
- `PREFIX` is an extension seam: absent or `env` means env vars; languages MAY add their own (Java `${sys:otel.service.name}` for system properties) and SHOULD document them. The validator has an `env_prefix` shelltest.

### 2.5 Interaction with the legacy flat `OTEL_*` vars

The flat env scheme and the structured file scheme are bridged **only** by substitution, and only where types line up. `CONTRIBUTING.md`:

> Properties should be modeled using the most appropriate data structures and types… This may result in a schema that doesn't support env var substitution for the standard env vars where a type mismatch occurs.

Their fix is deliberate, narrow duplication — a `*_list` sibling property whose format matches the legacy env var:

```yaml
resource:
  attributes:                              # the "good" model
    - name: service.name
      value: ${OTEL_SERVICE_NAME:-unknown_service}
  attributes_list: ${OTEL_RESOURCE_ATTRIBUTES}   # legacy comma-separated k=v format
propagator:
  composite_list: ${OTEL_PROPAGATORS:-tracecontext,baggage}
```

> Alternative properties are reserved for cases where there is a demonstrated need for platforms to be able to participate in configuration and there is no reasonable alternative.

Related: name/value pairs are modelled as **arrays of `{name, value}` objects**, not maps, for two stated reasons — user input never becomes a key (keeps the snake_case rule), and *both* name and value become substitution targets:

```yaml
headers:
  - name: ${AUTHORIZATION_HEADER_NAME:-api-key}
    value: ${AUTHORIZATION_HEADER_VALUE}
```

They ship `examples/otel-sdk-migration-config.yaml` as a ready-made bridge: a full config whose every value is a `${OTEL_...:-default}` reference, with a header comment listing the ~14 legacy vars that **cannot** be expressed (`OTEL_TRACES_EXPORTER`, `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_TRACES_SAMPLER`/`_ARG`, `OTEL_LOG_LEVEL`, the Zipkin/Prometheus endpoint vars, …) because they don't map onto the hierarchy.

---

## 3. Precedence: declarative config *replaces* env-var config

`sdk-environment-variables.md`, §Declarative configuration:

> `OTEL_CONFIG_FILE` — The path of the configuration file used to configure the SDK. If set, the configuration in this file takes precedence over all other SDK configuration environment variables.
>
> When `OTEL_CONFIG_FILE` is set, **all other environment variables besides those referenced in the configuration file for environment variable substitution MUST be ignored.** Ignoring the environment variables is necessary because **there is no intuitive way to merge the flat environment variable scheme with the structured file configuration scheme in all cases**.

(`OTEL_EXPERIMENTAL_CONFIG_FILE` is the deprecated predecessor name.)

### The reasoning, from the record

Spec issue [#3752](https://github.com/open-telemetry/opentelemetry-specification/issues/3752) "Should file configuration merge environment variable configuration?" ran to **126 comments** before the TC decided (2024-03-28) **not** to merge.

- *For merging* (tedsuo, trask): users expect env vars to override files, especially in restricted environments; high-level knobs like `OTEL_SDK_DISABLED`, `OTEL_SERVICE_NAME`, `OTEL_LOG_LEVEL` feel like they should always work.
- *Against* (MrAlias, and the winning argument): the flat scheme is **not addressable** against a tree. `OTEL_BSP_SCHEDULE_DELAY` — which of N batch processors? `OTEL_TRACES_SAMPLER` — does it replace a whole `parent_based` tree? Any answer is a "severe and subjective choice", and the env scheme was already stabilized with divergent implementations.
- Conditions attached to the decision: rename to `OTEL_EXPERIMENTAL_CONFIG_FILE` while semantics settled; deprecate non-interoperable env vars when file config stabilizes; solve "platform-contributed configuration" separately (that became the `*_list` properties + the migration template).

`supplementary-guidelines.md` adds the retrospective framing, which is the most transferable sentence in the whole corpus:

> With the environment variable configuration interface, the spec **failed to answer the question of whether programmatic or environment variable configuration took precedence**. This led to differences in implementations that were ultimately stabilized and difficult to resolve after the fact. With declarative config, we don't have ambiguity around configuration interface precedence.

The trick that removes the ambiguity is *structural*: because the API is `parse(file) -> model` and `create(model) -> components`, there is nowhere for a precedence rule to hide. Merging, if you want it, is **your** code operating on the in-memory model between the two calls — and the spec shows exactly that:

```java
OpenTelemetryConfiguration local  = parse(new File("/app/sdk-config.yaml"));
OpenTelemetryConfiguration remote = parse(getRemoteConfiguration("http://example-host/config/my-app"));
OpenTelemetryConfiguration resolved = merge(local, remote);   // YOUR logic
openTelemetry = create(resolved);
```

Programmatic config is likewise unambiguous: it is applied *after* `create`, so it wins.

---

## 4. Plugin / extension component model

### 4.1 The schema shape

Every extension point is modelled identically (enforced by tooling via `isSdkExtensionPlugin: true`):

```json
"SpanExporter": {
  "type": "object",
  "additionalProperties": { "type": ["object", "null"] },
  "minProperties": 1,
  "maxProperties": 1,
  "properties": {
    "otlp_http": { "$ref": "common.json#/$defs/OtlpHttpExporter" },
    "console":   { ... }
  }
}
```

Read that carefully — it's a clever, compact encoding:

- exactly one key (`minProperties: 1, maxProperties: 1`) → "pick one exporter"
- the key **is the component name**
- known built-ins are enumerated in `properties` with full schemas (so they validate and generate code)
- **anything else is accepted** with value `object|null` → third-party components

```yaml
# built-in
exporter:
  otlp_http:
    endpoint: http://example/v1/traces
---
# third party
exporter:
  my_custom_exporter:
    property: value
```

Extension points currently defined (`sdk.md` table): resource detector, text map propagator, span exporter, span processor, sampler, ID generator, pull metric reader, push metric exporter, metric producer, log record exporter, log record processor. (Exemplar reservoir is a known gap: [config#189](https://github.com/open-telemetry/opentelemetry-configuration/issues/189).)

There is also a top-level `distribution` object (`additionalProperties: {type: object}`, `minProperties: 1`) as "a standardized location for distribution-specific settings that are not part of the OpenTelemetry configuration model" — a named sandbox for vendors.

### 4.2 Registration and resolution: `PluginComponentProvider`

- A `PluginComponentProvider` is registered with a **`(type, name)` pair**; `(type, name)` is a unique key and double-registration MUST error.
- `type` should be idiomatic (class literal, enum…); `name` is the YAML key.
- Registration MAY be automatic — Java uses the JDK **service provider interface (SPI)**.
- It has exactly one operation, **Create Component(`properties: ConfigProperties`) -> component**.
- A provider "SHOULD document its configuration schema and include examples" and SHOULD error on missing/mistyped required properties. Note: third-party component config is **not** validated by the published JSON Schema — validation is delegated to the provider at create time.

### 4.3 Unknown component handling — split across parse and create

This split is the subtle, good bit:

- **`parse`** does *not* fail on an unknown component name. "When encountering a reference to a SDK extension component which is not built-in to the SDK, Parse MUST resolve corresponding configuration to a generic `ConfigProperties` representation." So a file referencing `my_custom_exporter` parses fine on any SDK.
- **`create`** is where it fails: "If no `PluginComponentProvider` is registered with the `type` and `name`, Create SHOULD return an error."

`ConfigProperties` (Stable, in `api.md`) is the schemaless bag: accessors for scalars (string, bool, double, int64), nested mappings (as `ConfigProperties`), sequences of scalars, sequences of mappings, the key set, type-safe access where idiomatic, and — again — the ability to distinguish **present-but-null from absent**.

### 4.4 The `/development` namespacing

Experimental *properties* carry a `/(development|alpha|beta)` suffix; experimental *types* an `Experimental` prefix. Everything nested under a suffixed property is exempt from the versioning policy. Stabilization = renaming (`max_export_batch_size/development` → `max_export_batch_size`, a documented BREAKING-but-allowed change in the current CHANGELOG).

This is **actively regretted** — see §7.

---

## 5. The SDK-facing API

Three operations, specified as **stateless pure functions** deliberately not attached to any class ("SDKs may organize them in whatever manner is idiomatic"):

**`parse(file[, file_format]) -> Configuration`**
- may take a path, a language file object, or a stream; format either a parameter, inferred from extension, or via `parseYaml(file)`-style overloads — "If `parse` accepts `file_format`, the API SHOULD be structured so a user is obligated to provide it."
- MUST perform env var substitution
- MUST preserve absent-vs-null
- MUST lower unknown components to `ConfigProperties`
- SHOULD error if the file is missing/invalid or **fails schema validation**, "including enforcing all constraints encoded into the schema"

**`create(Configuration) -> (TracerProvider, MeterProvider, LoggerProvider, Propagators, Resource, ConfigProvider)`**
- returned as a tuple or a wrapper object
- present-but-null → use `nullBehavior`, else `defaultBehavior`; required-and-absent → error
- SHOULD also error on violations expressed only in prose `description` (their example: `HttpTls.ca_file` must be an absolute path per its description — a validator can't check that, so `create` must)
- fail fast, per the general error-handling principles
- **Development**: MAY accept a callback invoked with each constructed sub-component, so users can reach things the data model can't express (Java's OTLP `ExecutorService` is the cited case)

**`register(plugin_component_provider, type, name)`** — may be automatic/SPI.

**In-memory configuration model**: SHOULD exist, SHOULD mirror the schema (unlike schemaless `ConfigProperties`), idiomatic per language, and if a class is needed the recommended name is `Configuration`.

**Consumption path**: `OTEL_CONFIG_FILE=/app/sdk-config.yaml` → the autoconfigure/bootstrap layer notices it, calls `parse` then `create`, and the app just does `AutoConfiguredOpenTelemetrySdk.initialize()`.

### Conformance / test data approach

There is no single cross-language conformance suite. Instead there are four layered artifacts:

1. **`examples/`** — 3 starter templates (`otel-getting-started.yaml`, `otel-sdk-config.yaml`, `otel-sdk-migration-config.yaml`), validated in CI by `make validate-examples` → `npx envsub` (substitution) then `ajv-cli validate --spec=draft2020`.
2. **`snippets/`** (~29 files) — per-type fixtures named `<JsonSchemaType>_<snake_case_description>.yaml`, e.g. `OtlpHttpMetricExporter_use_base2_exponential_histogram.yaml`. Each is a whole valid config, but contains a `# SNIPPET_START` marker; the content after the marker (with the marker's indentation stripped) is validated **against the named type**. Explicitly dual-purpose: documentation *and* "a library of valid configuration files which implementations can use in testing."
3. **`validator/`** — a Go CLI, `otel_config_validator`, that embeds the schema, performs env var substitution, validates, and can emit canonical JSON or YAML (`-o out.json`). Shipped as a Docker image and as `cargo-dist`-built binaries for 5 platforms. Its behavioural tests are `shelltestrunner` fixtures (`validator/shelltests/*.test`) asserting exact stdout/stderr/exit codes — this is where the substitution and `file_format` edge cases are pinned down.
4. **`schema/meta_schema_language_{cpp,go,java,js,php,python}.yaml`** — a machine-checked **per-language support matrix**:

```yaml
latestSupportedFileFormat: 1.0.0-rc.1
typeSupportStatuses:
  - type: Base2ExponentialBucketHistogramAggregation
    status: supported          # unknown | supported | not_implemented | not_applicable | ignored
    propertyOverrides:
      - property: record_min_max
        status: ignored
```

`make fix-language-implementations` adds/deletes entries to match the schema and stubs new ones with `TODO`; CI fails on a dirty tree. Output is rendered into `language-support-status.md`. Note the honesty this buys: as of now `latestSupportedFileFormat` is `1.0.0` for Go/Python/C++ but `1.0.0-rc.2`/`1.0.0-rc.3` for PHP/Java/JS — i.e. **no implementation is on 1.2**, and `ignored` is a first-class status.

### Code generation from the JSON Schema

- **Go** — `go.opentelemetry.io/contrib/otelconf` generates `generated_config.go` with [`atombender/go-jsonschema`](https://github.com/atombender/go-jsonschema). API: `otelconf.ParseYAML()` → model, `otelconf.NewSDK(...)`.
- **Java** — originally `jsonschema2pojo`; **replaced with a hand-rolled POJO generator** in opentelemetry-java 1.65.0 (PR #8600). A strong signal: off-the-shelf JSON-Schema codegen was not good enough for a schema this shape, even though the schema was written to accommodate codegen (no `allOf` inheritance, identifier-safe names, `$defs`-only types, no `title`).
- Docs/markdown generation from the schema is also home-grown Node (`scripts/generate-markdown.js`), now feeding opentelemetry.io's type explorer.

---

## 6. Things that can't be expressed as data

Three escape hatches, in descending order of blessing:

1. **Named plugin components** (§4) — the intended answer. A custom sampler/exporter/processor is a `(type, name)` registration plus an arbitrary properties bag.
2. **`additionalProperties: true` / `distribution`** — language- or vendor-specific knobs that the OTel schema doesn't model. Only granted "when requested by an OpenTelemetry component maintainer".
3. **Programmatic customization callback on `create`** (Development) — reach in and tweak each component as it is built (thread pools, dynamic auth).

And an explicit norm against over-using #3, from `supplementary-guidelines.md`:

> While `create` does provide an optional mechanism for programmatic customization, **its use should be considered a code smell, to be addressed by improving the declarative config data model.** For example, the fact that configuration of dynamic authentication for OTLP exporters is not possible to express with declarative config should not encourage the OpenTelemetry community to have better programmatic customization. Instead, we should pursue adding authentication as an SDK plugin component and modeling in declarative config.

Also relevant: the scope rule "Only properties that are described in opentelemetry-specification or semantic-conventions are modeled in the schema."

---

## 7. Known pain points and open questions

Specific, with issue numbers.

**a) `/development` suffix conflates identity with stability — [config#689](https://github.com/open-telemetry/opentelemetry-configuration/issues/689) (open).**
Two concrete harms: (i) stabilizing forces a *rename* (`detection/development` → `detection`), breaking every downstream reference; (ii) `/` is not an identifier character, so every code generator invents its own mangling (`detection_development`), and they have already shipped a real bug from it — Python's generated field names didn't match the YAML keys. Proposed fixes: publish separate stable/development schema files, or add a `stability` annotation alongside `deprecated` and keep names fixed. **This is the single clearest "don't copy this" in the corpus.**

**b) Secrets / sensitive values are unmodelled — [config#563](https://github.com/open-telemetry/opentelemetry-configuration/issues/563) (open).**
There is no way to mark `headers[].value`, TLS key paths, or auth material as sensitive, so anything that marshals the config back out (the Collector's `otelconf` path, config-dump/diagnostic endpoints) risks leaking credentials. Suggested direction: an OpenAPI-style `format` hint meaning "obscure this value". Current workaround — manual redaction — is "fairly tedious" and goes stale with schema changes. Note there is also **no secret-file indirection** (`*_FILE`) and no secret-manager integration anywhere in the model; `${ENV}` is the only mechanism, which pushes secrets into the process environment.

**c) Merging multiple files is explicitly out of scope.** The spec says "Users that require merging multiple sources of configuration are encouraged to customize the configuration model returned by `Parse` before `Create` is called," i.e. *write your own merge*. No merge semantics (list append vs replace, null-means-delete, etc.) are defined; "Implementations MAY provide a mechanism". Earlier alternative proposals including merges ([spec#3920](https://github.com/open-telemetry/opentelemetry-specification/issues/3920)) were closed.

**d) Hot reload: requested and declined.** [spec#3771](https://github.com/open-telemetry/opentelemetry-specification/issues/3771) asked for reloadable config (ConfigMap updates; `disabled` and sampler ratio at minimum). Closed **as not planned / stale**, tracked under "Declarative Configuration Stability" as *not blocking stability*. Remote/dynamic config is being pushed toward OpAMP instead ([config#544](https://github.com/open-telemetry/opentelemetry-configuration/issues/544), open).

**e) Arrays and env substitution don't mix.** Substitution is scalar-only, so an array-valued setting cannot be driven by one env var. Consequences visible throughout: `minItems: 1`, the duplicated `*_list` string properties (`attributes_list`, `composite_list`, `headers_list`), and the array-of-`{name,value}` modelling for maps. A platform can only participate in array-shaped config where a `*_list` twin was explicitly added.

**f) Verbosity / no presets — [config#334](https://github.com/open-telemetry/opentelemetry-configuration/issues/334) (open).**
WYSIWYG + no defaults means long files. Users want `presets` ("default"/"all"/"stable") and `enabled`/`disabled` lists for detectors, propagators and instrumentations (the golangci-lint / .NET auto-instrumentation model). The counter-argument in-thread is that presets are "magic" that drifts across versions. Unresolved.

**g) Schema packaging — [config#422](https://github.com/open-telemetry/opentelemetry-configuration/issues/422) (open).** Request to publish tiered self-contained schemas (core / OTel / complete-with-third-party) so vendors can build their own extension sets, rather than one monolithic file.

**h) Boundary/ownership questions still open**: where non-instrumentation technology-specific config lives ([#335](https://github.com/open-telemetry/opentelemetry-configuration/issues/335)); ownership/conflict semantics between technology-specific config and `instrumentation/development` ([#545](https://github.com/open-telemetry/opentelemetry-configuration/issues/545)); distribution-specific config ([spec#4770](https://github.com/open-telemetry/opentelemetry-specification/issues/4770)); whether to use JSON Schema's `default` annotation at all rather than their prose `defaultBehavior` ([#399](https://github.com/open-telemetry/opentelemetry-configuration/issues/399)).

**i) YAML's own footguns are a documented hazard.** `supplementary-guidelines.md` has a whole "Strict YAML parsing" section: authors are urged to stay inside the 1.2 core schema's minimal type system, because of (i) YAML 1.1-style coercion (`NO` → `false`), (ii) arbitrary code execution via language-specific tags (`!!python/object`, `!ruby/object`), (iii) anchors/aliases in untrusted input. Advice: use the library's safe mode (`yaml.safe_load`, Psych safe mode). Plus the hex-integer surprise in §2.2.

**j) Implementation lag is real.** Per `language-support-status.md`, the newest `file_format` any SDK claims is `1.0.0`, while the schema is at `1.2.0`; `ignored` and `not_implemented` are common (e.g. C++ `CardinalityLimits`: `ignored` on every property).

---

## 8. Checklist of transferable decisions

**Copy:**
- Programmatic API is normative; file format is a serialization of it.
- `parse` / `create` split, with no merge semantics in between — it *structurally* eliminates precedence ambiguity, and lets merging be user code.
- File config replaces env config; `${ENV:-default}` substitution is the only bridge; ship a migration template whose every value is a substitution ref, with an explicit list of env vars that don't map.
- Required `file_format` string, semver, MINOR-newer→warn / MAJOR-mismatch→error.
- An explicit, keyword-by-keyword schema-evolution policy, plus deprecate-never-delete.
- `defaultBehavior` / `nullBehavior` prose on every optional property; enforce their presence in CI.
- Absent vs present-but-null distinction, preserved by `parse`.
- Identifier-safe names, `$defs`-only types, no `allOf` inheritance, no inline subschemas — all for codegen.
- The one-key-object extension-point encoding (`minProperties/maxProperties: 1` + open `additionalProperties`), with `(type, name)` provider registration; unknown names survive `parse`, fail at `create`.
- Arrays of `{name, value}` instead of maps, so both halves can be substituted and keys stay controlled.
- Snippet fixtures doubling as docs and as a cross-language test corpus; a shipped standalone validator CLI; a machine-enforced per-language support matrix with an honest `ignored` status.
- "Programmatic escape hatch use is a code smell" as a written norm.

**Avoid:**
- Encoding stability in the property **name** (`foo/development`). Use a `stability` annotation and/or split schema documents.
- Assuming off-the-shelf JSON-Schema codegen will carry you (Java abandoned `jsonschema2pojo`; the versioning policy disclaims codegen stability).
- Leaving secrets entirely to `${ENV}` with no sensitivity marking and no file indirection.
- Deferring merge and reload to "user code" if you actually expect Kubernetes-style layering — you will be asked for it (#3752 at 126 comments, #3771).
- Letting YAML's type resolution define your typing rules without guardrails (hex→int, `NO`→bool, tags, anchors).
- Rigid WYSIWYG without a terseness story; they punt to Helm, which is not available to an SDK user.
