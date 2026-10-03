--!strict
--[[
	LuauLexer

	A small, forgiving Luau tokenizer. It never errors: unterminated strings and
	comments simply run to the end of the line / file, which is exactly what you
	want while the user is mid-typing.

	You only need this if your editor does not already have a tokenizer. The
	ChainCollector does not depend on it; it talks to an Adapter.

	Offsets are 1-based, inclusive character indices into the source string.
	Whitespace is skipped unless `keepSpace` is true.

	Known simplifications:
	  * `.5` style numbers lex as `.` then `5`
	  * interpolated strings (`...{x}...`) lex as one plain string token
	  * contextual keywords (`continue`, `type`, `export`) lex as names
]]

export type TokenKind = "name" | "keyword" | "string" | "number" | "symbol" | "comment" | "space" | "other"

export type Token = {
	kind: TokenKind,
	text: string,
	start: number,
	stop: number,
}

local KEYWORDS: { [string]: boolean } = {}
for _, word in
	{
		"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
		"local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
	}
do
	KEYWORDS[word] = true
end

local SYMBOLS3: { [string]: boolean } = { ["..."] = true, ["..="] = true, ["//="] = true }
local SYMBOLS2: { [string]: boolean } = {}
for _, s in { "==", "~=", "<=", ">=", "..", "::", "->", "+=", "-=", "*=", "/=", "//", "%=", "^=" } do
	SYMBOLS2[s] = true
end
local SYMBOLS1: { [string]: boolean } = {}
for c in string.gmatch("+-*/%^#<>=(){}[];:,.~|&?@", ".") do
	SYMBOLS1[c] = true
end

local function numberStop(src: string, i: number): number
	local hex = string.match(src, "^0[xX][%x_]+", i)
	if hex then
		return i + #hex - 1
	end
	local bin = string.match(src, "^0[bB][01_]+", i)
	if bin then
		return i + #bin - 1
	end
	local j = i
	local digits = string.match(src, "^[%d_]+", j) or ""
	j += #digits
	-- a fraction, but never swallow the first dot of `..`
	if string.sub(src, j, j) == "." and string.sub(src, j + 1, j + 1) ~= "." then
		j += 1
		local frac = string.match(src, "^[%d_]*", j) or ""
		j += #frac
	end
	local exp = string.match(src, "^[eE][+-]?%d+", j)
	if exp then
		j += #exp
	end
	return j - 1
end

local LuauLexer = {}

function LuauLexer.lex(src: string, keepSpace: boolean?): { Token }
	local tokens: { Token } = {}
	local n = #src
	local i = 1

	local function push(kind: TokenKind, s: number, e: number)
		tokens[#tokens + 1] = { kind = kind, text = string.sub(src, s, e), start = s, stop = e }
	end

	while i <= n do
		local ws, we = string.find(src, "^%s+", i)
		if ws and we then
			if keepSpace then
				push("space", ws, we)
			end
			i = we + 1
		elseif string.sub(src, i, i + 1) == "--" then
			local eq = string.match(src, "^%-%-%[(=*)%[", i)
			local stop: number
			if eq then
				local closer = "]" .. eq .. "]"
				local _, ce = string.find(src, closer, i + 4 + #eq, true)
				stop = ce or n
			else
				local nl = string.find(src, "\n", i, true)
				stop = nl and nl - 1 or n
				if stop > i + 1 and string.sub(src, stop, stop) == "\r" then
					stop -= 1
				end
			end
			push("comment", i, stop)
			i = stop + 1
		else
			local ns, ne = string.find(src, "^[%a_][%w_]*", i)
			local c = string.sub(src, i, i)
			if ns and ne then
				local word = string.sub(src, ns, ne)
				local kind: TokenKind = "name"
				if KEYWORDS[word] then
					kind = "keyword"
				end
				push(kind, ns, ne)
				i = ne + 1
			elseif string.find(c, "^%d") then
				local stop = numberStop(src, i)
				push("number", i, stop)
				i = stop + 1
			elseif c == '"' or c == "'" or c == "`" then
				local stop = n
				local j = i + 1
				while j <= n do
					local ch = string.sub(src, j, j)
					if ch == "\\" then
						j += 2
					elseif ch == c then
						stop = j
						break
					elseif ch == "\n" then
						stop = j - 1
						if stop > i and string.sub(src, stop, stop) == "\r" then
							stop -= 1
						end
						break
					else
						j += 1
					end
				end
				push("string", i, math.min(stop, n))
				i = math.min(stop, n) + 1
			else
				local eq = c == "[" and string.match(src, "^%[(=*)%[", i) or nil
				if eq then
					local closer = "]" .. eq .. "]"
					local _, ce = string.find(src, closer, i + #eq + 2, true)
					local stop = ce or n
					push("string", i, stop)
					i = stop + 1
				else
					local three = string.sub(src, i, i + 2)
					local two = string.sub(src, i, i + 1)
					if SYMBOLS3[three] then
						push("symbol", i, i + 2)
						i += 3
					elseif SYMBOLS2[two] then
						push("symbol", i, i + 1)
						i += 2
					elseif SYMBOLS1[c] then
						push("symbol", i, i)
						i += 1
					else
						push("other", i, i)
						i += 1
					end
				end
			end
		end
	end

	return tokens
end

return LuauLexer
