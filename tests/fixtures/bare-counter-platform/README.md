# `bare-counter-platform`

METADATA ONLY, ON PURPOSE. This directory holds one `metadata.json` and no
sources: it is `bare-counter`'s metadata with `"platform": true` added, and it
is used with **bare-counter's own `src/`**:

```nix
mkLogosModule {
  src        = fixturesRoot + "/bare-counter";
  configFile = fixturesRoot + "/bare-counter-platform/metadata.json";
}
```

That is the whole point. A separate fixture with its own copy of the counter
would prove that *some* module has no `web` output; the same sources under two
metadata files prove that the **declaration** is what removes it, with nothing
else different to blame — the module still builds its `bare` artifact, and the
name it is known by does not change.

See `tests/test-web-variant.nix` and ADR 0009 in logos-workspace.
