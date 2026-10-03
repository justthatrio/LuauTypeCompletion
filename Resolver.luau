--!strict
--[[
	Resolver
	========

	Turns the syntactic facts from ChainCollector (what chain is left of the cursor)
	and ScopeFinder (what local does this name refer to) into TYPES, and into
	completion / signature / hover results.

	The Resolver has NO idea what a type is. A "Type" is whatever value your
	Provider hands back: a table, a string, an interface object. It is opaque
	here; nil always means "unknown", and unknown propagates silently (no wrong
	guesses, no errors). Everything specific to your environment lives in the
	Provider you implement:

	    module("fs")                 -> Provider.globalCall("module", info)  (info.stringArg == "fs")
	    require(script.Parent.Foo)   -> Provider.globalCall("require", info) (info.argChain(1) / argText(1))
	    fs.read                      -> Provider.member(fsType, "read", ".")
	    fs.read("x")                 -> Provider.call(readType, info)

	WIRING (nothing is required internally, so this works in Studio and in the CLI)

	    local collector = ChainCollector.new(adapter)       -- adapter: see ChainCollector
	    local scope     = ScopeFinder.new(adapter)
	    local resolver  = Resolver.new(collector, scope, myProvider)

	    resolver:complete(cursor)       -> { context, items, ownerType? } | nil
	    resolver:signature(cursor)      -> { context, calleeType, receiver, isMethod, activeParam } | nil
	    resolver:hover(charIndex)       -> { context, type, declaration? } | nil
	    resolver:resolveChain(chain)    -> Type?
	    resolver:resolveEndingAt(i)     -> Type?   (chain ending at token i)

	Results are only valid for the token stream they were computed from: rebuild
	(or re-point) the adapter after every edit. Lazy closures in results (Item.resolve,
	CallInfo.argType, ...) must be used before the next edit.

	THE PROVIDER
	------------
	REQUIRED
	  global(name)                       type of a free identifier (not a local), or nil
	  member(owner, name, accessor)      type of owner.name / owner:name / owner["name"]
	  call(callee, info)                 result type of calling `callee` (see CallInfo)

	OPTIONAL (omit what you do not need)
	  globalCall(name, info)             intercepts `name(...)` for a free global name BEFORE
	                                     global()/call() are tried: the place to implement
	                                     module("x") and your shimmed require(...). Return nil
	                                     to fall back to the normal path.
	  literal(kind, value)               "string" | "number" | "boolean" | "nil" | "table";
	                                     for tables value is a TableInfo (named fields, lazily typed)
	  named(path, optional)              type named in an annotation: `local x: Foo`, `(y :: Foo)`
	  index(owner, key)                  owner[expr]; key is the key's type (nil if unknown)
	  functionType(fn, resolveRef)       type of a function declared in the source (FunctionInfo)
	  callbackParam(info)                type of parameter N of a function passed as argument M,
	                                     e.g. Event:Connect(function(value) ... end)
	  iterate(info)                      types of the loop variables in `for k, v in <expr>`
	  members(owner, accessor)           completion items for owner.| / owner:|
	  globals()                          completion items for free identifiers
	  stringArgs(request)                completion items inside a string argument: module("|
	  typeNames(partial)                 completion items in a type position

	Completion items: { label, kind?, detail?, type?, data?, resolve? }. Add any
	extra fields you like; they are passed through untouched.
]]

----------------------------------------------------------------------
-- shared shapes (duplicated from ChainCollector / ScopeFinder on purpose, so
-- this module needs no requires)
----------------------------------------------------------------------

export type Type = any

export type Arg = { first: number, last: number, start: number, stop: number, string: string? }

export type Step = {
	kind: "name" | "member" | "call" | "index" | "literal" | "group",
	name: string?,
	accessor: string?,
	args: { Arg }?,
	stringArg: string?,
	literal: string?,
	value: string?,
	inner: Chain?,
	cast: string?,
	first: number,
	last: number,
	start: number,
	stop: number,
}
export type Chain = { Step }

export type SignatureContext = {
	callee: Chain,
	isMethod: boolean,
	activeParam: number,
	openParen: number,
	argStart: number,
	stringArg: string?,
}

export type CompletionContext = {
	kind: "member" | "identifier" | "string" | "type",
	partial: string,
	anchor: number,
	replaceStart: number,
	replaceStop: number,
	accessor: string?,
	chain: Chain?,
	call: SignatureContext?,
	prev: string?,
}

export type HoverContext = { chain: Chain, token: number, start: number, stop: number }

export type TypeRef = { first: number, last: number, path: string?, optional: boolean }
export type Param = { name: string, token: number, annotation: TypeRef?, vararg: boolean }
export type FunctionInfo = {
	functionToken: number,
	anonymous: boolean,
	nameToken: number?,
	isMethod: boolean,
	ownerFirst: number?,
	ownerLast: number?,
	openParen: number,
	closeParen: number,
	params: { Param },
	returnType: TypeRef?,
}
export type ExprRange = {
	first: number,
	last: number,
	kind: "chain" | "literal" | "table" | "function" | "cast" | "other",
	cast: TypeRef?,
	fn: FunctionInfo?,
}
export type TableField = { name: string?, valueFirst: number }
export type Declaration = {
	name: string,
	kind: "local" | "localFunction" | "function" | "param" | "forNumeric" | "forIn",
	token: number,
	annotation: TypeRef?,
	index: number,
	count: number,
	init: ExprRange?,
	initCount: number?,
	fn: FunctionInfo?,
	paramIndex: number?,
	isSelf: boolean?,
}

----------------------------------------------------------------------
-- provider-facing types
----------------------------------------------------------------------

export type CallInfo = {
	step: Step, -- the call step (token / char range of the parentheses)
	args: { Arg }, -- token ranges of the arguments
	stringArg: string?, -- first argument if it is a plain string literal
	isMethod: boolean, -- invoked with `:` (implicit self)
	receiver: Type?, -- the type the method was looked up on (when isMethod)
	calleeChain: Chain, -- everything before the call, e.g. workspace.Map:Find
	argChain: (i: number) -> Chain?, -- argument i as a chain (e.g. script.Parent.Foo), if it is one
	argType: (i: number) -> Type?, -- argument i resolved to a type (chain, literal, table, cast)
	argText: (i: number) -> string, -- argument i's tokens joined without whitespace
}

export type TableInfo = {
	count: number,
	fields: { { name: string?, type: () -> Type? } }, -- name is nil for positional fields
}

export type CallbackParamInfo = {
	callee: Type, -- the function being called
	receiver: Type?, -- for method calls, what it was called on
	isMethod: boolean,
	calleeChain: Chain,
	argIndex: number, -- which argument the function expression is (1-based)
	paramIndex: number, -- which parameter of the function expression (1-based)
	paramName: string,
	fn: FunctionInfo,
}

export type IterateInfo = {
	count: number, -- how many loop variables
	exprType: () -> Type?, -- type of the expression after `in`
	call: CallInfo?, -- set when the expression ends in a call: pairs(t), ipairs(t), t:Iter() ...
	callName: string?, -- set when it is a call to a free global name: "pairs"
}

export type StringArgRequest = {
	partial: string, -- text typed so far inside the string
	chain: Chain, -- callee, e.g. {name "module"}
	name: string?, -- callee name when it is a bare identifier
	argIndex: number,
	isMethod: boolean,
	calleeType: () -> Type?, -- lazily resolved type of the callee
}

export type Item = {
	label: string,
	kind: string?,
	detail: string?,
	type: Type?,
	data: any?,
	resolve: (() -> Type?)?,
}

export type Provider = {
	global: (name: string) -> Type?,
	member: (owner: Type, name: string, accessor: "." | ":" | "[]") -> Type?,
	call: (callee: Type, info: CallInfo) -> Type?,

	globalCall: ((name: string, info: CallInfo) -> Type?)?,
	literal: ((kind: string, value: any) -> Type?)?,
	named: ((path: string, optional: boolean) -> Type?)?,
	index: ((owner: Type, key: Type?) -> Type?)?,
	functionType: ((fn: FunctionInfo, resolveRef: (ref: TypeRef) -> Type?) -> Type?)?,
	callbackParam: ((info: CallbackParamInfo) -> Type?)?,
	iterate: ((info: IterateInfo) -> (Type?, Type?))?,

	members: ((owner: Type, accessor: ":" | ".") -> { Item })?,
	globals: (() -> { Item })?,
	stringArgs: ((request: StringArgRequest) -> { Item })?,
	typeNames: ((partial: string) -> { Item })?,
}

export type Options = {
	maxDepth: number?, -- recursion guard for resolution (default 240; each alias hop `local b = a` costs 3)
	filter: (boolean | (item: Item, partial: string) -> boolean)?, -- default: case-insensitive prefix filter
}

export type CompletionResult = {
	context: CompletionContext,
	items: { Item },
	ownerType: Type?, -- member completions: the receiver's type
}

export type SignatureResult = {
	context: SignatureContext,
	calleeType: Type?,
	receiver: Type?,
	isMethod: boolean,
	activeParam: number,
}

export type HoverResult = {
	context: HoverContext,
	type: Type?,
	declaration: Declaration?, -- set when the hovered name is a local / parameter / loop variable
}

----------------------------------------------------------------------
-- internal collaborators (structural; passed in by the caller)
----------------------------------------------------------------------

type AdapterLike = {
	count: () -> number,
	kind: (i: number) -> string,
	text: (i: number) -> string,
	start: (i: number) -> number,
}

type Collector = {
	adapter: AdapterLike,
	forCompletion: (self: any, cursor: number) -> CompletionContext?,
	forSignature: (self: any, cursor: number) -> SignatureContext?,
	forHover: (self: any, charIndex: number) -> HoverContext?,
	chainEndingAt: (self: any, tokenIndex: number) -> Chain?,
	decodeString: (text: string) -> string,
}

type Scope = {
	find: (self: any, name: string, before: number) -> Declaration?,
	visible: (self: any, before: number) -> { Declaration },
	exprAt: (self: any, first: number) -> ExprRange?,
	tableFields: (self: any, openIdx: number) -> { TableField },
}

----------------------------------------------------------------------
-- class
----------------------------------------------------------------------

local NIL = {} -- memo sentinel: "resolved, and the answer is unknown"

local Resolver = {}
Resolver.__index = Resolver

export type Resolver = typeof(setmetatable(
	{} :: {
		collector: Collector,
		scope: Scope,
		provider: Provider,
		adapter: AdapterLike,
		maxDepth: number,
		filter: (boolean | (item: Item, partial: string) -> boolean)?,
		memo: { [number]: any },
		depth: number,
	},
	Resolver
))

function Resolver.new(collector: any, scope: any, provider: Provider, options: Options?): Resolver
	local o: Options = options or {}
	local c = collector :: Collector
	return setmetatable({
		collector = c,
		scope = scope :: Scope,
		provider = provider,
		adapter = c.adapter,
		maxDepth = o.maxDepth or 240,
		filter = o.filter,
		memo = {},
		depth = 0,
	}, Resolver)
end

local function reset(self: Resolver)
	self.memo = {}
	self.depth = 0
end

local function isTrivia(k: string): boolean
	return k == "comment" or k == "space"
end

local function nextSig(a: AdapterLike, i: number): number?
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

local function prevSig(a: AdapterLike, i: number): number?
	local j = i - 1
	while j >= 1 do
		if not isTrivia(a.kind(j)) then
			return j
		end
		j -= 1
	end
	return nil
end

----------------------------------------------------------------------
-- resolution
----------------------------------------------------------------------

local evalChain: (self: Resolver, chain: Chain) -> (Type?, Type?)
local typeOfDecl: (self: Resolver, decl: Declaration) -> Type?
local typeOfExpr: (self: Resolver, r: ExprRange) -> Type?

local function resolveRef(self: Resolver, ref: TypeRef): Type?
	local named = self.provider.named
	if ref.path and named then
		return named(ref.path, ref.optional)
	end
	return nil
end

local function makeCallInfo(self: Resolver, chain: Chain, callIdx: number, receiver: Type?, isMethod: boolean): CallInfo
	local step = chain[callIdx]
	local args: { Arg } = step.args or {}
	local calleeChain: Chain = table.move(chain, 1, callIdx - 1, 1, {})
	local a = self.adapter
	local collector = self.collector
	local scope = self.scope

	return {
		step = step,
		args = args,
		stringArg = step.stringArg,
		isMethod = isMethod,
		receiver = receiver,
		calleeChain = calleeChain,
		argChain = function(i: number): Chain?
			local arg = args[i]
			if not arg then
				return nil
			end
			local c = collector:chainEndingAt(arg.last)
			if c and c[1].first == arg.first then
				return c
			end
			return nil
		end,
		argType = function(i: number): Type?
			local arg = args[i]
			if not arg then
				return nil
			end
			local r = scope:exprAt(arg.first)
			if not r or r.last ~= arg.last then
				return nil
			end
			return typeOfExpr(self, r)
		end,
		argText = function(i: number): string
			local arg = args[i]
			if not arg then
				return ""
			end
			local parts: { string } = {}
			for t = arg.first, arg.last do
				if not isTrivia(a.kind(t)) then
					table.insert(parts, a.text(t))
				end
			end
			return table.concat(parts)
		end,
	}
end

local function evalChainInner(self: Resolver, chain: Chain): (Type?, Type?)
	local provider = self.provider
	local root = chain[1]
	local cur: Type? = nil
	local nextIdx = 2

	if root.kind == "name" then
		local name = root.name or ""
		local decl = self.scope:find(name, root.first)
		local globalCall = provider.globalCall
		if not decl and globalCall and chain[2] and chain[2].kind == "call" then
			cur = globalCall(name, makeCallInfo(self, chain, 2, nil, false))
			if cur ~= nil then
				nextIdx = 3
			end
		end
		if cur == nil then
			nextIdx = 2
			if decl then
				cur = typeOfDecl(self, decl)
			else
				cur = provider.global(name)
			end
		end
	elseif root.kind == "literal" then
		if provider.literal then
			cur = provider.literal(root.literal or "nil", root.value)
		end
	elseif root.kind == "group" then
		if root.cast then
			local named = provider.named
			if named then
				cur = named(root.cast, false)
			end
		elseif root.inner then
			cur = (evalChain(self, root.inner))
		end
	end
	if cur == nil then
		return nil, nil
	end

	local receiver: Type? = nil
	for s = nextIdx, #chain do
		local step = chain[s]
		if step.kind == "member" then
			local owner = cur
			local accessor = (step.accessor or ".") :: any
			cur = provider.member(owner, step.name or "", accessor)
			receiver = if accessor == ":" then owner else nil
		elseif step.kind == "call" then
			local prev = chain[s - 1]
			local viaColon = prev ~= nil and prev.kind == "member" and prev.accessor == ":"
			cur = provider.call(cur, makeCallInfo(self, chain, s, receiver, viaColon))
			receiver = nil
		elseif step.kind == "index" then
			local indexFn = provider.index
			if not indexFn then
				return nil, nil
			end
			local keyType: Type? = nil
			local f = nextSig(self.adapter, step.first)
			local l = prevSig(self.adapter, step.last)
			if f and l and f <= l then
				local r = self.scope:exprAt(f)
				if r and r.last == l then
					keyType = typeOfExpr(self, r)
				end
			end
			cur = indexFn(cur, keyType)
			receiver = nil
		else
			return nil, nil
		end
		if cur == nil then
			return nil, nil
		end
	end
	return cur, receiver
end

evalChain = function(self: Resolver, chain: Chain): (Type?, Type?)
	if self.depth >= self.maxDepth or #chain == 0 then
		return nil, nil
	end
	self.depth += 1
	local t, r = evalChainInner(self, chain)
	self.depth -= 1
	return t, r
end

local function chainForRange(self: Resolver, first: number, last: number): Chain?
	local chain = self.collector:chainEndingAt(last)
	if chain and chain[1].first == first then
		return chain
	end
	return nil
end

local function typeOfExprInner(self: Resolver, r: ExprRange): Type?
	local provider = self.provider
	local a = self.adapter
	if r.kind == "chain" then
		local chain = chainForRange(self, r.first, r.last)
		if chain then
			return (evalChain(self, chain))
		end
		return nil
	elseif r.kind == "literal" then
		local literal = provider.literal
		if not literal then
			return nil
		end
		local k = a.kind(r.first)
		local text = a.text(r.first)
		if k == "string" then
			return literal("string", self.collector.decodeString(text))
		elseif k == "number" then
			return literal("number", tonumber(text) or text)
		elseif text == "nil" then
			return literal("nil", nil)
		end
		return literal("boolean", text == "true")
	elseif r.kind == "table" then
		local literal = provider.literal
		if not literal then
			return nil
		end
		local scope = self.scope
		local fields = scope:tableFields(r.first)
		local info: TableInfo = { count = #fields, fields = {} }
		for _, f in fields do
			local valueFirst = f.valueFirst
			table.insert(info.fields, {
				name = f.name,
				type = function(): Type?
					local rr = scope:exprAt(valueFirst)
					if rr then
						return typeOfExpr(self, rr)
					end
					return nil
				end,
			})
		end
		return literal("table", info)
	elseif r.kind == "function" then
		local functionType = provider.functionType
		if r.fn and functionType then
			return functionType(r.fn, function(ref: TypeRef): Type?
				return resolveRef(self, ref)
			end)
		end
		return nil
	elseif r.kind == "cast" then
		local c = r.cast
		if c then
			return resolveRef(self, c)
		end
	end
	return nil
end

typeOfExpr = function(self: Resolver, r: ExprRange): Type?
	if self.depth >= self.maxDepth then
		return nil
	end
	self.depth += 1
	local t = typeOfExprInner(self, r)
	self.depth -= 1
	return t
end

-- `self` inside function A.B:method(): the type of A.B
local function selfType(self: Resolver, decl: Declaration): Type?
	local fn = decl.fn
	if not fn or not fn.ownerFirst or not fn.ownerLast then
		return nil
	end
	local chain = chainForRange(self, fn.ownerFirst, fn.ownerLast)
	if chain then
		return (evalChain(self, chain))
	end
	return nil
end

-- Event:Connect(function(value) ... end): ask the provider what `value` is
local function callbackParamType(self: Resolver, decl: Declaration): Type?
	local provider = self.provider
	local hook = provider.callbackParam
	local fn = decl.fn
	if not hook or not fn or not fn.anonymous or not decl.paramIndex then
		return nil
	end
	local a = self.adapter
	local sig = self.collector:forSignature(a.start(fn.functionToken))
	-- must be a DIRECT argument: `(function` or `, function`, not nested in a table
	if not sig or sig.argStart ~= prevSig(a, fn.functionToken) then
		return nil
	end
	local calleeType, receiver = evalChain(self, sig.callee)
	if calleeType == nil then
		return nil
	end
	return hook({
		callee = calleeType,
		receiver = receiver,
		isMethod = sig.isMethod,
		calleeChain = sig.callee,
		argIndex = sig.activeParam,
		paramIndex = decl.paramIndex,
		paramName = decl.name,
		fn = fn,
	})
end

local function forInType(self: Resolver, decl: Declaration): Type?
	local provider = self.provider
	local iterate = provider.iterate
	local init = decl.init
	if not iterate or not init then
		return nil
	end
	local info: IterateInfo = {
		count = decl.count,
		exprType = function(): Type?
			return typeOfExpr(self, init)
		end,
	}
	if init.kind == "chain" then
		local chain = chainForRange(self, init.first, init.last)
		if chain and chain[#chain].kind == "call" then
			local prev = chain[#chain - 1]
			local viaColon = prev ~= nil and prev.kind == "member" and prev.accessor == ":"
			info.call = makeCallInfo(self, chain, #chain, nil, viaColon)
			local root = chain[1]
			if #chain == 2 and root.kind == "name" and not self.scope:find(root.name or "", root.first) then
				info.callName = root.name
			end
		end
	end
	local k, v = iterate(info)
	if decl.index == 1 then
		return k
	elseif decl.index == 2 then
		return v
	end
	return nil
end

local function typeOfDeclInner(self: Resolver, decl: Declaration): Type?
	local provider = self.provider
	local ann = decl.annotation
	if ann then
		return resolveRef(self, ann) -- an annotation is authoritative: unresolved means unknown
	end
	local kind = decl.kind
	if kind == "local" then
		local init = decl.init
		if init then
			return typeOfExpr(self, init)
		end
		return nil
	elseif kind == "localFunction" or kind == "function" then
		local functionType = provider.functionType
		if decl.fn and functionType then
			return functionType(decl.fn, function(ref: TypeRef): Type?
				return resolveRef(self, ref)
			end)
		end
		return nil
	elseif kind == "param" then
		if decl.isSelf then
			return selfType(self, decl)
		end
		return callbackParamType(self, decl)
	elseif kind == "forNumeric" then
		local literal = provider.literal
		if literal then
			return literal("number", nil)
		end
		return nil
	elseif kind == "forIn" then
		return forInType(self, decl)
	end
	return nil
end

typeOfDecl = function(self: Resolver, decl: Declaration): Type?
	local key = decl.token
	local cached = self.memo[key]
	if cached ~= nil then
		if cached == NIL then
			return nil
		end
		return cached
	end
	self.memo[key] = NIL -- also the cycle guard: re-entry while computing yields "unknown"
	if self.depth >= self.maxDepth then
		return nil
	end
	self.depth += 1
	local result = typeOfDeclInner(self, decl)
	self.depth -= 1
	if result == nil then
		self.memo[key] = NIL
	else
		self.memo[key] = result
	end
	return result
end

----------------------------------------------------------------------
-- public API
----------------------------------------------------------------------

function Resolver.resolveChain(self: Resolver, chain: Chain): Type?
	reset(self)
	return (evalChain(self, chain))
end

function Resolver.resolveEndingAt(self: Resolver, tokenIndex: number): Type?
	reset(self)
	local chain = self.collector:chainEndingAt(tokenIndex)
	if chain then
		return (evalChain(self, chain))
	end
	return nil
end

function Resolver.typeOfDeclaration(self: Resolver, decl: Declaration): Type?
	reset(self)
	return typeOfDecl(self, decl)
end

local DECL_KIND: { [string]: string } = {
	["local"] = "variable",
	localFunction = "function",
	["function"] = "function",
	param = "parameter",
	forNumeric = "variable",
	forIn = "variable",
}

local NO_COMPLETION_AFTER: { [string]: boolean } = { ["local"] = true, ["function"] = true, ["for"] = true }

local function applyFilter(self: Resolver, items: { Item }, partial: string): { Item }
	local filter = self.filter
	if filter == false or partial == "" then
		return items
	end
	local out: { Item } = {}
	local lower = string.lower(partial)
	for _, item in items do
		local keep: boolean
		if type(filter) == "function" then
			keep = filter(item, partial)
		else
			keep = string.lower(string.sub(item.label, 1, #lower)) == lower
		end
		if keep then
			table.insert(out, item)
		end
	end
	return out
end

function Resolver.complete(self: Resolver, cursor: number): CompletionResult?
	reset(self)
	local provider = self.provider
	local ctx = self.collector:forCompletion(cursor)
	if not ctx then
		return nil
	end
	local items: { Item } = {}
	local owner: Type? = nil

	if ctx.kind == "member" then
		local membersFn = provider.members
		if ctx.chain and membersFn then
			owner = (evalChain(self, ctx.chain))
			if owner ~= nil then
				items = membersFn(owner, if ctx.accessor == ":" then ":" else ".") or {}
			end
		end
	elseif ctx.kind == "identifier" then
		if not (ctx.prev and NO_COMPLETION_AFTER[ctx.prev]) then
			for _, d in self.scope:visible(ctx.anchor) do
				local decl = d
				table.insert(items, {
					label = d.name,
					kind = DECL_KIND[d.kind],
					resolve = function(): Type?
						reset(self)
						return typeOfDecl(self, decl)
					end,
				})
			end
			local globalsFn = provider.globals
			if globalsFn then
				for _, item in globalsFn() do
					table.insert(items, item)
				end
			end
		end
	elseif ctx.kind == "string" then
		local stringArgs = provider.stringArgs
		local call = ctx.call
		if stringArgs and call then
			local first = call.callee[1]
			local bare: string? = nil
			if #call.callee == 1 and first.kind == "name" then
				bare = first.name
			end
			items = stringArgs({
				partial = ctx.partial,
				chain = call.callee,
				name = bare,
				argIndex = call.activeParam,
				isMethod = call.isMethod,
				calleeType = function(): Type?
					reset(self)
					return (evalChain(self, call.callee))
				end,
			}) or {}
		end
	elseif ctx.kind == "type" then
		local typeNames = provider.typeNames
		if typeNames then
			items = typeNames(ctx.partial) or {}
		end
	end

	return { context = ctx, items = applyFilter(self, items, ctx.partial), ownerType = owner }
end

function Resolver.signature(self: Resolver, cursor: number): SignatureResult?
	reset(self)
	local sig = self.collector:forSignature(cursor)
	if not sig then
		return nil
	end
	local calleeType, receiver = evalChain(self, sig.callee)
	return {
		context = sig,
		calleeType = calleeType,
		receiver = receiver,
		isMethod = sig.isMethod,
		activeParam = sig.activeParam,
	}
end

function Resolver.hover(self: Resolver, charIndex: number): HoverResult?
	reset(self)
	local h = self.collector:forHover(charIndex)
	if not h then
		return nil
	end
	local declaration: Declaration? = nil
	if #h.chain == 1 and h.chain[1].kind == "name" then
		declaration = self.scope:find(h.chain[1].name or "", h.chain[1].first)
	end
	local t = evalChain(self, h.chain)
	return { context = h, type = t, declaration = declaration }
end

return Resolver
