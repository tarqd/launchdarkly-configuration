// Canonical default values for SDKCONF.
//
// parse() materializes these for every absent property, so SDK-native defaults never apply on
// the declarative path (decision 4). Kept separate from sdkconf.cue so the generated JSON
// Schema describes only the document shape.
//
// Defaults come from the Go SDK, falling back to Java then Python where Go holds the option
// outside Config. Each fallback is noted inline.

package sdkconf

// ---------------------------------------------------------------------------
// Canonical defaults (decision 4)
// ---------------------------------------------------------------------------
//
// parse() materializes these for every absent property, so SDK-native defaults never apply on
// the declarative path. Written explicitly rather than as CUE disjunction defaults because the
// data_system source lists cannot be defaulted structurally, and unified with #Config below so
// CUE verifies the document is itself valid.

defaults: #Config & {
	file_format: "0.1"

	offline:            false
	start_wait_ms:      5000 // Java LDConfig.DEFAULT_START_WAIT; Go has no Config field
	diagnostic_opt_out: false

	service_endpoints: {
		streaming: "https://stream.launchdarkly.com"
		// ldcomponents.DefaultPollingBaseURI, the FDv2 constant. Go also carries
		// internal/endpoints.DefaultPollingBaseURI = "https://sdk.launchdarkly.com/" for its
		// FDv1 path; the two disagree, and FDv2 is the primary shape here.
		polling: "https://app.launchdarkly.com"
		events:  "https://events.launchdarkly.com"

		allow_partial_specification: false
	}

	// ldcomponents.DataSystem().Default()
	data_system: {
		initializers: [{type: "polling"}]
		synchronizers: [{type: "streaming"}, {type: "polling"}]
		fdv1_compatible_synchronizer: {type: "polling"}

		// The default store is in-memory, which has neither a read/write mode nor a cache.
		// Persistent-store defaults live in store_defaults below.
		data_store: {type: "in_memory"}
	}

	events: {
		enabled:                true
		capacity:               10000
		flush_interval_ms:      5000
		all_attributes_private: false
		private_attributes: []
		context_keys_capacity:            1000
		context_keys_flush_interval_ms:   300000
		omit_anonymous_contexts:          false
		enable_gzip:                      false
		diagnostic_recording_interval_ms: 900000
	}

	http: {
		connect_timeout_ms: 3000
		socket_timeout_ms:  10000 // Java LDConfig socketTimeout; Go has no separate read timeout
		headers: {}
	}

	logging: {
		enabled:                                 true
		min_level:                               "info"
		log_evaluation_errors:                   false
		log_context_key_in_errors:               false
		log_data_source_outage_as_error_after_ms: 60000
	}

	// big_segments has no default: the feature is off until a store is configured, and store
	// is a required property. Flags referencing a big segment then evaluate as "not included"
	// with reason BigSegmentsStoreNotConfigured.

	hooks: []
	plugins: []
}

// Per-source defaults, applied to each entry in an initializer or synchronizer list.
source_defaults: {
	streaming: #StreamingSource & {
		type:                       "streaming"
		initial_reconnect_delay_ms: 1000
	}
	polling: #PollingSource & {
		type:             "polling"
		poll_interval_ms: 30000
	}
	file: #FileSource & {
		type: "file"
		paths: ["flags.json"] // placeholder; paths is required and has no default
		duplicate_keys_handling: "fail"
		auto_update:             false
	}
}

// Defaults for stores, applied when the corresponding type is selected.
store_defaults: {
	// DataSystem().PersistentStore() configures read_write; Daemon() configures read. Go's
	// zero value is read only because that is the zero value of the enum, so read_write is
	// taken as the designed default for an explicitly configured store.
	_persistent: {
		mode: "read_write"
		cache: {
			mode:    "time"
			time_ms: 15000 // ldcomponents.PersistentDataStore DefaultCacheTime
		}
	}

	redis: #RedisDataStore & {
		_persistent
		type:   "redis"
		url:    "redis://localhost:6379"
		prefix: "launchdarkly"
	}
	dynamodb: #DynamoDbDataStore & {
		_persistent
		type:       "dynamodb"
		table_name: "PLACEHOLDER" // required, no default
		prefix:     ""            // Go's lddynamodb has no prefix default
	}
	consul: #ConsulDataStore & {
		_persistent
		type:    "consul"
		address: "localhost:8500"
		prefix:  "launchdarkly"
	}
}

// Defaults for big segments, applied when big_segments.store is present.
big_segments_defaults: {
	context_cache_size:      1000
	context_cache_time_ms:   5000
	status_poll_interval_ms: 5000
	stale_after_ms:          120000
}

// Defaults for first-party hooks and plugins.
hook_defaults: {
	tracing: {
		type:  "tracing"
		spans: false // ldotel.WithSpans() is opt-in
		value: false // ldotel.WithValue() is opt-in
	}
}

// Properties whose values MUST be redacted from logs, errors, and diagnostic events
// (decision 10). Expressed here so the generator can annotate the JSON Schema.
sensitive: ["/sdk_key", "/sdk_key_file", "/http/proxy_url", "/data_system/data_store/url"]

// Big segment stores reuse the same connection fields but carry no mode or cache.
big_segment_store_defaults: {
	redis: #RedisStore & {
		type:   "redis"
		url:    "redis://localhost:6379"
		prefix: "launchdarkly"
	}
	dynamodb: #DynamoDbStore & {
		type:       "dynamodb"
		table_name: "PLACEHOLDER" // required, no default
		prefix:     ""
	}
}
