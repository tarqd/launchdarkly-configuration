# Server-side SDK configuration inventory: Node.js, Edge (Cloudflare / Vercel / Akamai), PHP

Research for the cross-SDK declarative configuration spec (file + env var, OTel-style).

## Sources examined (all cloned at HEAD, 2026-09-17)

| SDK | Repo / package | Version marker | Primary config surface |
|---|---|---|---|
| Node.js server | `launchdarkly/js-core` → `packages/sdk/server-node` + `packages/shared/sdk-server` + `packages/shared/common` | monorepo HEAD | `LDOptions` object passed to `init(sdkKey, options)` |
| Cloudflare edge | `js-core` → `packages/sdk/cloudflare` (+ `packages/shared/sdk-server-edge`) | monorepo HEAD | `init(clientSideID, kvNamespace, options)` |
| Vercel edge | `js-core` → `packages/sdk/vercel` (+ `sdk-server-edge`) | monorepo HEAD | `init(sdkKey, edgeConfig, options)` |
| Akamai edge | `js-core` → `packages/sdk/akamai-base`, `packages/sdk/akamai-edgekv` (+ `packages/shared/akamai-edgeworker-sdk`) | base 3.0.36 / edgekv 1.4.38 | `init({ sdkKey, options, featureStoreProvider })` / `init({ sdkKey, options, namespace, group })` |
| PHP server | `launchdarkly/php-server-sdk` | `LDClient::VERSION = 6.9.0` | `new LDClient($sdkKey, array $options)` |
| Node stores | `js-core` → `packages/store/node-server-sdk-redis`, `node-server-sdk-dynamodb`; legacy repos `node-server-sdk-redis`, `node-server-sdk-dynamodb`, `node-server-sdk-consul` | — | factory function args / options object |
| PHP stores | `php-server-sdk-redis-predis`, `php-server-sdk-dynamodb`, `php-server-sdk-consul` | — | keys merged into the **same flat `$options` array** |

Key files:
- `js-core/packages/shared/sdk-server/src/api/options/LDOptions.ts` — the (mostly flat) public option surface
- `js-core/packages/shared/sdk-server/src/options/Configuration.ts` — **the validation/coercion layer** (see final section)
- `js-core/packages/shared/sdk-server/src/api/options/LDDataSystemOptions.ts` — FDv2 nested `dataSystem` tree
- `js-core/packages/sdk/server-node/src/api/LDOptions.ts` — Node-only extension (`plugins`, `proxyAgent`)
- `js-core/packages/shared/sdk-server-edge/src/api/createOptions.ts` + `utils/validateOptions.ts` — edge defaults & whitelist
- `js-core/packages/shared/akamai-edgeworker-sdk/src/index.ts` — Akamai `cacheTtlMs`
- `js-core/packages/tooling/contract-test-utils/src/types/ConfigParams.ts` — **existing grouped/nested config schema** (prior art)
- `php-server-sdk/src/LaunchDarkly/LDClient.php` — the `$options` array
- `php-server-sdk/src/LaunchDarkly/Impl/Integrations/FeatureRequesterBase.php` — `cache` / `cache_ttl` / `apc_expiration`

## Shape of each surface (important for the spec)

- **Node/js-core `LDOptions` is almost entirely FLAT camelCase.** The only nested objects are `application` (4 sub-keys), `bigSegments`, `proxyOptions`, `tlsParams`, and the newer `dataSystem` tree. There is **no `serviceEndpoints` option** in the server SDK — `ServiceEndpoints` is an *internal* class constructed from the three flat `baseUri` / `streamUri` / `eventsUri` strings.
- **All durations at the js-core server config surface are in SECONDS** (converted to ms internally via `secondsToMillis` / `* 1000`). The one exception is the Akamai edge SDK's `cacheTtlMs`, which is **milliseconds**. Node client/browser SDKs in the same monorepo use ms-named fields, and the contract-test schema uses `*Ms` everywhere — so the "seconds vs ms" trap is a *cross-surface* trap in js-core, not a within-`LDOptions` one.
- **PHP `$options` is a single flat snake_case array with no schema, no type validation, and no unknown-key detection.** Store-integration keys (`dynamodb_table`, `consul_prefix`, `prefix`, `apc_expiration`, …) are merged into the *same* array, so the namespace is shared between core and plugins. PHP durations are all **seconds** (integers).
- **Edge SDKs accept `Pick<LDOptions, 'logger' | 'sendEvents'>` only** and *throw* on anything else (Akamai adds `cacheTtlMs`; Cloudflare adds `cache`). See "Edge SDKs" table.

---

# 1. Identity / credential

| Option | Node server | Cloudflare | Vercel | Akamai | PHP |
|---|---|---|---|---|---|
| SDK key | positional arg `sdkKey` to `init(sdkKey, options)` — **not an option key**. Throws `You must configure the client with an SDK key` if empty *and* not offline | positional `clientSideID` (queries KV only, not LD) | positional `sdkKey` (queries Edge Config only) | `sdkKey` field of the params object | positional `$sdkKey` to `new LDClient()` |
| Required? | yes unless `offline: true` | yes — `validateOptions` throws `You must configure the client with a client key` | same | same | not validated (empty string accepted) |
| Expressible as data | yes (string; secret) | yes | yes | yes | yes |

`instanceId` (`X-LaunchDarkly-Instance-Id` header):

| | Node server | Edge | PHP |
|---|---|---|---|
| Source | **auto-generated**, not configurable: `platform.crypto.randomUUID()` in `LDClientNode.ts`, passed via `ServerInternalOptions.instanceId` | not set (edge SDKs deliberately do not advertise instance-id) | **auto-generated**: `apcu_entry('ld::instanceid', uuid4)` when APCu enabled, else `uuid4()` when `php_sapi_name() === 'cli'`, else absent. Written into `$options['instance_id']` by the constructor |
| Data-expressible | no (code-only / internal) | n/a | no (but it *is* a readable `$options` key — callers could in principle set it; undocumented) |

---

# 2. Service endpoints

Logical group: `endpoints`. All flat in both SDKs.

| Canonical name | SDK | Type | Default | Semantics | Notes |
|---|---|---|---|---|---|
| `baseUri` | Node | string | `https://sdk.launchdarkly.com` | polling / REST base URI | validator `TypeValidators.String`; trailing `/` stripped by `ServiceEndpoints.canonicalizeUri` |
| `streamUri` | Node | string | `https://stream.launchdarkly.com` | streaming base URI | same |
| `eventsUri` | Node | string | `https://events.launchdarkly.com` (`ServiceEndpoints.DEFAULT_EVENTS`) | analytics/diagnostic event base URI | same |
| `payloadFilterKey` | Node | string | unset | filtered-environment payload filter; appended as `?filter=` on polling & streaming requests | validator `stringMatchingRegex(/^[a-zA-Z0-9](\w|\.|-)*$/)`; **no effect under the FDv2 `dataSystem`** |
| `base_uri` | PHP | string | `https://sdk.launchdarkly.com` (`LDClient::DEFAULT_BASE_URI`) | flag-read base URI (LD, or ld-relay) | `rtrim($v, '/')` applied at construction |
| `events_uri` | PHP | string | `https://events.launchdarkly.com` (`LDClient::DEFAULT_EVENTS_URI`) | event-post base URI | `rtrim`, then `Util::adjustBaseUri` re-adds a trailing `/` |
| *(no `stream_uri`)* | PHP | — | — | PHP never streams | |
| *(no `payload_filter_key`)* | PHP | — | — | not supported | |

Per-data-source endpoint overrides (Node, FDv2 only): `dataSystem.dataSource.initializers[].baseUri`, `dataSystem.dataSource.synchronizers[].baseUri`, `dataSystem.fdv1Fallback.baseUri`. **`baseUri` is explicitly rejected** on `standard` / `streamingOnly` / `pollingOnly` data sources (`rejectDataSourceBaseUri` deletes it and logs `Ignoring unknown config option "dataSystem.dataSource.baseUri"`).

**Endpoint cross-validation (Node, `validateEndpoints`):** if some but not all three URIs are set, the SDK warns per missing one — `You have set custom uris without specifying the <name> URI; connections may not work properly`. `streamUri` is only warned about when `stream` is true; `eventsUri` only when `sendEvents` is true. This is strong prior art for a spec-level "endpoints are a set, override them together" rule. PHP has no equivalent check.

---

# 3. Mode / data source

| Canonical name | SDK | Type | Default | Semantics | Validation |
|---|---|---|---|---|---|
| `offline` | Node | bool | `false` | no network, all evals return default | `TypeValidators.Boolean`; non-bool coerced with `!!` + warning |
| `stream` | Node | bool | `true` | streaming vs polling | Boolean; **ignored if `dataSystem` is set** |
| `pollInterval` | Node | number, **seconds** | `30` (`DEFAULT_POLL_INTERVAL`) | poll period; ignored in streaming mode | `numberWithMin(30)` — values `< 30` are **clamped to 30** with warning; ignored if `dataSystem` set |
| `streamInitialReconnectDelay` | Node | number, **seconds** | `1` (`DEFAULT_STREAM_RECONNECT_DELAY`) | base of exponential-backoff+jitter reconnect | `TypeValidators.Number` (**no minimum**); `* 1000` → `initialRetryDelayMillis`; ignored if `dataSystem` set |
| `useLdd` | Node | bool | `false` | relay-proxy daemon mode: read only from the feature store, never connect to LD | Boolean; ignored if `dataSystem` set (use `dataSystem.useLdd`) |
| `updateProcessor` | Node | **code-only** (`LDStreamProcessor` instance or factory) | unset | replace the data source entirely (used by `FileDataSourceFactory`, test data) | `TypeValidators.ObjectOrFactory`; ignored if `dataSystem` set |
| `timeout` | Node | number, **seconds** | `10` | HTTP connect *and* read timeout for polling/requests (`Requestor: config.timeout * 1000`) | `numberWithMin(1)` — clamped to 1 |
| `offline` | PHP | bool | `false` | disables network **and forces `_send_events = false`** | none |
| `feature_requester` | PHP | **code-only-ish** (`FeatureRequester` instance \| callable factory \| class-name string) | `Guzzle::featureRequester()` | how flags are read (Guzzle HTTP, Redis, DynamoDB, Consul, Files, TestData) | if instance → used; if callable → `$fr($baseUri, $sdkKey, $options)`; if class name → `new $fr(...)`; else throws |
| `feature_requester_class` | PHP | — | — | **Does not exist at HEAD.** Older docs mention it; the current code only reads `feature_requester`, which already accepts a class-name string via `is_a($fr, FeatureRequester::class, true)` | — |
| `timeout` | PHP | int, **seconds** | `3` | HTTP *read* timeout (Guzzle `timeout`, curl `--max-time`) | none; `intval()` in curl publisher |
| `connect_timeout` | PHP | int, **seconds** | `3` | HTTP *connect* timeout (Guzzle `connect_timeout`, curl `--connect-timeout`) | none |
| `debug` | PHP | bool | `false` | Guzzle `debug` flag on the feature-requester client | undocumented in the `$options` docblock; read only by `GuzzleFeatureRequester` |
| no `stream` / `poll_interval` / `use_ldd` / `stream_initial_reconnect_delay` | PHP | — | — | PHP has **no streaming and no polling loop**. Each PHP request reads flags on demand. "Daemon mode" is implicit: pointing `feature_requester` at Redis/DynamoDB/Consul is the only way to avoid per-request HTTP, and LaunchDarkly documents ld-relay as effectively required for production PHP | — |

## Node FDv2 `dataSystem` (the one genuinely nested group)

Setting `dataSystem` **supersedes and silently ignores** `featureStore`, `stream`, `pollInterval`, `streamInitialReconnectDelay`, `useLdd`, `updateProcessor`, and `payloadFilterKey`.

| Path | Type | Default | Semantics |
|---|---|---|---|
| `dataSystem.dataSource` | tagged union on `dataSourceOptionsType` | `{ dataSourceOptionsType: 'standard', streamInitialReconnectDelay: 1, pollInterval: 30 }` | which init/sync chain to run |
| `dataSystem.dataSource.dataSourceOptionsType` | enum `'standard' \| 'streamingOnly' \| 'pollingOnly' \| 'custom'` | `'standard'` | discriminator (`TypeValidators.String`) |
| `…(standard).streamInitialReconnectDelay` | number, seconds | `1` | |
| `…(standard).pollInterval` | number, seconds | `30` | `numberWithMin(30)` |
| `…(streamingOnly).streamInitialReconnectDelay` | number, seconds | `1` | |
| `…(pollingOnly).pollInterval` | number, seconds | `30` | `numberWithMin(30)` |
| `…(custom).initializers[]` | list of `{type:'file', paths, yamlParser?}` \| `{type:'polling', baseUri?, pollInterval?}` | required | ordered; first success graduates to sync stage |
| `…(custom).synchronizers[]` | list of `{type:'streaming', baseUri?, streamInitialReconnectDelay?}` \| `{type:'polling', baseUri?, pollInterval?}` | required | priority-ordered failover chain |
| `dataSystem.persistentStore` | **code-only** (`LDFeatureStore` \| factory) | `InMemoryFeatureStore` | read-before-first-payload store; auto-wrapped in `TransactionalFeatureStore` if it lacks `applyChanges` |
| `dataSystem.useLdd` | bool | `false` | daemon mode under FDv2 |
| `dataSystem.fdv1Fallback` | `{baseUri?, pollInterval?}` \| **`null`** | derived from top-level config | FDv1 fallback synchronizer, engaged only on the `x-ld-fd-fallback: true` response header. `null` = opt out, go terminal-Closed. `undefined` ≠ `null` here — **a tri-state option, awkward for a data-only spec** |

Note the `custom` initializer type `'file'` is the only *data-expressible* file data source in js-core (`{ type: 'file', paths: [...], yamlParser? }`); the FDv1 route (`FileDataSourceFactory` → `updateProcessor`) is code-only.

---

# 4. Events

| Canonical name | SDK | Type | Default | Semantics | Validation |
|---|---|---|---|---|---|
| `sendEvents` | Node | bool | `true` | send analytics events | Boolean; `false` or `offline` → `NullEventProcessor` |
| `capacity` | Node | number | `10000` | max buffered events; overflow dropped | `TypeValidators.Number` (**no min**) |
| `flushInterval` | Node | number, **seconds** | `5` | background flush period (`* 1000` internally) | `TypeValidators.Number` (**no min**) |
| `allAttributesPrivate` | Node | bool | `false` | redact every attribute except key | Boolean |
| `privateAttributes` | Node | `string[]` (attribute references) | `[]` | globally private attribute refs | `TypeValidators.StringArray` |
| `contextKeysCapacity` | Node | number | `1000` | LRU size for context-dedup (index events) | Number (no min) |
| `contextKeysFlushInterval` | Node | number, **seconds** | `300` | reset the dedup LRU this often | Number (no min) |
| `diagnosticOptOut` | Node | bool | `false` | opt out of diagnostic payloads | Boolean |
| `diagnosticRecordingInterval` | Node | number, **seconds** | `900` | periodic diagnostic period | `numberWithMin(60)` — clamped to 60 with warning |
| `enableEventCompression` | Node | bool | `false` | gzip event POST bodies when the platform supports it | Boolean; Node implements it (`zlib.gzip` + `content-encoding: gzip`) |
| `eventProcessor` | Node | — | — | **not an option.** The processor is internal; there is no override hook (unlike PHP) | — |
| `send_events` | PHP | bool | `true` | send analytics events; **forced to `false` when `offline` is true** | none |
| `capacity` | PHP | int | `1000` | in-request queue cap; `enqueue` drops when `count > capacity` (note: strictly-greater, so effectively capacity+1) | none |
| `all_attributes_private` | PHP | bool | `false` | redact all but key | `!!` cast in `EventSerializer` |
| `private_attribute_names` | PHP | `string[]` | `[]` | globally private attribute refs; parsed via `AttributeReference::fromPath`, **invalid refs silently dropped** | per-item parse |
| `event_publisher` | PHP | **code-only-ish** (`EventPublisher` instance \| callable \| class name) | `Curl::eventPublisher()` | transport for events | instance → used; callable → `$ep($sdkKey,$options)`; class name → `new`; else `InvalidArgumentException` |
| `event_processor` | PHP | **code-only** (`EventProcessor` \| callable) | internal `EventProcessor` | replace the whole processor | if callable → `$ep($sdkKey,$options)` |
| `curl` | PHP | string (shell command) | `/usr/bin/env curl` | curl binary used by `CurlEventPublisher`; passed through `escapeshellcmd` | none |
| `payload_temp_dir` | PHP | `true` \| string path | unset (Unix: payload on the command line; Windows: always a file in `sys_get_temp_dir()`) | write the payload to a temp file instead of an argv arg (works around `Argument exceeds the allowed length of N bytes`) | `true` → `sys_get_temp_dir()`; non-empty string → that dir; anything else → unset |
| no `flush_interval` / dedup / diagnostics | PHP | — | — | PHP has **no flush timer** (flush happens in `__destruct` / explicit `flush()`), **no context-key dedup**, and **no diagnostic events at all** | — |
| no `enable_event_compression` | PHP | — | — | not supported | — |

PHP event delivery divergence worth spec attention: the default `Curl` publisher **forks a background `curl` (or PowerShell `Invoke-WebRequest`) process per payload**; the `Guzzle` publisher sends synchronously in the request. LaunchDarkly's own docs recommend `events_uri` → ld-relay for PHP production.

---

# 5. HTTP / transport

| Canonical name | SDK | Type | Default | Semantics | Data-expressible? |
|---|---|---|---|---|---|
| `timeout` | Node | number, seconds | `10` | connect+socket timeout | yes |
| `proxyOptions.host` | Node | string | unset | proxy host | yes |
| `proxyOptions.port` | Node | number | unset | proxy port (**both host and port required** to enable) | yes |
| `proxyOptions.scheme` | Node | string | `http` unless value starts with `https` | `http`/`https` to the proxy | yes |
| `proxyOptions.auth` | Node | string `user:pass` | unset | basic proxy auth → `Proxy-Authorization: Basic <b64>` | yes (secret) |
| `proxyAgent` | **Node-only** (`packages/sdk/server-node`) | `https.Agent \| http.Agent` | unset | escape hatch for non-HTTP proxies (e.g. `SocksProxyAgent`). **When set, `proxyOptions` and `tlsParams` are both ignored** (warning logged) | **code-only** |
| `tlsParams.ca` / `cert` / `key` / `pfx` | Node | string \| string[] \| Buffer \| Buffer[] (`key`/`pfx` also `object[]`) | unset | TLS material for `https.request()` | **partly** — PEM strings are data; `Buffer`/object forms are code-only. A spec would need file-path indirection |
| `tlsParams.passphrase` | Node | string | unset | private-key passphrase | yes (secret) |
| `tlsParams.rejectUnauthorized` | Node | bool | Node default `true` | verify peer | yes |
| `tlsParams.ciphers` / `secureProtocol` / `servername` | Node | string | unset | passthrough to `tls.connect()` | yes |
| `tlsParams.checkServerIdentity` | Node | function | unset | custom hostname verification | **code-only** |
| custom headers | Node | — | — | **not configurable.** Headers come from `defaultHeaders(sdkKey, info, tags, …)` — `Authorization`, `User-Agent`, `X-LaunchDarkly-Wrapper`, `X-LaunchDarkly-Tags`, `X-LaunchDarkly-Instance-Id`. No user hook | — |
| `timeout` / `connect_timeout` | PHP | int, seconds | `3` / `3` | Guzzle & curl timeouts | yes |
| Guzzle `$options` (via `Guzzle::featureRequester([...])` / `Guzzle::eventPublisher([...])`) | PHP | array | `[]` | `cache`, `connect_timeout`, `timeout`, `events_uri` — merged **over** the base client options via `array_merge($baseOptions, $options)` | yes |
| proxy | PHP | — | — | **no proxy option.** Guzzle env-var behavior (`HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY`) applies implicitly via Guzzle itself, not via the SDK | — |
| TLS | PHP | — | — | **no TLS option.** No `verify`, `cert`, or `ca` passthrough is exposed | — |
| custom headers | PHP | — | — | not configurable (`Util::defaultHeaders` / `Util::eventHeaders` only) | — |

---

# 6. Feature store / persistent store & caching

| Canonical name | SDK | Type | Default | Notes |
|---|---|---|---|---|
| `featureStore` | Node | `LDFeatureStore` \| `(clientContext) => LDFeatureStore` | `() => new InMemoryFeatureStore()` | **code-only.** `TypeValidators.ObjectOrFactory`. Ignored when `dataSystem` is set |
| `dataSystem.persistentStore` | Node | same | in-memory | code-only; wrong type → set to `undefined` + warning `Config option "persistentStore" should be of type LDFeatureStore` |
| `feature_requester` | PHP | see §3 | Guzzle | code-only-ish (class-name string form is *data-adjacent*) |
| `cache` | PHP | `Kevinrob\GuzzleCache\Storage\CacheStorageInterface` **or** PSR-6 `CacheItemPoolInterface` | in-memory Guzzle cache | **code-only.** Dual-purpose and overloaded: for the Guzzle requester it is HTTP response caching (`PublicCacheStrategy`); for database requesters, a PSR-6 pool turns into a `Psr6FeatureRequesterCache` |
| `cache_ttl` | PHP | `?int`, seconds | `null` | TTL for `Psr6FeatureRequesterCache` items (`expiresAfter(null)` = implementation-defined) |
| `apc_expiration` | PHP | int, seconds | `0` (= disabled) | legacy APCu local cache for *database* feature requesters. `> 0` builds `ApcuFeatureRequesterCache`; **throws `apc_expiration was specified but apcu is not installed`** if the extension is missing. Ignored if `cache` is a PSR-6 pool (PSR-6 wins) |
| `defaults` | PHP | `array<string,mixed>` | `[]` | **undocumented legacy option**: per-flag-key default values used when a variation call's own default is not honored. Fully data-expressible; not present in any other SDK |

## Store-integration option keys

Node (js-core `packages/store/*`) — all passed to a factory, not into `LDOptions`:

| Key | Package | Type | Default |
|---|---|---|---|
| `redisOpts` | `@launchdarkly/node-server-sdk-redis` | `ioredis.RedisOptions` object | `localhost:6379` |
| `prefix` | redis | string | `launchdarkly` (legacy repo `defaultPrefix`) |
| `client` | redis | `ioredis.Redis` instance — **code-only**; if set, `redisOpts` ignored | unset |
| `cacheTTL` | redis | number, **seconds**; `0` = no caching | `30` (`DEFAULT_CACHE_TTL_S`); applies to the feature store only, *not* `RedisBigSegmentStore` |
| `clientOptions` | `@launchdarkly/node-server-sdk-dynamodb` | `DynamoDBClientConfig` object | unset |
| `dynamoDBClient` | dynamodb | `DynamoDBClient` — code-only; if set, `clientOptions` ignored | unset |
| `prefix` | dynamodb | string | unset |
| `cacheTTL` | dynamodb | number, **seconds** | `15` (`DEFAULT_CACHE_TTL_S`) |
| `logger` | dynamodb | `LDLogger` — code-only | SDK logger |
| table name | dynamodb | positional first arg to the factory, **not an option key** | required |
| `consulOptions` / `prefix` / `cacheTTL` (15) / `logger` | legacy `node-server-sdk-consul` (not ported to js-core) | object / string / seconds / code-only | — |

PHP — keys live in the **shared flat `$options` array**:

| Key | Package | Type | Default |
|---|---|---|---|
| `prefix` | redis-predis | string | `launchdarkly` (`Redis::DEFAULT_PREFIX`) — used for both feature requester and big-segments store |
| Predis client | redis-predis | positional `ClientInterface` arg to `Redis::featureRequester($client, $options)` — **code-only** | required |
| `dynamodb_table` | dynamodb | string | **required**, else `InvalidArgumentException('dynamodb_table must be specified')` |
| `dynamodb_options` | dynamodb | array (AWS SDK client settings); `version` forced to `2012-08-10` | `[]` |
| `dynamodb_prefix` | dynamodb | string | `''` |
| `dynamodb_client` | dynamodb | `Aws\DynamoDb\DynamoDbClient` — code-only; if set, all options except `dynamodb_prefix` / `dynamodb_table` ignored | unset |
| `consul_uri` | consul | string | `http://localhost:8500` |
| `consul_options` | consul | array (Guzzle settings) | `[]` |
| `consul_prefix` | consul | string | `launchdarkly` |
| `apc_expiration` | all three | int seconds | `0` |

`php-server-sdk-apcu` **does not exist as a repository** — APCu caching is built into the core SDK (`Impl/Integrations/ApcuFeatureRequesterCache.php`), driven by `apc_expiration`.

---

# 7. Big segments

| Canonical name | Node path | Type | Default | Clamping |
|---|---|---|---|---|
| `bigSegments` | flat top-level, nested object | object | unset → big segments unevaluable (`bigSegmentsStatus: "NOT_CONFIGURED"`) | `TypeValidators.Object` |
| `bigSegments.store` | nested | `(clientContext) => BigSegmentStore` | **required** — **code-only** | not validated at the config layer |
| `bigSegments.userCacheSize` | nested | number | `1000` | `config.userCacheSize \|\| 1000` — so `0` falls back to 1000 |
| `bigSegments.userCacheTime` | nested | number, **seconds** | `5` | `|| 5`; doc says "negative values are changed to the default" — in practice only falsy values are; `-1` is passed through as `maxAge: -1000` |
| `bigSegments.statusPollInterval` | nested | number, **seconds** | `5` | `Number.is(v) && v > 0 ? v : 5` — zero/negative → default |
| `bigSegments.staleAfter` | nested | number, **seconds** | `120` | `Number.is(v) && v > 0 ? v : 120` |

| PHP (`big_segments` → `LaunchDarkly\Types\BigSegmentsConfig` object, **not an array**) | Type | Default | Clamping |
|---|---|---|---|
| `store` | `Subsystems\BigSegmentsStore` \| `null` | **required ctor arg**; `null` → big segments off — **code-only** | if `big_segments` is not a `BigSegmentsConfig`, the SDK silently substitutes `new BigSegmentsConfig(store: null)` |
| `cache` | PSR-6 `CacheItemPoolInterface` \| `null` | `null` | **code-only** |
| `contextCacheTime` | `?int`, **seconds** | `null` → `expiresAfter(null)`, implementation-defined | none. Note: name diverges from Node's `userCacheTime` |
| `statusPollInterval` | int, **seconds** | `5` (`DEFAULT_STATUS_POLL_INTERVAL`) | `null` or `< 0` → default |
| `staleAfter` | int, **seconds** | `120` (`DEFAULT_STALE_AFTER = 2*60`) | `null` or `< 0` → default |
| *(no `userCacheSize`)* | — | — | PHP caches per-context in the PSR-6 pool; size is the pool's concern |

Big-segments config is therefore **object-typed in PHP** (a constructor with named/readonly params) and **plain-object-typed in Node** — the only place where PHP breaks out of its flat array.

---

# 8. Application metadata / tags

| Canonical name | Node | PHP |
|---|---|---|
| Group | `application` (nested object) — JSDoc notes *"may be renamed to `applicationInfo` in a future major version to be consistent with other SDKs"* | `application_info` → `LaunchDarkly\Types\ApplicationInfo` **builder object** (`->withId()`, `->withVersion()`) |
| `id` | `application.id`, string | `withId(string)` |
| `version` | `application.version`, string | `withVersion(string)` |
| `name` | `application.name`, string | **not supported** |
| `versionName` | `application.versionName`, string → tag key `application-version-name` (special-cased in `ApplicationTags`) | **not supported** |
| Default | unset | unset |
| Validation | `TypeValidators.Object` at the top level; each value must match `/^(\w|\.|-)+$/` and be `<= 64` chars. Violations → warning (`Config option "application.<key>" must only contain letters, numbers, ., _ or -.` / `Value of "application.<key>" was longer than 64 characters and was discarded.`) and the value is **dropped** | same rules (`/[^a-zA-Z0-9._-]/`, `> 64`), errors accumulated on the object and logged as warnings by `LDClient`; empty string → `null` silently |
| Wire format | `X-LaunchDarkly-Tags: application-id/<v> application-version/<v> …`, keys sorted | same header, `application-id/<v> application-version/<v>` |
| Data-expressible | yes (Node: plain object; PHP: needs a builder — **object-only at the API level**, though trivially data-mappable) | |

---

# 9. Wrapper metadata

| Canonical name | Node | PHP |
|---|---|---|
| name | `wrapperName`, string, unset, `TypeValidators.String` | `wrapper_name`, string, unset |
| version | `wrapperVersion`, string, unset; **ignored unless `wrapperName` is set** | `wrapper_version`, string, unset; same conditional (`X-LaunchDarkly-Wrapper: name/version`) |
| Data-expressible | yes | yes |

---

# 10. Logging

| Canonical name | Node | Edge | PHP |
|---|---|---|---|
| Option | `logger` | `logger` (the *only* officially supported edge option) | `logger` |
| Type | `LDLogger` object (`debug/info/warn/error` methods) — **code-only** | same | PSR-3 `Psr\Log\LoggerInterface` — **code-only** |
| Default | `new BasicLogger({ level: 'info', destination: console.error, formatter: util.format })`, constructed in `LDClientNode`; a user logger is wrapped in `SafeLogger` (falls back to the basic logger if the user logger throws) | `BasicLogger.get()`; edge `validateOptions` **throws** `You must configure the client with a logger` if it is missing (the edge `init` always supplies one) | `new Monolog\Logger("LaunchDarkly", [new ErrorLogHandler()])` → PHP `error_log` |
| Data-expressible pieces | `basicLogger(BasicLoggerOptions)`: `level` (`'debug'\|'info'\|'warn'\|'error'\|'none'`, default `'info'`) and `name` (default `LaunchDarkly`) **are data**; `destination` (function or per-level map) and `formatter` are code-only. Note `BasicLoggerOptions.destination` is documented as *"Setting this property to anything other than a function will cause SDK initialization to fail"* | same | nothing — PSR-3 only. A spec would have to synthesize a Monolog/PSR-3 logger from level+destination data |
| Validation | `logger: TypeValidators.Object` (a plain object passes even without the right methods; `SafeLogger` catches failures at call time) | — | none |

---

# 11. Hooks, plugins, migrations

| Canonical name | Node | PHP |
|---|---|---|
| `hooks` | `Hook[]` — **code-only**. Validator `TypeValidators.createTypeArray('Hook[]', {})` (only checks that every element is an `object`) | `hooks` — array of `LaunchDarkly\Hooks\Hook`. Non-`Hook` entries logged (`Ignoring non-Hook entry in 'hooks' option`) and skipped. Also `LDClient::addHook()` post-construction |
| `plugins` | **Node-package-only** (`packages/sdk/server-node/src/api/LDOptions.ts`), `LDPlugin[]` — code-only. Marked *"currently experimental and subject to change"*. Validated with `TypeValidators.createTypeArray('LDPlugin', {})`; failure → `Could not validate plugins.` warning. **Stripped from the base options** (`delete baseOptions.plugins`) before reaching `Configuration`, which is why `plugins` is *not* in the shared `validations` table | **no plugin support** |
| Migration config | `LDMigrationOptions` is **per-migration**, passed to `createMigration()`, not client config: `execution` (`LDSerialExecution(LDExecutionOrdering)` \| `LDConcurrentExecution`), `latencyTracking` (bool), `errorTracking` (bool), plus the `readNew/writeNew/readOld/writeOld/check` function set — code-only | same shape via `LaunchDarkly\Migrations` |

A declarative spec can only express hooks/plugins as **named references** to registered implementations (à la OTel's component-provider registry) — there is no data form in either SDK today.

---

# 12. Edge SDKs (Cloudflare / Vercel / Akamai): the reduced set

These share `LDClientImpl` but hard-code a server-hostile default profile and **whitelist** options.

Forced defaults — `sdk-server-edge/src/api/createOptions.ts` and `akamai-edgeworker-sdk/src/utils/createOptions.ts` (identical):

```
stream: false, sendEvents: false, useLdd: true, diagnosticOptOut: true, logger: BasicLogger.get()
```

User options are spread **over** these defaults (`{ ...defaultOptions, ...options }`), so they are overridable in principle — but `validateOptions` then rejects anything outside the whitelist.

| Option | Cloudflare | Vercel | Akamai (base & edgekv) |
|---|---|---|---|
| Accepted type | `{ cache?: TtlCacheOptions } & LDOptionsCommon` (TS type is the full common `LDOptions`, but the runtime whitelist is `logger` + `sendEvents`) | `LDOptions` from the edge package (same situation) | `{ cacheTtlMs?: number } & Pick<LDOptions,'logger'\|'sendEvents'>` |
| `logger` | supported; required (auto-supplied) | same | same |
| `sendEvents` | supported, default `false`, documented as **"unsupported and only included as a beta preview"** | same | same |
| `cache` | `TtlCacheOptions = { ttl: number /* seconds */, checkInterval: number /* seconds */ }` — **both required, no defaults**; builds `internalServer.TtlCache` for the KV feature store. Destructured out before `validateOptions` | — | — |
| `cacheTtlMs` | — | — | number, **MILLISECONDS**, default `100`; `0` = cache indefinitely. Destructured out before `validateOptions`. **The only ms-denominated duration in the entire js-core server surface** |
| Anything else | **throws** `Invalid configuration: <keys> not supported` | same | same |
| `featureStore` | supplied internally (`EdgeFeatureStore(kvNamespace, clientSideID, 'Cloudflare', logger, cache)`); user-set value is overwritten and `validateOptions` requires an object with `.get` | `EdgeFeatureStore(edgeProvider, sdkKey, 'Vercel', logger)` — **no cache option at all** | `EdgeFeatureStore(provider, sdkKey, 'Akamai', logger, cacheTtlMs ?? 100)` |
| Positional / structural args | `kvNamespace: KVNamespace` (code-only) | `edgeConfig: EdgeConfigClient` (code-only) | base: `featureStoreProvider: EdgeProvider` (code-only). edgekv: **`namespace: string` + `group: string` — fully data-expressible** |
| Internal event paths | `analyticsEventPath: /events/bulk/<clientSideID>`, `diagnosticEventPath: /events/diagnostic/<clientSideID>`, `includeAuthorizationHeader: false` | same | Akamai `LDClient` sets these too |
| `disableBackgroundEventFlush` | internal (`ServerInternalOptions`) — for per-request edge clients that flush via `waitUntil` and must not leave interval timers running | | |

Fastly (`packages/sdk/fastly`) and Shopify Oxygen (`packages/sdk/shopify-oxygen`) exist in the same monorepo and follow the same edge pattern — worth a look if the spec aims for full coverage.

---

# 13. Environment variable support

**Neither SDK reads any environment variable for configuration.**

- `js-core`: `grep -rn "process\.env\.LD"` across `packages/` matches **only example apps and contract-test harnesses** (`packages/sdk/vercel/examples/*/… process.env.LD_CLIENT_SIDE_ID`, `packages/sdk/electron/contract-tests/…`). No `process.env` reference exists anywhere in `shared/common`, `shared/sdk-server`, `sdk/server-node`, `shared/sdk-server-edge`, `sdk/cloudflare`, `sdk/vercel`, or `sdk/akamai-*`.
- `php-server-sdk`: no `getenv`, `$_ENV`, or `LD_*` reference anywhere in `src/`. (Guzzle itself honors `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` and `HTTP_PROXY_REQUEST_FULLURI` at the HTTP-client layer, which is incidental, not SDK-designed.)

So the spec's env-var layer is **entirely greenfield** for both SDKs — no prefix, no naming precedent, and no back-compat constraint. `LD_CLIENT_SIDE_ID` / `LD_SDK_KEY` are the only names with informal currency (examples and CI only).

---

# 14. Deprecated options

| SDK | Deprecated | Notes |
|---|---|---|
| Node | **none.** `grep "@deprecated"` in `shared/sdk-server/src` + `sdk/server-node/src` yields only `LDMigrationOpEvent.user` and `LDUser`, neither a config option | `OptionMessages.deprecated(oldName, newName)` (`"<old>" is deprecated, please use "<new>"`) exists in `shared/common/src/options/OptionMessages.ts` but has **no call sites** in the server SDK — machinery ready, unused |
| Node (soft-deprecated by supersession) | `featureStore`, `stream`, `pollInterval`, `streamInitialReconnectDelay`, `useLdd`, `updateProcessor`, `payloadFilterKey` | Not flagged `@deprecated`, but silently ignored once `dataSystem` is set. `dataSystem` is the forward-looking (FDv2) surface |
| Node (legacy store repos) | `RedisFeatureStore(redisOpts, cacheTTL, prefix, logger, client)` positional form | Doc: *"an older syntax that uses multiple parameters … will be dropped in a future version"*; superseded by the `LDRedisOptions` object |
| PHP | `feature_requester_class` | Gone from the code; `feature_requester` accepts a class-name string instead |
| PHP | `defaults` | Undocumented in the `$options` docblock but still honored (`LDClient.php:137`, `:646`) |
| PHP | `private_attribute_names` | Name retains the pre-contexts "user attribute" framing (other SDKs use `privateAttributes`); still the only supported spelling |

---

# 15. Prior art already in the repos: grouped config schemas

Two existing artifacts already do "grouped declarative config → flat SDK options" and should be read as direct input to the spec.

**`js-core/packages/tooling/contract-test-utils/src/types/ConfigParams.ts`** — the cross-SDK contract-test config schema. It is already the shape a declarative spec wants: `credential`, `startWaitTimeMs`, `initCanFail`, `serviceEndpoints{streaming,polling,events}`, `tls{skipVerifyPeer,customCAFile}`, `streaming{baseUri,initialRetryDelayMs,filter}`, `polling{baseUri,pollIntervalMs,filter}`, `events{baseUri,capacity,enableDiagnostics,allAttributesPrivate,globalPrivateAttributes,flushIntervalMs,omitAnonymousContexts,enableGzip}`, `tags{applicationId,applicationVersion}`, `hooks{hooks[]{name,callbackUri,data,errors}}`, `wrapper{name,version}`, `proxy{httpProxy}`, `dataSystem{initializers[],synchronizers[],fdv1Fallback,payloadFilter,connectionModeConfig}`, and server-only `bigSegments{callbackUri,userCacheSize,userCacheTimeMs,statusPollIntervalMs,staleAfterMs}`. **Every duration in it is `*Ms`.**

**`js-core/packages/sdk/server-node/contract-tests/src/sdkClientEntity.ts` → `makeSdkConfig`** — the actual translation layer. Notable behaviors a spec should reuse or consciously reject:
- `const maybeTime = (ms) => ms == null ? undefined : ms / 1000` — a single ms→s adapter at the boundary.
- Presence of the `polling` group is what sets `stream = false`; there is no explicit mode enum.
- `filter` appears on both `streaming` and `polling` but maps to the same single `payloadFilterKey`.
- `diagnosticOptOut = !options.events.enableDiagnostics` — polarity inversion.
- `tls`/`proxy` groups exist in the schema but the Node entity ignores them.

**`php-server-sdk/test-service/SdkClientEntity.php`** does the same for PHP: `polling.baseUri → base_uri`, `events !== null → send_events`, `events.baseUri → events_uri`, `events.allAttributesPrivate → all_attributes_private`, `events.globalPrivateAttributes → private_attribute_names`, `bigSegments.*Ms / 1000 → BigSegmentsConfig(...)`, and it forcibly installs `Guzzle::eventPublisher()` (the forking curl publisher is untestable). PHP's declared contract-test capabilities: `php, server-side, all-flags-*, context-type, secure-mode-hash, migrations, event-sampling, inline-context-all, instance-id, anonymous-redaction, client-prereq-events, big-segments, evaluation-hooks, hook-environment-id, track-hooks`.

---

# 16. Notable divergences and oddities

1. **PHP has no streaming, no polling loop, and no background anything.** `stream`, `poll_interval`, `use_ldd`, `stream_initial_reconnect_delay`, `flush_interval`, `context_keys_*`, and all diagnostics options are absent by architecture, not by omission. Every PHP request reads flags on demand; ld-relay (via `feature_requester` pointed at Redis/DynamoDB/Consul, plus `events_uri` → relay) is the de facto production requirement. A spec needs a per-SDK "not applicable" concept, distinct from "unset".
2. **`offline` has different blast radius.** Node: `offline` disables network and short-circuits events. PHP: `offline: true` *mutates* `send_events` to `false` — an option writing to another option, so the effective value of `send_events` is not a pure function of the input map.
3. **`useLdd` has no PHP analogue but is the *default* for edge SDKs** (`useLdd: true`, `stream: false`, `sendEvents: false`, `diagnosticOptOut: true`). Any spec default of `stream: true` / `sendEvents: true` will be wrong for three of the five SDKs covered here.
4. **`timeout` means three different things.** Node: one `timeout` (seconds, default 10) used for *both* connect and socket (`createDiagnosticsInitConfig` reports it as both `connectTimeoutMillis` and `socketTimeoutMillis`). PHP: two separate knobs, `timeout` and `connect_timeout` (both seconds, both default 3). And `waitForInitialization({ timeout })` is a *fourth* thing — an init-wait, in seconds, **with no default**, that warns if omitted (*"In a future version a default timeout will be applied"*) and warns above `HIGH_TIMEOUT_THRESHOLD = 60`. The contract schema calls the init-wait `startWaitTimeMs`. A spec must distinguish connect / read / init-wait explicitly.
5. **Seconds everywhere in js-core server config — except Akamai's `cacheTtlMs`.** That single ms field, plus the all-`*Ms` contract schema and the ms-denominated client SDKs, makes the unit boundary a per-surface convention rather than a monorepo-wide one. Strong argument for ISO-8601 durations or mandatory unit suffixes in the spec.
6. **`dataSystem` silently supersedes seven top-level options** with no warning emitted. Under a declarative spec where a user might set both a `dataSystem` block and legacy keys, silence is the wrong behavior; the validation layer already has `unknownOption`/`wrongOptionType` messages that could be extended to "ignored because superseded".
7. **`dataSystem.fdv1Fallback` is tri-state**: `undefined` = derive defaults, `null` = opt out (terminate on directive), object = configure. JSON/YAML can express `null`, but many env-var and merge layers cannot distinguish "absent" from "null" — a genuine spec hazard, and the only place in either SDK where explicit `null` is semantically load-bearing.
8. **`payloadFilterKey` has three homes and one meaning**: top-level (FDv1 only), `dataSystem.payloadFilter` in the contract schema, and per-source `filter` on both streaming and polling in the contract schema. Also documented as *"releasing through a closed alpha and beta pipeline"* and explicitly **inert under FDv2**.
9. **`baseUri` is accepted on some data sources and hard-rejected on others.** `rejectDataSourceBaseUri` exists solely because the shared `validations` table would otherwise let `baseUri` through on `standard`/`streamingOnly`/`pollingOnly`, where it is meaningless. A spec with per-source endpoints needs to state which source types support them.
10. **Edge SDKs whitelist by *throwing*, the core SDK by *warning*.** `validateOptions` throws `Invalid configuration: <keys> not supported` on any extra key, while `Configuration.validateTypesAndNames` logs `Ignoring unknown config option "<name>"` and proceeds. Same monorepo, opposite strictness policies — the spec must pick one (or make it configurable).
11. **Edge SDK type declarations lie.** Cloudflare's exported `LDOptions` is `{cache?} & LDOptionsCommon` (i.e. the full server surface), and Vercel re-exports the common `LDOptions` wholesale — but the runtime whitelist is `logger` + `sendEvents`. Setting e.g. `capacity` type-checks and then throws at init.
12. **PHP's `cache` option is overloaded across two incompatible interfaces**: a Guzzle `CacheStorageInterface` (HTTP response caching for the default requester) or a PSR-6 `CacheItemPoolInterface` (item caching for database requesters, with `cache_ttl`). `FeatureRequesterBase::createCache` carries a comment acknowledging the confusion. A PSR-6 pool also *suppresses* `apc_expiration`.
13. **`apc_expiration` throws rather than degrading** when APCu is not installed (`apc_expiration was specified but apcu is not installed`) — a hard failure from a cache-tuning option.
14. **Big segments cache-time key names diverge**: Node `bigSegments.userCacheTime` + `userCacheSize`; PHP `BigSegmentsConfig.contextCacheTime` with no size. Node uses `userCache*` (pre-contexts naming) while PHP uses `context*`.
15. **Big segments clamping is inconsistent even within Node**: `statusPollInterval` and `staleAfter` use `v > 0 ? v : default` (so `0` and negatives are corrected); `userCacheSize` and `userCacheTime` use `v || default` (so `0` is corrected but `-1` passes straight through as `maxAge: -1000`). The doc comment for `userCacheTime` claims negatives are defaulted — **the doc and the code disagree**.
16. **PHP event capacity is off-by-one**: `if (count($this->_queue) > $this->_capacity) return false;` admits `capacity + 1` events.
17. **Custom HTTP headers are not configurable in any of these SDKs.** Node builds headers via `defaultHeaders()`; PHP via `Util::defaultHeaders()`/`eventHeaders()`. If the spec has a `headers` map, all five SDKs need new plumbing.
18. **No proxy or TLS configuration at all in PHP.** Node's `proxyAgent` (Node-package-only) is the documented escape hatch for anything beyond basic HTTP proxying, and it **silently supersedes both `proxyOptions` and `tlsParams`** (warning logged). `createAgent` also has a quirky check — `if (!proxyOptions?.auth?.startsWith('https'))` warns *"Proxy configured with TLS options, but is not using an https auth"*, testing the **auth credential string** for an `https` prefix, which looks like a bug (it presumably meant `scheme`).
19. **`application.name` / `application.versionName` exist only in Node.** PHP's `ApplicationInfo` supports only `id` and `version`. Validation rules are otherwise identical (`[a-zA-Z0-9._-]`, ≤ 64 chars, drop + warn).
20. **`omitAnonymousContexts` is not a server option.** It appears only in `contract-test-utils` (a client-side event option). Server SDKs redact anonymous attributes on *all* inlined events unconditionally: `{ ...config, redactAnonymousAllEvents: true }` in `LDClientImpl`. PHP declares the `anonymous-redaction` capability with no option either.
21. **`enableEventCompression` is opt-in and platform-conditional** (default `false`; *"if the compression library is not supported then event payloads will not be compressed even if this option is enabled"*). Node implements it; PHP has no equivalent. GET responses are gzip-accepted unconditionally in Node regardless of the flag.
22. **PHP's `defaults` option is unique across the SDK family** — a map of flag key → default value, undocumented in the current `$options` docblock but live in code.
23. **PHP `capacity` default is 1000; Node's is 10000** — a 10× divergence in the same logical option.
24. **PHP `big_segments` and `application_info` require *objects*, not arrays**, in an otherwise-scalar flat array. A file-based config layer for PHP therefore needs constructor/builder mapping for exactly two keys.
25. **No option in either SDK is currently sourced from anything but the caller's literal argument.** There is no file loader, no env layer, no merge/precedence logic, and no config-source concept to extend.

---

# 17. js-core's existing validation & coercion layer (prior art, in detail)

Located in `js-core/packages/shared/sdk-server/src/options/Configuration.ts`, with the validator primitives in `js-core/packages/shared/common/src/validators.ts` and the message catalog in `js-core/packages/shared/common/src/options/OptionMessages.ts`. **PHP has no counterpart whatsoever** — it does no type checking, no clamping, and no unknown-key detection on `$options`.

## 17.1 Validator primitives (`validators.ts`)

| Validator | `getType()` | `is()` semantics |
|---|---|---|
| `Type<T>(name, example)` | `name` | `typeof u === typeof example` **and not an Array** (arrays are explicitly excluded, so `TypeValidators.Object` rejects arrays) |
| `TypeArray<T>(name, example)` | `name` | must be an Array; every element `typeof === typeof example`; **an empty array always passes** |
| `NumberWithMinimum(min)` | `` `number with minimum value of ${min}` `` | `typeof u === 'number' && u >= min` |
| `StringMatchingRegex(re)` | `` `string matching ${re}` `` | `typeof u === 'string' && !!u.match(re)` |
| `FactoryOrInstance` | `factory method or object` | `typeof` is `function` or `object`, and not an Array |
| `Function` | `function` | `typeof u === 'function'` |
| `NullableBoolean` | `boolean \| undefined \| null` | bool, undefined, or null |
| `DateValidator` | `date` | number, or RFC3339Nano-shaped string |
| `KindValidator` | (regex) | `/^(\w|\.|-)+$/` and `!== 'kind'` |
| `OneOf(values)` | `values.join(' \| ')` | string ∈ values |

Statics: `TypeValidators.String / Number / Boolean / Object / ObjectOrFactory / StringArray / Function / Date / Kind / NullableBoolean`, plus `numberWithMin(min)`, `stringMatchingRegex(re)`, `oneOf(...)`, `createTypeArray(name, example)`.

## 17.2 The full server `validations` table

```
baseUri                     String
streamUri                   String
eventsUri                   String
timeout                     numberWithMin(1)
capacity                    Number
logger                      Object
featureStore                ObjectOrFactory
dataSystem                  Object
bigSegments                 Object
updateProcessor             ObjectOrFactory
flushInterval               Number
pollInterval                numberWithMin(30)
proxyOptions                Object
offline                     Boolean
stream                      Boolean
streamInitialReconnectDelay Number
useLdd                      Boolean
sendEvents                  Boolean
allAttributesPrivate        Boolean
privateAttributes           StringArray
contextKeysCapacity         Number
contextKeysFlushInterval    Number
tlsParams                   Object
diagnosticOptOut            Boolean
diagnosticRecordingInterval numberWithMin(60)
wrapperName                 String
wrapperVersion              String
application                 Object
payloadFilterKey            stringMatchingRegex(/^[a-zA-Z0-9](\w|\.|-)*$/)
hooks                       createTypeArray('Hook[]', {})
enableEventCompression      Boolean
dataSourceOptionsType       String
```

Only **three** options carry a minimum: `timeout ≥ 1`, `pollInterval ≥ 30`, `diagnosticRecordingInterval ≥ 60`. Notably **`capacity`, `flushInterval`, `contextKeysCapacity`, `contextKeysFlushInterval`, and `streamInitialReconnectDelay` have no minimum** — `capacity: -5` or `flushInterval: 0` is accepted as-is. There are **no maximums anywhere**.

`plugins` and `proxyAgent` are deliberately absent: `LDClientNode` deletes them from the options before constructing `Configuration`, validating `plugins` itself with `TypeValidators.createTypeArray('LDPlugin', {})`.

## 17.3 `validateTypesAndNames` — the three-branch coercion algorithm

Starting point is `{ ...defaultValues }`; then for each **caller-supplied** key:

| Case | Action | Message |
|---|---|---|
| No validator for the key | leave the default; **do not** record an error | `options.logger?.warn(...)` immediately: `Ignoring unknown config option "<name>"` |
| Validator passes | `validatedOptions[name] = value` | — |
| Fails, validator type is `boolean` | **truthiness-coerce**: `validatedOptions[name] = !!value` | `Config option "<name>" should be a boolean, got <typeof>, converting to boolean` |
| Fails, validator is `NumberWithMinimum` **and** the value is a number | **clamp to the minimum**: `validatedOptions[name] = min` | `Config option "<name>" had invalid value of <value>, using minimum of <min> instead` |
| Fails, anything else | **reset to the default**: `validatedOptions[name] = defaultValues[name]` | `Config option "<name>" should be of type <expectedType>, got <typeof>, using default value` |

Three properties worth carrying into a spec:
- **Nothing ever throws.** Every bad value produces a usable value plus a warning. (The *edge* SDKs invert this and throw.)
- Errors are collected into an array and flushed to the logger *after* validation (`errors.forEach(e => this.logger?.warn(e))`), while unknown-option warnings fire *during* the loop — so ordering in the log differs by category.
- `options.logger` is read **before** validation (`this.logger = options.logger`) so that warnings about the logger itself can be emitted. A non-object `logger` is reset to `defaultValues.logger`, which is `undefined` — the actual fallback logger is constructed one layer up in `LDClientNode`.

## 17.4 Nested validation

**`validateDataSystemOptions`** (`dataSystem`):
- `persistentStore` failing `ObjectOrFactory` → set to `undefined` (in-memory store) + `Config option "persistentStore" should be of type LDFeatureStore, got <typeof>`.
- `fdv1Fallback`: `undefined` and `null` preserved as-is; an object is validated against its own 2-key table (`baseUri: String`, `pollInterval: numberWithMin(30)`); any other type → `undefined` + `Config option "dataSystem.fdv1Fallback" should be of type FDv1FallbackConfiguration, got <typeof>`.
- `dataSource`: dispatched on the `dataSourceOptionsType` discriminator to one of three per-type default sets; an unrecognized shape falls back to `defaultStandardDataSourceOptions` + `Config option "dataSource" should be of type DataSourceOptions, got <typeof>`.
- `baseUri` on standard/streamingOnly/pollingOnly is deleted + `Ignoring unknown config option "dataSystem.dataSource.baseUri"`.
- `custom` data sources are **passed through unvalidated** (`validatedDataSourceOptions = options.dataSource; errors = []`) — initializer/synchronizer arrays get no type or minimum checks at all.

**`validateFDv1FallbackOptions`** is the only validator that treats an unknown nested key as a *collected error* rather than an immediate log line, and it **drops** (rather than defaults) an invalid non-numeric value so downstream derivation from top-level config still works. Worth noting: it reuses the `Ignoring unknown config option` message with a dotted path (`dataSystem.fdv1Fallback.<name>`) — the closest thing in the codebase to spec-style path-qualified diagnostics.

## 17.5 `ApplicationTags` validation (separate path)

`js-core/packages/shared/common/src/options/ApplicationTags.ts` validates each `application.*` value independently of the main table: regex `/^(\w|\.|-)+$/` and length ≤ 64.
- Too long → `Value of "application.<key>" was longer than 64 characters and was discarded.`
- Bad characters → `Config option "application.<key>" must only contain letters, numbers, ., _ or -.`
- In both cases the value is **dropped** (no default substituted), and `versionName` is special-cased to the tag key `application-version-name` (all other keys become `application-<key>`). Tag keys are sorted, values sorted within a key, joined with spaces.

## 17.6 The message catalog (`OptionMessages`)

```
deprecated(old,new)                 "<old>" is deprecated, please use "<new>"                                                  [no call sites]
optionBelowMinimum(name,value,min)  Config option "<name>" had invalid value of <value>, using minimum of <min> instead
unknownOption(name)                 Ignoring unknown config option "<name>"
wrongOptionType(name,exp,act)       Config option "<name>" should be of type <exp>, got <act>, using default value
wrongOptionTypeBoolean(name,act)    Config option "<name>" should be a boolean, got <act>, converting to boolean
invalidTagValue(name)               Config option "<name>" must only contain letters, numbers, ., _ or -.
tagValueTooLong(name)               Value of "<name>" was longer than 64 characters and was discarded.
partialEndpoint(name)               You have set custom uris without specifying the <name> URI; connections may not work properly
```

A shared, parameterized message catalog with stable wording across SDKs is itself reusable prior art for the spec's diagnostics section — and `deprecated()` is a ready-made hook for spec-driven option renames.

## 17.7 Complete Node default table (`defaultValues`)

```
baseUri                     'https://sdk.launchdarkly.com'
streamUri                   'https://stream.launchdarkly.com'
eventsUri                   'https://events.launchdarkly.com'
stream                      true
streamInitialReconnectDelay 1        (seconds)
sendEvents                  true
timeout                     10       (seconds)
capacity                    10000
flushInterval               5        (seconds)
pollInterval                30       (seconds)
offline                     false
useLdd                      false
allAttributesPrivate        false
privateAttributes           []
contextKeysCapacity         1000
contextKeysFlushInterval    300      (seconds)
diagnosticOptOut            false
diagnosticRecordingInterval 900      (seconds)
featureStore                () => new InMemoryFeatureStore()
enableEventCompression      false
dataSystem                  { dataSource: { dataSourceOptionsType: 'standard',
                                            streamInitialReconnectDelay: 1,
                                            pollInterval: 30 } }
```

Defaults *not* in this table (applied deeper in the stack): big-segments `userCacheSize 1000` / `userCacheTime 5s` / `statusPollInterval 5s` / `staleAfter 120s` (`BigSegmentsManager.ts`); `basicLogger` level `info` and name `LaunchDarkly` (`BasicLoggerOptions.ts`); store `cacheTTL` 30s (redis) / 15s (dynamodb, consul); Akamai `cacheTtlMs 100`. Note `defaultValues` declares **both** the legacy flat `stream`/`pollInterval`/`streamInitialReconnectDelay` **and** the `dataSystem` equivalents, so the defaults are duplicated across the two surfaces — a consistency hazard if the spec emits both.

## 17.8 PHP defaults, for comparison

Applied imperatively in the `LDClient` constructor, with no table and no validation:

```
base_uri         'https://sdk.launchdarkly.com'   (rtrim '/')
events_uri       'https://events.launchdarkly.com' (rtrim '/', then adjustBaseUri re-adds '/')
timeout          3    (seconds)
connect_timeout  3    (seconds)
capacity         1000
send_events      true  (forced false when offline)
offline          false
logger           Monolog\Logger('LaunchDarkly', [ErrorLogHandler])
feature_requester Guzzle::featureRequester()
event_publisher  Curl::eventPublisher()
big_segments     new BigSegmentsConfig(store: null)   (substituted if the supplied value is not a BigSegmentsConfig)
apc_expiration   0     (disabled)
cache_ttl        null
curl             '/usr/bin/env curl'
instance_id      auto (APCu-shared UUID, or per-process UUID under CLI, else absent)
```
