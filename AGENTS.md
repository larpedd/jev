# jev — agent notes

A dependency-free Luau ModuleScript (`src/Jev/`) that wraps TypeSafe's
`POST https://api.typesafe.ai/v1/systemone` endpoint. Rojo project, no
Roblox packages, no build step beyond Rojo sync.

## Verify your change

There is **no test suite and no lint/formatter config.** The only gate is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\typecheck.ps1
```

It runs `luau-lsp analyze` over `src/` with `--defs tools/roblox.d.luau`. Exits
non-zero on any diagnostic, including `ImportUnused` — an unused `require` is a
failure, not a warning. Run it from the repo root; Aftman's shims refuse to run
from a directory with no `aftman.toml`.

Behavior can only be exercised in Roblox Studio against a real API key. There is
no way to run this module outside Studio.

## The sourcemap is load-bearing

`sourcemap.json` is gitignored (a build artifact) but **`script.Parent.X`
requires only resolve through it.** Without it the analyzer emits ~180 bogus
diagnostics (`Unknown require: unsupported path`, `Unknown global 'script'`).
`sourcemap.json` also drives `rojo build` / `rojo serve`.

Regenerate it after adding, renaming, or deleting any `.luau` file:

```powershell
rojo sourcemap -o sourcemap.json
```

Verified: a stale sourcemap makes a newly added sibling module fail to resolve,
and the analyzer will not tell you the sourcemap is the cause.

## Roblox defs are hand-maintained

`tools/roblox.d.luau` exists because the analyzer CLI does not download
Roblox's type database. It declares only the Roblox surface `src/Jev` currently
touches. **Touch a new Roblox global and you must add it there too**, or
typecheck fails with `Unknown global`. Your editor uses Roblox's real database
and will not show you this.

## Layout and wiring

`src/Jev/init.luau` is the only public surface; every other file is internal and
reachable only through it. `default.project.json` maps `src/` to
`ServerStorage.Modules`, so the module lands at
`ServerStorage.Modules.Jev` and callers do
`require(game:GetService("ServerStorage").Modules.Jev)`.

Ownership (each file's header comment says the same):

| File | Owns |
| --- | --- |
| `types.luau` | every `export type`; returns `{}`, no runtime behaviour |
| `constants.luau` | endpoints, pricing, limits, `DEFAULTS`, `RETRYABLE_KINDS`, `Null` |
| `util.luau` | `truncate`, `isNonEmptyString` |
| `errors.luau` | `Jev.Error` construction |
| `json.luau` | request-body encoding (hand-rolled, see below) |
| `questions.luau` | the noul/choice/score builders + wire map |
| `validation.luau` | local checks that run before a request is spent |
| `transport.luau` | headers, preflight, retry loop, error-body parsing |
| `decode.luau` | response → `Jev.Result` and the model list |
| `routing.luau` | `Jev.Route` |
| `client.luau` | the copy-on-write client |

Requires use the Roblox sourcemap path form, so they differ by depth:
`init.luau` uses `require(script.constants)`; siblings use
`require(script.Parent.constants)`. Both work; keep whichever the file already
uses.

## Invariants — do not break these

- **The module never calls `error()`.** Every failure is a returned
  `Jev.Error`. Only `transport.luau` touches the network, and it `pcall`s every
  `RequestAsync`. Callers must not need `pcall`.
- **`ok, result | error` two-value return.** Luau cannot tie the boolean to the
  second value, so under `--!strict` callers cast. Do not "improve" this into
  throwing or into a single result table.
- **Copy-on-write client.** Every question and config method returns a *new*
  client; `derive()` deep-copies `_retry` and `table.clone`s `_headers` /
  `_questions`. Mutating in place silently breaks two threads deriving from the
  same base.
- **The API key is never stringified.** For a `Secret`, `transport.luau` builds
  the header with `key:AddPrefix("Bearer ")`; for a string it concatenates.
  There is no accessor that returns it and no log that touches it. Headers are
  lower-cased (HTTP/2 requirement).
- **`Jev.Null` is identity-compared** (`value == C.Null` in `json.luau` and
  `validation.luau`). It must be the required instance, never rebuilt.
- **`json.luau` is hand-rolled on purpose.** `HttpService:JSONEncode` cannot
  represent `Jev.Null`, cannot detect cycles, and handles non-finite numbers
  inconsistently. Do not swap it out.
- **`client.luau` casts through `any` around `setmetatable`.** The type system
  cannot see methods reached via `__index`; removing the cast breaks every
  `client:Noul(...)` call site.
- **`:Retry`/`:Send` accept both `jitter` and `backoffJitter`** as an alias, and
  guard with `type(x) == "number"` rather than `~= nil` — a wrong caller value
  must become a `validation` error, never a comparison error thrown out of
  `Send`. Keep that guard style.

`models()` is lowercase on purpose (it mirrors `GET /v1/models`). Don't
"correct" it to `Models`.

## CONCEPT.md is the spec, README.md is not

`CONCEPT.md` (1600 lines) is the normative specification the module implements.
Read §6, §7, §8, §11, §19, and §12 before changing the public surface; §23
separates normative TypeSafe/Roblox behaviour from *our* inferred design
choices, and tells you which is which. When code and `CONCEPT.md` disagree, fix
one deliberately rather than drifting.

`README.md` is stale Rojo boilerplate (it advertises `jev.rbxmx` while
`.gitignore` lists `jev.rbxlx`) and documents no Jev API. Ignore it.

Upstream docs have `.md` variants — append `.md` to any `docs.typesafe.ai` URL
for clean markdown. TypeSafe publishes an index at
`https://docs.typesafe.ai/llms.txt`. Note `typesafe.io` is an unrelated company;
use `docs.typesafe.ai`.

## Roblox constraints that shape the code

- `Send` yields for the whole request plus retry backoff. Callers must wrap it
  in `task.spawn` inside `RemoteEvent`/`PlayerAdded` handlers.
- **500 non-Open-Cloud requests per minute per game server** is the binding
  limit, and over-cap requests stall ~30s rather than failing fast. `CONCEPT.md`
  §16.2 is why the design favours one batched request with many questions over
  one request per item.
- `HttpService:GetSecret` only resolves on live servers and collaborative
  testing. Local Play needs a Local Secret, or use a hardcoded string in Studio
  guarded by `RunService:IsStudio()`.
- Roblox's header restriction to `x-api-key`/`content-type` applies to
  Open Cloud endpoints, not to third parties. `authorization` is correct here.

## Conventions

Tabs, double quotes, `--!strict` on line 1 of every file, a header comment
explaining what the file owns, and `local X = require(...)` aliases
(`C` for constants, `Types`, `Errors`, `Util`, `Questions`, `Transport`,
`Json`, `Decode`, `Validation`). Sibling methods are `function M:Name()` on a
plain table, never a class.

`aftman install` provisions `rojo` 7.7.0 and `luau-lsp` 1.70.1 into
`~/.aftman/bin`. If it fails with `The process cannot access the file because it
is being used by another process`, a Rojo server or editor plugin is holding
`rojo.exe`; close it and retry.
