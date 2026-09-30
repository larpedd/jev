--!strict

-- Native Luau type definitions for the whole package. This module has no
-- runtime behaviour; it exists so every other module can refer to the same
-- types without redefining them.
--
-- Every type is `export type`, so sibling modules reach them through their
-- require alias: `local Types = require(script.Parent.types)` then
-- `Types.Question`. `init` re-exports the public ones as `Jev.*`.

export type Instructions = string | { [any]: any } | { any }

export type Criteria = { [any]: any }

export type QuestionType = "noul" | "choice" | "score"

export type QuestionTypes = {
	Noul: "noul",
	Choice: "choice",
	Score: "score",
}

export type Question = {
	id: string,
	type: QuestionType,
	instructions: Instructions,
	criteria: Criteria?,
}

export type Answer = {
	type: string,
	noul: number?,
	choice: string?,
	score: number?,
	confidence: number?,
	probabilities: { [any]: number }?,
	legend: { [number]: string }?,
}

export type Usage = {
	input_tokens: number,
	output_tokens: number,
	input_cost: number,
}

export type Result = {
	model: string,
	answers: { [string]: Answer },
	usage: Usage,
	attempts: number,
	latency: number,
}

export type ErrorKind =
	"validation"
	| "config"
	| "auth"
	| "forbidden"
	| "notfound"
	| "rate_limited"
	| "overloaded"
	| "server"
	| "network"
	| "decode"
	| "timeout"

export type Error = {
	kind: ErrorKind,
	message: string,
	status: number?,
	field: string?,
	retryable: boolean,
	attempts: number,
	cause: string?,
}

export type ErrorOptions = {
	status: number?,
	field: string?,
	attempts: number?,
	cause: string?,
	retryable: boolean?,
}

export type ModelInfo = {
	name: string,
	description: string?,
	release_date: any?,
}

export type Retry = {
	backoffInitial: number,
	backoffMax: number,
	jitter: number,
}

export type RetryOverrides = {
	backoffInitial: number?,
	backoffMax: number?,
	jitter: number?,
	backoffJitter: number?,
}

export type Config = {
	model: string,
	timeout: number,
	maxRetries: number,
	retry: Retry,
}

export type SendOverrides = RetryOverrides & {
	timeout: number?,
	model: string?,
	maxRetries: number?,
}

export type Defaults = {
	model: string,
	timeout: number,
	maxRetries: number,
	backoffInitial: number,
	backoffMax: number,
	jitter: number,
	autoThreshold: number,
	reviewThreshold: number,
}

export type Headers = { [string]: string | Secret }

-- Mirrors the subset of Roblox's `HttpService:RequestAsync` request and
-- response tables this module relies on.
export type HttpRequest = {
	Url: string,
	Method: ("GET" | "HEAD" | "POST" | "PUT" | "DELETE" | "PATCH")?,
	Headers: Headers?,
	Body: string?,
}

export type HttpResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
	Body: string,
}

export type Route = "act" | "confirm" | "review"

-- The state a client carries. Copy-on-write methods clone this and hand back
-- a new `Client`, so a base client is a reusable template.
export type ClientData = {
	_key: string | Secret | nil,
	_model: string,
	_timeout: number,
	_maxRetries: number,
	_retry: Retry,
	_headers: Headers,
	_questions: { Question },
}

-- The methods reached through the metatable's `__index`. Declaring them as a
-- table of function types, rather than leaving them implicit behind
-- `setmetatable`, is what lets `client:Noul(...)` type-check at the call site.
export type ClientMethods = {
	Noul: (self: Client, id: string, instructions: Instructions, criteria: Criteria?) -> Client,
	Choice: (self: Client, id: string, instructions: Instructions, criteria: Criteria) -> Client,
	Score: (self: Client, id: string, instructions: Instructions, levels: Criteria) -> Client,
	Model: (self: Client, name: string) -> Client,
	Timeout: (self: Client, seconds: number) -> Client,
	MaxRetries: (self: Client, count: number) -> Client,
	Retry: (self: Client, overrides: RetryOverrides) -> Client,
	Header: (self: Client, name: string, value: string) -> Client,
	Send: (self: Client, state: any, overrides: SendOverrides?) -> (boolean, Result | Error),
	models: (self: Client) -> (boolean, { ModelInfo } | Error),
}

export type Client = ClientData & ClientMethods

return {}
