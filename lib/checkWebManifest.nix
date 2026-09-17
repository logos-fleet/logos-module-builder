# THE SHIPPED MANIFEST AGAINST THE SOURCE metadata.json (logos-workspace#250).
#
# WHAT WENT WRONG, and why no source-level test could have caught it. The wallet
# UI's `metadata.json` declares five dependencies; the `web` variant that shipped
# in an iPad's app image declared four, and `wallet_backend_module` -- sitting in
# the same image, Bundled and embedded -- was never loaded, because the core
# brings a view's DECLARED dependencies up and only those. Three screens then
# reported a missing module that was right there. Every check in the wallet's own
# tree reads `metadata.json` and so agreed with itself; the artifact was the only
# place the difference existed.
#
# For that module the cause turned out to be a deliberate `web.dependencies`
# override rather than a packaging stage losing a name -- but that is a fact
# about one module, and the CLASS is what this guards: a manifest produced from a
# different source of truth than the one a reviewer reads.
#
# So the comparison derives what it expects with `jq`, straight from
# `metadata.json`, rather than from the parsed nix `config` the manifest was
# written from. A second implementation is the whole point: reading the same
# attrset back would assert that a value equals itself.
#
# The rule it re-states (parseMetadata: `web_dependencies`,
# `web_optional_dependencies`) lives in check-web-manifest.sh beside the
# comparison, so the check and its own test run one implementation.
{ pkgs, lib }:

{
  # The module's name, which is also the package directory the `web` builders
  # install into (`<name>_web/`).
  name,
  # The built `web` variant -- `packages.<system>.web` of the module.
  webPackage,
  # The module's OWN metadata.json, as a path. Not the parsed config: see above.
  metadataFile,
}:

pkgs.runCommand "${name}-web-manifest-check"
  {
    nativeBuildInputs = [ pkgs.jq pkgs.bash ];
    meta.description =
      "the ${name} `web` variant's shipped manifest declares what metadata.json does";
  }
  ''
    set -euo pipefail
    manifest=${webPackage}/${name}_web/manifest.json
    test -s "$manifest" || {
      echo "FAIL: the ${name} web variant ships no ${name}_web/manifest.json"
      find ${webPackage} -maxdepth 2 >&2
      exit 1
    }
    bash ${../lib/check-web-manifest.sh} ${name} ${metadataFile} "$manifest"
    touch $out
  ''
