# Jev — a Luau client for TypeSafe's System One API

`Jev` is a dependency-free Roblox module — one `require`, no packages — that
wraps TypeSafe's `POST https://api.typesafe.ai/v1/systemone` endpoint. It lets a
Roblox experience ask a model (`jev-latest`) structured questions about a piece
of state and get back typed, calibrated answers — probabilities and confidences
your own Luau code can threshold, branch on, and combine.

The module name is the model name: TypeSafe's flagship model is **Jev**, and
`jev-latest` is the alias every example in their docs uses.

This document is the specification. It was written before the module was
implemented and is meant to be picked up cold by whoever builds it. Read the
whole thing before writing code; the API surface is already decided.

---

- [1. What the module does](#1-what-the-module-does)
- [2. Requirements and setup](#2-requirements-and-setup)
- [3. Installing and requiring the module](#3-installing-and-requiring-the-module)
- [4. Quickstart](#4-quickstart)
- [5. The three question primitives](#5-the-three-question-primitives)
- [6. The client](#6-the-client)
- [7. Building questions](#7-building-questions)
- [8. Sending a request](#8-sending-a-request)
- [9. Reading answers](#9-reading-answers)
- [10. Validation rules and limits](#10-validation-rules-and-limits)
- [11. Errors and retries](#11-errors-and-retries)
- [12. Roblox-specific behaviour](#12-roblox-specific-behaviour)
- [13. Confidence and routing](#13-confidence-and-routing)
- [14. Listing models](#14-listing-models)
- [15. Token usage and cost](#15-token-usage-and-cost)
- [16. Patterns](#16-patterns)
- [17. What Jev is bad at](#17-what-jev-is-bad-at)
- [18. Testing in Studio](#18-testing-in-studio)
- [19. API reference](#19-api-reference)
- [20. Troubleshooting](#20-troubleshooting)
- [21. Security checklist](#21-security-checklist)
- [22. Limits cheat sheet](#22-limits-cheat-sheet)
- [23. Sources](#23-sources)

**If you are implementing this:** read §6, §7, §8, §11
and §19, and skip to §12 before writing any HTTP code. §16 through §18 are
context for *callers* and can come last.

---

## 1. What the module does

One HTTP call to TypeSafe is: send a `state`, send a map of `questions`, get back
a map of `answers`. The questions are typed — `noul`, `choice`, `score` — and so
are the answers.

```json
{
  "state": "Hi, I've been trying to connect my Stripe account for 3 days and the integration keeps failing. I'm losing sales. Please help ASAP.",
  "model": "jev-latest",
  "questions": {
    "is_urgent": { "type": "noul", "instructions": "Does this message convey urgency?" }
  }
}
```

```json
{
  "model": "jev-1.13.0",
  "answers": {
    "is_urgent": { "type": "noul", "noul": 0.95 }
  },
  "usage": { "input_tokens": 296, "output_tokens": 20 }
}
```

The module's job is to make that call from inside a Roblox server without you
hand-writing `HttpService:RequestAsync`, and without you having to deal with
Roblox's failure modes: keys stored as `Secret` datatypes, `pcall`-ing every
request, retrying `429` and `529` with backoff, and reading `usage` off the
response.

It deliberately does **not** try to be a general HTTP client, and it does not
hide the API. The request body it sends is the documented TypeSafe request body.

---

## 2. Requirements and setup

### 2.1 Roblox-side requirements

| Requirement | Why | Where |
| --- | --- | --- |
| **Allow HTTP Requests** enabled | `HttpService:RequestAsync` throws without it | Studio: `File ⟩ Experience Settings ⟩ Security ⟩ Allow HTTP Requests` |
| **Server-side execution** | Secrets are unreadable from client scripts, and a client-held key is public | ServerScriptService, not LocalScript |
| **A TypeSafe API key** | Bearer auth on every call | [console.typesafe.ai/keys](https://console.typesafe.ai/keys) |
| **An experience that can be published or collaborative-tested** | The secrets store does not exist in local playtesting | See [§18](#18-testing-in-studio) |

The module can fail fast if HTTP is off: constructing a client checks
`HttpService.HttpEnabled` and reports `config` with the Studio setting name if
requests are disabled.

### 2.2 Getting a key

Create a key in the TypeSafe dashboard. Keys look like `sk-...`. Treat it as a
credential: it bills your account, and a leaked key lets anyone spend your money.

### 2.3 Storing the key — the important part

There are three ways to supply a key, in descending order of safety.

**1. `HttpService:GetSecret` (recommended for anything published).**

```luau
local HttpService = game:GetService("HttpService")
local key = HttpService:GetSecret("typesafe_api_key")
```

In the Creator Dashboard: `Creations ⟩ <your game> ⟩ Secrets ⟩ Create Secret`.

- Name it `typesafe_api_key` (or whatever you pass to `GetSecret`).
- Set the secret's **domain** to `api.typesafe.ai`. Roblox scopes secrets by
  domain; a wildcard `*` works but is discouraged.
- The store only resolves secrets on **live servers** and in **collaborative
  testing**. In local playtesting you get `Can't find secret with given key`
  unless you created a Local Secret.
- `GetSecret` returns a `Secret` datatype, not a string. You cannot `tostring`
  it, concatenate it, or log it. `print(secret)` prints `Secret(name)`. You can
  only do `secret:AddPrefix(x)` and `secret:AddSuffix(y)`.
- Secrets may appear in the **URL or headers** only, never in a request body.
  The module therefore sends it as `Authorization: Bearer <key>`.
- If you accidentally call `GetSecret` from a client script you get the same
  `Can't find secret with given key` error — a client can never read a secret.

**2. Local Secrets (for Studio).** `File ⟩ Experience Settings ⟩ Security ⟩
Local Secrets`. Same name, same shape, only in Studio.

**3. A hardcoded string.** Works, ships your key to every client, and is a
`Secret` violation waiting to happen. Use it only for a local scratch test that
never gets published, and pass it via the constructor as a plain string:

```luau
local client = Jev.new("sk-local-dev-only")
```

### 2.4 TypeSafe-side requirements

- A key with access to at least one model. `GET /v1/models` lists what your key
  can send; the module wraps it as `client:models()`.
- Billing enabled. Calls are charged per input token; see [§15](#15-token-usage-and-cost).

---

## 3. Installing and requiring the module

The module is a folder of `ModuleScript`s with no dependencies beyond
`HttpService` and `tostring`-free `Secret` handling. `init.luau` is the entry
point and the only file callers name; the rest are its internals. It is
currently served from `ServerStorage/Modules/Jev` by this repo's
`default.project.json`.

Copy the whole `src/Jev/` folder into your own Rojo project:

```json
{
  "name": "my_game",
  "tree": {
    "$className": "DataModel",
    "ServerStorage": {
      "Modules": {
        "$path": "src/"
      }
    }
  }
}
```

Require it once, at the top of a server script:

```luau
local Jev = require(game:GetService("ServerStorage").Modules.Jev)
```

`require` is safe anywhere. Constructing a client with a secret is only safe on
the server, and only where the secrets store resolves — see
[§2.3](#23-storing-the-key--the-important-part).

The module returns the class table itself. There is no `Jev.new()` side effect
and no global state beyond the class.

---

## 4. Quickstart

Classify a player's chat message, gauge how upset they are, and escalate when
both signals agree.

```luau
local Jev = require(game:GetService("ServerStorage").Modules.Jev)
local HttpService = game:GetService("HttpService")

local client = Jev.new(HttpService:GetSecret("typesafe_api_key"))

local function onChat(player, message)
    local state = {
        message = message,
        display_name = player.DisplayName,
        username = player.Name,
    }

    local ok, result = client
        :Choice("category", "Which category best describes this message?", {
            chat = "Casual conversation between players",
            complaint = "The player is reporting a problem with the game",
            exploit_attempt = "The player appears to be using or requesting cheats",
        })
        :Score("tone", "How hostile is the player's tone?", {
            "Friendly and playful",
            "Neutral",
            "Annoyed",
            "Hostile or abusive",
        })
        :Noul("wants_staff", "Does this message ask for staff help or attention?")
        :Send(state)

    if not ok then
        -- The module never errors, so decide what a failure means for you.
        -- See §11 for the shape of `result`.
        warn(("[jev] %s failed: %s"):format(player.Name, result.kind))
        return
    end

    local category = result.answers.category
    local tone = result.answers.tone

    if category.choice == "exploit_attempt" then
        player:Kick("Attempting to exploit the game is not allowed.")
        return
    end

    if category.choice == "complaint" and tone.score >= 2 then
        -- Confidence is a second axis: act only when the model is sure.
        if tone.confidence > 0.7 then
            reportToStaff(player, message, tone.score)
        else
            flagForManualReview(player, message)
        end
    end
end
```

Note what is *not* there: no `pcall`, no `Content-Type` header, no
`JSONEncode`, no `task.wait`, no status-code branching, no retry loop, no
`usage` accounting. One `Send` call, and the module handles the rest.

---

## 5. The three question primitives

Every question is one of three types. All three share `type` and `instructions`.
Choice and Score require `criteria`; Noul accepts it as optional clarification.

| Type | Asks | Returns | Criteria shape |
| --- | --- | --- | --- |
| **Noul** | Is this true? | `noul` — probability of yes, 0 to 1 | optional `{ true = ..., false = ... }` |
| **Choice** | Which of these? | `choice`, `probabilities`, `confidence` | map of option to description |
| **Score** | Which level? | `score`, `legend`, `probabilities`, `confidence` | ordered array of 2 to 10 level descriptions |

```luau
-- Noul: a yes/no judgment. The number itself is the signal.
Jev.new(key):Noul("pii", "Does this message contain an email address or phone number?")

-- Choice: one of a known set, no order between the options.
Jev.new(key):Choice("language", "Which programming language is this file?", {
    luau = "Roblox Luau with Roblox APIs",
    python = "Python",
    other = "Any other language",
})

-- Score: a position on a spectrum you describe.
Jev.new(key):Score("severity", "How severe is this bug?", {
    "Cosmetic; no impact on functionality",
    "Degraded; a workaround exists",
    "Blocking; no workaround exists",
})
```

**Choosing between them.** Use Noul for a clean yes/no where the probability is
the useful output. Use Choice when the answer is one of a closed set your code
can branch on directly. Use Score when the answer sits on a spectrum you can
describe level by level. A Noul of `0.5` means "the model gives yes and no equal
weight" — it does **not** mean "medium". If you need a position on a scale, ask
a Score.

**Every answer is constrained to the options you supplied.** The model returns
a distribution over *your* options, never a value outside them, so your code
never has to parse generated prose. That is the property that makes this usable
inside a game loop.

**Questions are independent.** One answer never becomes hidden context for
another. Add or remove questions without disturbing the rest.

---

## 6. The client

```luau
local client = Jev.new(apiKey)
```

`apiKey` is either a `Secret` from `HttpService:GetSecret` or a plain string.
The module keeps it in a private field; it is never logged, never returned, and
never placed in a request body.

### 6.1 Every method returns a new client

This is the rule that makes the chainable builder safe. `:Noul`, `:Choice`,
`:Score`, `:Model`, `:Retry`, `:Timeout`, and `:MaxRetries` all **return a new
client** with the change applied. Your original client is untouched.

```luau
local base = Jev.new(key)

local a = base:Noul("urgent", "Does this convey urgency?")
local b = base:Noul("spam", "Is this message spam?")

-- base has zero questions; a and b each have exactly one.
```

Consequences worth relying on:

- A base client is a reusable template. Build questions off it per request.
- Two threads deriving from the same base client cannot corrupt each other. No
  mutex, no `table.clone`, no "don't call this from two places" caveat.
- You can name intermediate clients for readability:

```luau
local withTriage = base
    :Choice("category", "Which category best describes this message?", CATEGORIES)
    :Noul("needs_human", "Does this message need a human response?")

-- later, two different conversations, two different derived clients
local convoA = withTriage:Noul("second_try", "Did the user try again?")
local convoB = withTriage:Noul("mentions_price", "Does the user mention price?")
```

### 6.2 Configuration methods

All of these are also copy-on-write.

| Method | Effect | Default |
| --- | --- | --- |
| `:Model(name)` | Sets the `model` field | `"jev-latest"` |
| `:Timeout(seconds)` | Per-attempt timeout | `30` |
| `:MaxRetries(n)` | Retries after the first attempt; `0` disables | `2` |
| `:Retry(overrides)` | Sets several retry knobs at once | see [§11.4](#114-retry-defaults) |
| `:Header(name, value)` | Adds a request header (lower-cased) | none |

`:Model` matters for reproducibility. `jev-latest` is an **alias** that moves
when a new release ships, so answers can change without your code changing. The
response's `model` field reports the versioned ID that answered. If you have
tuned confidence thresholds against a specific version, pin it:

```luau
local pinned = client:Model("jev-1.13.0")
```

`GET /v1/models` currently lists the aliases; versioned IDs are accepted whether
or not they appear in the list.

---

## 7. Building questions

### 7.1 Noul

```luau
client:Noul(id, instructions)
client:Noul(id, instructions, criteria)
```

`criteria` is optional and takes `true` and `false` descriptions of what each
answer means.

```luau
client:Noul("is_urgent", "Does this convey urgency or time-sensitivity?", {
    true = "The message states a deadline, a business impact, or an explicit plea for speed",
    false = "The message is a routine request with no time pressure",
})
```

The keys may be written as the booleans `true` / `false` or as the strings
`"true"` / `"false"`; both spellings encode to the same JSON keys, so an editor
that rewrites them changes nothing on the wire. Use one spelling per table —
describing `true` and `"true"` in the same `criteria` is a `validation` error,
because they would collide into a single key.

Keep `true` and `false` pointing the same way as the question. A Noul whose
`true` means "no" performs measurably worse.

### 7.2 Choice

```luau
client:Choice(id, instructions, criteria)
```

`criteria` is a **map** of option name to description. Names are yours to pick
and come back in the answer. Descriptions may be a string, a table, or
`Jev.Null` when an option needs no elaboration.

```luau
client:Choice("department", "Which team should handle this ticket?", {
    billing = "Payments, invoicing, refunds, subscriptions",
    technical = "Bugs, outages, third-party integrations",
    game_design = "Balance, progression, economy",
    other = Jev.Null, -- an explicit escape hatch, always include one
})
```

Include an `other` / `none of the above` option whenever your set might not
cover every input. A closed set with no escape makes the model pick the least
bad option instead of admitting it does not know, which shows up as a confident
wrong answer rather than a low confidence one.

Hard cap: **255 options** per Choice.

### 7.3 Score

```luau
client:Score(id, instructions, levels)
```

`levels` is an **ordered array** of level descriptions. Level `0` is the first
element. At least two, at most ten.

```luau
client:Score("frustration", "How frustrated does the player appear?", {
    "Calm, matter-of-fact",
    "Frustrated but civil",
    "Angry, strong language",
})
```

The answer's `score` is a probability-weighted position across those levels and
can land between two of them — `1.05` means "just past level 1". `legend` maps
each index back to your description text.

### 7.4 Structured instructions

`instructions` is usually a string, but it can be an object or array. Put the
question in one field and the data it refers to in the others:

```luau
client:Choice("duplicate", "Is the resume for the same person as `candidate`?", {
    candidate = {
        name = "John Smith",
        location = "Oakland, California",
        last_employer = "Google",
    },
})
```

### 7.5 Referring to state by path

When `state` is a structured object, point a question at the field it should
judge using a dot-and-index path **in backticks**:

```luau
local state = {
    ticket = {
        subject = "Duplicate charge",
        messages = {
            { from = "customer", text = "I was charged twice for order A-104. Please refund the duplicate." },
            { from = "support", text = "We are checking the charges." },
        },
    },
    order = { id = "A-104", charges = { { amount_usd = 49 }, { amount_usd = 49 } } },
    refund_policy = "Duplicate charges are eligible for a refund.",
}

client
    :Noul("refund_requested", "Does `ticket.messages[0].text` request a refund?")
    :Noul("policy_supports", "Does `refund_policy` support the refund requested in `ticket.messages[0].text`, given `order.charges`?")
    :Send(state)
```

Explicit paths are the single highest-leverage thing you can do. They cut
through the model's biggest weakness, which is guessing which part of a long
state you meant.

### 7.6 Question IDs

The key you pick is how the answer comes back. It is **not** sent to the model
and does not influence inference. Write the complete question in
`instructions` even when the ID looks self-explanatory.

IDs must be unique within one client, must be non-empty strings, and cannot
contain the characters used to build the response path. Use `snake_case`.

### 7.7 Reusable question sets

The builder methods are just sugar over plain tables, so a question set can
live in a module and be shared:

```luau
-- ReusableQuestionSets.lua (a ModuleScript)
local function apply(base)
    return base
        :Noul("is_urgent", "Does this convey urgency or time-sensitivity?")
        :Noul("mentions_competitor", "Does the player name a competing game?")
end

return { apply = apply }
```

```luau
local Reusable = require(script.Parent.ReusableQuestionSets)

local client = Jev.new(HttpService:GetSecret("typesafe_api_key"))
local clientWithBasics = Reusable.apply(client)

local ok, result = clientWithBasics
    :Choice("category", "Which category best describes this message?", CATEGORIES)
    :Send(state)
```

---

## 8. Sending a request

```luau
local ok, result = client:Send(state)
local ok, result = client:Send(state, {
    timeout = 45,
    model = "jev-1.13.0",
    maxRetries = 0,
})
```

`state` may be a string, an object, or an array — the three shapes TypeSafe
accepts. Prefer an object even for one message; named fields keep the
relationships legible to the model and let you point at them by path later.

`Send` is a **yielding** call: it suspends the calling thread for the duration
of the HTTP request and any retry backoff. It never calls `error`, so it does
not need a `pcall` — but it does need a thread you are willing to wait on.

```luau
-- In a RemoteEvent handler: spawn so the callback does not yield.
game:GetService("ReplicatedStorage").ChatHandler.OnMessage:Connect(function(player, message)
    task.spawn(function()
        local ok, result = client
            :Noul("is_urgent", "Does this convey urgency?")
            :Send({ message = message })

        if not ok then
            return
        end

        -- ... use result
    end)
end)
```

**Do not call `Send` from a thread that must stay responsive.** A `RemoteEvent`
connection that yields blocks every other connection on that signal. Wrap
network work in `task.spawn`, and in a `while` loop use `task.wait` between
iterations rather than sleeping the whole server.

**`Send` does not mutate the client.** You can reuse the same derived client for
many states.

### 8.1 The request the module sends

```json
{
  "state": { "...": "your value" },
  "model": "jev-latest",
  "questions": {
    "is_urgent": { "type": "noul", "instructions": "Does this convey urgency?" }
  }
}
```

with `Content-Type: application/json` and `Authorization: Bearer <key>`. Every
question id you added becomes a key in `questions`. Nothing else is added.

---

## 9. Reading answers

On success, `result` is a table:

```luau
{
    model = "jev-1.13.0",        -- the versioned ID that actually answered
    answers = { [id] = Answer },
    usage = {
        input_tokens = 392,
        output_tokens = 65,
        input_cost = 0.0000165,  -- USD, estimated at the current rate
    },
    attempts = 1,                -- how many HTTP attempts it took
    latency = 0.412,             -- seconds, end to end
}
```

### 9.1 Noul answer

```luau
local answer = result.answers.is_urgent
answer.type       -- "noul"
answer.noul       -- 0.95, probability of yes
```

No `confidence` on a Noul — the probability is the whole answer.

### 9.2 Choice answer

```luau
local answer = result.answers.category
answer.type             -- "choice"
answer.choice           -- "billing"
answer.confidence       -- 0.81
answer.probabilities   -- { billing = 0.88, technical = 0.12, sales = 0.0 }
```

`answer.probabilities` always contains **every** option you defined, so
`answer.probabilities.department` is safe even when that option lost.

### 9.3 Score answer

```luau
local answer = result.answers.frustration
answer.type           -- "score"
answer.score          -- 1.05, weighted position across levels
answer.confidence     -- 0.92
answer.legend         -- { [0] = "Calm", [1] = "Frustrated", [2] = "Very angry" }
answer.probabilities  -- { [0] = 0.0, [1] = 0.95, [2] = 0.05 }
```

`legend` and `probabilities` are keyed by **numeric level index**, not by
description. `legend[0]` is the first entry of your `criteria` array.

### 9.4 Reading answers defensively

Never index `result.answers[id]` without checking the id exists. If you build a
question id dynamically, or you send a set whose ids you generated from data, a
typo becomes a `nil` index and a confusing downstream error.

```luau
local answer = result.answers[questionId]
if not answer then
    warn(("[jev] no answer for question %q"):format(questionId))
    return
end
```

Also branch on `answer.type` rather than assuming. The module passes the type
through from the response, and a Noul answer has no `confidence` field — reading
`answer.confidence` off a Noul yields `nil`, which is falsy, so a naive
`if answer.confidence > 0.7 then` silently never fires.

---

## 10. Validation rules and limits

The module checks what it can locally, before spending a request. A local
failure returns `ok == false` with `kind == "validation"` and never touches the
network.

| Rule | Limit | On violation |
| --- | --- | --- |
| `state` is a string, object, or array | — | `validation` |
| At least one question | — | `validation` |
| Question ids unique, non-empty strings | — | `validation` |
| Choice `criteria` non-empty | — | `validation` |
| Choice options | 255 max | `validation` |
| Score levels | 2 to 10 | `validation` |
| Noul `criteria` keys | `true` / `false`, boolean or string, once each | `validation` |
| Answer ids match question ids | — | `decode` |
| Answer `type` matches question `type` | — | `decode` |

Server-side limits you cannot check locally, and the API enforces with `422`:

- A Score needs at least two levels; the API accepts up to ten.
- A Choice allows at most 255 options.
- `instructions` and every criteria description accept a string, object, array,
  or (for Choice option descriptions) `null`.

Context budget for `jev-1.13`:

- **32k tokens** for `state` plus the single longest question.
- **64k tokens** for `state` plus *all* questions combined.

The first limit is the one that bites. One huge `state` with two small questions
is fine; a huge `state` with one huge question is not. Truncate or filter in
Luau before sending — see [§17](#17-what-jev-is-bad-at).

---

## 11. Errors and retries

### 11.1 The return contract

Every method that talks to the network returns exactly two values:

```luau
local ok, result = client:Send(state)

if ok then
    -- result.model, result.answers, result.usage
else
    -- result is an error table
end
```

The module never calls `error`, so you never need `pcall` around it.

The second value is typed `Jev.Result | Jev.Error`. Luau cannot tie a separate
boolean to a second return value, so `if ok then` does **not** narrow it. Under
`--!strict` say which arm you are on with one cast:

```luau
local ok, result = client:Send(state)

if not ok then
    local err: Jev.Error = result :: Jev.Error
    warn(err.message)
    return
end

local okResult: Jev.Result = result :: Jev.Result
print(okResult.model, okResult.usage.input_tokens)
```

The cast cannot be wrong in practice: the module only returns the error table
alongside `ok == false`, and the result table alongside `ok == true`. The same
applies to `:models()`, whose second value is `Jev.ModelInfo[] | Jev.Error`.

### 11.2 The error table

```luau
{
    kind = "validation",    -- see table below
    message = "...",        -- human readable, safe to log
    status = 401,           -- HTTP status, or nil for local/transport failures
    field = "questions.x.criteria",  -- set when the API names the offending field
    retryable = false,
    attempts = 1,
    cause = "Unauthorized", -- raw status message / transport error
}
```

| `kind` | Meaning | Typical cause | Retryable |
| --- | --- | --- | --- |
| `validation` | The module rejected your arguments before sending | bad criteria, duplicate id | no |
| `config` | The module cannot work in this environment | HTTP requests disabled | no |
| `auth` | `401` | missing or invalid API key | no |
| `forbidden` | `403` | key cannot use that model, or domain not allowlisted | no |
| `notfound` | `404` | wrong endpoint path | no |
| `validation` (server) | `422` | the API rejected the body; `field` names the problem | no |
| `rate_limited` | `429` | account or Roblox-server request cap | yes |
| `overloaded` | `529` | TypeSafe temporarily overloaded | yes |
| `server` | `5xx` | upstream problem | yes |
| `network` | transport | DNS, TLS, timeout, `pcall` failure | yes |
| `decode` | malformed response | body was not the documented shape | no |
| `timeout` | per-attempt timeout elapsed | request took too long | yes |

Distinguishing `network` from `server` matters: `network` means Roblox or the
connection failed, so the request may never have reached TypeSafe, and it
therefore may or may not have been billed. `server` means it was answered.

### 11.3 What the module does automatically

- Wraps every `RequestAsync` in a `pcall`, so a transport failure becomes
  `kind = "network"` rather than a script error.
- Retries the retryable kinds listed above.
- Honours `Retry-After` and `retry-after-ms` response headers when present,
  capped by the remaining budget.
- Applies exponential backoff with jitter, so a burst of servers backing off at
  once does not resynchronise into a second burst.
- Stops when the total time budget would be exceeded, and returns the last
  error rather than a fresh timeout.
- Parses the error body so `field` is populated on a `422`.

### 11.4 Retry defaults

| Knob | Default | Notes |
| --- | --- | --- |
| `maxRetries` | `2` | retries *after* the first attempt; total 3 attempts |
| `backoffInitial` | `0.5` s | first delay, doubled each attempt |
| `backoffMax` | `5.0` s | delay ceiling |
| `backoffJitter` | `0.25` | fraction of each delay randomly removed |
| `timeout` | `30` s | total budget per `Send`, including attempts and delays |
| `httpStatuses` | `408`, `429`, `5xx` | plus `529` |

Override with `:Retry`:

```luau
local patient = client
    :MaxRetries(4)
    :Timeout(60)
    :Retry({ backoffInitial = 1.0, backoffMax = 8.0, jitter = 0.4 })
```

Or per call:

```luau
local ok, result = client:Send(state, { maxRetries = 0, timeout = 5 })
```

`maxRetries = 0` is the right setting for anything user-facing on a latency
budget — a chat filter that waits 30 seconds to make an obvious call is worse
than one that falls back to a static rule.

### 11.5 Handling errors in practice

```luau
local function trySend(client, state)
    local ok, result = client:Send(state)

    if ok then
        return result :: Jev.Result
    end

    local err: Jev.Error = result :: Jev.Error

    if err.kind == "auth" then
        -- A bug, not a runtime condition. Alert loudly, once.
        -- `cause` is optional, so wrap it: it is absent on local failures.
        error(("[jev] API key rejected: %s"):format(tostring(err.cause)))
    end

    if err.retryable then
        -- Degrade, don't fail. Route to the static path.
        return nil
    end

    warn(("[jev] %s: %s"):format(err.kind, err.message))
    return nil
end
```

On a `429`, the correct response is to let the module back off and to stop
calling it more often, not to shorten the timeout. See
[§12.4](#124-roblox-request-caps) for the Roblox-side cap.

---

## 12. Roblox-specific behaviour

### 12.1 `RequestAsync` semantics

The module calls `HttpService:RequestAsync` and reads:

| Field | Meaning |
| --- | --- |
| `Success` | `true` only for 2xx |
| `StatusCode` | present even when `Success` is `false` |
| `StatusMessage` | sometimes empty; the module falls back to `StatusCode` |
| `Headers` | returned lower-cased |
| `Body` | the raw string, present on `4xx`/`5xx` too |

The `Body`-on-failure detail is what makes `422` field extraction possible: a
`Success == false` response still carries the body that explains what was wrong.
Do not write your own request loop that bails out at `Success == false` without
reading `Body`.

### 12.2 Headers and HTTP/2

Roblox uses HTTP/2 when the endpoint supports it, and HTTP/2 requires header
names in lower case. The module sends `content-type` and `authorization` in
lower case, and lower-cases anything you add with `:Header`.

Note that Roblox's documented restriction to *only* `x-api-key` and
`content-type` headers applies to Roblox-hosted Open Cloud endpoints, not to
third-party services. `authorization` is fine here.

### 12.3 Secrets, again

If you pass a `Secret`, the module builds the header with
`secret:AddPrefix("Bearer ")`. It never stringifies the key. If you pass a
string, it concatenates. There is no code path that logs the value, and the
client has no accessor that returns it.

A `Secret` can only be used in a URL or header, never a body — which is
convenient, because that is exactly where the key belongs.

### 12.4 Roblox request caps

| Limit | Value | Scope |
| --- | --- | --- |
| Non-Open-Cloud HTTP requests | **500 per minute per game server** | Roblox |
| Open Cloud requests | 2,500 per minute per game server | Roblox |
| TypeSafe requests | 1,200 per minute per API key | TypeSafe |
| TypeSafe tokens | 250,000 per second per key | TypeSafe |

Exceeding the Roblox cap makes `RequestAsync` **stall for about 30 seconds**, and
`pcall` may fail with `Number of HTTP requests exceeded limit`. The module
surfaces that as `kind = "network"`, and because it is retryable it will try
again — which, if you are genuinely over the cap, wastes the budget. If you see
that exact message repeatedly, the fix is to send fewer requests, not to retry
harder.

**500 requests per minute per server is the binding constraint for almost every
use of this module.** A server with 60 players, each sending one chat message
per 30 seconds, generates 120 requests per minute. A server where every player
runs a per-second evaluation will hit the cap in under ten seconds.

This is the strongest argument for the fan-out pattern in
[§16.1](#161-speculative-fan-out--one-request-many-questions): one request per
batch, not one per item.

### 12.5 Threading and yielding

`Send` yields. Inside a `RemoteEvent` or `BindableEvent` connection, wrap it in
`task.spawn` — otherwise every other handler on that signal waits for the HTTP
round trip. Inside `Players.PlayerAdded`, also `task.spawn`: blocking player
join on a remote API is how a game ends up with a frozen join queue.

### 12.6 Data you send leaves the server

Everything in `state` is transmitted to `api.typesafe.ai` and is billed per
token. Do not send player tokens, personal data, or anything your privacy policy
does not cover. Filter in Luau first — which is good practice anyway, because
unrelated detail degrades accuracy ([§17](#17-what-jev-is-bad-at)).

---

## 13. Confidence and routing

Choice and Score answers carry `confidence`, a single number from 0 to 1 derived
from how peaked the probability distribution is. All mass on one option gives
`1.0`; an even split gives `0.0`.

The module ships a three-band helper matching TypeSafe's recommended pattern:

```luau
local action = Jev.Route(result.answers.action)
-- "act"     -- confidence above autoThreshold, proceed
-- "confirm" -- above reviewThreshold, ask the user or flag for review
-- "review"  -- below reviewThreshold, do not guess
```

```luau
local ACT, CONFIRM = 0.9, 0.6

local function route(player, state)
    local ok, result = client
        :Choice("action", "What is the player trying to do?", {
            check_balance = "View their balance",
            approve_transfer = "Approve the pending withdrawal",
            support = "Get help with an issue",
        })
        :Send(state)

    if not ok then
        return openFallbackMenu(player)
    end

    local answer = result.answers.action
    local decision = Jev.Route(answer, ACT, CONFIRM)

    if decision == "review" then
        return openSupportChat(player) -- genuinely unsure; do not guess
    end

    if answer.choice == "approve_transfer" then
        if decision == "act" then
            confirmThenExecute(player)
        else
            askUserToConfirm(player) -- high stakes, moderate confidence
        end
        return
    end

    -- check_balance / support: low stakes, wrong answer is recoverable
    showScreen(player, answer.choice)
end
```

**Thresholds scale with risk, not with the model.** A read-only screen can act
at `0.7`. A transfer approval should not act below `0.95`. Start conservative,
measure against your own content, and tighten from there. Do not carry a
threshold tuned on a Noul over to a Choice, or between versions of the model —
the numbers are not interchangeable.

You can also compute your own confidence from `probabilities`; the module
delivers them in full precisely so you are not locked into one definition.

---

## 14. Listing models

```luau
local ok, models = client:models()

if ok then
    for _, model in ipairs(models) do
        print(model.name, model.release_date, model.description)
    end
end
```

Wraps `GET /v1/models`, returning a plain array of:

```luau
{ name = "jev-latest", description = "...", release_date = "..." }
```

Currently this lists the **aliases**, not versioned IDs. Versioned IDs like
`jev-1.13.0` are accepted by the `model` field whether or not they appear in
this list, so a missing `jev-1.13.0` here does not mean you cannot pin to it.

This call is subject to the same 500/minute Roblox cap. Cache it — model lists
change a few times a year at most:

```luau
local CACHE_TTL = 3600
local cached, cachedAt

local function getModels(client)
    if cached and os.clock() - cachedAt < CACHE_TTL then
        return cached
    end
    local ok, models = client:models()
    if ok then
        cached, cachedAt = models, os.clock()
    end
    return cached
end
```

---

## 15. Token usage and cost

Every successful response carries usage:

```luau
result.usage.input_tokens    -- 392
result.usage.output_tokens   -- 65
result.usage.input_cost      -- 0.0000165 (USD)
```

Pricing is per **input** token; output tokens are free. Jev 1.13 is
**$42 per billion input tokens**, which is $0.042 per million:

```luau
local INPUT_COST_PER_TOKEN = 0.042 / 1_000_000 -- USD, also exported as Jev.INPUT_COST_PER_TOKEN
```

That makes a 400-input-token request cost about **$0.0000168**, so 100,000 such
requests cost about **$1.68**. Batch aggressively and the cost is almost
irrelevant; send one request per chat message and it is not.

A per-server accumulator is a few lines:

```luau
local INPUT_COST = Jev.INPUT_COST_PER_TOKEN
local sessionCost = 0

local function account(result)
    sessionCost += result.usage.input_tokens * INPUT_COST
    return sessionCost
end
```

Report `result.model` alongside your metrics. An alias moving under you is
exactly the kind of change that otherwise shows up as unexplained accuracy
drift weeks later.

---

## 16. Patterns

### 16.1 Speculative fan-out: one request, many questions

Because all questions in a request are evaluated in parallel against the same
state, adding questions barely changes latency and costs only the extra
question tokens. TypeSafe reports 13 questions in one call as roughly 12x
cheaper and 10x faster than 13 calls with no change in the answers.

Ask everything you might need — including questions that only matter for some
inputs — and let your Luau decide what to use.

```luau
local function triage(player, message)
    local state = {
        message = message,
        display_name = player.DisplayName,
        account_age_days = player.AccountAge,
    }

    local ok, result = client
        :Choice("category", "Determine the broad category of this message", {
            bug_report = "Something is broken or producing errors",
            billing = "Charges, invoices, refunds, subscriptions",
            feature_request = "Requesting new functionality",
            exploit_attempt = "Using or requesting cheats",
        })
        :Score("severity", "How severe is the reported issue", {
            "Cosmetic; no impact on functionality",
            "Degraded; a workaround exists",
            "Blocking; no workaround exists",
        })
        :Noul("reproducible", "Does the message describe specific steps to reproduce the issue")
        :Noul("pays", "Does the message mention money, Robux, or a purchase")
        :Send(state)

    if not ok then
        return
    end

    local category = result.answers.category
    local severity = result.answers.severity

    if category.choice == "exploit_attempt" then
        return kickForExploit(player, result)
    end

    if category.choice == "bug_report" then
        if severity.score > 1.5 and result.answers.reproducible.noul > 0.6 then
            escalateToEngineering(player, severity.score)
        else
            addToBacklog(player)
        end
    elseif category.choice == "billing" then
        if result.answers.pays.noul > 0.7 then
            routeToBilling(player, { priority = true })
        else
            routeToBilling(player)
        end
    elseif category.choice == "feature_request" then
        logFeatureRequest(player)
    end
end
```

One request, five answers, one full decision tree. The severity and
reproducibility answers are ignored when the ticket turns out to be a feature
request — that is the point.

### 16.2 Batch per chat window, not per message

The natural instinct is to evaluate each message as it arrives. The 500/minute
Roblox cap makes that untenable and the cost is 20x worse. Buffer instead:

```luau
local BATCH_SIZE = 20
local FLUSH_AFTER = 5 -- seconds

local pending = {}

local function queue(player, message)
    table.insert(pending, {
        player = player,
        message = message,
        sent_at = os.clock(),
    })

    if #pending >= BATCH_SIZE then
        task.spawn(flush)
    end
end

local flushing = false

local function flush()
    if flushing or #pending == 0 then
        return
    end
    flushing = true

    local batch = pending
    pending = {}

    local messages = {}
    for index, entry in ipairs(batch) do
        messages[index] = {
            display_name = entry.player.DisplayName,
            text = entry.message,
        }
    end

    local ok, result = client
        :Choice("category", "Which of these messages, if any, describes a problem with the game?", CATEGORIES)
        :Score("tone", "How hostile is the most hostile message in this batch?", TONE_LEVELS)
        :Send({ messages = messages })

    flushing = false

    if not ok then
        -- Fall back to a static filter for this batch, do not lose it.
        for _, entry in ipairs(batch) do
            staticFilter(entry)
        end
        return
    end

    local category = result.answers.category
    if category.choice == "exploit_attempt" then
        for _, entry in ipairs(batch) do
            entry.player:Kick("Attempting to exploit the game is not allowed.")
        end
    end
end
```

With 20 messages per request, a 60-player server at one message per 30 seconds
uses about 6 requests per minute instead of 120. Note that batching a Choice
over a batch changes the question: "which message is a problem" is not the same
question as "which category is this message", and a batched Score answers about
the *worst* message, not each one. Batch deliberately, and say so in the
`instructions` — the model reads them literally.

### 16.3 Confidence-gated escalating cost

Do not spend an expensive call on an input a cheap one can route.

```luau
local ok, result = client
    :Noul("needs_full_review", "Does this report allege wrongdoing by another player")
    :Send(state)

if not ok or result.answers.needs_full_review.noul < 0.5 then
    return -- cheap path: static rules handle this one
end

-- only now do we assemble the richer state and pay for the bigger call
local ok2, detailed = client
    :Choice("violation_type", "What kind of wrongdoing is alleged?", VIOLATION_TYPES)
    :Score("confidence_in_taking", "How confident is the reporter?", SEVERITY)
    :Send(enrichedState)
```

### 16.4 Composite scoring

A judgment that depends on several factors becomes one question per factor,
combined in your own Luau with weights you control.

```luau
-- Send severity, frustration, and reproducibility as Scores.
local WEIGHTS = { severity = 0.5, frustration = 0.3, reproducibility = 0.2 }
local LEVELS = 3 -- highest level index, for normalizing into 0..1

local function priority(result)
    local total = 0
    for id, weight in WEIGHTS do
        local answer = result.answers[id]
        total += (answer.score / (LEVELS - 1)) * weight
    end
    return total -- 0..1
end

local ok, result = client
    :Score("severity", "How severe is the reported issue?", SEVERITY_LEVELS)
    :Score("frustration", "How frustrated does the reporter appear?", FRUSTRATION_LEVELS)
    :Score("reproducibility", "How much does the report tell an engineer about the fault?", REPRO_LEVELS)
    :Send(state)

if ok and priority(result) > 0.6 then
    escalate(player)
end
```

When the composite result disagrees with what your team would decide, change a
weight in Luau. Do not rewrite the instructions. That is the whole point of
keeping the decision in code.

### 16.5 When two requests are genuinely needed

Usually one request is enough. A second call is warranted only when your code
cannot build the second request until it has the first answer — because the
answer determines what the state *contains*, not because the questions are
related.

Genuinely dependent: fetch the full text of the top-ranked candidate, then
re-judge against the better evidence. Chain the answer into a second `Send`:

```luau
local first = client:Choice("best", "Which passage is most relevant to the query?", rankedIds)
if not first then
    return
end

local full = fetchFullText(first.result.answers.best.choice)

local second = client
    :Noul("actually_answers", "Does the document state an answer to the query?", {
        true = "The document explicitly states the answer",
        false = "The document does not state it",
    })
    :Send({ query = query, document = full })
```

Not a reason for two calls: "question B would be more accurate if it knew
answer A." Both questions see the same state either way, and answers are
independent by design. Put both in one request.

### 16.6 Bounded extraction as a Choice

When the answer space is closed, enumerate it and let the model select rather
than asking it to produce free text.

```luau
-- Instead of: "What is the ban reason in this log?" (generation)
client:Choice("reason", "Which of these best describes why the player was banned?", {
    cheating = "Used an exploit or macro",
    exploiting = "Exploited a bug for advantage",
    ban_evasion = "Evaded a previous ban",
    inappropriate_text = "Inappropriate text or names",
    other = Jev.Null,
})
```

You get a typed label, a full distribution, and a confidence — instead of a
string you have to validate.

---

## 17. What Jev is bad at

`jev-1.13` is calibrated and fast, and it is not a general-purpose model. These
are documented failure modes, and several of them are traps a Roblox developer
walks straight into.

**Never ask it to count.** It does not reliably count characters, occurrences,
or list items, and error grows with list length. Count in Luau. If you need
"how many of these items match X", loop in Luau and ask one question per item.

**Never do arithmetic or numeric comparison.** It is not a calculator. Compute
in Luau and pass in a named bucket or a computed value. In particular, do not
interpolate a `score` back into a quantity: score levels are weakly calibrated
numerically and cannot reconstruct an exact number between two levels.

**Never compare dates as ordered values.** It reads dates as text. Extract
components with a Choice over enumerated options (including an explicit
"not stated"), then assemble and compare the date in Luau.

**Avoid indirection.** Questions about a property of a property, or with double
negatives, cost accuracy. Point at the state by name instead.

**Filter before you send.** Accuracy falls as `state` grows with content
unrelated to the decision. Unrelated detail is a distractor. Retrieve and
filter in Luau, send only the fields the question needs.

**It reads literally.** Scoping words and implied conditions are taken at face
value. If you find yourself explaining a wrong answer with "I meant...", that
explanation is the missing half of the instruction. Put it in.

**It does not distrust adversarial content.** A `state` containing injected
instructions or text arguing for its own classification can move the answer.
This matters in a game, where player-authored chat *is* the input. Never use a
Jev answer as the sole gate on a destructive action; layer a deterministic check
on top, and test your prompt against hand-written adversarial strings.

**Do not rely on invariants across questions.** A Noul and a yes/no Choice of
the same question do not return corresponding numbers. `P(noul)` and
`1 - P(negated noul)` do not sum to 1. Treat each question as its own
measurement.

**It cannot generate text.** Use it to select among options you define, not to
produce prose.

**English first.** Other languages, including CJK, work but with lower accuracy.
Watch confidence closely if your players are not writing English.

---

## 18. Testing in Studio

The secrets store is deliberately unavailable in local playtesting, which is
what trips up most first attempts.

| Test mode | Secrets | `GetSecret` result | Use for |
| --- | --- | --- | --- |
| **Local playtesting** (Play / Run) | Local Secrets only | works if a Local Secret with the same name exists | iterating on prompts |
| **Collaborative testing** (2+ players, Test tab) | real secrets | works | realistic multiplayer behaviour |
| **Published / live server** | real secrets | works | the only true test |

```luau
-- works in local playtesting, provided you created Local Secret "typesafe_api_key"
local client = Jev.new(HttpService:GetSecret("typesafe_api_key"))
```

If `GetSecret` throws `Can't find secret with given key`, you are in one of
three situations: local playtesting with no Local Secret, a client script, or a
secret that does not exist for this experience.

A fast iteration loop, using a hardcoded key so you can run local Play:

```luau
local IS_STUDIO = RunService:IsStudio()

local client
if IS_STUDIO then
    client = Jev.new("sk-dev-key-not-published")
else
    client = Jev.new(HttpService:GetSecret("typesafe_api_key"))
end
```

Guard the branch so the literal key never reaches a published build. Better
still, read a flag so it cannot ship by accident:

```luau
local USE_DEV_KEY = IS_STUDIO and not RunService:IsRunning()
```

Also remember **Allow HTTP Requests** must be on in
`File ⟩ Experience Settings ⟩ Security`, and that Studio writes to the output
window with a throttle — rapid-fire tests will look like they silently did
nothing.

Use the [TypeSafe Playground](https://console.typesafe.ai/playground) to iterate
on prompts without spending requests. Paste the same state and question, and
compare the answer to what your code will do with it.

---

## 19. API reference

### Module

| Symbol | Description |
| --- | --- |
| `Jev.new(key)` | Creates a client. `key` is a `Secret` or a string. |
| `Jev.Noul(id, instructions, criteria?)` | Builds a Noul question table. |
| `Jev.Choice(id, instructions, criteria)` | Builds a Choice question table. |
| `Jev.Score(id, instructions, levels)` | Builds a Score question table. |
| `Jev.Route(answer, autoThreshold?, reviewThreshold?)` | Confidence band: `"act"`, `"confirm"`, `"review"`. |
| `Jev.INPUT_COST_PER_TOKEN` | `0.042 / 1_000_000` USD. |
| `Jev.Null` | Sentinel that serialises to JSON `null`. |
| `Jev.QuestionTypes` | `{ Noul = "noul", Choice = "choice", Score = "score" }`. |

### Client

| Method | Returns | Description |
| --- | --- | --- |
| `:Noul(id, instructions, criteria?)` | `Client` | Adds a Noul question. |
| `:Choice(id, instructions, criteria)` | `Client` | Adds a Choice question. |
| `:Score(id, instructions, levels)` | `Client` | Adds a Score question. |
| `:Model(name)` | `Client` | Sets the model. Default `"jev-latest"`. |
| `:Timeout(seconds)` | `Client` | Total budget per `Send`. Default `30`. |
| `:MaxRetries(n)` | `Client` | Retries after the first attempt. Default `2`. |
| `:Retry(overrides)` | `Client` | Sets retry knobs together. |
| `:Header(name, value)` | `Client` | Adds a header; name is lower-cased. |
| `:Send(state, overrides?)` | `ok, result` | Sends. Yields. Never errors. |
| `:models()` | `ok, list` | `GET /v1/models`. Yields. Never errors. |

All question and configuration methods are copy-on-write and return a new
client.

### Result

| Field | Type | Description |
| --- | --- | --- |
| `model` | `string` | Versioned model ID that answered, e.g. `"jev-1.13.0"`. |
| `answers` | `{ [string]: Answer }` | One answer per question id. |
| `usage.input_tokens` | `number` | Billed tokens. |
| `usage.output_tokens` | `number` | Free, reported for visibility. |
| `usage.input_cost` | `number` | Estimated USD. |
| `attempts` | `number` | HTTP attempts made, including retries. |
| `latency` | `number` | Seconds, end to end. |

### Answer

| Type | Fields |
| --- | --- |
| `noul` | `type`, `noul` |
| `choice` | `type`, `choice`, `probabilities`, `confidence` |
| `score` | `type`, `score`, `legend`, `probabilities`, `confidence` |

### Error

| Field | Type | Description |
| --- | --- | --- |
| `kind` | `string` | See [§11.2](#112-the-error-table). |
| `message` | `string` | Safe to log. |
| `status` | `number?` | HTTP status, `nil` if no response. |
| `field` | `string?` | Offending field, on a `422`. |
| `retryable` | `boolean` | Whether a retry could help. |
| `attempts` | `number` | Attempts made. |
| `cause` | `string?` | Raw status message or transport error. |

---

## 20. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Can't find secret with given key` | local Play with no Local Secret, or a client script | Add a Local Secret for Studio; run in collaborative testing; move the call server-side |
| `config: HTTP requests are not enabled` | Studio setting off | `File ⟩ Experience Settings ⟩ Security ⟩ Allow HTTP Requests` |
| `NetworkError: ... HttpEnabled` | same, hit at request time instead of construct time | same |
| `Number of HTTP requests exceeded limit` | over 500 requests/min on this server | Batch ([§16.2](#162-batch-per-chat-window-not-per-message)); check for a per-frame call |
| Requests stall ~30 s then fail | same cap, hit mid-flight | same |
| `auth: 401` | key missing, wrong, or not loaded | Check the secret name matches `GetSecret`; confirm the key is active in the dashboard |
| `validation: 422` with a `field` | API rejected the body | `field` names the problem — usually a Choice over 255 options or a Score with fewer than 2 levels |
| `decode: malformed response` | proxy or interception returning HTML | Check for a network-level filter; log `result.cause` |
| `rate_limited: 429` | TypeSafe per-key cap, or the Roblox cap | Let the module back off; send fewer requests; consider `maxRetries = 0` with a static fallback |
| `overloaded: 529` | TypeSafe busy | Already retried; fall back to a deterministic path |
| Answers are consistently wrong | prompt is ambiguous or literal | Put the exact condition in `instructions`; add criteria; see [§17](#17-what-jev-is-bad-at) |
| Right answer, low confidence | state lacks the needed context | Filter/extend the state, or add a `criteria` description |
| Wrong answer, high confidence | an `other` option is missing, so the model had no honest exit | Add `other` / `none of the above` with `Jev.Null` |
| Quality dropped after a while | `jev-latest` moved | Log `result.model`; pin `:Model("jev-1.13.0")` and move deliberately |
| Nothing logged in Studio | output throttling | Slow the loop; use `print` sparingly |
| `score` is not an integer | it is a weighted position between levels | expected; threshold on it rather than switching on it |

---

## 21. Security checklist

- [ ] The API key is in the **secrets store**, not in a script, and its domain
      is scoped to `api.typesafe.ai`.
- [ ] The key is never read from a `LocalScript`. `GetSecret` cannot return a
      secret to a client, so keep it that way.
- [ ] No `print`, `warn`, `tostring`, or table serialization ever touches the
      key or the client object. `HttpService:JSONEncode(client)` is not a thing
      you should be doing.
- [ ] `Allow HTTP Requests` is enabled **only where needed**. A published game
      that does not call this module does not need it.
- [ ] The key is scoped to the minimum it needs, and rotated if it was ever in a
      script, a DataStore, or a screenshot.
- [ ] `state` contains nothing your privacy policy does not cover, because
      everything in it is transmitted to a third party and billed.
- [ ] Destructive actions are not gated on a Jev answer alone. Player-authored
      text is untrusted input, and the model does not treat it as hostile.
- [ ] `:Send` is not called from a yielding-sensitive thread without
      `task.spawn`.
- [ ] Cost is monitored. 1,200 requests/minute per key is enough to run up a
      bill quickly if a loop is wrong.

---

## 22. Limits cheat sheet

**Roblox**

| Limit | Value |
| --- | --- |
| Non-Open-Cloud HTTP requests | 500 / minute / game server |
| Open Cloud HTTP requests | 2,500 / minute / game server |
| Over-cap behaviour | ~30 s stall, `pcall` may throw |
| Secrets available | live servers and collaborative testing only |
| Secrets per game | 500, up to 1,024 characters each |
| Secret placement | URL or headers only, never a body |
| HTTP requests enabled | off by default; Studio setting |

**TypeSafe / Jev 1.13**

| Limit | Value |
| --- | --- |
| Endpoint | `POST https://api.typesafe.ai/v1/systemone` |
| Models | `GET https://api.typesafe.ai/v1/models` |
| Auth | `Authorization: Bearer <key>` |
| Default model | `jev-latest` (currently `jev-1.13.0`) |
| Context | 64k tokens total; 32k for state + longest question |
| Choice options | 255 max |
| Score levels | 2 to 10 |
| Requests | 1,200 / minute per key |
| Throughput | 250,000 tokens / second per key |
| Price | $42 / Btok input ($0.042 / Mtok); output free |
| Input | text only — string, object, or array of text values |
| Languages | English best; others lower accuracy |
| Retriable statuses | `408`, `429`, `5xx`, `529` |
| Error statuses | `401`, `403`, `422`, `429`, `529` |

**Rates are subject to change.** TypeSafe states their limits are being adjusted
dynamically and can change without notice. Read `client:models()` and treat the
table above as a starting point, not a contract. Higher limits are available on
custom and enterprise plans.

---

## 23. Sources

Everything in this document is derived from the pages below, fetched
**2026-09-30**. TypeSafe publishes a machine-readable index at
`https://docs.typesafe.ai/llms.txt` and every page has an `.md` variant, so the
cleanest way to re-read one is to append `.md` to the URL.

**Normative — the module must match these exactly**

| Source | What it fixes |
| --- | --- |
| [api](https://docs.typesafe.ai/api.md) | Request/response schema, question and answer shapes, `422` field reporting, error statuses |
| [models](https://docs.typesafe.ai/models.md) | Model IDs and aliases, context budgets, rate limits, price, `GET /v1/models` response shape |
| [primitives](https://docs.typesafe.ai/primitives.md) | Noul / Choice / Score semantics, id rules, referencing state by backticked path |
| [primitives/advanced](https://docs.typesafe.ai/primitives/advanced.md) | Structured `instructions` and criteria |
| [confidence](https://docs.typesafe.ai/confidence.md) | What `confidence` means, the three-band routing pattern behind `Jev.Route` |
| [state](https://docs.typesafe.ai/concepts/state.md) | Accepted state shapes |
| [patterns/fan-out](https://docs.typesafe.ai/patterns/fan-out.md) | Why one request with many questions is the default ([§16.1](#161-speculative-fan-out-one-request-many-questions)) |
| [model-jaggedness/jev-1.13](https://docs.typesafe.ai/model-jaggedness/jev-1.13.md) | The whole of [§17](#17-what-jev-is-bad-at) |
| [sdk/python retries](https://docs.typesafe.ai/sdk/python/api/retries.md) | Retry defaults reproduced in [§11.4](#114-retry-defaults) |
| [create.roblox.com: HTTP](https://create.roblox.com/docs/cloud-services/http-service) | `RequestAsync` semantics, 500/min cap, HTTP/2 lower-case headers, yielding |
| [create.roblox.com: secrets](https://create.roblox.com/docs/cloud-services/secrets) | `GetSecret` availability, `Secret` datatype, Local Secrets, URL/headers only |
| [create.roblox.com: HttpService:RequestAsync](https://create.roblox.com/docs/reference/engine/classes/HttpService/RequestAsync) | Exact response table fields |

**Inferred — our design choices, not TypeSafe's, and safe to change**

- the `ok, err` tuple convention and the `kind` names in [§11.2](#112-the-error-table)
- the copy-on-write client rule in [§6.1](#61-every-method-returns-a-new-client)
- `Jev.Null`, `Jev.Route`, `latency`, `attempts`, `result.usage.input_cost`
- the `kind = "config"` preflight on `HttpEnabled`
- the batching and escalation recipes in [§16](#16-patterns)

**Not a source of truth:** `typesafe.io` is now a different company (QueryGraph)
and unrelated to the API. Use `docs.typesafe.ai`.

Handy: the [Playground](https://console.typesafe.ai/playground) for iterating on
prompts, and [console.typesafe.ai/keys](https://console.typesafe.ai/keys) to
mint a key. There is no official Roblox SDK, which is why this module exists;
`@typesafe-ai/sdk` and `typesafe-sdk` (Python) are the reference implementations
the surface here mirrors.
