--!strict

-- Everything the module can reject before spending a request. Each validator
-- returns a `Jev.Error` or nil, and nothing here touches the network.

local C = require(script.Parent.constants)
local Errors = require(script.Parent.errors)
local Types = require(script.Parent.types)
local Util = require(script.Parent.util)

local newError = Errors.new
local isNonEmptyString = Util.isNonEmptyString

local QuestionTypes = C.QuestionTypes

-- Returns the entry count, and whether the table is a dense 1..n array.
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

local function validateState(state: any): Types.Error?
	local stateType = typeof(state)

	if stateType == "string" then
		if #state == 0 then
			return newError("validation", "`state` is an empty string; pass the text to judge")
		end
		return nil
	end

	if stateType == "table" then
		if state == C.Null or next(state) == nil then
			return newError("validation", "`state` is empty; pass a string, an object, or an array of text values")
		end
		return nil
	end

	return newError("validation", ("`state` must be a string, an object, or an array, not %s"):format(stateType))
end

local function validateInstructions(instructions: Types.Instructions): Types.Error?
	local instructionsType = typeof(instructions)

	if instructionsType == "string" then
		if #instructions == 0 then
			return newError("validation", "`instructions` is an empty string; write the whole question out")
		end
		return nil
	end

	if instructionsType == "table" then
		if instructions == C.Null or next(instructions) == nil then
			return newError("validation", "`instructions` is an empty table; write the whole question out")
		end
		return nil
	end

	return newError("validation", ("`instructions` must be a string, an object, or an array, not %s"):format(instructionsType))
end

-- `json.luau` writes every object key with `tostring(key)`, so boolean `true`
-- and the string `"true"` already encode to the same JSON key. Editors differ
-- on which spelling they produce, so both are accepted here rather than
-- rejecting a table that would have serialized correctly.
local function isNoulKey(key: any): boolean
	return key == true or key == false or key == "true" or key == "false"
end

local function validateQuestion(index: number, question: Types.Question, seenIds: { [string]: boolean }): Types.Error?
	if not isNonEmptyString(question.id) then
		return newError("validation", ("Question #%d has a missing or non-string id"):format(index))
	end

	local id = question.id
	local label = ("Question %q"):format(id)

	if id:match("^%s*$") then
		return newError("validation", ("%s has an id made only of whitespace"):format(label))
	end
	if id:find(C.PATH_CHARACTERS) then
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

	local criteria = question.criteria

	if question.type == QuestionTypes.Noul then
		if criteria == nil then
			return nil
		end
		if type(criteria) ~= "table" then
			return newError("validation", ("%s: `criteria` must be a table with `true` and `false` keys"):format(label))
		end
		-- Keyed by the encoded form, so `{ true = .., ["true"] = .. }` is caught
		-- rather than serialized into a JSON object with a repeated key.
		local encodedKeys: { [string]: boolean } = {}
		for key in criteria do
			if not isNoulKey(key) then
				return newError(
					"validation",
					("%s: `criteria` accepts only the keys true and false, found %s"):format(label, typeof(key)),
					{ field = "questions." .. id .. ".criteria" }
				)
			end
			local encodedKey = tostring(key)
			if encodedKeys[encodedKey] then
				return newError(
					"validation",
					("%s: `criteria` describes %s twice; `true` and %q encode to the same key, so keep one"):format(
						label,
						encodedKey,
						encodedKey
					),
					{ field = "questions." .. id .. ".criteria" }
				)
			end
			encodedKeys[encodedKey] = true
		end
		return nil
	end

	if question.type == QuestionTypes.Choice then
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
		if count > C.MAX_CHOICE_OPTIONS then
			return newError(
				"validation",
				("%s: %d options exceeds the maximum of %d"):format(label, count, C.MAX_CHOICE_OPTIONS),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		return nil
	end

	if question.type == QuestionTypes.Score then
		if type(criteria) ~= "table" then
			return newError(
				"validation",
				("%s: `criteria` must be an ordered array of level descriptions"):format(label),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		local count, ordered = arrayShape(criteria)
		if not ordered then
			return newError(
				"validation",
				("%s: `criteria` must be an ordered array; use a table of index to description"):format(label),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		if count < C.MIN_SCORE_LEVELS or count > C.MAX_SCORE_LEVELS then
			return newError(
				"validation",
				("%s: %d levels is outside the allowed range of %d to %d"):format(
					label,
					count,
					C.MIN_SCORE_LEVELS,
					C.MAX_SCORE_LEVELS
				),
				{ field = "questions." .. id .. ".criteria" }
			)
		end
		return nil
	end

	return newError("validation", ("%s: unknown question type %s"):format(label, tostring(question.type)))
end

local function validateQuestions(questions: { Types.Question }): Types.Error?
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

return {
	validateState = validateState,
	validateQuestions = validateQuestions,
}
