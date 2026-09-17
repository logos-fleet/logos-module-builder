#!/usr/bin/env bash
# THE SHIPPED `web` MANIFEST AGAINST THE SOURCE metadata.json.
#
#   check-web-manifest.sh <name> <metadata.json> <manifest.json>
#
# Exits 0 when the artifact declares what the source does, non-zero (saying
# which list and both values) when it does not. See lib/checkWebManifest.nix for
# why this comparison exists at all and why it is written here, in jq, rather
# than over the parsed nix `config` the manifest was generated from.
#
# A PLAIN SCRIPT AND NOT AN INLINE BUILDER so that the check's own test can run
# it over inputs that are wrong ON PURPOSE. A nix check can only demonstrate
# itself passing, and a comparison that never refuses anything is exactly the
# shape of a check that asserts nothing.
set -euo pipefail

name=$1
metadata=$2
manifest=$3

test -s "$metadata"  || { echo "FAIL: $name has no metadata.json at $metadata"; exit 1; }
test -s "$manifest"  || { echo "FAIL: $name ships no manifest.json at $manifest"; exit 1; }

# Both spellings of a dependency entry -- a bare string, or an object with a
# `name` -- flattened to a name, declaration order kept. Order is part of the
# comparison: the core brings a view's dependencies up in declaration order, so
# two manifests that differ only in order are two different startups.
names='[ .[]? | if type == "string" then . else .name end ]'

# THE RULE parseMetadata RESOLVES, re-stated (web_dependencies,
# web_optional_dependencies): a `web` variant may declare its own lists, and
# absent means the module's.
expect_deps=$(jq -c "if .web.dependencies == null then .dependencies else .web.dependencies end | $names" "$metadata")
expect_opt=$(jq -c "if .web.optional_dependencies == null then .optional_dependencies else .web.optional_dependencies end | $names" "$metadata")

got_deps=$(jq -c ".dependencies | $names" "$manifest")
# Absent is the same as empty: an LGX manifest omits `optional_dependencies`
# entirely when a package declares none (logos-package spec 0.6.0).
got_opt=$(jq -c ".optional_dependencies | $names" "$manifest")

fail=0
if [ "$expect_deps" != "$got_deps" ]; then
  echo "FAIL: $name's shipped web manifest declares different dependencies"
  echo "      metadata.json: $expect_deps"
  echo "      manifest.json: $got_deps"
  fail=1
else
  echo "PASS: $name dependencies match: $got_deps"
fi

if [ "$expect_opt" != "$got_opt" ]; then
  echo "FAIL: $name's shipped web manifest declares different optional_dependencies"
  echo "      metadata.json: $expect_opt"
  echo "      manifest.json: $got_opt"
  fail=1
else
  echo "PASS: $name optional_dependencies match: $got_opt"
fi

# Name and version too, cheaply: a manifest carrying a DIFFERENT module's
# dependency lists would pass everything above.
for key in name version; do
  want=$(jq -r ".$key" "$metadata")
  got=$(jq -r ".$key" "$manifest")
  if [ "$want" != "$got" ]; then
    echo "FAIL: $name's shipped manifest $key is '$got', metadata.json says '$want'"
    fail=1
  fi
done

[ "$fail" -eq 0 ] || exit 1
echo "PASS: $name's shipped web manifest agrees with its metadata.json"
