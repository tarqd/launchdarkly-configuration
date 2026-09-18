# Design decisions (confirmed with Chris Tarquini)

## Round 1
1. **Format / normative schema**: YAML primary for authoring; **JSON is an exactly-equivalent
   surface** (an SDK whose language has a YAML-library problem may ship JSON-only and remain
   conformant). **JSON Schema draft 2020-12 is the normative artifact.** Optionally author the
   schema in CUE and export JSON Schema. Rejected: TOML (no null -> loses absent/null/value
   tri-state; no PHP 1.0 lib; Erlang tomerl stale), KDL (no Erlang parser, PHP v1 only, no
   mainstream Go v2 -> 3 of 11 SDKs cannot read it), JSON-only-consumed.
   NOTE: serde_yaml (Rust) and gopkg.in/yaml.v3 (Go) are both archived -> call out in the spec.

2. **Layering / precedence**: **OTel model.** When a config file is present, all
   LD_*/LAUNCHDARKLY_* env vars are ignored EXCEPT via `${VAR}` substitution inside the file.
   `parse(file) -> model`, user code MAY mutate the model, then `create(model) -> client`.
   No merge rule. Consequence: Dan Mashuda's flat env-var proposal becomes a legacy layer needing
   a migration template (every value `${VAR:-default}`) plus a list of vars that do not map.

3. **Option surface**: **Full tree** - events, endpoints, HTTP, logging, data system, persistent
   stores, big segments, application info, hooks/plugins by registered name. Per-SDK capability
   gaps expressed with the sdk-specs `Condition` / `Conditional Requirement` pattern, plus a
   machine-readable support matrix with an honest `ignored` status per SDK.

## Round 2
4. **Defaults**: **Spec owns defaults; `parse()` materializes them.** The schema declares one
   canonical default per property; parse fills every absent key from the schema before create.
   SDK-native defaults never apply on the declarative path. No SDK has to change its in-code
   defaults. Consequences to handle in the spec:
   - schema is source of truth for ~80 defaults and must be kept in sync (CI check)
   - a file omitting a key silently overrides that SDK's historical default -> document loudly
   - must pick canonical values for the known spreads (capacity 10000/1000/500,
     flush 5s/10s/30s, polling host app. vs sdk., start wait 5s/10s, store TTL 10s/15s/30s/5min,
     gzip true/false, connect timeout 2s/10s/none)

5. **Data system**: **Full FDv2 tree is the primary shape.** Ordered initializer + synchronizer
   lists are the model. Legacy flat options (`stream`, `poll_interval`, `use_ldd`,
   `persistent_store`) become **deprecated aliases** mapped onto the tree.
   (User chose this over my "named modes" recommendation.) Consequences:
   - PHP, Erlang, Haskell have no FDv2 data system -> must emulate the tree with FDv1 primitives,
     or declare the branch `ignored` in the support matrix
   - Java has distinct Initializer/Synchronizer types, .NET reuses IDataSource -> model **roles**,
     not types
   - FDv2 fallback/recovery timeouts are hardcoded and DIFFERENT per SDK (Go 10s/1min/5min,
     Rust 120s/300s) and exposed by none -> unspecifiable branches; either omit or require new API
   - MUST take a position on top-level endpoints vs per-source endpoints (Go/Ruby currently ignore
     top-level under FDv2 with no warning - Ryan Lamb's audit)
   - FDv1/FDv2 paths must be mutually exclusive, not merged

6. **Durations**: **Integer milliseconds with `_ms`-suffixed keys** (`flush_interval_ms: 5000`).
   Every SDK already has a translator for exactly this shape (contract-test harness:
   `startWaitTimeMs`, `cacheTtlMs`). Consequences:
   - needs an explicit rule for the negative "cache forever" sentinel used by Java/.NET/C++
     (Duration.ofMillis(-1) / Timeout.InfiniteTimeSpan) - prefer an explicit enum over a sign hack
   - unit is baked into the key name, so a future unit change is a rename

## Round 3
7. **Env-var surface**: **Curated legacy layer + `${VAR}` substitution.** A hand-picked,
   additive-only set of flat vars, explicitly documented as NOT a mirror of the schema
   (so the spec never owes an env name for every key). Starting set = Dan Mashuda's tiers:
   LAUNCHDARKLY_SDK_KEY, _OFFLINE, _BASE_URI, _EVENTS_URI, _STREAM_URI, _SEND_EVENTS,
   _APPLICATION_ID, _APPLICATION_VERSION, _RELAY_PROXY_URL, _USE_LDD.
   Plus LAUNCHDARKLY_CONFIG_FILE. The deprecated flat aliases (decision 5) double as the
   env-addressable names. Prefix is `LAUNCHDARKLY_`.

8. **File discovery**: search order
   1. `$LAUNCHDARKLY_CONFIG_FILE` (explicit; must exist or error)
   2. `$XDG_CONFIG_HOME/launchdarkly/`
   3. `$HOME/.config/launchdarkly/`
   4. `/etc/launchdarkly/`
   First match wins. **`$PWD` is NOT on the default search path** - requires explicit opt-in -
   because a working-directory file could otherwise silently redirect endpoints and the event
   stream on CI runners and shared build agents. (Diverges from the 2021 proposal, which listed
   `$PWD/.config/launchdarkly/client.conf` first.)

9. **Strictness** - differs by case:
   - **unknown key** -> **error at parse** (typos are the top config failure mode)
   - **known key unsupported by this SDK** -> **warn once and ignore at create**
     (so one file serves all 11 SDKs; mirrors OTel's unknown-component-name = parse ok, create fails,
     but downgraded to a warning because capability gaps are expected and permanent)
   - **out-of-range value** -> **error at parse**, replacing today's silent clamping
     (clamping is inconsistent in every SDK: Java clamps nothing that .NET clamps; Ruby falls back
     to the default where Python clamps to the minimum; Ruby rejects the boundary value 60)
   Note the parse/create split does real work here: case 1 and 3 are parse-time and
   SDK-independent, so a validator CLI catches them without any SDK present.

## Round 4
10. **Secrets**: `sdk_key` IS a schema property, marked **`sensitive: true`**, with a sibling
    **`sdk_key_file`** that reads the value from a path (Relay's `*_FILE` pattern; what Docker/K8s
    secret mounts actually produce). Docs lead with `${LAUNCHDARKLY_SDK_KEY}`.
    The `sensitive` annotation drives redaction in error messages, diagnostic events, and the
    validator CLI - closing the gap OTel still has open (opentelemetry-configuration#563).
    Relay prior art to mirror: `SDKKey`/`MobileKey`/`AutoConfigKey` types with `Masked()`.

11. **Root shape**: **a single client config at the document root.** No named-clients map.
    Matches every server SDK's API; keeps `${VAR}` substitution and the flat env aliases
    unambiguous; the research explicitly warns against hoisting Relay's multi-environment
    concept into an SDK spec. Multi-client apps and Erlang's `Tag` registry are served by
    loading N files / N models.

12. **SDK scope**: **server-side only.** `applies-to: server-sdk`.
    Schema should avoid server-only assumptions where that is free, so a later client-side spec
    can share `$defs` for endpoints, events, application info, and logging.
    Edge SDKs (Cloudflare/Vercel/Akamai) need an explicit note: they hard-code
    `stream:false, sendEvents:false, useLdd:true, diagnosticOptOut:true` and **throw**
    `Invalid configuration: <keys> not supported` on anything outside a `logger`+`sendEvents`
    whitelist, while their exported TS types advertise the full server surface. That contradicts
    decision 9's warn-and-ignore rule.

## Round 5
13. **Component encoding**: **flat `type` discriminator.**
    `persistent_store: {type: "redis", url: ..., prefix: ...}`; same for initializers,
    synchronizers, hooks, plugins. Rationale: matches the `{type, dsn, prefix}` shape the
    contract-test harness already implements in all 11 SDKs and the
    `LAUNCHDARKLY_PERSISTENT_STORE_TYPE` var the dotnet-core sandbox ships; flat enough to be
    env-addressable; JSON Schema expresses it as `oneOf` on `type` with `additionalProperties`
    left open for third parties.
    Rejected: OTel's single-key object (`{redis: {...}}`, minProperties/maxProperties 1).

14. **Canonical defaults**: **Go is the reference SDK.** Where Go does not have the option,
    fall to **Java**, then **Python**. This replaces the "majority value" rule I proposed -
    it is a precedence chain, not a vote, so every default has one unambiguous source.
    Watch-outs when applying it:
    - Go has TWO conflicting polling-base-URI constants: `internal/endpoints` says
      `https://sdk.launchdarkly.com/` (FDv1) while `ldcomponents.DefaultPollingBaseURI` says
      `https://app.launchdarkly.com` (FDv2). Since the FDv2 tree is the primary shape (decision 5),
      take the FDv2 constant: `app.launchdarkly.com`. Flag the Go inconsistency upstream.
    - Go has no default HTTP connect timeout story that Rust shares (Go 3s, Rust none) - Go wins.
    - Options Go lacks entirely -> Java: `ApplicationName`/`ApplicationVersionName` (Java lacks
      these too, .NET-only -> then Python, which also lacks them; such options get no canonical
      default and are optional-with-no-default).
    - `Config.LDRelayDataDestination` is LD-internal and MUST be excluded from the spec.
    - Go's `EnableGzip` default `false` therefore wins over Rust's `true`.
    - Go event capacity 10000 wins over PHP 1000 / Rust 500.

15. **Reference implementation sequencing**: **schema first.** Land the CUE-authored schema,
    generated JSON Schema, snippet fixtures, and a validator CLI before any loader.
    Then loaders in the order **Go -> Java -> Python** (per decision 14's reference ordering;
    Go and Java exercise the nested-builder shape, Python the flat option bag).
    Node moves to the second wave despite already having a validation layer and a
    ConfigParams translator. FLAGGED TO USER for confirmation, since the option text I
    presented named Node + Go.

## Round 6
16. **Config reload**: **out of scope for v1, but not precluded.** `parse`/`create` are one-shot.
    No normative statement forbidding reload; a non-normative note records that the parse/create
    split leaves room for it. (Reload is still an open unresolved issue in OTel, and all 11 SDKs
    build an immutable config at client construction.)

17. **Hooks / plugins**: **first-party `type` values enumerated in v1** with their data-shaped
    options (observability, tracing). Third-party `type` values parse successfully and warn at
    create (per decision 9). **No open provider registry in v1.**
    CRITICAL CARVE-OUT: the spec does NOT restate or shadow `OTEL_*` environment variables.
    `OTEL_EXPORTER_OTLP_ENDPOINT` already works across all server SDKs per LD docs, and it belongs
    to the OTel SDK, not to us. The "file replaces env" rule (decision 2) MUST be scoped to
    `LAUNCHDARKLY_*`/`LD_*` only - otherwise loading a config file would silently disable a
    customer's OTLP endpoint.

18. **Conformance**: **spec `test-vectors/` + a new sdk-test-harness suite.**
    - `test-vectors/` holds language-agnostic cases: input document -> expected materialized model,
      plus expected parse errors. Must include the sdk-specs-mandated `README.md` documenting
      schema, comparison/equality rules, organization, and a **"Requirements Not Covered"** section.
    - Extend sdk-test-harness so each SDK's contract-test service accepts a declarative document.
      This is a small step: those services ALREADY translate a JSON config block into native
      config (`contract-test-utils/ConfigParams.ts`, `data_model.hpp`, `ts_sdk_config_params.erl`,
      the `SdkClientEntity` translators). That existing code is the de facto prototype.
    - Because unknown-key and out-of-range are parse-time errors (decision 9), the validator CLI
      catches them with no SDK present.

## Round 7
19. **Key case**: **snake_case.** `flush_interval_ms`, `all_attributes_private`, `persistent_store`.
    Matches OTel; native in Python, Ruby, Erlang, PHP (4 of 11 need no transformation); and
    converts to SCREAMING_SNAKE env names mechanically with no acronym-boundary ambiguity
    (camelCase would make `baseURI`/`sdkKey` lossy, forcing a hand-maintained alias table -
    Relay's exact failure mode).

20. **File name**: `launchdarkly.yaml`, `launchdarkly.yml`, then `launchdarkly.json`, tried in that
    order in each directory on the search path. **The extension is normative and selects the
    parser** - no content sniffing. Makes the YAML/JSON equivalence from decision 1 visible in the
    filename and gets editor schema-store association (autocomplete) for free.
    (Supersedes the 2021 proposal's `client.conf`.)

21. **Spec home**: **permanently in this repo**, published alongside the JSON Schema and the
    reference implementations - the direct analogue of OTel's separate
    `opentelemetry-configuration` repo. Still WRITTEN in sdk-specs SPEC format (immutable numbered
    requirements, RFC 2119 bold keywords, Condition/Conditional Requirement for capability gaps,
    test-vectors/ with "Requirements Not Covered") so the squad's conventions and review habits
    apply, and so cross-referencing from sdk-specs works.
    Trade-off accepted: lives outside the squad's spec index.
    Proposed spec id: `SDKCONF`.
