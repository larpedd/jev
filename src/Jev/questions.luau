--!strict

-- The three question primitives, plus the map the API expects on the wire.
-- These are plain table builders: `Jev.Noul` and `ClientMethods:Noul` both
-- come from here, so a question set can be built without a client.

local C = require(script.Parent.constants)
local Types = require(script.Parent.types)

local QuestionTypes = C.QuestionTypes

local function buildNoul(id: string, instructions: Types.Instructions, criteria: Types.Criteria?): Types.Question
	return {
		id = id,
		type = QuestionTypes.Noul,
		instructions = instructions,
		criteria = criteria,
	}
end

local function buildChoice(id: string, instructions: Types.Instructions, criteria: Types.Criteria): Types.Question
	return {
		id = id,
		type = QuestionTypes.Choice,
		instructions = instructions,
		criteria = criteria,
	}
end

local function buildScore(id: string, instructions: Types.Instructions, levels: Types.Criteria): Types.Question
	return {
		id = id,
		type = QuestionTypes.Score,
		instructions = instructions,
		criteria = levels,
	}
end

export type WireQuestion = {
	type: Types.QuestionType,
	instructions: Types.Instructions,
	criteria: Types.Criteria?,
}

local function buildQuestionMap(questions: { Types.Question }): { [string]: WireQuestion }
	local map: { [string]: WireQuestion } = {}
	for _, question in questions do
		map[question.id] = {
			type = question.type,
			instructions = question.instructions,
			criteria = question.criteria,
		}
	end
	return map
end

return {
	buildNoul = buildNoul,
	buildChoice = buildChoice,
	buildScore = buildScore,
	buildQuestionMap = buildQuestionMap,
}
