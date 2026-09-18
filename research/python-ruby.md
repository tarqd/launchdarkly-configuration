# LaunchDarkly server-side SDK configuration: **Python** and **Ruby**

Research input for a cross-SDK declarative configuration spec (file + env var, OTel-style).

| | Python | Ruby |
|---|---|---|
| Repo | `launchdarkly/python-server-sdk` | `launchdarkly/ruby-server-sdk` |
| Version inspected | **9.17.0** (`pyproject.toml`) | **8.18.0** (`lib/ldclient-rb/version.rb`) |
| Primary config file | `/tmp/.../python-server-sdk/ldclient/config.py` (+ `ldclient/async_config.py`) | `/tmp/.../ruby-server-sdk/lib/ldclient-rb/config.rb` |
| Config shape | `Config(**kwargs)` — **flat keyword args**, exposed as read-only `@property`. Two nested value objects: `HTTPConfig`, `BigSegmentsConfig`. Plus opt-in `DataSystemConfig` (FDv2). | `Config.new(opts = {})` — **flat symbol-keyed options hash**, exposed as `attr_reader` (booleans as `foo?`). Nested: `BigSegmentsConfig`, `DataSystemConfig`. **No `HTTPConfig` equivalent — HTTP options are top-level flat keys.** |
| Persistent stores | **In-repo** (`ldclient/integrations/__init__.py`): `Redis`, `DynamoDB`, `Consul`. There are *no* separate `python-server-sdk-redis/-dynamodb/-consul` repos. | **In-repo** (`lib/ldclient-rb/integrations/*.rb`): `Redis`, `DynamoDB`, `Consul`. Same — no separate gems. |
| Async variant | `AsyncConfig` / `AsyncBigSegmentsConfig` / `AsyncDataSystemConfig` in `ldclient/async_config.py` — **byte-for-byte the same option names, types and defaults** as `Config`; only the component *types* differ (`AsyncFeatureStore`, `AsyncHook`, …). Experimental. | none |

## 0. Structural headline: both SDKs are FLAT

Neither SDK has the nested builder tree that Java/.NET/Go use (`Components.streamingDataSource().initialReconnectDelay(...)`). Both are **one flat namespace of prefixed names**, which makes them the *closest existing analogue to a flat declarative file*, but the prefixes are inconsistent and the logical grouping is only implied by the name. Mapping to logical groups:

| Logical group | Python flat names | Ruby flat names |
|---|---|---|
| credential | `sdk_key` (on `Config`) | *(not on `Config` — positional arg to `LDClient.new`)* |
| service endpoints | `base_uri`, `stream_uri`, `events_uri` | `base_uri`, `stream_uri`, `events_uri` |
| mode | `offline`, `use_ldd` | `offline`, `use_ldd` |
| data source | `stream`, `poll_interval`, `initial_reconnect_delay`, `payload_filter_key`, `update_processor_class`, `feature_requester_class` | `stream`, `poll_interval`, `initial_reconnect_delay`, `payload_filter_key`, `data_source` |
| events | `send_events`, `events_max_pending`, `flush_interval`, `context_keys_capacity`, `context_keys_flush_interval`, `all_attributes_private`, `private_attributes`, `omit_anonymous_contexts`, `enable_event_compression`, `event_processor_class` | `send_events`, `capacity`, `flush_interval`, `context_keys_capacity`, `context_keys_flush_interval`, `all_attributes_private`, `private_attributes`, `omit_anonymous_contexts`, `compress_events` |
| diagnostics | `diagnostic_opt_out`, `diagnostic_recording_interval` | `diagnostic_opt_out`, `diagnostic_recording_interval` |
| http | **nested** `http=HTTPConfig(connect_timeout, read_timeout, http_proxy, ca_certs, cert_file, disable_ssl_verification)` | **flat** `connect_timeout`, `read_timeout`, `socket_factory`, `cache_store` |
| data store | `feature_store` | `feature_store` |
| big segments | **nested** `big_segments=BigSegmentsConfig(...)` | **nested** `big_segments: BigSegmentsConfig.new(...)` |
| metadata | `application` (dict), `wrapper_name`, `wrapper_version` | `application` (hash), `wrapper_name`, `wrapper_version` |
| extensibility | `hooks`, `plugins` | `hooks`, `plugins` |
| logging | *(none — uses stdlib `logging`)* | `logger` |
| FDv2 | `datasystem_config` (nested builders) | `data_system_config` (nested builders) |
| init blocking | *(not on Config)* `LDClient(config, start_wait=5)` / module global `ldclient.start_wait` | *(not on Config)* `LDClient.new(sdk_key, config, wait_for_sec = 5)` |
| misc | `defaults` (dict of per-flag fallbacks) | — |

---

## 1. Credential, mode, endpoints

| Option | Python name / type / default | Ruby name / type / default | Semantics | Data-expressible? |
|---|---|---|---|---|
| SDK key | `sdk_key`: str, **required positional-or-kw on `Config`** | **not a `Config` option**; `LDClient.new(sdk_key, config, wait_for_sec)` — positional, may be `nil` in offline / LDD+no-events / custom-data-source+no-events configurations (else `ArgumentError`) | auth credential | yes (secret) |
| offline | `offline`: bool, `False` | `offline`: bool, `false` (reader `offline?`) | return defaults for all flags, no network | yes |
| daemon mode | `use_ldd`: bool, `False` | `use_ldd`: bool, `false` (reader `use_ldd?`) | read flags only from the persistent store (Relay Proxy daemon mode); `stream`/`poll_interval` ignored | yes |
| polling/base URI | `base_uri`: str, **`https://app.launchdarkly.com`** | `base_uri`: str, **`https://sdk.launchdarkly.com`** (`PollingDataSourceBuilder::DEFAULT_BASE_URI`) | base for `/sdk/latest-all` (FDv1) and `/sdk/poll` (FDv2) | yes |
| stream URI | `stream_uri`: str, `https://stream.launchdarkly.com` | `stream_uri`: str, `https://stream.launchdarkly.com` | base for `/flags` (FDv1) / `/sdk/stream` (FDv2) | yes |
| events URI | `events_uri`: str, `https://events.launchdarkly.com` | `events_uri`: str, `https://events.launchdarkly.com` | base for `/bulk` and `/diagnostic` | yes |

**Validation / normalization**
- Python: all three URIs `.rstrip('/')`. `sdk_key` goes through `validate_sdk_key_format()` (`ldclient/impl/util.py`): rejects non-`str`, length > **8192**, or any char outside `[a-zA-Z0-9._-]` → **replaced with `""` and a warning logged** (not an exception). `Config._validate()` logs `"Missing or blank SDK key"` if not offline and key is `""`.
- Ruby: all three URIs `.chomp("/")`. **No SDK-key format/length validation at all.**

---

## 2. Data source (FDv1 — the default path)

| Option | Python | Ruby | Semantics | Notes |
|---|---|---|---|---|
| streaming on/off | `stream`: bool, `True` | `stream`: bool, `true` (reader `stream?`) | use SSE instead of polling | Ruby uses `opts.has_key?(:stream)` so explicit `false` is honored |
| poll interval | `poll_interval`: float **seconds**, `30` | `poll_interval`: float **seconds**, `30` (`PollingDataSourceBuilder::DEFAULT_POLL_INTERVAL`) | poll period when `stream=false` | **Clamping differs — see §11** |
| initial reconnect delay | `initial_reconnect_delay`: float **seconds**, `1` | `initial_reconnect_delay`: float **seconds**, `1` (`StreamingDataSourceBuilder::DEFAULT_INITIAL_RECONNECT_DELAY`) | base of SSE exponential backoff | no clamping either SDK |
| payload filter | `payload_filter_key`: Optional[str], `None` | `payload_filter_key`: String|nil, `nil` | filtered environment; appended as `?filter=`. No effect on FDv2 or on TestData/FileData | Ruby **validates** `^[a-zA-Z0-9][._\-a-zA-Z0-9]*$` → else warn + `nil` (`Impl::Util.validate_payload_filter_key`). **Python does not validate.** |
| custom data source | `update_processor_class`: callable `(Config, FeatureStore, threading.Event) -> UpdateProcessor`, `None` | `data_source`: an object implementing `Interfaces::DataSource`, **or** a lambda `(sdk_key, config)`, `nil` | replaces streaming/polling | **code-only** |
| custom flag requester | `feature_requester_class`: callable `(sdk_key, config)`, `None` | *(none)* | replaces polling HTTP layer | **code-only** |
| stream read timeout | hard-coded `stream_read_timeout = 5*60` (`impl/datasource/streaming.py`); FDv2 `STREAM_READ_TIMEOUT = 5*60` | hard-coded `READ_TIMEOUT_SECONDS = 300` (`impl/data_source/stream.rb`); FDv2 `STREAM_READ_TIMEOUT = 5*60` | not configurable | n/a |
| stream backoff caps | hard-coded `MAX_RETRY_DELAY=30`, `BACKOFF_RESET_INTERVAL=60`, `JITTER_RATIO=0.5` | delegated to `ld-eventsource` gem | not configurable | n/a |

---

## 3. Events

| Option | Python name / type / default | Ruby name / type / default | Semantics |
|---|---|---|---|
| send events | `send_events`: Optional[bool] → stored bool, `True` | `send_events`: bool, `true` | send analytics events |
| buffer capacity | **`events_max_pending`**: int, `10000` | **`capacity`**: int, `10000` | max buffered events before dropping |
| flush interval | `flush_interval`: float **seconds**, **`5`** | `flush_interval`: float **seconds**, **`10`** | periodic flush period |
| all attrs private | `all_attributes_private`: bool, `False` | `all_attributes_private`: bool, `false` | redact every attribute except key |
| private attrs | `private_attributes`: `Set[str]`, `set()` (read back as `List[str]`) | `private_attributes`: Array<String>, `[]` | attribute references (`email`, `/address/street`) to redact |
| context key LRU size | `context_keys_capacity`: int, `1000` | `context_keys_capacity`: int, `1000` | dedupe window for index events |
| context key LRU reset | `context_keys_flush_interval`: float **seconds**, `300` | `context_keys_flush_interval`: float **seconds**, `300` | period at which the known-keys set is cleared |
| omit anonymous | `omit_anonymous_contexts`: bool, `False` | `omit_anonymous_contexts`: bool, `false` | drop anonymous contexts from index/identify events |
| gzip payloads | **`enable_event_compression`**: bool, `False` | **`compress_events`**: bool, `false` | GZIP the event payload (off by default for old Relay compat) |
| custom processor | `event_processor_class`: callable `(Config) -> EventProcessor`, `None` | *(none)* | **code-only** |

**Behavioral divergence:** Python **mutates** the value — `if offline is True: send_events = False` in `Config.__init__`, so `config.send_events` *reads back* `False`. Ruby leaves `send_events` at its configured value and only checks `offline?` at runtime (`ldclient.rb:196`). A declarative spec that round-trips config will observe different values for the same input.

**Clamping:** Ruby event *inbox* queue is clamped to a floor of 100: `SizedQueue.new(config.capacity < 100 ? 100 : config.capacity)` (`events.rb:135`). Python applies no floor to `events_max_pending`.

---

## 4. Diagnostics

| Option | Python | Ruby | Semantics |
|---|---|---|---|
| opt out | `diagnostic_opt_out`: bool, `False` | `diagnostic_opt_out`: bool, `false` (reader `diagnostic_opt_out?`) | disable SDK diagnostic telemetry |
| recording interval | `diagnostic_recording_interval`: **int** seconds, `900`, min `60` | `diagnostic_recording_interval`: Float seconds, `900`, min `60` | period of periodic diagnostic event |

**Clamping divergence (important):**
- Python: `max(diagnostic_recording_interval, 60)` → setting `30` yields **60**.
- Ruby: `opts[:diagnostic_recording_interval] > 60 ? opts[...] : 900` → setting `30` yields **900** (falls back to the *default*, not the minimum). Setting exactly `60` also yields `900`.

Python's diagnostic payload (`impl/events/diagnostics.py`) is a useful list of what LD considers "the config": `eventsCapacity`, `eventsFlushIntervalMillis`, `userKeysCapacity`, `userKeysFlushIntervalMillis`, `diagnosticRecordingIntervalMillis`, etc. — note it converts seconds → millis, i.e. the wire format is **millis** while the SDK surface is **float seconds**.

---

## 5. HTTP

Python groups these in a nested `HTTPConfig` value object; Ruby scatters them flat on `Config`. **The two sets barely overlap.**

| Concern | Python (`http=HTTPConfig(...)`) | Ruby (top-level `Config` opts) |
|---|---|---|
| connect timeout | `connect_timeout`: float seconds, **`10`** | `connect_timeout`: float seconds, **`2`** (`Impl::DataSystem::HttpConfigOptions::DEFAULT_CONNECT_TIMEOUT`) |
| read timeout | `read_timeout`: float seconds, **`15`** | `read_timeout`: float seconds, **`10`** (`HttpConfigOptions::DEFAULT_READ_TIMEOUT`) |
| explicit proxy | `http_proxy`: Optional[str], `None` — full URI, used for **both** http and https targets; overrides env vars; basic-auth in the URI becomes `Proxy-Authorization` | **NOT SUPPORTED.** Ruby only gets a proxy from `URI#find_proxy`, i.e. **environment variables only** (`impl/util.rb:new_http_client`) |
| custom CA bundle | `ca_certs`: Optional[str] (file path), `None` — defaults to `certifi.where()` | **not supported** |
| client cert | `cert_file`: Optional[str] (file path), `None` | **not supported** |
| disable TLS verify | `disable_ssl_verification`: bool, `False` → `cert_reqs='CERT_NONE'` | **not supported** |
| socket factory | **not supported** | `socket_factory`: object responding to `open(uri, timeout)`, `nil` → passed as `HTTP::Client` `socket_class`. **code-only** |
| HTTP response cache | **not supported** (Python keeps its own in-process ETag dict in `impl/datasource/feature_requester.py`) | `cache_store`: object with `faraday-http-cache` semantics; default **`Rails.cache` if Rails is loaded, else `Impl::ThreadSafeMemoryStore.new`**. Polling mode only. **code-only** |

`cert_file` in Python is actually *not* wired into `create_pool_manager` (only `ca_certs` and `disable_ssl_verification` are) — worth flagging as a latent no-op.

---

## 6. Big Segments (nested in both)

`BigSegmentsConfig` (Python `ldclient/config.py`; Ruby `lib/ldclient-rb/config.rb`) — **identical names, types and defaults in both SDKs**:

| Option | Type | Default | Semantics | Data? |
|---|---|---|---|---|
| `store` | `BigSegmentStore` instance | Python `None`; Ruby **required kwarg** `store:` | the big-segment database adapter | **code-only** (must be a constructed Redis/DynamoDB store object) |
| `context_cache_size` | int | `1000` | max contexts whose membership is cached | yes |
| `context_cache_time` | float **seconds** | `5` | membership cache TTL | yes |
| `status_poll_interval` | float **seconds** | `5` | store availability/staleness poll period | yes |
| `stale_after` | float **seconds** | `120` (Ruby literal `2 * 60`) | data older than this is `STALE` | yes |

Ruby constants are exposed publicly: `BigSegmentsConfig::DEFAULT_CONTEXT_CACHE_SIZE`, `DEFAULT_CONTEXT_CACHE_TIME`, `DEFAULT_STATUS_POLL_INTERVAL`, `DEFAULT_STALE_AFTER`. Python's defaults are only in the signature.

Python: `Config(big_segments=None)` → replaced with `BigSegmentsConfig()` (store `None`). Ruby: `opts[:big_segments] || BigSegmentsConfig.new(store: nil)`.

---

## 7. Data store / persistent stores

The store is always passed as a **constructed object** in both SDKs (`feature_store` / `data_store`), so a declarative spec must model *factory parameters* (type + options) rather than the object.

### 7a. In-memory default
- Python: `feature_store: Optional[FeatureStore]` → `InMemoryFeatureStore()` if falsy.
- Ruby: `feature_store` → `Config.default_feature_store` = `InMemoryFeatureStore.new`.

### 7b. Local cache wrapper

| | Python | Ruby |
|---|---|---|
| Type | `CacheConfig(expiration=15.0, capacity=1000)` value object, `ldclient/feature_store.py`; helpers `CacheConfig.default()`, `CacheConfig.disabled()` (`expiration=0`) | plain keys `:expiration` (15) and `:capacity` (1000) merged into the **same** options hash as the store's own options (`Integrations::Util::CachingStoreWrapper`) |
| `expiration` | float seconds, `15.0`; **`<= 0` disables caching** | Integer/Float seconds, `15`; **`0` = no local caching** (`> 0` check) |
| `capacity` | int, `1000` | Integer, `1000` |
| FDv2 note | Under FDv2 the persistent-store cache is swapped for a no-op once the in-memory store initializes, so TTL/capacity only matter during bootstrap (documented in both SDKs) | same |

Ruby's flattening of cache options into the store options hash is notable: `Redis.new_feature_store(redis_url:, prefix:, expiration:, capacity:, logger:, max_connections:, pool:, pool_shutdown_on_close:)` is a single undifferentiated bag.

### 7c. Redis

| Option | Python `Redis.new_feature_store(...)` / `new_big_segment_store(...)` | Ruby `Integrations::Redis.new_feature_store(opts)` / `new_big_segment_store(opts)` |
|---|---|---|
| URL | `url`: str, `redis://localhost:6379/0` (`Redis.DEFAULT_URL`) | `:redis_url`: String, `redis://localhost:6379/0` (`Redis.default_redis_url`) — shortcut that sets `redis_opts[:url]` |
| key prefix | `prefix`: str, `launchdarkly` (`Redis.DEFAULT_PREFIX`); async variants default `None` → `'launchdarkly'` | `:prefix`: String, `launchdarkly` (`Redis.default_prefix`) |
| extra client opts | `redis_opts`: dict, `{}` → `redis.ConnectionPool.from_url(url, **redis_opts)` | `:redis_opts`: Hash → `::Redis.new(redis_opts)` |
| pool size | **`max_connections`: int, `16` — DEPRECATED and UNUSED**; passing anything != 16 logs a warning telling you to use `redis_opts={'max_connections': N}` | `:max_connections`: Integer, **`16`** — live, `ConnectionPool.new(size: max_connections)` |
| custom pool | not supported | `:pool`: ConnectionPool object (**code-only**) |
| pool lifecycle | n/a | `:pool_shutdown_on_close`: bool, `true` (only meaningful with `:pool`) |
| caching | `caching`: `CacheConfig`, `CacheConfig.default()` (feature store only) | `:expiration` / `:capacity` in the same hash |
| logger | n/a (stdlib logging) | `:logger`, default `Config.default_logger` (**code-only**) |
| undocumented | `test_update_hook` attr (test only) | `:test_hook` (deliberately undocumented) |
| async | `Redis.async_feature_store(url, prefix, caching, redis_opts)`, `Redis.async_big_segment_store(url, prefix, redis_opts)` | n/a |

Big-segment key layout (Ruby, informative): `<prefix>:big_segments_synchronized_on`, `:big_segment_include:`, `:big_segment_exclude:`.

### 7d. DynamoDB

| Option | Python `DynamoDB.new_feature_store(table_name, ...)` | Ruby `Integrations::DynamoDB.new_feature_store(table_name, opts)` |
|---|---|---|
| table | `table_name`: str, **required positional** | `table_name`: String, **required positional** |
| prefix | `prefix`: Optional[str], `None` (no prefix) | `:prefix`: String, `nil` → stored as `prefix + ":"` when present |
| client opts | `dynamodb_opts`: Mapping, `{}` → `boto3` client kwargs | `:dynamodb_opts`: Hash → `Aws::DynamoDB::Client.new(...)` |
| existing client | **not supported** | `:existing_client`: object (**code-only**); `:dynamodb_opts` ignored when set |
| caching | `caching`: `CacheConfig` | `:expiration` / `:capacity` |
| logger | n/a | `:logger` |
| big segments | `DynamoDB.new_big_segment_store(table_name, prefix, dynamodb_opts)` | `DynamoDB.new_big_segment_store(table_name, opts)` |
| async | `DynamoDB.async_feature_store(...)` (aioboto3) | n/a |

Table must pre-exist with partition key `namespace`, sort key `key` (both string). Credentials/region come from the AWS SDK's own env/config chain.

### 7e. Consul

| Option | Python `Consul.new_feature_store(...)` | Ruby `Integrations::Consul.new_feature_store(opts)` |
|---|---|---|
| host | `host`: Optional[str], `None` → python-consul default `localhost` | **not supported** |
| port | `port`: Optional[int], `None` → python-consul default `8500` | **not supported** |
| URL | **not supported** | `:url`: String → `Diplomat.configuration.url = url` |
| client config object | `consul_opts`: dict, `{}` → `consul.Consul(**opts)` | `:consul_config`: `Diplomat::Configuration` instance (**code-only**) |
| prefix | `prefix`: Optional[str], `None` → `launchdarkly` (`Consul.DEFAULT_PREFIX`), stored as `prefix + "/"` | `:prefix`: String, `launchdarkly` (`Consul.default_prefix`), stored as `prefix + '/'` |
| caching | `caching`: `CacheConfig` | `:expiration` / `:capacity` |
| logger | n/a | `:logger` |
| big segments | **not supported** for Consul | **not supported** for Consul |

Both use the sentinel key `<prefix>/$inited`.

---

## 8. File data source & test data source

| | Python | Ruby |
|---|---|---|
| FDv1 factory | `Files.new_data_source(paths, auto_update=False, poll_interval=1, force_polling=False)` → lambda for **`update_processor_class`** | `FileData.data_source(paths:, auto_update:, poll_interval:, force_polling:)` → lambda for **`data_source`** |
| `paths` | `List[str]`, required | Array (or String), `[]` |
| `auto_update` | bool, `False` | truthy, `nil` |
| `poll_interval` | float seconds, `1` | Float seconds, `1` |
| `force_polling` | bool, `False` | **implemented (`options[:force_polling]`) but NOT documented** in `file_data.rb` |
| native watcher | `watchdog` package if installed | `listen` gem if installed |
| FDv2 factory | `Files.new_data_source_v2(paths, poll_interval=1, force_polling=False)` → `FileDataSourceV2Builder`; builder methods `.poll_interval(f)`, `.force_polling(b)`; `DEFAULT_POLL_INTERVAL = 1` | `FileData.data_source_v2(paths:, poll_interval:)` → `FileDataSourceV2Builder`; **no `force_polling`**; poll_interval default `1` |
| test data | `ldclient.integrations.test_data.TestData.data_source()` → assign to `update_processor_class`; `test_datav2.TestDataV2` for FDv2 | `Integrations::TestData.data_source` → assign to `data_source`; `Integrations::TestDataV2` for FDv2 |

All of these are **code-only** in their current form, although `paths`/`poll_interval`/`auto_update`/`force_polling` are pure data and would be trivially declarable.

---

## 9. Application metadata, wrapper, instance id, hooks, plugins, logging

| Option | Python | Ruby | Notes |
|---|---|---|---|
| application | `application`: `Optional[dict]`, `None` → normalized to `{"id": "", "version": ""}` | `application`: Hash, `{}` → normalized to `{id: "", version: ""}` (symbol keys) | **Only `id` and `version` exist. Neither SDK supports `name` / `version_name`** (unlike Java/.NET). Sent as `X-LaunchDarkly-Tags: application-id/<id> application-version/<ver>` |
| application validation | `validate_application_value`: non-str → `""`; len > **64** → warn + `""`; any char outside `[a-zA-Z0-9._-]` → warn + `""` | identical rules in `Impl::Util.validate_application_value` (`.to_s` coercion first) | silent-discard-with-warning, never raises |
| wrapper name | `wrapper_name`: Optional[str], `None` | `wrapper_name`: String, `nil` | → `X-LaunchDarkly-Wrapper: <name>[/<version>]` |
| wrapper version | `wrapper_version`: Optional[str], `None`; **ignored unless `wrapper_name` set** | same | |
| wrapper override API | `Config.with_wrapper_information(name, version=None)` → shallow copy | `Config#with_wrapper_information(name, version=nil)` → `dup` with protected writers | for OpenFeature providers |
| instance id | `Config._instance_id`: Optional[str], set **by the SDK** (private) | `Config#instance_id`: `attr_accessor`, set by `LDClient.new` to `SecureRandom.uuid` | → `X-LaunchDarkly-Instance-Id`. **Not user-configurable in Python** (private, set post-construction); technically writable in Ruby but `@api private`. |
| hooks | `hooks`: `Optional[List[Hook]]`, `None` → `[]`; **non-`Hook` items silently filtered out** | `hooks`: Array, `[]`; `.keep_if { |h| h.is_a? Interfaces::Hooks::Hook }` | **code-only** (a declarative spec would need a plugin/hook *registry by name*) |
| plugins | `plugins`: `Optional[List[Plugin]]`, `None` → `[]`; non-`Plugin` filtered | `plugins`: Array, `[]`; `keep_if is_a? Interfaces::Plugins::Plugin` | **code-only**. Plugins receive `EnvironmentMetadata{sdk{name,version,wrapper_name,wrapper_version}, sdk_key, application{id,version}}` |
| logger | **no option** — uses stdlib `logging.getLogger('ldclient.util')` | `logger`: Logger, default **`Rails.logger` if Rails is loaded and responds to `logger`, else `Logger.new($stdout)` at `WARN`** | Ruby's is **code-only**; note the *implicit environment-dependent default* |
| per-flag defaults | `defaults`: dict, `{}` — `variation(key, ctx, default)` substitutes `config.defaults[key]` when present (`client.py:412`) | *(none)* | **Python-only, pure data.** Effectively an undocumented legacy feature; a genuine "config as data" precedent |

---

## 10. FDv2 / "data system" (experimental in both)

Both SDKs now ship an opt-in FDv2 data system with a small **nested builder** tree — the only nesting in either SDK beyond the value objects.

| | Python | Ruby |
|---|---|---|
| `Config` key | `datasystem_config`: `Optional[DataSystemConfig]`, `None` | `data_system_config`: `DataSystemConfig`, `nil` |
| module | `ldclient/datasystem.py` | `lib/ldclient-rb/data_system.rb` |
| presets | `datasystem.default()`, `.streaming()`, `.polling()`, `.custom()`, `.daemon(store)`, `.persistent_store(store)` | `DataSystem.default`, `.streaming`, `.polling`, `.custom`, `.daemon(store)`, `.persistent_store(store)` |
| builder | `ConfigBuilder`: `.initializers([...])`, `.synchronizers(*builders)` (**varargs; raises `ValueError` if empty**), `.fdv1_compatible_synchronizer(b)`, `.data_store(store, mode)`, `.build()` | `ConfigBuilder`: `.initializers([...])`, `.synchronizers([...])` (**array arg; no validation**), `.fdv1_compatible_synchronizer(b)`, `.data_store(store, mode)`, `.build` |
| store mode enum | `interfaces.DataStoreMode`: `READ_ONLY = 'read-only'`, `READ_WRITE = 'read-write'` | `Interfaces::DataSystem::DataStoreMode`: `READ_ONLY = :read_only`, `READ_WRITE = :read_write` |
| store-mode default | `ConfigBuilder` → `READ_ONLY`, but the `DataSystemConfig` **dataclass field default is `READ_WRITE`** (inconsistent) | `ConfigBuilder` → `READ_ONLY`; `DataSystemConfig.new` kwarg default also `READ_ONLY` |
| polling DS builder | `datasystem.polling_ds_builder()` → `.base_uri(str)`, `.poll_interval(float)`, `.http_options(HTTPConfig)`, `.requester(Requester)`; falls back to `config.base_uri` / `config.poll_interval` / `config.http` | `DataSystem.polling_ds_builder` → `.base_uri`, `.poll_interval`, `.socket_factory`, `.read_timeout`, `.connect_timeout`, `.requester`; `DEFAULT_BASE_URI = https://sdk.launchdarkly.com`, `DEFAULT_POLL_INTERVAL = 30` |
| streaming DS builder | `streaming_ds_builder()` → `.base_uri`, `.initial_reconnect_delay`, `.http_options` | `streaming_ds_builder` → `.base_uri`, `.initial_reconnect_delay`, `.socket_factory`, `.read_timeout`, `.connect_timeout`; `DEFAULT_BASE_URI = https://stream.launchdarkly.com`, `DEFAULT_INITIAL_RECONNECT_DELAY = 1` |
| FDv1 fallback builder | `fdv1_fallback_ds_builder()` → `FallbackToFDv1PollingDataSourceBuilder` (`.base_uri`, `.poll_interval`, `.http_options`) | `fdv1_fallback_ds_builder` → `FDv1PollingDataSourceBuilder` (same common HTTP setters + `.poll_interval`, `.requester`) |
| file DS builder | `datasystem.file_ds_builder(paths)` | via `FileData.data_source_v2` |
| endpoints | FDv2 poll `/sdk/poll`, stream `/sdk/stream`; FDv1 fallback poll `/sdk/latest-all` | identical (`FDV2_POLLING_ENDPOINT`, `FDV1_POLLING_ENDPOINT = "/sdk/latest-all"`) |

Important: **`payload_filter_key` is documented as having no effect under FDv2** in both SDKs, yet both FDv2 requesters *do* still append `?filter=` — the code and the docstring disagree.

Ruby doc bug: `data_system.rb`, `file_data.rb` and `test_data_v2.rb` all show `Config.new(data_system: ...)`, but the option `Config#initialize` actually reads is **`:data_system_config`**. `data_system:` is silently ignored.

Per-data-source HTTP overrides (`.http_options` / `.read_timeout` etc.) mean FDv2 introduces *scoped* HTTP config that shadows the global one — a declarative spec needs a per-source override slot.

## AI Config

Neither core repo contains any AI-config surface (`grep -rl "ai_config|AIConfig|ldai"` over `ldclient/` and `lib/` returns nothing). AI configs live in the separate `launchdarkly-server-sdk-ai` Python package / `launchdarkly-server-sdk-ai` Ruby gem, whose repos were **not reachable in this session** (GitHub access restricted to the working repo). They should be researched separately; the AI client wraps an already-constructed `LDClient`, so it is expected to add no transport-level config.

---

## 11. Validation / clamping rules (consolidated)

| Rule | Python | Ruby |
|---|---|---|
| URI trailing slash | `.rstrip('/')` on base/events/stream | `.chomp("/")` on base/stream/events |
| `poll_interval` floor | `max(poll_interval, 30.0)` — silent | `opts[:poll_interval] > 30 ? opts[:poll_interval] : 30` — silent; **note strict `>`, so `30` takes the default path (same value)** |
| `diagnostic_recording_interval` floor | `max(value, 60)` → **60** | `value > 60 ? value : 900` → **900** (resets to default, not the min) |
| event queue floor | none | inbox `SizedQueue` floored at **100** |
| `sdk_key` | non-str / >8192 chars / chars outside `[a-zA-Z0-9._-]` → `""` + warning; blank + not offline → warning | **none** |
| `application.id` / `.version` | non-str → `""`; >64 chars → warn + `""`; invalid chars → warn + `""` | same (after `.to_s`) |
| `payload_filter_key` | **none** | `^[a-zA-Z0-9][._\-a-zA-Z0-9]*$` else warn + `nil` |
| `hooks` / `plugins` | wrong-type entries silently dropped | wrong-type entries silently dropped (`keep_if`) |
| `synchronizers` (FDv2) | empty list → `ValueError` | no validation |
| `start_wait` / `wait_for_sec` | `> 60` logs a "we recommend blocking no longer than 60" warning | same warning in `start_up` |
| Redis `max_connections` (Python) | any value != 16 → deprecation warning, value discarded | n/a |
| `expiration <= 0` | disables the store cache | `expiration > 0` check; `0` disables |

**Pattern to note for the spec:** both SDKs *never raise* on bad scalar config. They log a warning and substitute a default or empty value. The only exceptions are `ArgumentError` for a `nil` SDK key in Ruby's `LDClient.new` and `ValueError` for empty FDv2 synchronizers in Python.

---

## 12. Existing environment variable support (prior art)

**There is no LaunchDarkly-specific (`LD_*`) environment variable support in either SDK.** `grep -rn "os.environ|os.getenv"` over `python-server-sdk/ldclient` (excluding tests) returns exactly one file; `grep -rn "ENV\[|ENV.fetch"` over `ruby-server-sdk/lib` returns **nothing**. So a declarative env-var layer would be entirely greenfield — but there are four kinds of *ambient* configuration already in play, all worth treating as precedent/collision risk:

### 12a. Proxy env vars — Python (`ldclient/impl/http.py`, `_get_proxy_url`)
The only direct `os.environ` read in the SDK. Hand-rolled (does **not** delegate to urllib3/requests):

| Variable | Read when | Behavior |
|---|---|---|
| `https_proxy` | target URI scheme is `https` | used as the proxy URL |
| `http_proxy` | target URI scheme is not `https` | used as the proxy URL |
| `no_proxy` | always | `*` disables all proxying; otherwise comma-separated entries, each either `host-suffix` or `host-suffix:port`; a suffix match (`target_host.endswith(entry)`) disables proxying |

Notes / gotchas:
- **Lowercase only.** `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY` are *not* read. This differs from `requests`, `curl`, and Ruby.
- Scheme selection is by the **target** URI's scheme, not by the proxy's — so a Relay Proxy reached over plain `http://` picks up `http_proxy`.
- `HTTPConfig(http_proxy=...)` **overrides** the env vars entirely, and unlike the env vars it applies regardless of target scheme.
- Default port assumption when the URI has no `//`: port 80, insecure.

### 12b. Proxy env vars — Ruby (`Impl::Util.new_http_client`)
`URI.parse(base_uri).find_proxy` — delegates to Ruby stdlib, which honors `http_proxy` / `HTTP_PROXY`, `https_proxy` / `HTTPS_PROXY`, `no_proxy` / `NO_PROXY` (with stdlib's CGI-environment guard that ignores lowercase `http_proxy` when `REQUEST_METHOD` is set). User/password in the proxy URI become `proxy_username`/`proxy_password`. **Since Ruby has no `http_proxy` config option at all, env vars are the *only* way to configure a proxy in the Ruby SDK** — a strong argument that env-var support is load-bearing, not merely convenient.

### 12c. Implicit framework detection — Ruby only
`Config.default_logger` and `Config.default_cache_store` both branch on `defined?(Rails)`. This is ambient, non-declarative configuration whose value cannot be expressed in a file; a declarative spec needs an explicit way to say "use the framework default".

### 12d. Transitive env vars from store/client libraries
Not SDK code, but they *are* observable configuration surface:
- **DynamoDB** (both SDKs): the AWS SDK credential/region chain — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_REGION`/`AWS_DEFAULT_REGION`, `AWS_PROFILE`, `AWS_ENDPOINT_URL_DYNAMODB`, plus `~/.aws/config`. Both SDKs' docstrings explicitly say "the DynamoDB client will try to get your AWS credentials and region name from environment variables and/or local configuration files".
- **Consul**: Ruby uses `Diplomat`, whose default configuration seeds its URL/token from Consul's conventional `CONSUL_HTTP_ADDR`/`CONSUL_HTTP_TOKEN` variables; Python uses `python-consul`, configured via `host`/`port`/`consul_opts`. (Not verified against the gem/package source in this session — flag as "verify before relying on it".)
- **Python TLS**: `ca_certs` defaults to `certifi.where()`, so `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` are *not* honored unless the user passes `ca_certs` explicitly.

### 12e. Non-`Config` global — Python only
`ldclient/__init__.py` defines a module-level mutable `start_wait = 5` that `set_config()`/`get()` read when constructing the singleton `LDClient`. Prior art for "configuration that lives outside the config object", and a natural env-var candidate (`ldclient.start_wait` is the init-timeout knob for singleton users).

---

## 13. Init-wait timeout (not a `Config` option in either SDK)

| | Python | Ruby |
|---|---|---|
| Where | `LDClient(config, start_wait: float = 5)`; `LDClient.postfork(start_wait=5)`; `AsyncLDClient.start(start_wait: float = 5.0)`; singleton path uses module global `ldclient.start_wait = 5` | `LDClient.new(sdk_key, config = Config.default, wait_for_sec = 5)`; `LDClient#postfork(wait_for_sec = 5)` |
| Units | float **seconds** | Float **seconds** |
| Default | `5` | `5` |
| `<= 0` | skip waiting entirely | same |
| `> 60` | warning logged | warning logged |
| Skipped when | `offline` or `use_ldd` | `offline?` or `use_ldd?` |

This is a real gap for a declarative spec: the single most commonly tuned knob is not part of the config object in either SDK.

---

## 14. Notable divergences and oddities

**Cross-SDK name divergences for the same concept**
1. Event buffer: Python **`events_max_pending`** vs Ruby **`capacity`**.
2. Gzip: Python **`enable_event_compression`** vs Ruby **`compress_events`**.
3. Custom data source: Python **`update_processor_class`** (a 3-arg factory) vs Ruby **`data_source`** (object *or* 2-arg lambda).
4. FDv2 entry point: Python **`datasystem_config`** vs Ruby **`data_system_config`** (and Ruby's own docs say `data_system:`, which is silently ignored).

**Default-value divergences for the same option**
5. **`base_uri`: Python `https://app.launchdarkly.com`, Ruby `https://sdk.launchdarkly.com`.** Same endpoint path (`/sdk/latest-all`), different hostname default. Ruby's FDv2 builders also default to `sdk.launchdarkly.com`. A spec picking one canonical default will change behavior for one of the two.
6. `flush_interval`: Python **5 s**, Ruby **10 s**.
7. `connect_timeout`: Python **10 s**, Ruby **2 s**. `read_timeout`: Python **15 s**, Ruby **10 s**. Five-fold spreads.

**Clamping / validation oddities**
8. Ruby's `diagnostic_recording_interval` falls back to the **default (900)** rather than the **minimum (60)** when below the minimum — and rejects the boundary value 60 itself because the comparison is `> 60`.
9. Python clamps `poll_interval` with `max(v, 30)`; Ruby uses `v > 30 ? v : 30`. Equivalent in effect but Ruby's is easy to misread.
10. Ruby floors the event inbox at 100 while `config.capacity` still reports whatever was set — the effective and reported values diverge.
11. Python rewrites `send_events` to `False` when `offline=True` (config value changes); Ruby preserves the value and checks `offline?` at use time. Round-tripping config is therefore lossy in Python.
12. Neither SDK validates numeric option *types* — passing a string where a float is expected fails later, at use.
13. Python `sdk_key` validation *silently blanks* an invalid key and then only *warns* about the blank key — an invalid key degrades to "no key" rather than erroring.
14. Ruby performs **zero** SDK-key validation.

**Capability gaps**
15. **TLS/proxy asymmetry is the biggest gap.** Python has `http_proxy`, `ca_certs`, `cert_file`, `disable_ssl_verification`; Ruby has **none of these** and only `socket_factory`. Conversely Ruby has `socket_factory` and `cache_store`; Python has neither. A common declarative schema cannot be fully satisfied by either SDK today.
16. Python's `HTTPConfig.cert_file` appears to be **dead** — `HTTPFactory.create_pool_manager` never passes it to urllib3.
17. `application` supports only `id` and `version` in both SDKs. **`name` and `version_name` are unsupported**, unlike Java/.NET. A spec with four application fields will need graceful degradation.
18. No `omit_anonymous_contexts`/private-attribute differences — these are well aligned.
19. Consul big-segment stores do not exist in either SDK (Redis and DynamoDB only).
20. Python's Redis `max_connections` is deprecated-and-ignored while Ruby's is live — the same-named option means different things.
21. Ruby's `force_polling` on `FileData.data_source` is implemented but undocumented; Ruby's FDv2 file source lacks it entirely (Python has it in both).
22. Python has a unique `defaults` dict (per-flag fallback values consulted by `variation()`); Ruby has no analogue. It is pure data and is arguably the only existing "flag-level config as data" feature in these SDKs.

**Structural oddities relevant to the spec**
23. `sdk_key` lives in **different objects**: Python on `Config`, Ruby on `LDClient`. A declarative file must carry it and the loader must place it correctly per SDK. Ruby also permits it to be `nil` under three specific configurations.
24. Ruby merges *cache* options, *store* options, and a *logger* into a single flat options hash per store factory — no grouping at all.
25. Ruby's defaults are exposed as public class methods (`Config.default_flush_interval`, `Config.default_capacity`, …) and constants (`BigSegmentsConfig::DEFAULT_*`, `PollingDataSourceBuilder::DEFAULT_POLL_INTERVAL`). Python's defaults exist only in function signatures and a handful of class constants (`Redis.DEFAULT_URL`, `CacheConfig.DEFAULT_EXPIRATION`). Ruby is machine-introspectable; Python is not.
26. Ruby's docstring for `flush_interval` says `(30)` and `read_timeout` says `(10)`/`connect_timeout` `(2)` while `default_flush_interval` returns **10** — the published doc comment at the top of `config.rb` is wrong about `flush_interval`. Don't derive the spec from docs.
27. Python's `Config.copy_with_new_sdk_key` is **deprecated** (emits `DeprecationWarning`) and, notably, **drops** `application`, `hooks`, `plugins`, `omit_anonymous_contexts`, `payload_filter_key`, `enable_event_compression` and `datasystem_config` when copying — a latent bug.
28. All duration units in both SDKs are **float/Float seconds** at the API surface, but the diagnostic wire format converts to **milliseconds**. The spec should pick one and state it explicitly; "seconds as a float" is the established SDK-surface convention here.
29. `AsyncConfig` duplicates every `Config` option verbatim. Any declarative loader for Python must target both, or the async client silently loses declarative support.
30. Ruby's `logger`/`cache_store` defaults depend on whether Rails is loaded — an environment-sensitive default that no file can express.
