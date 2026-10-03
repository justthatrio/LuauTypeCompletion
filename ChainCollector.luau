--!strict
--[[
	ChainCollector
	==============

	Answers one question for an editor, lazily and without a full parse:

	    "Given the cursor, what expression chain is to its left?"

	e.g. for   workspace.Map:FindFirstChild("Door").Na|
	it yields  receiver chain  workspace  .Map  :FindFirstChild  ("Door")
	           partial         "Na"

	It only looks at tokens (never the whole file), walks BACKWARD from the
	cursor, and returns nil / empty results instead of guessing when the code is
	too broken to say. It knows nothing about Roblox types, UI, or how your editor
	stores text. Resolving a Chain into types is the next layer's job.

	INTEGRATING WITH YOUR EDITOR
	----------------------------
	Implement an Adapter over your existing token storage (no copying needed):

	    local adapter = {
	        count = function() return #tokens end,
	        kind  = function(i) ... end,   -- see TokenKind
	        text  = function(i) ... end,   -- source text of token i
	        start = function(i) ... end,   -- 1-based char index of first char
	        stop  = function(i) ... end,   -- 1-based char index of last char (inclusive)
	    }
	    local collector = ChainCollector.new(adapter)

	or, if you have a flat array of token tables:

	    ChainCollector.fromTokenArray(tokens, {
	        fields = { kind = "Type", text = "Value", start = "Start", stop = "End" },
	        kinds  = { Identifier = "name", Keyword = "keyword", ... },
	    })

	Requirements: tokens are ordered, non-overlapping, and use ONE consistent
	absolute offset space (the same one your cursor is expressed in). Comment
	tokens must be emitted (so the collector can tell it is inside one);
	whitespace tokens are optional. Unterminated strings/comments must still be
	emitted as a single token running to end of line / file.

	COORDINATES
	-----------
	forCompletion / forSignature take `cursor`, a 1-based insertion point exactly
	like TextBox.CursorPosition (cursor == #text + 1 at the very end).
	forHover takes `charIndex`, the index of the character under the pointer.

	STEP SHAPES (Chain = array of Step, in evaluation order, [1] is the root)
	-------------------------------------------------------------------------
	name     { name }                              workspace
	member   { name, accessor = "." | ":" | "[]" } .Map   :FindFirstChild   ["Map"]
	call     { args, stringArg }                   ("Door")   (args are token ranges)
	index    { }                                   [expr]  (dynamic, unresolvable)
	literal  { literal, value }                    root of ("abc"):upper()
	group    { inner?, cast? }                     root of (expr) ; `cast` for (x :: T)

	Every step also carries first/last (token indices) and start/stop (chars).

	KNOWN LIMITS (all fail closed, i.e. nil / partial info, never a wrong answer)
	  * `f"str"` / `f{...}` call sugar is not treated as a call
	  * type-annotation detection covers `local x:`, parameters, return types
	    and `::`; `type X = {...}` table fields are not recognised
	  * if-expressions vs if-statements are told apart by the preceding token
	    (see isStatementIf); `else if` is assumed to be a statement
	  * only simple string escapes are decoded (\n \t \r \\ \" \' \`)
]]

export type TokenKind = "name" | "keyword" | "string" | "number" | "symbol" | "comment" | "space" | "other"

export type Adapter = {
	count: () -> number,
	kind: (i: number) -> TokenKind,
	text: (i: number) -> string,
	start: (i: number) -> number,
	stop: (i: number) -> number,
}

export type Options = {
	maxScan: number?, -- max tokens examined per backward scan (default 4000)
	maxSteps: number?, -- max steps in one chain (default 64)
	maxDepth: number?, -- max nesting of ( ) groups (default 8)
}

type ResolvedOptions = { maxScan: number, maxSteps: number, maxDepth: number }

export type Arg = {
	first: number, -- token index range of the argument
	last: number,
	start: number, -- char range
	stop: number,
	string: string?, -- decoded value when the argument is exactly one string literal
}

export type Step = {
	kind: "name" | "member" | "call" | "index" | "literal" | "group",
	name: string?, -- name, member
	accessor: string?, -- member: "." | ":" | "[]"
	args: { Arg }?, -- call
	stringArg: string?, -- call: args[1].string, for GetService("X") / Instance.new("X")
	literal: string?, -- literal: "string" | "number" | "boolean" | "nil" | "table"
	value: string?, -- literal
	inner: Chain?, -- group: chain of the parenthesised expression, nil if it is not a plain chain
	cast: string?, -- group: type name of a `(expr :: Type)` cast
	first: number,
	last: number,
	start: number,
	stop: number,
}
export type Chain = { Step }

export type SignatureContext = {
	callee: Chain, -- chain up to and including the function name
	isMethod: boolean, -- called with `:` (implicit self)
	activeParam: number, -- 1-based index of the argument being typed
	openParen: number, -- token index of the `(`
	argStart: number, -- token index of the `(` or `,` that starts the current argument
	stringArg: string?, -- current argument if it is a lone string literal (text before the cursor)
}

export type CompletionContext = {
	kind: "member" | "identifier" | "string" | "type",
	partial: string, -- text already typed (before the cursor)
	anchor: number, -- every token with index < anchor lies entirely before the text being completed
	replaceStart: number, -- range an accepted completion should replace
	replaceStop: number, -- (empty range when replaceStop == replaceStart - 1)
	accessor: string?, -- member: "." | ":"
	chain: Chain?, -- member: receiver chain; nil when it could not be determined
	call: SignatureContext?, -- string: the call the string is an argument of, if any
	prev: string?, -- text of the previous significant token ("local", "(", ...)
}

export type HoverContext = {
	chain: Chain, -- chain ending at the hovered name (inclusive)
	token: number,
	start: number,
	stop: number,
}

----------------------------------------------------------------------
-- token helpers
----------------------------------------------------------------------

local function isTrivia(kind: TokenKind): boolean
	return kind == "comment" or kind == "space"
end

local function prevSig(a: Adapter, i: number): number?
	local j = i - 1
	while j >= 1 do
		if not isTrivia(a.kind(j)) then
			return j
		end
		j -= 1
	end
	return nil
end

local function nextSig(a: Adapter, i: number): number?
	local n = a.count()
	local j = i + 1
	while j <= n do
		if not isTrivia(a.kind(j)) then
			return j
		end
		j += 1
	end
	return nil
end

-- i itself if it is significant, otherwise the closest significant token before it
local function skipTriviaBack(a: Adapter, i: number): number?
	local j = i
	while j >= 1 do
		if not isTrivia(a.kind(j)) then
			return j
		end
		j -= 1
	end
	return nil
end

local function isSym(a: Adapter, i: number, text: string): boolean
	return a.kind(i) == "symbol" and a.text(i) == text
end

local function isKeyword(a: Adapter, i: number, text: string): boolean
	return a.kind(i) == "keyword" and a.text(i) == text
end

-- Can token i be the end of something that is being called or indexed?
local function isCalleeEnd(a: Adapter, i: number): boolean
	local k = a.kind(i)
	if k == "name" then
		return true
	end
	return k == "symbol" and (a.text(i) == ")" or a.text(i) == "]")
end

local CLOSER_TO_OPENER: { [string]: string } = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

-- index of the bracket matching the closing bracket at closeIdx, counting only that bracket type
local function matchBackward(a: Adapter, closeIdx: number, limit: number): number?
	local closeText = a.text(closeIdx)
	local openText = CLOSER_TO_OPENER[closeText]
	if not openText then
		return nil
	end
	local depth = 0
	local i = closeIdx
	local scanned = 0
	while i >= 1 do
		if a.kind(i) == "symbol" then
			local t = a.text(i)
			if t == closeText then
				depth += 1
			elseif t == openText then
				depth -= 1
				if depth == 0 then
					return i
				end
			end
		end
		i -= 1
		scanned += 1
		if scanned > limit then
			return nil
		end
	end
	return nil
end

----------------------------------------------------------------------
-- blocks (function/do/if ... end, repeat ... until)
----------------------------------------------------------------------

-- Is the `if` at index i the start of an if-STATEMENT (closed by `end`) rather than a
-- Luau if-EXPRESSION (`x = if a then b else c`, no `end`)? Decided by the previous token:
-- an expression can only follow an operator, `(`, `,`, `=`, `return`, ...
local STATEMENT_BEFORE_IF: { [string]: boolean } = {
	["then"] = true, ["else"] = true, ["do"] = true, ["repeat"] = true, ["end"] = true,
}
local function isStatementIf(a: Adapter, i: number): boolean
	local p = prevSig(a, i)
	if not p then
		return true
	end
	local k = a.kind(p)
	if k == "name" or k == "number" or k == "string" then
		return true
	end
	local t = a.text(p)
	if k == "keyword" then
		return STATEMENT_BEFORE_IF[t] == true
	end
	return k == "symbol" and (t == ")" or t == "]" or t == "}" or t == ";")
end

-- +1 for a token that opens a block, -1 for one that closes it, else 0
local function blockDelta(a: Adapter, i: number): number
	if a.kind(i) ~= "keyword" then
		return 0
	end
	local t = a.text(i)
	if t == "function" or t == "do" or t == "repeat" then
		return 1
	elseif t == "end" or t == "until" then
		return -1
	elseif t == "if" then
		return isStatementIf(a, i) and 1 or 0
	end
	return 0
end

----------------------------------------------------------------------
-- strings
----------------------------------------------------------------------

local ESCAPES: { [string]: string } = { n = "\n", t = "\t", r = "\r", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["`"] = "`" }

local function unescape(s: string): string
	local out = string.gsub(s, "\\(.)", function(c: string): string
		return ESCAPES[c] or c
	end)
	return out
end

local function isQuote(c: string): boolean
	return c == '"' or c == "'" or c == "`"
end

local function isClosedString(text: string): boolean
	local q = string.sub(text, 1, 1)
	if isQuote(q) then
		if #text < 2 or string.sub(text, -1) ~= q then
			return false
		end
		local slashes = string.match(string.sub(text, 1, -2), "\\*$") or ""
		return #slashes % 2 == 0
	end
	local eq = string.match(text, "^%[(=*)%[")
	if eq then
		local closer = "]" .. eq .. "]"
		return #text >= #eq * 2 + 4 and string.sub(text, -#closer) == closer
	end
	return true
end

local function isClosedLongComment(text: string): boolean
	local eq = string.match(text, "^%-%-%[(=*)%[")
	if not eq then
		return false -- line comments are never "closed" at the cursor
	end
	local closer = "]" .. eq .. "]"
	return #text >= #eq * 2 + 6 and string.sub(text, -#closer) == closer
end

-- first and last index of the string's body inside the token text (quotes/brackets excluded)
local function stringBounds(text: string): (number, number)
	local q = string.sub(text, 1, 1)
	if isQuote(q) then
		return 2, isClosedString(text) and #text - 1 or #text
	end
	local eq = string.match(text, "^%[(=*)%[")
	if eq then
		return #eq + 3, isClosedString(text) and #text - (#eq + 2) or #text
	end
	return 1, #text
end

-- body text for the first n characters of the token
local function stringPrefix(text: string, n: number): string
	local s, e = stringBounds(text)
	local body = string.sub(text, s, math.min(n, e))
	if isQuote(string.sub(text, 1, 1)) then
		body = unescape(body)
	end
	return body
end

----------------------------------------------------------------------
-- chain collection
----------------------------------------------------------------------

local function newStep(a: Adapter, kind: "name" | "member" | "call" | "index" | "literal" | "group", first: number, last: number): Step
	return { kind = kind, first = first, last = last, start = a.start(first), stop = a.stop(last) }
end

-- Split the tokens between `(` at openIdx and `)` at closeIdx into top-level arguments.
local function parseArgs(a: Adapter, openIdx: number, closeIdx: number): { Arg }
	local args: { Arg } = {}
	local depth = 0
	local block = 0
	local firstIdx: number? = nil
	local lastIdx: number? = nil

	local function flush()
		if firstIdx and lastIdx then
			local arg: Arg = { first = firstIdx, last = lastIdx, start = a.start(firstIdx), stop = a.stop(lastIdx) }
			if firstIdx == lastIdx and a.kind(firstIdx) == "string" then
				local text = a.text(firstIdx)
				arg.string = stringPrefix(text, #text)
			end
			table.insert(args, arg)
		end
		firstIdx, lastIdx = nil, nil
	end

	for i = openIdx + 1, closeIdx - 1 do
		local k = a.kind(i)
		if not isTrivia(k) then
			if k == "symbol" then
				local t = a.text(i)
				if t == "(" or t == "[" or t == "{" then
					depth += 1
				elseif t == ")" or t == "]" or t == "}" then
					depth -= 1
				elseif t == "," and depth == 0 and block == 0 then
					flush()
					continue
				end
			elseif k == "keyword" then
				block += blockDelta(a, i)
			end
			if not firstIdx then
				firstIdx = i
			end
			lastIdx = i
		end
	end
	flush()
	return args
end

local function literalKeyword(text: string): boolean
	return text == "nil" or text == "true" or text == "false"
end

local collectChain: (a: Adapter, opts: ResolvedOptions, lastIdx: number, depth: number) -> Chain?

local function makeGroup(a: Adapter, opts: ResolvedOptions, open: number, close: number, depth: number): Step
	local step = newStep(a, "group", open, close)
	local innerLast = prevSig(a, close)
	if innerLast and innerLast > open then
		-- (expr :: Type) / (expr :: Type?)
		local t: number? = innerLast
		if t and isSym(a, t, "?") then
			t = prevSig(a, t)
		end
		local castPrev = t and a.kind(t) == "name" and prevSig(a, t) or nil
		if t and castPrev and isSym(a, castPrev, "::") then
			step.cast = a.text(t)
		else
			local inner = collectChain(a, opts, innerLast, depth + 1)
			-- only trust it if the chain really spans the whole parenthesised expression
			if inner and prevSig(a, inner[1].first) == open then
				step.inner = inner
			end
		end
	end
	return step
end

collectChain = function(a: Adapter, opts: ResolvedOptions, lastIdx: number, depth: number): Chain?
	if depth > opts.maxDepth then
		return nil
	end
	local rev: { Step } = {}
	local idx: number = lastIdx
	local steps = 0

	while true do
		steps += 1
		if steps > opts.maxSteps then
			return nil
		end
		local k = a.kind(idx)
		local text = a.text(idx)

		if k == "symbol" and text == ")" then
			local open = matchBackward(a, idx, opts.maxScan)
			if not open then
				return nil
			end
			local before = prevSig(a, open)
			if before and isCalleeEnd(a, before) then
				local step = newStep(a, "call", open, idx)
				local args = parseArgs(a, open, idx)
				step.args = args
				step.stringArg = args[1] and args[1].string or nil
				table.insert(rev, step)
				idx = before
			else
				-- `(expr)` that is not a call: always the root of the chain
				table.insert(rev, makeGroup(a, opts, open, idx, depth))
				break
			end
		elseif k == "symbol" and text == "]" then
			local open = matchBackward(a, idx, opts.maxScan)
			if not open then
				return nil
			end
			local before = prevSig(a, open)
			if not before or not isCalleeEnd(a, before) then
				return nil
			end
			local first, last = nextSig(a, open), prevSig(a, idx)
			local step = newStep(a, "index", open, idx)
			if first and last and first == last and a.kind(first) == "string" then
				local t = a.text(first)
				step.kind = "member"
				step.name = stringPrefix(t, #t)
				step.accessor = "[]"
			end
			table.insert(rev, step)
			idx = before
		elseif k == "name" or k == "keyword" then
			local p = prevSig(a, idx)
			if p and (isSym(a, p, ".") or isSym(a, p, ":")) then
				local step = newStep(a, "member", idx, idx)
				step.name = text
				step.accessor = a.text(p)
				table.insert(rev, step)
				local before = prevSig(a, p)
				if not before then
					return nil
				end
				idx = before
			elseif k == "name" then
				local step = newStep(a, "name", idx, idx)
				step.name = text
				table.insert(rev, step)
				break
			elseif depth > 0 and idx == lastIdx and literalKeyword(text) then
				local step = newStep(a, "literal", idx, idx)
				step.literal = text == "nil" and "nil" or "boolean"
				step.value = text
				table.insert(rev, step)
				break
			else
				return nil
			end
		elseif depth > 0 and idx == lastIdx and (k == "string" or k == "number") then
			-- only meaningful as the whole contents of a ( ) group
			local step = newStep(a, "literal", idx, idx)
			step.literal = k
			step.value = k == "string" and stringPrefix(text, #text) or text
			table.insert(rev, step)
			break
		elseif depth > 0 and idx == lastIdx and k == "symbol" and text == "}" then
			local open = matchBackward(a, idx, opts.maxScan)
			if not open then
				return nil
			end
			local step = newStep(a, "literal", open, idx)
			step.literal = "table"
			table.insert(rev, step)
			break
		else
			return nil
		end
	end

	local chain: Chain = {}
	for i = #rev, 1, -1 do
		table.insert(chain, rev[i])
	end
	return chain
end

----------------------------------------------------------------------
-- enclosing call / type-annotation detection
----------------------------------------------------------------------

type Scan = { open: number, commas: number, nearestComma: number? }

-- Walk backward from `from` to the nearest unmatched `(`.
-- `decide` is asked about each candidate: "found" | "skip" (e.g. a grouping paren) | "stop".
-- Commas that sit at the same level as the found paren are counted (for the active parameter).
-- Returns nil if we leave the enclosing block first, e.g. the cursor is in a statement inside
-- a callback passed as an argument.
local function scanForOpenParen(a: Adapter, from: number, opts: ResolvedOptions, decide: (open: number) -> "found" | "skip" | "stop"): Scan?
	local paren, bracket, brace, block = 0, 0, 0, 0
	local commas = 0
	local nearest: number? = nil
	local i = from
	local scanned = 0

	while i >= 1 do
		scanned += 1
		if scanned > opts.maxScan then
			return nil
		end
		local k = a.kind(i)
		if k == "symbol" then
			local t = a.text(i)
			if t == ")" then
				paren += 1
			elseif t == "(" then
				if paren > 0 then
					paren -= 1
				else
					local verdict = decide(i)
					if verdict == "found" then
						return { open = i, commas = commas, nearestComma = nearest }
					elseif verdict == "stop" then
						return nil
					end
					commas, nearest = 0, nil
				end
			elseif t == "]" then
				bracket += 1
			elseif t == "[" then
				if bracket > 0 then
					bracket -= 1
				else
					commas, nearest = 0, nil -- we were inside an index; commas belonged to it
				end
			elseif t == "}" then
				brace += 1
			elseif t == "{" then
				if brace > 0 then
					brace -= 1
				else
					commas, nearest = 0, nil -- we were inside a table; commas belonged to it
				end
			elseif t == "," then
				if paren == 0 and bracket == 0 and brace == 0 and block == 0 then
					commas += 1
					if not nearest then
						nearest = i
					end
				end
			end
		elseif k == "keyword" then
			local d = blockDelta(a, i)
			if d < 0 then
				block += 1 -- an `end` going backward opens a nested (already closed) block
			elseif d > 0 then
				if block > 0 then
					block -= 1
				else
					return nil -- inside an unclosed block: a statement, not an argument
				end
			end
		end
		i -= 1
	end
	return nil
end

-- Is the `(` at openIdx the parameter list of a function declaration?
local function isFunctionHeaderParen(a: Adapter, openIdx: number): boolean
	local p = prevSig(a, openIdx)
	if not p then
		return false
	end
	if isKeyword(a, p, "function") then
		return true -- function(...)
	end
	if a.kind(p) ~= "name" then
		return false
	end
	-- function a.b:c(   -> walk back over the name path
	local j = p
	while true do
		local q = prevSig(a, j)
		if q and (isSym(a, q, ".") or isSym(a, q, ":")) then
			local r = prevSig(a, q)
			if r and a.kind(r) == "name" then
				j = r
			else
				return false
			end
		else
			return q ~= nil and isKeyword(a, q, "function")
		end
	end
end

-- Is the `:` at colonIdx a type annotation colon rather than a method-call colon?
local function isTypeColon(a: Adapter, opts: ResolvedOptions, colonIdx: number): boolean
	local n = prevSig(a, colonIdx)
	if not n then
		return false
	end
	if isSym(a, n, ")") then
		-- function f(...): ReturnType
		local open = matchBackward(a, n, opts.maxScan)
		return open ~= nil and isFunctionHeaderParen(a, open)
	end
	if a.kind(n) == "name" then
		local b = prevSig(a, n)
		if not b then
			return false
		end
		if isKeyword(a, b, "local") then
			return true -- local x: Type
		end
		if isSym(a, b, "(") or isSym(a, b, ",") then
			-- parameter?  function(a, b: Type)
			local scan = scanForOpenParen(a, colonIdx, opts, function()
				return "found"
			end)
			return scan ~= nil and isFunctionHeaderParen(a, scan.open)
		end
	end
	return false
end

----------------------------------------------------------------------
-- locating the cursor
----------------------------------------------------------------------

-- Last token that has at least one character before `cursor`, and where the cursor sits:
--   "inside" strictly inside the token, "end" right after its last char, "after" later
local function locate(a: Adapter, cursor: number): (number?, string)
	local lo, hi = 1, a.count()
	local found: number? = nil
	while lo <= hi do
		local mid = (lo + hi) // 2
		if a.start(mid) < cursor then
			found = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	if not found then
		return nil, "none"
	end
	local stop = a.stop(found)
	if cursor <= stop then
		return found, "inside"
	elseif cursor == stop + 1 then
		return found, "end"
	end
	return found, "after"
end

----------------------------------------------------------------------
-- public API
----------------------------------------------------------------------

local ChainCollector = {}
ChainCollector.__index = ChainCollector

export type ChainCollector = typeof(setmetatable({} :: { adapter: Adapter, opts: ResolvedOptions }, ChainCollector))

function ChainCollector.new(adapter: Adapter, options: Options?): ChainCollector
	local o: Options = options or {}
	return setmetatable({
		adapter = adapter,
		opts = {
			maxScan = o.maxScan or 4000,
			maxSteps = o.maxSteps or 64,
			maxDepth = o.maxDepth or 8,
		},
	}, ChainCollector)
end

-- Adapter over a flat array of token tables.
function ChainCollector.fromTokenArray(
	tokens: { any },
	map: { fields: { kind: string?, text: string?, start: string?, stop: string? }?, kinds: { [string]: TokenKind }? }?,
	options: Options?
): ChainCollector
	local fields: { kind: string?, text: string?, start: string?, stop: string? } = (map and map.fields) or {}
	local kinds = map and map.kinds
	local fKind = fields.kind or "kind"
	local fText = fields.text or "text"
	local fStart = fields.start or "start"
	local fStop = fields.stop or "stop"
	local adapter: Adapter = {
		count = function()
			return #tokens
		end,
		kind = function(i)
			local k = tokens[i][fKind]
			if kinds then
				return kinds[k] or "other"
			end
			return k
		end,
		text = function(i)
			return tokens[i][fText]
		end,
		start = function(i)
			return tokens[i][fStart]
		end,
		stop = function(i)
			return tokens[i][fStop]
		end,
	}
	return ChainCollector.new(adapter, options)
end

-- Decoded body of a string token's text ("abc", 'abc', [[abc]]); simple escapes only.
function ChainCollector.decodeString(text: string): string
	return stringPrefix(text, #text)
end

-- Chain ending at token index `tokenIndex` (inclusive). Handy for resolving the initializer
-- of a `local x = <expr>` once you know the last token of <expr>.
function ChainCollector.chainEndingAt(self: ChainCollector, tokenIndex: number): Chain?
	return collectChain(self.adapter, self.opts, tokenIndex, 0)
end

local function memberContext(
	self: ChainCollector,
	accessorIdx: number,
	partial: string,
	anchor: number,
	replaceStart: number,
	replaceStop: number
): CompletionContext
	local a = self.adapter
	local accessor = a.text(accessorIdx)
	local ctx: CompletionContext = {
		kind = "member",
		partial = partial,
		anchor = anchor,
		replaceStart = replaceStart,
		replaceStop = replaceStop,
		accessor = accessor,
	}
	if accessor == ":" and isTypeColon(a, self.opts, accessorIdx) then
		ctx.kind = "type"
		ctx.accessor = nil
		return ctx
	end
	local receiverEnd = prevSig(a, accessorIdx)
	if receiverEnd then
		ctx.chain = collectChain(a, self.opts, receiverEnd, 0)
	end
	return ctx
end

-- What should be completed at `cursor`?  nil when completion makes no sense (comment, number...).
function ChainCollector.forCompletion(self: ChainCollector, cursor: number): CompletionContext?
	local a = self.adapter
	local i, rel = locate(a, cursor)
	if not i then
		return { kind = "identifier", partial = "", anchor = 1, replaceStart = cursor, replaceStop = cursor - 1 }
	end

	local k = a.kind(i)
	local touching = rel ~= "after"

	-- comments and whitespace tokens: either we are inside one, or step back to real code
	if isTrivia(k) then
		if k == "comment" and (rel == "inside" or (rel == "end" and not isClosedLongComment(a.text(i)))) then
			return nil
		end
		local j = skipTriviaBack(a, i)
		if not j then
			return { kind = "identifier", partial = "", anchor = 1, replaceStart = cursor, replaceStop = cursor - 1 }
		end
		i, k, touching = j, a.kind(j), false
	end
	local text = a.text(i)

	if k == "string" and touching then
		if rel == "inside" or not isClosedString(text) then
			local start = a.start(i)
			local s, e = stringBounds(text)
			return {
				kind = "string",
				anchor = i,
				partial = stringPrefix(text, cursor - start),
				replaceStart = start + s - 1,
				replaceStop = start + e - 1,
				call = self:forSignature(cursor),
			}
		end
		return nil -- directly after a closed string literal
	end

	if k == "number" and touching then
		return nil
	end
	-- (a string or number followed by whitespace / a newline falls through: a new statement may start here)

	if (k == "name" or k == "keyword") and touching then
		local start = a.start(i)
		local partial = string.sub(text, 1, cursor - start)
		local stop = a.stop(i)
		local p = prevSig(a, i)
		if p and a.kind(p) == "symbol" then
			local pt = a.text(p)
			if pt == "." or pt == ":" then
				return memberContext(self, p, partial, i, start, stop)
			elseif pt == "::" then
				return { kind = "type", partial = partial, anchor = i, replaceStart = start, replaceStop = stop, prev = pt }
			end
		end
		return {
			kind = "identifier",
			partial = partial,
			anchor = i,
			replaceStart = start,
			replaceStop = stop,
			prev = p and a.text(p) or nil,
		}
	end

	if k == "symbol" then
		if text == "." or text == ":" then
			return memberContext(self, i, "", i + 1, cursor, cursor - 1)
		elseif text == "::" then
			return { kind = "type", partial = "", anchor = i + 1, replaceStart = cursor, replaceStop = cursor - 1, prev = text }
		elseif rel == "inside" then
			return nil -- cursor in the middle of a multi-character operator
		end
	end

	return { kind = "identifier", partial = "", anchor = i + 1, replaceStart = cursor, replaceStop = cursor - 1, prev = text }
end

-- Which call is the cursor inside, and which argument is it on?
function ChainCollector.forSignature(self: ChainCollector, cursor: number): SignatureContext?
	local a, opts = self.adapter, self.opts
	local i, rel = locate(a, cursor)
	if not i then
		return nil
	end
	if a.kind(i) == "comment" and (rel == "inside" or (rel == "end" and not isClosedLongComment(a.text(i)))) then
		return nil
	end

	local scan = scanForOpenParen(a, i, opts, function(open)
		local before = prevSig(a, open)
		if not before then
			return "skip"
		end
		if isCalleeEnd(a, before) then
			return "found"
		end
		if isKeyword(a, before, "function") then
			return "stop" -- parameter list of an anonymous function
		end
		return "skip" -- plain grouping parenthesis
	end)
	if not scan then
		return nil
	end

	local before = prevSig(a, scan.open)
	if not before then
		return nil
	end
	local callee = collectChain(a, opts, before, 0)
	if not callee then
		return nil
	end
	-- `function name(` is a declaration, not a call
	local rootPrev = prevSig(a, callee[1].first)
	if rootPrev and isKeyword(a, rootPrev, "function") then
		return nil
	end

	-- is the current argument just one string literal?
	local stringArg: string? = nil
	local argStart = scan.nearestComma or scan.open
	local firstTok = nextSig(a, argStart)
	if firstTok and firstTok <= i and a.kind(firstTok) == "string" then
		local after = nextSig(a, firstTok)
		if after == nil or after > i then
			stringArg = stringPrefix(a.text(firstTok), cursor - a.start(firstTok))
		end
	end

	local last = callee[#callee]
	return {
		callee = callee,
		isMethod = last.kind == "member" and last.accessor == ":",
		activeParam = scan.commas + 1,
		openParen = scan.open,
		argStart = argStart,
		stringArg = stringArg,
	}
end

-- Chain for the name under the pointer. `charIndex` is the index of the hovered character.
function ChainCollector.forHover(self: ChainCollector, charIndex: number): HoverContext?
	local a = self.adapter
	local lo, hi = 1, a.count()
	local found: number? = nil
	while lo <= hi do
		local mid = (lo + hi) // 2
		if a.start(mid) <= charIndex then
			found = mid
			lo = mid + 1
		else
			hi = mid - 1
		end
	end
	if not found or a.stop(found) < charIndex or a.kind(found) ~= "name" then
		return nil
	end
	local chain = collectChain(a, self.opts, found, 0)
	if not chain then
		return nil
	end
	return { chain = chain, token = found, start = a.start(found), stop = a.stop(found) }
end

-- Source-like rendering of a chain, for logging and tests:  workspace.Map:Find("x")(...)
function ChainCollector.format(chain: Chain): string
	local out: { string } = {}
	for _, s in chain do
		if s.kind == "name" then
			table.insert(out, s.name or "?")
		elseif s.kind == "member" then
			if s.accessor == "[]" then
				table.insert(out, string.format("[%q]", s.name or ""))
			else
				table.insert(out, (s.accessor or ".") .. (s.name or "?"))
			end
		elseif s.kind == "call" then
			local parts: { string } = {}
			for _, arg in s.args or {} do
				table.insert(parts, arg.string and string.format("%q", arg.string) or "_")
			end
			table.insert(out, "(" .. table.concat(parts, ", ") .. ")")
		elseif s.kind == "index" then
			table.insert(out, "[?]")
		elseif s.kind == "literal" then
			table.insert(out, s.literal == "string" and string.format("%q", s.value or "") or (s.value or s.literal or "?"))
		elseif s.kind == "group" then
			local inner = s.cast and ("_ :: " .. s.cast) or (s.inner and ChainCollector.format(s.inner)) or "?"
			table.insert(out, "(" .. inner .. ")")
		end
	end
	return table.concat(out)
end

return ChainCollector
