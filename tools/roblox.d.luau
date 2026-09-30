--!strict

-- Roblox globals for `luau-lsp analyze`.
--
-- The Luau analyzer's CLI does not download Roblox's type database, so without
-- this file every `game:GetService`, `Secret`, and `task` reference in the
-- package reports as an unknown global. This declares exactly the surface
-- `src/Jev` touches, with the shapes Roblox documents.
--
-- In your editor, luau-lsp loads Roblox's real database and this file is not
-- used. Keep it in step with the API if the package starts using more.
--
-- `export type` is what makes an alias visible outside a definitions file;
-- `declare` is what makes a value or function global.

export type Secret = {
	AddPrefix: (self: Secret, prefix: string) -> Secret,
	AddSuffix: (self: Secret, suffix: string) -> Secret,
}

-- Roblox accepts a Secret anywhere a header value is expected.
export type HttpHeaders = { [string]: string | Secret }

export type HttpRequest = {
	Url: string | Secret,
	Method: ("GET" | "HEAD" | "POST" | "PUT" | "DELETE" | "PATCH")?,
	Body: string?,
	Headers: HttpHeaders?,
	Compress: any?,
	Timeout: number?,
}

export type HttpResponse = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
	Body: string,
}

export type HttpService = {
	HttpEnabled: boolean,
	RequestAsync: (self: HttpService, request: HttpRequest) -> HttpResponse,
	JSONEncode: (self: HttpService, value: any) -> string,
	JSONDecode: (self: HttpService, json: string) -> any,
	GetSecret: (self: HttpService, key: string) -> Secret,
}

export type DataModel = {
	GetService: (self: DataModel, className: "HttpService") -> HttpService,
}

declare game: DataModel

declare task: {
	wait: (seconds: number?) -> number,
	spawn: <T>(thread: () -> T) -> thread,
	delay: (seconds: number, thread: () -> ()) -> thread,
}

declare Debug: {
	isDebuggerEnabled: () -> boolean,
}

declare function warn(message: any): ()
