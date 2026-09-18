# Server-side SDK configuration inventory: Go (v7) and Rust

Sources examined (shallow clones / crate downloads):

| SDK | Repo / crate | Version examined | Commit |
|---|---|---|---|
| Go | `github.com/launchdarkly/go-server-sdk/v7` | v7 (go 1.25) | `5bf0434` |
| Rust | `launchdarkly/rust-server-sdk` → crate `launchdarkly-server-sdk` | 3.2.0 | tip of `main` |
| Rust HTTP layer | crate `launchdarkly-sdk-transport` | 0.1.4 | crates.io |
| Rust Redis store | crate `launchdarkly-server-sdk-redis` | 1.0.0-rc.1 | crates.io (repo is **private**) |
| Go stores | `go-server-sdk-redis-redigo`, `go-server-sdk-dynamodb`, `go-server-sdk-consul` | tip | GitHub |

Legend for the **Data?** column:
- **D** = expressible as declarative data (scalar/duration/bool/string/enum/list of scalars)
- **D\*** = expressible as data only if the spec defines a named-component vocabulary (e.g. `redis`, `dynamodb`, `streaming`)
- **C** = code-only (closure, trait/interface object, logger instance, transport, cert bytes, connection pool)

---

## 1. Top-level config shape

| Aspect | Go | Rust |
|---|---|---|
| Entry point | `ldclient.Config` **struct with exported fields** (zero value valid); client built with `ld.MakeClient(sdkKey, waitFor)` / `ld.MakeCustomClient(sdkKey, config, waitFor)` | `ConfigBuilder::new(sdk_key) -> ConfigBuilder`, `.build() -> Result<Config, BuildError>`, then `Client::build(config)` |
| SDK key | **Not on Config** — positional arg to `MakeClient`/`MakeCustomClient`. Validated: rejected if any char <32 or >127 ("SDK key contains invalid characters") | `ConfigBuilder::new(sdk_key: &str)`; stored on `Config.sdk_key`; **no validation** |
| Sub-config style | Each area is a `subsystems.ComponentConfigurer[T]` produced by an `ldcomponents.X()` builder; nil means default | Each area is a `Box<dyn XFactory>` produced by a `XBuilder`; `None` means default |
| Build errors | Returned from `MakeCustomClient` | `ConfigBuildError::InvalidConfig(String)`, `client::BuildError` |
| Instance ID | `uuid.New().String()` generated in `newClientContextFromConfig`; not configurable; sent as `X-LaunchDarkly-Instance-Id` | `uuid::Uuid::new_v4()` generated in `ConfigBuilder::build()`; exposed read-only via `Config::instance_id()`; not configurable; sent as `x-launchdarkly-instance-id` |

Key files: `config.go`, `client_context_from_config.go`, `ldclient.go` / `src/config.rs`, `src/client.rs`.

---

## 2. Core / client-level options

| Option | Go canonical name | Rust canonical name | Type | Go default | Rust default | Semantics | Data? |
|---|---|---|---|---|---|---|---|
| SDK key | `MakeClient(sdkKey, …)` arg | `ConfigBuilder::new(sdk_key)` | string | — (required) | — (required) | Environment credential | D |
| Offline mode | `Config.Offline` | `ConfigBuilder::offline(bool)` | bool | `false` | `false` | No network; all flags return defaults. Go: ignores `DataSource`, `Events`, `HTTP`. Rust: replaces data source/data system with `NullDataSourceBuilder` and event processor with `NullEventProcessorBuilder`, logging a warning if one was explicitly configured. | D |
| Daemon mode | **absent as a flag** — expressed as `Config.DataSource = ldcomponents.ExternalUpdatesOnly()` or `ldcomponents.DataSystem().Daemon(store)` | `ConfigBuilder::daemon_mode(bool)` | bool / component | n/a | `false` | Read flags only from the persistent store; never connect to LD. Rust daemon mode nulls the data source/data system but **keeps events enabled**. | D |
| Init wait timeout | `waitFor time.Duration` param to `MakeClient`/`MakeCustomClient` | `Client::wait_for_initialization(timeout).await` (runtime call, not config) | duration | — (0 = return immediately) | — | Block until data source initializes. Go logs a warning if `waitFor > 60s` (`highWaitForDuration`); `waitFor == 0` returns immediately; ignored if offline. | D (if hoisted into config) |
| Diagnostic opt-out | `Config.DiagnosticOptOut` | **not supported** | bool | `false` | n/a | Suppress diagnostic event payloads. Go only creates a diagnostics manager when the event processor is exactly `ldcomponents.SendEvents()` (reflect type check). | D |
| Hooks | `Config.Hooks []ldhooks.Hook` | **not supported** | list of objects | `nil` | n/a | Evaluation/track series interception | C |
| Plugins | `Config.Plugins []ldplugins.Plugin` (documented experimental) | **not supported** | list of objects | `nil` | n/a | Register hooks + client-level extension | C |
| Relay-proxy data destination | `Config.LDRelayDataDestination func(ReadOnlyDataStore, <-chan ChangeSet)` — "for use by LaunchDarkly only" | **not supported** | closure | `nil` | n/a | Relay Proxy internal hook | C |
| Wrapper name/version | `ldcomponents.HTTPConfiguration().Wrapper(name, version)` | **not supported** | 2× string | `""` | n/a | Sent as `X-LaunchDarkly-Wrapper: name/version` (name only if version empty) | D |
| Extra User-Agent | `ldcomponents.HTTPConfiguration().UserAgent(string)` | **not supported** | string | `""` | n/a | Appended to `GoClient/<ver>` | D |

---

## 3. Application info (tags)

| Option | Go | Rust | Type | Default | Validation | Data? |
|---|---|---|---|---|---|---|
| Application ID | `Config.ApplicationInfo.ApplicationID` | `ApplicationInfo::application_identifier(impl Into<String>)` | string | `""` / none | Both: ≤64 chars, only `[A-Za-z0-9._-]`; invalid values **discarded with a warning**. Go regex `^[\w.-]*$` in `validateTagValue`; Rust `Tag::is_valid` | D |
| Application version | `Config.ApplicationInfo.ApplicationVersion` | `ApplicationInfo::application_version(...)` | string | `""` / none | same | D |
| Application name | **not supported** | **not supported** | — | — | — | — |
| Application version name | **not supported** | **not supported** | — | — | — | — |
| Arbitrary tags | not exposed (only the two fields) | `ApplicationInfo::add_tag` is **private**; only the two public setters | — | — | Rust emits sorted+deduped `key/value` pairs space-joined | — |

Both emit `X-LaunchDarkly-Tags: application-id/<id> application-version/<ver>`. Go builds it in `buildTagsHeaderValue` (order: id then version); Rust ASCII-sorts and dedupes.

**Divergence:** Neither Go nor Rust supports `application.name` / `application.versionName`, which other LD SDKs do.

---

## 4. Service endpoints

| Option | Go | Rust | Type | Default | Data? |
|---|---|---|---|---|---|
| Streaming URI | `Config.ServiceEndpoints.Streaming` | `ServiceEndpointsBuilder::streaming_base_url(&str)` | string | Go `https://stream.launchdarkly.com/`; Rust `https://stream.launchdarkly.com` | D |
| Polling URI | `Config.ServiceEndpoints.Polling` | `ServiceEndpointsBuilder::polling_base_url(&str)` | string | Go (FDv1) `https://sdk.launchdarkly.com/`; Rust `https://sdk.launchdarkly.com` | D |
| Events URI | `Config.ServiceEndpoints.Events` | `ServiceEndpointsBuilder::events_base_url(&str)` | string | `https://events.launchdarkly.com` | D |
| Relay proxy (all three) | `ldcomponents.RelayProxyEndpoints(uri)` | `ServiceEndpointsBuilder::relay_proxy(&str)` | string | — | D |
| Relay proxy without event forwarding | `ldcomponents.RelayProxyEndpointsWithoutEvents(uri)` (sets streaming+polling, marks partial) | **not supported** | string | — | D |
| Partial specification escape hatch | `ServiceEndpoints.WithPartialSpecification()` (private field `allowPartialSpecification`) | **not supported** | bool | `false` | D |
| Validation of partial sets | **Warn-and-default**: `endpoints.SelectBaseURI` logs `Error` "You have set custom ServiceEndpoints without specifying the %s base URI" and falls back to the default for the missing one (suppressed by `WithPartialSpecification`) | **Hard error**: `ServiceEndpointsBuilder::build()` returns `BuildError::InvalidConfig("If you specify any endpoints, then you must specify all endpoints.")` | — | — | — |
| Trailing-slash handling | `strings.TrimRight(uri, "/")` at selection time | `trim_end_matches('/')` at build time | — | — | — |

Known URL paths (not configurable): Go FDv1 stream `/all`, FDv2 stream `/sdk/stream`, FDv1 poll `/sdk/latest-all`, FDv2 poll `/sdk/poll`; Rust FDv1 poll `/sdk/latest-all`, events `POST {events_base_url}/bulk`.

**Important Go oddity:** `ldcomponents.DefaultPollingBaseURI = "https://app.launchdarkly.com"` while `internal/endpoints.DefaultPollingBaseURI = "https://sdk.launchdarkly.com/"`. The FDv1 path uses the latter; the FDv2 `DataSystem()` modes and `PollingDataSourceV2`/`FDv1PollingDataSourceV2` builders default to the former (`app.launchdarkly.com`). Two different "default polling URI" constants coexist in the same package.

---

## 5. Data source selection (FDv1)

| Option | Go | Rust | Type | Default | Data? |
|---|---|---|---|---|---|
| Data source choice | `Config.DataSource` = one of the configurers below | `ConfigBuilder::data_source(&dyn DataSourceFactory)` | object / enum | streaming | D\* |
| Streaming | `ldcomponents.StreamingDataSource()` | `StreamingDataSourceBuilder::<T>::new()` | object | **default** in both | D\* |
| Polling | `ldcomponents.PollingDataSource()` | `PollingDataSourceBuilder::<T>::new()` | object | — | D\* |
| External updates only / daemon | `ldcomponents.ExternalUpdatesOnly()` | `ConfigBuilder::daemon_mode(true)` (internally `NullDataSourceBuilder`) | object / bool | — | D |
| File data | `ldfiledata.DataSource()` (FDv1) / `ldfiledatav2.DataSource()` (FDv2) | **not supported** | object | — | D\* |
| Test data | `testhelpers/ldtestdata.DataSource()` (FDv1), `ldtestdatav2.DataSource()` (FDv2) | `TestData::new()` (implements `DataSourceFactory`; shipped in the main crate, not behind a test feature) | object | — | C (flags built programmatically) |

### 5.1 Streaming data source options

| Option | Go | Rust | Type | Default | Units | Validation | Data? |
|---|---|---|---|---|---|---|---|
| Initial reconnect delay | `StreamingDataSource().InitialReconnectDelay(d)` | `StreamingDataSourceBuilder::initial_reconnect_delay(Duration)` | duration | 1s (`DefaultInitialReconnectDelay`) | ns-precision `time.Duration` / `Duration` | Go: `<= 0` → reset to default. Rust: **no clamping** | D |
| Payload filter key | `StreamingDataSource().PayloadFilter(string)` | **not supported** | string | unset | — | Go: empty string → `Build` returns error "payload filter key cannot be an empty string" | D |
| Streaming base URI | via `Config.ServiceEndpoints.Streaming` | via `ServiceEndpointsBuilder` | string | see §4 | — | — | D |
| Transport injection | — (see HTTP section) | `StreamingDataSourceBuilder::transport(T: HttpTransport)` | trait object | default HTTPS `HyperTransport` | — | — | C |

### 5.2 Polling data source options

| Option | Go | Rust | Type | Default | Validation | Data? |
|---|---|---|---|---|---|---|
| Poll interval | `PollingDataSource().PollInterval(d)` | `PollingDataSourceBuilder::poll_interval(Duration)` | duration | 30s | Go: `< 30s` → **silently set to 30s** (`DefaultPollInterval` is both default and minimum). Rust: `max(v, MINIMUM_POLL_INTERVAL=30s)` | D |
| Payload filter key | `PollingDataSource().PayloadFilter(string)` | **not supported** | string | unset | empty → build error | D |
| Polling base URI | `Config.ServiceEndpoints.Polling` | `ServiceEndpointsBuilder::polling_base_url` | string | see §4 | — | D |
| Transport injection | — | `PollingDataSourceBuilder::transport(T)` | trait object | default HTTPS | — | C |
| Feature requester factory | — | `FeatureRequesterFactory` trait (public; `HttpFeatureRequesterBuilder` is the built-in) | trait object | HTTP | — | C |

Go logs a `Warn` on every polling `Build()`: "You should only disable the streaming API if instructed to do so by LaunchDarkly support". Rust does not.

### 5.3 File data source (Go only)

| Option | Go | Type | Default | Data? |
|---|---|---|---|---|
| File paths | `ldfiledata.DataSource().FilePaths(paths ...string)` (**appends**, does not replace) | list of strings | empty | D |
| Duplicate-key handling | `.DuplicateKeysHandling(ldfiledata.DuplicateKeysFail \| DuplicateKeysKeepFirst)` | enum (`"fail"` / `"ignore"`) | `DuplicateKeysFail` | D |
| Reloader / file watching | `.Reloader(ldfilewatch.WatchFiles)` | `ReloaderFactory` func | none (no auto-reload) | C — the only built-in impl is `ldfilewatch.WatchFiles`, so a spec could model it as `autoUpdate: bool` |

`ldfiledatav2` is byte-for-byte the same builder API, but `Build` returns a `DataSynchronizer` and it adds `.AsInitializer()` for use in the FDv2 data system.

---

## 6. FDv2 / data system

Both SDKs ship a parallel "data system" config that supersedes the FDv1 data source.

| Option | Go | Rust | Type | Default | Data? |
|---|---|---|---|---|---|
| Select the data system | `Config.DataSystem = ldcomponents.DataSystem().<mode>()` | `ConfigBuilder::data_system(&DataSystemBuilder)` | object | Go: nil → FDv1 path. Rust: `None` → FDv1 path | D\* |
| Recommended mode | `DataSystem().Default()` = initializer: polling-v2; synchronizers: [streaming-v2, polling-v2]; FDv1 fallback: `FDv1PollingDataSourceV2()` | `DataSystemBuilder::default()` = initializer: `FDv2PollingBuilder`; synchronizers: [`FDv2StreamingBuilder`, `FDv2PollingBuilder`]; fdv1 fallback: `PollingDataSourceBuilder` | preset | same shape in both | D\* |
| Streaming-only mode | `DataSystem().Streaming()` | — (assemble via `custom()`) | preset | — | D\* |
| Polling-only mode | `DataSystem().Polling()` | — (assemble via `custom()`) | preset | — | D\* |
| Daemon mode | `DataSystem().Daemon(store)` → store in `DataStoreModeRead`, no initializers/synchronizers | `ConfigBuilder::daemon_mode(true)` | preset | — | D\* |
| Persistent-store mode | `DataSystem().PersistentStore(store)` → `Default()` + store in `DataStoreModeReadWrite` | — (pass a `PersistentDataStoreBuilder` to `data_store`) | preset | — | D\* |
| Custom assembly | `DataSystem().Custom()` | `DataSystemBuilder::custom()` | object | empty | D\* |
| Initializers (ordered) | `.Initializers(cfgs ...ComponentConfigurer[DataInitializer])` (**replaces**) | `DataSystemBuilder::initializer(impl FDv2InitializerConfig)` (**appends**) | list of objects | Go: nil → error `"initializer %d is nil"` if a nil slot is passed | D\* |
| Synchronizers (ordered, with fallback) | `.Synchronizers(cfgs ...)` (**replaces**) | `DataSystemBuilder::synchronizer(...)` (**appends**) | list of objects | — | D\* |
| FDv1-compatible fallback | `.FDv1CompatibleSynchronizer(cfg)` | `DataSystemBuilder::fdv1_fallback(&dyn DataSourceFactory)` / `.disable_fdv1_fallback()` | object / off | set by Default modes | D\* |
| Data store + mode | `.DataStore(store, ss.DataStoreModeRead \| DataStoreModeReadWrite)` | not part of the data system (store is a top-level `ConfigBuilder::data_store`) | object + enum | `DataStoreModeRead` (=0) is the Go zero value | D\* + D |
| Endpoint overrides | `DataSystem().WithEndpoints(Endpoints{Streaming, Polling})`, `.WithRelayProxyEndpoints(baseURI)`; also per-source `.BaseURI(string)` | per-source `FDv2StreamingBuilder::base_url` / `FDv2PollingBuilder::base_url`; otherwise inherits `ServiceEndpoints` | string(s) | Go: `Streaming = "https://stream.launchdarkly.com/"`, `Polling = "https://app.launchdarkly.com"` | D |
| Fallback timeout | **hardcoded** (`fdv2_datasystem.go`: outage thresholds 10s / 1min / 5min; 10s status ticker) | **hardcoded** `DEFAULT_FALLBACK_TIMEOUT = 120s` | duration | not configurable in either | — |
| Recovery timeout | **hardcoded** | **hardcoded** `DEFAULT_RECOVERY_TIMEOUT = 300s` | duration | not configurable in either | — |

FDv2 per-source options:

| Option | Go | Rust | Default | Notes |
|---|---|---|---|---|
| Streaming initial reconnect delay | `StreamingDataSourceV2().InitialReconnectDelay(d)` | `FDv2StreamingBuilder::initial_reconnect_delay(d)` | 1s | Go clamps `<=0` to default; Rust does not |
| Streaming base URI | `StreamingDataSourceV2().BaseURI(s)` | `FDv2StreamingBuilder::base_url(&str)` | Go `https://stream.launchdarkly.com/`; Rust falls back to `ServiceEndpoints` | |
| Polling interval | `PollingDataSourceV2().PollInterval(d)`, `FDv1PollingDataSourceV2().PollInterval(d)` | `FDv2PollingBuilder::poll_interval(d)` | 30s | Go clamps to ≥30s; **Rust `FDv2PollingBuilder::poll_interval` does NOT clamp** even though its doc comment says "effective minimum of 30 seconds" |
| Polling base URI | `.BaseURI(s)` on both v2 polling builders | `FDv2PollingBuilder::base_url(&str)` | Go `https://app.launchdarkly.com`; Rust falls back to `ServiceEndpoints` | |
| Use polling as initializer | `PollingDataSourceV2().AsInitializer()`, `ldfiledatav2.DataSource().AsInitializer()` | `FDv2PollingBuilder` implements both `FDv2InitializerConfig` and `FDv2SynchronizerConfig` | | |
| Payload filter | `StreamingDataSourceV2().PayloadFilter(k)` / `PollingDataSourceV2().PayloadFilter(k)` — **deprecated**, logs a warning: "Payload filtering is not supported with the FDv2 data system; the configured payload filter will stop being applied in a future release". `FDv1PollingDataSourceV2().PayloadFilter(k)` is **not** deprecated | **not supported** | unset | |
| Transport | — | `.transport(T)` on both FDv2 builders | default HTTPS | C |
| Custom sources | `ComponentConfigurer[DataInitializer]` / `[DataSynchronizer]` | `data_sources` module (`FDv2SynchronizerConfig`, `FDv2InitializerConfig`, `Synchronizer`, `Initializer`) — documented as experimental/not semver | — | C |

**Divergence:** In Go, FDv2 sources do **not** consult `Config.ServiceEndpoints` at all — `StreamingDataSourceBuilderV2.Build`/`PollingDataSourceBuilderV2.Build` use only their own `baseURI` field. Endpoint config therefore has to be re-specified via `DataSystem().WithEndpoints(...)`. In Rust, FDv2 builders fall back to the shared `ServiceEndpoints` when `base_url` is unset. Events in both SDKs still use `ServiceEndpoints`.

---

## 7. Events

| Option | Go | Rust | Type | Go default | Rust default | Units | Data? |
|---|---|---|---|---|---|---|---|
| Enable / disable | `Config.Events = ldcomponents.SendEvents()` or `ldcomponents.NoEvents()` | `ConfigBuilder::event_processor(&EventProcessorBuilder)` or `&NullEventProcessorBuilder` | object / bool | `SendEvents()` | `EventProcessorBuilder` | — | D |
| Capacity | `SendEvents().Capacity(int)` | `EventProcessorBuilder::capacity(usize)` | int | **10000** (`DefaultEventsCapacity`) | **500** (`DEFAULT_EVENT_CAPACITY`) | events | D |
| Flush interval | `SendEvents().FlushInterval(d)` | `EventProcessorBuilder::flush_interval(Duration)` | duration | 5s | 5s | — | D |
| All attributes private | `SendEvents().AllAttributesPrivate(bool)` | `EventProcessorBuilder::all_attributes_private(bool)` | bool | `false` | `false` | — | D |
| Private attributes | `SendEvents().PrivateAttributes(attrs ...string)` — **replaces** previous values; each parsed via `ldattr.NewRef` | `EventProcessorBuilder::private_attributes(HashSet<R: Into<Reference>>)` — **replaces** | list of attr refs | empty | empty | leading `/` = JSON-Pointer-ish path with `~0`/`~1` escapes | D |
| Context keys capacity | `SendEvents().ContextKeysCapacity(int)` | `EventProcessorBuilder::context_keys_capacity(NonZeroUsize)` | int | 1000 | 1000 | keys | D |
| Context keys flush interval | `SendEvents().ContextKeysFlushInterval(d)` | `EventProcessorBuilder::context_keys_flush_interval(Duration)` | duration | 5m | 5m (300s) | — | D |
| Omit anonymous contexts | `SendEvents().OmitAnonymousContexts(bool)` | `EventProcessorBuilder::omit_anonymous_contexts(bool)` | bool | `false` | `false` | — | D |
| Gzip event payloads | `SendEvents().EnableGzip(bool)` | `EventProcessorBuilder::compress_events(bool)` — gated behind Cargo feature `event-compression` | bool | **`false`** | **`true`** (when `event-compression` is on, which is a default feature); `false` otherwise | — | D |
| Diagnostic opt-out | `Config.DiagnosticOptOut` (top level) | **not supported** | bool | `false` | n/a | — | D |
| Diagnostic recording interval | `SendEvents().DiagnosticRecordingInterval(d)` | **not supported** (a commented-out `// diagnostic_recording_interval: Duration` field exists in `EventProcessorBuilder`) | duration | 15m; **clamped up** to `MinimumDiagnosticRecordingInterval = 60s` | n/a | — | D |
| Log context key in errors | `ldcomponents.Logging().LogContextKeyInErrors(bool)` (flows into `EventsConfiguration.LogUserKeyInErrors`) | **not supported** | bool | `false` | n/a | — | D |
| Events base URI | `Config.ServiceEndpoints.Events` | `ServiceEndpointsBuilder::events_base_url` | string | see §4 | see §4 | — | D |
| Event sender / transport | — (uses the shared HTTP client) | `EventProcessorBuilder::transport(T)`; `event_sender(Arc<dyn EventSender>)` is `#[cfg(test)]`-only | trait object | — | default HTTPS | — | C |

Validation: neither SDK clamps `Capacity`, `FlushInterval`, `ContextKeysCapacity`, or `ContextKeysFlushInterval`. Rust's `context_keys_capacity` is type-enforced non-zero (`NonZeroUsize`), with a comment that caching "cannot be entirely disabled"; Go accepts 0/negative.

Go's diagnostic payload field names (a useful cross-SDK naming reference from `DescribeConfiguration`): `allAttributesPrivate`, `customEventsURI`, `diagnosticRecordingIntervalMillis`, `eventsCapacity`, `eventsFlushIntervalMillis`, `userKeysCapacity`, `userKeysFlushIntervalMillis`, `omitAnonymousContexts`, `enableGzip`, `connectTimeoutMillis`, `socketTimeoutMillis`, `usingProxy`, `streamingDisabled`, `customStreamURI`, `customBaseURI`, `reconnectTimeMillis`, `pollingIntervalMillis`, `usingRelayDaemon`.

---

## 8. HTTP / networking

Go centralizes this in `ldcomponents.HTTPConfiguration()`. **Rust has no HTTP config object at all** — networking is configured by constructing a `launchdarkly_sdk_transport::HyperTransport` and injecting it into each component builder (`.transport(t)`), so it is per-component and code-only.

| Option | Go | Rust | Type | Go default | Rust default | Data? |
|---|---|---|---|---|---|---|
| Connect timeout | `HTTPConfiguration().ConnectTimeout(d)` | `HyperTransport::builder().connect_timeout(Duration)` | duration | 3s (`DefaultConnectTimeout`); `<=0` → reset to default. Also used as the whole-request `http.Client.Timeout` | **none** (no connect timeout by default) | D |
| Read timeout | — (no separate setting; Go uses `connectTimeout` for `Client.Timeout` too) | `.read_timeout(Duration)` | duration | n/a | none | D |
| Write timeout | — | `.write_timeout(Duration)` | duration | n/a | none | D |
| Proxy URL | `HTTPConfiguration().ProxyURL(string)` — invalid URL → error from `MakeCustomClient`; supports `scheme://user:pass@host:port` | `HyperTransportBuilder::proxy_url(String)` | string | unset | unset | D |
| Proxy from environment | implicit via Go stdlib `http.ProxyFromEnvironment` semantics; `ProxyURL` overrides `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` | `HyperTransportBuilder::auto_proxy()` (the default) reads `http_proxy`/`HTTP_PROXY`, `https_proxy`/`HTTPS_PROXY`, `no_proxy`/`NO_PROXY`, lowercase taking precedence | bool/enum | env-driven | `Auto` | D |
| Disable proxy | — | `HyperTransportBuilder::disable_proxy()` | bool | n/a | off | D |
| CA cert (bytes) | `HTTPConfiguration().CACert([]byte)` | — (choose a TLS backend via Cargo features) | bytes | none | n/a | C |
| CA cert (file) | `HTTPConfiguration().CACertFile(path)` | — | string path | none | n/a | **D** (path is data) |
| Custom headers | `HTTPConfiguration().Header(key, value)` — repeated calls overwrite same key; **allowed to override `User-Agent` and `Authorization`** | **not supported** | map<string,string> | empty | n/a | D |
| Custom HTTP client factory | `HTTPConfiguration().HTTPClientFactory(func() *http.Client)` — **overrides** `ConnectTimeout` and `ProxyURL` | `.transport(T: HttpTransport)` per component | closure / trait object | nil | none | C |
| Low-level transport options | `HTTPConfiguration().HTTPOptions([]ldhttp.TransportOption)` — `ldhttp` provides `ConnectTimeoutOption`, `CACertOption`, `CACertFileOption`, `ProxyOption`, `IdleConnTimeoutOption`, `MaxIdleConnsOption`, `MaxIdleConnsPerHostOption`, `DisableKeepAlivesOption` | Cargo features + `HyperTransportBuilder` | list of objects | empty | — | C (though idle-conn/keep-alive knobs are conceptually D) |
| NTLM proxy | `ldntlm.NewNTLMProxyHTTPClientFactory(proxyURL, username, password, domain, opts...)` → pass to `HTTPClientFactory` | **not supported** | closure factory | — | — | C (params are D) |
| TLS backend choice | runtime (system roots + optional extra CA) | **compile-time Cargo features**: `hyper-rustls-native-roots` (default), `hyper-rustls-webpki-roots`, `native-tls`; crypto backend `crypto-aws-lc-rs` (default) or `crypto-openssl` | — | — | **not data** (build-time) |

**Rust note:** if none of the TLS features is enabled, `ConfigBuilder::build()` returns `InvalidConfig("data source builder required when hyper-rustls-native-roots, hyper-rustls-webpki-roots, or native-tls features are disabled")` unless a data source and event processor were explicitly supplied.

---

## 9. Logging

| Option | Go | Rust | Type | Default | Data? |
|---|---|---|---|---|---|
| Logging config object | `Config.Logging = ldcomponents.Logging()` / `ldcomponents.NoLogging()` | **absent** — the SDK uses the `log` crate facade (`#[macro_use] extern crate log`); configuration is entirely the host application's (e.g. `env_logger`) | object | `Logging()` | D\* for Go |
| Min level | `Logging().MinLevel(ldlog.Debug\|Info\|Warn\|Error)` | n/a | enum | `ldlog.Info` | D |
| Disable all logging | `ldcomponents.NoLogging()` (= `Logging().Loggers(ldlog.NewDisabledLoggers())`) | n/a | bool | enabled | D |
| Custom logger sink | `Logging().Loggers(ldlog.Loggers)` | n/a (any `log` backend) | object | `ldlog.NewDefaultLoggers()` | C |
| Log evaluation errors | `Logging().LogEvaluationErrors(bool)` | n/a | bool | `false` | D |
| Log context key in errors | `Logging().LogContextKeyInErrors(bool)` | n/a | bool | `false` | D |
| Log data source outage as error after | `Logging().LogDataSourceOutageAsErrorAfter(d)` | n/a | duration | 1m (`DefaultLogDataSourceOutageAsErrorAfter`); **0 disables** the escalation | D |

---

## 10. Big segments

**Rust does not implement Big Segments at all** (no `big_segment` symbol anywhere in the crate).

| Option | Go | Type | Default | Validation | Data? |
|---|---|---|---|---|---|
| Enable + choose store | `Config.BigSegments = ldcomponents.BigSegments(storeConfigurer)` | object | `nil` → feature disabled; flags referencing a big segment evaluate as "not included" with reason `BigSegmentsStoreNotConfigured`. `BigSegments(nil)` also disables | — | D\* |
| Context cache size | `BigSegments(...).ContextCacheSize(int)` | int | 1000 | none | D |
| Context cache time | `.ContextCacheTime(d)` | duration | 5s | none | D |
| Status poll interval | `.StatusPollInterval(d)` | duration | 5s | `<= 0` → reset to default | D |
| Stale after | `.StaleAfter(d)` | duration | 120s | none | D |
| Store implementation | `ldredis.BigSegmentStore()`, `lddynamodb.BigSegmentStore(tableName)` | object | — | — | D\* |

Go's Big Segment stores have their own `Prefix`/`URL`/table options (see §11). Note asymmetry: the big-segment store is configured **separately** from the main data store and may point at a different database.

---

## 11. Persistent data stores

| Option | Go | Rust | Type | Default | Data? |
|---|---|---|---|---|---|
| Wrap a persistent store | `Config.DataStore = ldcomponents.PersistentDataStore(impl)` | `ConfigBuilder::data_store(&PersistentDataStoreBuilder::new(Arc<dyn PersistentDataStoreFactory>))` | object | in-memory | D\* |
| In-memory store | `ldcomponents.InMemoryDataStore()` | `InMemoryDataStoreBuilder::new()` | object | **default** | D\* |
| Cache TTL | `PersistentDataStore(x).CacheTime(d)` | `PersistentDataStoreBuilder::cache_time(Duration)` | duration | 15s in both | D |
| Cache TTL (seconds shortcut) | `.CacheSeconds(int)` | `.cache_seconds(u64)` | int (seconds) | 15 | D |
| Cache forever | `.CacheForever()` (encoded as `cacheTTL = -1ms`) | `.cache_forever()` (encoded as `cache_ttl = None`) | bool | off | D |
| No caching | `.NoCaching()` (`cacheTTL = 0`) | `.no_caching()` (`Duration::ZERO`) | bool | off | D |
| Custom store impl | `subsystems.PersistentDataStore` interface | `PersistentDataStore` trait + `PersistentDataStoreFactory` | interface | — | C |

Go's caching doc explicitly notes: *"Under FDv2 the persistent-store cache is automatically dropped once the in-memory store has been initialized, so this setting only affects the brief bootstrap window… retained for backward compatibility and may be deprecated in a future major version."* Effectively soft-deprecated.

### Database integrations

| Option | Go Redis (`ldredis`) | Go DynamoDB (`lddynamodb`) | Go Consul (`ldconsul`) | Rust Redis (`launchdarkly-server-sdk-redis`) | Data? |
|---|---|---|---|---|---|
| URL / address | `DataStore().URL(string)` — default `redis://localhost:6379`; empty → default. Also `.HostAndPort(host, port)` | — (AWS endpoint resolution) | `DataStore().Address(string)` | `RedisPersistentDataStoreFactory::url(&str)` — default `redis://localhost:6379` | D |
| Key prefix | `.Prefix(string)` — default `"launchdarkly"`; empty → default; colon appended | `.Prefix(string)` — **no default** (empty allowed) | `.Prefix(string)` — default `"launchdarkly"`; empty → default | `.prefix(&str)` — default `"launchdarkly"` | D |
| Table name | n/a | `DataStore(tableName)` / `BigSegmentStore(tableName)` — **required positional arg**, table must pre-exist | n/a | n/a | D |
| Big segment store | `BigSegmentStore()` (same `StoreBuilder[T]`) | `BigSegmentStore(tableName)` | **not supported** | **not supported** | D\* |
| TLS | `rediss://` URL scheme | AWS SDK default | — | `rediss://` URL scheme | D |
| Password / DB number | in the `redis://` URL, or `.DialOptions(redigo.DialPassword(...))` | — | — | in the `redis://` URL | D (URL) / C (dial options) |
| Connection pool | `.Pool(*redigo.Pool)` / `.PoolInterface(Pool)` — **overrides `URL`/`HostAndPort`** | `.DynamoClient(*dynamodb.Client)` — overrides config/options | `.Config(consul.Config)` — overwrites prior settings | — | C |
| Client/region options | — | `.ClientConfig(aws.Config, optFns...)`, `.ClientOptions(dynamodb.Options, optFns...)` (mutually exclusive: `ClientOptions` clears `awsConfig`) | — | — | C (region/endpoint themselves are D) |
| Raw dial options | `.DialOptions(...redigo.DialOption)` — **replaces** | — | — | — | C |

DynamoDB relies on the AWS SDK's own env-var resolution (`AWS_REGION`, `AWS_ACCESS_KEY_ID`, …) — the only substantial env-var-driven config in the Go ecosystem.

---

## 12. Other / AI config

| Option | Go | Rust |
|---|---|---|
| AI config | The in-repo `ldai` package is **a stub**: it has moved to `github.com/launchdarkly/go-server-sdk-ai` (`ldai` at v0.10.0+). No config surface remains in `go-server-sdk`. | **not supported** |
| OpenTelemetry hook | `ldotel.NewTracingHook(ldotel.WithSpans(), WithVariant(), WithValue(), WithEnvironmentID(id))` — separate Go module (`ldotel/go.mod`); passed via `Config.Hooks`. Options: spans off, variant off, value off, environment ID unset by default | **not supported** |
| HTTP middleware | `ldmiddleware` — separate Go module | — |
| Migrations | `ld.Migrator(...)` builder (`migrator_builder.go`): read execution order, latency/error tracking, check ratio — per-migrator, not SDK config | `MigratorBuilder::read_execution_order(ExecutionOrder)`, `.track_latency(bool)`, `.track_errors(bool)`, `.read(...)`, `.write(...)` — per-migrator |
| all-flags-state filter | `ldclient.AllFlagsState(ctx, options ...FlagsStateOption)` | `FlagDetailConfig` / `FlagFilter` in `evaluation.rs` — per-call, not config |

---

## 13. Environment-variable support

Neither SDK reads any `LD_*` environment variable for configuration. Exhaustive results of `os.Getenv`/`os.LookupEnv` (Go) and `std::env`/`env::var` (Rust):

| SDK | Location | Variable | Purpose |
|---|---|---|---|
| Go | `ldcomponents/http_configuration_builder.go:216` (`isProxyEnabled`) | `HTTP_PROXY` | **Diagnostics only** — reported as `usingProxy` in the diagnostic payload; does not configure anything |
| Go | Go stdlib `net/http` (`ProxyFromEnvironment`, reached through the default transport) | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` | Actual proxy selection unless `ProxyURL`/`HTTPClientFactory` overrides |
| Go | `testservice/service.go:63, 259` | arbitrary, `LD_LOG_LEVEL` | **Contract-test harness only**, not the SDK |
| Go | `go-server-sdk-dynamodb` (via AWS SDK) | `AWS_REGION`, `AWS_*` credentials | AWS client resolution |
| Rust | `launchdarkly-sdk-transport` `HyperTransportBuilder::auto_proxy()` (the default) | `http_proxy`/`HTTP_PROXY`, `https_proxy`/`HTTPS_PROXY`, `no_proxy`/`NO_PROXY` | Proxy selection; lowercase takes precedence. If only `HTTP_PROXY` is set, **all** requests (including HTTPS) use it |
| Rust | — | none in the SDK crate itself | `grep` for `std::env`/`env::var` in `launchdarkly-server-sdk/src` returns nothing |

Practical consequence for a declarative-config spec: there is **no existing `LD_`-prefixed env-var convention to preserve in either SDK**, so the spec is free to define one. The only collision risk is the standard proxy variables.

---

## 14. Deprecated options

| SDK | Option | Status |
|---|---|---|
| Go | `StreamingDataSourceBuilderV2.PayloadFilter(k)` | Marked `Deprecated:`; logs "Payload filtering is not supported with the FDv2 data system; the configured payload filter will stop being applied in a future release"; will be removed |
| Go | `PollingDataSourceBuilderV2.PayloadFilter(k)` | Same |
| Go | `ldfiledata.DuplicateKeysIgnoreAllButFirst` | Marked `Deprecated:`; alias of `DuplicateKeysKeepFirst` (both are the string `"ignore"`). Same in `ldfiledatav2` |
| Go | `PersistentDataStoreBuilder.CacheTime` / `CacheSeconds` / `CacheForever` / `NoCaching` | Soft-deprecated: "retained for backward compatibility and may be deprecated in a future major version" (no-ops in practice under FDv2 after initialization) |
| Go | `lddynamodb.StoreBuilder.DescribeConfiguration()` (no-arg form) | Maintainer comment: deprecated, to be changed to take a `ClientContext` in the next major (SDK-2925) |
| Go | `ldcomponents.DefaultEventsBaseURI` / `DefaultPollingBaseURI` / `DefaultStreamingBaseURI` constants | Not formally deprecated, but doc-referenced to builder methods (`[EventProcessorBuilder.BaseURI]`, `[PollingDataSourceBuilder.BaseURI]`) **that no longer exist** — the builders lost their `BaseURI` methods in favor of `Config.ServiceEndpoints` |
| Rust | none marked `#[deprecated]` | — |
| Rust | `data_sources` module | "experimental and not subject to semantic versioning" |
| Go | `Config.Plugins` | "Plugin support is currently experimental and subject to change" |

---

## 15. Validation / clamping summary

| Rule | Go | Rust |
|---|---|---|
| Poll interval minimum | 30s, **silently raised** (`if pollInterval < DefaultPollInterval { = DefaultPollInterval }`); FDv2 variant uses `max(...)` | 30s in FDv1 `PollingDataSourceBuilder` (`std::cmp::max`); **FDv2 `FDv2PollingBuilder::poll_interval` does not clamp** despite its doc comment |
| Streaming initial reconnect delay | `<= 0` → reset to 1s default | no clamping |
| Connect timeout | `<= 0` → reset to 3s default (checked twice: in the setter and again in `Build`) | no clamping; no default timeout at all |
| Big segments status poll interval | `<= 0` → reset to 5s | n/a |
| Diagnostic recording interval | raised to ≥ 60s | n/a |
| Payload filter key | empty string → `Build()` error (FDv1 streaming/polling, FDv1-v2 polling). The **deprecated** FDv2 setters skip this check | n/a |
| Service endpoints | partial set → `Error`-level log + defaults for the missing one | partial set → hard `BuildError` |
| Application tags | ≤64 chars, `[A-Za-z0-9._-]` only; invalid → discarded + warning | same, plus non-empty key and value required; invalid → discarded + warning |
| SDK key | chars must be in `[32,127]`, else `MakeCustomClient` error | not validated |
| Store prefix | Redis/Consul: empty → `"launchdarkly"`; DynamoDB: empty allowed | Redis: empty allowed (no re-defaulting) |
| Redis URL | empty → default URL | invalid URL → `create_persistent_data_store` returns `io::Error` |
| Data system nil slots | `Initializers`/`Synchronizers` with a nil element → `Build` error `"initializer %d is nil"` / `"synchronizer %d is nil"` | type system prevents it |
| Event capacity / flush interval | unvalidated | unvalidated; `context_keys_capacity` is `NonZeroUsize` |
| init wait | `waitFor > 60s` → warning "We recommend blocking no longer than %v milliseconds" | n/a |

---

## 16. Notable divergences and oddities

1. **Event buffer capacity differs by 20×.** Go defaults to **10 000** events; Rust to **500**. This is the single largest cross-SDK default mismatch found here and will need an explicit spec decision.
2. **Event gzip default is inverted.** Go `EnableGzip` defaults to `false`; Rust `compress_events` defaults to `true` (because `event-compression` is a default Cargo feature). A declarative spec that omits the key would produce different wire behavior on the two SDKs today. Rust's setter also *only exists* when the Cargo feature is enabled, so the key is unrepresentable in some builds.
3. **Rust has no HTTP configuration object.** Timeouts, proxy, and TLS are properties of a `launchdarkly_sdk_transport::HyperTransport` that must be constructed in code and injected into each component builder individually (`StreamingDataSourceBuilder::transport`, `PollingDataSourceBuilder::transport`, `EventProcessorBuilder::transport`, `FDv2*Builder::transport`). There is no single place to set "connect timeout" for the whole SDK, and a declarative spec would need the Rust SDK to grow one. Rust also has **no default connect/read/write timeout at all**, versus Go's 3s.
4. **Rust TLS/crypto backend is a compile-time Cargo feature**, not runtime config (`hyper-rustls-native-roots` | `hyper-rustls-webpki-roots` | `native-tls`; `crypto-aws-lc-rs` | `crypto-openssl`). Custom CA certs are only reachable in Go (`CACert`/`CACertFile`). If no TLS feature is on, `Config::build()` *fails* unless you inject your own data source and event processor.
5. **Two conflicting "default polling base URI" constants in Go.** `internal/endpoints.DefaultPollingBaseURI = "https://sdk.launchdarkly.com/"` (used by FDv1) vs `ldcomponents.DefaultPollingBaseURI = "https://app.launchdarkly.com"` (used by the FDv2 `DataSystem()` modes and all v2 polling builders). Looks like a latent bug.
6. **Go's FDv2 sources ignore `Config.ServiceEndpoints`.** `StreamingDataSourceBuilderV2`/`PollingDataSourceBuilderV2`/`FDv1PollingDataSourceBuilderV2` read only their own `baseURI`, so relay-proxy/private-instance URIs must be re-specified via `DataSystem().WithEndpoints(...)` or `.WithRelayProxyEndpoints(...)`. Rust's FDv2 builders correctly fall back to `ServiceEndpoints`. A single declarative `serviceEndpoints` block would behave differently on the two SDKs.
7. **Partial endpoint specification: warn vs. error.** Go logs an `Error` and quietly uses defaults for unspecified URIs (with an opt-out, `WithPartialSpecification()`); Rust hard-fails the build. Go additionally has `RelayProxyEndpointsWithoutEvents`, which Rust lacks.
8. **Daemon mode is modeled completely differently.** Rust has a first-class `ConfigBuilder::daemon_mode(bool)`; Go expresses it as a data-source/data-system choice (`ExternalUpdatesOnly()` / `DataSystem().Daemon(store)`). Rust's daemon mode leaves events *on*, while Go's `ExternalUpdatesOnly` also unconditionally reports the data source as `Valid`.
9. **Rust is missing four whole feature areas** that Go has: Big Segments, hooks, plugins, and diagnostic events. Rust's `EventProcessorBuilder` even carries a commented-out `// diagnostic_recording_interval: Duration` field. Any spec sections for these will be Go-only (and, for Rust, must degrade gracefully / warn on unknown keys).
10. **Logging is entirely out of scope for Rust.** Rust uses the `log` facade, so there is no `minLevel`, no `NoLogging`, and no `logEvaluationErrors`/`logContextKeyInErrors`/`logDataSourceOutageAsErrorAfter`. Go's `Logging()` builder has all five. A declarative `logging.level` key cannot be honored by Rust without adding a level filter.
11. **Payload filtering is Go-only, and is being removed from FDv2.** `PayloadFilter` exists on Go's FDv1 streaming/polling builders (validated non-empty) and is `Deprecated` on the FDv2 builders with a warning that it will stop being applied. Rust never supported it. A spec `payloadFilterKey` key is effectively FDv1-Go-only.
12. **Clamping is silent and inconsistent.** Go silently raises a sub-30s poll interval and silently resets non-positive timeouts/delays to defaults; Rust clamps the FDv1 poll interval but *not* the FDv2 one (contradicting its own doc comment) and never clamps reconnect delay. A declarative spec should state whether out-of-range values are clamped, warned about, or rejected.
13. **`privateAttributes` and Go's `FilePaths` have opposite list semantics.** `PrivateAttributes(...)` / `private_attributes(...)` **replace** on each call, while `ldfiledata.FilePaths(...)` **appends**. Likewise Go's `Initializers`/`Synchronizers` replace while Rust's `initializer`/`synchronizer` append. Declarative lists should be unambiguous.
14. **Persistent-store caching is close to a no-op under FDv2 in Go**, and is documented as such; in Rust it is still fully meaningful. The identical `cacheTime` key therefore means different things.
15. **Go allows custom headers to override `Authorization` and `User-Agent`** ("For consistency with other SDKs"), which makes `http.headers` a security-relevant key. Rust has no custom-header support at all.
16. **SDK key placement differs.** Go takes it as a positional argument to `MakeClient` and never stores it in `Config`; Rust requires it in `ConfigBuilder::new`. A file-based spec must decide whether `sdkKey` lives in the document (and Go's `Config` would need a new field).
17. **Instance ID is auto-generated and deliberately non-configurable** in both (v4 UUID per client, sent as `X-LaunchDarkly-Instance-Id` for connection-minutes accounting). It should be excluded from the spec.
18. **FDv2 fallback/recovery timeouts are hardcoded in both**, and at *different* values: Go uses 10s/1min/5min outage thresholds with a 10s status ticker; Rust uses `DEFAULT_FALLBACK_TIMEOUT = 120s` and `DEFAULT_RECOVERY_TIMEOUT = 300s`. Neither exposes a setter, so they cannot be expressed today.
19. **Go's Redis/DynamoDB/Consul "escape hatch" options silently invalidate the data-shaped ones.** `ldredis.Pool()`/`PoolInterface()` cause `URL`/`HostAndPort` to be ignored; `lddynamodb.DynamoClient()` causes `ClientConfig`/`ClientOptions` to be ignored; `ldconsul.Config()` overwrites everything set before it. Declarative config should only expose the data-shaped subset (URL, prefix, table, address).
20. **Rust's Redis integration repo is private** (`launchdarkly/rust-server-sdk-redis`) and the published crate is still `1.0.0-rc.1`, with only `url` and `prefix` — no DynamoDB, Consul, or big-segment store exists for Rust.
21. **Go ships two parallel copies of several builders** (`ldfiledata` / `ldfiledatav2`, `ldtestdata` / `ldtestdatav2`, polling/streaming v1 / v2 / FDv1-v2) with identical option names but different `Build` return types. Any spec mapping must disambiguate by data-source generation, not by option name alone.
22. **`ldcomponents` exports default-URI constants whose doc links point at builder methods that no longer exist** (`[EventProcessorBuilder.BaseURI]`, `[PollingDataSourceBuilder.BaseURI]`, `[StreamingDataSourceBuilder.BaseURI]`). Dead documentation, but a hint that per-source base URIs used to be configurable in Go's FDv1 path and were consolidated into `ServiceEndpoints`.
23. **Go AI configs have left the repo** — `ldai` is now `github.com/launchdarkly/go-server-sdk-ai`; Rust has no AI SDK. No AI config surface to specify for either SDK.
24. **Go exposes a LaunchDarkly-internal config field**, `Config.LDRelayDataDestination`, explicitly marked "for use by LaunchDarkly only. External use outside of the Relay Proxy is not supported." It must be excluded from any public spec.
