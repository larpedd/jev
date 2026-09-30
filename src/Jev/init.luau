--!strict

local HttpService = game:GetService("HttpService")

---@alias Jev.Instructions string | { [any]: any } | { any }
---@alias Jev.Criteria { [any]: any }

---@class Jev.Question
---@field id string
---@field type "noul" | "choice" | "score"
---@field instructions Jev.Instructions
---@field criteria Jev.Criteria?

---@class Jev.Answer
---@field type string
---@field noul number?
---@field choice string?
---@field score number?
---@field confidence number?
---@field probabilities { [any]: number }?
---@field legend { [number]: string }?

---@class Jev.Usage
---@field input_tokens number
---@field output_tokens number
---@field input_cost number

---@class Jev.Result
---@field model string
---@field answers { [string]: Jev.Answer }
---@field usage Jev.Usage
---@field attempts number
---@field latency number

---@class Jev.Error
---@field kind string
---@field message string
---@field status number?
---@field field string?
---@field retryable boolean
---@field attempts number
---@field cause string?

---@class Jev.ModelInfo
---@field name string
---@field description string?
---@field release_date any?

---@class Jev.Retry
---@field backoffInitial number
---@field backoffMax number
---@field jitter number

---@class Jev.Config
---@field model string
---@field timeout number
---@field maxRetries number
---@field retry Jev.Retry

---@class Jev.SendOverrides
---@field timeout number?
---@field model string?
---@field maxRetries number?
---@field backoffInitial number?
---@field backoffMax number?
---@field jitter number?
---@field backoffJitter number?

---@class Jev.Client
---@field _key string | Secret | nil
---@field _model string
---@field _timeout number
---@field _maxRetries number
---@field _retry Jev.Retry
---@field _headers { [string]: string }
---@field _questions { Jev.Question }

local ENDPOINT = "https://api.typesafe.ai/v1/systemone"
local MODELS_ENDPOINT = "https://api.typesafe.ai/v1/models"
local INPUT_COST_PER_TOKEN = 0.042 / 1_000_000

local MAX_CHOICE_OPTIONS = 255
local MIN_SCORE_LEVELS = 2
local MAX_SCORE_LEVELS = 10
local PATH_CHARACTERS = "[%[%].]"

local DEFAULTS = {
	model = "jev-latest",
	timeout = 30,
	maxRetries = 2,
	backoffInitial = 0.5,
	backoffMax = 5.0,
	jitter = 0.25,
	autoThreshold = 0.9,
	reviewThreshold = 0.6,
}

local RETRYABLE_KINDS: { [string]: boolean } = {
	rate_limited = true,
	overloaded = true,
	server = true,
	network = true,
	timeout = true,
}

local QuestionTypes = {
	Noul = "noul",
	Choice = "choice",
	Score = "score",
}

local MONTHS: { [string]: number } = {
	jan = 1,
	feb = 2,
	mar = 3,
	apr = 4,
	may = 5,
	jun = 6,
	jul = 7,
	aug = 8,
	sep = 9,
	oct = 10,
	nov = 11,
	dec = 12,
}

local NESTED_ERROR_KEYS = { "error", "detail", "data" }

local ERROR_MESSAGE_KEYS = { "message", "error", "detail", "description" }

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local Jev: any = {}

local NULL = setmetatable({}, {
	__tostring = function()
		return "Jev.Null"
	end,
	__metatable = "locked",
})

Jev.Null = NULL
Jev.QuestionTypes = QuestionTypes
Jev.INPUT_COST_PER_TOKEN = INPUT_COST_PER_TOKEN
Jev.ENDPOINT = ENDPOINT
Jev.MODELS_ENDPOINT = MODELS_ENDPOINT
Jev.Defaults = {
	model = DEFAULTS.model,
	timeout = DEFAULTS.timeout,
	maxRetries = DEFAULTS.maxRetries,
	backoffInitial = DEFAULTS.backoffInitial,
	backoffMax = DEFAULTS.backoffMax,
	jitter = DEFAULTS.jitter,
	autoThreshold = DEFAULTS.autoThreshold,
	reviewThreshold = DEFAULTS.reviewThreshold,
}

---@param kind string
---@param message string
---@param options { status: number?, field: string?, attempts: number?, cause: string?, retryable: boolean? }?
---@return Jev.Error
local function newError(kind: string, message: string, options: { status: number?, field: string?, attempts: number?, cause: string?, retryable: boolean? }?): Jev.Error
	local retryable: boolean
	if options ~= nil and options.retryable ~= nil then
		retryable = options.retryable
	else
		retryable = RETRYABLE_KINDS[kind] == true
	end

	return {
		kind = kind,
		message = message,
		status = if options then options.status else nil,
		field = if options then options.field else nil,
		retryable = retryable,
		attempts = if options then (options.attempts or 0) else 0,
		cause = if options then options.cause else nil,
	}
end

local function truncate(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	return text:sub(1, limit) .. "..."
end

local function isNonEmptyString(value: any): boolean
	return typeof(value) == "string" and #value > 0
end

local function escapeString(value: string): string
	local escaped = value:gsub('[%c"\\]', function(char: string): string
		return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
	end)
	return '"' .. escaped .. '"'
end

---@param value any
---@param seen { [any]: boolean }
---@param path string
---@return string?, string?
local function encodeValue(value: any, seen: { [any]: boolean }, path: string): (string?, string?)
	local valueType = typeof(value)

	if valueType == "nil" then
		return "null", nil
	elseif valueType == "string" then
		return escapeString(value), nil
	elseif valueType == "boolean" then
		return tostring(value), nil
	elseif valueType == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil, ("%s is not a finite number"):format(path)
		elseif value % 1 == 0 and math.abs(value) < 1e15 then
			return ("%d"):format(value), nil
		else
			return ("%.14g"):format(value), nil
		end
	elseif valueType ~= "table" then
		return nil, ("%s is a %s, which is not valid JSON"):format(path, valueType)
	end

	if value == NULL then
		return "null", nil
	end

	if seen[value] then
		return nil, ("%s is a circular reference"):format(path)
	end
	seen[value] = true

	local entryCount = 0
	for _ in value do
		entryCount += 1
	end

	local dense = entryCount > 0
	local index = 1
	while value[index] ~= nil do
		index += 1
	end
	if (index - 1) ~= entryCount then
		dense = false
	end

	local out
	if dense then
		local parts = table.create(entryCount)
		for position = 1, entryCount do
			local encoded, err = encodeValue(value[position], seen, ("%s[%d]"):format(path, position))
			if encoded == nil then
				seen[value] = nil
				return nil, err
			end
			parts[position] = encoded
		end
		out = "[" .. table.concat(parts, ",") .. "]"
	else
		local keys = table.create(entryCount)
		for key in value do
			local keyType = typeof(key)
			if keyType ~= "string" and keyType ~= "number" and keyType ~= "boolean" then
				seen[value] = nil
				return nil, ("%s has a key of type %s, which is not valid JSON"):format(path, keyType)
			end
			keys[#keys + 1] = key
		end
		table.sort(keys, function(a: any, b: any): boolean
			return tostring(a) < tostring(b)
		end)

		local parts = table.create(#keys)
		for position = 1, #keys do
			local key = keys[position]
			local encoded, err = encodeValue(value[key], seen, ("%s.%s"):format(path, tostring(key)))
			if encoded == nil then
				seen[value] = nil
				return nil, err
			end
			parts[position] = escapeString(tostring(key)) .. ":" .. encoded
		end
		out = "{" .. table.concat(parts, ",") .. "}"
	end

	seen[value] = nil
	return out, nil
end

---@param body any
---@return (string?, Jev.Error?)
local function encodeBody(body: any): (string?, Jev.Error?)
	local encoded, err = encodeValue(body, {}, "body")
	if encoded == nil then
		return nil, newError("validation", ("Request body cannot be encoded: %s"):format(err or "unknown reason"))
	end
	return encoded, nil
end

---@param values any
---@return number, boolean
local function arrayShape(values: any): (number, boolean)
	local count = 0
	local ordered = true
	for key in values do
		count += 1
		if typeof(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			ordered = false
		end
	end
	if #values ~= count then
		ordered = false
	end
	return count, ordered
end

---@param state any
---@return Jev.Error?
local function validateState(state: any): Jev.Error?
	local stateType = typeof(state)

	if stateType == "string" then
		if #state == 0 then
			return newError("validation", "`state` is an empty string; pass the text to judge")
		end
		return nil
	end

	if stateType == "table" then
		if state == NULL or next(state) == nil then
			return newError("validation", "`state` is empty; pass a string, an object, or an array of text values")
		end
		return nil
	end

	return newError("validation", ("`state` must be a string, an object, or an array, not %s"):format(stateType))
end

---@param instructions any
---@return Jev.Error?
local function validateInstructions(instructions: any): Jev.Error?
	local instructionsType = typeof(instructions)

	if instructionsType == "string" then
		if #instructions == 0 then
			return newError("validation", "`instructions` is an empty string; write the whole question out")
		end
		return nil
	end

	if instructionsType == "table" then
		if instructions == NULL or next(instructions) == nil then
			return newError("validation", "`instructions` is an empty table; write the whole question out")
		end
		return nil
	end

	return newError("validation", ("`instructions` must be a string, an object, or an array, not %s"):format(instructionsType))
end

---@param index number
---@param question Jev.Question
---@param seenIds { [string]: boolean }
---@return Jev.Error?
local function validateQuestion(index: number, question: Jev.Question, seenIds: { [string]: boolean }): Jev.Error?
	if not isNonEmptyString(question.id) then
		return newError("validation", ("Question #%d has a missing or non-string id"):format(index))
	end

	local id = question.id
	local label = ("Question %q"):format(id)

	if id:match("^%s*$") then
		return newError("validation", ("%s has an id made only of whitespace"):format(label))
	end
	if id:find(PATH_CHARACTERS) then
		return newError(
			"validation",
			("%s has an id containing '.', '[' or ']', which are used to build the answer path. Use snake_case"):format(label),
			{ field = "questions." .. id }
		)
	end
	if seenIds[id] then
		return newError(
			"validation",
			("Duplicate question id %q; ids must be unique within one client"):format(id),
			{ field = "questions." .. id }
		)
	end
	seenIds[id] = true

	local instructionsError = validateInstructions(question.instructions)
	if instructionsError then
		return newError("validation", ("%s: %s"):format(label, instructionsError.message), { field = "questions." .. id })
	end

	if question.type == QuestionTypes.Noul then
		local criteria = question.criteria
		if criteria == nil then
			return nil
		end
		if type(criteria) ~= "table" then
			return newError("validation", ("%s: `criteria` must be a table with `true` and `false` keys"):format(label))
		end
		for key in criteria do
			if key ~= true and key ~= false then
				return newError(
					"validation",
					("%s: `criteria` accepts only the keys true and false, found %s"):format(label, typeof(key)),
					{ field = "questions." .. id .. ".criteria" }
				)
			end
		end
		return nil
	end

	if question.type == QuestionTypes.Choice then
		local criteria = question.criteria
		if type(criteria) ~= "table" then
			return newError(
				"validation",
				("%s: `criteria` must be a map of option name to description"):format(label),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		local count = 0
		for key in criteria do
			count += 1
			if not isNonEmptyString(key) then
				return newError(
					"validation",
					("%s: `criteria` keys must be non-empty strings, found %s"):format(label, typeof(key)),
					{ field = "questions." .. id .. ".criteria" }
				)
			end
		end
		if count == 0 then
			return newError(
				"validation",
				("%s: `criteria` is empty; name at least one option, and an `other` escape when the set may not cover every input"):format(
					label
				),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		if count > MAX_CHOICE_OPTIONS then
			return newError(
				"validation",
				("%s: %d options exceeds the maximum of %d"):format(label, count, MAX_CHOICE_OPTIONS),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		return nil
	end

	if question.type == QuestionTypes.Score then
		local levels = question.criteria
		if type(levels) ~= "table" then
			return newError(
				"validation",
				("%s: `criteria` must be an ordered array of level descriptions"):format(label),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		local count, ordered = arrayShape(levels)
		if not ordered then
			return newError(
				"validation",
				("%s: `criteria` must be an ordered array; use a table of index to description"):format(label),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		if count < MIN_SCORE_LEVELS or count > MAX_SCORE_LEVELS then
			return newError(
				"validation",
				("%s: %d levels is outside the allowed range of %d to %d"):format(label, count, MIN_SCORE_LEVELS, MAX_SCORE_LEVELS),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		return nil
	end

	return newError("validation", ("%s: unknown question type %s"):format(label, tostring(question.type)))
end

---@param questions { Jev.Question }
---@return Jev.Error?
local function validateQuestions(questions: { Jev.Question }): Jev.Error?
	if #questions == 0 then
		return newError("validation", "No questions were added; add at least one with :Noul, :Choice, or :Score")
	end

	local seenIds: { [string]: boolean } = {}
	for index, question in questions do
		local err = validateQuestion(index, question, seenIds)
		if err then
			return err
		end
	end

	return nil
end

---@param client Jev.Client
---@param overrides Jev.SendOverrides?
---@return (Jev.Config?, Jev.Error?)
local function resolveConfig(client: Jev.Client, overrides: Jev.SendOverrides?): (Jev.Config?, Jev.Error?)
	local retry: Jev.Retry = {
		backoffInitial = client._retry.backoffInitial,
		backoffMax = client._retry.backoffMax,
		jitter = client._retry.jitter,
	}
	local model: any = client._model
	local timeout: any = client._timeout
	local maxRetries: any = client._maxRetries

	if overrides ~= nil then
		if type(overrides.model) == "string" and #overrides.model > 0 then
			model = overrides.model
		end
		if type(overrides.timeout) == "number" then
			timeout = overrides.timeout
		end
		if type(overrides.maxRetries) == "number" then
			maxRetries = overrides.maxRetries
		end
		if type(overrides.backoffInitial) == "number" then
			retry.backoffInitial = overrides.backoffInitial
		end
		if type(overrides.backoffMax) == "number" then
			retry.backoffMax = overrides.backoffMax
		end
		if type(overrides.jitter) == "number" then
			retry.jitter = overrides.jitter
		elseif type(overrides.backoffJitter) == "number" then
			retry.jitter = overrides.backoffJitter
		end
	end

	if type(model) ~= "string" or #model == 0 then
		return nil, newError("validation", "`model` must be a non-empty string, such as \"jev-latest\"")
	end
	if type(timeout) ~= "number" or timeout <= 0 then
		return nil, newError("validation", "`timeout` must be greater than zero")
	end
	if type(maxRetries) ~= "number" or maxRetries < 0 or maxRetries % 1 ~= 0 then
		return nil, newError("validation", "`maxRetries` must be zero or a positive whole number")
	end
	if retry.backoffInitial < 0 or retry.backoffMax < 0 then
		return nil, newError("validation", "`backoffInitial` and `backoffMax` must not be negative")
	end
	if retry.jitter < 0 or retry.jitter > 1 then
		return nil, newError("validation", "`jitter` is a fraction of the delay to remove, so it must be between 0 and 1")
	end

	return {
		model = model,
		timeout = timeout,
		maxRetries = maxRetries,
		retry = retry,
	}, nil
end

---@param client Jev.Client
---@return Jev.Error?
local function preflight(client: Jev.Client): Jev.Error?
	if not HttpService.HttpEnabled then
		return newError(
			"config",
			"HTTP requests are not enabled. Turn on File > Experience Settings > Security > Allow HTTP Requests.",
			{ cause = "HttpEnabled is false" }
		)
	end

	local keyType = typeof(client._key)
	if keyType ~= "Secret" and keyType ~= "string" then
		return newError(
			"config",
			"No usable API key. Pass a Secret from HttpService:GetSecret, or a string for a local scratch test.",
			{ cause = "key is " .. keyType }
		)
	end
	if keyType == "string" and #(client._key :: string) == 0 then
		return newError("config", "The API key is an empty string.", { cause = "key is empty" })
	end

	return nil
end

---@param key any
---@return string | Secret
local function authorizationHeader(key: any): string | Secret
	if type(key) == "string" then
		return "Bearer " .. key
	end
	return (key :: Secret):AddPrefix("Bearer ")
end

---@param client Jev.Client
---@param json boolean
---@return { [string]: string | Secret }
local function buildHeaders(client: Jev.Client, json: boolean): { [string]: string | Secret }
	local headers: { [string]: string | Secret } = {}
	for name, value in client._headers do
		headers[name] = value
	end
	if json then
		headers["content-type"] = "application/json"
	end
	headers["authorization"] = authorizationHeader(client._key)
	return headers
end

---@param headers any
---@param name string
---@return string?
local function getHeader(headers: any, name: string): string?
	if typeof(headers) ~= "table" then
		return nil
	end
	local direct = headers[name]
	if typeof(direct) == "string" then
		return direct
	end
	local lowered = name:lower()
	for key, value in headers do
		if typeof(key) == "string" and key:lower() == lowered and typeof(value) == "string" then
			return value
		end
	end
	return nil
end

---@param value string
---@return number?
local function parseHttpDate(value: string): number?
	local day, monthName, year, hour, minute, second, zone =
		value:match("^%a+,%s+(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%a+)$")
	if day == nil or monthName == nil or year == nil then
		return nil
	end
	local zoneName = if zone ~= nil then zone:lower() else ""
	if zoneName ~= "gmt" and zoneName ~= "utc" then
		return nil
	end
	local month = MONTHS[monthName:lower()]
	if month == nil then
		return nil
	end
	local target = os.time({
		year = tonumber(year) :: number,
		month = month,
		day = tonumber(day) :: number,
		hour = tonumber(hour) :: number,
		min = tonumber(minute) :: number,
		sec = tonumber(second) :: number,
	})
	return os.difftime(target, os.time())
end

---@param response any
---@return number?
local function retryAfterSeconds(response: any): number?
	if response == nil then
		return nil
	end
	local headers = response.Headers

	local millis = getHeader(headers, "retry-after-ms")
	if millis ~= nil then
		local value = tonumber(millis)
		if value ~= nil then
			return math.max(value / 1000, 0)
		end
	end

	local seconds = getHeader(headers, "retry-after")
	if seconds == nil then
		return nil
	end
	local numeric = tonumber(seconds)
	if numeric ~= nil then
		return math.max(numeric, 0)
	end
	local date = parseHttpDate(seconds)
	if date ~= nil then
		return math.max(date, 0)
	end
	return nil
end

---@param status number
---@return string
local function kindForStatus(status: number): string
	if status == 401 then
		return "auth"
	elseif status == 403 then
		return "forbidden"
	elseif status == 404 then
		return "notfound"
	elseif status == 408 then
		return "timeout"
	elseif status == 422 then
		return "validation"
	elseif status == 429 then
		return "rate_limited"
	elseif status == 529 then
		return "overloaded"
	elseif status >= 500 then
		return "server"
	end
	return "validation"
end

---@param value any
---@param depth number
---@return string?
local function findErrorField(value: any, depth: number): string?
	if depth > 3 or typeof(value) ~= "table" then
		return nil
	end
	if isNonEmptyString(value.field) then
		return value.field
	end

	local errors = value.errors
	if typeof(errors) == "table" then
		if typeof(errors[1]) == "table" then
			local nested = findErrorField(errors[1], depth + 1)
			if nested ~= nil then
				return nested
			end
		else
			for key in errors do
				if isNonEmptyString(key) then
					return key
				end
			end
		end
	end

	for _, key in NESTED_ERROR_KEYS do
		local nested = findErrorField(value[key], depth + 1)
		if nested ~= nil then
			return nested
		end
	end

	return nil
end

---@param value any
---@param depth number
---@return string?
local function findErrorMessage(value: any, depth: number): string?
	if depth > 3 or typeof(value) ~= "table" then
		return nil
	end

	for _, key in ERROR_MESSAGE_KEYS do
		local item = value[key]
		if isNonEmptyString(item) then
			return item
		end
		if typeof(item) == "table" then
			local nested = findErrorMessage(item, depth + 1)
			if nested ~= nil then
				return nested
			end
		end
	end

	local errors = value.errors
	if typeof(errors) == "table" then
		for key, item in errors do
			if isNonEmptyString(key) and isNonEmptyString(item) then
				return item
			end
			if typeof(item) == "table" then
				local nested = findErrorMessage(item, depth + 1)
				if nested ~= nil then
					return nested
				end
			end
		end
	end

	return nil
end

---@param body any
---@return string?, string?
local function inspectErrorBody(body: any): (string?, string?)
	if not isNonEmptyString(body) then
		return nil, nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(body :: string)
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil, truncate(body, 200)
	end

	return findErrorField(decoded, 1), findErrorMessage(decoded, 1)
end

---@param response any
---@param status number
---@param attempts number
---@return Jev.Error
local function responseError(response: any, status: number, attempts: number): Jev.Error
	local statusMessage = response.StatusMessage
	if not isNonEmptyString(statusMessage) then
		statusMessage = ("HTTP %d"):format(status)
	end

	local field, detail = inspectErrorBody(response.Body)
	local message = ("%s returned %d %s"):format(ENDPOINT, status, statusMessage)
	if detail ~= nil then
		message ..= ": " .. detail
	end
	if field ~= nil then
		message ..= (" (field %s)"):format(field)
	end

	return newError(kindForStatus(status), message, {
		status = status,
		field = field,
		attempts = attempts,
		cause = statusMessage,
	})
end

---@param retry Jev.Retry
---@param attempt number
---@return number
local function backoffDelay(retry: Jev.Retry, attempt: number): number
	local delay = math.min(retry.backoffMax, retry.backoffInitial * (2 ^ (attempt - 1)))
	local jitter = math.min(retry.jitter, 1)
	if jitter > 0 then
		delay *= 1 - math.random() * jitter
	end
	return math.max(delay, 0)
end

---@param request any
---@param config Jev.Config
---@param startedAt number
---@return boolean, any, number
local function performRequest(request: any, config: Jev.Config, startedAt: number): (boolean, any, number)
	local deadline = startedAt + config.timeout
	local maxAttempts = config.maxRetries + 1
	local attempts = 0
	local lastError: Jev.Error? = nil
	local lastResponse: any = nil

	while attempts < maxAttempts do
		if os.clock() >= deadline then
			if lastError ~= nil then
				return false, lastError, attempts
			end
			return false,
				newError("timeout", ("Request exceeded its %s seconds"):format(tostring(config.timeout)), {
					attempts = attempts,
					cause = "time budget exhausted",
				}),
				attempts
		end

		attempts += 1

		local called, response = pcall(function()
			return HttpService:RequestAsync(request)
		end)

		if not called or response == nil then
			lastResponse = nil
			lastError = newError("network", "The request failed before a response was received", {
				attempts = attempts,
				cause = tostring(response),
			})
		else
			lastResponse = response
			local status = tonumber(response.StatusCode) or 0

			if status >= 200 and status < 300 then
				local decoded, decodeError = pcall(function()
					return HttpService:JSONDecode(response.Body)
				end)
				if not decoded or typeof(decodeError) ~= "table" then
					return false,
						newError("decode", "The response body was not valid JSON", {
							status = status,
							attempts = attempts,
							cause = truncate(tostring(response.Body), 200),
						}),
						attempts
				end
				return true, decodeError, attempts
			end

			lastError = responseError(response, status, attempts)
		end

		if not lastError.retryable or attempts >= maxAttempts then
			return false, lastError, attempts
		end

		local serverDelay = retryAfterSeconds(lastResponse)
		local delay = if serverDelay ~= nil then serverDelay else backoffDelay(config.retry, attempts)

		if delay > 0 then
			if os.clock() + delay >= deadline then
				lastError.attempts = attempts
				return false, lastError, attempts
			end
			task.wait(delay)
		end
	end

	if lastError ~= nil then
		return false, lastError, attempts
	end
	return false, newError("timeout", "The request was never attempted", { attempts = attempts }), attempts
end

---@param questions { Jev.Question }
---@return { [string]: { type: string, instructions: any, criteria: any? } }
local function buildQuestionMap(questions: { Jev.Question }): { [string]: { type: string, instructions: any, criteria: any? } }
	local map = {}
	for _, question in questions do
		map[question.id] = {
			type = question.type,
			instructions = question.instructions,
			criteria = question.criteria,
		}
	end
	return map
end

---@param keyed any
---@return any
local function indexByLevel(keyed: any): any
	if typeof(keyed) ~= "table" then
		return keyed
	end
	local levels = {}
	for key, value in keyed do
		local level = tonumber(key)
		levels[if level ~= nil then level else key] = value
	end
	return levels
end

---@param decoded any
---@param questions { Jev.Question }
---@param model string
---@param attempts number
---@param startedAt number
---@return (Jev.Result?, Jev.Error?)
local function buildResult(
	decoded: any,
	questions: { Jev.Question },
	model: string,
	attempts: number,
	startedAt: number
): (Jev.Result?, Jev.Error?)
	if typeof(decoded) ~= "table" then
		return nil, newError("decode", "The response was not a JSON object", { attempts = attempts, cause = typeof(decoded) })
	end

	local answers = decoded.answers
	if typeof(answers) ~= "table" then
		return nil, newError("decode", "The response has no `answers` object", { attempts = attempts, cause = "answers" })
	end

	for _, question in questions do
		local answer = answers[question.id]
		if answer == nil then
			return nil,
				newError("decode", ("The response has no answer for question %q"):format(question.id), {
					attempts = attempts,
					field = question.id,
					cause = "missing answer",
				})
		end
		if typeof(answer) ~= "table" then
			return nil,
				newError("decode", ("The answer for %q was not an object"):format(question.id), {
					attempts = attempts,
					field = question.id,
					cause = "malformed answer",
				})
		end
		if answer.type ~= question.type then
			return nil,
				newError(
					"decode",
					("The answer for %q came back as %s but the question was %s"):format(
						question.id,
						tostring(answer.type),
						question.type
					),
					{ attempts = attempts, field = question.id, cause = "answer type mismatch" }
				)
		end
		if answer.type == QuestionTypes.Score then
			answer.legend = indexByLevel(answer.legend)
			answer.probabilities = indexByLevel(answer.probabilities)
		end
	end

	local rawUsage = decoded.usage
	if typeof(rawUsage) ~= "table" then
		rawUsage = {}
	end
	local inputTokens = tonumber(rawUsage.input_tokens) or 0
	local outputTokens = tonumber(rawUsage.output_tokens) or 0
	local inputCost = tonumber(rawUsage.input_cost) or (inputTokens * INPUT_COST_PER_TOKEN)

	return {
		model = if isNonEmptyString(decoded.model) then decoded.model else model,
		answers = answers,
		usage = {
			input_tokens = inputTokens,
			output_tokens = outputTokens,
			input_cost = inputCost,
		},
		attempts = attempts,
		latency = os.clock() - startedAt,
	}, nil
end

---@param decoded any
---@return ({ Jev.ModelInfo }?, Jev.Error?)
local function buildModelList(decoded: any): ({ Jev.ModelInfo }?, Jev.Error?)
	if typeof(decoded) ~= "table" then
		return nil, newError("decode", "The models response was not a JSON object or array", { cause = typeof(decoded) })
	end

	local list = decoded
	if typeof(decoded.models) == "table" then
		list = decoded.models
	elseif typeof(decoded.data) == "table" then
		list = decoded.data
	end

	if typeof(list) ~= "table" then
		return nil, newError("decode", "The models response has no model list", { cause = "models" })
	end

	local models: { Jev.ModelInfo } = {}
	for _, entry in list do
		if typeof(entry) ~= "table" or not isNonEmptyString(entry.name) then
			return nil, newError("decode", "The models response contained an entry without a `name`", { cause = "malformed model" })
		end
		models[#models + 1] = entry
	end

	return models, nil
end

---@param id string
---@param instructions any
---@param criteria any
---@return Jev.Question
local function buildNoul(id: string, instructions: any, criteria: any): Jev.Question
	return {
		id = id,
		type = QuestionTypes.Noul,
		instructions = instructions,
		criteria = criteria,
	}
end

---@param id string
---@param instructions any
---@param criteria any
---@return Jev.Question
local function buildChoice(id: string, instructions: any, criteria: any): Jev.Question
	return {
		id = id,
		type = QuestionTypes.Choice,
		instructions = instructions,
		criteria = criteria,
	}
end

---@param id string
---@param instructions any
---@param levels any
---@return Jev.Question
local function buildScore(id: string, instructions: any, levels: any): Jev.Question
	return {
		id = id,
		type = QuestionTypes.Score,
		instructions = instructions,
		criteria = levels,
	}
end

Jev.Noul = buildNoul
Jev.Choice = buildChoice
Jev.Score = buildScore

---@param answer any
---@return number?
local function answerConfidence(answer: any): number?
	if typeof(answer) ~= "table" then
		return nil
	end
	if typeof(answer.confidence) == "number" then
		return answer.confidence
	end
	if answer.type == QuestionTypes.Noul and typeof(answer.noul) == "number" then
		return answer.noul
	end
	return nil
end

---@param answer Jev.Answer | nil
---@param autoThreshold number?
---@param reviewThreshold number?
---@return "act" | "confirm" | "review"
function Jev.Route(answer: Jev.Answer | nil, autoThreshold: number?, reviewThreshold: number?): "act" | "confirm" | "review"
	local act: number = if type(autoThreshold) == "number" then autoThreshold else DEFAULTS.autoThreshold
	local review: number = if type(reviewThreshold) == "number" then reviewThreshold else DEFAULTS.reviewThreshold

	local confidence = answerConfidence(answer)
	if confidence == nil then
		return "review"
	elseif confidence > act then
		return "act"
	elseif confidence > review then
		return "confirm"
	end
	return "review"
end

local ClientMethods = {}
ClientMethods.__index = ClientMethods

local CLIENT_METATABLE = {
	__index = ClientMethods,
	__metatable = "locked",
	__tostring = function(self: Jev.Client): string
		return ("Jev.Client(model=%s, questions=%d)"):format(self._model, #self._questions)
	end,
}

---@param client Jev.Client
---@return Jev.Client
local function derive(client: Jev.Client): Jev.Client
	return setmetatable({
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
	}, CLIENT_METATABLE :: any) :: Jev.Client
end

---@param client Jev.Client
---@param question Jev.Question
---@return Jev.Client
local function withQuestion(client: Jev.Client, question: Jev.Question): Jev.Client
	local derived = derive(client)
	table.insert(derived._questions, question)
	return derived
end

---@param id string
---@param instructions Jev.Instructions
---@param criteria Jev.Criteria?
---@return Jev.Client
function ClientMethods:Noul(id: string, instructions: Jev.Instructions, criteria: Jev.Criteria?): Jev.Client
	return withQuestion(self, buildNoul(id, instructions, criteria))
end

---@param id string
---@param instructions Jev.Instructions
---@param criteria Jev.Criteria
---@return Jev.Client
function ClientMethods:Choice(id: string, instructions: Jev.Instructions, criteria: Jev.Criteria): Jev.Client
	return withQuestion(self, buildChoice(id, instructions, criteria))
end

---@param id string
---@param instructions Jev.Instructions
---@param levels Jev.Criteria
---@return Jev.Client
function ClientMethods:Score(id: string, instructions: Jev.Instructions, levels: Jev.Criteria): Jev.Client
	return withQuestion(self, buildScore(id, instructions, levels))
end

---@param name string
---@return Jev.Client
function ClientMethods:Model(name: string): Jev.Client
	local derived = derive(self)
	derived._model = name
	return derived
end

---@param seconds number
---@return Jev.Client
function ClientMethods:Timeout(seconds: number): Jev.Client
	local derived = derive(self)
	derived._timeout = seconds
	return derived
end

---@param count number
---@return Jev.Client
function ClientMethods:MaxRetries(count: number): Jev.Client
	local derived = derive(self)
	derived._maxRetries = count
	return derived
end

---@param overrides { backoffInitial: number?, backoffMax: number?, jitter: number?, backoffJitter: number? }
---@return Jev.Client
function ClientMethods:Retry(overrides: { backoffInitial: number?, backoffMax: number?, jitter: number?, backoffJitter: number? }): Jev.Client
	local derived = derive(self)
	if type(overrides.backoffInitial) == "number" then
		derived._retry.backoffInitial = overrides.backoffInitial
	end
	if type(overrides.backoffMax) == "number" then
		derived._retry.backoffMax = overrides.backoffMax
	end
	if type(overrides.jitter) == "number" then
		derived._retry.jitter = overrides.jitter
	elseif type(overrides.backoffJitter) == "number" then
		derived._retry.jitter = overrides.backoffJitter
	end
	return derived
end

---@param name string
---@param value string
---@return Jev.Client
function ClientMethods:Header(name: string, value: string): Jev.Client
	if not isNonEmptyString(name) or not isNonEmptyString(value) then
		return derive(self)
	end
	local derived = derive(self)
	derived._headers[name:lower()] = value
	return derived
end

---@param state any
---@param overrides Jev.SendOverrides?
---@return boolean, Jev.Result | Jev.Error
function ClientMethods:Send(state: any, overrides: Jev.SendOverrides?): (boolean, Jev.Result | Jev.Error)
	local startedAt = os.clock()

	local config, configError = resolveConfig(self, overrides)
	if config == nil then
		return false, configError :: Jev.Error
	end

	local stateError = validateState(state)
	if stateError then
		return false, stateError
	end

	local questionsError = validateQuestions(self._questions)
	if questionsError then
		return false, questionsError
	end

	local environmentError = preflight(self)
	if environmentError then
		return false, environmentError
	end

	local body = {
		state = state,
		model = config.model,
		questions = buildQuestionMap(self._questions),
	}

	local encoded, encodeError = encodeBody(body)
	if encoded == nil then
		return false, encodeError :: Jev.Error
	end

	local request = {
		Url = ENDPOINT,
		Method = "POST",
		Headers = buildHeaders(self, true),
		Body = encoded,
	}

	local ok, payload, attempts = performRequest(request, config, startedAt)
	if not ok then
		return false, payload
	end

	local result, resultError = buildResult(payload, self._questions, config.model, attempts, startedAt)
	if result == nil then
		return false, resultError :: Jev.Error
	end
	return true, result
end

---@return boolean, { Jev.ModelInfo } | Jev.Error
function ClientMethods:models(): (boolean, { Jev.ModelInfo } | Jev.Error)
	local startedAt = os.clock()

	local config, configError = resolveConfig(self, nil)
	if config == nil then
		return false, configError :: Jev.Error
	end

	local environmentError = preflight(self)
	if environmentError then
		return false, environmentError
	end

	local request = {
		Url = MODELS_ENDPOINT,
		Method = "GET",
		Headers = buildHeaders(self, false),
	}

	local ok, payload = performRequest(request, config, startedAt)
	if not ok then
		return false, payload
	end

	local models, modelsError = buildModelList(payload)
	if models == nil then
		return false, modelsError :: Jev.Error
	end
	return true, models
end

---@param key string | Secret | nil
---@return Jev.Client
function Jev.new(key: string | Secret | nil): Jev.Client
	return setmetatable({
		_key = key,
		_model = DEFAULTS.model,
		_timeout = DEFAULTS.timeout,
		_maxRetries = DEFAULTS.maxRetries,
		_retry = {
			backoffInitial = DEFAULTS.backoffInitial,
			backoffMax = DEFAULTS.backoffMax,
			jitter = DEFAULTS.jitter,
		},
		_headers = {},
		_questions = {},
	}, CLIENT_METATABLE :: any) :: Jev.Client
end

return Jev
