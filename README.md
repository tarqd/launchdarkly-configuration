# LaunchDarkly SDK declarative configuration

A specification for configuring LaunchDarkly server-side SDKs from a file and from environment
variables, so that one artifact configures an SDK regardless of its language.

Configuring an SDK today requires code. Every option is reachable only through a builder or an
options object, so an organization standardizing configuration across teams and languages writes
and maintains that code once per language — and the options do not line up. The same concept
carries different names in different SDKs, the same name carries different defaults, and a
platform team cannot point every application at a Relay Proxy without editing every application.

```yaml
# launchdarkly.yaml
file_format: "0.1"
sdk_key: ${LAUNCHDARKLY_SDK_KEY}

service_endpoints:
  relay_proxy: https://relay.internal.example.com

events:
  capacity: 20000
  private_attributes:
    - /email
```

## Layout

| Path | Contents |
|---|---|
| [`spec/`](spec/) | The specification, JSON Schema, test vectors, and design record. |
| [`research/`](research/) | Source-level audit of all eleven server-side SDKs' configuration surfaces, plus the prior art the design draws on. |
| `packages/server-side/<sdk>-configuration/` | Reference implementations. Not yet started; planned in the order Go, Java, Python. |

Start with [`spec/SDKCONF-declarative-configuration/`](spec/SDKCONF-declarative-configuration/)
for the specification itself, or [`spec/DECISIONS.md`](spec/DECISIONS.md) for why it looks the way
it does.

## Design in one page

- **YAML for authoring, JSON as an exactly equivalent surface.** JSON Schema 2020-12 is
  normative, generated from CUE. An SDK whose language lacks a maintained YAML library may accept
  JSON only and stay conformant.
- **Parse and create are separate operations**, with a plain data model in between. This is
  OpenTelemetry's structure, and it is what lets the specification say nothing about merge
  precedence: there is no place for a merge rule to hide.
- **A document replaces `LAUNCHDARKLY_*` environment configuration** rather than merging with it,
  because a flat name cannot address a repeated structure. `OTEL_*` and the conventional proxy
  and AWS variables are explicitly out of scope of that rule.
- **The schema owns every default**, materialized at parse time. The surveyed SDKs disagree about
  the default value of the same option — event capacity is 10,000 in Go, 1,000 in PHP, 500 in
  Rust — so a document that omits a property would otherwise mean something different in every
  language.
- **Go is the reference** for both default values and property names, falling back to Java then
  Python where Go holds an option outside `Config`.
- **Unknown properties and out-of-range values are errors**; properties an SDK cannot honor warn
  once and are ignored. That combination is what lets one document serve all eleven SDKs while
  still catching typos.

## Status

DRAFT. The specification, schema, and conformance vectors exist and are self-consistent; no SDK
implements it yet.
