--!strict

-- Turning a decoded response into the tables the caller sees: `Jev.Result`
-- and the model list from `GET /v1/models`. Anything that does not match the
-- documented shape becomes a `decode` error rather than a `nil` index later.

local C = require(script.Parent.constants)
local Errors = require(script.Parent.errors)
local Types = require(script.Parent.types)
local Util = require(script.Parent.util)

local newError = Errors.new
local isNonEmptyString = Util.isNonEmptyString

local QuestionTypes = C.QuestionTypes

-- `legend` and `probabilities` arrive keyed by stringified level index, so
-- rebuild them keyed by number.
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

local function buildResult(
	decoded: any,
	questions: { Types.Question },
	model: string,
	attempts: number,
	startedAt: number
): (Types.Result?, Types.Error?)
	if typeof(decoded) ~= "table" then
		return nil, newError("decode", "The response was not a JSON object", { attempts = attempts, cause = typeof(decoded) })
	end

	local rawAnswers = decoded.answers
	if typeof(rawAnswers) ~= "table" then
		return nil, newError("decode", "The response has no `answers` object", { attempts = attempts, cause = "answers" })
	end

	for _, question in questions do
		local answer = rawAnswers[question.id]
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
	local inputCost = tonumber(rawUsage.input_cost) or (inputTokens * C.INPUT_COST_PER_TOKEN)

	return {
		model = if isNonEmptyString(decoded.model) then decoded.model else model,
		answers = rawAnswers :: { [string]: Types.Answer },
		usage = {
			input_tokens = inputTokens,
			output_tokens = outputTokens,
			input_cost = inputCost,
		},
		attempts = attempts,
		latency = os.clock() - startedAt,
	}, nil
end

local function buildModelList(decoded: any): ({ Types.ModelInfo }?, Types.Error?)
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

	local models: { Types.ModelInfo } = {}
	for _, entry in list do
		if typeof(entry) ~= "table" or not isNonEmptyString(entry.name) then
			return nil, newError("decode", "The models response contained an entry without a `name`", { cause = "malformed model" })
		end
		models[#models + 1] = entry
	end

	return models, nil
end

return {
	buildResult = buildResult,
	buildModelList = buildModelList,
}
