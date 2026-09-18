// SDKCONF — LaunchDarkly server-side SDK declarative configuration.
//
// This file is the single source of truth for the document's shape, its constraints, and its
// default values. Two artifacts are generated from it and MUST NOT be edited by hand:
//
//   sdkconf.schema.json  JSON Schema 2020-12, normative for validation
//   defaults.json        the canonical materialized defaults (decision 4)
//
// Regenerate with `make -C spec/schema`.
//
// Property names are derived from the Go SDK's public API per spec/NAMING.md. Defaults come
// from Go, falling back to Java then Python where Go holds the option outside Config.

package sdkconf

// ---------------------------------------------------------------------------
// Root
// ---------------------------------------------------------------------------

#Config: {
	// Schema version this document targets. A MINOR version newer than the SDK understands
	// produces a warning; a MAJOR mismatch is an error.
	file_format!: string & =~"^[0-9]+\\.[0-9]+$"

	// Environment credential. Sensitive: redacted from logs, errors, and diagnostic events.
	// Prefer "${LAUNCHDARKLY_SDK_KEY}" or sdk_key_file over a literal value.
	sdk_key?: string & !=""

	// Path to a file whose entire trimmed contents are the SDK key. Mutually exclusive with
	// sdk_key. Intended for Docker and Kubernetes secret mounts.
	sdk_key_file?: string & !=""

	// Disable all network access. Every evaluation returns the application's fallback value.
	offline?: bool

	// How long client construction blocks waiting for the data system to initialize.
	// Zero does not block. Name and default come from Java; Go takes this as a constructor
	// argument rather than a Config field.
	start_wait_ms?: int & >=0

	// Suppress SDK diagnostic telemetry. Sits at the root because Go's Config.DiagnosticOptOut
	// does, even though events.diagnostic_recording_interval_ms is on the events builder.
	diagnostic_opt_out?: bool

	application_info?:   #ApplicationInfo
	service_endpoints?:  #ServiceEndpoints
	data_system?:        #DataSystem
	events?:             #Events
	http?:               #Http
	logging?:            #Logging
	big_segments?:       #BigSegments
	hooks?:              [...#Hook]
	plugins?:            [...#Plugin]
}

// ---------------------------------------------------------------------------
// Application metadata
// ---------------------------------------------------------------------------

// Emitted as the X-LaunchDarkly-Tags request header. Go supports only these two fields;
// .NET's name and version_name fall through Go -> Java -> Python and land nowhere, so they
// are not part of v1.
#ApplicationInfo: {
	// Application identifier. At most 64 characters from [A-Za-z0-9._-].
	id?: string & =~"^[A-Za-z0-9._-]{1,64}$"

	// Application version. Same character restrictions as id.
	version?: string & =~"^[A-Za-z0-9._-]{1,64}$"
}

// ---------------------------------------------------------------------------
// Service endpoints
// ---------------------------------------------------------------------------

// Authoritative for every data source that does not override them. Sources MUST fall back to
// these values; Go and Ruby currently ignore them under FDv2, which silently sends a Relay
// Proxy deployment to production LaunchDarkly.
#ServiceEndpoints: {
	streaming?: #Uri
	polling?:   #Uri
	events?:    #Uri

	// Sets streaming, polling, and events to a single Relay Proxy base URI. Mutually exclusive
	// with the three individual properties.
	relay_proxy?: #Uri

	// Permit specifying some but not all endpoints. Without this, a partial set is an error.
	allow_partial_specification?: bool
}

#Uri: string & =~"^https?://"

// ---------------------------------------------------------------------------
// Data system
// ---------------------------------------------------------------------------

// Ordered initializers run once to seed data; ordered synchronizers then keep it current,
// the first being primary and later ones acting as fallbacks. Roles are modelled rather than
// types, because Java has distinct Initializer and Synchronizer types while .NET reuses
// IDataSource for both.
//
// Not implemented by PHP, Erlang, or Haskell; those SDKs either emulate this tree with FDv1
// primitives or report the branch as ignored in the support matrix.
#DataSystem: {
	initializers?:  [...#Initializer]
	synchronizers?: [...#Synchronizer]

	// Data source used when LaunchDarkly directs the SDK back to the FDv1 protocol.
	fdv1_compatible_synchronizer?: #PollingSource | null

	// Overrides service_endpoints for this data system's sources only.
	endpoints?: {
		streaming?: #Uri
		polling?:   #Uri
	}

	data_store?: #DataStore
}

#Initializer:  #PollingSource | #FileSource
#Synchronizer: #StreamingSource | #PollingSource

#StreamingSource: {
	type!: "streaming"

	// Base delay before the first reconnection attempt. Subsequent attempts back off.
	initial_reconnect_delay_ms?: int & >=0

	// Overrides both service_endpoints.streaming and data_system.endpoints.streaming.
	base_uri?: #Uri
}

#PollingSource: {
	type!: "polling"

	// Interval between polls. Values below 30000 are rejected rather than silently raised.
	poll_interval_ms?: int & >=30000

	base_uri?: #Uri
}

// Reads flag data from files on disk. Go-only today (ldfiledatav2).
#FileSource: {
	type!: "file"

	// Files to load, in order.
	paths!: [...string & !=""]

	// What to do when two files define the same flag key.
	duplicate_keys_handling?: "fail" | "ignore"

	// Reload when a file changes. Go models this as a Reloader function, but ldfilewatch.WatchFiles
	// is the only implementation that exists, so the capability is a boolean in practice.
	auto_update?: bool
}

// ---------------------------------------------------------------------------
// Data store
// ---------------------------------------------------------------------------

// An explicit mode rather than Go's internal sentinel encoding, where CacheForever is a
// duration of -1ms and NoCaching is 0 — a schema constraining durations to be non-negative
// would otherwise reject "cache forever".
#Cache: {
	mode?: "time" | "forever" | "off"

	// Only meaningful when mode is "time".
	time_ms?: int & >=0
}

// Each store variant is a single closed object rather than an allOf composition. JSON Schema's
// additionalProperties: false only sees the properties declared in the branch it appears in, so
// composing shared fields with allOf would make every branch reject the others' keys — and
// decision 9 needs these objects closed so that an unknown key is an error. The shared field
// sets below are therefore plain structs, which CUE unifies into each definition before
// closing it.

_inMemoryFields: {
	type!: "in_memory"
}

_redisFields: {
	type!: "redis"

	// Connection URI. Use the rediss:// scheme for TLS, and embed credentials and database
	// number in the URI.
	url?: string & =~"^rediss?://"

	// Prefix for every key the SDK reads or writes.
	prefix?: string
}

_dynamoDbFields: {
	type!: "dynamodb"

	// Table name. The table must already exist; the SDK does not create it. AWS region and
	// credentials come from the AWS SDK's own resolution chain, not from this document.
	table_name!: string & !=""

	prefix?: string
}

_consulFields: {
	type!: "consul"

	// Consul agent address.
	address?: string & !=""

	prefix?: string
}

// Applies only to persistent stores: an in-memory store has neither a read/write mode nor a
// cache in front of it.
_persistentStoreFields: {
	// read_write keeps the store current as data arrives. read never writes, which is Relay
	// Proxy daemon mode.
	mode?: "read" | "read_write"

	cache?: #Cache
}

#DataStore: #InMemoryDataStore | #RedisDataStore | #DynamoDbDataStore | #ConsulDataStore

#InMemoryDataStore: {_inMemoryFields}
#RedisDataStore: {_redisFields, _persistentStoreFields}
#DynamoDbDataStore: {_dynamoDbFields, _persistentStoreFields}
#ConsulDataStore: {_consulFields, _persistentStoreFields}

// Big segment stores carry no mode or cache; big_segments has its own cache properties.
#RedisStore: {_redisFields}
#DynamoDbStore: {_dynamoDbFields}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

#Events: {
	// Go expresses this by swapping SendEvents() for NoEvents() rather than setting a flag.
	enabled?: bool

	// Maximum events buffered between flushes. Events beyond this are dropped.
	capacity?: int & >0

	flush_interval_ms?: int & >0

	// Redact every context attribute from events. Overrides private_attributes.
	all_attributes_private?: bool

	// Attribute *references*, not plain names: a leading "/" makes the value a path, with "~0"
	// and "~1" escaping "~" and "/" respectively. A value without a leading "/" is a literal
	// top-level attribute name.
	private_attributes?: [...string & !=""]

	// Size of the deduplication cache for context keys in index events.
	context_keys_capacity?: int & >0

	context_keys_flush_interval_ms?: int & >0

	// Omit anonymous contexts from index and identify events.
	omit_anonymous_contexts?: bool

	// gzip event payloads before sending.
	enable_gzip?: bool

	// Values below 60000 are rejected rather than silently raised.
	diagnostic_recording_interval_ms?: int & >=60000
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

// Flat, because Go's HTTPConfiguration is flat. Go reuses connect_timeout_ms as the whole-request
// timeout and has no separate read timeout, so socket_timeout_ms takes its name and default
// from Java.
#Http: {
	connect_timeout_ms?: int & >0
	socket_timeout_ms?:  int & >0

	// Proxy URI, optionally with credentials: scheme://user:pass@host:port. When unset, the
	// SDK honours the conventional http_proxy, https_proxy, and no_proxy variables.
	proxy_url?: string & =~"^https?://"

	// PEM file holding additional trusted CA certificates. Expressible as data only in Go and
	// Python today; other SDKs report it as ignored.
	ca_cert_file?: string & !=""

	// Additional request headers. Go permits these to override Authorization and User-Agent,
	// which makes this property security-relevant.
	headers?: [string]: string

	// Identifies a wrapper library built on the SDK. Sent as X-LaunchDarkly-Wrapper.
	wrapper_name?:    string & !=""
	wrapper_version?: string & !=""

	// Appended to the SDK's own User-Agent value.
	user_agent?: string & !=""
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

// Rust has no logging configuration at all — it uses the `log` facade — so this entire group
// is reported as ignored there.
#Logging: {
	// Go expresses this by swapping Logging() for NoLogging().
	enabled?: bool

	min_level?: "debug" | "info" | "warn" | "error"

	// Log the full evaluation error whenever a flag cannot be evaluated.
	log_evaluation_errors?: bool

	// Include the context key in evaluation error messages.
	log_context_key_in_errors?: bool

	// Escalate a data source outage from WARN to ERROR once it has lasted this long.
	// Zero disables the escalation.
	log_data_source_outage_as_error_after_ms?: int & >=0
}

// ---------------------------------------------------------------------------
// Big segments
// ---------------------------------------------------------------------------

// Configured separately from data_system.data_store and may point at a different database.
// Consul is not supported as a big segment store by any SDK. Rust does not implement big
// segments at all.
#BigSegments: {
	store!: #RedisStore | #DynamoDbStore

	// Number of context membership results cached in memory.
	context_cache_size?: int & >0

	context_cache_time_ms?: int & >0

	// How often to poll the store for its last-updated timestamp.
	status_poll_interval_ms?: int & >0

	// Treat store data as stale once its last-updated timestamp is older than this.
	stale_after_ms?: int & >0
}

// ---------------------------------------------------------------------------
// Hooks and plugins
// ---------------------------------------------------------------------------

// Only first-party type values are enumerated in v1. An unrecognized type parses successfully
// and produces a warning at create time; there is no open provider registry yet.
#Hook: #TracingHook

#TracingHook: {
	type!: "tracing"

	// Emit a span for each variation call.
	spans?: bool

	// Include the evaluated flag value as a span attribute. Go's WithVariant() is a legacy
	// alias of WithValue() and is not part of this schema.
	value?: bool

	// LaunchDarkly environment ID, added to emitted spans.
	environment_id?: string & !=""
}

#Plugin: #ObservabilityPlugin

#ObservabilityPlugin: {
	type!: "observability"
}
