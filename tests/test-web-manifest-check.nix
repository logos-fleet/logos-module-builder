# THE CHECK THAT COMPARES A SHIPPED `web` MANIFEST WITH ITS SOURCE metadata.json
# (lib/check-web-manifest.sh, logos-workspace#250), driven over manifests written
# here.
#
# WHY NOT ONLY THE REAL ARTIFACT. The real artifact is checked where it is built:
# tests/test-web-view-variant.nix runs this same script over the fixture's `web`
# output, and logos-evm-wallet-ui wires `lib.checkWebManifest` into its own
# checks, which is where the module #250 was reported against lives. What neither
# can do is show the comparison REFUSING something -- a green check over a
# correct artifact is indistinguishable from a check that asserts nothing, and
# "the artifact silently disagrees with the source" is the entire defect class
# this exists for. So the cases that matter here are the red ones, and they need
# a manifest that is wrong on purpose.
#
# It is the shipped script that is run, not a copy of its rule: a test that
# re-implemented the comparison would pass while the check was broken.
{ pkgs }:

pkgs.runCommand "web-manifest-check-tests"
  { nativeBuildInputs = [ pkgs.jq pkgs.bash ]; }
  ''
    set -euo pipefail
    failures=0

    src=$TMPDIR/metadata.json
    art=$TMPDIR/manifest.json

    # `agrees NAME` — the script must accept; `differs NAME WORD` — it must
    # refuse, and say which list it refused over. The captured output is `said`
    # and never `out`: $out is this derivation's output path.
    agrees() {
      if said=$(bash ${../lib/check-web-manifest.sh} "$1" "$src" "$art" 2>&1); then
        echo "PASS: $2"
      else
        echo "FAIL: $2"
        echo "$said" | sed 's/^/      /'
        failures=$((failures + 1))
      fi
    }
    differs() {
      if said=$(bash ${../lib/check-web-manifest.sh} "$1" "$src" "$art" 2>&1); then
        echo "FAIL: $3 — the check passed"
        echo "$said" | sed 's/^/      /'
        failures=$((failures + 1))
      elif echo "$said" | grep -q "$2"; then
        echo "PASS: $3"
      else
        echo "FAIL: $3 — refused, but not over $2"
        echo "$said" | sed 's/^/      /'
        failures=$((failures + 1))
      fi
    }

    # ── the green cases ───────────────────────────────────────────────────────
    cat > "$src" <<'EOF'
    {"name":"plain_mod","version":"1.0.0","dependencies":["a_module","b_module"]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"plain_mod","version":"1.0.0","dependencies":["a_module","b_module"]}
    EOF
    agrees plain_mod "a variant that inherits its module's dependencies agrees"

    # THE OVERRIDE IS PART OF THE SOURCE. A variant that legitimately declares a
    # different list is not drift -- that rule is what made #250 look like a
    # packaging bug when it was a declaration.
    cat > "$src" <<'EOF'
    {"name":"over_mod","version":"1.0.0",
     "dependencies":["a_module","b_module","coordinator_module"],
     "optional_dependencies":["c_module"],
     "web":{"dependencies":["a_module"],
            "optional_dependencies":["coordinator_module"]}}
    EOF
    cat > "$art" <<'EOF'
    {"name":"over_mod","version":"1.0.0","dependencies":["a_module"],
     "optional_dependencies":["coordinator_module"]}
    EOF
    agrees over_mod "a variant with its own web lists agrees with them, not with the module's"

    # Both entry spellings -- a bare string and an object with a `name` -- are
    # one declaration, so a manifest that carries either is not a difference.
    cat > "$src" <<'EOF'
    {"name":"spell_mod","version":"1.0.0",
     "dependencies":["a_module",{"name":"b_module","version":"^1.0.0"}]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"spell_mod","version":"1.0.0",
     "dependencies":["a_module","b_module"]}
    EOF
    agrees spell_mod "the two dependency spellings are one declaration"

    # A module with no optional list at all, and a manifest that omits the key.
    cat > "$src" <<'EOF'
    {"name":"bare_mod","version":"1.0.0","dependencies":[]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"bare_mod","version":"1.0.0","dependencies":[]}
    EOF
    agrees bare_mod "an omitted optional_dependencies key is an empty list"

    # ── the red cases, which are the point ────────────────────────────────────
    #
    # #250 ITSELF: five at source, four in the artifact.
    cat > "$src" <<'EOF'
    {"name":"wallet_ui","version":"1.0.0","dependencies":
      ["eth_rpc_module","keystore_module","token_list_module","uniswap_module",
       "wallet_backend_module"]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"wallet_ui","version":"1.0.0","dependencies":
      ["eth_rpc_module","keystore_module","uniswap_module","token_list_module"]}
    EOF
    differs wallet_ui "different dependencies" \
      "a dependency present at source and absent from the artifact is refused"

    # ORDER IS A DIFFERENCE. The core brings a view's dependencies up in
    # declaration order, so two manifests that differ only in order are two
    # different startups.
    cat > "$src" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module","b_module"]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["b_module","a_module"]}
    EOF
    differs m "different dependencies" "a reordered dependency list is refused"

    # AN EXTRA NAME IN THE ARTIFACT is the other direction, and it is worse: the
    # core refuses a module whose declared list it cannot satisfy, so a manifest
    # naming one module more than the source does is an app that will not start
    # on an image the source says is complete.
    cat > "$src" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module"]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module","ghost_module"]}
    EOF
    differs m "different dependencies" "a dependency the source never declared is refused"

    # THE OPTIONAL LIST IS CHECKED TOO. It decides what an image LOADS beside the
    # app (liblogos OptionalLoad::BestEffort), so losing a name there is #250
    # again with a quieter symptom: everything mounts and one screen is dead.
    cat > "$src" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module"],
     "web":{"dependencies":["a_module"],
            "optional_dependencies":["coordinator_module","railgun_module"]}}
    EOF
    cat > "$art" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module"],
     "optional_dependencies":["coordinator_module"]}
    EOF
    differs m "different optional_dependencies" \
      "an optional dependency lost between source and artifact is refused"

    # A manifest carrying ANOTHER module's lists would pass every comparison
    # above, so the identity is checked as well.
    cat > "$src" <<'EOF'
    {"name":"m","version":"2.0.0","dependencies":["a_module"]}
    EOF
    cat > "$art" <<'EOF'
    {"name":"m","version":"1.0.0","dependencies":["a_module"]}
    EOF
    differs m "version" "a manifest that ships a different version is refused"

    [ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
    touch $out
  ''
