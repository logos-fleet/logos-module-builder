# Parse metadata.json as the single source of truth for a module.
# Runtime fields (name, type, dependencies, icon, main…) live at the top level
# and are read by Qt, logos-standalone-app, the nix bundler and the Nix build system.
# Nix/build-only fields live under the "nix" key and are ignored at runtime.
#
# Fields may be platform-keyed via `platforms` overlays (top level, and inside
# "nix"). Resolution happens FIRST, in lib/resolvePlatforms.nix, over the raw
# JSON tree — so the ~300 lines below run once over the resolved answer, every
# existing validation applies to that answer, and `config.*` keeps exactly the
# flat shape every consumer already reads.
{ lib }:

let
  platforms = import ./resolvePlatforms.nix { inherit lib; };

  # ── Why the signature is an attrset with a REQUIRED `platform` ─────────────
  #
  # `parseModuleConfig` used to take the JSON text alone, and the tempting
  # migration was to keep that and add a second entry point that throws only
  # when the JSON declares `platforms`. That guarantee is conditional on module
  # CONTENT: a call site that forgot the platform works perfectly for every
  # module written so far and detonates months later when someone else, in
  # another repo, adds a `platforms` block. The defect is authored in one place
  # and discovered in another.
  #
  # A required argument makes it a property of the SIGNATURE instead — a caller
  # that supplies no platform gets an error at the call, before any module
  # content is read, on day one. `platform = null` is still spellable and
  # means "no target known"; see resolvePlatforms.poisonField for what that
  # buys and what it costs.
  #
  # The old positional form is intercepted rather than left to Nix's "expected
  # a set but found a string", because docs/nix-api.md publishes it and the
  # two forms are distinguishable by type.
  requireArgs = arg:
    if builtins.isString arg then
      throw ''
        parseMetadata.parseModuleConfig now takes an attrset, not the JSON string alone:

          parseModuleConfig {
            json     = builtins.readFile ./metadata.json;
            platform = parseMetadata.platformForSystem system;   # or null
          }

        The platform is required because metadata.json fields can now be platform-keyed
        (`platforms` overlays). A caller that cannot name a target passes
        `platform = null` explicitly and gets a config whose platform-keyed fields
        THROW when read, rather than one that quietly answers with the base value.
      ''
    else if !(builtins.isAttrs arg) then
      throw ("parseMetadata.parseModuleConfig expects { json, platform }, got "
             + "${builtins.typeOf arg}.")
    else if !(arg ? json) then
      throw "parseMetadata.parseModuleConfig: missing required argument `json`."
    else if !(arg ? platform) then
      throw ("parseMetadata.parseModuleConfig: missing required argument `platform`. "
             + "Pass parseMetadata.platformForSystem <system> (inside forAllSystems, where "
             + "the target is known), parseMetadata.platformOf pkgs.stdenv.hostPlatform, or "
             + "an explicit `null` to mean \"no target known\" — null is not a default "
             + "because a forgotten platform would then read as a deliberate one.")
    else
      let extra = lib.subtractLists [ "json" "platform" ] (builtins.attrNames arg); in
      if extra != [ ] then
        throw ("parseMetadata.parseModuleConfig: unexpected argument(s) "
               + builtins.concatStringsSep ", " extra + ". Expected { json, platform }.")
      else arg;
in

{
  # The platform-triple constructors and the reachable-target table, re-exported
  # so a caller reaches them through the same attrset it already has.
  inherit (platforms) platformForSystem platformOf validatePlatform platformTriples;

  # What a `platforms` overlay may vary, and — for the top-level fields that are
  # refused only until the resolved tree reaches the shipped manifest — the
  # reason and the precondition, as text. Re-exported because a throw message is
  # not something a pure-Nix test can read, so this is the only way to assert
  # that the refusal still EXPLAINS itself rather than merely refusing.
  inherit (platforms) overlayAllowed overlayDeferredTop overlayDeferredPrecondition;

  parseModuleConfig = arg:
    let
      args = requireArgs arg;
      raw = platforms.resolvePlatforms {
        platform = args.platform;
        raw = builtins.fromJSON args.json;
      };
      nix = raw.nix or {};
      safeList = val: if builtins.isList val then val else [];

      # Dependency-entry names for `dependencies` and `optional_dependencies`.
      # One reader for both: an entry is a bare name or `{ name, ... }` carrying
      # the constraints an installer resolves it by, and two readers is how the
      # two lists would come to disagree about what an entry names.
      depNames_ = field: val: map (e:
        if builtins.isString e then e
        else (e.name or (throw "${field} entry must be a string name or { name, ... }, got: ${builtins.toJSON e}"))
      ) (safeList val);

      # The two fields the consumer axis below turns on, hoisted so the
      # attrset's own `interface` / `type` and the derivation of
      # `consumer_api_style` cannot drift apart (this set is not `rec`).
      moduleName_ = raw.name or "?";

      # A platform overlay ADDS to these lists rather than replacing them, and
      # the merge deliberately does not dedup (list order is load-bearing
      # elsewhere). So a name written in both the base and a matching overlay
      # arrives twice, and `modules()` has one member per name.
      noDuplicateNames = field: names:
        let dupes = lib.unique (lib.filter (n: lib.count (m: m == n) names > 1) names);
        in if dupes == [] then names
           else throw ("metadata.json: module '${moduleName_}' names "
                       + builtins.concatStringsSep ", " dupes
                       + " more than once in `${field}`. A platform overlay ADDS to the "
                       + "base list, so a name written in both arrives twice; `modules()` "
                       + "has one member per name. Keep the entry in one place.");

      # ── PLATFORM ACCESS, DECLARED (ADR 0009) ──────────────────────────────
      #
      # `"platform": true` means: this module owns access a webview cannot give
      # it — raw TCP/UDP, background execution, a secure enclave, a device
      # radio. It is therefore always part of a shell's Bundled set, and the
      # builder gives it NO `web` variant (mkLogosModule's `webVariant`, and the
      # same gate on a ui_qml module's web output).
      #
      # DECLARED, NEVER INFERRED, and that is the decision worth restating here
      # rather than only in the ADR. The tempting rule is to read it off the
      # crate list — a module linking `reqwest` with `socks` plainly opens a
      # socket. But the SAME crate with the `js` feature is the correct way to
      # fetch from wasm, so the inference is wrong in both directions and both
      # of its failures are silent: it either drops a `web` variant that worked
      # or ships one that dies on the phone. Intent is not in the dependency
      # list, so the author writes it down.
      #
      # `false` when absent, which is what every module written before this key
      # means: it gets exactly the outputs it got before.
      platform_ =
        let declared = raw.platform or false; in
        if builtins.isBool declared then declared
        else throw ("metadata.json: `platform` must be true or false in module "
                    + "'${raw.name or "?"}', got: ${builtins.toJSON declared}. It "
                    + "declares that the module owns access a webview cannot "
                    + "provide (raw sockets, background execution, a secure "
                    + "enclave), which is why it is always Bundled and has no "
                    + "`web` variant.");

      # ── ASKING FOR A `web` VARIANT WHILE DECLARING PLATFORM ACCESS ────────
      #
      # The two gates in mkLogosModule make a `platform: true` module's `web`
      # output simply ABSENT rather than a throwing attribute, and that is
      # deliberate: a consumer writes `pkgs.web or null`, and `or` cannot catch a
      # value that throws — one refused module would take a whole shell's flake
      # down at eval instead of leaving it one variant short.
      #
      # Absence is silent, though, and silence is the wrong answer to an author
      # who WROTE a `web` block. Declaring `web.view_backend` or
      # `web.dependencies` is asking for the variant in so many words, so that
      # ask is refused BY NAME, here, where the contradiction is — rather than
      # being dropped on the floor and discovered as a missing output months
      # later, or (before these gates existed) as an undefined symbol at
      # wasm-ld.
      refuseWebWhenPlatform = key:
        throw ("metadata.json: module '${raw.name or "?"}' declares `platform: "
               + "true` and `web.${key}`. A module that owns access the webview "
               + "cannot provide -- raw sockets, background execution, a secure "
               + "enclave -- gets no `web` variant at all (ADR 0009), so the "
               + "`web` block has nothing to configure. Drop one of the two: "
               + "remove `web.${key}` if the module really is a Platform module "
               + "and belongs in every shell's Bundled set, or drop `platform: "
               + "true` if its access is reachable from a Web container after "
               + "all.");

      # THE `web` VARIANT'S HARD DEPENDENCY NAMES, resolved once. Published as
      # `web_dependencies` and checked against by `web_optional_dependencies`,
      # which cannot read it as an attribute because the result set is not
      # `rec` -- and two copies of this fallback rule is exactly how the two
      # keys would come to disagree about what a variant requires.
      webHardNames_ =
        let declared = ((raw.web or {}).dependencies or null); in
        if declared == null then
          noDuplicateNames "dependencies" (depNames_ "dependencies" (raw.dependencies or []))
        else if platform_ then refuseWebWhenPlatform "dependencies"
        else if !(builtins.isList declared) then
          throw ("metadata.json: web.dependencies must be a list of module names in "
                 + "module '${moduleName_}', got: ${builtins.toJSON declared}")
        else
          noDuplicateNames "web.dependencies" (depNames_ "web.dependencies" declared);

      type_       = raw.type or "core";
      interface_  = raw.interface or "legacy";
      codegen_    = let c = raw.codegen or {}; in if builtins.isAttrs c then c else {};

      # ── Is this module's own image a cdylib PROVIDER? ─────────────────────
      #
      # True exactly when modulePreConfigure.autoCodegen gives the module the
      # module-impl C ABI export surface (logos_module_impl.h) in the SAME
      # image its generated consumer wrappers are compiled into:
      #
      #   interface "cdylib"                       -> cdylibCodegen
      #   interface "universal", type != "ui_qml"  -> universalCodegen
      #                                               (a header-first cdylib)
      #
      # and false for the two shapes that are Qt PLUGIN objects holding a
      # LogosAPI: `interface: "legacy"` (handcrafted Qt) and
      # `interface: "universal"` + `type: "ui_qml"` (a view backend, which is
      # not a module — uiCodegen emits only the view glue).
      #
      # This predicate is deliberately the SAME expression autoCodegen
      # branches on, because the thing it decides is where this image's auth
      # TOKENS come from:
      #
      #   cdylib   — `logos_module_accept_token` -> `lp_token_save`, straight
      #              into the TokenManager this image's outbound lp client
      #              reads (logos-cpp-sdk lidl_gen_cdylib.cpp; the Rust
      #              equivalent in logos-rust-sdk rustgen_provider.rs). A
      #              consumer wrapper here needs NO LogosAPI.
      #   Qt plugin — the host writes to the TokenManager in ITS image; the
      #              plugin links its own copy of the protocol library, so the
      #              tokens have to be MIRRORED across
      #              (logos::qt::LpBridge::syncTokens, reached only via
      #              `forTarget(api, ...)`). A consumer wrapper here that holds
      #              no LogosAPI authenticates as nobody, and the call comes
      #              back as a default value with no error raised.
      packagedAsCdylib_ =
        interface_ == "cdylib"
        || (interface_ == "universal" && type_ != "ui_qml");

      # ── codegen.consumer_api_style: "qt" | "lp" ───────────────────────────
      #
      # Which TYPE SURFACE this module's generated dependency wrappers expose
      # (`modules().<dep>` and the LogosModules umbrella). Independent of the
      # module's own PROVIDER surface, which `interface` alone decides.
      #
      # The default is exactly the value the build derived before this key
      # existed (logos-plugin-qt buildPlugin.nix's `apiStyle`), so an existing
      # metadata.json produces a byte-identical build.
      #
      # Only ONE override is reachable, and `packagedAsCdylib_` is why:
      #
      #   cdylib + "qt"  — ALLOWED, and the point of this key. The wrappers
      #     come out Qt-typed and origin-bound (`--binding origin`): they hold
      #     no LogosAPI and state this module's own name as the call origin.
      #     Correct here precisely because tokens arrive over the C ABI.
      #   Qt plugin + "lp" — REFUSED below. The lp wrappers hold no LogosAPI
      #     either, and in a Qt plugin image nothing would ever populate the
      #     TokenManager they read.
      consumerApiStyleDerived_ = if packagedAsCdylib_ then "lp" else "qt";
      consumerApiStyleDeclared_ = codegen_.consumer_api_style or null;
      consumerApiStyle_ =
        if consumerApiStyleDeclared_ == null then consumerApiStyleDerived_
        else if !(builtins.isString consumerApiStyleDeclared_)
                || !(builtins.elem consumerApiStyleDeclared_ [ "qt" "lp" ]) then
          throw ("metadata.json: module '${moduleName_}' sets codegen.consumer_api_style = "
                 + "${builtins.toJSON consumerApiStyleDeclared_}. Valid values are \"qt\" "
                 + "(Qt-typed dependency wrappers) and \"lp\" (Qt-free, the logos-protocol "
                 + "C ABI). Omit the key to get this module's default (\"${consumerApiStyleDerived_}\").")
        else if consumerApiStyleDeclared_ == "lp" && !packagedAsCdylib_ then
          throw ''
            metadata.json: module '${moduleName_}' sets codegen.consumer_api_style = "lp",
            which is only available to a module packaged as a cdylib provider.

            This module declares interface "${interface_}" with type "${type_}", so its
            generated dependency wrappers are compiled into a Qt PLUGIN object that holds a
            LogosAPI and exports no `logos_module_accept_token`. The lp wrappers call the
            logos-protocol C ABI directly and hold no LogosAPI, so NOTHING would populate the
            TokenManager they read: every outbound call would present an empty auth token,
            capability_module would refuse to mint a per-target token, and the call would
            return a default value with no error surfaced. That is the exact defect
            `logos::qt::LpBridge::syncTokens` exists to prevent — which is why the two
            consumer surfaces are not freely interchangeable.

            Reachable values for this module: "qt" (its default; omit the key).

            To get the Qt-free consumer surface, make the module a cdylib provider —
            `interface: "universal"` (write a plain src/${moduleName_}_impl.h and the contract
            is derived from it) or `interface: "cdylib"`.
          ''
        else consumerApiStyleDeclared_;
    in {
      # Runtime fields
      name        = raw.name        or (throw "metadata.json must specify 'name'");
      version     = raw.version     or "1.0.0";
      type        = type_;
      category    = raw.category    or "general";
      description = raw.description or "A Logos module";
      main        = raw.main        or null;
      icon        = raw.icon        or null;
      view        = raw.view        or null;
      # Concrete module dependencies, as a list of NAME strings. Entries may be
      # bare strings (the common form) or objects `{ name, ... }`; either way we
      # keep just the name here so every existing consumer of `config.dependencies`
      # (the umbrella, collectAllModuleDeps, classifyConcreteDeps) is unchanged.
      dependencies = noDuplicateNames "dependencies"
        (depNames_ "dependencies" (raw.dependencies or []));

      # Concrete dependencies that MAY be absent at runtime — the third kind,
      # between `dependencies` and `interface_dependencies`. Same entry shape
      # and same typed `modules().<dep>` wrapper as `dependencies` (the name is
      # concrete, so the contract is too); what differs is lifetime:
      #
      #   - never auto-loaded, and absence is not a load error (liblogos)
      #   - not in the bundle closure, so a consumer does not inherit the
      #     dependency's runtime deps just because it can call it
      #
      # Refused when the name is also a `dependencies` or `interface_dependencies`
      # entry: `modules()` has one member per name, and two declarations for one
      # name have no single answer for whether the loader must supply it.
      optional_dependencies =
        let
          optNames = noDuplicateNames "optional_dependencies"
            (depNames_ "optional_dependencies" (raw.optional_dependencies or []));
          hardDup = lib.intersectLists optNames
                      (depNames_ "dependencies" (raw.dependencies or []));
          ifaceDup = lib.intersectLists optNames
                       (map (e: e.name or "") (safeList (raw.interface_dependencies or [])));
        in
          if hardDup != [] then
            throw ("metadata.json: module '${moduleName_}' declares "
                   + builtins.concatStringsSep ", " hardDup
                   + " in BOTH `dependencies` and `optional_dependencies`. A dependency is "
                   + "either required at load time or not; keep the entry in one list.")
          else if ifaceDup != [] then
            throw ("metadata.json: module '${moduleName_}' declares "
                   + builtins.concatStringsSep ", " ifaceDup
                   + " in BOTH `optional_dependencies` and `interface_dependencies`. An "
                   + "optional dependency names a concrete module; an interface dependency "
                   + "is bound to one at runtime. They cannot share a `modules()` member.")
          else optNames;

      include      = safeList (raw.include      or []);

      # Interface dependencies — method/event contracts decoupled from any
      # concrete module. The consumer binds an interface to a module name at
      # runtime (modules().bind_<name>("some_module")). Each entry:
      #   { name, file, input?, impl_class? }
      #   name       — interface identifier → bound wrapper class + bind_<name>
      #   file       — path to the .lidl/.h definition. For a local interface,
      #                relative to this repo root; for a remote one, relative
      #                to the flake input named by `input`.
      #   input      — (optional) flake-input attr name hosting the interface,
      #                mirroring how `dependencies` map to flake inputs. Absent
      #                ⇒ local file in this repo.
      #   impl_class — (required for .h definitions) the C++ class whose public
      #                methods + logos_events: define the interface.
      interface_dependencies = map (e:
        let
          # Reject non-object entries with a clear message rather than the
          # low-level "is not an attribute set" error that `e.file` would
          # otherwise raise on a bare string / list element.
          _ok = if builtins.isAttrs e then true
                else throw "interface_dependencies entries must be objects like { name, file, impl_class?, input? }, got: ${builtins.toJSON e}";
          file = if _ok then (e.file or (throw "interface_dependencies entry '${e.name or "?"}' must specify 'file'")) else null;
          implClass = e.impl_class or null;
          isHeader = lib.hasSuffix ".h" file || lib.hasSuffix ".hpp" file;
        in
          if isHeader && implClass == null
          then throw "interface_dependencies entry '${e.name or file}' is a C++ header (${file}) and must specify 'impl_class'"
          else {
            name       = e.name or (throw "interface_dependencies entry must specify 'name'");
            inherit file;
            input      = e.input or null;
            impl_class = implClass;
          }
      ) (safeList (raw.interface_dependencies or []));

      # Optional per-dependency LIDL-source overrides. Normally a dependency's
      # interface LIDL is auto-resolved from its `packages.<sys>.lidl` flake
      # output (no plugin build); an override forces a specific definition —
      # e.g. a committed `.lidl`, or a header in another input. It is also the
      # way to depend on a module that publishes no contract of its own, which
      # is otherwise refused. Keyed by dependency name → { file, input?, impl_class? }:
      #   file       — path to the .lidl/.h. Relative to this repo (no `input`)
      #                or to the named flake input.
      #   input      — (optional) flake-input attr name hosting the file.
      #   impl_class — (required for a .h file) the class whose API defines the dep.
      dependency_overrides = lib.mapAttrs (name: ov:
        let
          file = ov.file or (throw "dependency_overrides.${name} must specify 'file'");
          implClass = ov.impl_class or null;
          isHeader = lib.hasSuffix ".h" file || lib.hasSuffix ".hpp" file;
        in
          if isHeader && implClass == null
          then throw "dependency_overrides.${name} is a C++ header (${file}) and must specify 'impl_class'"
          else { inherit file; input = ov.input or null; impl_class = implClass; }
      ) (if builtins.isAttrs (raw.dependency_overrides or {}) then (raw.dependency_overrides or {}) else {});

      # Nix/build-only fields (nested under "nix" in metadata.json)
      nix_packages = {
        build   = safeList ((nix.packages or {}).build   or []);
        runtime = safeList ((nix.packages or {}).runtime or []);
      };
      external_libraries = safeList (nix.external_libraries or []);
      cmake = {
        find_packages      = safeList ((nix.cmake or {}).find_packages      or []);
        extra_sources      = safeList ((nix.cmake or {}).extra_sources      or []);
        extra_include_dirs = safeList ((nix.cmake or {}).extra_include_dirs or []);
        extra_link_libraries = safeList ((nix.cmake or {}).extra_link_libraries or []);
      };

      # Rust crate build inputs (nested under "nix.rust" in metadata.json). Fed to
      # the buildRustPackage that compiles a cdylib module's crate (mkLogosModule
      # rustStaticLib), NOT the C++ plugin link (that's nix.packages):
      #   packages.build   -> nativeBuildInputs (host tools: pkg-config, protoc,
      #                       perl, rustPlatform.bindgenHook)
      #   packages.runtime -> buildInputs       (link libs: openssl, sqlite, zstd)
      #   env              -> buildRustPackage env (flag-style vars)
      # Names resolve via getPkg (dotted nixpkgs paths). Empty by default, so
      # non-Rust modules and Rust modules without native deps are unaffected.
      nix_rust = {
        packages = {
          build   = safeList (((nix.rust or {}).packages or {}).build   or []);
          runtime = safeList (((nix.rust or {}).packages or {}).runtime or []);
        };
        env = let e = (nix.rust or {}).env or {}; in if builtins.isAttrs e then e else {};
        # Optional stable rustc version (e.g. "1.96.0") for the crate compile.
        # When set, the builder uses a rust-overlay toolchain at that version
        # instead of the pinned nixpkgs rustc — for modules whose deps need a
        # newer rustc than the workspace nixpkgs ships (e.g. the railgun engine's
        # alloy 1.8 / ruint). null (default) = unchanged, uses nixpkgs rustc.
        toolchain = let t = (nix.rust or {}).toolchain or null; in if builtins.isString t then t else null;
      };

      # Module API style: "legacy" (default), "universal" (pure C++ + generated
      # Qt glue), "cdylib" (module-impl C ABI + generated glue).
      # "provider" was removed; autoCodegen throws if a module still declares it.
      interface = interface_;

      # Where this module's generated consumer wrappers get compiled, as a
      # boolean the backends can consult without re-deriving it: true = into
      # the cdylib provider image (tokens arrive over the module-impl C ABI),
      # false = into a Qt plugin object holding a LogosAPI (tokens have to be
      # mirrored). Derived in the `let` above, next to the reasoning.
      packaged_as_cdylib = packagedAsCdylib_;

      # The resolved consumer type surface ("qt" | "lp") — the default derived
      # from `packaged_as_cdylib`, or the validated `codegen.consumer_api_style`
      # override. See the `let` above for the one override that is reachable
      # and why the other is refused there rather than at compile time.
      consumer_api_style = consumerApiStyle_;

      # Privileged host services this module asks the host to grant it, from a
      # CLOSED set. Parsed and validated here, unlike the older decorative
      # `capabilities` field which nothing in this file reads — a security
      # decision must not ride on a key that is never looked at.
      #
      #   "token_registry"  — enumerate the token store (lp_token_keys)
      #   "token_delivery"  — push a token to an arbitrary target
      #                       (lp_inform_module_token_to)
      #
      # Both are TRUST-ROOT services: capability_module's job, and a module
      # holding them can hand out authority. They are additionally restricted to
      # an allowlist of module names below.
      #
      # `dynamic_calls` USED TO BE LISTED HERE and is not a service at all. It
      # gated nothing, and could not: the by-name path (lp_client_create /
      # lp_invoke, and logos::LpClient above it) is ungated at every layer, so a
      # module could always make dynamic calls without asking. What the
      # declaration actually did was BREAK the asking module — hostServiceBit
      # (logos_protocol.cpp:109-111) knows only the two names above, and
      # lp_grant_host_services returns LP_ERR_INVALID_ARG on the first entry it
      # does not recognise (:695-702), failing the WHOLE grant. So a module that
      # asked for dynamic_calls alongside a real service silently lost the real
      # one. Removed rather than made inert, so asking is a build error instead.
      # The supported surface for by-name calls is LogosModules::dynamic(target)
      # plus LpClient::getMethods(), which need no grant.
      #
      # This declaration is ADVISORY. The authority is the host's grant, pushed
      # into the module's own image over the module-impl C ABI; an ungranted
      # module gets LP_ERR_UNSUPPORTED however loudly its metadata asks.
      host_services =
        let
          declared = safeList (raw.host_services or []);
          known = [ "token_registry" "token_delivery" ];
          trustRoot = [ "token_registry" "token_delivery" ];
          # Only capability_module may ask for a trust-root service. Hardcoded
          # rather than configurable: a build-time allowlist that a module could
          # extend from its own metadata would not be an allowlist.
          privilegedModules = [ "capability_module" ];
          checkKnown = svc:
            if !(builtins.isString svc) then
              throw ("host_services entries must be strings, got: ${builtins.toJSON svc}")
            else if !(builtins.elem svc known) then
              throw ("metadata.json: unknown host service '${svc}' in module "
                     + "'${raw.name or "?"}'. Known services: "
                     + builtins.concatStringsSep ", " known
                     + ". An unrecognised name means the module believes it holds a "
                     + "privilege that does not exist, so the whole declaration is refused.")
            else if builtins.elem svc trustRoot
                    && !(builtins.elem (raw.name or "") privilegedModules) then
              throw ("metadata.json: module '${raw.name or "?"}' asks for the trust-root "
                     + "host service '${svc}', which is restricted to: "
                     + builtins.concatStringsSep ", " privilegedModules
                     + ". A module needing to call another module should declare it as a "
                     + "dependency; token_registry/token_delivery hand out authority.")
            else svc;
        in map checkKnown declared;

      # Concurrent dispatch mode (parallel to `interface`):
      #   "single" (default) — today's event-loop semantics: every call to this
      #     module is dispatched serially on one thread, so the author needs no
      #     thread-safety. This stays the default forever (even post-Qt).
      #   "multi" — the generated dispatch runs handlers concurrently on a worker
      #     pool; the author owns thread-safety (interior mutability / mutexes on
      #     their own state). Realized transport-agnostically by the codegen + the
      #     protocol's async dispatch path (a blocking handler no longer stalls
      #     other callers of the same module).
      concurrency = raw.concurrency or "single";
      # Optional worker-pool cap for a "multi" module; null ⇒ the runtime sizes the
      # pool to available parallelism (capped). Ignored for "single".
      max_workers = if raw ? max_workers then raw.max_workers else null;

      # Optional codegen overrides (see docs); read for interface universal/cdylib
      # (and by the ui_qml backend, for codegen.rep). The removed `provider`
      # interface used to be the other consumer.
      codegen = raw.codegen or {};

      # See `platform_` in the let block above for what this declares and why
      # it is not inferred.
      platform = platform_;

      # ── the `web` variant of a `type: ui_qml` module ──────────────────────
      #
      # `web.view_backend` is what makes a view module downloadable onto a Store
      # shell (ADR 0003/0004): its QML goes into the app's bundled Qt-wasm QML
      # runtime, and the C++ backend behind it is compiled into a wasm image of
      # its own and remoted over QtRO on a MessagePort (slice 27).
      #
      #   "web": { "view_backend": {
      #       "class":   "CounterBackend",
      #       "header":  "src/CounterBackend.h",
      #       "sources": ["src/CounterBackend.cpp"] } }
      #
      # DECLARED, NOT DERIVED, and that is the whole design of this key. A
      # ui_qml module's `SOURCES` is its Qt PLUGIN — an object that inherits
      # LogosViewPluginBase and holds a LogosAPI, neither of which exists in a
      # wasm image — so the subset that is only the backend cannot be guessed
      # from the file list. Modules whose backend is not separable from their
      # plugin (the plugin IS the .rep source, which is a perfectly good desktop
      # design) simply have no `web` output, which is better than one that fails
      # to compile three layers down.
      #
      # null when absent, so this is additive: every existing ui_qml module is
      # unchanged and gains no output.
      web_view_backend =
        let
          declared = ((raw.web or {}).view_backend or null);
          need = key:
            let v = declared.${key} or null; in
            if builtins.isString v && v != "" then v
            else throw ("metadata.json: web.view_backend needs a non-empty string "
                        + "'${key}' in module '${raw.name or "?"}'. It names the "
                        + "QObject the module's Qt-wasm view backend hosts.");
        in
        if declared == null then null
        else if platform_ then refuseWebWhenPlatform "view_backend"
        else if !(builtins.isAttrs declared) then
          throw ("metadata.json: web.view_backend must be an object in module "
                 + "'${raw.name or "?"}', got: ${builtins.toJSON declared}")
        else if type_ != "ui_qml" then
          throw ("metadata.json: module '${raw.name or "?"}' declares "
                 + "web.view_backend but is type '${type_}'. A view backend is "
                 + "remoted to the bundled QML runtime as a .rep source, which "
                 + "only a ui_qml module has; a headless module's `web` variant "
                 + "is the Bare Wasm host and needs no declaration.")
        else {
          class = need "class";
          header = need "header";
          sources = safeList (declared.sources or []);
        };

      # ── what a `web` variant DECLARES it needs ───────────────────────────
      #
      # A `web` variant is a different artifact with a different backend, and
      # therefore a different dependency set. logos-evm-wallet-ui is the case
      # this exists for: the desktop plugin reaches six modules through a
      # coordinator, and the `web` variant reaches two of them directly because
      # the coordinator has no build for the target. The core RESOLVES a
      # module's declared dependencies before loading it and refuses a module
      # whose list it cannot satisfy, so a variant carrying the other build's
      # list does not load at all -- with an error naming four modules the
      # running image never calls.
      #
      # Absent means `dependencies`, which is what every `web` variant written
      # before this key has and what most will always want.
      #
      # NOT a subset check. A `web` variant may need something the native build
      # does not -- a module that only exists on a phone -- and a rule that
      # forbade it would be guessing about a direction nothing has taken yet.
      web_dependencies = webHardNames_;

      # ── ...and what it can call but does not NEED ─────────────────────────
      #
      # The same second edge set as `optional_dependencies`, for the same
      # reason a `web` variant has its own hard list: the two builds reach
      # different modules, so they have different answers to "may be absent".
      #
      # THIS IS THE KEY A VARIANT USES FOR A MODULE THE IMAGE MAY OR MAY NOT
      # CARRY. logos-evm-wallet-ui is the case it exists for
      # (logos-workspace#250): `wallet_backend_module` and `railgun_module` are
      # Bundled members an app image carries only when `--bundle` asked for
      # them, and the wallet's `web` half calls both when they are there.
      # Declaring them HARD would refuse the whole wallet on an image without
      # them -- trading every wallet build for two tabs -- and leaving them
      # undeclared is what #250 reported: never loaded, so never callable, so
      # three screens refusing a module that was sitting in the image.
      # Optional is the shape that says exactly that: load it if it is here.
      #
      # Absent means `optional_dependencies`, the same way `web.dependencies`
      # falls back to `dependencies`.
      #
      # Refused when a name is in this variant's HARD list, for the reason the
      # top-level pair is refused: one name, one answer about who must supply it.
      web_optional_dependencies =
        let
          declared = ((raw.web or {}).optional_dependencies or null);
          optNames =
            if declared == null then
              noDuplicateNames "optional_dependencies"
                (depNames_ "optional_dependencies" (raw.optional_dependencies or []))
            else if platform_ then refuseWebWhenPlatform "optional_dependencies"
            else if !(builtins.isList declared) then
              throw ("metadata.json: web.optional_dependencies must be a list of module "
                     + "names in module '${moduleName_}', got: "
                     + builtins.toJSON declared)
            else
              noDuplicateNames "web.optional_dependencies"
                (depNames_ "web.optional_dependencies" declared);
          hardDup = lib.intersectLists optNames webHardNames_;
        in
          if hardDup != [] then
            throw ("metadata.json: module '${moduleName_}' declares "
                   + builtins.concatStringsSep ", " hardDup
                   + " in BOTH the `web` variant's required and optional dependency "
                   + "lists. A dependency is either required at load time or not; keep "
                   + "the entry in one list.")
          else optNames;

      # Names of external_libraries entries built with go_build (for CMake whole-archive link flags)
      go_static_lib_names = map (x: x.name) (lib.filter (x: x ? go_build && x.go_build == true)
        (safeList (nix.external_libraries or [])));

      # The RESOLVED raw tree, with both `platforms` keys removed. Not the
      # pre-resolution JSON: a consumer reading `_raw.include` off that would
      # get the unresolved superset, which is the same silent wrong answer one
      # layer down from the one this feature exists to remove.
      _raw = raw;

      # The triple this config was resolved for (null when parsed without a
      # target). Exposed so a builder can assert which answer it is holding
      # rather than inferring it from where the value came from.
      _platform = platforms.validatePlatform args.platform;
    };
}
