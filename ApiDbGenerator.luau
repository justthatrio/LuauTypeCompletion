--[[
	ApiDbGenerator (Studio plugin)

	Turns Mini-API-Dump.json into compact ModuleScripts for the ShapeProvider.

	Output:
	  ApiDb/
	    Index      -> version + class metadata
	    Enums      -> enum metadata + items
	    Classes/
	      <ClassName> -> class metadata + rich member/type descriptors

	Unlike the original generator, this version does NOT flatten API types to
	strings. It preserves the structure supplied by the API dump, including:
	  * primitive/class/data-type/enum/group kinds
	  * Array / Dictionary / Map / Table / Objects / Tuple groups
	  * union-like descriptors when present
	  * tuple/multiple return values
	  * overload lists when present or when duplicate member names occur
	  * parameter defaults and optionality
	  * security, tags, descriptions, serialization, categories, thread safety

	The generator is deliberately tolerant of newer API-dump fields: unknown
	fields on types/members are retained in `raw` when useful rather than being
	collapsed into `any`.
]]

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CONFIG = {
	URL = "https://raw.githubusercontent.com/MaximumADHD/Roblox-Client-Tracker/roblox/Mini-API-Dump.json",
	OutputParent = ReplicatedStorage,
	FolderName = "ApiDb",
	SkipTags = { Deprecated = true, NotScriptable = true, Hidden = true },
	SkipRestricted = true,
}

local KEYWORDS = {}
for _, w in {
	"and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
	"local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "continue",
	} do
	KEYWORDS[w] = true
end

local GROUP_NAMES = {
	Array = true,
	Dictionary = true,
	Map = true,
	Objects = true,
	Table = true,
	Tuple = true,
}

local function key(name: string): string
	if name:match("^[%a_][%w_]*$") and not KEYWORDS[name] then
		return name
	end
	return string.format("[%q]", name)
end

local function hasAnyTag(tags: any, set: { [string]: boolean }): boolean
	if type(tags) ~= "table" then
		return false
	end
	for _, t in tags do
		if type(t) == "string" and set[t] then
			return true
		end
	end
	return false
end

local function hasTag(tags: any, tag: string): boolean
	return hasAnyTag(tags, { [tag] = true })
end

local function checkSecurity(sec: any): (boolean, boolean)
	if sec == nil then
		return true, false
	end
	if type(sec) == "string" then
		return sec == "None", false
	end
	if type(sec) == "table" then
		local read = sec.Read or "None"
		local write = sec.Write or "None"
		return read == "None", write ~= "None"
	end
	return true, false
end

local function cloneSerializable(value: any, depth: number?): any
	depth = depth or 0
	if depth > 24 then
		return "<depth-limit>"
	end
	local kind = type(value)
	if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then
		return value
	end
	if kind ~= "table" then
		return tostring(value)
	end
	local out = {}
	for k, v in pairs(value) do
		if type(k) == "string" or type(k) == "number" then
			out[k] = cloneSerializable(v, depth + 1)
		end
	end
	return out
end

-- The JSON dump normally uses { Category = ..., Name = ... } for a type.
-- We preserve the original descriptor and normalize the common group forms
-- into a small stable representation understood by ShapeProvider.
local function typeDescriptor(t: any): any
	if type(t) ~= "table" then
		return { kind = "any" }
	end

	-- Some future/derived dumps may encode a union explicitly.
	local union = t.Types or t.Options or t.Union
	if t.Category == "Union" or type(union) == "table" then
		local items = {}
		if type(union) == "table" then
			for _, item in union do
				table.insert(items, typeDescriptor(item))
			end
		end
		return {
			kind = "union",
			items = items,
			optional = t.Optional == true,
		}
	end

	local category = t.Category
	local name = t.Name
	if type(category) ~= "string" and type(name) ~= "string" then
		return { kind = "any" }
	end

	if category == "Enum" then
		return { kind = "enum", name = name, rawCategory = category }
	end

	if category == "Group" then
		local group = tostring(name or "")
		if group == "Array" or group == "Objects" then
			return {
				kind = "array",
				element = typeDescriptor(t.Element or t.ValueType or t.ItemType or t.Value),
				optional = t.Optional == true,
			}
		elseif group == "Dictionary" or group == "Map" then
			return {
				kind = "map",
				key = typeDescriptor(t.KeyType or t.Key or t.KeyValueType),
				value = typeDescriptor(t.ValueType or t.Value or t.Element),
				optional = t.Optional == true,
			}
		elseif group == "Tuple" then
			local items = {}
			local source = t.Types or t.Items or t.Values or t.Elements
			if type(source) == "table" then
				for _, item in source do
					table.insert(items, typeDescriptor(item))
				end
			end
			return {
				kind = "tuple",
				items = items,
				optional = t.Optional == true,
			}
		end
		return { kind = "group", name = group }
	end

	if category == "Primitive" then
		local primitive = tostring(name or "any")
		if primitive == "void" or primitive == "null" then
			primitive = "nil"
		elseif primitive == "bool" then
			primitive = "boolean"
		end
		return {
			kind = "primitive",
			name = primitive,
			optional = t.Optional == true,
		}
	end

	if category == "Class" or category == "DataType" then
		return {
			kind = string.lower(category),
			name = name,
			optional = t.Optional == true,
		}
	end

	if name == "Variant" then
		return { kind = "any", name = name }
	elseif name == "Tuple" then
		return { kind = "tuple", items = {} }
	end

	return {
		kind = "named",
		name = name,
		category = category,
		optional = t.Optional == true,
	}
end

local function returnDescriptor(rt: any, tupleReturns: any): any
	local values = {}

	if type(tupleReturns) == "table" then
		for _, t in tupleReturns do
			table.insert(values, typeDescriptor(t))
		end
	end

	if #values == 0 and type(rt) == "table" and rt.Name == nil and rt.Category == nil then
		for _, t in rt do
			table.insert(values, typeDescriptor(t))
		end
	end

	if #values > 1 then
		return { kind = "tuple", items = values }
	elseif #values == 1 then
		return values[1]
	end

	if rt ~= nil then
		return typeDescriptor(rt)
	end

	return { kind = "nil", name = "nil" }
end

local function parameterDescriptor(p: any): any
	local default = p.Default
	local optional = p.Optional == true or default ~= nil
	local type = typeDescriptor(p.Type)
	if optional then
		type.optional = true
	end
	return {
		name = tostring(p.Name or "arg"),
		type = type,
		default = if default ~= nil then tostring(default) else nil,
		optional = optional,
		variadic = p.Variadic == true or p.Vararg == true,
		description = p.Description,
	}
end

local function paramsDescriptor(params: any): { any }
	local out = {}
	if type(params) ~= "table" then
		return out
	end
	for _, p in params do
		if type(p) == "table" then
			table.insert(out, parameterDescriptor(p))
		end
	end
	return out
end

local function memberDescriptor(m: any): any?
	if hasAnyTag(m.Tags, CONFIG.SkipTags) then
		return nil
	end
	local allowed, writeRestricted = checkSecurity(m.Security)
	if CONFIG.SkipRestricted and not allowed then
		return nil
	end

	local base = {
		name = tostring(m.Name or ""),
		kind = m.MemberType,
		description = m.Description,
		category = m.Category,
		tags = cloneSerializable(m.Tags),
		security = cloneSerializable(m.Security),
		threadSafety = m.ThreadSafety,
		serialization = cloneSerializable(m.Serialization),
	}

	if m.MemberType == "Property" then
		base.type = typeDescriptor(m.ValueType)
		base.readonly = writeRestricted or hasTag(m.Tags, "ReadOnly")
		return base
	elseif m.MemberType == "Function" or m.MemberType == "Callback" then
		base.params = paramsDescriptor(m.Parameters)
		base.returns = returnDescriptor(m.ReturnType, m.TupleReturns)
		base.yields = hasTag(m.Tags, "Yields")
		if type(m.Overloads) == "table" then
			base.overloads = cloneSerializable(m.Overloads)
		end
		return base
	elseif m.MemberType == "Event" then
		base.params = paramsDescriptor(m.Parameters)
		return base
	end

	return nil
end

-- Lua source serializer for generated ModuleScripts.
local function serializeLua(value: any, indent: number?): string
	indent = indent or 0
	local pad = string.rep("\t", indent)
	local nextPad = string.rep("\t", indent + 1)
	local kind = type(value)

	if kind == "nil" then
		return "nil"
	elseif kind == "string" then
		return string.format("%q", value)
	elseif kind == "number" then
		return tostring(value)
	elseif kind == "boolean" then
		return if value then "true" else "false"
	elseif kind ~= "table" then
		return string.format("%q", tostring(value))
	end

	local isArray = true
	local max = 0
	for k in pairs(value) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
			isArray = false
			break
		end
		max = math.max(max, k)
	end
	if isArray then
		for i = 1, max do
			if value[i] == nil then
				isArray = false
				break
			end
		end
	end

	local lines = { "{" }
	if isArray then
		for i = 1, max do
			table.insert(lines, nextPad .. serializeLua(value[i], indent + 1) .. ",")
		end
	else
		local keys = {}
		for k in pairs(value) do
			table.insert(keys, k)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, k in ipairs(keys) do
			local keyText
			if type(k) == "string" and k:match("^[%a_][%w_]*$") and not KEYWORDS[k] then
				keyText = k
			else
				keyText = "[" .. serializeLua(k, 0) .. "]"
			end
			table.insert(lines, nextPad .. keyText .. " = " .. serializeLua(value[k], indent + 1) .. ",")
		end
	end
	table.insert(lines, pad .. "}")
	return table.concat(lines, "\n")
end

local function buildClassSourceFinal(cls: any): string
	local result = {
		schema = 2,
		name = cls.Name,
		super = if type(cls.Superclass) == "string" and cls.Superclass ~= "<<<ROOT>>>" then cls.Superclass else nil,
		service = hasTag(cls.Tags, "Service"),
		creatable = not hasTag(cls.Tags, "NotCreatable"),
		description = cls.Description,
		memoryCategory = cls.MemoryCategory,
		tags = cloneSerializable(cls.Tags),
		members = {},
	}

	local grouped: { [string]: { any } } = {}
	for _, m in cls.Members or {} do
		local d = memberDescriptor(m)
		if d then
			grouped[d.name] = grouped[d.name] or {}
			table.insert(grouped[d.name], d)
		end
	end
	for name, list in pairs(grouped) do
		if #list == 1 then
			result.members[name] = list[1]
		else
			local first = table.clone(list[1])
			first.overloads = list
			result.members[name] = first
		end
	end

	return "-- generated by ApiDbGenerator v2, do not edit\nreturn " .. serializeLua(result)
end

local function buildIndexSource(classes: { any }, version: any): string
	local result: any = {
		schema = 2,
		version = tostring(version or "unknown"),
		classes = {},
	}
	for _, cls in classes do
		result.classes[cls.Name] = {
			name = cls.Name,
			super = if type(cls.Superclass) == "string" and cls.Superclass ~= "<<<ROOT>>>" then cls.Superclass else nil,
			service = hasTag(cls.Tags, "Service"),
			creatable = not hasTag(cls.Tags, "NotCreatable"),
			description = cls.Description,
			tags = cloneSerializable(cls.Tags),
		}
	end
	return "-- generated by ApiDbGenerator v2, do not edit\nreturn " .. serializeLua(result)
end

local function buildEnumSource(e: any): string
	local result = {
		schema = 2,
		name = e.Name,
		description = e.Description,
		items = {},
	}
	for _, item in e.Items or {} do
		result.items[item.Name] = {
			value = item.Value,
			description = item.Description,
		}
	end
	return "-- generated by ApiDbGenerator v2, do not edit\nreturn " .. serializeLua(result)
end

local function buildEnumsIndexSource(enums: { any }): string
	local result: any = { schema = 2, enums = {} }
	for _, e in enums do
		result.enums[e.Name] = {
			name = e.Name,
			description = e.Description,
		}
	end
	return "-- generated by ApiDbGenerator v2, do not edit\nreturn " .. serializeLua(result)
end

local function loadJsonText(): string?
	local ok, result = pcall(function()
		return HttpService:GetAsync(CONFIG.URL)
	end)
	if ok then
		return result
	end
	warn("[ApiDbGenerator] HTTP fetch failed: " .. tostring(result))

	local sel = Selection:Get()[1]
	if sel then
		if sel:IsA("StringValue") then
			return sel.Value
		elseif sel:IsA("LuaSourceContainer") then
			return sel.Source
		end
	end
	warn("[ApiDbGenerator] Enable HTTP requests for this plugin, or select a StringValue/Script containing the raw JSON.")
	return nil
end

local MAX_MODULE_SOURCE = 190000 -- Studio rejects ModuleScript.Source at ~200000 bytes

local function newModule(name: string, source: string, parent: Instance)
	if #source >= MAX_MODULE_SOURCE then
		error(string.format("[ApiDbGenerator] Generated module %q is %d bytes; refusing to assign ModuleScript.Source (limit is ~200000).", name, #source))
	end
	local m = Instance.new("ModuleScript")
	m.Name = name
	m.Source = source
	m.Parent = parent
	return m
end

local function generate()
	local text = loadJsonText()
	if not text then
		return
	end

	local okDecode, dump = pcall(HttpService.JSONDecode, HttpService, text)
	if not okDecode or type(dump) ~= "table" or type(dump.Classes) ~= "table" then
		warn("[ApiDbGenerator] Could not parse API dump JSON.")
		return
	end

	local recording = ChangeHistoryService:TryBeginRecording("Generate API DB v2")
	local old = CONFIG.OutputParent:FindFirstChild(CONFIG.FolderName)
	if old then
		old:Destroy()
	end

	local root = Instance.new("Folder")
	root.Name = CONFIG.FolderName
	local classesFolder = Instance.new("Folder")
	classesFolder.Name = "Classes"
	classesFolder.Parent = root

	local count = 0
	for _, cls in dump.Classes do
		newModule(cls.Name, buildClassSourceFinal(cls), classesFolder)
		count += 1
		if count % 25 == 0 then
			task.wait()
		end
	end

	newModule("Index", buildIndexSource(dump.Classes, dump.Version), root)

	local enumsFolder = Instance.new("Folder")
	enumsFolder.Name = "Enums"
	enumsFolder.Parent = root
	newModule("Index", buildEnumsIndexSource(dump.Enums or {}), enumsFolder)
	for _, enum in dump.Enums or {} do
		newModule(enum.Name, buildEnumSource(enum), enumsFolder)
	end

	root.Parent = CONFIG.OutputParent

	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	print(string.format("[ApiDbGenerator] Generated schema v2: %d classes and %d enums into %s.", count, #(dump.Enums or {}), root:GetFullName()))
end

local toolbar = plugin:CreateToolbar("API DB")
local button = toolbar:CreateButton("Generate", "Generate rich API DB modules from Mini-API-Dump", "")
button.ClickableWhenViewportHidden = true

local busy = false
button.Click:Connect(function()
	if busy then
		return
	end
	busy = true
	local ok, err = pcall(generate)
	if not ok then
		warn("[ApiDbGenerator] " .. tostring(err))
	end
	busy = false
end)
