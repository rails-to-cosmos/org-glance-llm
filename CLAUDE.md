# org-glance-llm

The `llm` plugin for org-glance: opens `agnostic-llm` (Claude in vterm) sessions
pinned to a headline's data directory. `l` opens one headline's session; `L`
lists every session.

## Invariants

Rules the code silently enforces; any change must preserve them.

1. **One session per headline, keyed by its session DIR** — matched on the
   `*llm:…*` buffer's `default-directory` (or `agnostic-llm--root-override`),
   never the title. The title label is cosmetic, so two same-titled headlines
   still get separate sessions. (`--session-buffer`, `--buffer-dir`.)
2. **Session state is never persisted** — running/exited/stopped is derived live
   at display from `buffer-list` plus the provider's recorded store; there is no
   cache. `L` must stay O(recorded sessions), never scan all headlines.
   (`--session-rows`, `--recorded`.)
3. **agnostic-llm (and vterm) load lazily** — core org-glance must never pull
   vterm at load or byte-compile. Reach agnostic-llm through `declare-function`
   plus a run-time `require`, never a top-level `require`.
4. **Session-dir encoding is `[/.] -> -` of the absolute dir** — `--decode-id`
   reverses it assuming the `data/SHARD/REST` layout and verifies every decode
   via `get-headline` (an id with a literal `.` decodes wrong and is dropped).
   Keep `--data-store-prefix` and `--decode-id` in lock-step with
   `agnostic-llm--session-dir`.
5. **Transient self-registration is idempotent** — remove-then-append the `l`/`L`
   row so reloading the plugin never duplicates it.
6. **Tests load their own files by ABSOLUTE path** (`Eask` test command) — the
   sibling `../org-glance` checkout is on `load-path` and ships its own
   `test/test-helpers.el`; a relative `load` resolves to the core copy and
   shadows this plugin's fixtures. Never revert to a relative `load`.

## Build

- `make test` — clean, compile, run the ert suite (needs sibling `../org-glance`).
- `make lint` — checkdoc + relint.
- `make patch|minor|major|build|rev` — bump the version in `Eask` and the `.el` header.
