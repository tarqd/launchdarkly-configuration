# Server-side SDK configuration survey: Erlang/Elixir, C/C++, Haskell

Research for the cross-SDK declarative (file + env var) configuration spec.

Sources (shallow clones, `scratchpad/`):

| SDK | Repo | Version surveyed | Primary config file |
| --- | --- | --- | --- |
| Erlang/Elixir | `launchdarkly/erlang-server-sdk` | 3.11.2 | `src/ldclient_config.erl` |
| C++ server (current) | `launchdarkly/cpp-sdks` | `launchdarkly-cpp-server` 3.13.1 | `libs/server-sdk/include/launchdarkly/server_side/config/**`, `libs/common/include/launchdarkly/config/shared/**` |
| C server (legacy, EOL-ish) | `launchdarkly/c-server-sdk` | 2.9.3 | `include/launchdarkly/config.h`, `src/config.c`, `src/config.h` |
| Haskell | `launchdarkly/haskell-server-sdk` | 4.6.0 | `src/LaunchDarkly/Server/Config.hs`, `Config/Internal.hs` |

## 0. Shape of each config surface (read this first)

| Aspect | Erlang | C++ (cpp-sdks) | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Surface | **Single flat map** of atom keys passed to `ldclient:start_instance(SdkKey, Tag, Options)`; unknown keys are silently ignored; defaults applied by `ldclient_config:parse_options/2` | **Nested fluent builders**: `ConfigBuilder` → `ServiceEndpoints()`, `Events()`, `DataSystem()`, `HttpProperties()`, `Logging()`, `AppInfo()`, `BigSegments()`, `Hooks()`, `Offline()`; `Build()` returns `tl::expected<Config, Error>` | **Flat opaque struct** + `LDConfigSet*` setters on `struct LDConfig` | **Flat record + setter functions** `configSetX :: v -> Config -> Config`, composed over `makeConfig key` |
| Nesting | flat (2 nested sub-maps: `http_options`, `application`) | deep (up to 4 levels: `DataSystem().Method(FDv2).Synchronizer(Streaming().InitialReconnectDelay(...))`) | flat | flat (1 nested opaque: `ApplicationInfo`) |
| Validation | mostly none; two clamps + tag validation (see §10) | `tl::expected` errors at `Build()`; several silent coercions | `LDBoolean` return + `LD_LOG_WARNING`, no range checks | almost none; one guard (`configSetInitialRetryDelay`) |
| Data-expressible fraction | **very high** (only `feature_store`, `events_dispatcher`, `polling_update_requestor`, `testdata_tag` are code/module refs — and even those are atoms, i.e. data) | medium (stores, hooks, log backends, data readers are C++ objects) | medium (store backend, data source, logger are pointers) | medium-low (logger, manager, store backend, data source factory are functions) |
| Instance identity | **multi-instance via `Tag` atom** (`default`); settings live in app env `ldclient.instances :: #{Tag => instance()}` | one `Client` object per config | one `LDClient` (also `LDClientInit` per process) | one `Client` value per `makeClient` |

---

## 1. Credential / mode

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| SDK key | `sdk_key` — `string()` (charlist!). **Positional arg** to `start_instance/1,2,3`, not a map key; injected into the settings map | `ConfigBuilder(std::string sdk_key)` ctor arg. Empty ⇒ `Error::kConfig_SDKKey_Empty` at `Build()` | `LDConfigNew(const char* key)`; `NULL` ⇒ `NULL` config | `makeConfig :: Text -> Config`; `configSetKey :: Text` |
| Offline | `offline` bool, default `false`. Forces the null update processor (`ldclient_update_null_server`); `initialized/1` returns `true`; events still gated separately by `send_events` | `ConfigBuilder::Offline(bool)`, default `false`. At `Build()` it is **expanded** into `Events().Disable()` + `DataSystem().Disable()` and *overrides* explicit settings; not stored as its own field on `Config` | `LDConfigSetOffline(bool)`, default `LDBooleanFalse` | `configSetOffline`, default `False`. `shouldSendEvents = not offline && sendEvents`; data source becomes `nullDataSourceFactory` |
| Daemon mode (LDD / relay daemon) | `use_ldd` bool, default `false` → null update processor; also suppresses pre-creating `features`/`segments` Redis buckets (`ldclient_storage_redis:init/3`) | **no `use_ldd` flag** — replaced by `DataSystem().Method(LazyLoad)` (read-only external store) | `LDConfigSetUseLDD(bool)`, default `false` | `configSetUseLdd`, default `False` → null data source |
| Send events (analytics only) | `send_events` bool, default `true` | `Events().Enabled(bool)` / `Events().Disable()`, default enabled `true` | `LDConfigSetSendEvents(bool)`, default `true` | `configSetSendEvents`, default `True` |
| Data system disable | `datasource => undefined \| poll \| stream \| file \| testdata` (see §3) | `DataSystem().Enabled(bool)` / `.Disable()`, default enabled | n/a (implied by `offline`/`useLDD`) | n/a |

## 2. Service endpoints / URIs

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Polling / base URI | `base_uri`, `string()`, default `"https://sdk.launchdarkly.com"`; **trailing `/` trimmed** | `ServiceEndpoints().PollingBaseUrl(std::string)`, default `"https://sdk.launchdarkly.com"`; trailing slashes trimmed | `LDConfigSetBaseURI`, default **`"https://app.launchdarkly.com"`** (legacy value); single trailing slash trimmed | `configSetBaseURI :: Text`, default `"https://sdk.launchdarkly.com"`; trailing `/` dropped |
| Streaming URI | `stream_uri`, default `"https://stream.launchdarkly.com"`; trailing `/` trimmed | `ServiceEndpoints().StreamingBaseUrl`, default `"https://stream.launchdarkly.com"` | `LDConfigSetStreamURI`, default same | `configSetStreamURI`, default same |
| Events URI | `events_uri`, default `"https://events.launchdarkly.com"`; trailing `/` trimmed | `ServiceEndpoints().EventsBaseUrl`, default `"https://events.launchdarkly.com"` | `LDConfigSetEventsURI`, default same | `configSetEventsURI`, default same |
| Relay-proxy convenience (one URL for all three) | ✗ | `ServiceEndpoints().RelayProxyBaseURL(url)` — sets all three | ✗ | ✗ |
| All-or-nothing rule | none (each independent) | **yes**: if any one of the three is set, all three must be set, else `Error::kConfig_Endpoints_AllURLsMustBeSet`; empty string ⇒ `kConfig_Endpoints_EmptyURL` | none | none |
| Path components (streaming `/all`, polling `/sdk/latest-all`, events `/bulk`) | hardcoded in the update/event servers | **configurable in the built structs but not via the public builder** (`Defaults<ServerSDK>`: `"/all"`, `"/sdk/latest-all"`, `"/bulk"`) | hardcoded | hardcoded |

## 3. Data source: stream vs poll, intervals, filters

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Stream vs poll selector | `stream` bool, default `true`. Resolution order in `ldclient_instance:get_update_processor/1`: `offline` → `use_ldd` → `datasource` → `file_datasource` → `stream` | `DataSystem().Method(BackgroundSync().Synchronizer(Streaming()\|Polling()))`; default method = BackgroundSync with **Streaming** | `LDConfigSetStream(bool)`, default `true` | `configSetStreaming :: Bool`, default `True` |
| Poll interval | `polling_interval`, **seconds**, default & minimum **30**; clamped via `lists:max([30, V])` at parse time. Multiplied by 1000 in `ldclient_update_poll_server` | `BackgroundSync().Synchronizer(Polling().PollInterval(std::chrono::seconds))`, default **30 s**; `min_polling_interval` 30 s enforced **at data-source construction** with a warn log, not in the builder. FDv2 `Polling().PollInterval(seconds)` default 30 s | `LDConfigSetPollInterval(unsigned ms)`, default **30000 ms**; no clamping | `configSetPollIntervalSeconds :: Natural`, default **30**; **no clamping anywhere** |
| Stream initial reconnect delay | `stream_initial_retry_delay_ms`, **ms**, default `1000`; exponential backoff capped at `?MAX_BACKOFF_DELAY = 30000` ms | `Streaming().InitialReconnectDelay(std::chrono::milliseconds)`, default **1000 ms**; FDv2 `Streaming()` default also 1000 ms | ✗ (not configurable) | `configSetInitialRetryDelay :: Int` — **ms** despite the parameter being named `seconds`; default `1_000`; `<= 0` is a **silent no-op**; backoff capped at 30 s in `Streaming.hs` |
| Payload filter key | ✗ | `Streaming().Filter(key)` / `Polling().Filter(key)` (server-only, SFINAE-gated). **Oddity:** `FDv2Builder::Streaming`/`Polling` have a private `filter_key_` member with **no public setter** | ✗ | ✗ |
| File data source | `file_datasource` bool `false`; `file_paths` list of string/binary, default `[]`; `file_auto_update` bool `false`; `file_poll_interval` **ms** default `1000`; `file_allow_duplicate_keys` bool `false` | ✗ (no file data source) | `LDFileDataInit(int fileCount, const char** filenames)` → `LDConfigSetDataSource` (no auto-update / dup-key knobs) | `FileData.dataSourceFactory [FilePath]` → `configSetDataSourceFactory` (no auto-update / dup-key knobs) |
| Test data source | `datasource => testdata` + `testdata_tag` atom (default `default`) | `ITestData`-style not in config; contract-test only | `LDTestDataInit()` → `LDConfigSetDataSource` | `TestData.dataSourceFactory` → `configSetDataSourceFactory` |
| Pluggable data source | `datasource` atom → module `ldclient_update_<name>_server`; `polling_update_requestor` atom, default `ldclient_update_requestor_httpc` | data system variants only | `LDConfigSetDataSource(struct LDDataSource*)` (ownership transferred) | `configSetDataSourceFactory :: Maybe DataSourceFactory` (code-only) |
| FDv2 / changeset protocol | ✗ | **Unique to C++.** `DataSystem().Method(FDv2::Default()\|FDv2::Custom())` with ordered `Initializer(Polling)` list, ordered `Synchronizer(Streaming\|Polling)` list (first = primary, rest = fallbacks), `FDv1Fallback(FDv1Streaming\|FDv1Polling)` / `DisableFDv1Fallback()`, `FallbackTimeout(ms)` default **2 min**, `RecoveryTimeout(ms)` default **5 min** | ✗ | ✗ |
| Bootstrap / data destination | ✗ | `BackgroundSync().Bootstrapper()` and `.Destination(DataDestinationBuilder)` exist but are **stubs**: `Defaults::BootstrapConfig()` and `DataDestinationConfig()` both return `std::nullopt` and the builders expose no setters | ✗ | ✗ |
| Init wait / start timeout | ✗ — `start_instance` returns immediately; poll `ldclient:initialized(Tag)` | ✗ in config; `Client::StartAsync()` returns `std::future<bool>`, caller applies its own `wait_for` | **`LDClientInit(config, unsigned maxwaitmilli)`** — the timeout is an *argument to init*, not config | ✗ — `makeClient` returns immediately; poll `getStatus` |

## 4. Events

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Capacity | `events_capacity`, default **10000** | `Events().Capacity(std::size_t)`, default **10000**; `0` ⇒ `Error::kConfig_Events_ZeroCapacity` | `LDConfigSetEventsCapacity(unsigned)`, default **10000** | `configSetEventsCapacity :: Natural`, default **10000** |
| Flush interval | `events_flush_interval`, **ms**, default **30000** | `Events().FlushInterval(std::chrono::milliseconds)`, default **5 s** | `LDConfigSetFlushInterval(unsigned ms)`, default **5000** | `configSetFlushIntervalSeconds :: Natural`, **seconds**, default **5** |
| All attributes private | ✗ as a bool — expressed as `private_attributes => all` | `Events().AllAttributesPrivate(bool)`, default `false` | `LDConfigSetAllAttributesPrivate(bool)`, default `false` | `configSetAllAttributesPrivate :: Bool`, default `False` |
| Private attributes | `private_attributes :: all \| [binary() \| attribute_reference()]`, default `[]`; binaries are converted via `ldclient_attribute_reference:new/1` | `Events().PrivateAttributes(AttributeReference::SetType)` (replaces) and `Events().PrivateAttribute(AttributeReference)` (appends), default empty set | `LDConfigAddPrivateAttribute(const char*)` (append only), default empty JSON array | `configSetPrivateAttributeNames :: Set Reference`, default `mempty` |
| Context-key dedup capacity | `context_keys_capacity`, default **1000** | `Events().ContextKeysCapacity(std::size_t)`, default **1000** (`std::optional`; `nullopt` for client-side) | `LDConfigSetUserKeysCapacity(unsigned)`, default **1000** | `configSetContextKeyLRUCapacity :: Natural`, default **1000**; **deprecated alias** `configSetUserKeyLRUCapacity` |
| Context-key cache flush interval | ✗ | ✗ | `LDConfigSetUserKeysFlushInterval(unsigned ms)`, default **300000** (5 min) | ✗ |
| Inline users in events | ✗ | ✗ | `LDConfigInlineUsersInEvents(bool)`, default `false` — **deprecated concept**, removed everywhere else | ✗ |
| Gzip event payloads | ✗ | ✗ | ✗ | `configSetCompressEvents :: Bool`, default **`False`** (kept false for old Relay Proxy compat) |
| Omit anonymous contexts from index/identify | ✗ | ✗ | ✗ | `configSetOmitAnonymousContexts :: Bool`, default `False` |
| Delivery retry delay | hardcoded | present in `built::Events` (**1 s** default) but **no builder setter** | hardcoded | hardcoded |
| Flush workers | hardcoded | present in `built::Events` (**5** default) but **no builder setter** | hardcoded | hardcoded |
| Event dispatcher override | `events_dispatcher` atom, default `ldclient_event_dispatch_httpc` (test hook) | ✗ | ✗ | ✗ |
| Diagnostics (`enableDiagnostics`, `diagnosticRecordingInterval`) | **✗ not implemented** | **✗ not implemented** (the contract-test data model accepts `enableDiagnostics` but nothing consumes it) | ✗ | ✗ |

## 5. HTTP / networking / TLS

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Grouping | nested `http_options => #{tls_options, connect_timeout, custom_headers}` | `HttpProperties()` builder + nested `Tls(TlsBuilder)` and `Proxy()` | flat | flat / none |
| Connect timeout | `http_options.connect_timeout`, **ms**, default **2000** | `HttpProperties().ConnectTimeout(ms)`, default **10 s** | `LDConfigSetTimeout(unsigned ms)`, default **5000** (single generic timeout) | ✗ |
| Read timeout | ✗ | `ReadTimeout(ms)`, default **10 s** | ✗ | ✗ |
| Write timeout | ✗ | `WriteTimeout(ms)`, default **10 s** | ✗ | ✗ |
| Response timeout | ✗ | `ResponseTimeout(ms)`, default **10 s** | ✗ | `configSetRequestTimeoutSeconds :: Natural`, **seconds**, default **30** (maps to `responseTimeoutMicro`) |
| Custom headers | `http_options.custom_headers :: [{string(), string()}] \| undefined`, default `undefined`; appended to default headers | `Headers(std::map<string,string>)` (replace) and `Header(key, std::optional<value>)` (`nullopt` removes); default empty map | ✗ | ✗ |
| Proxy | ✗ (inherits `httpc`/`gun` behaviour) | `Proxy(std::optional<std::string> url)`: `nullopt` = honour `ALL_PROXY`/`HTTP_PROXY`/`HTTPS_PROXY`; non-empty = explicit URL (wins over env); `""` = **explicitly disable proxy**. Throws `std::runtime_error` if built without `LD_CURL_NETWORKING` | ✗ | ✗ (inherits `http-client` `tlsManagerSettings`) |
| TLS peer verification | via full `tls_options :: [ssl:tls_client_option()]` (default `undefined` ⇒ SDK picks; see helpers below) | `Tls(TlsBuilder().SkipVerifyPeer(bool))`, default `kVerifyPeer` | ✗ | ✗ |
| Custom CA file | `ldclient_config:tls_ca_certfile_options(Path)` helper | `Tls(TlsBuilder().CustomCAFile(path))`; `""` clears back to system store | ✗ | ✗ |
| TLS helper presets (**unique to Erlang**) | `tls_basic_options/0` (OTP ≥ 25 → `public_key:cacerts_get()`; else `/etc/ssl/certs/ca-certificates.crt` if present, else bundled `certifi` with a warning), `tls_basic_linux_options/0`, `tls_basic_certifi_options/0`, `tls_basic_erlef_options/0`, `tls_ca_certfile_options/1`, `with_tls_revocation/1` (adds `crl_check` + `ssl_crl_cache`). Base options pin `verify_peer`, `depth 3`, filtered ECDHE cipher suites, TLS 1.2/1.3 (1.2 only on OTP < 23), hostname check fun | ✗ | ✗ | ✗ |
| Custom HTTP client object | ✗ (module swap via `polling_update_requestor`) | ✗ | ✗ | `configSetManager :: Manager -> Config -> Config` (code-only; wraps in `Just`) |
| Wrapper name / version | ✗ | `HttpProperties().WrapperName(std::string)`, `WrapperVersion(std::string)`, defaults `""` | `LDConfigSetWrapperInfo(name, version)` — "if version set, name must be set" | ✗ |

## 6. Persistent stores / feature stores

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Store selection | `feature_store :: atom()`, default `ldclient_storage_ets`; also `ldclient_storage_map`, `ldclient_storage_redis` (in-tree; Redis layers `ldclient_storage_cache` on top) | `DataSystem().Method(LazyLoad().Source(SourcePtr))` where `SourcePtr = std::shared_ptr<ISerializedDataReader>` | `LDConfigSetFeatureStoreBackend(struct LDStoreInterface*)`, default `NULL` (in-memory) | `configSetStoreBackend :: Maybe PersistentDataStore`, default `Nothing` |
| Cache TTL | `cache_ttl :: integer()`, **seconds**, default **15**. `0` = "testing mode" (always miss, always hit backend); **negative = infinite TTL** | `LazyLoad().CacheRefresh(std::chrono::milliseconds)`, default **5 min** | `LDConfigSetFeatureStoreBackendCacheTTL(unsigned ms)`, default **30000** | `configSetStoreTTL :: Natural`, **seconds**, default **10** |
| Cache eviction policy | ✗ | `LazyLoad().CacheEviction(EvictionPolicy)`; only `Disabled` (0) exists — stale items are served until refreshable | ✗ | ✗ |
| Store required | n/a | `LazyLoad` without a `Source` ⇒ `Error::kConfig_DataSystem_LazyLoad_MissingSource` | n/a | n/a |
| Redis: host | `redis_host`, default `"127.0.0.1"` | via URI (below) | `LDRedisConfigSetHost`, default `"127.0.0.1"` | via `hedis` `Connection` (built by the app) |
| Redis: port | `redis_port`, default **6379** | via URI | `LDRedisConfigSetPort(unsigned short)`, default **6379** | via `Connection` |
| Redis: database | `redis_database :: integer()`, default **0** | via URI | ✗ | via `Connection` |
| Redis: username | `redis_username :: string() \| undefined`, default `undefined` | via URI | ✗ | via `Connection` |
| Redis: password | `redis_password`, default `""` | via URI | ✗ | via `Connection` |
| Redis: key prefix | `redis_prefix`, default **`"launchdarkly"`** | `RedisDataSource::Create(uri, prefix)` 2nd arg | `LDRedisConfigSetPrefix`, default **`"launchdarkly"`** | `redisConfigSetNamespace :: Text`, default **`"launchdarkly"`** (`makeRedisStoreConfig con`) |
| Redis: TLS | `redis_tls :: [ssl:tls_option()] \| undefined`, default `undefined` (appended as eredis `{tls, Opts}`) | via URI (`rediss://…`, Redis++ semantics) | ✗ | via `Connection` |
| Redis: pool size | ✗ | via URI | `LDRedisConfigSetPoolSize(unsigned)`, default **10** | via `Connection` |
| Redis: URI/DSN style | ✗ (discrete fields) | **`RedisDataSource::Create(std::string uri, std::string prefix)`** — whole connection expressed as a Redis++ URI | ✗ | ✗ |
| Other stores | Redis only in-tree (no Postgres/DynamoDB module in this repo despite community wrappers) | `server-sdk-redis-source`, `server-sdk-dynamodb-source` (`DynamoDBClientOptions{region, endpoint, aws_access_key_id, aws_secret_access_key, aws_session_token}`, all `std::optional` falling back to the AWS provider chain; table name + prefix are `Create` args) | Redis only | `haskell-server-sdk-redis-hedis` only |

## 7. Big segments

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Enable | ✗ | `ConfigBuilder::BigSegments(BigSegmentsBuilder(store))` — **opt-in by presence**; if never called, big-segment flags evaluate as non-member | ✗ | ✗ |
| Store | — | `BigSegmentsBuilder(std::shared_ptr<IBigSegmentStore>)`; null ⇒ `Error::kConfig_BigSegments_NullStore`. Impls: `RedisBigSegmentStore::Create(uri, prefix)`, `DynamoDBBigSegmentStore` | — | — |
| Context cache size | — | `ContextCacheSize(std::size_t)`, default **1000** | — | — |
| Context cache TTL | — | `ContextCacheTime(ms)`, default **5 s**; `<= 0` **silently coerced to default** | — | — |
| Status poll interval | — | `StatusPollInterval(ms)`, default **5 s**; `<= 0` coerced to default; **clamped at `Build()` to `min(poll, stale_after)`** | — | — |
| Stale after | — | `StaleAfter(ms)`, default **2 min**; `<= 0` coerced to default | — | — |

## 8. Application info / tags

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Grouping | nested map `application => #{id => binary(), version => binary()}`, default `undefined` | `AppInfo()` builder | ✗ | opaque `ApplicationInfo` via `configSetApplicationInfo` |
| App id | `application.id` | `AppInfo().Identifier(std::string)` → tag `application-id` | ✗ | `withApplicationValue "id" v makeApplicationInfo` |
| App version | `application.version` | `AppInfo().Version(std::string)` → tag `application-version` | ✗ | `withApplicationValue "version" v` |
| Arbitrary tags | ✗ | `AppInfo().AddTag(key, value)` — **generic** | ✗ | only keys `"id"`/`"version"` accepted; others silently ignored |
| Validation | ≤ 64 bytes, non-empty, `[A-Za-z0-9._-]` only; invalid ⇒ `error_logger:warning_msg` and the key is **dropped** | same char/length rules (`kMaxTagValueLength = 64`); invalid tags dropped at `Build()` — reporting is a **TODO (sc-204388)** | — | ≤ 64 chars, non-empty, same char set; invalid ⇒ silently ignored |
| Wire format | `x-launchdarkly-tags: application-id/foo application-version/1.0` (sorted by key, values sorted) | same header, sorted | — | same header, sorted by key |

## 9. Logging, hooks, plugins, misc

| Option | Erlang | C++ | C (legacy) | Haskell |
| --- | --- | --- | --- | --- |
| Logging config | **✗ none** — uses OTP `error_logger` / `logger` directly; verbosity controlled entirely by the host app's `kernel`/`logger` config | `Logging()` builder: `Logging(BasicLogging().Level(LogLevel).Tag(std::string))`, `Logging(CustomLogging().Backend(shared_ptr<ILogBackend>))`, `Logging(NoLogging())`. Defaults: level `kInfo`, tag `"LaunchDarkly"`. C binding: `LDServerConfigBuilder_Logging_Disable` | `LDConfigureGlobalLogger(LDLogLevel, fnptr)` — **process-global, not per-config**; levels `LD_LOG_FATAL..LD_LOG_TRACE`; `LDBasicLogger` deprecated in favour of `LDBasicLoggerThreadSafe` (+ `Initialize`/`Shutdown`) | `configSetLogger :: (LoggingT IO () -> IO ()) -> Config`, default `runStdoutLoggingT` (code-only) |
| Log level from env | — | **`LD_LOG_LEVEL`** — read by `LoggingBuilder::BasicLogging()`'s ctor via `std::getenv`; accepted values `debug`/`info`/`warn`/`error` (case-insensitive), unknown ⇒ default. **This is the only env-var-driven config option across all four SDKs.** | — | — |
| Hooks | ✗ | `ConfigBuilder::Hooks(std::shared_ptr<hooks::Hook>)` — additive; null pointers ignored. OTel tracing hook in `server-sdk-otel` with `TracingHookOptionsBuilder{IncludeValue(bool)=false, CreateSpans(bool)=false, EnvironmentId(optional<string>)}` | ✗ | ✗ |
| Plugins | ✗ | ✗ (hooks only) | ✗ | ✗ |
| Instance / naming | **`Tag :: atom()`, default `default`** — second positional arg to `start_instance`; namespaces supervisors (`ldclient_instance_<Tag>`, `..._stream_<Tag>`, `..._events_<Tag>`) and the settings registry | ✗ | ✗ | ✗ |
| Per-instance id | `instance_id` — **generated, not user-settable**: v4 UUID minted in `parse_options/2`, sent as `X-LaunchDarkly-Instance-Id` | ✗ | ✗ | generated in `makeHttpConfiguration` (`X-LaunchDarkly-Instance-Id`), not settable |
| Version/UA constants | `?USER_AGENT "ErlangClient"`, `?VERSION`, `?EVENT_SCHEMA "4"` — compile-time, exposed read-only | compile-time | compile-time | `"HaskellServerClient/<version>"`, event schema `4` |

## 10. Validation / clamping / coercion summary

| SDK | Rule |
| --- | --- |
| Erlang | `polling_interval` clamped up to ≥ 30 s (`lists:max`); `base_uri`/`events_uri`/`stream_uri` right-trimmed of `/`; `application.id`/`.version` validated (≤64 bytes, `[A-Za-z0-9._-]`, non-empty) and **dropped with a warning** if invalid; `private_attributes` binaries coerced into attribute references; `cache_ttl` sign-overloaded (0 = bypass, <0 = infinite). **No other validation** — unknown keys and bad types just propagate. |
| C++ | Hard errors at `Build()`: empty SDK key, empty endpoint URL, partial endpoint set, zero event capacity, null big-segment store, LazyLoad without source. Silent coercions: big-segment `ContextCacheTime`/`StatusPollInterval`/`StaleAfter` ≤ 0 → default; `StatusPollInterval` clamped to `min(poll, stale_after)`; polling interval clamped up to `min_polling_interval` (30 s) at data-source construction with a warn log; invalid app tags dropped silently (TODO to report); `Offline(true)` overrides explicit Events/DataSystem settings. |
| C (legacy) | Only null-pointer guards (`LD_ASSERT_API` + `LAUNCHDARKLY_DEFENSIVE` warn-and-return). URIs get **one** trailing slash trimmed. No numeric range checks at all — a 1 ms poll interval is accepted. |
| Haskell | `configSetInitialRetryDelay` ignores values ≤ 0 (no-op). URIs `dropWhileEnd (== '/')`. `withApplicationValue` silently ignores unknown keys and invalid values. `Natural`-typed fields make negatives unrepresentable, but **no minimum poll interval** and **no capacity > 0 check**. |

## 11. Existing file / app-env / environment-variable configuration (prior art)

### 11.1 Erlang/Elixir — OTP application environment

This is the closest thing to declarative config in the three SDK families, and it is worth being precise about what the SDK does and does not do.

**What the SDK actually does**

- `ldclient_app:start/2` calls `ldclient_config:init/0`, which does `application:set_env(ldclient, instances, #{})`.
- `ldclient_config:register(Tag, Settings)` / `unregister/1` / `get_value(Tag, Key)` / `get_registered_tags/0` read and write `application:get_env(ldclient, instances)`. So the **OTP application environment is used as the live per-instance config registry**, keyed by instance `Tag`.
- `{env, []}` in `src/ldclient.app.src` — the SDK ships **no** default app-env entries.
- There is **no** `application:get_env` call that reads user-authored configuration, and **no `os:getenv` anywhere in `src/`**. The SDK will not pick up options from `sys.config` / `config.exs` by itself; the host app must read them and pass the map to `ldclient:start_instance/3`.

**Why it is still strong prior art**

The option surface is *already a serialisable document*: a single flat map whose keys are atoms and whose values are scalars, booleans, lists of strings, atoms (module names), or two small nested maps. An Erlang `sys.config` fragment or an Elixir `config.exs` keyword list is a literal 1:1 transcription:

```erlang
%% sys.config
[{my_app, [{launchdarkly, #{
     sdk_key => "sdk-...",
     stream => false,
     polling_interval => 60,
     events_capacity => 5000,
     events_flush_interval => 10000,
     private_attributes => [<<"email">>, <<"/address/street">>],
     feature_store => ldclient_storage_redis,
     redis_host => "redis.internal", redis_port => 6379, redis_prefix => "ld",
     cache_ttl => 30,
     application => #{id => <<"payment-svc">>, version => <<"1.4.2">>},
     http_options => #{connect_timeout => 3000,
                       custom_headers => [{"x-corp-trace", "on"}]}
 }}]}].
```

```elixir
# config/config.exs
config :my_app, :launchdarkly, %{
  stream: false, polling_interval: 60, events_capacity: 5_000,
  application: %{id: "payment-svc", version: "1.4.2"}
}
# then: LaunchDarkly.start_instance(key, :default, Application.get_env(:my_app, :launchdarkly))
```

Lessons for the declarative spec:
1. **Flat + atoms/strings works.** The only options that cannot survive a round-trip through a config file are `feature_store`, `events_dispatcher`, `polling_update_requestor` and `testdata_tag` — and even those are *atoms*, i.e. names resolved at runtime, which is exactly the "component reference by identifier" pattern OTel declarative config uses for exporters/processors.
2. **Ignoring unknown keys** (a plain `maps:get/3` per option) gives forwards compatibility for free — an older SDK reading a newer config file does not crash.
3. **Instance `Tag`** is a first-class multi-environment key. A declarative spec that wants to support multiple LD environments in one process can reuse this shape (`instances: { default: {...}, analytics: {...} }`).
4. Units are **not** encoded in key names consistently (`polling_interval` = seconds, `events_flush_interval` = ms, `file_poll_interval` = ms, `stream_initial_retry_delay_ms` = ms, `cache_ttl` = seconds, `connect_timeout` = ms). This is the single biggest hazard to copy *away from*: a declarative spec should either suffix every duration key with its unit or use ISO-8601/`"30s"` strings.
5. `cache_ttl`'s sign overloading (0 = bypass, negative = infinite) is a pattern to avoid in a declarative schema; prefer an explicit enum (`{"mode": "off" | "ttl" | "infinite", "ttl": "30s"}`) — which is, notably, exactly what the contract-test harness schema does.

### 11.2 C++ — `LD_LOG_LEVEL` and proxy env vars

- **`LD_LOG_LEVEL`** (`libs/common/src/config/logging_builder.cpp:63`): `LoggingBuilder::BasicLogging`'s default-constructed level is `GetLogLevelEnum(std::getenv("LD_LOG_LEVEL"), LogLevel::kInfo)`. Accepts `debug|info|warn|error`, case-insensitive; unrecognised values fall back to `info`. Note the semantics: it sets the *initial* value, so an explicit `.Level(...)` call still wins — i.e. **code overrides env**, which is the opposite of the usual OTel precedence (env overrides file/code). Worth calling out in the spec.
- **Proxy**: `HttpPropertiesBuilder::Proxy(std::optional<std::string>)` / `built::ProxyOptions`. Default `nullopt` defers to CURL's `ALL_PROXY` / `HTTP_PROXY` / `HTTPS_PROXY`; a non-empty string overrides the env; the **empty string explicitly disables proxying even when the env vars are set**. This tri-state (`unset` / `value` / `""`) is a useful precedent for "how do I say *no*, not just *unspecified*" in a declarative schema. Requires the `LD_CURL_NETWORKING` build option, otherwise it throws.
- **DynamoDB**: `DynamoDBClientOptions` fields left unset fall through to the AWS SDK's own env/shared-config/instance-metadata chains — an example of *delegated* env configuration.
- **No file-based config loading exists anywhere in `cpp-sdks`.** I searched for `FromJson`, `from_json`, `ParseConfig`, `LoadConfig`, `config.json`, `declarative`: nothing. `ConfigBuilder` is builder-only.

### 11.3 The contract-test harness config schema — the real cross-SDK "declarative config" that already exists

`cpp-sdks/contract-tests/data-model/include/data_model/data_model.hpp` defines a full **JSON⇄config mapping** (nlohmann, `NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE_WITH_DEFAULT`), consumed by `contract-tests/server-contract-tests/src/entity_manager.cpp`. Erlang has the equivalent in `test-service/src/ts_sdk_config_params.erl` (JSON map → `ldclient` options map), and Haskell/C have their own test services. This is the *de facto* existing declarative schema and the spec should align with it where sensible:

```
ConfigParams {
  credential, startWaitTimeMs, initCanFail,
  streaming   { baseUri, initialRetryDelayMs, filter },
  polling     { baseUri, pollIntervalMs, filter },
  dataSystem  { initializers[ { polling } ], synchronizers[ { streaming | polling } ],
                fdv1Fallback { …polling… }, payloadFilter,
                store { persistentDataStore { store { type, dsn, prefix },
                                              cache { mode: off|ttl|infinite, ttl } } } },
  events      { baseUri, capacity, enableDiagnostics, allAttributesPrivate,
                globalPrivateAttributes[], flushIntervalMs },
  serviceEndpoints { streaming, polling, events },
  clientSide  { initialContext, evaluationReasons, useReport },
  tags        { applicationId, applicationVersion },
  tls         { … }, proxy { httpProxy },
  hooks       { hooks[ { name, callbackUri, data, errors } ] },
  wrapper     { name, version },
  persistentDataStore { store, cache },   // v2 harness: top level
  bigSegments { callbackUri, userCacheSize, userCacheTimeMs,
                statusPollIntervalMs, staleAfterMs }
}
```

Notable properties: every duration key carries its unit suffix (`…Ms`); cache lifetime is an explicit **mode enum + value** rather than sign overloading; persistent stores are `{type, dsn, prefix}` (type-tagged component reference + connection string), which is precisely the "component by name" pattern a declarative spec needs; and the schema already had to cope with a **v2 (top-level `persistentDataStore`) vs v3 (nested under `dataSystem.store`) migration**, handled by `PersistentDataStoreConfig()` reading whichever is present — a concrete precedent for schema versioning/aliasing.

### 11.4 C (legacy) and Haskell

No file-based or environment-variable configuration of any kind in either. Haskell's `Config` is a plain record and *could* trivially gain a `FromJSON` instance for the ~20 data-expressible fields (the 5 function/handle fields — `logger`, `manager`, `storeBackend`, `dataSourceFactory` — would need component-reference indirection). The C SDK's flat `struct LDConfig` is likewise almost entirely scalars.

---

## 12. Notable divergences and oddities

1. **Duration units are inconsistent within *and* across SDKs.** Same logical option, four units: event flush interval is ms in Erlang (30000) and C (5000), ms-typed `std::chrono` in C++ (5 s), seconds in Haskell (5). Erlang mixes seconds (`polling_interval`, `cache_ttl`) and ms (`events_flush_interval`, `file_poll_interval`, `stream_initial_retry_delay_ms`) in one flat map with only one key self-documenting its unit. A declarative spec must mandate unit-suffixed keys or duration strings.
2. **Default flush interval differs by 6×**: Erlang 30 s vs C++/C/Haskell 5 s.
3. **Default store cache TTL differs 30×**: Haskell 10 s, Erlang 15 s, C 30 s, C++ **5 minutes**.
4. **Legacy C base URI is wrong-by-modern-standards**: `https://app.launchdarkly.com` instead of `https://sdk.launchdarkly.com`.
5. **`all_attributes_private` is not a boolean in Erlang** — it is the sentinel value `private_attributes => all`. Union-typed option value vs separate boolean; a declarative schema has to pick one and probably support both.
6. **`cache_ttl` sign overloading in Erlang**: `0` = testing/bypass mode, negative = infinite TTL, positive = seconds. Three modes in one integer.
7. **C++ has no `use_ldd`/daemon-mode flag**; daemon mode is re-expressed as `DataSystem().Method(LazyLoad)` with a read-only source. Any cross-SDK key named `daemonMode`/`useLdd` cannot map onto C++ 1:1.
8. **C++ `Offline(true)` is a macro, not a field**: it is expanded at `Build()` into `Events().Disable()` + `DataSystem().Disable()` and silently **overrides** more specific settings. Precedence rules matter if a declarative file sets both.
9. **Init-wait timeout lives in three different places**: an argument to `LDClientInit(config, maxwaitmilli)` in C; nowhere in Erlang/Haskell (poll `initialized/1` / `getStatus`); and nowhere in the C++ *config* (the caller applies `std::future::wait_for` to `StartAsync()`). The contract-test schema has `startWaitTimeMs` at top level — the right home for a declarative spec, but three of four SDKs would need new API.
10. **Nobody implements diagnostic events.** None of the four SDKs has `enableDiagnostics` or `diagnosticRecordingInterval`, even though the shared contract schema carries the field.
11. **Big segments exist only in C++.** Erlang, C, Haskell have no big-segment support at all.
12. **Hooks exist only in C++** (`ConfigBuilder::Hooks`, plus the OTel tracing hook lib). No plugin concept in any of the four.
13. **Payload filter key exists only in C++**, and only on the BackgroundSync `Streaming`/`Polling` builders. `FDv2Builder::Streaming`/`Polling` carry a `filter_key_` member with **no setter** — a latent gap.
14. **Wrapper name/version** exists in C++ and legacy C but **not** in Erlang or Haskell.
15. **Haskell `configSetInitialRetryDelay`'s parameter is named `seconds` but the value is milliseconds** (default `1_000` ms, doc comment says milliseconds). Latent API bug worth reporting.
16. **Haskell has two options nobody else has**: `configSetCompressEvents` (gzip event payloads, default `False` for old Relay Proxy compatibility) and `configSetOmitAnonymousContexts`.
17. **Deprecated options**: Haskell `configSetUserKeyLRUCapacity` (pragma-deprecated alias of `configSetContextKeyLRUCapacity`); legacy C `LDConfigInlineUsersInEvents` and `LDBasicLogger`; legacy C's user-centric naming (`userKeysCapacity`, `userKeysFlushInterval`) versus context-centric elsewhere.
18. **Redis is configured four different ways**: 7 discrete Erlang keys (`redis_host/port/database/username/password/prefix/tls`), a single Redis++ URI + prefix in C++, host/port/prefix/poolSize setters in C, and a pre-built `hedis` `Connection` + namespace in Haskell. A declarative spec almost certainly wants `{type, dsn/uri, prefix}` (the contract-schema shape) with discrete fields as optional sugar.
19. **C++ builder options that exist in the built structs but are unreachable from the public API**: event `DeliveryRetryDelay` (1 s), event `FlushWorkers` (5), streaming/polling/event **path components**, and the entire `BootstrapBuilder` / `DataDestinationBuilder` (stubs returning `nullopt`). The C bindings are also narrower than the C++ API — they expose no HTTP connect/read/write/response timeouts.
20. **Logging is the only env-var-configurable thing** (`LD_LOG_LEVEL`, C++ only) and its precedence is inverted relative to OTel convention (explicit code wins over env, because the env read happens in the builder's default constructor).
21. **Erlang has no logging configuration at all** — it writes via `error_logger`/`logger`, so "log level" is host-app config, not SDK config. A declarative spec's logging section would be a no-op there.
22. **Erlang's file data source is the most featureful** (`file_paths`, `file_auto_update`, `file_poll_interval`, `file_allow_duplicate_keys`); C and Haskell only take a list of paths; C++ has none.
23. **Erlang's multi-instance `Tag`** has no analogue in the other three, and it doubles as the namespace for supervisors and the app-env settings registry. It also collides terminologically with application *tags* (`x-launchdarkly-tags`) — `ldclient_headers` explicitly comments on the clash.
24. **Erlang's TLS story is uniquely rich and uniquely code-shaped**: `tls_options` is a raw `[ssl:tls_client_option()]`, with six helper constructors including OTP-version-dependent CA-store selection and a CRL-revocation wrapper. Only "use system CA store" / "use CA file at path" / "skip verification" are realistically expressible declaratively; the rest is code-only.
25. **Only Erlang and Haskell mint a per-instance UUID** (`X-LaunchDarkly-Instance-Id`); it is generated, never configurable, in both.
