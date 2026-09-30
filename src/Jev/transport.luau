--!strict

-- Everything that touches `HttpService`: per-call config resolution, header
-- construction, environment preflight, error-body inspection, and the retry
-- loop with exponential backoff and `Retry-After` support.

local HttpService = game:GetService("HttpService")

local C = require(script.Parent.constants)
local Errors = require(script.Parent.errors)
local Types = require(script.Parent.types)
local Util = require(script.Parent.util)

local newError = Errors.new
local isNonEmptyString = Util.isNonEmptyString
local truncate = Util.truncate

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

local function resolveConfig(client: Types.Client, overrides: Types.SendOverrides?): (Types.Config?, Types.Error?)
	local retry: Types.Retry = {
		backoffInitial = client._retry.backoffInitial,
		backoffMax = client._retry.backoffMax,
		jitter = client._retry.jitter,
	}
	local model = client._model
	local timeout = client._timeout
	local maxRetries = client._maxRetries

	if overrides ~= nil then
		-- The types say these are numbers or nil, but this function is the
		-- last line of defence: a wrong type here must become a validation
		-- error, not a comparison error thrown out of Send.
		local overrideModel = overrides.model
		local overrideTimeout = overrides.timeout
		local overrideMaxRetries = overrides.maxRetries
		local overrideBackoffInitial = overrides.backoffInitial
		local overrideBackoffMax = overrides.backoffMax
		local overrideJitter = overrides.jitter
		local overrideBackoffJitter = overrides.backoffJitter

		if type(overrideModel) == "string" and #overrideModel > 0 then
			model = overrideModel
		end
		if type(overrideTimeout) == "number" then
			timeout = overrideTimeout
		end
		if type(overrideMaxRetries) == "number" then
			maxRetries = overrideMaxRetries
		end
		if type(overrideBackoffInitial) == "number" then
			retry.backoffInitial = overrideBackoffInitial
		end
		if type(overrideBackoffMax) == "number" then
			retry.backoffMax = overrideBackoffMax
		end
		if type(overrideJitter) == "number" then
			retry.jitter = overrideJitter
		elseif type(overrideBackoffJitter) == "number" then
			retry.jitter = overrideBackoffJitter
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
	if type(retry.backoffInitial) ~= "number" or type(retry.backoffMax) ~= "number" then
		return nil, newError("validation", "`backoffInitial` and `backoffMax` must be numbers")
	end
	if retry.backoffInitial < 0 or retry.backoffMax < 0 then
		return nil, newError("validation", "`backoffInitial` and `backoffMax` must not be negative")
	end
	if type(retry.jitter) ~= "number" or retry.jitter < 0 or retry.jitter > 1 then
		return nil, newError("validation", "`jitter` is a fraction of the delay to remove, so it must be between 0 and 1")
	end

	local config: Types.Config = {
		model = model,
		timeout = timeout,
		maxRetries = maxRetries,
		retry = retry,
	}
	return config, nil
end

local function preflight(client: Types.Client): Types.Error?
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

local function authorizationHeader(key: string | Secret): string | Secret
	if type(key) == "string" then
		return "Bearer " .. key
	end
	return key:AddPrefix("Bearer ")
end

local function buildHeaders(client: Types.Client, json: boolean): Types.Headers
	local headers: Types.Headers = {}
	for name, value in client._headers do
		headers[name] = value
	end
	if json then
		headers["content-type"] = "application/json"
	end

	-- `preflight` has already rejected a missing key; leaving the header off
	-- keeps this function total instead of fabricating "Bearer nil".
	local key = client._key
	if key ~= nil then
		headers["authorization"] = authorizationHeader(key)
	end

	return headers
end

local function getHeader(headers: { [string]: string }?, name: string): string?
	if headers == nil or typeof(headers) ~= "table" then
		return nil
	end
	local direct = headers[name]
	if typeof(direct) == "string" then
		return direct
	end
	local lowered = name:lower()
	for key, value in headers do
		if key:lower() == lowered and typeof(value) == "string" then
			return value
		end
	end
	return nil
end

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

local function retryAfterSeconds(response: Types.HttpResponse?): number?
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

local function kindForStatus(status: number): Types.ErrorKind
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

local function inspectErrorBody(body: any): (string?, string?)
	if not isNonEmptyString(body) then
		return nil, nil
	end

	local ok, decoded = pcall(function(): any
		return HttpService:JSONDecode(body :: string)
	end)
	if not ok or typeof(decoded) ~= "table" then
		return nil, truncate(body, 200)
	end

	return findErrorField(decoded, 1), findErrorMessage(decoded, 1)
end

local function responseError(response: Types.HttpResponse, status: number, attempts: number): Types.Error
	local statusMessage = response.StatusMessage
	if not isNonEmptyString(statusMessage) then
		statusMessage = ("HTTP %d"):format(status)
	end

	local field, detail = inspectErrorBody(response.Body)
	local message = ("%s returned %d %s"):format(C.ENDPOINT, status, statusMessage)
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

local function backoffDelay(retry: Types.Retry, attempt: number): number
	local delay = math.min(retry.backoffMax, retry.backoffInitial * (2 ^ (attempt - 1)))
	local jitter = math.min(retry.jitter, 1)
	if jitter > 0 then
		delay *= 1 - math.random() * jitter
	end
	return math.max(delay, 0)
end

-- Returns `true, decodedBody, attempts` on success and `false, error, attempts`
-- otherwise. The second slot is deliberately `any`: it is a decoded JSON body
-- on success and a `Jev.Error` on failure, and the two are told apart by `ok`.
local function performRequest(
	request: Types.HttpRequest,
	config: Types.Config,
	startedAt: number
): (boolean, any, number)
	local deadline = startedAt + config.timeout
	local maxAttempts = config.maxRetries + 1
	local attempts = 0
	local lastError: Types.Error? = nil
	local lastResponse: Types.HttpResponse? = nil

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

		local called, rawResponse = pcall(function(): Types.HttpResponse
			return HttpService:RequestAsync(request)
		end)

		local attemptError: Types.Error
		if not called or rawResponse == nil then
			lastResponse = nil
			attemptError = newError("network", "The request failed before a response was received", {
				attempts = attempts,
				cause = tostring(rawResponse),
			})
		else
			local response: Types.HttpResponse = rawResponse
			lastResponse = response
			local status = tonumber(response.StatusCode) or 0

			if status >= 200 and status < 300 then
				local decoded, decodeError = pcall(function(): any
					return HttpService:JSONDecode(response.Body)
				end)
				if not decoded or typeof(decodeError) ~= "table" then
					return false,
						newError("decode", "The response body was not valid JSON", {
							status = status,
							attempts = attempts,
							cause = truncate(response.Body, 200),
						}),
						attempts
				end
				return true, decodeError, attempts
			end

			attemptError = responseError(response, status, attempts)
		end

		lastError = attemptError

		if not attemptError.retryable or attempts >= maxAttempts then
			return false, attemptError, attempts
		end

		local serverDelay = retryAfterSeconds(lastResponse)
		local delay = if serverDelay ~= nil then serverDelay else backoffDelay(config.retry, attempts)

		if delay > 0 then
			if os.clock() + delay >= deadline then
				attemptError.attempts = attempts
				return false, attemptError, attempts
			end
			task.wait(delay)
		end
	end

	if lastError ~= nil then
		return false, lastError, attempts
	end
	return false, newError("timeout", "The request was never attempted", { attempts = attempts }), attempts
end

return {
	resolveConfig = resolveConfig,
	preflight = preflight,
	buildHeaders = buildHeaders,
	performRequest = performRequest,
}
