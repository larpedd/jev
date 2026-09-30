--!strict

-- The confidence routing helper behind `Jev.Route`. Confidence is a property
-- of how peaked the distribution is, and it only exists on choice and score
-- answers; a noul falls back to its probability.

local C = require(script.Parent.constants)
local Types = require(script.Parent.types)

local QuestionTypes = C.QuestionTypes

local function answerConfidence(answer: Types.Answer?): number?
	if answer == nil then
		return nil
	end
	if answer.confidence ~= nil then
		return answer.confidence
	end
	if answer.type == QuestionTypes.Noul and answer.noul ~= nil then
		return answer.noul
	end
	return nil
end

local function route(answer: Types.Answer?, autoThreshold: number?, reviewThreshold: number?): Types.Route
	-- `type` guards rather than `~= nil`: a non-number threshold must not
	-- reach the comparisons below and throw out of Route.
	local act: number = if type(autoThreshold) == "number" then autoThreshold else C.DEFAULTS.autoThreshold
	local review: number =
		if type(reviewThreshold) == "number" then reviewThreshold else C.DEFAULTS.reviewThreshold

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

return {
	route = route,
}
