# Property naming derivation

Decision 22: **the Go SDK is the reference for property names**, as it already is for default
values (decision 14). Where Go has no equivalent option, fall to **Java**, then **Python**.

## The rule, precisely

1. A property's **word** comes from the name Go's public API uses for that concept —
   the `ldcomponents` builder method or the `ldclient.Config` field — converted to snake_case.
2. A property's **group** comes from the Go builder that owns the option
   (`ldcomponents.HTTPConfiguration()` -> `http`, `ldcomponents.Logging()` -> `logging`).
3. Where Go's literal field name **stutters** against its own group, the redundant prefix is
   dropped (`ApplicationInfo.ApplicationID` -> `application_info.id`, not
   `application_info.application_id`). The three places this applies are marked below.
4. Where Go expresses a choice by **swapping a component** rather than setting a value
   (`SendEvents()`/`NoEvents()`, `Logging()`/`NoLogging()`), the spec uses a boolean named
   `enabled` in that group.
5. `_ms` is appended to every duration per decision 6. Go's durations are `time.Duration`, so
   the suffix is additive and never conflicts with a Go name.
6. **Go's builder API wins over Go's diagnostic-event field names.** Go's diagnostic payload
   still emits the legacy `userKeysCapacity` / `userKeysFlushIntervalMillis` while its builder
   says `ContextKeysCapacity` / `ContextKeysFlushInterval`. The builder is the public API and
   the current vocabulary, so the spec says `context_keys_*`.

## Root

| Property | Go source | Note |
|---|---|---|
| `sdk_key` | — | Go takes it as a positional argument to `MakeClient`, not a `Config` field. Java has no config-level setter either. Falls through to Python's `Config(sdk_key=...)`. |
| `sdk_key_file` | — | No SDK has this; introduced by decision 10, named after Relay's `*_FILE` convention. |
| `offline` | `Config.Offline` | |
| `start_wait_ms` | — | Go passes `waitFor` as an argument to `MakeCustomClient`; not config. Falls to Java's `startWait`. Needs new API in Go, Python, and Ruby to be settable from a document. |
| `diagnostic_opt_out` | `Config.DiagnosticOptOut` | Stays at the **root**, not under `events`, because that is where Go puts it — even though its sibling `diagnostic_recording_interval_ms` lives on the events builder. The split is Go's, and the double negative is Go's too. Flagged below. |
| `hooks` | `Config.Hooks` | |
| `plugins` | `Config.Plugins` | Documented experimental in Go. |

## `application_info`

From `Config.ApplicationInfo`. Stutter rule applies.

| Property | Go source |
|---|---|
| `id` | `ApplicationInfo.ApplicationID` |
| `version` | `ApplicationInfo.ApplicationVersion` |

Go supports no other fields. `name` and `version_name` exist only in .NET, so they fall through
Go -> Java -> Python and land nowhere: they are omitted from v1.

## `service_endpoints`

From `Config.ServiceEndpoints`. Named `service_endpoints`, not `endpoints`, because that is Go's
field name.

| Property | Go source |
|---|---|
| `streaming` | `ServiceEndpoints.Streaming` |
| `polling` | `ServiceEndpoints.Polling` |
| `events` | `ServiceEndpoints.Events` |
| `relay_proxy` | `ldcomponents.RelayProxyEndpoints(uri)` — sets all three |
| `allow_partial_specification` | `ServiceEndpoints.WithPartialSpecification()` — the opt-out from the partial-specification error |

`ldcomponents.RelayProxyEndpointsWithoutEvents` is not given its own property; it is expressible
as `relay_proxy` plus an explicit `events`.

## `data_system`

From `Config.DataSystem` / `ldcomponents.DataSystem()`.

| Property | Go source |
|---|---|
| `initializers` | `.Initializers(...)` — ordered list |
| `synchronizers` | `.Synchronizers(...)` — ordered list |
| `fdv1_compatible_synchronizer` | `.FDv1CompatibleSynchronizer(cfg)` — Go's name wins over Rust's `fdv1_fallback` |
| `endpoints` | `.WithEndpoints(Endpoints{Streaming, Polling})` — per-data-system override of `service_endpoints` |
| `data_store` | `.DataStore(store, mode)` |
| `data_store.mode` | `subsystems.DataStoreModeRead` / `DataStoreModeReadWrite` -> `read` / `read_write` |

### Source entries (`type` discriminated, per decision 13)

| `type` | Go source | Properties |
|---|---|---|
| `streaming` | `ldcomponents.StreamingDataSourceV2()` | `initial_reconnect_delay_ms` (`InitialReconnectDelay`), `base_uri` (`BaseURI`) |
| `polling` | `ldcomponents.PollingDataSourceV2()` | `poll_interval_ms` (`PollInterval`), `base_uri` |
| `file` | `ldfiledatav2.DataSource()` | `paths` (`FilePaths`, stutter rule), `duplicate_keys_handling` (`DuplicateKeysHandling`, values `fail`/`ignore`), `auto_update` |

`auto_update` is the one invented name here: Go models file watching as
`.Reloader(ldfilewatch.WatchFiles)`, a function, but `ldfilewatch.WatchFiles` is the only
implementation that exists, so the capability is a boolean in practice.

`payload_filter` (`PayloadFilter`) is **excluded from v1**: it is deprecated on Go's FDv2
builders (logs "Payload filtering is not supported with the FDv2 data system"), and .NET never
had it at all.

### `data_store`

From `ldcomponents.PersistentDataStore(impl)` plus the integration packages.

| Property | Go source |
|---|---|
| `cache.mode` | `.CacheTime()` / `.CacheForever()` / `.NoCaching()` -> `time` / `forever` / `off` |
| `cache.time_ms` | `.CacheTime(d)` (and its `.CacheSeconds(int)` shortcut) |
| `type: redis` -> `url`, `prefix` | `ldredis.DataStore().URL()`, `.Prefix()` |
| `type: dynamodb` -> `table_name`, `prefix` | `lddynamodb.DataStore(tableName)`, `.Prefix()` |
| `type: consul` -> `address`, `prefix` | `ldconsul.DataStore().Address()`, `.Prefix()` |

An explicit `cache.mode` replaces Go's internal sentinel encoding, where `CacheForever` is
`cacheTTL = -1ms` and `NoCaching` is `0`. A schema constraining durations to be non-negative
would otherwise reject "cache forever". Go's `.HostAndPort(host, port)` is omitted as redundant
with `url`.

## `events`

From `ldcomponents.SendEvents()`.

| Property | Go source |
|---|---|
| `enabled` | `SendEvents()` vs `NoEvents()` — component swap, so rule 4 applies |
| `capacity` | `.Capacity(int)` — Go's word wins over Python's `events_max_pending` |
| `flush_interval_ms` | `.FlushInterval(d)` |
| `all_attributes_private` | `.AllAttributesPrivate(bool)` |
| `private_attributes` | `.PrivateAttributes(...)` — attribute *references*, not names |
| `context_keys_capacity` | `.ContextKeysCapacity(int)` — see rule 6 |
| `context_keys_flush_interval_ms` | `.ContextKeysFlushInterval(d)` |
| `omit_anonymous_contexts` | `.OmitAnonymousContexts(bool)` |
| `enable_gzip` | `.EnableGzip(bool)` — Go's word wins over Rust's `compress_events` |
| `diagnostic_recording_interval_ms` | `.DiagnosticRecordingInterval(d)` |

## `http`

From `ldcomponents.HTTPConfiguration()`. Go's HTTP options are flat, so the spec's are too —
no nested `proxy` or `tls` objects.

| Property | Go source | Note |
|---|---|---|
| `connect_timeout_ms` | `.ConnectTimeout(d)` | Go also uses this as the whole-request timeout |
| `socket_timeout_ms` | — | Go has **no** separate read timeout. Falls to Java's `socketTimeout`, which beats .NET's `ReadTimeout`. |
| `proxy_url` | `.ProxyURL(string)` | |
| `ca_cert_file` | `.CACertFile(path)` | Go's `.CACert([]byte)` is code-only; the file path is data. Expressible today in Go and Python only. |
| `headers` | `.Header(key, value)` | Singular in Go because it is called repeatedly; the property is a map. Go permits overriding `Authorization` and `User-Agent`, which makes this security-relevant. |
| `wrapper_name`, `wrapper_version` | `.Wrapper(name, version)` | |
| `user_agent` | `.UserAgent(string)` | |

Go's `ldhttp` transport options (`IdleConnTimeoutOption`, `MaxIdleConnsOption`,
`MaxIdleConnsPerHostOption`, `DisableKeepAlivesOption`) are conceptually data but reachable only
through a `[]ldhttp.TransportOption`. Deferred past v1.

## `logging`

From `ldcomponents.Logging()`.

| Property | Go source |
|---|---|
| `enabled` | `Logging()` vs `ldcomponents.NoLogging()` — rule 4 |
| `min_level` | `.MinLevel(ldlog.Debug\|Info\|Warn\|Error)` — **not** `level` |
| `log_evaluation_errors` | `.LogEvaluationErrors(bool)` |
| `log_context_key_in_errors` | `.LogContextKeyInErrors(bool)` |
| `log_data_source_outage_as_error_after_ms` | `.LogDataSourceOutageAsErrorAfter(d)` — `0` disables escalation |

Rust has no logging configuration at all, so this whole group warns once and is ignored there.

## `big_segments`

From `ldcomponents.BigSegments(store)`.

| Property | Go source |
|---|---|
| `store` | `ldredis.BigSegmentStore()`, `lddynamodb.BigSegmentStore(tableName)` |
| `context_cache_size` | `.ContextCacheSize(int)` |
| `context_cache_time_ms` | `.ContextCacheTime(d)` — Go says Time, not TTL |
| `status_poll_interval_ms` | `.StatusPollInterval(d)` |
| `stale_after_ms` | `.StaleAfter(d)` |

Configured separately from `data_system.data_store` and may point at a different database.
Consul is not supported as a big-segment store in any SDK.

## `hooks`

| `type` | Go source | Properties |
|---|---|---|
| `tracing` | `ldotel.NewTracingHook(...)` | `spans` (`WithSpans`), `value` (`WithValue`), `environment_id` (`WithEnvironmentID`) |

`WithVariant()` is a legacy alias of `WithValue()` and is omitted.

## Three places the rule produces something awkward

These were reviewed and **kept as Go dictates**. Recorded here so the next reader knows they were
a choice rather than an oversight.

1. **`diagnostic_opt_out` at the root, `events.diagnostic_recording_interval_ms` under events.**
   Go splits them that way (`Config.DiagnosticOptOut` against
   `SendEvents().DiagnosticRecordingInterval()`), so rule 1 keeps the split. Two related settings
   land in different groups, and it is a double negative in a format that otherwise uses positive
   booleans. The alternative considered was `events.diagnostics: {enabled, recording_interval_ms}`.
2. **`service_endpoints` rather than `endpoints`.** Faithful to `Config.ServiceEndpoints`, though
   "service" carries no information in a document that only ever describes one.
3. **`application_info` rather than `application`.** `_info` is an artifact of Go needing a struct
   type name. Rule 3 already strips the stutter from the fields, so the group name could have
   taken the same treatment.

## One invented name

`auto_update` on the `file` data source has no Go equivalent to transliterate. Go models file
watching as `.Reloader(ldfilewatch.WatchFiles)` — a function — but `ldfilewatch.WatchFiles` is the
only implementation that exists, so the capability is a boolean in practice. This is the only
property in the schema whose name is not derived from an existing SDK.
