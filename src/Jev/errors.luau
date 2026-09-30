--!strict

-- Construction of the `Jev.Error` table. The module never calls `error`;
-- every failure is one of these returned to the caller.

local C = require(script.Parent.constants)
local Types = require(script.Parent.types)

local function newError(kind: Types.ErrorKind, message: string, options: Types.ErrorOptions?): Types.Error
	local retryable: boolean
	if options ~= nil and options.retryable ~= nil then
		retryable = options.retryable
	else
		retryable = C.RETRYABLE_KINDS[kind] == true
	end

	local status = if options then options.status else nil
	local field = if options then options.field else nil
	local attempts = if options then options.attempts else nil
	local cause = if options then options.cause else nil

	return {
		kind = kind,
		message = message,
		status = status,
		field = field,
		retryable = retryable,
		attempts = attempts or 0,
		cause = cause,
	}
end

return {
	new = newError,
}
