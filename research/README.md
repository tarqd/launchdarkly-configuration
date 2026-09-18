# Research

Source-level audits of every LaunchDarkly server-side SDK's configuration surface, plus the
prior art the specification draws on. Produced by reading the SDK sources directly (not the
docs — several reports note where published documentation contradicts the code).

Each SDK report enumerates every configurable option with its exact name, grouping, type,
default, units, validation/clamping rules, whether it is expressible as data or code-only, and
any existing environment-variable support. Each ends with a "notable divergences and oddities"
section.

| File | Covers |
|---|---|
| [`go-rust.md`](go-rust.md) | Go (`go-server-sdk` v7), Rust (`rust-server-sdk` 3.2.0) |
| [`java-dotnet.md`](java-dotnet.md) | Java (`java-core`, v7.17.1), .NET (`dotnet-core`, v8.17.0) |
| [`python-ruby.md`](python-ruby.md) | Python (9.17.0), Ruby (8.18.0) |
| [`node-php.md`](node-php.md) | Node + Cloudflare/Vercel/Akamai edge (`js-core`), PHP |
| [`erlang-cpp-haskell.md`](erlang-cpp-haskell.md) | Erlang/Elixir, C++ (`cpp-sdks`), legacy `c-server-sdk`, Haskell |
| [`otel-declarative-config.md`](otel-declarative-config.md) | OpenTelemetry declarative configuration — the primary inspiration |
| [`ld-relay-config.md`](ld-relay-config.md) | LaunchDarkly Relay Proxy configuration — in-house prior art |
| [`format-evaluation.md`](format-evaluation.md) | TOML / YAML / JSON / KDL / CUE / JSON Schema, with per-language parser availability |
| [`internal-prior-art.md`](internal-prior-art.md) | Prior internal proposals, the dotnet-core sandbox env scheme, the FDv2 endpoint audit, sdk-specs conventions |

## Findings that shaped the design

**No server SDK reads an LD-namespaced environment variable, and none loads a config file.**
Across all eleven. The only ambient environment reads are C++'s `LD_LOG_LEVEL` (where code
overrides env — inverted from the precedence everyone else uses), the conventional proxy
variables in Go/Python/Ruby/C++, and the AWS credential chain for DynamoDB. The namespace is
greenfield.

**Every SDK already ships a declarative JSON-to-native config mapper.** The contract-test
harness config blocks — `contract-test-utils/ConfigParams.ts`, `data_model.hpp`,
`ts_sdk_config_params.erl`, and the various `SdkClientEntity` translators — already solve
unit-suffixed durations, persistent stores as `{type, dsn, prefix}`, cache lifetime as
`{mode, ttl}`, and a v2-to-v3 key-aliasing migration. This is the de facto prototype for both
the schema and the reference implementations.

**Identical options carry different defaults.** Event capacity is 10,000 in Go and Node, 1,000
in PHP, 500 in Rust. Flush interval is 5s, 10s, or 30s depending on SDK. The default polling
host is `app.launchdarkly.com` in Java, Python, and Go's FDv2 path but `sdk.launchdarkly.com` in
.NET, Ruby, and Go's FDv1 path — Go contains both constants. Event gzip defaults on in Rust and
off in Go.

**Capability gaps are large and asymmetric.** Rust has no big segments, hooks, plugins,
diagnostics, logging configuration, or HTTP configuration object at all. PHP has no streaming,
polling loop, proxy, or TLS options. PHP, Erlang, and Haskell have no FDv2 data system. Only Go
and Python can express a custom CA as data.

**Three hazards the schema has to address directly.** The FDv2 `data_system` silently supersedes
`stream`/`poll_interval`/`use_ldd`/`persistent_store` in Java, Node, .NET, and Go, so the two
paths cannot be merged. Go and Ruby ignore top-level endpoints entirely under FDv2, with no
warning — a Relay user silently reaches production LaunchDarkly. And "cache forever" is encoded
as a negative duration in Java, .NET, and C++, which a naive non-negative duration constraint
would reject.
