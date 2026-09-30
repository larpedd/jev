--!strict

-- JSON encoding. `HttpService:JSONEncode` cannot represent `Jev.Null`, cannot
-- detect cycles with a useful path, and rejects non-finite numbers silently
-- differently per version, so the request body is encoded here.

local C = require(script.Parent.constants)
local Errors = require(script.Parent.errors)
local Types = require(script.Parent.types)

local newError = Errors.new

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

-- Tables are visited for cycle detection, so the key is the table itself.
type Seen = { [any]: boolean }

local function escapeString(value: string): string
	local escaped = value:gsub('[%c"\\]', function(char: string): string
		return ESCAPES[char] or string.format("\\u%04x", string.byte(char))
	end)
	return '"' .. escaped .. '"'
end

local function encodeValue(value: any, seen: Seen, path: string): (string?, string?)
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

	if value == C.Null then
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

local function encodeBody(body: any): (string?, Types.Error?)
	local encoded, err = encodeValue(body, {}, "body")
	if encoded == nil then
		return nil, newError("validation", ("Request body cannot be encoded: %s"):format(err or "unknown reason"))
	end
	return encoded, nil
end

return {
	encodeBody = encodeBody,
}
