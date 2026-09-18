# LaunchDarkly Relay Proxy Configuration — In-House Prior Art

Source: `github.com/launchdarkly/ld-relay` @ `e30a61d` (2026-09-17), plus `github.com/launchdarkly/go-configtypes` (v1.2.2 is the pinned version) and `github.com/launchdarkly/go-server-sdk` (v7) for naming comparison.

Files that matter:

| File | Lines | Role |
|---|---|---|
| `config/config.go` | 373 | the whole config struct tree + defaults + `conf:"ENV_VAR"` tags |
| `config/config_from_file.go` | 36 | `LoadConfigFile` — 3 lines of real logic over `gcfg` |
| `config/config_from_env.go` | 168 | `LoadConfigFromEnvironment` — hand-written, incl. all the special cases |
| `config/config_validation.go` | 339 | cross-field validation + canonicalization |
| `config/config_field_types.go` | 258 | relay-specific typed values + credential types |
| `config/test_data_configs_{valid,invalid}_test.go` | 1395 | shared table of (file content, env vars, expected Config, expected error) |
| `internal/application/options.go` | — | CLI flags and file-vs-env source selection |
| `docs/configuration.md` | 324 | the normative user-facing reference (file property ↔ env var ↔ type ↔ default) |

---

## 1. The file format: git-config-style INI via `gcfg`

From `docs/configuration.md`:

> The configuration file format is an INI-like one, based on [Git configuration format](https://git-scm.com/docs/git-config#_syntax) (as implemented by the [gcfg](https://github.com/go-gcfg/gcfg) package).
>
> Every configuration file option has an equivalent environment variable.

```ini
[Main]
    Port = 8333
    BaseUri = "http://base"
    ExitOnError = 1
    LogLevel = "debug"

[Environment "Spree Project Production"]
    sdkKey = "SPREE_PROD_SDK_KEY"
    mobileKey = "SPREE_PROD_MOBILE_KEY"

[Environment "Spree Project Test"]
    sdkKey = "SPREE_TEST_SDK_KEY"
    logLevel = "debug"

[Filters "my-project"]
    keys = filter-a, filter-b

[Redis]
    Host = localhost
    localTtl = 30s
```

Notes on the format itself:

- **Subsections are the only nesting mechanism**: `[Environment "name"]` and `[Filters "projkey"]`. gcfg maps these to `map[string]*EnvConfig` / `map[string]*FiltersConfig` on the `Config` struct. There is **no** arbitrary nesting, no arrays of objects, and no way to express a list of heterogeneous components.
- **Repeated keys = list**: `EnvAllowedOrigin = http://first` twice appends (gcfg calls `UnmarshalText` repeatedly). In env vars the same setting must be a single comma-delimited string. This dual representation is baked into `go-configtypes`' `OptStringList` and its `SingleValueTextUnmarshaler` interface.
- **Property names are case-insensitive-ish in practice**: the docs use `baseUri`, tests use `BaseUri` and `BaseURI` interchangeably; gcfg matches struct field names loosely.
- **Loading is 3 lines** (`config_from_file.go`):

```go
func LoadConfigFile(c *Config, path string, loggers ldlog.Loggers) error {
	if err := gcfg.ReadFileInto(c, path); err != nil {
		return errLoadingConfigFile(path, FilterGcfgError(err))
	}
	return ValidateConfig(c, loggers)
}
```

- **No interpolation, no includes, no env substitution.** The only textual substitution anywhere is the `$CID` placeholder inside two specific string fields (§5).
- **Dependency risk**: pinned at `gopkg.in/gcfg.v1 v1.2.3`. Upstream `go-gcfg/gcfg` shows very little recent activity; I could not confirm any release after the v1.2.x line, so treat it as effectively frozen (verify before building anything new on it). `go-configtypes`' own docs reference a LaunchDarkly *fork* (`launchdarkly/gcfg`), which suggests upstream has already needed patching. There is essentially **one** viable INI-with-subsections parser in Go and none of the other 10 SDK languages has a compatible one — this format is not portable.

---

## 2. The parallel environment-variable scheme

### 2.1 Mechanism: struct tags + reflection

Every field carries a `conf:"VAR_NAME"` tag, and `go-configtypes.VarReader.ReadStruct` reflects over them:

```go
type MainConfig struct {
	ExitOnError              bool                     `conf:"EXIT_ON_ERROR"`
	StreamURI                ct.OptURLAbsolute        `conf:"STREAM_URI"`
	Port                     ct.OptIntGreaterThanZero `conf:"PORT"`
	InitTimeout              ct.OptDuration           `conf:"INIT_TIMEOUT"`
	MaxClientRequestBodySize ct.OptBase2Bytes         `conf:"MAX_CLIENT_REQUEST_BODY_SIZE"`
	TLSMinVersion            OptTLSVersion            `conf:"TLS_MIN_VERSION"`
	LogLevel                 OptLogLevel              `conf:"LOG_LEVEL"`
}
```

The env var names are **not derived** from the file property names — they are a hand-maintained parallel vocabulary. `[Main] baseUri` ↔ `BASE_URI` is mechanical, but `[Events] sendEvents` ↔ `USE_EVENTS`, `[Events] eventsUri` ↔ `EVENTS_HOST`, `[Redis] localTtl` ↔ `CACHE_TTL` are not. And `CACHE_TTL` is *shared* by three different file properties (`[Redis] localTtl`, `[Consul] localTtl`, `[DynamoDB] localTtl`) — one env var writing three struct fields.

`VarReader.Read` **does nothing if the variable is unset** — it never overwrites with a zero value. That is what makes the file+env overlay work at all.

### 2.2 Numbered / indexed / keyed env vars for repeated sections

There are no numbered indices; relay uses **name-suffixed** variables, discovered by prefix scan:

```go
for envName, envKey := range reader.FindPrefixedValues("LD_ENV_") {
	var ec EnvConfig
	if c.Environment[envName] != nil { ec = *c.Environment[envName] }   // merge onto file-defined env
	ec.SDKKey = SDKKey(envKey)
	subReader := reader.WithVarNameSuffix(envName)                      // LD_PREFIX_ + envName, etc.
	subReader.ReadStruct(&ec, false)
	rejectObsoleteVariableName("LD_TTL_MINUTES_"+envName, "LD_TTL_"+envName, reader)
	c.Environment[envName] = &ec
}
```

So the discovery key is `LD_ENV_<name>` (whose *value* is the SDK key), and every other per-environment setting is `<PREFIX>_<name>`:

```
LD_ENV_Spree_Project_Production=SPREE_PROD_SDK_KEY
LD_MOBILE_KEY_Spree_Project_Production=SPREE_PROD_MOBILE_KEY
LD_CLIENT_SIDE_ID_Spree_Project_Production=...
LD_PREFIX_Spree_Project_Production=...
LD_LOG_LEVEL_Spree_Project_Test=debug
```

The same trick appears three times with three different shapes:

| Pattern | Discovery var | Per-item vars | Notes |
|---|---|---|---|
| Environments | `LD_ENV_<name>` = SDK key | `LD_<SETTING>_<name>` | name is arbitrary user text |
| Filters | `LD_FILTER_KEYS_<projKey>` | (only the one) | discovery *is* the setting |
| Datadog tags | `DATADOG_TAG_<TagName>` = value | — | assembled into `[]string{"name:value"}` |

```go
for tagName, tagVal := range reader.FindPrefixedValues("DATADOG_TAG_") {
	c.Datadog.Tag = append(c.Datadog.Tag, tagName+":"+tagVal)
}
sort.Strings(c.Datadog.Tag) // for test determinacy
```

**Problems with this, concretely:**

- The name is embedded in the variable *name*, so it inherits shell identifier constraints. `[Environment "Spree Project Production"]` becomes `LD_ENV_Spree_Project_Production` — spaces silently become underscores in the docs' own example, and there is no stated normalization rule. Two environments differing only by space-vs-underscore collide.
- Prefix scanning is ambiguous. `LD_ENV_*` and `LD_ENV_DATASTORE_*`-ish names can't coexist safely; relay dodges this only because it happened to pick `ENV_DATASTORE_PREFIX` (no `LD_` prefix) for the AutoConfig equivalent.
- Typos in a suffixed variable are **silently ignored** (unknown env vars are not errors), unlike the file path where gcfg rejects unknown fields (§6).

### 2.3 Opt-in `USE_*` booleans that have no file equivalent

`docs/configuration.md` has rows literally marked `n/a` in the "Property in file" column:

| Property in file | Environment var | Meaning |
|---|---|---|
| n/a | `USE_REDIS` | enable Redis |
| n/a | `USE_CONSUL` | enable Consul |

The file expresses "enabled" by the **presence of a section/field** (`[Redis] host = ...`), whereas env vars need an explicit boolean because there is no section to be present. The code has to reconcile both:

```go
useRedis := false
reader.Read("USE_REDIS", &useRedis)
if useRedis || c.Redis.Host != "" || c.Redis.URL.IsDefined() {
	...
	if !c.Redis.URL.IsDefined() && c.Redis.Host == "" && !c.Redis.Port.IsDefined() {
		c.Redis.URL = defaultRedisURL   // "all they specified was USE_REDIS"
	}
}
```

Meanwhile `[DynamoDB] enabled`/`USE_DYNAMODB`, `[Datadog] enabled`/`USE_DATADOG`, `[Prometheus] enabled`/`USE_PROMETHEUS` *do* have file equivalents, but the file property is `enabled` and the env var is `USE_*`. So: three different enablement idioms across four subsystems.

### 2.4 One genuinely nasty special case

```go
reader.Read("REDIS_PORT", &portStr) // handled separately because it could be a string or a number
if strings.HasPrefix(portStr, "tcp://") {
	// REDIS_PORT gets set to tcp://$docker_ip:6379 when linking to a Redis container
	hostAndPort := strings.TrimPrefix(portStr, "tcp://")
	fields := strings.Split(hostAndPort, ":")
	c.Redis.Host = fields[0]
	...
}
```

A single variable is polymorphic (`6379` or `tcp://host:6379`) and can set a *different* field than its name suggests, because of a Docker legacy-links convention. This is the canonical example of what happens when the env-var surface is hand-written rather than generated.

---

## 3. Typed values

All typing lives in `go-configtypes`' `Opt*` types, which implement `encoding.TextUnmarshaler`. That single interface is what lets the *same* type definitions serve gcfg (file) and `VarReader` (env) — a genuinely good design decision.

The contract (`go-configtypes/package_info.go`):

- Every `Opt*` is either **defined** or **empty**; `IsDefined()`, `GetOrElse(fallback)`. The zero value is empty, so "unset" is representable without pointers. Crucially this gives the same **absent / present** distinction OTel needed.
- Validating variants encode the constraint in the *type name*: `OptIntGreaterThanZero`, `OptURLAbsolute`, `OptDurationNonNegative`, `OptStringNonEmpty`. Constructors for validating types return `(T, error)` and "will never return an instance that wraps an illegal value".
- Empty string is always valid and yields the empty state.
- They also implement `json.Marshaler`/`Unmarshaler` (empty ↔ JSON `null`), so the same types could back a JSON/YAML config with no change.

| Concept | Type | Accepted text form |
|---|---|---|
| Boolean | `bool` / `OptBool` | `true`/`false`, `1`/`0`, `yes`/`no`, case-insensitive; empty → unset |
| Duration | `OptDuration` | Go-ish: integer + `ms`/`s`/`m`/`h`, combinable (`1m30s`). **Unit is mandatory** — "You cannot specify a number by itself without a unit." |
| Byte size | `OptBase2Bytes` | `100MiB`, `5MiB`, `B`/`KiB`/`MiB`/`GiB`/… |
| URL | `OptURLAbsolute` | must parse and be absolute |
| Port / positive int | `OptIntGreaterThanZero` | error, not clamp, on `0` or `-1` |
| String list | `OptStringList` | file: repeated keys **or** comma-delimited; env: comma-delimited only |
| Log level | `OptLogLevel` (relay-local) | `debug`/`info`/`warn`/`error`/`none`, case-insensitive |
| TLS version | `OptTLSVersion` (relay-local) | `"1.0"`–`"1.3"` → `crypto/tls` constant; round-trips via `String()` |
| Credentials | `SDKKey`, `MobileKey`, `EnvironmentID`, `AutoConfigKey`, `FilterKey` | type-tag strings (§5) |

Mandatory duration units are worth stealing. Relay's own docs betray one place they didn't: `heartbeatInterval` is typed `Number` in the table with the note "Assumed to be in seconds if no unit is specified" — an inconsistency with every other duration.

Contrast with OTel, which specifies **integer milliseconds** for all durations (`common.md#duration`) precisely because a unit grammar is another thing every language must implement identically. Relay's suffix grammar is friendlier to humans and worse for portability.

---

## 4. How env and file config relate

There is **no merge algorithm**. Both loaders write into the *same* `Config` struct, sequentially, in `ld-relay.go`:

```go
if opts.ConfigFile != "" {
	if err := config.LoadConfigFile(&c, opts.ConfigFile, loggers); err != nil { os.Exit(1) }
}
if opts.UseEnvironment {
	if err := config.LoadConfigFromEnvironment(&c, loggers); err != nil { os.Exit(1) }
}
```

CLI semantics (`internal/application/options.go`):

- no flags → load `/etc/ld-relay.conf` (must exist)
- `--config FILEPATH` → must exist
- `--config FILEPATH --allow-missing-file` → load only if present (and if absent, `o.ConfigFile` is blanked)
- `--from-env` → read env vars
- both → "the file is loaded first, then it applies changes from variables if any"

So the effective rule is a **shallow, per-field, last-writer-wins overlay**, where env vars only write fields whose variable is actually set. `docs/configuration.md` states the motivating use case plainly:

```shell
LD_ENV_production={your_SDK_key} ./ld-relay --config base.conf --from-env
```

> …if you want to deploy a `base.conf` file that contains all of the global configuration for your relay instance, but for security reasons you do not want your SDK key to appear in that file.

This is exactly the requirement that OTel refused to serve (§3 of the OTel report), and relay serves it — but only because its config tree is *shallow and finite*. It works because there is exactly one `[Redis]`, and per-environment settings are addressed by name rather than by position. **The moment your schema has `processors: [ {...}, {...} ]`, this scheme has no addressing story** — which is precisely OTel's argument.

Two real consequences of the sequential-overlay design:

1. **`ValidateConfig` runs twice** (once per loader), and it *mutates* the config (canonicalization). It's idempotent today, but only by care: `normalizeRedisConfig` converts host/port → URL and then **clears** host/port, so the second pass doesn't trip `errRedisURLWithHostAndPort`. A file setting `[Redis] host` plus an env `REDIS_URL` *does* error, which is arguably right but is emergent rather than specified.
2. Env-var reading has to defensively undo file state. The AutoConfig/OfflineMode sections share env var names (`ENV_DATASTORE_PREFIX`, `ENV_ALLOWED_ORIGIN`, …) because only one can be active, so `LoadConfigFromEnvironmentBase` explicitly blanks the fields of whichever section isn't in use. Sharing one env var across two mutually-exclusive sections is a wart that then needs corrective code.

---

## 5. Secrets

This is the thinnest part of the system.

- **No general `*_FILE` indirection.** There is exactly **one** file-based secret: `[Consul] tokenFile` / `CONSUL_TOKEN_FILE`, and validation rejects setting both it and `token` (`errConsulTokenAndTokenFile`). Every other secret — `AUTO_CONFIG_KEY`, `AUTO_CONFIG_CACHE_ENCRYPTION_KEY`, `LD_ENV_*` (SDK keys), `LD_MOBILE_KEY_*`, `REDIS_PASSWORD`, `PROXY_AUTH_PASSWORD`, `CONSUL_TOKEN`, `TLS_KEY` (a path, at least) — is an inline string in the file or an env var.
- **The documented secret-handling pattern is "use env vars for the secrets, a file for everything else."** That is the primary justification given for supporting both sources at once.
- **Redirection via URL vs discrete fields** is offered as a lesser alternative: the Redis password can live in `REDIS_URL` (`redis://user:pass@host`) or in `REDIS_PASSWORD`, and the docs say "You may want to use the separate options instead if… you would rather set the password in an environment variable."
- **Credential type-tagging is the good idea here.** `config_field_types.go` defines distinct types for each credential kind, with a `Masked()` method:

```go
func (k SDKKey) Masked() string       { return "..." + last4Chars(k.String()) }
func (k MobileKey) Masked() string    { return "..." + last4Chars(k.String()) }
func (k AutoConfigKey) Masked() string{ return last4Chars(string(k)) }
// EnvironmentID is public information, so Masked() is an alias for String()
func (k EnvironmentID) Masked() string { return k.String() }
```

Plus `GetAuthorizationHeaderValue()` on each, so the type system — not a convention — decides how a credential is transmitted and how it appears in logs. This is directly the thing OTel is missing (`opentelemetry-configuration#563`), and it is better done here.

- **`$CID` placeholder**: the only interpolation in the system. `AutoConfigEnvironmentIDPlaceholder = "$CID"` is substituted with the environment's client-side ID inside `envDatastorePrefix` / `envDatastoreTableName`, with filter key appended (`"LD-$CID"` + env `12345` + filter `microservice-a` → `LD-12345.microservice-a`). Validation *requires* `$CID` when AutoConfig + a database are combined (`errAutoConfWithoutDBDisambig`), because AutoConfig implies "multiple, unknown-at-config-time environments." A neat, narrowly-scoped templating primitive; note it uses `$CID` not `${CID}`, so it can never be confused with env substitution.
- **AutoConfig is the dynamic/remote-config story** that OTel lacks: `AUTO_CONFIG_KEY` streams environment definitions from LaunchDarkly at runtime, optionally cached (encrypted with `AUTO_CONFIG_CACHE_ENCRYPTION_KEY`) in Redis/DynamoDB. It is mutually exclusive with static `[Environment]` sections, enforced by `errAutoConfWithEnvironments`.

---

## 6. Validation and error reporting

Three distinct layers, and the split is worth copying:

**(1) Per-field, at parse time** — via `TextUnmarshaler` on the `Opt*` types. Same messages regardless of source:

```
[Main] ExitOnError = "x"   ->  failed to parse bool `x`
[Main] Port = "x"          ->  not a valid integer
[Main] Port = "0"          ->  value must be greater than zero
```

**(2) Unknown keys — file only, and this is a real asymmetry.** gcfg rejects unknown sections/fields; relay post-processes the message to be legible:

```go
gcfgExtraDataErrPhrase := "can't store data at"
// Make gcfg's messages for unknown sections/fields slightly easier to understand
return errors.New(strings.Replace(err.Error(), gcfgExtraDataErrPhrase, "unsupported or misspelled", 1))
```

```
[Unknown]            ->  unsupported or misspelled section "Unknown"
[Main] Unknown = x   ->  unsupported or misspelled section "Main", variable "Unknown"
```

Environment variables get **no** such check — an unknown `LD_PREFX_myenv` is silently dropped. The only exception is a hand-maintained deny-list of *retired* variable names:

```go
func rejectObsoleteVariableName(oldName, preferredName string, reader *ct.VarReader) {
	// Unrecognized environment variables are normally ignored, but if someone has set a variable that
	// used to be used in configuration and is no longer used, we want to raise an error rather than just
	// silently omitting part of the configuration that they thought they had set.
	if os.Getenv(oldName) != "" { ... }
}
```
applied to exactly three names: `EVENTS_SAMPLING_INTERVAL`, `REDIS_TTL` (→ `CACHE_TTL`), `LD_TTL_MINUTES_<env>` (→ `LD_TTL_<env>`). Good instinct ("don't silently ignore something the user thought they set"), unscalable implementation.

**(3) Cross-field validation + canonicalization** — `ValidateConfig`, ~30 named error values. It is explicitly allowed to mutate:

> It is allowed to modify the Config struct in order to canonicalize settings in a way that simplifies things for the Relay code (for instance, converting Redis host/port settings into a Redis URL, or converting deprecated fields to non-deprecated ones).

and it is called a **third** time by `relay.NewRelay()` so that programmatic (library) users get the same checks. Representative rules:

```go
errTLSEnabledWithoutCertOrKey  = "TLS cert and key are required if TLS is enabled"
errAutoConfWithEnvironments    = "cannot configure specific environments if auto-configuration is enabled"
errFileDataWithAutoConf        = "cannot specify both auto-configuration key and file data source"
errMultipleDatabases           = "multiple databases are enabled (%s); only one is allowed"
errRedisURLWithHostAndPort     = "please specify Redis URL or host/port, but not both"
errCacheKeyWithoutStore        = "AUTO_CONFIG_CACHE_KEY requires Redis or DynamoDB to be enabled"
errMissingProjKey              = "when filters are configured, all environments must specify a 'projKey'"
errFilterInvalidKey            = "filter key [%d] for project '%s' is malformed (note: lists are comma-delimited)"
```

Three details worth noting:

- **Errors accumulate.** `ct.ValidationResult` collects `{Path, Err}` pairs; `GetError()` returns a single `ValidationError` or a comma-joined `ValidationAggregateError`. So users see all their mistakes at once. (The `ValidationPath` is a dot-joined field path — but `ValidateConfig` passes `nil` for almost every cross-field error, so those messages have no path. Half-used mechanism.)
- **Warn-and-continue is used deliberately**, in two flavours:
  - *warn instead of error when the situation is only potentially wrong*: one environment without a DB prefix warns with `"; this would be an error if multiple environments were configured"`.
  - *warn and clamp*: `validateMetricsCapacity` raises a below-minimum value to 1000 with `"configured usage metrics event capacity of %d is below the minimum of %d; using %[2]d instead"`. Note this contradicts the `OptIntGreaterThanZero` philosophy (error, don't coerce) and OTel's guidance ("gracefully ignore the setting… SHOULD NOT assign a custom interpretation"). Two policies coexist in one codebase.
- **Error messages name the env var, not the file property** (`errCacheKeyWithoutStore` says `AUTO_CONFIG_CACHE_KEY`), so a file-only user gets told about a variable they never set. Symptom of the parallel-vocabulary problem.

**Testing approach worth copying**: `test_data_configs_{valid,invalid}_test.go` is a single table of cases, each carrying `fileContent`, `envVars`, a `makeConfig` mutator describing the expected result, `warnings`, `fileError`, `envVarsError`. `config_from_file_test.go` and `config_from_env_test.go` both iterate it, skipping cases where the relevant input is empty. One corpus, two loaders, equivalence checked by construction. This is the relay analog of OTel's `snippets/` and it's arguably better because it asserts the *parsed result*, not just validity.

---

## 7. Where relay and the SDKs name the same thing differently

This matters because a declarative config spec has to pick one vocabulary, and relay is the incumbent whose users will read the new spec.

| Concept | Relay file | Relay env | Go SDK (v7) |
|---|---|---|---|
| Streaming endpoint | `[Main] streamUri` | `STREAM_URI` | `Config.ServiceEndpoints.Streaming` |
| Polling endpoint | `[Main] baseUri` | `BASE_URI` | `Config.ServiceEndpoints.Polling` |
| Events endpoint | `[Events] eventsUri` | `EVENTS_HOST` | `Config.ServiceEndpoints.Events` |
| Client-side polling endpoint | `[Main] clientSideBaseUri` | `CLIENT_SIDE_BASE_URI` | (no server-SDK analog) |
| Enable event sending | `[Events] sendEvents` | `USE_EVENTS` | `Config.Events` component (`ldcomponents.SendEvents()` / `NoEvents()`), plus `Config.Offline` |
| Event buffer size | `[Events] capacity` | `EVENTS_CAPACITY` | `EventProcessorBuilder.Capacity(int)` ✅ same word |
| Event flush period | `[Events] flushInterval` | `EVENTS_FLUSH_INTERVAL` | `EventProcessorBuilder.FlushInterval(Duration)` ✅ same word |
| Persistent-store cache TTL | `[Redis] localTtl` | `CACHE_TTL` | `PersistentDataStoreBuilder.CacheTime(Duration)` / `.CacheSeconds(int)` / `.CacheForever()` / `.NoCaching()` |
| Store key prefix | `[Environment ...] prefix` | `LD_PREFIX_<name>` | `ldredis.DataStore().Prefix(...)` ✅ same word |
| Log level | `[Main] logLevel` | `LOG_LEVEL` | `LoggingConfigurationBuilder.MinLevel(ldlog.LogLevel)` |
| HTTP proxy | `[Proxy] url` | `PROXY_URL` | `HTTPConfigurationBuilder.ProxyURL` |
| Startup wait | `[Main] initTimeout` | `INIT_TIMEOUT` | not config — the `waitFor` argument to `MakeCustomClient` |
| Credential | `sdkKey` | `LD_ENV_<name>` (value) | the SDK key is a *constructor argument*, not a `Config` field |

Two deeper mismatches, not just naming:

1. **"Environment" is a relay-only concept.** Relay multiplexes N LaunchDarkly environments in one process, each with its own credential set (`sdkKey`, `mobileKey`, `envId`) and store prefix. An SDK instance has exactly one. A shared declarative spec should almost certainly be **single-environment at the root**, with relay's multi-environment shape as a *relay-specific* wrapper (`environments: {name: <sdk-config>}`), not the other way round — otherwise every SDK user pays for a nesting level they never use.
2. **"ttl" is overloaded inside relay itself.** `[Environment] ttl` / `LD_TTL_<name>` is the *HTTP cache TTL for PHP polling endpoints*; `[Redis] localTtl` / `CACHE_TTL` is the *in-memory store cache TTL*. Do not inherit this.
3. **Relay's "enabled" flags vs the SDK's component-configurer model.** Relay says `USE_REDIS=1` + `REDIS_HOST=...`; the SDKs say `DataStore: ldcomponents.PersistentDataStore(ldredis.DataStore().HostAndPort(...))`. The SDK model is a *tagged union of components* — structurally identical to OTel's one-key-object extension points, and therefore what the declarative schema should mirror (`data_store: { redis: {...} }`), not relay's `USE_*` booleans.

---

## 8. Verdict: steal / avoid

### Steal

1. **One set of typed value objects (`Opt*`) implementing a single text-decoding interface, reused by every source.** File parser, env reader, JSON unmarshaller and programmatic constructor all get identical parsing and identical error messages for free. The constraint-in-the-type-name convention (`OptIntGreaterThanZero`, `OptURLAbsolute`) makes the schema self-documenting and makes illegal states unconstructable.
2. **Defined-vs-empty as a first-class state, with `GetOrElse(default)` at the point of use.** Same requirement OTel hit (absent vs null); relay's zero-value-is-empty approach is cheaper than nullable everything.
3. **Credential types with `Masked()` and `GetAuthorizationHeaderValue()`.** Sensitivity as a type property, not a doc note. This is the concrete answer to OTel's unresolved secrets issue — and in a schema it becomes a `"sensitive": true` / `format: secret` annotation that every implementation honours in logs, diagnostics and config dumps.
4. **Three-layer validation: field-level at decode, unknown-key rejection, cross-field afterwards** — with errors **accumulated** and returned together, and with the cross-field layer re-runnable so programmatic users get the same checks.
5. **A single shared test corpus of `(file content, env vars, expected parsed config, expected error/warning)` driven by every loader.** Guarantees the file and env surfaces stay equivalent by construction.
6. **Reject retired option names loudly instead of ignoring them** — generalize relay's three-entry deny-list into a schema-level `deprecated` / `removed` annotation so it's data, not code.
7. **Mandatory duration units** (`30s`, `1m30s`) if you value human legibility — but see the caveat below.
8. **A narrowly-scoped, unambiguous placeholder** (`$CID`, deliberately not `${...}`) for values that can only be known per-entity at runtime, with validation that *requires* it where ambiguity would otherwise result.
9. **`--allow-missing-file`** — an explicit "optional config file" mode. Trivial, and every deployment eventually wants it.

### Avoid

1. **Two hand-maintained vocabularies.** `sendEvents`↔`USE_EVENTS`, `eventsUri`↔`EVENTS_HOST`, `localTtl`↔`CACHE_TTL`, one env var writing three fields. Env var names must be **derived mechanically** from the schema path (or, like OTel, not exist at all beyond `${ENV}` substitution).
2. **Settings that exist in only one source.** `USE_REDIS`/`USE_CONSUL` have no file form; `[Environment]` sections have no way to say "enabled". Every option must exist in every source or the docs need an `n/a` column (relay's does).
3. **Encoding entity names into env var names** (`LD_ENV_<name>`, `LD_PREFIX_<name>`, `DATADOG_TAG_<name>`). Shell-identifier constraints, silent space→underscore mangling, prefix-scan ambiguity, no typo detection. Prefer a single structured env var, or the OTel approach (name/value **arrays** in the file, each half substitutable from an env var).
4. **Polymorphic variables** (`REDIS_PORT` accepting `6379` or `tcp://host:6379`, and setting `Host` as a side effect). Never let one key set a different key's field.
5. **Silently ignoring unknown environment variables while erroring on unknown file keys.** Users cannot tell whether their variable took effect. Pick one policy; strict is better, with an explicit escape for genuinely foreign vars.
6. **Mutating validation.** `ValidateConfig` canonicalizes *and* validates *and* runs 2–3 times. Separate `validate(model) -> errors` from `normalize(model) -> model` (OTel's `parse`/`create` split does this correctly), or you will eventually ship a non-idempotent bug.
7. **Mixed error-vs-clamp policy.** `Port = 0` errors; `metricsCapacity = 500` warns and clamps. Choose one rule and write it down (OTel's rule: warn and treat as unset; explicitly *don't* invent interpretations).
8. **Error messages that reference the other source's spelling.** `AUTO_CONFIG_CACHE_KEY requires Redis or DynamoDB to be enabled` is unhelpful to a file-only user. Report the path *as the user wrote it*.
9. **An INI/gcfg-shaped format.** Only `[Section "sub"]` nesting, no arrays of objects, no arrays of anything except repeated-key strings, one effectively-frozen parser that exists in exactly one of the eleven target languages. It cannot express the component-tree shape the SDKs actually have (`data_system: { store: { redis: {...} } }`, hooks lists, plugin lists).
10. **Duration suffix grammars, if portability dominates.** Relay's own `heartbeatInterval` already drifted ("assumed to be in seconds if no unit is specified"). Eleven independent implementations of `1m30s` will diverge; OTel's integer-milliseconds rule is uglier and safer. If you want suffixes, publish a strict grammar + a shared fixture file of accepted/rejected strings.
