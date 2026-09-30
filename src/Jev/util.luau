--!strict

-- Small predicates and string helpers shared by the rest of the package.

local function truncate(text: string, limit: number): string
	if #text <= limit then
		return text
	end
	return text:sub(1, limit) .. "..."
end

local function isNonEmptyString(value: any): boolean
	return typeof(value) == "string" and #value > 0
end

return {
	truncate = truncate,
	isNonEmptyString = isNonEmptyString,
}
