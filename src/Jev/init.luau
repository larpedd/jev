--!strict

-- Jev: a Luau client for TypeSafe's System One API.
--
-- This file is only the public surface. The work is split across:
--
--   types.luau      the Jev.* type definitions
--   constants.luau  endpoints, pricing, limits, defaults, Jev.Null
--   util.luau       shared predicates and string helpers
--   errors.luau     Jev.Error construction
--   json.luau       request body encoding
--   questions.luau  the noul / choice / score builders
--   validation.luau local checks that run before a request is spent
--   transport.luau  headers, preflight, retry loop, error body parsing
--   decode.luau     response -> Jev.Result and the model list
--   routing.luau    Jev.Route
--   client.luau     the copy-on-write client and its methods

local Types = require(script.types)

local C = require(script.constants)
local Client = require(script.client)
local Questions = require(script.questions)
local Routing = require(script.routing)

-- The types a caller needs are re-exported here, so `local Jev = require(.)`
-- is enough to annotate against them without reaching into `types.luau`.
export type Client = Types.Client
export type Question = Types.Question
export type Instructions = Types.Instructions
export type Criteria = Types.Criteria
export type Answer = Types.Answer
export type Usage = Types.Usage
export type Result = Types.Result
export type Error = Types.Error
export type ErrorKind = Types.ErrorKind
export type ModelInfo = Types.ModelInfo
export type Route = Types.Route
export type RetryOverrides = Types.RetryOverrides
export type SendOverrides = Types.SendOverrides
export type Defaults = Types.Defaults
export type QuestionTypes = Types.QuestionTypes

export type Module = {
	new: (key: string | Secret | nil) -> Types.Client,
	Noul: (id: string, instructions: Types.Instructions, criteria: Types.Criteria?) -> Types.Question,
	Choice: (id: string, instructions: Types.Instructions, criteria: Types.Criteria) -> Types.Question,
	Score: (id: string, instructions: Types.Instructions, levels: Types.Criteria) -> Types.Question,
	Route: (answer: Types.Answer?, autoThreshold: number?, reviewThreshold: number?) -> Types.Route,
	Null: unknown,
	QuestionTypes: Types.QuestionTypes,
	INPUT_COST_PER_TOKEN: number,
	ENDPOINT: string,
	MODELS_ENDPOINT: string,
	Defaults: Types.Defaults,
}


local Jev: Module = {
	Null = C.Null,
	QuestionTypes = C.QuestionTypes,
	INPUT_COST_PER_TOKEN = C.INPUT_COST_PER_TOKEN,
	ENDPOINT = C.ENDPOINT,
	MODELS_ENDPOINT = C.MODELS_ENDPOINT,
	Defaults = table.clone(C.DEFAULTS),

	Noul = Questions.buildNoul,
	Choice = Questions.buildChoice,
	Score = Questions.buildScore,

	Route = Routing.route,

	new = Client.new,
}

return Jev
