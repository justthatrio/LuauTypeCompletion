--!strict
--[[
	ScopeFinder
	===========

	Token-level scope analysis. It answers purely SYNTACTIC questions and knows
	nothing about types:

	  find(name, before)    nearest declaration of `name` visible to a use at token `before`
	  visible(before)       every declaration visible there (nearest first, shadowed names removed)
	  exprAt(first)         extent and shape of the expression starting at token `first`
	  functionAt(fnToken)   parameters / return annotation of a function header
	  tableFields(open)     fields of a table constructor

	`before` is a token index: only tokens with index < before are considered. For
	an identifier use pass that identifier's token index; for a cursor use
	CompletionContext.anchor from ChainCollector.

	Like ChainCollector it walks BACKWARD and locally, so it works on broken code
	and costs time proportional to the distance back to the declaration.

	Declarations understood
	  local a, b: T = e1, e2      local function f(...)     function f(...)   (plain name)
	  function(a, b: T)           function A.B:m(...)  (implicit `self`)
	  for i = a, b do             for k, v in expr do

	Scoping rules implemented: block scope (function/do/if/repeat ... end), locals
	visible only after their statement, `local function` visible inside its own
	body, locals from an earlier if-branch not visible in else/elseif branches.

	Known limits (all fail towards "not found", never towards a wrong binding)
	  * assignments after the declaration (x = other) are ignored
	  * a `repeat ... until cond` body's locals are not visible inside `cond`
	  * `else if` is treated as a statement, `if` after an operator as an expression
	  * type annotations are only understood as simple dotted names with an
	    optional `?`; anything else yields a TypeRef with path = nil
	  * `f"str"` / `f{...}` call sugar is classified as kind "other"

	No requires on purpose: pass any adapter that has count/kind/text.
	(blockDelta / isStatementIf are intentionally duplicated from ChainCollector
	to keep both modules standalone.)
]]

export type TokenKind = "name" | "keyword" | "string" | "number" | "symbol" | "comment" | "space" | "other"

export type Adapter = {
	count: () -> number,
	kind: (i: number) -> TokenKind,
	text: (i: number) -> string,
}

export type Options = { maxScan: number? }

-- A type annotation as written. `path` is set for simple (dotted) names, e.g. "Player", "Types.Foo".
export type TypeRef = {
	first: number,
	last: number,
	path: string?,
	optional: boolean,
}

export type Param = {
	name: string,
	token: number,
	annotation: TypeRef?,
	vararg: boolean,
}

export type FunctionInfo = {
	functionToken: number, -- the `function` keyword
	anonymous: boolean,
	nameToken: number?, -- last token of the declared name
	isMethod: boolean, -- declared with `:`, so there is an implicit `self`
	ownerFirst: number?, -- tokens of `A.B` in `function A.B:m()` (the type of `self`)
	ownerLast: number?,
	openParen: number,
	closeParen: number,
	params: { Param },
	returnType: TypeRef?,
}

export type ExprKind = "chain" | "literal" | "table" | "function" | "cast" | "other"

-- first/last are the token range of the WHOLE expression.
--   chain    a pure name/call/index chain, e.g. a.b:c(1)[2]   (also a bare `(expr)` group)
--   literal  one string / number / true / false / nil token
--   table    a `{ ... }` constructor (first = `{`, last = `}`)
--   function an anonymous function expression (fn is filled in)
--   cast     <operand> :: Type          (cast is filled in)
--   other    anything with operators, if-expressions, call sugar, ...
export type ExprRange = {
	first: number,
	last: number,
	kind: ExprKind,
	cast: TypeRef?,
	fn: FunctionInfo?,
}

export type TableField = {
	name: string?, -- nil for positional fields and non-literal keys
	valueFirst: number, -- first token of the value expression
}

export type DeclKind = "local" | "localFunction" | "function" | "param" | "forNumeric" | "forIn"

export type Declaration = {
	name: string,
	kind: DeclKind,
	token: number, -- the name token (unique per declared name)
	annotation: TypeRef?,
	index: number, -- 1-based position among the names declared together
	count: number,
	init: ExprRange?, -- local: expression for this name; forIn: first iterator expression; forNumeric: start value
	initCount: number?, -- local: how many expressions were on the right-hand side
	fn: FunctionInfo?, -- function kinds and params
	paramIndex: number?,
	isSelf: boolean?,
}

local SCAN_LIMIT = 20000

----------------------------------------------------------------------
-- token helpers
----------------------------------------------------------------------

local function isTrivia(k: TokenKind): boolean
	return k == "comment" or k == "space"
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

local function isSym(a: Adapter, i: number, text: string): boolean
	return a.kind(i) == "symbol" and a.text(i) == text
end

local function isKeyword(a: Adapter, i: number, text: string): boolean
	return a.kind(i) == "keyword" and a.text(i) == text
end

local PAIRS: { [string]: string } = { ["("] = ")", ["["] = "]", ["{"] = "}", ["<"] = ">" }

local function matchForward(a: Adapter, openIdx: number): number?
	local openText = a.text(openIdx)
	local closeText = PAIRS[openText]
	if not closeText then
		return nil
	end
	local n = a.count()
	local depth = 0
	local i = openIdx
	while i <= n and i - openIdx <= SCAN_LIMIT do
		if a.kind(i) == "symbol" then
			local t = a.text(i)
			if t == openText then
				depth += 1
			elseif t == closeText then
				depth -= 1
				if depth == 0 then
					return i
				end
			end
		end
		i += 1
	end
	return nil
end

-- same rule as ChainCollector: an `if` that follows an operand / statement boundary starts a statement
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

-- the `end` that closes the block opened at openIdx
local function blockEnd(a: Adapter, openIdx: number): number?
	local n = a.count()
	local depth = 0
	local i = openIdx
	while i <= n and i - openIdx <= SCAN_LIMIT do
		if a.kind(i) == "keyword" then
			depth += blockDelta(a, i)
			if depth == 0 then
				return i
			end
		end
		i += 1
	end
	return nil
end

----------------------------------------------------------------------
-- types (annotations)
----------------------------------------------------------------------

local function typeRef(a: Adapter, first: number, last: number): TypeRef
	local parts: { string } = {}
	local optional = false
	local ok = true
	local expectName = true
	local j: number? = first
	while j and j <= last do
		if expectName then
			if a.kind(j) == "name" then
				table.insert(parts, a.text(j))
				expectName = false
			else
				ok = false
				break
			end
		elseif isSym(a, j, ".") then
			expectName = true
		elseif isSym(a, j, "?") and j == last then
			optional = true
		else
			ok = false
			break
		end
		j = nextSig(a, j)
	end
	if expectName then
		ok = false
	end
	return { first = first, last = last, path = ok and table.concat(parts, ".") or nil, optional = optional }
end

local skipType: (a: Adapter, first: number) -> number?

local function skipTypeAtom(a: Adapter, i: number): number?
	local k = a.kind(i)
	local t = a.text(i)
	local last: number = i
	if k == "name" then
		while true do
			local d = nextSig(a, last)
			local nn = if d and isSym(a, d, ".") then nextSig(a, d) else nil
			if nn and a.kind(nn) == "name" then
				last = nn
			else
				break
			end
		end
		local g = nextSig(a, last)
		if g and (isSym(a, g, "<") or (t == "typeof" and isSym(a, g, "("))) then
			local e = matchForward(a, g)
			if e then
				last = e
			end
		end
	elseif k == "string" or (k == "keyword" and (t == "nil" or t == "true" or t == "false")) then
		last = i
	elseif k == "symbol" and (t == "{" or t == "(") then
		local e = matchForward(a, i)
		if not e then
			return nil
		end
		last = e
		if t == "(" then
			local arrow = nextSig(a, last)
			if arrow and isSym(a, arrow, "->") then
				local r = nextSig(a, arrow)
				local rl = if r then skipType(a, r) else nil
				if rl then
					last = rl
				end
			end
		end
	else
		return nil
	end
	while true do
		local q = nextSig(a, last)
		if q and isSym(a, q, "?") then
			last = q
		else
			break
		end
	end
	return last
end

skipType = function(a: Adapter, first: number): number?
	local last = skipTypeAtom(a, first)
	if not last then
		return nil
	end
	while true do
		local op = nextSig(a, last)
		if op and (isSym(a, op, "|") or isSym(a, op, "&")) then
			local nx = nextSig(a, op)
			local l2 = if nx then skipTypeAtom(a, nx) else nil
			if l2 then
				last = l2
			else
				break
			end
		else
			break
		end
	end
	return last
end

----------------------------------------------------------------------
-- class
----------------------------------------------------------------------

local ScopeFinder = {}
ScopeFinder.__index = ScopeFinder

export type ScopeFinder = typeof(setmetatable({} :: { adapter: Adapter, maxScan: number }, ScopeFinder))

function ScopeFinder.new(adapter: Adapter, options: Options?): ScopeFinder
	local o: Options = options or {}
	return setmetatable({ adapter = adapter, maxScan = o.maxScan or 50000 }, ScopeFinder)
end

----------------------------------------------------------------------
-- function headers
----------------------------------------------------------------------

local function parseFunction(self: ScopeFinder, fIdx: number): FunctionInfo?
	local a = self.adapter
	if not isKeyword(a, fIdx, "function") then
		return nil
	end
	local anonymous = true
	local isMethod = false
	local nameToken: number? = nil
	local ownerFirst: number? = nil
	local ownerLast: number? = nil

	local j = nextSig(a, fIdx)
	if j and a.kind(j) == "name" then
		anonymous = false
		local first = j
		local last = j
		while true do
			local n = nextSig(a, last)
			if not n then
				break
			end
			local nn = nextSig(a, n)
			if isSym(a, n, ".") and nn and a.kind(nn) == "name" then
				last = nn
			elseif isSym(a, n, ":") and nn and a.kind(nn) == "name" then
				isMethod = true
				ownerFirst, ownerLast = first, last
				last = nn
				break
			else
				break
			end
		end
		nameToken = last
		j = nextSig(a, last)
	end

	if j and isSym(a, j, "<") then -- generics: function f<T>(...)
		local e = matchForward(a, j)
		j = if e then nextSig(a, e) else nil
	end
	if not j or not isSym(a, j, "(") then
		return nil
	end
	local openParen = j
	local closeParen = matchForward(a, openParen)
	if not closeParen then
		return nil
	end

	local params: { Param } = {}
	local cur = nextSig(a, openParen)
	while cur and cur < closeParen do
		if isSym(a, cur, "...") then
			table.insert(params, { name = "...", token = cur, vararg = true })
			cur = nextSig(a, cur)
		elseif a.kind(cur) == "name" then
			local param: Param = { name = a.text(cur), token = cur, vararg = false }
			local n = nextSig(a, cur)
			if n and n < closeParen and isSym(a, n, ":") then
				local tf = nextSig(a, n)
				local tl = if tf then skipType(a, tf) else nil
				if tf and tl then
					param.annotation = typeRef(a, tf, tl)
					n = nextSig(a, tl)
				else
					n = nil
				end
			end
			table.insert(params, param)
			cur = n
		else
			break
		end
		if cur and cur < closeParen and isSym(a, cur, ",") then
			cur = nextSig(a, cur)
		end
	end

	local returnType: TypeRef? = nil
	local after = nextSig(a, closeParen)
	if after and isSym(a, after, ":") then
		local rf = nextSig(a, after)
		local rl = if rf then skipType(a, rf) else nil
		if rf and rl then
			returnType = typeRef(a, rf, rl)
		end
	end

	return {
		functionToken = fIdx,
		anonymous = anonymous,
		nameToken = nameToken,
		isMethod = isMethod,
		ownerFirst = ownerFirst,
		ownerLast = ownerLast,
		openParen = openParen,
		closeParen = closeParen,
		params = params,
		returnType = returnType,
	}
end

----------------------------------------------------------------------
-- expressions
----------------------------------------------------------------------

local BINARY_SYMBOLS: { [string]: boolean } = {
	["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["//"] = true, ["%"] = true, ["^"] = true,
	[".."] = true, ["=="] = true, ["~="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true,
}

local function isBinaryOp(a: Adapter, i: number): boolean
	local k = a.kind(i)
	local t = a.text(i)
	if k == "symbol" then
		return BINARY_SYMBOLS[t] == true
	end
	return k == "keyword" and (t == "and" or t == "or")
end

local exprAt: (self: ScopeFinder, first: number, depth: number) -> ExprRange?
local skipOperand: (self: ScopeFinder, first: number, depth: number) -> (number?, ExprKind)

-- Luau if-expression: if c then a [elseif c then a]* else b
local function skipIfExpr(self: ScopeFinder, first: number, depth: number): number?
	local a = self.adapter
	local cf = nextSig(a, first)
	local c = if cf then exprAt(self, cf, depth + 1) else nil
	if not c then
		return first
	end
	local th = nextSig(a, c.last)
	if not th or not isKeyword(a, th, "then") then
		return c.last
	end
	local vf = nextSig(a, th)
	local v = if vf then exprAt(self, vf, depth + 1) else nil
	if not v then
		return th
	end
	local last = v.last
	while true do
		local n = nextSig(a, last)
		if n and isKeyword(a, n, "elseif") then
			local c2f = nextSig(a, n)
			local c2 = if c2f then exprAt(self, c2f, depth + 1) else nil
			if not c2 then
				return n
			end
			local th2 = nextSig(a, c2.last)
			if not th2 or not isKeyword(a, th2, "then") then
				return c2.last
			end
			local v2f = nextSig(a, th2)
			local v2 = if v2f then exprAt(self, v2f, depth + 1) else nil
			if not v2 then
				return th2
			end
			last = v2.last
		elseif n and isKeyword(a, n, "else") then
			local v3f = nextSig(a, n)
			local v3 = if v3f then exprAt(self, v3f, depth + 1) else nil
			return if v3 then v3.last else n
		else
			return last
		end
	end
end

skipOperand = function(self: ScopeFinder, first: number, depth: number): (number?, ExprKind)
	local a = self.adapter
	if depth > 24 then
		return nil, "other"
	end
	local k = a.kind(first)
	local t = a.text(first)
	local idx: number = first

	if k == "name" then
		idx = first
	elseif k == "number" or k == "string" then
		return first, "literal"
	elseif k == "keyword" then
		if t == "nil" or t == "true" or t == "false" then
			return first, "literal"
		elseif t == "function" then
			return blockEnd(a, first), "function"
		elseif t == "not" then
			local n = nextSig(a, first)
			if not n then
				return nil, "other"
			end
			local e = skipOperand(self, n, depth + 1)
			return e, "other"
		elseif t == "if" then
			return skipIfExpr(self, first, depth), "other"
		end
		return nil, "other"
	elseif k == "symbol" then
		if t == "{" then
			return matchForward(a, first), "table"
		elseif t == "-" or t == "#" then
			local n = nextSig(a, first)
			if not n then
				return nil, "other"
			end
			local e = skipOperand(self, n, depth + 1)
			return e, "other"
		elseif t == "..." then
			return first, "other"
		elseif t == "(" then
			local e = matchForward(a, first)
			if not e then
				return nil, "other"
			end
			idx = e
		else
			return nil, "other"
		end
	else
		return nil, "other"
	end

	-- suffixes: .name  :name  [..]  (..)   (and f"x" / f{..} sugar, which ends the chain)
	local kind: ExprKind = "chain"
	while true do
		local n = nextSig(a, idx)
		if not n then
			break
		end
		if isSym(a, n, ".") or isSym(a, n, ":") then
			local nn = nextSig(a, n)
			if nn and a.kind(nn) == "name" then
				idx = nn
			else
				break
			end
		elseif isSym(a, n, "(") or isSym(a, n, "[") then
			local e = matchForward(a, n)
			if not e then
				break
			end
			idx = e
		elseif a.kind(n) == "string" then
			idx = n
			kind = "other"
			break
		elseif isSym(a, n, "{") then
			local e = matchForward(a, n)
			if e then
				idx = e
			end
			kind = "other"
			break
		else
			break
		end
	end
	return idx, kind
end

exprAt = function(self: ScopeFinder, first: number, depth: number): ExprRange?
	local a = self.adapter
	if first < 1 or first > a.count() then
		return nil
	end
	local last, kind = skipOperand(self, first, depth)
	if not last then
		return nil
	end

	local cast: TypeRef? = nil
	local c = nextSig(a, last)
	if c and isSym(a, c, "::") then
		local tf = nextSig(a, c)
		local tl = if tf then skipType(a, tf) else nil
		if tf and tl then
			cast = typeRef(a, tf, tl)
			last = tl
			kind = "cast"
		end
	end

	while true do
		local op = nextSig(a, last)
		if not (op and isBinaryOp(a, op)) then
			break
		end
		local rf = nextSig(a, op)
		if not rf then
			break
		end
		local rl = skipOperand(self, rf, depth + 1)
		if not rl then
			break
		end
		last = rl
		kind = "other"
		cast = nil
		local c2 = nextSig(a, last)
		if c2 and isSym(a, c2, "::") then
			local tf = nextSig(a, c2)
			local tl = if tf then skipType(a, tf) else nil
			if tl then
				last = tl
			end
		end
	end

	local range: ExprRange = { first = first, last = last, kind = kind, cast = cast }
	if kind == "function" then
		range.fn = parseFunction(self, first)
	end
	return range
end

----------------------------------------------------------------------
-- declarations
----------------------------------------------------------------------

type LocalParse = { decls: { Declaration }, listEnd: number }

-- names with optional `: Type`, starting at token `start`. Returns the names and the token after them.
type NameList = { names: { { tok: number, ref: TypeRef? } }, last: number, after: number? }
local function parseNames(a: Adapter, start: number): NameList
	local names: { { tok: number, ref: TypeRef? } } = {}
	local last = start
	local cur: number? = start
	while cur and a.kind(cur) == "name" do
		local nameTok = cur
		local ref: TypeRef? = nil
		last = cur
		local n = nextSig(a, cur)
		if n and isSym(a, n, ":") then
			local tf = nextSig(a, n)
			local tl = if tf then skipType(a, tf) else nil
			if tf and tl then
				ref = typeRef(a, tf, tl)
				last = tl
				n = nextSig(a, tl)
			end
		end
		table.insert(names, { tok = nameTok, ref = ref })
		if n and isSym(a, n, ",") then
			cur = nextSig(a, n)
		else
			cur = n
			break
		end
	end
	return { names = names, last = last, after = cur }
end

local function parseLocal(self: ScopeFinder, localIdx: number): LocalParse?
	local a = self.adapter
	local j = nextSig(a, localIdx)
	if not j then
		return nil
	end
	if isKeyword(a, j, "function") then
		local nameTok = nextSig(a, j)
		if not (nameTok and a.kind(nameTok) == "name") then
			return nil
		end
		local decl: Declaration = {
			name = a.text(nameTok),
			kind = "localFunction",
			token = nameTok,
			index = 1,
			count = 1,
			fn = parseFunction(self, j),
		}
		-- visible inside its own body
		return { decls = { decl }, listEnd = nameTok }
	end

	local list = parseNames(a, j)
	if #list.names == 0 then
		return nil
	end
	local last = list.last
	local ranges: { ExprRange } = {}
	local eq = list.after
	if eq and isSym(a, eq, "=") then
		local f = nextSig(a, eq)
		while f do
			local r = exprAt(self, f, 0)
			if not r then
				break
			end
			table.insert(ranges, r)
			last = r.last
			local n = nextSig(a, r.last)
			if n and isSym(a, n, ",") then
				f = nextSig(a, n)
			else
				break
			end
		end
	end

	local decls: { Declaration } = {}
	for idx, nm in list.names do
		local d: Declaration = {
			name = a.text(nm.tok),
			kind = "local",
			token = nm.tok,
			annotation = nm.ref,
			index = idx,
			count = #list.names,
			init = ranges[idx],
			initCount = #ranges,
		}
		table.insert(decls, d)
	end
	return { decls = decls, listEnd = last }
end

local function parseFor(self: ScopeFinder, forIdx: number): { Declaration }
	local a = self.adapter
	local j = nextSig(a, forIdx)
	local decls: { Declaration } = {}
	if not j then
		return decls
	end
	local list = parseNames(a, j)
	if #list.names == 0 then
		return decls
	end
	local after = list.after
	local kind: DeclKind = "forIn"
	local init: ExprRange? = nil
	if after and isSym(a, after, "=") then
		kind = "forNumeric"
		local f = nextSig(a, after)
		init = if f then exprAt(self, f, 0) else nil
	elseif after and isKeyword(a, after, "in") then
		local f = nextSig(a, after)
		init = if f then exprAt(self, f, 0) else nil
	else
		return decls
	end
	for idx, nm in list.names do
		local d: Declaration = {
			name = a.text(nm.tok),
			kind = kind,
			token = nm.tok,
			annotation = nm.ref,
			index = idx,
			count = #list.names,
			init = init,
		}
		table.insert(decls, d)
	end
	return decls
end

-- The `for` keyword of the loop whose `do` is at doIdx, or nil for `while` / bare `do`.
local HEADER_STOP: { [string]: boolean } = {
	["end"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true, ["do"] = true, ["repeat"] = true,
	["until"] = true, ["local"] = true, ["return"] = true, ["break"] = true, ["function"] = true, ["while"] = true,
}
local function loopHeaderFor(a: Adapter, doIdx: number): number?
	local depth = 0
	local i = doIdx - 1
	local scanned = 0
	while i >= 1 and scanned < 400 do
		scanned += 1
		local k = a.kind(i)
		if k == "symbol" then
			local t = a.text(i)
			if t == ")" or t == "]" or t == "}" then
				depth += 1
			elseif t == "(" or t == "[" or t == "{" then
				if depth == 0 then
					return nil
				end
				depth -= 1
			end
		elseif k == "keyword" and depth == 0 then
			local t = a.text(i)
			if t == "for" then
				return i
			elseif HEADER_STOP[t] then
				return nil
			end
		end
		i -= 1
	end
	return nil
end

----------------------------------------------------------------------
-- public: scanning
----------------------------------------------------------------------

-- Visit declarations visible before token `before`, nearest first. `visit` returns true to stop.
local function scan(self: ScopeFinder, before: number, visit: (Declaration) -> boolean)
	local a = self.adapter
	local skip = 0 -- closed blocks we are currently skipping over (going backward)
	local elseFlag = false -- we came from an else/elseif branch: skip the earlier branch
	local i = math.min(before, a.count() + 1) - 1
	local scanned = 0

	while i >= 1 do
		scanned += 1
		if scanned > self.maxScan then
			return
		end
		if a.kind(i) == "keyword" then
			local t = a.text(i)
			if t == "end" or t == "until" then
				skip += 1
			elseif t == "else" or t == "elseif" then
				if skip == 0 then
					elseFlag = true
				end
			elseif t == "if" then
				if skip == 0 then
					elseFlag = false -- pairs with the else/elseif we came through (statement or expression)
				end
				if isStatementIf(a, i) and skip > 0 then
					skip -= 1
				end
			elseif t == "function" or t == "do" or t == "repeat" then
				if skip > 0 then
					skip -= 1
					if skip == 0 and t == "function" and not elseFlag then
						-- a sibling `function name(...)` declaration that we are past
						local nameTok = nextSig(a, i)
						local prev = prevSig(a, i)
						local after = if nameTok then nextSig(a, nameTok) else nil
						if
							nameTok
							and a.kind(nameTok) == "name"
							and after
							and (isSym(a, after, "(") or isSym(a, after, "<"))
							and not (prev and isKeyword(a, prev, "local"))
						then
							local decl: Declaration = {
								name = a.text(nameTok),
								kind = "function",
								token = nameTok,
								index = 1,
								count = 1,
								fn = parseFunction(self, i),
							}
							if visit(decl) then
								return
							end
						end
					end
				elseif not elseFlag then
					-- we are INSIDE this block: its header bindings are in scope
					if t == "function" then
						local fn = parseFunction(self, i)
						if fn then
							for p = #fn.params, 1, -1 do
								local prm = fn.params[p]
								if not prm.vararg then
									local decl: Declaration = {
										name = prm.name,
										kind = "param",
										token = prm.token,
										annotation = prm.annotation,
										index = p,
										count = #fn.params,
										fn = fn,
										paramIndex = p,
									}
									if visit(decl) then
										return
									end
								end
							end
							if fn.isMethod then
								local selfDecl: Declaration = {
									name = "self",
									kind = "param",
									token = fn.functionToken,
									index = 0,
									count = 0,
									fn = fn,
									isSelf = true,
								}
								if visit(selfDecl) then
									return
								end
							end
						end
					elseif t == "do" then
						local forIdx = loopHeaderFor(a, i)
						if forIdx then
							local decls = parseFor(self, forIdx)
							for d = #decls, 1, -1 do
								if visit(decls[d]) then
									return
								end
							end
						end
					end
				end
			elseif t == "local" and skip == 0 and not elseFlag then
				local parsed = parseLocal(self, i)
				if parsed and before > parsed.listEnd then
					for d = #parsed.decls, 1, -1 do
						if visit(parsed.decls[d]) then
							return
						end
					end
				end
			end
		end
		i -= 1
	end
end

function ScopeFinder.find(self: ScopeFinder, name: string, before: number): Declaration?
	local found: Declaration? = nil
	scan(self, before, function(d)
		if d.name == name then
			found = d
			return true
		end
		return false
	end)
	return found
end

function ScopeFinder.visible(self: ScopeFinder, before: number): { Declaration }
	local out: { Declaration } = {}
	local seen: { [string]: boolean } = {}
	scan(self, before, function(d)
		if not seen[d.name] then
			seen[d.name] = true
			table.insert(out, d)
		end
		return false
	end)
	return out
end

function ScopeFinder.exprAt(self: ScopeFinder, first: number): ExprRange?
	return exprAt(self, first, 0)
end

function ScopeFinder.functionAt(self: ScopeFinder, functionToken: number): FunctionInfo?
	return parseFunction(self, functionToken)
end

-- Fields of the table constructor whose `{` is at openIdx.
function ScopeFinder.tableFields(self: ScopeFinder, openIdx: number): { TableField }
	local a = self.adapter
	local fields: { TableField } = {}
	local close = matchForward(a, openIdx)
	if not close then
		return fields
	end
	local cur = nextSig(a, openIdx)
	while cur and cur < close do
		local name: string? = nil
		local valueFirst = cur
		local n = nextSig(a, cur)
		if a.kind(cur) == "name" and n and isSym(a, n, "=") then
			name = a.text(cur)
			valueFirst = nextSig(a, n) or cur
		elseif isSym(a, cur, "[") then
			local e = matchForward(a, cur)
			local eq = if e then nextSig(a, e) else nil
			if e and eq and isSym(a, eq, "=") then
				local key = nextSig(a, cur)
				if key and key == prevSig(a, e) and a.kind(key) == "string" then
					local text = a.text(key)
					name = string.match(text, "^[\"'](.*)[\"']$")
				end
				valueFirst = nextSig(a, eq) or cur
			end
		end
		local r = exprAt(self, valueFirst, 0)
		if not r then
			break
		end
		table.insert(fields, { name = name, valueFirst = valueFirst })
		local sep = nextSig(a, r.last)
		if sep and (isSym(a, sep, ",") or isSym(a, sep, ";")) then
			cur = nextSig(a, sep)
		else
			break
		end
	end
	return fields
end

return ScopeFinder
