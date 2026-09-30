--!strict

-- Endpoints, pricing, hard limits, and default configuration. Anything a
-- caller might reasonably want to read off `Jev` is defined here once.

local Types = require(script.Parent.types)

local C = {}

C.ENDPOINT = "https://api.typesafe.ai/v1/systemone"
C.MODELS_ENDPOINT = "https://api.typesafe.ai/v1/models"
C.INPUT_COST_PER_TOKEN = 0.042 / 1_000_000

C.MAX_CHOICE_OPTIONS = 255
C.MIN_SCORE_LEVELS = 2
C.MAX_SCORE_LEVELS = 10
C.PATH_CHARACTERS = "[%[%].]"

local DEFAULTS: Types.Defaults = {
	model = "jev-latest",
	timeout = 30,
	maxRetries = 2,
	backoffInitial = 0.5,
	backoffMax = 5.0,
	jitter = 0.25,
	autoThreshold = 0.9,
	reviewThreshold = 0.6,
}
C.DEFAULTS = DEFAULTS

-- Indexed by every `ErrorKind`, so `C.RETRYABLE_KINDS[kind]` is total.
local RETRYABLE_KINDS: { [Types.ErrorKind]: boolean } = {
	rate_limited = true,
	overloaded = true,
	server = true,
	network = true,
	timeout = true,
}
C.RETRYABLE_KINDS = RETRYABLE_KINDS

local QuestionTypes: Types.QuestionTypes = {
	Noul = "noul",
	Choice = "choice",
	Score = "score",
}
C.QuestionTypes = QuestionTypes

--- Sentinel that serialises to JSON `null`. Identity-compared, so it must be
--- required rather than rebuilt.
C.Null = setmetatable({}, {
	__tostring = function()
		return "Jev.Null"
	end,
	__metatable = "locked",
})

return C
