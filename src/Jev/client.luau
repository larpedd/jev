--!strict

-- The copy-on-write client. Every method returns a new client, so a base
-- client is a reusable template and two threads deriving from it cannot
-- interfere. `Send` and `models` are the only methods that talk to the network.

local C = require(script.Parent.constants)
local Decode = require(script.Parent.decode)
local Json = require(script.Parent.json)
local Questions = require(script.Parent.questions)
local Transport = require(script.Parent.transport)
local Types = require(script.Parent.types)
local Util = require(script.Parent.util)
local Validation = require(script.Parent.validation)

export type Client = Types.Client

local isNonEmptyString = Util.isNonEmptyString

local ClientMethods = {} :: Types.ClientMethods

local CLIENT_METATABLE: {
	__index: Types.ClientMethods,
	__metatable: string,
	__tostring: (self: Types.Client) -> string,
} = {
	__index = ClientMethods,
	__metatable = "locked",
	__tostring = function(self: Types.Client): string
		return ("Jev.Client(model=%s, questions=%d)"):format(self._model, #self._questions)
	end,
}

-- `setmetatable` hands the instance its methods through `__index`, which the
-- type system cannot see, so the result is widened before being handed back
-- as a `Client`.
local function instantiate(data: Types.ClientData): Types.Client
	local built: any = setmetatable(data, CLIENT_METATABLE)
	return built :: Types.Client
end

local function derive(client: Types.Client): Types.Client
	local fresh: Types.ClientData = {
		_key = client._key,
		_model = client._model,
		_timeout = client._timeout,
		_maxRetries = client._maxRetries,
		_retry = {
			backoffInitial = client._retry.backoffInitial,
			backoffMax = client._retry.backoffMax,
			jitter = client._retry.jitter,
		},
		_headers = table.clone(client._headers),
		_questions = table.clone(client._questions),
	}
	return instantiate(fresh)
end

local function withQuestion(client: Types.Client, question: Types.Question): Types.Client
	local derived = derive(client)
	table.insert(derived._questions, question)
	return derived
end

function ClientMethods:Noul(id: string, instructions: Types.Instructions, criteria: Types.Criteria?): Types.Client
	return withQuestion(self, Questions.buildNoul(id, instructions, criteria))
end

function ClientMethods:Choice(id: string, instructions: Types.Instructions, criteria: Types.Criteria): Types.Client
	return withQuestion(self, Questions.buildChoice(id, instructions, criteria))
end

function ClientMethods:Score(id: string, instructions: Types.Instructions, levels: Types.Criteria): Types.Client
	return withQuestion(self, Questions.buildScore(id, instructions, levels))
end

function ClientMethods:Model(name: string): Types.Client
	local derived = derive(self)
	derived._model = name
	return derived
end

function ClientMethods:Timeout(seconds: number): Types.Client
	local derived = derive(self)
	derived._timeout = seconds
	return derived
end

function ClientMethods:MaxRetries(count: number): Types.Client
	local derived = derive(self)
	derived._maxRetries = count
	return derived
end

function ClientMethods:Retry(overrides: Types.RetryOverrides): Types.Client
	local derived = derive(self)
	-- `type` guards rather than `~= nil`: the type says number?, but a wrong
	-- value here must be ignored, never reach an arithmetic comparison.
	local backoffInitial = overrides.backoffInitial
	local backoffMax = overrides.backoffMax
	local jitter = overrides.jitter
	local backoffJitter = overrides.backoffJitter

	if type(backoffInitial) == "number" then
		derived._retry.backoffInitial = backoffInitial
	end
	if type(backoffMax) == "number" then
		derived._retry.backoffMax = backoffMax
	end
	if type(jitter) == "number" then
		derived._retry.jitter = jitter
	elseif type(backoffJitter) == "number" then
		derived._retry.jitter = backoffJitter
	end
	return derived
end

function ClientMethods:Header(name: string, value: string): Types.Client
	if not isNonEmptyString(name) or not isNonEmptyString(value) then
		return derive(self)
	end
	local derived = derive(self)
	derived._headers[name:lower()] = value
	return derived
end

function ClientMethods:Send(state: any, overrides: Types.SendOverrides?): (boolean, Types.Result | Types.Error)
	local startedAt = os.clock()

	local config, configError = Transport.resolveConfig(self, overrides)
	if config == nil then
		return false, configError :: Types.Error
	end

	local stateError = Validation.validateState(state)
	if stateError then
		return false, stateError
	end

	local questionsError = Validation.validateQuestions(self._questions)
	if questionsError then
		return false, questionsError
	end

	local environmentError = Transport.preflight(self)
	if environmentError then
		return false, environmentError
	end

	local body: {
		state: any,
		model: string,
		questions: { [string]: Questions.WireQuestion },
	} = {
		state = state,
		model = config.model,
		questions = Questions.buildQuestionMap(self._questions),
	}

	local encoded, encodeError = Json.encodeBody(body)
	if encoded == nil then
		return false, encodeError :: Types.Error
	end

	local request: Types.HttpRequest = {
		Url = C.ENDPOINT,
		Method = "POST",
		Headers = Transport.buildHeaders(self, true),
		Body = encoded,
	}

	local ok, payload, attempts = Transport.performRequest(request, config, startedAt)
	if not ok then
		return false, payload :: Types.Error
	end

	local result, resultError = Decode.buildResult(payload, self._questions, config.model, attempts, startedAt)
	if result == nil then
		return false, resultError :: Types.Error
	end
	return true, result
end

function ClientMethods:models(): (boolean, { Types.ModelInfo } | Types.Error)
	local startedAt = os.clock()

	local config, configError = Transport.resolveConfig(self, nil)
	if config == nil then
		return false, configError :: Types.Error
	end

	local environmentError = Transport.preflight(self)
	if environmentError then
		return false, environmentError
	end

	local request: Types.HttpRequest = {
		Url = C.MODELS_ENDPOINT,
		Method = "GET",
		Headers = Transport.buildHeaders(self, false),
	}

	local ok, payload = Transport.performRequest(request, config, startedAt)
	if not ok then
		return false, payload :: Types.Error
	end

	local models, modelsError = Decode.buildModelList(payload)
	if models == nil then
		return false, modelsError :: Types.Error
	end
	return true, models
end

local function newClient(key: string | Secret | nil): Types.Client
	local fresh: Types.ClientData = {
		_key = key,
		_model = C.DEFAULTS.model,
		_timeout = C.DEFAULTS.timeout,
		_maxRetries = C.DEFAULTS.maxRetries,
		_retry = {
			backoffInitial = C.DEFAULTS.backoffInitial,
			backoffMax = C.DEFAULTS.backoffMax,
			jitter = C.DEFAULTS.jitter,
		},
		_headers = {},
		_questions = {},
	}
	return instantiate(fresh)
end

return {
	new = newClient,
}
