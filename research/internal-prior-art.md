# Internal LaunchDarkly prior art (via Glean)

## 1. "Universal SDK Configuration File" — Chris Tarquini, Confluence, 2021-11-24
https://launchdarkly.atlassian.net/wiki/spaces/ENG/pages/1979678926
Status: READ ME. Impact L / Effort M. Audience: developers, large enterprise with centralized implementation.

- Problem: standardizing config across multiple SDKs/teams is a burden; hard to integrate with existing config management tooling.
- Solution: common config file format + standard location; each SDK supports auto-config via file OR env vars.
- Proposed starting point: **a subset of the LD Relay config file format** (covers SaaS URIs, event capacity/flush, proxy settings).
- Prior art cited: AWS CLI config files (`~/.aws/config`), MySQL option files.
- Proposed lookup path / precedence:
  1. `$PWD/.config/launchdarkly/client.conf`
  2. `$XDG_CONFIG_HOME/launchdarkly/client.conf`
  3. `$HOME/.config/launchdarkly/client.conf`
  4. `/etc/launchdarkly/client.conf`
- Explicitly rejected: `.htaccess`-style walking up the directory tree (surprising behavior).
- Env vars: same file<->env mapping approach as LD Relay. Notes env vars work for JS SDKs via bundlers.
- Desired outcomes: CS/docs/support can hand out one config; enterprises standardize; ecosystem tools/demos
  stop inventing their own config; `LDClient.init()` with no args becomes the simplest working example;
  easier local dev + IDE integrations (vscode, intellij).
- Next steps listed (still open questions today):
  - what options are in scope
  - choose format + env var mapping
  - **strategy for SDK feature differences (log warning? error? SDK-specific sections/overrides?)**
  - tooling support (syntax highlighting, autocomplete, IDE integration)
  - consider API client credentials: a standardized `LD_API_KEY`

## 2. "SDK Environment Variable Initialization" — Dan Mashuda, Confluence, 2026-04-01
https://launchdarkly.atlassian.net/wiki/spaces/~627a8a7bb249c0006f9591d3/pages/4706893827

- Proposal: first-class env var support in all server-side SDKs, zero code changes.
- Motivation: every LD service manually wires env vars into SDK config; internal wrappers
  (`foundation`/`dogfood2`) do this today but are private. Wants to deprecate those.
- **Naming convention: `LAUNCHDARKLY_` prefix** (aligns with AWS_, DD_).
- Tier 1 — universal across all 8 server SDKs (Go, Java, Python, Node, .NET, Ruby, PHP, Rust):
  - LAUNCHDARKLY_SDK_KEY (required)
  - LAUNCHDARKLY_OFFLINE (false)
  - LAUNCHDARKLY_BASE_URI (https://app.launchdarkly.com)
  - LAUNCHDARKLY_EVENTS_URI (https://events.launchdarkly.com)
  - LAUNCHDARKLY_SEND_EVENTS (true)
  - LAUNCHDARKLY_APPLICATION_ID (unset)
  - LAUNCHDARKLY_APPLICATION_VERSION (unset)
- Tier 2 — 7/8:
  - LAUNCHDARKLY_STREAM_URI (gap: PHP, no streaming)
  - LAUNCHDARKLY_ALL_ATTRIBUTES_PRIVATE (gap: Rust)
  - LAUNCHDARKLY_DIAGNOSTIC_OPT_OUT (gap: PHP, Rust)
- Tier 3 — partial:
  - LAUNCHDARKLY_RELAY_PROXY_URL — sets all three endpoints (Go, Java, .NET, Rust = 4/8)
  - LAUNCHDARKLY_USE_LDD — daemon mode (Go, Python, Node, Ruby, Rust = 5/8)
- Explicitly excluded as code-only: things requiring object composition (data store, hooks, plugins).
- Open questions:
  - Precedence: env vars vs code-set config. Recommendation in doc: **env vars are defaults; code wins**.
  - Scope: server-side first, or include edge/client-side?

## 3. .NET server sandbox — already prototyping LAUNCHDARKLY_* env vars
https://github.com/launchdarkly/dotnet-core/blob/main/sandbox/dotnet-server-sandbox/README.md
Real, working env var scheme worth mining for naming:
- LAUNCHDARKLY_SDK_KEY, LAUNCHDARKLY_OFFLINE, LAUNCHDARKLY_START_WAIT_TIME_MS
- LAUNCHDARKLY_DATA_SYSTEM_MODE = default | streaming | polling | daemon | persistent-store
- LAUNCHDARKLY_PERSISTENT_STORE_TYPE = redis | dynamodb
- LAUNCHDARKLY_REDIS_HOST / _PORT / _PREFIX / _CONNECT_TIMEOUT_MS / _OPERATION_TIMEOUT_MS
- LAUNCHDARKLY_DYNAMODB_TABLE_NAME / _PREFIX
- Validation errors are explicit: "Invalid data system mode", "daemon mode requires a persistent store",
  "LAUNCHDARKLY_DYNAMODB_TABLE_NAME is required". Booleans case-insensitive true/false.
- Notably defers AWS/Redis credentials to the vendor's own env vars (AWS_ACCESS_KEY_ID etc.) — same
  pattern LD Relay uses for DynamoDB.

## 4. FDv2 endpoint handling audit — Ryan Lamb, sdk-scratchpad, 2026-09-10
https://github.com/launchdarkly/sdk-scratchpad/blob/main/research/fdv2-endpoint-handling-audit.md
**Directly relevant structural hazard for the schema.** Findings:
- `DATASYSTEM v2` spec says *nothing* about endpoints, so every SDK differs.
- Go: FDv2 data sources read endpoints ONLY from the data-system config; top-level `ServiceEndpoints`
  is ignored for polling/streaming (events still honored) with NO warning. Relay users need two settings.
- Ruby: `base_uri`/`stream_uri` silently ignored under FDv2 → talks to production LD.
- Python/Ruby/Node/Rust/C++: per-component `base_uri` on each initializer/synchronizer.
- Rust & C++ FDv1-fallback has no per-component setter; mutates top-level endpoints instead.
- js-core: top-level baseUri/streamUri/eventsUri build one ServiceEndpoints which also carries
  `payloadFilterKey`; getPollingUri/getStreamingUri append `filter=`.
- Recommendation in audit: fall back to top-level endpoints, or document loudly.
=> A declarative config spec MUST take a position on top-level endpoints vs per-source endpoints
   and precedence between them.
- FDv2 ("data saving mode") GA 2026-05-15 in .NET 8.11+, Go 7.11+, Java 7.11+ (dataSystem in 9.10 per docs),
  Node 9.10+, Python 9.13+, Ruby 8.12.0+; Relay 9.0.0-rc.1+. No FDv2 data system in:
  .NET client, Erlang, PHP, Haskell, Lua, Roku, new Apple SDK.
- Java migration note: `persistentStore`, `stream`, `streamInitialReconnectDelay`, `pollInterval`, `useLDD`
  moved from top-level LDOptions into `dataSystem` as of 9.10.

## 5. sdk-specs repo conventions (SPEC-specification-for-specs)
https://github.com/launchdarkly/sdk-specs — private; format extracted via Glean.
If we want this spec to land in sdk-specs, it must follow:
- Header markdown table: `| id | version | status | title | description | applies-to |`
  - id: A-Z only, unique, short symbol (e.g. `SDKCONF`)
  - version: semver
  - status: DRAFT | ACCEPTED | DEPRECATED | SUPERSEDED
  - applies-to: client-sdk, server-sdk, relay-proxy
- Layout order: header, Prerequisite Specs, See Also, Glossary, then numbered body.
- Section 1 starts with `## Introduction`.
- Requirements: `### Requirement X.Y.Z` followed by a markdown **quote block**, RFC 2119 keywords in **bold**,
  one keyword per statement. Requirement numbers are immutable once ACCEPTED.
- String literals quoted AND code-formatted: `"like this"`.
- Conditional requirements: `### Condition X.Y.Z` (plain declarative text) + `#### Conditional Requirement X.Y.Z.1`.
  Use this instead of inline "if the SDK supports X" language. **Perfect fit for per-SDK capability gaps.**
- Multi-version specs: `specs/ID-name/v1/README.md`, `v2/...`, plus a top-level index README. Same id across versions.
- Test vectors: optional, in `test-vectors/` next to README.md, with a README documenting schema,
  comparison/equality rules, organization, and a **"Requirements Not Covered"** section.
  Vectors MUST be language-agnostic (abstract operations, per-SDK runner) and each needs a human-readable description.
