# Server-side SDK configuration surface: Java and .NET

Research for a cross-SDK declarative configuration spec (file + env var, OTel-style).

## Sources

| SDK | Canonical repo (current) | Version inspected | Notes |
|---|---|---|---|
| Java | `launchdarkly/java-core` → `lib/sdk/server` | `launchdarkly-java-server-sdk` 7.17.1 (2026-09-15) | The old `launchdarkly/java-server-sdk` repo is **archived** (README: "This code has a new home") and frozen at 7.4.1. Shared code: `lib/shared/common` (was `java-sdk-common`), `lib/shared/internal`. Also `lib/java-server-sdk-redis-store`, `lib/java-server-sdk-otel`, `lib/sdk/server-ai`. |
| .NET | `launchdarkly/dotnet-core` → `pkgs/sdk/server` | `LaunchDarkly.ServerSdk` 8.17.0 (2026-09-17) | The old `launchdarkly/dotnet-server-sdk` repo is **deprecated** (README: "Development has moved to dotnet-core"), frozen at 8.3.0/8.x. Shared: `pkgs/shared/common` (was `dotnet-sdk-common`), `pkgs/shared/internal`. Stores + telemetry live in the same monorepo: `pkgs/dotnet-server-sdk-{redis,dynamodb,consul}`, `pkgs/telemetry`, `pkgs/sdk/server-ai`. |
| Java stores (separate repos) | `java-server-sdk-dynamodb` (2026-07-08), `java-server-sdk-consul` (2026-06-03) | — | `java-server-sdk-redis` is archived; Redis now lives inside `java-core`. |

Key type names: Java `LDConfig.Builder` + `Components.*` sub-builders; .NET `Configuration.Builder(sdkKey)` / `ConfigurationBuilder` + `Components.*` sub-builders. Both use the same `IComponentConfigurer<T>` / `ComponentConfigurer<T>` pattern, so almost every component slot is *code-shaped* (a factory object) rather than data-shaped; a declarative spec has to map names → known built-in configurers.

**Environment variables: neither SDK reads any.** No `getenv` / `Environment.GetEnvironmentVariable` for configuration in either repo. The only hits are:
- Java: `System.getProperty("os.name"/"java.version"/…)` for diagnostic events only.
- .NET: `Environment.GetEnvironmentVariable("HTTP_PROXY"/"HTTPS_PROXY"/"ALL_PROXY")` in `pkgs/shared/internal/src/Events/DiagnosticConfigProperties.cs` — used *only* to report `usingProxy` in diagnostic events, not to configure anything.

No `LD_`-prefixed variables exist in either SDK. SDK key must be passed programmatically.

---

## 1. Top level (credentials, offline, lifecycle)

| Option | Java | .NET | Type | Java default | .NET default | Semantics / notes |
|---|---|---|---|---|---|---|
| SDK key | ctor arg `new LDClient(sdkKey)` / `new LDClient(sdkKey, config)` | `ConfigurationBuilder.SdkKey(string)` **and** `Configuration.Builder(sdkKey)` | string | required (non-null) | `null` allowed | **Divergence:** Java has *no* config-builder property for the key — it is only a client constructor arg. .NET has both. Data-expressible (but secret). |
| SDK key validation | `LDClient` ctor: `checkNotNull`, then `HttpHelpers.isAsciiHeaderValue(sdkKey)`; non-ASCII → throws `IllegalArgumentException` | `ValidationUtils.IsValidSdkKeyFormat`: null/empty OK; >8192 chars rejected; must match `^[-a-zA-Z0-9._]+\z`. Invalid keys are **silently dropped** (field stays null) and `LdClient` logs `"The SDK key provided is invalid."` if not offline | — | — | — | Divergence in strictness and failure mode (throw vs. drop+log). |
| Offline mode | `offline(boolean)` | `Offline(bool)` | bool | `false` | `false` | Java applies it in `LDConfig` ctor (forces `externalUpdatesOnly()` + `noEvents()`, overriding `dataSource`/`events`). .NET applies it at client-construction time in `FDv1DataSystem.Create` / `FDv2DataSystem.Create` + `LdClient` (events → `NoEvents`). Data-expressible. |
| Start/init wait | `startWait(Duration)` | `StartWaitTime(TimeSpan)` | duration object | **5 s** (`LDConfig.DEFAULT_START_WAIT`) | **10 s** (`ConfigurationBuilder.DefaultStartWaitTime`) | **Unit/default divergence.** `<= 0` → don't block. Both warn if excessive: Java `> 60000 ms`, .NET `>= 60 s`. Data-expressible. |
| Diagnostic opt-out | `diagnosticOptOut(boolean)` | `DiagnosticOptOut(bool)` | bool | `false` | `false` | Disables the diagnostic-event pipeline entirely. Data-expressible. |
| SDK thread priority | `threadPriority(int)` | *(absent)* | int | `Thread.MIN_PRIORITY` (1) | — | Clamped to `[Thread.MIN_PRIORITY, Thread.MAX_PRIORITY]` (1–10). **Java-only.** Data-expressible but JVM-specific. |
| Instance id | *not configurable* — `ClientContextImpl` generates `UUID.randomUUID()` | *not configurable* — `LdClientContext`: `instanceId ?? Guid.NewGuid().ToString()` | string | random UUID | random GUID | Sent as `X-LaunchDarkly-Instance-Id` header by both. Not settable from user config in either SDK. |
| Copy-from-config | `LDConfig.Builder.fromConfig(LDConfig)` | `Configuration.Builder(Configuration)` | — | — | — | **.NET bug:** the copy constructor does **not** copy `_wrapperInfo` (see `ConfigurationBuilder.cs`, `ConfigurationBuilder(Configuration copyFrom)`); Java's `fromConfig` does copy `wrapperBuilder`. |

---

## 2. Service endpoints

Java `LDConfig.Builder.serviceEndpoints(Components.serviceEndpoints()…)`; .NET `ConfigurationBuilder.ServiceEndpoints(Components.ServiceEndpoints()…)`.

| Option | Java | .NET | Type | Java default | .NET default |
|---|---|---|---|---|---|
| Streaming base URI | `streaming(URI)` / `streaming(String)` | `Streaming(Uri)` / `Streaming(string)` | URI string | `https://stream.launchdarkly.com` | `https://stream.launchdarkly.com` |
| Polling base URI | `polling(URI)` / `polling(String)` | `Polling(Uri)` / `Polling(string)` | URI string | **`https://app.launchdarkly.com`** | **`https://sdk.launchdarkly.com`** |
| Events base URI | `events(URI)` / `events(String)` | `Events(Uri)` / `Events(string)` | URI string | `https://events.launchdarkly.com` | `https://events.launchdarkly.com` |
| Relay Proxy (all three at once) | `relayProxy(URI/String)` | `RelayProxy(Uri/string)` | URI string | — | — |

All data-expressible. Identical "all-or-nothing" semantics in both (`ComponentsImpl.ServiceEndpointsBuilderImpl.createServiceEndpoints` / `ServiceEndpointsBuilder.Build`): if *any* of the three is set, the unset ones stay `null` and the consuming component logs `"You have set custom ServiceEndpoints without specifying the X base URI; connections may not work properly"` and falls back to the standard default at use time (`StandardEndpoints.selectBaseUri` / `SelectBaseUri`).

Fixed request paths (not configurable): FDv1 streaming `/all`, FDv1 polling `/sdk/latest-all`; FDv2 polling `/sdk/poll`, FDv2 streaming `/sdk/stream`.

---

## 3. Data source (FDv1 — `dataSource` slot)

Selected via Java `dataSource(ComponentConfigurer<DataSource>)` / .NET `DataSource(IComponentConfigurer<IDataSource>)`. Default when unset: **streaming**.

| Option | Java | .NET | Type | Java default | .NET default | Notes |
|---|---|---|---|---|---|---|
| Streaming source | `Components.streamingDataSource()` | `Components.StreamingDataSource()` | selector | default | default | Data-expressible (named variant). |
| – initial reconnect delay | `initialReconnectDelay(Duration)` | `InitialReconnectDelay(TimeSpan)` | duration | 1000 ms | 1 s | No clamping in either. |
| – extended-backoff regime | *(absent)* | `_extendedInitialReconnectDelay` = 5 min, `_extendedMaxRetryDelay` = 1 h — **`internal`, test-only** | duration | — | 5 min / 1 h | .NET-only internal knobs; not part of the public surface. |
| – payload filter | `payloadFilter(String)` | **absent** | string | none | — | **Major divergence:** .NET server SDK has *no* payload-filter option anywhere (contract tests contain `// PayloadFilter is not yet supported … TODO`). |
| Polling source | `Components.pollingDataSource()` | `Components.PollingDataSource()` | selector | — | — | .NET logs a warning on build: "You should only disable the streaming API if instructed to do so by LaunchDarkly support". |
| – poll interval | `pollInterval(Duration)` | `PollInterval(TimeSpan)` | duration | 30 s | 30 s | **Clamped to a 30 s minimum in both** (silently raised to the default, no error). Java also maps `null` → default. |
| – extended initial interval | *(absent)* | `_extendedInitialInterval` = 5 min (`internal`) | duration | — | 5 min | .NET-only, test-only. |
| – payload filter | `payloadFilter(String)` | absent | string | none | — | as above |
| External updates only / daemon mode | `Components.externalUpdatesOnly()` | `Components.ExternalUpdatesOnly` (property) | selector | — | — | Combine with a persistent store for Relay Proxy daemon mode. Data-expressible. |
| File data source | `FileData.dataSource()` | `FileData.DataSource()` | selector | — | — | See §7. |
| Test data source | `TestData.dataSource()` (+ `TestDataV2` for FDv2) | `TestData.DataSource()` | selector | — | — | **Code-only** (flags are built by API calls). Java additionally has `TestDataV2`; .NET has no FDv2 test-data equivalent. |
| Custom data source | any `ComponentConfigurer<DataSource>` | any `IComponentConfigurer<IDataSource>` | object | — | — | **Code-only.** Java also exposes the `FeatureRequestor` interface — code-only. |

---

## 4. Data system (FDv2) — newer, parallel configuration path

Java `LDConfig.Builder.dataSystem(Components.dataSystem()…)`; .NET `ConfigurationBuilder.DataSystem(Components.DataSystem()…)`. **When set, it overrides `dataSource` and `dataStore`.** Structurally near-identical in the two SDKs.

| Option | Java | .NET | Type | Default |
|---|---|---|---|---|
| Mode: default (polling init + streaming/polling sync + FDv1 polling fallback) | `dataSystem().defaultMode()` | `DataSystem().Default()` | selector | — |
| Mode: streaming only | `.streaming()` | `.Streaming()` | selector | — |
| Mode: polling only | `.polling()` | `.Polling()` | selector | — |
| Mode: daemon (read-only persistent store, no sources) | `.daemon(store)` | `.Daemon(store)` | selector + store obj | — |
| Mode: persistent store (default mode + read-write store) | `.persistentStore(store)` | `.PersistentStore(store)` | selector + store obj | — |
| Mode: custom | `.custom()` | `.Custom()` | selector | — |
| Initializers list | `initializers(...)` / `replaceInitializers(...)` | `Initializers(...)` / `ReplaceInitializers(...)` | list of component objects | mode-dependent |
| Synchronizers list (ordered fallback) | `synchronizers(...)` / `replaceSynchronizers(...)` | `Synchronizers(...)` / `ReplaceSynchronizers(...)` | list of component objects | mode-dependent |
| FDv1 fallback synchronizer | `fDv1FallbackSynchronizer(ComponentConfigurer<DataSource>)` | `FDv1FallbackSynchronizer(IComponentConfigurer<IDataSource>)` | component object | `fDv1Polling()` / `FDv1Polling()` in default/streaming/polling modes |
| Persistent store + mode | `persistentStore(store, DataStoreMode.READ_ONLY|READ_WRITE)` | `PersistentStore(store, DataStoreMode.ReadOnly|ReadWrite)` | object + enum | none |
| `build()` visibility | `public DataSystemConfiguration build()` | `internal DataSystemConfiguration Build()` | — | — |

FDv2 component builders:

| Option | Java | .NET | Type | Java default | .NET default |
|---|---|---|---|---|---|
| Polling initializer | `DataSystemComponents.pollingInitializer()` (`FDv2PollingInitializerBuilder`) | `DataSystemComponents.Polling()` (`FDv2PollingDataSourceBuilder` doubles as initializer) | selector | — | — |
| – endpoint override | `serviceEndpointsOverride(ServiceEndpointsBuilder)` | `ServiceEndpointsOverride(ServiceEndpointsBuilder)` | nested endpoints obj | inherits client endpoints | same |
| – payload filter | `payloadFilter(String)` — **`@Deprecated`**, logs a deprecation warning and is ignored for FDv2 | absent | string | — | — |
| Polling synchronizer | `DataSystemComponents.pollingSynchronizer()` | `DataSystemComponents.Polling()` | selector | — | — |
| – poll interval | `pollInterval(Duration)` | `PollInterval(TimeSpan)` | duration | 30 s, clamped min 30 s | 30 s, clamped min 30 s |
| Streaming synchronizer | `DataSystemComponents.streamingSynchronizer()` | `DataSystemComponents.Streaming()` | selector | — | — |
| – initial reconnect delay | `initialReconnectDelay(Duration)` | `InitialReconnectDelay(TimeSpan)` | duration | 1 s | 1 s |
| FDv1 polling (for fallback) | `DataSystemComponents.fDv1Polling()` (= `Components.pollingDataSource()`) | `DataSystemComponents.FDv1Polling()` | selector | — | — |
| File initializer / synchronizer | `FileData.initializer()`, `FileData.synchronizer()` | **absent** | selector | — | — |

**Java-only in FDv2:** separate `Initializer`/`Synchronizer` types (`DataSourceBuilder<Initializer>` vs `DataSourceBuilder<Synchronizer>`), file-based initializer/synchronizer, `TestDataV2`. .NET reuses `IComponentConfigurer<IDataSource>` for both roles.

---

## 5. Events

Java `events(Components.sendEvents()…)`; .NET `Events(Components.SendEvents()…)`. Disable with Java `Components.noEvents()` / .NET `Components.NoEvents`.

| Option | Java | .NET | Type | Java default | .NET default | Validation | Notes |
|---|---|---|---|---|---|---|---|
| Event buffer capacity | `capacity(int)` | `Capacity(int)` | int | 10000 | 10000 | Java: **none**; .NET: `<= 0` → default | |
| Flush interval | `flushInterval(Duration)` | `FlushInterval(TimeSpan)` | duration | 5 s | 5 s | Java: `null` → default (negatives accepted); .NET: `<= 0` → default | |
| All attributes private | `allAttributesPrivate(boolean)` | `AllAttributesPrivate(bool)` | bool | `false` | `false` | — | |
| Private attributes | `privateAttributes(String...)` | `PrivateAttributes(params string[])` | list of strings (attribute references) | empty | empty | parsed via `AttributeRef.fromPath` / `FromPath` | Java *replaces* the set on each call (allocates new `HashSet`); .NET `Clear()`s then adds — same effective semantics. |
| Context-key dedup cache size | **`userKeysCapacity(int)`** | **`ContextKeysCapacity(int)`** | int | 1000 | 1000 | Java: none; .NET: `<= 0` → default | **Naming divergence** (Java kept the legacy `user` name; still reported as `userKeysCapacity` in .NET diagnostics). |
| Context-key dedup cache flush | **`userKeysFlushInterval(Duration)`** | **`ContextKeysFlushInterval(TimeSpan)`** | duration | 5 min | 5 min | Java: `null` → default; .NET: `<= 0` → default | naming divergence |
| Diagnostic recording interval | `diagnosticRecordingInterval(Duration)` | `DiagnosticRecordingInterval(TimeSpan)` | duration | 15 min | 15 min | **Clamped to min 60 s in both** (`MIN_DIAGNOSTIC_RECORDING_INTERVAL` / `MinimumDiagnosticRecordingInterval`) | |
| Gzip request compression | `enableGzipCompression(boolean)` | **absent** | bool | `false` | — | — | **Java-only** (outbound event payload compression). .NET only does transparent gzip *decompression* of responses (`HttpProperties.AutomaticDecompression`). |
| Custom event sender | `eventSender(ComponentConfigurer<EventSender>)` — **public** | `EventSender(IEventSender)` — **`internal`** | object | none | — | — | **Code-only.** Public in Java, test-only in .NET. |

Both derive the events URL as `<eventsBaseUri>/bulk` and diagnostics as `<eventsBaseUri>/diagnostic`; not separately configurable. Both hard-code `RedactAnonymousAllEvents = true` for server-side.

---

## 6. HTTP

Java `http(Components.httpConfiguration()…)`; .NET `Http(Components.HttpConfiguration()…)`.

| Option | Java | .NET | Type | Java default | .NET default | Data or code? |
|---|---|---|---|---|---|---|
| Connect timeout | `connectTimeout(Duration)` | `ConnectTimeout(TimeSpan)` | duration | 2 s | 2 s | data |
| Read/socket timeout | **`socketTimeout(Duration)`** | **`ReadTimeout(TimeSpan)`** | duration | 10 s | 10 s | data — **naming divergence** |
| Response-start timeout | *(absent)* | `ResponseStartTimeout(TimeSpan)` | duration | — | 10 s | data — **.NET-only** |
| Custom headers | `addCustomHeader(String, String)` (accumulates into a `Map`) | `CustomHeader(string, string)` (accumulates into a `List<KVP>`) | map/list of strings | empty | empty | data |
| Proxy | `proxyHostAndPort(String host, int port)` | `Proxy(IWebProxy)` | Java: string+int; .NET: object | none | none | **Java: data. .NET: code-only** (`IWebProxy` instance). |
| Proxy authentication | `proxyAuth(HttpAuthentication)`; helper `Components.httpBasicAuthentication(user, pass)` | via `IWebProxy.Credentials` | object | none | none | Java: *semi-data* (the basic-auth helper takes two strings, so `{username, password}` is expressible); a custom `HttpAuthentication` is code-only. .NET: code-only. |
| Socket factory | `socketFactory(SocketFactory)` | — | object | none | — | **code-only, Java-only** |
| TLS / custom CA | `sslSocketFactory(SSLSocketFactory, X509TrustManager)` | — (via `MessageHandler`) | object pair | none | — | **code-only** in both; no file-path-based CA bundle option in either SDK. |
| HTTP message handler | — | `MessageHandler(HttpMessageHandler)` | object | none | none | **code-only, .NET-only** |
| Wrapper name/version | `wrapper(String name, String version)` | `Wrapper(string name, string version)` | strings | none | none | data; superseded by the top-level wrapper config (§10). |
| Instance-id header | auto (`X-LaunchDarkly-Instance-Id` from `ClientContext.getInstanceId()`) | auto (`HttpConfigurationBuilder.InstanceIdHeader`) | — | UUID | GUID | not configurable |

Notes: neither builder validates/clamps timeouts. In .NET, custom headers are applied last and *may overwrite* `User-Agent`, `Authorization`, and the instance-id header (explicit comment in `HttpConfigurationBuilder`). Java builds `Authorization` from the SDK key in `ComponentsImpl.HttpConfigurationBuilderImpl`.

---

## 7. File data source (testing / offline flag files)

| Option | Java (`FileDataSourceBuilder`) | .NET (`FileDataSourceBuilder`) | Type | Java default | .NET default |
|---|---|---|---|---|---|
| File paths | `filePaths(String...)` / `filePaths(Path...)` | `FilePaths(params string[])` | list of path strings | empty | empty |
| Classpath resources | `classpathResources(String...)` | *(absent)* | list of strings | empty | — |
| Auto-update (watch files) | `autoUpdate(boolean)` | `AutoUpdate(bool)` | bool | `false` | `false` |
| Duplicate-key handling | `duplicateKeysHandling(FileData.DuplicateKeysHandling)` → `FAIL` \| `IGNORE` | `DuplicateKeysHandling(FileDataTypes.DuplicateKeysHandling)` → `Throw` \| `Ignore` | enum | `FAIL` | `Throw` |
| Skip missing paths | *(absent)* | `SkipMissingPaths(bool)` | bool | — | `false` |
| Custom parser | *(absent — YAML/JSON auto-detected)* | `Parser(Func<string, object>)` | callback | — | none (JSON only unless set) |
| Custom file reader | *(absent)* | `FileReader(FileDataTypes.IFileReader)` | object | — | `FlagFileReader.Instance` |
| Persist to store (FDv2) | `shouldPersist(boolean)` | *(absent)* | bool | `true` for `dataSource()`, `false` for `initializer()`/`synchronizer()` | — |

Java's `Parser`/`FileReader` gaps and .NET's `classpathResources` gap are both meaningful; `Parser` and `FileReader` are **code-only**.

---

## 8. Persistent data store (caching wrapper)

Java `dataStore(Components.persistentDataStore(storeConfigurer)…)`; .NET `DataStore(Components.PersistentDataStore(storeConfig)…)`. Default data store when unset: Java `Components.inMemoryDataStore()` / .NET `Components.InMemoryDataStore`.

| Option | Java | .NET | Type | Java default | .NET default | Notes |
|---|---|---|---|---|---|---|
| Cache TTL | `cacheTime(Duration)`, `cacheMillis(long)`, `cacheSeconds(long)` | `CacheTime(TimeSpan)`, `CacheMillis(int)`, `CacheSeconds(int)` | duration | **15 s** (`DEFAULT_CACHE_TTL`) | **30 s** (`DataStoreCacheConfig.DefaultTtl`) | **Default divergence (2×).** |
| No caching | `noCaching()` (= TTL 0) | `NoCaching()` (= TimeSpan.Zero) | flag | — | — | |
| Cache forever | `cacheForever()` (= `Duration.ofMillis(-1)`) | `CacheForever()` (= `Timeout.InfiniteTimeSpan`, i.e. −1 ms) | flag | — | — | Same encoding (negative TTL = infinite). |
| Max cache entries | *(absent)* | `CacheMaximumEntries(int?)` | nullable int | — | `null` (unbounded) | **.NET-only**; throws `ArgumentException` if `<= 0`. |
| Stale-values policy | `staleValuesPolicy(StaleValuesPolicy)` → `EVICT` \| `REFRESH` \| `REFRESH_ASYNC` | *(absent)* | enum | `EVICT` | — | **Java-only.** `null` → `EVICT`. |
| Record cache stats | `recordCacheStats(boolean)` | *(absent)* | bool | `false` | — | **Java-only** (feeds `DataStoreStatusProvider.getCacheStats()`). |

### Redis

| Option | Java (`Redis.dataStore()` / `Redis.bigSegmentStore()`) | .NET (`Redis.DataStore()` / `Redis.BigSegmentStore()`) | Type | Java default | .NET default |
|---|---|---|---|---|---|
| Connection URI | `uri(URI)` | `Uri(string)` / `Uri(Uri)` | URI string | `redis://localhost:6379` | — (endpoint default below); **scheme must be `redis`** or throws; `rediss` is rejected |
| Host/port | (via URI) | `HostAndPort(string, int)`, `EndPoint(EndPoint)`, `EndPoints(IList<EndPoint>)` | string+int / objects | — | `localhost:6379` (`DnsEndPoint`) |
| Prefix | `prefix(String)` | `Prefix(string)` | string | `launchdarkly` | `launchdarkly` (empty → default) |
| Database index | `database(Integer)` (else parsed from URI path) | `DatabaseIndex(int)` (else parsed from URI path) | int | from URI, else 0 | none set |
| Username | `username(String)` (else from URI userinfo) | *(absent — Redis ACL username unsupported; URI userinfo username is discarded)* | string | from URI | — |
| Password | `password(String)` (else from URI userinfo) | only via URI `:password` form or `ConfigurationOptions` | string | from URI | — |
| TLS | `tls(boolean)` (or `rediss://` scheme) | only via `ConfigurationOptions.Ssl` | bool | `false` | — |
| Connect timeout | `connectTimeout(Duration)` | `ConnectTimeout(TimeSpan)` | duration | 2000 ms (Jedis `Protocol.DEFAULT_TIMEOUT`) | 5 s (`Redis.DefaultConnectTimeout`) |
| Socket / operation timeout | `socketTimeout(Duration)` | `OperationTimeout(TimeSpan)` → `ConfigurationOptions.SyncTimeout` | duration | 2000 ms | `Redis.DefaultOperationTimeout` = 3 s is **declared but never applied** (the builder ctor only sets `ConnectTimeout`), so the effective default is StackExchange.Redis' `SyncTimeout` (5 s) |
| Pool config | `poolConfig(JedisPoolConfig)` | — | object | none | — |
| SSL socket factory / params / hostname verifier | `sslSocketFactory`, `sslParameters`, `hostnameVerifier` | — | objects | none | — |
| Raw client options | — | `RedisConfiguration(ConfigurationOptions)`, `RedisConfigChanges(Action<ConfigurationOptions>)` | object / callback | — | — |
| Existing connection | — | `Connection(IConnectionMultiplexer)` | object | — | none |

Code-only: Java `poolConfig`/`sslSocketFactory`/`sslParameters`/`hostnameVerifier`; .NET `RedisConfiguration`, `RedisConfigChanges` (a lambda), `Connection`.

### DynamoDB

| Option | Java (`DynamoDb.dataStore(tableName)` / `.bigSegmentStore(tableName)`) | .NET (`DynamoDB.DataStore(tableName)` / `.BigSegmentStore(tableName)`) | Type | Java default | .NET default |
|---|---|---|---|---|---|
| Table name | required constructor arg | required constructor arg | string | — | — |
| Key prefix | `prefix(String)` | `Prefix(string)` | string | `null` (no prefix) | `""` |
| AWS region | `region(Region)` | *(only inside `AmazonDynamoDBConfig`)* | Java: SDK enum-ish object; .NET: object | AWS default chain | — |
| Endpoint override | `endpoint(URI)` | *(only inside `AmazonDynamoDBConfig`)* | URI | none | — |
| Credentials | `credentials(AwsCredentialsProvider)` | `Credentials(AWSCredentials)` | object | AWS default chain | AWS default chain |
| Client override config | `clientOverrideConfiguration(ClientOverrideConfiguration)` | `Configuration(AmazonDynamoDBConfig)` | object | — | — |
| Existing client | `existingClient(DynamoDbClient)` | `ExistingClient(AmazonDynamoDBClient)` | object | — | — |

Data-expressible: table name, prefix; Java additionally region + endpoint. Everything else is **code-only** (AWS SDK objects). Both rely on the AWS default credential/region resolution chain when unset (which *is* env-var driven, but by the AWS SDK, not LaunchDarkly).

### Consul

| Option | Java (`Consul.dataStore()`) | .NET (`Consul.DataStore()`) | Type | Java default | .NET default |
|---|---|---|---|---|---|
| Host | `host(String)` | — | string | `Consul.DEFAULT_HTTP_HOST` | — |
| Port | `port(int)` | — | int | `Consul.DEFAULT_HTTP_PORT` | — |
| Address / URL | `url(URL)` | `Address(string)` / `Address(Uri)` | URL string | none | library default |
| Prefix | `prefix(String)` | `Prefix(string)` | string | `launchdarkly` | `launchdarkly` |
| Existing client | `existingClient(Consul)` | `ExistingClient(ConsulClient)` | object | — | — |
| Raw client options | — | `ConsulConfigChanges(Action<ConsulClientConfiguration>)` | callback | — | — |

Neither Consul integration provides a Big Segment store (data store only). `host`/`port` and `url`/`Address` are mutually exclusive in Java (setting one nulls the other).

---

## 9. Big Segments

Java `bigSegments(Components.bigSegments(storeConfigurer)…)`; .NET `BigSegments(Components.BigSegments(storeConfig)…)`.

| Option | Java | .NET | Type | Java default | .NET default | Validation |
|---|---|---|---|---|---|---|
| Store | ctor arg `Components.bigSegments(ComponentConfigurer<BigSegmentStore>)` — `null` allowed | ctor arg `Components.BigSegments(IComponentConfigurer<IBigSegmentStore>)` — `null` allowed | object (Redis/DynamoDB builder) | none (Big Segments unevaluable → `BigSegmentsStatus.NOT_CONFIGURED`) | same | Data-expressible only as a *named* store selector. |
| Membership cache size | **`userCacheSize(int)`** | **`ContextCacheSize(int)`** | int | 1000 | 1000 | Java: `max(value, 0)`; .NET: **no validation** |
| Membership cache TTL | **`userCacheTime(Duration)`** | **`ContextCacheTime(TimeSpan)`** | duration | 5 s | 5 s | Java: `null`/negative → default; .NET: **no validation** |
| Status poll interval | `statusPollInterval(Duration)` | `StatusPollInterval(TimeSpan)` | duration | 5 s | 5 s | both: `<= 0` → default |
| Stale after | `staleAfter(Duration)` | `StaleAfter(TimeSpan)` | duration | 2 min | 2 min | both: `<= 0` → default |

**Naming divergence:** Java still uses the legacy `userCache*`; .NET modernised to `ContextCache*`.

---

## 10. Application info, wrapper info

| Option | Java | .NET | Type | Default | Notes |
|---|---|---|---|---|---|
| Application ID | `applicationInfo(Components.applicationInfo().applicationId(String))` | `ApplicationInfo(Components.ApplicationInfo().ApplicationId(string))` | string | none | data |
| Application version | `applicationVersion(String)` | `ApplicationVersion(string)` | string | none | data |
| Application name | **absent** | `ApplicationName(string)` | string | none | **.NET-only** |
| Application version name | **absent** | `ApplicationVersionName(string)` | string | none | **.NET-only** |
| Validation | at *header-build* time in `Util.applicationTagHeader`: must match `^[\w.-]+$` and `<= 64` chars, else the value is dropped with a warning | at *set* time in `ApplicationInfoBuilder.ValidatedThenSet`: spaces are **sanitized to `-`**, then `^[-a-zA-Z0-9._]+\z` and `<= 64` chars, else value ignored with a warning | — | — | **Divergence:** .NET silently rewrites spaces to hyphens; Java rejects any value containing a space. |
| Wrapper name | `wrapper(Components.wrapperInfo().wrapperName(String))` | `WrapperInfo(Components.WrapperInfo().Name(string))` | string | none | **naming divergence** (`wrapperName` vs `Name`) |
| Wrapper version | `wrapperVersion(String)` | `Version(string)` | string | none | same |
| Legacy wrapper location | `Components.httpConfiguration().wrapper(name, version)` | `Components.HttpConfiguration().Wrapper(name, version)` | strings | none | Top-level wrapper info takes precedence over the HTTP-level one in both. |

Both send `X-LaunchDarkly-Tags: application-id/<id> application-version/<ver>` (plus name/version-name in .NET).

---

## 11. Logging

| Option | Java | .NET | Type | Java default | .NET default | Data or code? |
|---|---|---|---|---|---|---|
| Log adapter | `logging(Components.logging(LDLogAdapter))` or `.adapter(LDLogAdapter)` | `Logging(ILogAdapter)` or `.Adapter(ILogAdapter)` | object | **SLF4J if `org.slf4j.LoggerFactory` is on the classpath, else `Logs.toConsole()`** | `Logs.ToConsole` | **code-only** |
| Minimum level | `level(LDLogLevel)` | `Level(LogLevel)` | enum (`DEBUG/INFO/WARN/ERROR/NONE`) | `INFO` | `Info` | data |
| Base logger name | `baseLoggerName(String)` | `BaseLoggerName(string)` | string | `Loggers.BASE_LOGGER_NAME` (`com.launchdarkly.sdk.server.LDClient`) | `LogNames.DefaultBase` | data |
| Data-source-outage-as-error-after | `logDataSourceOutageAsErrorAfter(Duration)` | `LogDataSourceOutageAsErrorAfter(TimeSpan?)` | duration, nullable = disabled | **1 min** (`DEFAULT_LOG_DATA_SOURCE_OUTAGE_AS_ERROR_AFTER`) | **`null` = feature disabled** — `DefaultLogDataSourceAsErrorAfter` (1 min) is declared but never used as the builder default | data |
| Disable logging entirely | `Components.noLogging()` | `Components.NoLogging` | selector | — | — | data |

Note on Java: `Logs.level(...)` has no effect when the adapter delegates to an externally configured framework (SLF4J, java.util.logging), so `level` is only meaningful with the console/simple adapters.

---

## 12. Hooks, plugins, telemetry

| Option | Java | .NET | Type | Default | Data or code? |
|---|---|---|---|---|---|
| Hooks | `hooks(Components.hooks().setHooks(List<Hook>))` | `Hooks(Components.Hooks().Add(Hook))` or `Components.Hooks(IEnumerable<Hook>)` | list of objects | empty | **code-only** — `Hook` is an abstract class/subclass with `beforeEvaluation`/`afterEvaluation` callbacks. **API divergence:** Java replaces the whole list (`setHooks`), .NET appends (`Add`). |
| Plugins | `plugins(Components.plugins().setPlugins(List<Plugin>))` | `Plugins(Components.Plugins().Add(Plugin))` or `Components.Plugins(IEnumerable<Plugin>)` | list of objects | empty | **code-only.** Java marks plugin support "experimental and subject to change". Plugins contribute hooks at client construction. A declarative spec could plausibly express plugins by *name* + options if a registry existed; none does today. |
| OpenTelemetry tracing hook | `java-server-sdk-otel`: `TracingHook.builder().withSpans().withValue().withVariant()` (`withVariant` is the deprecated alias of `withValue`) | `pkgs/telemetry`: `TracingHook.Builder().CreateActivities(bool).IncludeValue(bool).IncludeVariant(bool).IncludeAllAttributesInSpan(bool).EnvironmentId(string)`; `TracingHook.Default()` | booleans + string | all `false` | The *hook itself* is code, but its options are booleans/strings and therefore data-shaped. **Divergence:** .NET has `IncludeAllAttributesInSpan` and `EnvironmentId`; Java does not. Java's flags are no-arg toggles (`withSpans()`), .NET's take `bool` with default `true`. |

---

## 13. AI SDK

| | Java (`lib/sdk/server-ai`, `LDAIClientImpl`) | .NET (`pkgs/sdk/server-ai`, `LdAiClient`) |
|---|---|---|
| Construction | `new LDAIClientImpl(LDClientInterface)` or `(LDClientInterface, LDLogger)` | `new LdAiClient(ILaunchDarklyClient)` |
| Config surface | **none** beyond the wrapped client + optional logger | **none** beyond the wrapped client |

"AI config" in both SDKs means flag-delivered model/prompt configuration (`AIConfig`, `LdAiConfig`), not SDK configuration. Nothing here is relevant to a declarative SDK-config spec except that the AI client needs an already-configured base client.

---

## 14. Notable divergences and oddities

**Different defaults for the same option**
1. `startWait` / `StartWaitTime`: Java **5 s**, .NET **10 s**.
2. Persistent-store cache TTL: Java **15 s**, .NET **30 s**.
3. Default polling base URI: Java `https://app.launchdarkly.com`, .NET `https://sdk.launchdarkly.com`.
4. `logDataSourceOutageAsErrorAfter`: Java default **1 min (enabled)**; .NET default **null (disabled)** despite a `DefaultLogDataSourceAsErrorAfter = 1 min` constant that is never used.
5. Redis connect timeout: Java 2 s (Jedis default), .NET 5 s. Redis operation timeout: Java 2 s; .NET declares 3 s (`Redis.DefaultOperationTimeout`) but never applies it, so the real default is the StackExchange.Redis `SyncTimeout` of 5 s.
6. DynamoDB prefix: Java `null`, .NET `""` (functionally equivalent, but not literally the same default).

**Naming mismatches for identical semantics**
- `socketTimeout` (Java) vs `ReadTimeout` (.NET).
- `userKeysCapacity` / `userKeysFlushInterval` (Java) vs `ContextKeysCapacity` / `ContextKeysFlushInterval` (.NET) — and .NET still *reports* them as `userKeysCapacity` in diagnostics.
- Big Segments `userCacheSize` / `userCacheTime` (Java) vs `ContextCacheSize` / `ContextCacheTime` (.NET).
- Wrapper `wrapperName` / `wrapperVersion` (Java) vs `Name` / `Version` (.NET).
- FDv2 mode selector `defaultMode()` (Java) vs `Default()` (.NET) — `default` is a C# keyword.
- Duplicate-key enum: `FAIL`/`IGNORE` (Java) vs `Throw`/`Ignore` (.NET).
- Hooks: `setHooks(list)` (replace) vs `Add(hook)` (append).

**Options one SDK has and the other lacks**
- Java-only: `threadPriority`, `enableGzipCompression` (events), `payloadFilter` (all data sources — .NET has **none**), `classpathResources` (file data), `staleValuesPolicy`, `recordCacheStats`, `socketFactory`, `sslSocketFactory`+`X509TrustManager`, `proxyHostAndPort` (string+int), `Components.httpBasicAuthentication`, FDv2 `FileData.initializer()`/`synchronizer()`, `TestDataV2`, Redis `tls`/`username`/`password`/`database` as first-class options, DynamoDB `region`/`endpoint`, Consul `host`/`port`, public `eventSender`, public `DataSystemBuilder.build()`.
- .NET-only: `SdkKey` on the config builder, `ResponseStartTimeout`, `MessageHandler`, `Proxy(IWebProxy)`, `CacheMaximumEntries`, `SkipMissingPaths`, `Parser`, `FileReader` (file data), `ApplicationName`, `ApplicationVersionName`, Redis `EndPoints`/`RedisConfiguration`/`RedisConfigChanges`/`Connection`, Consul `ConsulConfigChanges`, telemetry `IncludeAllAttributesInSpan` + `EnvironmentId`, internal extended-backoff knobs on the FDv1 streaming/polling builders.

**Unit / type representation**
- Java uses `java.time.Duration` everywhere; .NET uses `TimeSpan`. Neither has ms/second-suffixed scalar setters *except* the persistent-store cache (`cacheMillis`/`cacheSeconds` vs `CacheMillis`/`CacheSeconds` — Java takes `long`, .NET takes `int`). A declarative spec needs one canonical duration encoding (e.g. ISO-8601 or ms integer) mapped onto both.
- "Cache forever" is encoded as a negative duration in both (`Duration.ofMillis(-1)` / `Timeout.InfiniteTimeSpan`), which a naive "duration must be non-negative" schema rule would break.
- Java `privateAttributes`/`.NET PrivateAttributes` take attribute-*reference* strings (`/a/b` escaping rules), not plain names — declarative config must document the reference syntax.

**Validation / clamping inconsistencies** (both silently coerce rather than erroring, which a declarative loader probably should not imitate silently)
- Poll interval: 30 s minimum in both (values below are silently raised).
- Diagnostic recording interval: 60 s minimum in both.
- .NET clamps `Capacity`, `FlushInterval`, `ContextKeysCapacity`, `ContextKeysFlushInterval` (`<= 0` → default); **Java clamps none of these** — a Java user can set `capacity(0)` or a negative flush interval.
- Java clamps Big Segments `userCacheSize`/`userCacheTime`; .NET clamps neither.
- Java clamps `threadPriority` into 1–10.
- SDK key: Java throws on non-ASCII; .NET silently discards malformed keys and logs an error later.
- `ApplicationInfo`: .NET rewrites spaces to `-` and validates at set time; Java validates at header-build time and drops values containing spaces.

**Cannot be expressed as data (code-only) — the hard boundary for a declarative spec**
- Any custom `ComponentConfigurer`/`IComponentConfigurer` implementation (data source, data store, event processor, big segment store, event sender).
- Log adapters (`LDLogAdapter` / `ILogAdapter`) — only `level` and `baseLoggerName` are data.
- Hooks and plugins (`Hook`, `Plugin` subclasses). Telemetry hook *options* are data, but instantiating the hook is code.
- HTTP: Java `socketFactory`, `sslSocketFactory` + `X509TrustManager`, custom `HttpAuthentication`; .NET `HttpMessageHandler`, `IWebProxy`. **Neither SDK offers a data-expressible custom CA / TLS configuration** (no "ca_file" style option) — a declarative spec would need new API surface in both.
- File data source: .NET `Parser` (a `Func<string,object>`) and `FileReader`.
- Store integrations: Jedis `JedisPoolConfig`; StackExchange `ConfigurationOptions` / `IConnectionMultiplexer` / `RedisConfigChanges` lambda; AWS `AwsCredentialsProvider` / `AmazonDynamoDBConfig` / `ClientOverrideConfiguration` / existing clients; Consul `ConsulClient` / `ConsulConfigChanges` lambda.
- `TestData` / `TestDataV2` (flags are constructed via API calls).

**Deprecations**
- Java: `payloadFilter(String)` on all three FDv2 builders (`FDv2PollingInitializerBuilder`, `FDv2PollingSynchronizerBuilder`, `FDv2StreamingSynchronizerBuilder`) is `@Deprecated` as of 7.17.0; setting it logs `DEPRECATED_PAYLOAD_FILTER_MESSAGE` and it is not applied in FDv2. The FDv1 `StreamingDataSourceBuilder`/`PollingDataSourceBuilder` `payloadFilter` is still supported.
- Java otel: `TracingHook.Builder.withVariant()` is the legacy alias of `withValue()`.
- .NET: no deprecated *configuration* options (the only `[Obsolete]` in the server SDK is `FeatureFlagsStateBuilder.Valid`).
- Both repos have archived/deprecated predecessor repositories; a spec targeting "the Java SDK" or "the .NET SDK" should cite `java-core` / `dotnet-core`.

**Other oddities**
- .NET `ConfigurationBuilder(Configuration copyFrom)` silently drops `WrapperInfo` (Java's `fromConfig` preserves it) — a genuine bug.
- Both SDKs generate a per-client instance id (UUID/GUID) sent as `X-LaunchDarkly-Instance-Id`; it is *not* user-configurable in either, so a spec-level `instance_id` option would require new API.
- The FDv2 `DataSystem` path *overrides* `dataSource`/`dataStore` in both SDKs, so a declarative schema must make the two paths mutually exclusive (or define precedence) rather than merging them.
- Java's FDv2 model has distinct `Initializer` and `Synchronizer` types; .NET reuses `IDataSource` for both roles. A cross-SDK schema should model roles (initializer/synchronizer) rather than types.
- `Components.serviceEndpoints()` "all-or-nothing" semantics: partially specifying endpoints produces a warning and default fallback rather than an error — worth making an explicit error in declarative config.
