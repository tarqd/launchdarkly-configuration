| id | version | status | title | description | applies-to |
|---------|---------|--------|-------------------------------------|-----------------------------------------------------------------------------|------------|
| SDKCONF | 0.1.0 | DRAFT | Declarative SDK configuration | How server-side SDKs are configured from a file and from environment variables. | server-sdk |

***Prerequisite Specs:***

| Link | Version | Requirement |
|---|---|---|
| [DATASYSTEM](https://github.com/launchdarkly/sdk-specs/blob/main/specs/DATASYSTEM-data-system/v2/README.md) | v2 | All |

***See Also:***

| Link | Description |
|---|---|
| [`spec/DECISIONS.md`](../DECISIONS.md) | The 22 design decisions this specification implements, with rationale and consequences. |
| [`spec/NAMING.md`](../NAMING.md) | Derivation of every property name from the Go SDK's public API. |
| [`spec/schema/`](../schema/) | The CUE source and the generated JSON Schema and defaults documents. |
| [`research/`](../../research/) | Source-level audit of all eleven server-side SDKs' configuration surfaces. |
| [OpenTelemetry declarative configuration](https://opentelemetry.io/docs/specs/otel/configuration/) | The primary inspiration for this specification's structure. |

# Glossary

**Configuration document** — a single YAML or JSON document describing the configuration of one
SDK client.

**Configuration model** — the in-memory representation produced by parsing a configuration
document, with all default values materialized. The model is data; it holds no SDK components.

**Parse** — the operation that reads a configuration document and produces a configuration
model. Parse performs no I/O beyond reading the document and the files it references, and
constructs no SDK components.

**Create** — the operation that consumes a configuration model and produces a configured SDK
client. Create is where components are instantiated and where capability differences between
SDKs become observable.

**Property** — a named value in a configuration document, identified by a JSON Pointer such as
`/events/capacity`.

**Ignored property** — a property an SDK recognizes but cannot honor, because the SDK does not
implement the underlying capability.

**Sensitive property** — a property whose value must not appear in logs, error messages, or
diagnostic events.

# 1. Declarative SDK configuration

## Introduction

Configuring a LaunchDarkly SDK today requires code. Every option is reachable only through a
builder or an options object, so an organization standardizing SDK configuration across teams
and languages has to write and maintain that code once per language — and the options do not
line up. The same concept carries different names in different SDKs, the same name carries
different defaults, and there is no way for a platform team to point every application at a
Relay Proxy without editing every application.

This specification defines a configuration document that any server-side SDK can read, so that
one artifact configures an SDK regardless of its language. It is deliberately modelled on
OpenTelemetry's declarative configuration, including the structural decision that makes that
design work: parsing a document and creating a client are separate operations, with a plain data
model in between. That separation is what allows this specification to say nothing at all about
merge precedence — there is no place for a merge rule to hide.

Two facts from the survey of existing SDKs shape what follows. First, no server-side SDK reads
any LaunchDarkly-namespaced environment variable or loads any configuration file today, so this
specification is not constrained by an installed base. Second, every SDK already contains a
working translator from a declarative JSON configuration block into its own native
configuration, written for the contract-test harness. This specification describes what those
translators should have been.

## 1.1 Document format

### Requirement 1.1.1

> A configuration document **MUST** be a single YAML 1.2 or JSON document.

### Requirement 1.1.2

> An SDK **MUST** accept JSON configuration documents.

### Requirement 1.1.3

> An SDK **SHOULD** accept YAML configuration documents.

YAML is the authoring format, but a maintained YAML library is not universally available: Rust's
`serde_yaml` and Go's `gopkg.in/yaml.v3` are both archived. An SDK whose language has no
suitable YAML library remains conformant by accepting JSON only, and reports that in its support
matrix.

### Requirement 1.1.4

> A configuration document **MUST** be encoded as UTF-8.

### Requirement 1.1.5

> The root of a configuration document **MUST** be a mapping describing exactly one SDK client.

A document describes one client. An application that holds several clients loads several
documents, or several models.

### Requirement 1.1.6

> A configuration document **MUST** contain the property `"file_format"`.

### Requirement 1.1.7

> The value of `"file_format"` **MUST** be a string of the form `"MAJOR.MINOR"`.

## 1.2 Property names and value conventions

### Requirement 1.2.1

> Property names **MUST** be `"snake_case"`.

### Requirement 1.2.2

> A property holding a duration **MUST** be named with the suffix `"_ms"`.

### Requirement 1.2.3

> A property holding a duration **MUST** be an integer number of milliseconds.

Integer milliseconds with the unit in the property name is what every SDK's contract-test
translator already consumes, so no SDK needs a duration parser. The alternative encodings each
cost more than they return: unit-suffixed strings need a normative grammar and a hand-written
parser in eleven languages; bare seconds put the unit in prose rather than in the name, which
OpenTelemetry records as a recurring source of confusion.

### Requirement 1.2.4

> A duration property **MUST NOT** use a negative value as a sentinel.

Java, .NET, and C++ each encode "cache forever" internally as a negative duration. A schema that
admitted that encoding could not also constrain durations to be non-negative, and a reader
cannot tell a sentinel from a mistake. Where a duration has modes, the modes are a separate
enumerated property — see `/data_system/data_store/cache/mode`.

### Requirement 1.2.5

> A pluggable component **MUST** be encoded as a mapping containing a `"type"` property naming
> the component.

### Requirement 1.2.6

> The value of a `"type"` property **MUST** be `"snake_case"`.

## 1.3 Environment variable substitution

### Requirement 1.3.1

> An SDK **MUST** support environment variable substitution in configuration documents.

### Requirement 1.3.2

> The syntax `"${VAR}"` **MUST** be replaced with the value of the environment variable `VAR`.

### Requirement 1.3.3

> The syntax `"${VAR:-default}"` **MUST** be replaced with the value of the environment variable
> `VAR`, or with `default` when `VAR` is unset or empty.

### Requirement 1.3.4

> Substitution **MUST** occur before the document is validated.

### Requirement 1.3.5

> When a substituted value occupies an entire scalar node, the substituted value **MUST** be
> typed according to the schema type of the property it occupies.

An environment variable is always a string. `capacity: ${LD_CAPACITY}` with `LD_CAPACITY=5000`
yields the integer `5000`, because `/events/capacity` is an integer property. A substituted value
that cannot be converted to the property's type is a validation error, as any other ill-typed
value would be.

### Requirement 1.3.6

> A substituted value **MUST NOT** itself be subject to further substitution.

### Requirement 1.3.7

> Referencing an unset environment variable without a default **MUST** be a validation error
> when the property is required, and **MUST** leave the property absent otherwise.

### Requirement 1.3.8

> The syntax `"$${"` **MUST** produce the literal characters `"${"`.

## 1.4 Configuration sources and precedence

### Requirement 1.4.1

> An SDK **MUST** expose parsing a configuration document and creating a client from a
> configuration model as two separate operations.

### Requirement 1.4.2

> Parse **MUST NOT** construct SDK components.

### Requirement 1.4.3

> Parse **MUST** produce a model in which every absent property holds its default value as
> defined by this specification's schema.

Defaults are the schema's, not the SDK's. The surveyed SDKs disagree about the default value of
the same option — event capacity is 10,000 in Go, 1,000 in PHP, and 500 in Rust — so a document
that omitted a property would otherwise mean something different in every language. Materializing
schema defaults at parse time makes one document mean one thing without requiring any SDK to
change the defaults of its own code path.

### Requirement 1.4.4

> An SDK **SHOULD** allow an application to modify a configuration model between parse and
> create.

This is the escape hatch for everything a document cannot express. A hook instance, a custom
logger, or a connection pool is attached to the model in code, after parse, without needing a
merge rule.

### Requirement 1.4.5

> When a configuration document is in use, an SDK **MUST NOT** read configuration from any
> `LAUNCHDARKLY_`-prefixed or `LD_`-prefixed environment variable, except through the
> substitution defined in section 1.3.

A flat environment variable scheme and a structured document cannot be merged predictably,
because a flat name cannot address a repeated structure — there is no way for one variable to
say which of several synchronizers it means. OpenTelemetry reached the same conclusion after
extended debate, and recorded that its earlier failure to settle precedence between programmatic
and environment configuration became difficult to resolve once shipped.

### Requirement 1.4.6

> Requirement 1.4.5 **MUST NOT** be applied to environment variables outside the
> `LAUNCHDARKLY_` and `LD_` prefixes.

`OTEL_EXPORTER_OTLP_ENDPOINT` and its siblings configure the OpenTelemetry SDK, not this one,
and they already work with every LaunchDarkly server-side SDK. Loading a LaunchDarkly
configuration document must not silently disable a customer's telemetry pipeline. The same
applies to the conventional proxy variables and to the AWS credential chain that DynamoDB store
integrations rely on.

### Requirement 1.4.7

> In the absence of a configuration document, an SDK **MAY** read configuration from the
> environment variables listed in section 1.9.

## 1.5 File discovery

### Requirement 1.5.1

> An SDK **MUST** accept an explicit configuration document path from the application.

### Requirement 1.5.2

> When no path is supplied by the application, an SDK **MUST** search the following directories
> in order, and **MUST** use the first document it finds:
>
> 1. the path named by the environment variable `LAUNCHDARKLY_CONFIG_FILE`
> 2. `$XDG_CONFIG_HOME/launchdarkly/`
> 3. `$HOME/.config/launchdarkly/`
> 4. `/etc/launchdarkly/`

### Requirement 1.5.3

> Within a searched directory, an SDK **MUST** try the file names `launchdarkly.yaml`,
> `launchdarkly.yml`, and `launchdarkly.json`, in that order.

### Requirement 1.5.4

> An SDK **MUST** select a parser by file extension.

No content sniffing. A `.json` extension means JSON and a `.yaml` extension means YAML, which
also lets editors and schema registries associate the document with its schema and offer
completion.

### Requirement 1.5.5

> When `LAUNCHDARKLY_CONFIG_FILE` names a path that does not exist, an SDK **MUST** report an
> error rather than continuing the search.

An operator who named a file expects that file. Silently falling through to a different
configuration is the failure mode this requirement exists to prevent.

### Requirement 1.5.6

> An SDK **MUST NOT** include the current working directory in the default search path.

A configuration document controls the endpoints an SDK connects to and the destination of its
analytics events. On a CI runner, a shared build agent, or any process whose working directory
is writable by another party, a working-directory entry in the search path is a redirection
vector. An application that wants project-local configuration passes the path explicitly, per
Requirement 1.5.1.

### Requirement 1.5.7

> When no configuration document is found, an SDK **MUST** proceed without one rather than
> reporting an error.

## 1.6 Validation

### Requirement 1.6.1

> An SDK **MUST** validate a configuration document against this specification's JSON Schema
> during parse.

### Requirement 1.6.2

> A property not present in the schema **MUST** be reported as an error during parse.

A misspelled property is the most common configuration failure, and silently dropping it is how
the divergences catalogued in `research/` went unnoticed for years. The schema closes every
object for this reason.

### Requirement 1.6.3

> A value outside the range the schema permits **MUST** be reported as an error during parse.

Every surveyed SDK silently coerces out-of-range values, and no two agree on how. Java clamps
nothing that .NET clamps; Ruby substitutes the default where Python clamps to the minimum, and
rejects the boundary value it documents as valid. Silent coercion means an operator cannot tell
from the document what the SDK will do.

### Requirement 1.6.4

> An error reported during parse **MUST** identify the offending property by JSON Pointer.

### Requirement 1.6.5

> Parse **MUST NOT** report an error for a property the SDK does not implement.

### Requirement 1.6.6

> Create **MUST** log a warning, at most once per property, for each property present in the
> model that the SDK does not implement.

Requirements 1.6.5 and 1.6.6 are what let one document serve all eleven SDKs. Capability gaps are
real and permanent — Rust has no logging configuration, PHP has no streaming — so an unsupported
property cannot be fatal. It must not be silent either.

### Requirement 1.6.7

> Create **MUST NOT** apply a partially valid component configuration.

## 1.7 Endpoints

### Requirement 1.7.1

> The endpoints in `/service_endpoints` **MUST** apply to every data source that does not
> specify its own.

### Requirement 1.7.2

> A data source that specifies its own endpoint **MUST** use it in preference to
> `/service_endpoints`.

### Requirement 1.7.3

> A data source **MUST NOT** fall back to a built-in default endpoint while an applicable
> endpoint is present in `/service_endpoints` or `/data_system/endpoints`.

This is the one requirement that fixes a live defect rather than describing intended behavior. In
the Go SDK, FDv2 data sources read only their own base URI and never consult
`Config.ServiceEndpoints`, so a Relay Proxy user who sets the endpoints and enables the FDv2 data
system polls and streams from production LaunchDarkly with no warning; events still go to the
Relay. Ruby behaves the same way. Under this requirement, a document that names a Relay Proxy
reaches the Relay Proxy.

### Requirement 1.7.4

> Specifying some but not all of `"streaming"`, `"polling"`, and `"events"` in
> `/service_endpoints` **MUST** be an error, unless
> `/service_endpoints/allow_partial_specification` is `true`.

### Requirement 1.7.5

> `/service_endpoints/relay_proxy` **MUST** set the streaming, polling, and events endpoints to
> the value given.

### Requirement 1.7.6

> Specifying both `/service_endpoints/relay_proxy` and any of `"streaming"`, `"polling"`, or
> `"events"` **MUST** be an error.

## 1.8 Data system

### Requirement 1.8.1

> `/data_system/initializers` **MUST** be an ordered list, applied in the order given.

### Requirement 1.8.2

> `/data_system/synchronizers` **MUST** be an ordered list, in which the first entry is the
> primary synchronizer and each subsequent entry is a fallback, as defined by DATASYSTEM v2.

### Requirement 1.8.3

> A configuration document **MUST** describe data sources by role rather than by type.

Java models initializers and synchronizers as distinct types while .NET uses one interface for
both. A document says where a source appears — in `initializers` or in `synchronizers` — and each
SDK maps that onto whatever its own API requires.

### Condition 1.8.4

The SDK implements the FDv2 data system defined by DATASYSTEM v2.

#### Conditional Requirement 1.8.4.1

> The SDK **MUST** honor `/data_system`.

### Condition 1.8.5

The SDK does not implement the FDv2 data system.

#### Conditional Requirement 1.8.5.1

> The SDK **MUST** either express `/data_system` using its own data source primitives, or report
> `/data_system` as ignored.

PHP, Erlang, and Haskell have no FDv2 data system. A polling synchronizer and a persistent store
have direct FDv1 equivalents; an ordered synchronizer list with fallback does not.

### Requirement 1.8.6

> A configuration document **MUST NOT** contain both `/data_system` and any of the deprecated
> properties it supersedes.

In Go, Java, .NET, and Node, configuring the data system causes the older top-level options to be
ignored — silently. Making the two mutually exclusive turns that into a parse error.

## 1.9 Environment variables

An SDK reads these only in the absence of a configuration document, per Requirement 1.4.7. This
list is curated and additive; it is deliberately not a mirror of the schema, because a flat name
cannot address a repeated structure.

### Requirement 1.9.1

> An SDK **MUST** support the following environment variables:
>
> | Variable | Property |
> |---|---|
> | `LAUNCHDARKLY_SDK_KEY` | `/sdk_key` |
> | `LAUNCHDARKLY_OFFLINE` | `/offline` |
> | `LAUNCHDARKLY_SEND_EVENTS` | `/events/enabled` |
> | `LAUNCHDARKLY_APPLICATION_ID` | `/application_info/id` |
> | `LAUNCHDARKLY_APPLICATION_VERSION` | `/application_info/version` |
> | `LAUNCHDARKLY_STREAM_URI` | `/service_endpoints/streaming` |
> | `LAUNCHDARKLY_POLLING_URI` | `/service_endpoints/polling` |
> | `LAUNCHDARKLY_EVENTS_URI` | `/service_endpoints/events` |
> | `LAUNCHDARKLY_RELAY_PROXY_URL` | `/service_endpoints/relay_proxy` |
> | `LAUNCHDARKLY_ALL_ATTRIBUTES_PRIVATE` | `/events/all_attributes_private` |
> | `LAUNCHDARKLY_DIAGNOSTIC_OPT_OUT` | `/diagnostic_opt_out` |

### Requirement 1.9.2

> A boolean environment variable **MUST** accept `"true"` and `"false"`, case-insensitively.

### Requirement 1.9.3

> A boolean environment variable **MUST NOT** treat any other value as `true`.

### Requirement 1.9.4

> An SDK **MUST NOT** define additional `LAUNCHDARKLY_`-prefixed or `LD_`-prefixed configuration
> variables beyond those in Requirement 1.9.1.

Relay Proxy maintains two hand-written vocabularies, one for its file format and one for its
environment variables, and they have drifted: `sendEvents` against `USE_EVENTS`, `localTtl`
against `CACHE_TTL`, options that exist in one source and not the other. Freezing this list
prevents a second vocabulary from growing.

## 1.10 Sensitive values

### Requirement 1.10.1

> A property annotated `"x-ld-sensitive"` in the schema **MUST NOT** have its value written to
> logs, error messages, or diagnostic events.

### Requirement 1.10.2

> `/sdk_key_file` **MUST** be read as a file whose entire contents, with leading and trailing
> whitespace removed, are the SDK key.

This is Relay Proxy's `*_FILE` convention, and it is the shape a Docker or Kubernetes secret
mount actually produces.

### Requirement 1.10.3

> Specifying both `/sdk_key` and `/sdk_key_file` **MUST** be an error.

### Requirement 1.10.4

> An SDK **MUST NOT** require a credential to appear literally in a configuration document.

## 1.11 Schema versioning

### Requirement 1.11.1

> When the MAJOR component of `"file_format"` differs from the version the SDK implements, parse
> **MUST** report an error.

### Requirement 1.11.2

> When the MINOR component of `"file_format"` is greater than the version the SDK implements,
> parse **MUST** log a warning and continue.

### Requirement 1.11.3

> A property **MUST NOT** be removed from the schema within a MAJOR version.

### Requirement 1.11.4

> A property **MUST NOT** change its type within a MAJOR version.

### Requirement 1.11.5

> A default value **MUST NOT** change within a MAJOR version.

Because parse materializes schema defaults, a changed default silently changes the behavior of
every document that omits the property.

### Requirement 1.11.6

> A property whose stability differs from the document's **MUST** be annotated in the schema
> rather than named differently.

OpenTelemetry encodes stability into property names — `detection/development` — and regrets it:
stabilizing a property forces a rename, the separator is not an identifier character, and every
code generator invents its own mangling for it.

## 1.12 Conformance

### Requirement 1.12.1

> An SDK **MUST** publish which properties it implements, which it ignores, and which file
> formats it accepts.

### Requirement 1.12.2

> An SDK's contract-test service **MUST** accept a configuration document.

### Requirement 1.12.3

> An SDK **MUST** pass the test vectors in [`test-vectors/`](test-vectors/).
