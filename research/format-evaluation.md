# Configuration Format Evaluation for LaunchDarkly Server-Side SDKs

Target languages (all must be able to *consume* the format): **Java, .NET, Go, Node, Python, Ruby, PHP, Rust, Erlang, C++, Haskell**.

Two separable decisions, which this document keeps apart:

- **D1 — the authoring/wire format** the SDKs actually parse (TOML / YAML / JSON / KDL).
- **D2 — the normative schema artifact** (JSON Schema / CUE / prose), and what you can generate from it.

A note on evidence: library existence and spec versions below were checked against upstream repos/registries during this research pass. Where I could not confirm current maintenance status I say so explicitly rather than guessing. Anything marked ⚠️ should be re-verified before it goes in a public spec.

---

## Part A — Per-language parser reality check

Legend: **✅ stdlib** = ships with the language/runtime. **✅ de-facto** = one library that essentially everyone uses. **⚠️** = exists but with a maintenance or correctness caveat. **❌** = no maintained option I could find.

| Language | JSON | YAML | TOML | KDL |
|---|---|---|---|---|
| **Java** | ✅ de-facto — Jackson, Gson | ✅ de-facto — SnakeYAML (YAML 1.1), **snakeyaml-engine** (YAML 1.2), `jackson-dataformat-yaml` (wraps SnakeYAML) | ✅ — [tomlj](https://github.com/tomlj/tomlj) (TOML 1.0.0, Maven Central `org.tomlj:tomlj:1.1.1`, ANTLR-based); also night-config | ⚠️ — [kdl4j](https://github.com/kdl-org/kdl4j), KDL v1+v2. Official-org, but low adoption |
| **.NET** | ✅ stdlib — `System.Text.Json` | ✅ de-facto — YamlDotNet | ✅ — [Tomlyn](https://github.com/xoofx/Tomlyn) (TOML 1.1, NativeAOT-ready, netstandard2.0+); also CsToml | ⚠️ — [KdlSharp](https://github.com/AndreyAkinshin/KdlSharp) (v2), [Kadlet](https://github.com/oledfish/Kadlet) (v1 only). Both single-maintainer, young |
| **Go** | ✅ stdlib — `encoding/json` | ⚠️ **`gopkg.in/yaml.v3` is archived/unmaintained** (2025). Migration targets: [`go.yaml.in/yaml/v3`](https://github.com/yaml/go-yaml) (YAML-org fork) or [goccy/go-yaml](https://github.com/goccy/go-yaml) (passes ~60 more yaml-test-suite cases than v3). Ecosystem is mid-churn | ✅ de-facto — `BurntSushi/toml`, `pelletier/go-toml/v2` | ⚠️ — v1-only: gokdl, kdl-go. v2: [gokdl2](https://github.com/njreid/gokdl2) (a fork), [kdly](https://codeberg.org/shimeoki/kdly). No established v2 option |
| **Node** | ✅ stdlib — `JSON.parse` | ✅ de-facto — [`yaml`](https://www.npmjs.com/package/yaml) (eemeli; YAML 1.1+1.2, CST-preserving), `js-yaml` (huge install base) | ✅ — [smol-toml](https://github.com/squirrelchat/smol-toml) (TOML 1.0/1.1, actively maintained). ⚠️ `@iarna/toml` (the historical default) last published ~6 years ago | ⚠️ — [kdljs](https://github.com/kdl-org/kdljs) (v1+v2), [@bgotink/kdl](https://github.com/bgotink/kdl) (v1+v2) |
| **Python** | ✅ stdlib — `json` | ✅ de-facto — PyYAML (**YAML 1.1**), ruamel.yaml (YAML 1.2) | ✅ **stdlib** — `tomllib` (3.11+, read-only); `tomli` backport; `tomli-w`/`tomlkit` to write | ⚠️ — [kdl-py](https://github.com/tabatkins/kdlpy) (v1+v2), [ckdl](https://github.com/tjol/ckdl) Python bindings (v1+v2) |
| **Ruby** | ✅ stdlib — `json` | ✅ stdlib — Psych (libyaml); `YAML.safe_load` is the safe entry point | ✅ — `toml-rb` gem (4.x, releases through Oct 2025); `tomlrb` gem (Racc-based) | ⚠️ — [kdl-rb](https://github.com/danini-the-panini/kdl-rb) (v1+v2) |
| **PHP** | ✅ stdlib — `json_encode`/`json_decode` | ✅ de-facto — `symfony/yaml` (pure PHP, deliberate YAML subset); optional `ext-yaml` (libyaml) | ⚠️ — `yosymfony/toml` is **TOML 0.4 only**; [devium/toml](https://github.com/vanodevium/toml) claims TOML 1.0/1.1 but is a small single-maintainer package. No Composer-ecosystem-standard TOML library | ❌ for v2 — [kdl-php](https://github.com/kdl-org/kdl-php) is **v1 only** |
| **Rust** | ✅ de-facto — `serde_json` | ⚠️ **`serde_yaml` is deprecated and its repo archived (Mar 2024).** Successors are fragmented: `serde_norway`, `serde-yaml-ng` (both still on `unsafe-libyaml`), `serde-saphyr`, `yaml-rust2`. `serde_yml` is itself flagged unmaintained/unsound. **There is no settled Rust YAML story.** | ✅ de-facto — the `toml` crate (the reference implementation's home ecosystem; Cargo's own format) | ✅ — [kdl-rs](https://github.com/kdl-org/kdl-rs) (official, v1+v2) |
| **Erlang** | ✅ **stdlib** — `json` module, OTP 27+ (RFC 8259 conformant). Pre-27 needs jsx/jiffy/thoas | ⚠️ — [yamerl](https://github.com/yakaz/yamerl) (pure Erlang, YAML 1.1+1.2) and [fast_yaml](https://github.com/processone/fast_yaml) (libyaml NIF, so a C build dependency). Both usable; neither is high-velocity | ⚠️ — [tomerl](https://github.com/filmor/tomerl) (TOML 1.0.0). Last release 0.5.0, **June 2021** | ❌ **No KDL implementation exists in any version.** Not on the kdl.dev implementations table, not in the KDL 2.0 compliance tracking issue |
| **C++** | ✅ de-facto — nlohmann/json, RapidJSON, Boost.JSON | ✅ — yaml-cpp (YAML 1.2; ⚠️ maintenance has been sporadic historically — verify), rapidyaml | ✅ de-facto — [toml++](https://github.com/marzer/tomlplusplus) (TOML 1.0, header-only), toml11 | ⚠️ — [kdlpp](https://github.com/tjol/ckdl) (C++ wrapper over ckdl, v1+v2) |
| **Haskell** | ✅ de-facto — aeson | ⚠️ — `yaml` (libyaml-backed, Stackage), HsYAML (pure, YAML 1.2). ⚠️ HsYAML maintenance status uncertain | ✅ — [toml-reader](https://hackage.haskell.org/package/toml-reader) (TOML 1.0.0), tomland, toml-parser (TOML 1.1) | ⚠️ — [kdl-hs](https://github.com/brandonchinn178/kdl-hs) (v2 since 1.0.0, announced on Discourse 2025) |

### What the table actually says

**JSON is the only format with a maintained, widely-used parser in every one of the eleven ecosystems, and it is built into the standard library/runtime of seven of them** (.NET, Go, Node, Python, Ruby, PHP, and Erlang from OTP 27). The other four (Java, Rust, C++, Haskell) each have a single overwhelmingly dominant library (Jackson, `serde_json`, nlohmann/json, aeson). There is no per-language risk item at all.

**YAML has coverage everywhere, but two of the eleven are actively broken-ish**: Rust has *no* consensus library post-`serde_yaml` deprecation, and Go's canonical `gopkg.in/yaml.v3` is archived with the ecosystem mid-migration between two forks. Erlang and Haskell have working libraries with low activity or a C dependency. That's four of eleven with a real caveat — and Rust + Go are two of LaunchDarkly's most-used server SDKs.

**TOML has coverage everywhere too, and better stdlib support than YAML in Python**, but PHP is a genuine weak spot (no spec-1.0 library with ecosystem consensus) and Erlang's `tomerl` has not shipped since 2021.

**KDL fails outright.** Erlang has no implementation. PHP has v1 only, so it cannot read KDL 2.0 documents. Go has no established v2 implementation (one fork, one Codeberg project). That's three of eleven with no viable path, and most of the remaining eight are single-maintainer projects with small user bases. For a format you intend to publish and expect customers to hand-author across eleven runtimes, this is disqualifying regardless of how nice the syntax is.

---

## Part B — Format-by-format assessment

### TOML

**Spec maturity.** TOML 1.0.0 was finalized in January 2021 and is genuinely stable; 1.1.0 is in progress (note the drift risk: Tomlyn and devium/toml and smol-toml already advertise 1.1 support, tomlj and toml-reader target 1.0.0 — so "TOML" already means two different things across your target languages).

**Data model limits — the decisive issue.** TOML's model is tables, arrays, arrays-of-tables, strings, integers, floats, booleans, and *dates*. Two consequences:

1. **No null.** TOML has no null/nil value; the [long-running proposal](https://github.com/toml-lang/toml/issues/30) has not landed. This directly kills the OTel-style "absent vs present-but-null" pattern, which is exactly how OTel expresses "use the `drop` aggregation, which has no parameters" and "this env var is undefined, so apply the default". You would need a workaround convention (`x = ""`? a sentinel? omit-only semantics?) in a spec meant to be implemented eleven times.
2. **Nesting is legible only up to a point.** Deep component trees become either painful dotted keys or heavily repeated headers:

```toml
[[tracer_provider.processors]]
[tracer_provider.processors.batch.exporter.otlp_http]
endpoint = "http://localhost:4318/v1/traces"

[[tracer_provider.processors]]
[tracer_provider.processors.simple.exporter.console]
```

Arrays of tables *do* work and are arguably clearer than YAML lists for homogeneous lists — but for the tagged-union-of-components shape (`exporter: { otlp_http: {...} }`) the header paths get long fast. Inline tables mitigate this but have a one-line restriction in 1.0.

3. **Dates are a feature you don't want.** TOML's first-class offset/local datetimes mean the parser hands you a date object for anything that looks like one — a typing surprise analogous to YAML's `0xdeadbeef` → int.

**Env-var substitution story.** None, in any implementation. You would define `${VAR}` yourself and implement it in eleven languages. Note TOML makes this *easier* than YAML in one respect: because TOML has no re-tagging step, `key = "${PORT}"` is unambiguously a string and you must do explicit conversion — which removes the YAML "substitute-then-let-the-parser-guess-the-type" magic (and its hex-integer surprise), at the cost of requiring the schema to drive coercion.

**Verdict.** Strongest argument *for*: mature, boring, human-authorable, unambiguous scalar typing (no YAML-style re-tagging), stdlib in Python, canonical in Rust and Go. Strongest argument *against*: **no null**, which breaks the tri-state modelling that declarative config needs, plus a real gap in PHP and a stale Erlang library.

### YAML (what OTel chose)

**Spec.** YAML 1.2.2 (2021) is the current spec; OTel pins to ">= 1.2" and specifically the **1.2 core schema**.

**1.1 vs 1.2 is not academic.** Several of the most-used libraries in your target list are 1.1-era:
- PyYAML implements **YAML 1.1** → `yes`/`no`/`on`/`off` are booleans, `:` in some contexts differs, and sexagesimal (`1:30` → 90) lurks in 1.1.
- SnakeYAML is 1.1-based (snakeyaml-engine is the 1.2 one); Ruby Psych is libyaml-based and 1.1-leaning.
- `js-yaml` implements the 1.2 core schema; the `yaml` npm package can do both.

So the *same document* can parse differently in Python and Node. OTel's answer is a whole "Strict YAML parsing" section in `supplementary-guidelines.md` telling authors to voluntarily stay inside the 1.2 core schema's minimal type system.

**Footguns, as documented by OTel themselves:**
- the Norway problem (`NO` → `false` under 1.1)
- **arbitrary code execution** via language-specific tags — `!!python/object`, `!ruby/object`. Mitigation is per-language: `yaml.safe_load()`, Psych safe mode, `SafeConstructor` in SnakeYAML. **A spec that says "parse this YAML" must mandate safe mode**, and eleven implementations must each get it right.
- anchors/aliases (`&a`/`*a`) in untrusted input — including billion-laughs expansion
- OTel's own tested surprise: `${HEX_VALUE}` where `HEX_VALUE="0xdeadbeef"` resolves to the integer **3735928559**
- significant whitespace: the single most common source of "my config file doesn't work" tickets

**Library availability.** Universal, but with the two live problems noted above (Rust post-`serde_yaml`, Go post-`yaml.v3`). Also note YAML is the format most likely to require a **C dependency** (libyaml) in Erlang, Ruby, Haskell and PHP-with-ext-yaml — relevant for restricted deployment targets.

**Env substitution.** No standard. OTel defines its own `${ENV}`/`${ENV:-default}` grammar in ABNF and every SDK reimplements it (plus the `$$` escaping algorithm, non-recursion rules and anti-injection rules — a non-trivial ~100-line spec, which OTel pins down with shelltest fixtures).

**Verdict.** Strongest argument *for*: it is what OTel chose and what customers already write for Kubernetes/CI, it is the only format in this list where every target language has *some* parser and where comments + multi-line strings + anchors make hand-authoring pleasant. Strongest argument *against*: **the same document is not guaranteed to parse identically across your eleven SDKs** (1.1 vs 1.2, tag handling, implicit typing), and two of your highest-traffic languages are currently between maintained libraries.

### JSON

**As a wire format**: unbeatable. Stdlib or de-facto-single-library in all eleven; one data model (object/array/string/number/bool/null); **has null**, so the absent/null/value tri-state works; no re-tagging, no code execution, no whitespace sensitivity; identical parse in every language for any conforming document.

**As an authoring format**: bad. No comments, no multi-line strings, trailing-comma intolerance, quoting noise. JSON5/JSONC fix this but shatter the library-availability argument (JSON5 support across Erlang/Haskell/PHP/C++ is nothing like JSON's).

**Number representation is the one sharp edge.** RFC 8259 leaves precision to implementations; JS gives you `double` for everything, Go's `encoding/json` gives `float64` unless you ask for `json.Number`, Erlang/Haskell/Python give exact integers. If you have int64-valued settings (byte sizes, timeouts in ms) you must bound them or specify them as strings.

**Env substitution.** None standard; you'd define `${VAR}` yourself, and it's *easier* than in YAML because there is no re-tagging phase: `"port": "${PORT}"` is a string and the schema drives conversion. (You lose the ability to write `port: ${PORT}` unquoted and get an integer — which is a feature, not a loss.)

**Verdict.** Strongest argument *for*: it is the **only** candidate with zero per-language risk and zero parse-divergence risk across all eleven SDKs, and it has `null`. Strongest argument *against*: nobody wants to hand-write it — no comments is close to fatal for a file customers maintain.

### KDL

**Spec status.** KDL 2.0.0 is **finalized** — "no further changes are expected" (kdl.dev). The spec is genuinely good: nodes with arguments and properties, unambiguous type annotations `(u8)10`, comments including node-level `/-`, no significant whitespace, a real test suite.

**Language support reality check** (from the [kdl.dev implementations table](https://github.com/kdl-org/kdl/blob/main/README.md) and [KDL 2.0.0 compliance tracking issue #372](https://github.com/kdl-org/kdl/issues/372)):

| Target language | Implementation | v1 | v2 |
|---|---|---|---|
| Java | [kdl4j](https://github.com/kdl-org/kdl4j) | ✅ | ✅ |
| .NET | [KdlSharp](https://github.com/AndreyAkinshin/KdlSharp) | ✅ | ✅ |
| .NET | [Kadlet](https://github.com/oledfish/Kadlet) | ✅ | ✖ |
| Go | [gokdl](https://github.com/lunjon/gokdl) | ✅ | ✖ |
| Go | [kdl-go](https://github.com/sblinch/kdl-go) | ✅ | ✖ |
| Go | [gokdl2](https://github.com/njreid/gokdl2) | ✅ | ✅ |
| Go | [kdly](https://codeberg.org/shimeoki/kdly) | ✖ | ✅ |
| Node | [kdljs](https://github.com/kdl-org/kdljs) | ✅ | ✅ |
| Node | [@bgotink/kdl](https://github.com/bgotink/kdl) | ✅ | ✅ |
| Python | [kdl-py](https://github.com/tabatkins/kdlpy) | ✅ | ✅ |
| Python | [ckdl](https://github.com/tjol/ckdl) | ✅ | ✅ |
| Ruby | [kdl-rb](https://github.com/danini-the-panini/kdl-rb) | ✅ | ✅ |
| **PHP** | [kdl-php](https://github.com/kdl-org/kdl-php) | ✅ | **✖** |
| Rust | [kdl-rs](https://github.com/kdl-org/kdl-rs) | ✅ | ✅ |
| **Erlang** | — | **none** | **none** |
| C++ | [kdlpp](https://github.com/tjol/ckdl) | ✅ | ✅ |
| Haskell | [kdl-hs](https://github.com/brandonchinn178/kdl-hs) | ✅ | ✅ |
| Haskell | [Hustle](https://github.com/fuzzypixelz/Hustle) | ✅ | ✖ |

**Erlang: zero implementations. PHP: v1 only. Go: no mainstream v2.** Three of eleven cannot read a KDL 2.0 document today without you writing or funding a parser. Every remaining implementation is a hobby-scale project — none has the install base of `yaml`, `serde_json`, Jackson or PyYAML, so you are also taking on the risk that a parser disagrees with the spec on your exact documents.

Secondary problem: KDL's node/argument/property model is **not** a JSON-shaped tree. `node arg1 arg2 key=val { child }` has no single canonical mapping to objects, so you'd have to define your own KDL↔data-model projection (KDL's own "KDL Query"/"KDL Schema" side-specs exist but are far less mature than JSON Schema) and every implementation would have to follow it. That erases most of the tooling advantage you'd get from a JSON-shaped format.

**Verdict.** Strongest argument *for*: the nicest hand-authoring experience of the four, with a finalized spec, real comments, unambiguous typing, and no whitespace sensitivity. Strongest argument *against*: **no Erlang parser at all and no KDL-2 parser for PHP or mainstream Go**, plus a non-JSON data model that forfeits the JSON Schema/codegen ecosystem.

### CUE

**What it's genuinely good at.** CUE unifies types and values in one lattice, so a single file is simultaneously schema, constraint set, and defaults. It is excellent at: expressing constraints that JSON Schema can't (cross-field relationships, "if TLS enabled then cert and key required" — exactly relay's `errTLSEnabledWithoutCertOrKey`, which today is hand-written Go), validating configuration in CI, generating and composing configuration, and **exporting to JSON/YAML** (`cue export -o json`). It can also *import* JSON Schema and *export* OpenAPI.

**Maturity.** CUE is **pre-1.0** (v0.17.x line as of this research; the project states its sequencing as "language stability first, then API and tooling", and has been making backwards-incompatible language changes deliberately to get them out before 1.0). ⚠️ Verify the exact current version before citing.

**Is it realistic as the normative schema language?** No, for one structural reason: **CUE is a single-implementation language written in Go.** There is no CUE evaluator in Java, .NET, Python, Ruby, PHP, Rust, Erlang, C++ or Haskell. If CUE is normative, then:
- every SDK must either shell out to the `cue` binary (unacceptable at SDK init) or reimplement validation by hand from prose, and
- you cannot generate per-language model types from it with off-the-shelf tooling.

JSON Schema, by contrast, has conforming validators in every one of the eleven languages, plus IDE integration (VS Code / JetBrains resolve `$schema` and give completion in YAML and JSON files for free) — which is precisely the reason OTel gave for choosing it.

**The "author in CUE, emit JSON Schema/JSON" idea is the right use.** This is a real and attractive pattern, and it's a strict improvement on OTel's home-grown Node `compile-schema.js`:
- maintain the schema in CUE, where constraints and defaults are expressive and composable;
- `cue export` the normative artifact as a single compiled **JSON Schema** file (CUE can emit OpenAPI/JSON Schema; ⚠️ coverage of draft-2020-12 keyword emission needs verification against your actual needs — this is the load-bearing risk);
- also use CUE as the *validator* in CI and in a shipped `ld-config validate` CLI, and to generate the conformance fixture corpus;
- SDKs consume only the JSON Schema + the fixtures and never see CUE.

Caveats to plan for: CUE's expressive constraints will not all survive the trip to JSON Schema, so you either constrain yourself to the JSON-Schema-expressible subset (and lose CUE's main advantage) or accept a two-tier model — "schema-validatable" vs "create-time validated" — which is exactly what OTel ended up with anyway via prose `description` rules that `create` must enforce. Also, CUE is another tool your schema maintainers must learn, whereas ~everyone can read JSON Schema.

**Verdict.** Strongest argument *for*: the best available language for *authoring and validating* the schema, with constraint expressiveness that covers the cross-field rules you'd otherwise hand-write eleven times, and it can emit the normative JSON. Strongest argument *against*: **single implementation, Go-only, pre-1.0** — it can never be the artifact the SDKs consume, and making it normative would leave ten languages with no mechanical path to validation or codegen.

---

## Part C — Normative artifact: JSON Schema vs CUE vs prose

| Criterion | JSON Schema (draft 2020-12) | CUE | Handwritten prose |
|---|---|---|---|
| Validators in all 11 languages | ✅ yes | ❌ Go only | ❌ n/a |
| Machine-checkable | ✅ | ✅ (best-in-class) | ❌ |
| IDE completion/validation for user files | ✅ free via `$schema` | ⚠️ for `.cue` files only | ❌ |
| Cross-field constraints | ⚠️ awkward (`if`/`then`, `dependentRequired`); OTel punted to prose `description` + `create`-time checks | ✅ natural | ✅ but unenforced |
| Defaults / "behaviour when absent" | ⚠️ `default` is an *annotation*, not semantics — OTel deliberately invented `defaultBehavior`/`nullBehavior` prose fields instead (and is still debating using `default`: [config#399](https://github.com/open-telemetry/opentelemetry-configuration/issues/399)) | ✅ real defaults in the lattice | ✅ but unenforced |
| Codegen tooling | ✅ broad but uneven (see below) | ⚠️ `cue get go` is Go-inward; no multi-language emitters | ❌ |
| Versioning/evolution policy | ✅ OTel's `VERSIONING.md` is a ready-made keyword-by-keyword template | ⚠️ you'd have to invent it | ⚠️ |
| Maintainer learning curve | low | medium-high | none |

**Codegen, honestly.** The single most useful data point in this whole study: **OpenTelemetry Java started with `jsonschema2pojo` and replaced it with a hand-rolled POJO generator** (opentelemetry-java 1.65.0, PR #8600) — and this is a schema that was *deliberately written for codegen* (no `allOf` inheritance, identifier-safe names, all types in `$defs`, `title` omitted so `$defs` keys become class names). Go's `otelconf` does use [`atombender/go-jsonschema`](https://github.com/atombender/go-jsonschema) successfully. And OTel's own versioning policy carries the disclaimer:

> **NOTE**: There is _no_ guarantee that the output of off-the-shelf code generation tools will be stable when allowed changes are made.

Plan accordingly: treat generated models as a *convenience for 2–3 languages* (Go, Java, maybe TypeScript/C#), hand-write the rest, and make the **fixture corpus** — not the generated code — the thing that guarantees cross-language agreement.

**Prose** is not a candidate on its own, but note that OTel *needs* prose for a meaningful slice of semantics: `defaultBehavior`, `nullBehavior`, `enumDescriptions`, and "`ca_file` must be an absolute path" (unrepresentable in JSON Schema, so `create` must enforce it). The lesson is to make prose **structured and machine-required** — OTel's CI fails if any non-required property lacks a `defaultBehavior` — rather than letting it live in a README.

---

## Part D — Recommendation

**Recommended: YAML as the primary authoring format, with JSON accepted as an exactly-equivalent alternative; JSON Schema (draft 2020-12) as the normative artifact, optionally authored in CUE and exported.**

Rationale:

1. **JSON must be accepted regardless of what else you do.** It is the only format with zero per-language risk across all eleven SDKs, it has `null`, it never re-tags scalars, and every YAML 1.2 parser reads it. Making the spec "the data model is JSON; YAML is an accepted surface syntax for it" means an SDK whose language has a YAML problem (Rust today, Go this year) can ship JSON-only support and still be conformant. This is a much cheaper insurance policy than picking YAML-only and hoping.
2. **YAML is what customers will actually write**, it is what OTel chose (so the two config files sit side by side in the same repo and look alike), and comments are non-negotiable for a file humans maintain.
3. **Mandatory mitigations for YAML, copied from OTel and tightened**: pin **YAML 1.2 core schema**; require **safe/strict mode** in every implementation (no tags, no custom constructors); forbid anchors/aliases in the spec; and — going further than OTel — specify that scalar values reached by env substitution are typed **by the schema, not by YAML's implicit resolver**, so `${PORT}` is never accidentally a hex integer or a sexagesimal. Ship a fixture file of ~40 (input, env, expected JSON) triples as the conformance test, exactly as OTel's `validator/shelltests` does.
4. **JSON Schema is normative** because it is the only schema language with validators, IDE integration and codegen in all eleven ecosystems — the same reason OTel gave. Author it in one place, compile to a single self-contained file with no external `$ref`s.
5. **CUE is worth adopting internally** to author the schema and to implement the cross-field rules (relay's `errTLSEnabledWithoutCertOrKey`, `errMultipleDatabases`, `errRedisURLWithHostAndPort` class of checks) and to generate fixtures — then `cue export` the normative JSON Schema. Validate this path with a spike before committing: the risk is JSON-Schema-emission fidelity for draft 2020-12.

**Rejected: TOML.** Fatal issue is **no null**, which breaks the absent/null/value tri-state that both OTel and relay's `Opt*` types depend on; secondary issues are the PHP library gap, the 2021-vintage Erlang library, and awkward deep nesting for tagged-union component trees.

**Rejected: KDL.** No Erlang implementation, PHP stuck on v1, no mainstream Go v2 — three of eleven SDKs can't read it. Its node/argument/property model also isn't JSON-shaped, so you'd forfeit the JSON Schema and IDE tooling that is the main practical reason to have a published schema at all.

### One-line pros/cons summary

| Candidate | Strongest argument FOR | Strongest argument AGAINST |
|---|---|---|
| **YAML** | Every one of the 11 languages has a parser, it's what customers and OTel already write, and it's the only candidate that's both comment-friendly and universally available | The same document is not guaranteed to parse identically across the 11 SDKs (1.1 vs 1.2, implicit typing, tags), and Rust + Go are both currently between maintained libraries |
| **JSON** | The only candidate with a maintained, widely-used (mostly stdlib) parser in all 11 with no parse-divergence risk — and it has `null` | No comments; unacceptable as the format a human maintains by hand |
| **TOML** | Mature, boring, unambiguous scalar typing with no YAML-style re-tagging; stdlib in Python, canonical in Rust/Go | **No null value**, which breaks the absent-vs-present-but-null modelling the data model needs |
| **KDL** | Finalized 2.0 spec with the best hand-authoring ergonomics: comments, node-level comment-out, explicit type annotations, no significant whitespace | **No Erlang parser exists; PHP is v1-only; Go has no mainstream v2** — 3 of 11 SDKs cannot read it |
| **CUE** (schema) | Best-in-class for authoring + validating the schema, covers the cross-field constraints JSON Schema can't, and can export the normative JSON | Single Go-only implementation, pre-1.0 — can never be the artifact 11 SDKs consume |
| **JSON Schema** (schema) | Conforming validators, IDE completion and codegen in all 11 ecosystems; OTel's versioning policy is a ready-made template | Weak at cross-field constraints and defaults, so a slice of semantics inevitably lands in structured prose that `create` must enforce |
