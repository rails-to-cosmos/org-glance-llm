# org-glance-llm

The `llm` plugin for org-glance opens `agnostic-llm` sessions pinned to a
headline's data directory. `l` opens one headline's session; `L` lists sessions
for the selected provider.

## Invariants

1. **One session per provider and headline** — identity is the provider plus
   session directory, never the cosmetic title. Claude and Codex may both own a
   session rooted at one headline.
2. **Session state is never persisted** — running/exited/stopped is derived live
   from provider-recorded sessions and buffers. `L` stays O(recorded sessions)
   and never scans all headlines.
3. **Provider owns its models** — provider selection and model catalogs come
   from `agnostic-llm`; this plugin carries no duplicate model registry.
4. **agnostic-llm and vterm load lazily** — core org-glance must never pull
   vterm at load or byte-compile. Reach agnostic-llm through declarations and
   autoloaded entry points, never a top-level `require`.
5. **Provider storage layouts remain distinct** — Claude encodes session roots
   as direct children of its store; Codex stores date-partitioned rollouts whose
   metadata names the CWD. Both decode only paths inside this graph's data store.
6. **Session-dir encoding is `[/.] -> -` for directory-encoded providers** —
   keep `--data-store-prefix` and `--decode-id` in lock-step and verify decoded
   ids through `get-headline`.
7. **Transient self-registration is idempotent** — remove then append the
   `l`/`L` row so reloading never duplicates it. Provider selection is `-p`
   beside `-m` in the pinned LLM menu; reloading leaves one provider choice.
8. **Tests load their own files by absolute path** — the sibling `../org-glance`
   checkout has identically named helpers; relative loading can shadow these.

## Build

- `make test` — clean, compile, run ERT (needs sibling `../org-glance`).
- `make lint` — checkdoc and relint.
- `make patch|minor|major|build|rev` — bump versions in `Eask` and the Elisp header.
