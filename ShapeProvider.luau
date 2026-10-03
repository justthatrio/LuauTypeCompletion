--!strict
--[[
	Roblox ShapeProvider - ApiDb schema v2

	Consumes the rich ApiDb emitted by ApiDbGenerator v2. The provider keeps the
	Resolver-facing interface from the original reference implementation while
	adding Roblox-specific semantics:

	  * classes + inheritance
	  * primitive/data-type/enum/named types
	  * arrays, dictionaries/maps, tuples, unions, optional types
	  * overloaded functions and tuple/multiple returns
	  * parameter defaults / optional parameters / varargs
	  * API metadata for hover/completion consumers
	  * events -> RBXScriptSignal-like shapes with typed Connect callbacks
	  * game:GetService("...") and Instance.new("...") specialization
	  * Enum.X.Y

	The loader also understands the old ApiDb schema emitted by the original
	generator, so upgrading the database can be done independently.
]]

export type Shape = any

export type Config = {
	apiDb: Instance | { Index: any, Enums: any, Classes: any }?,
	scriptClass: string?,
	globals: { [string]: Shape }?,
}

local S = {}

S.any = { tag = "any" }
S.nilType = { tag = "prim", name = "nil" }
S.string = { tag = "prim", name = "string" }
S.number = { tag = "prim", name = "number" }
S.boolean = { tag = "prim", name = "boolean" }

function S.object(members: { [string]: Shape }): Shape
	return { tag = "object", members = members }
end

function S.class(name: string, superName: string?, members: { [string]: Shape }): Shape
	return {
		tag = "class",
		name = name,
		super = superName,
		members = members,
	}
end

function S.datatype(name: string, members: { [string]: Shape }?): Shape
	return {
		tag = "datatype",
		name = name,
		members = members or {},
	}
end

function S.fn(params: { any }, returns: Shape?): Shape
	return { tag = "fn", params = params, returns = returns }
end

function S.overloaded(overloads: { Shape }): Shape
	return { tag = "overload", overloads = overloads }
end

function S.array(element: Shape): Shape
	return { tag = "array", element = element }
end

function S.map(key: Shape, value: Shape): Shape
	return { tag = "map", key = key, value = value }
end

function S.tuple(items: { Shape }): Shape
	return { tag = "tuple", items = items }
end

function S.union(items: { Shape }): Shape
	local flat = {}
	local seen = {}
	for _, item in items do
		if item and item.tag == "union" then
			for _, nested in item.items do
				local id = tostring(nested)
				if not seen[id] then
					seen[id] = true
					table.insert(flat, nested)
				end
			end
		elseif item then
			local id = tostring(item)
			if not seen[id] then
				seen[id] = true
				table.insert(flat, item)
			end
		end
	end
	if #flat == 0 then
		return S.any
	elseif #flat == 1 then
		return flat[1]
	end
	return { tag = "union", items = flat }
end

function S.optional(value: Shape): Shape
	return S.union({ value, S.nilType })
end

function S.enum(name: string): Shape
	return { tag = "enum", name = name }
end

function S.signal(params: { any }, connection: Shape?): Shape
	return {
		tag = "signal",
		params = params,
		members = {},
		connection = connection,
	}
end

local function describe(shape: Shape?): string
	if shape == nil then
		return "any"
	end
	local tag = shape.tag
	if tag == "any" then
		return "any"
	elseif tag == "prim" then
		return shape.name
	elseif tag == "class" or tag == "datatype" then
		return shape.name
	elseif tag == "object" then
		return "object"
	elseif tag == "enum" then
		return shape.name
	elseif tag == "array" then
		return "{" .. describe(shape.element) .. "}"
	elseif tag == "map" then
		return "{[" .. describe(shape.key) .. "]: " .. describe(shape.value) .. "}"
	elseif tag == "tuple" then
		local parts = {}
		for _, item in shape.items do
			table.insert(parts, describe(item))
		end
		return "(" .. table.concat(parts, ", ") .. ")"
	elseif tag == "union" then
		local parts = {}
		for _, item in shape.items do
			table.insert(parts, describe(item))
		end
		return table.concat(parts, " | ")
	elseif tag == "signal" then
		return "RBXScriptSignal"
	elseif tag == "overload" then
		return "overloaded function"
	elseif tag == "fn" then
		local params = {}
		for _, p in shape.params do
			local suffix = if p.optional then "?" else ""
			local variadic = if p.variadic then "..." else ""
			table.insert(params, variadic .. p.name .. suffix .. ": " .. describe(p.type))
		end
		return "(" .. table.concat(params, ", ") .. ") -> " .. describe(shape.returns)
	end
	return "any"
end

S.describe = describe

local function sortedNames(t: { [string]: any }): { string }
	local names = {}
	for name in t do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function moduleValue(value: any): any
	if typeof(value) == "Instance" then
		return require(value)
	end
	return value
end

local function childModule(root: Instance, name: string): any
	local child = root:FindFirstChild(name)
	if not child or not child:IsA("ModuleScript") then
		return nil
	end
	return require(child)
end

local function oldTypeName(value: any): string?
	if type(value) ~= "string" then
		return nil
	end
	return value
end

local function isPrimitiveName(name: string): boolean
	return name == "string" or name == "boolean" or name == "bool" or name == "number"
		or name == "int" or name == "int8" or name == "int16" or name == "int32" or name == "int64"
		or name == "uint8" or name == "uint16" or name == "uint32" or name == "uint64"
		or name == "float" or name == "double" or name == "void" or name == "null" or name == "nil"
		or name == "Variant" or name == "any"
end

local function primitiveShape(name: string): Shape?
	if name == "string" then return S.string end
	if name == "boolean" or name == "bool" then return S.boolean end
	if name == "number" or name == "int" or name == "int8" or name == "int16" or name == "int32" or name == "int64"
		or name == "uint8" or name == "uint16" or name == "uint32" or name == "uint64" or name == "float" or name == "double" then
		return S.number
	end
	if name == "void" or name == "null" or name == "nil" then return S.nilType end
	if name == "Variant" or name == "any" then return S.any end
	return nil
end

local function typeDescriptorKind(desc: any): string?
	if type(desc) ~= "table" then
		return nil
	end
	return desc.kind or desc.Category
end

local ShapeProvider = {}
ShapeProvider.S = S

function ShapeProvider.new(config: Config?): any
	config = config or {}
	local apiDb = config.apiDb
	if apiDb == nil then
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		apiDb = ReplicatedStorage:FindFirstChild("ApiDb")
	end
	assert(apiDb ~= nil, "ShapeProvider: ApiDb was not supplied and ReplicatedStorage.ApiDb was not found")

	local index: any
	local enumsRaw: any
	local classesFolder: any
	if typeof(apiDb) == "Instance" then
		assert(apiDb:IsA("Folder"), "ShapeProvider: apiDb must be an ApiDb Folder")
		index = childModule(apiDb, "Index")
		enumsRaw = apiDb:FindFirstChild("Enums")
		if enumsRaw and enumsRaw:IsA("ModuleScript") then
			enumsRaw = require(enumsRaw)
		end
		classesFolder = apiDb:FindFirstChild("Classes")
	else
		index = moduleValue(apiDb.Index)
		enumsRaw = moduleValue(apiDb.Enums)
		classesFolder = apiDb.Classes
	end

	assert(type(index) == "table", "ShapeProvider: ApiDb.Index could not be loaded")

	-- v2.1 stores large enum sets as individual ModuleScripts under ApiDb.Enums
	-- so the aggregate enum database cannot hit ModuleScript.Source's size limit.
	local enums: { [string]: any } = {}
	if typeof(enumsRaw) == "Instance" and enumsRaw:IsA("Folder") then
		for _, child in enumsRaw:GetChildren() do
			if child:IsA("ModuleScript") and child.Name ~= "Index" then
				local ok, data = pcall(require, child)
				if ok and type(data) == "table" then
					enums[child.Name] = data
				end
			end
		end
	elseif type(enumsRaw) == "table" then
		-- v2 stores enums under .enums; v1 stored them directly by name.
		enums = if type(enumsRaw.enums) == "table" then enumsRaw.enums else enumsRaw
	else
		assert(false, "ShapeProvider: ApiDb.Enums could not be loaded")
	end

	local classIndex = if type(index.classes) == "table" then index.classes else {}

	local classes: { [string]: Shape } = {}
	local classData: { [string]: any } = {}
	local classModuleCache: { [string]: any } = {}
	local datatypes: { [string]: Shape } = {}
	local enumShapes: { [string]: Shape } = {}
	local enumItems: { [string]: Shape } = {}

	for className, info in pairs(classIndex) do
		if type(className) == "string" and type(info) == "table" then
			classes[className] = S.class(className, info.super, {})
			classData[className] = info
		end
	end

	local function loadClassData(className: string): any
		if classModuleCache[className] ~= nil then
			return classModuleCache[className]
		end
		local data
		if typeof(classesFolder) == "Instance" then
			local module = classesFolder:FindFirstChild(className)
			if module and module:IsA("ModuleScript") then
				data = require(module)
			end
		else
			local entry = classesFolder and classesFolder[className]
			data = moduleValue(entry)
		end
		if type(data) ~= "table" then
			data = { members = {} }
		end
		classModuleCache[className] = data
		return data
	end

	for enumName, enumData in pairs(enums) do
		if type(enumName) == "string" then
			local data = enumData
			local items = if type(data) == "table" and type(data.items) == "table" then data.items else data
			local members = {}
			local enumShape = S.object(members)
			enumShape.enumName = enumName
			enumShape.meta = if type(data) == "table" then data else nil
			enumShapes[enumName] = enumShape
			if type(items) == "table" then
				for itemName, itemData in pairs(items) do
					if type(itemName) == "string" then
						local item = S.enum("Enum." .. enumName)
						item.value = if type(itemData) == "table" then itemData.value or itemData.Value else itemData end
					item.meta = itemData
					members[itemName] = item
					enumItems["Enum." .. enumName .. "." .. itemName] = item
				end
			end
		end
	end
end

local enumRoot = S.object({})
for enumName, shape in pairs(enumShapes) do
	enumRoot.members[enumName] = shape
end

local typeFromDescriptor: (any) -> Shape

local function unionFromDescriptors(items: { any }): Shape
	local shapes = {}
	for _, item in items do
		table.insert(shapes, typeFromDescriptor(item))
	end
	return S.union(shapes)
end

typeFromDescriptor = function(desc: any): Shape
	if desc == nil then
		return S.any
	end

	-- Backwards compatibility with schema v1: descriptors were strings.
	if type(desc) == "string" then
		local primitive = primitiveShape(desc)
		if primitive then return primitive end
		if desc == "table" then return S.any end
		if desc == "Enum" then return enumRoot end
		if desc:sub(1, 5) == "Enum." then
			return enumShapes[desc:sub(6)] or S.enum(desc)
		end
		return classes[desc] or datatypes[desc] or S.any
	end

	if type(desc) ~= "table" then
		return S.any
	end

	local kind = desc.kind or desc.Category
	local name = desc.name or desc.Name

	if kind == "primitive" or kind == "Primitive" then
		local result = primitiveShape(tostring(name or "any")) or S.any
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "class" or kind == "Class" then
		local result = classes[name] or S.any
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "datatype" or kind == "DataType" then
		if not datatypes[name] then
			datatypes[name] = S.datatype(name, {})
		end
		local result = datatypes[name]
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "enum" or kind == "Enum" then
		local result = enumShapes[name] or S.enum("Enum." .. tostring(name))
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "array" or kind == "Array" then
		local result = S.array(typeFromDescriptor(desc.element or desc.Element))
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "map" or kind == "Dictionary" or kind == "Map" then
		local result = S.map(
			typeFromDescriptor(desc.key or desc.Key or desc.keyType or desc.KeyType),
			typeFromDescriptor(desc.value or desc.Value or desc.valueType or desc.ValueType)
		)
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "tuple" or kind == "Tuple" then
		local tupleItems = {}
		for _, item in (desc.items or desc.Items or desc.types or desc.Types or {}) do
			table.insert(tupleItems, typeFromDescriptor(item))
		end
		local result = S.tuple(tupleItems)
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "union" or kind == "Union" then
		local result = unionFromDescriptors(desc.items or desc.Items or desc.types or desc.Types or desc.options or desc.Options or {})
		if desc.optional then result = S.optional(result) end
		return result
	elseif kind == "any" or name == "Variant" then
		return S.any
	elseif kind == "nil" then
		return S.nilType
	elseif kind == "named" or kind == "group" then
		local named = tostring(name or "")
		if named == "Array" then return S.array(S.any) end
		if named == "Dictionary" or named == "Map" then return S.map(S.any, S.any) end
		if named == "Tuple" then return S.tuple({}) end
		return classes[named] or datatypes[named] or S.any
	end

	-- Graceful handling of raw/newer dump descriptors.
	if desc.Types or desc.Options or desc.Union then
		return unionFromDescriptors(desc.Types or desc.Options or desc.Union)
	end
	if name and isPrimitiveName(name) then
		return primitiveShape(name) or S.any
	end
	if name and enumShapes[name] then
		return enumShapes[name]
	end
	if name and classes[name] then
		return classes[name]
	end
	return S.any
end

local function paramsFromDb(params: any): { any }
	local out = {}
	if type(params) ~= "table" then return out end
	for _, p in params do
		if type(p) == "table" then
			local name = tostring(p.name or p.Name or p[1] or "arg")
			local typeDesc = p.type or p.Type or p[2]
			local optional = p.optional == true or p.Optional == true or p.default ~= nil or p.Default ~= nil
			local shape = typeFromDescriptor(typeDesc)
			if optional then shape = S.optional(shape) end
			table.insert(out, {
				name = name,
				type = shape,
				optional = optional,
				variadic = p.variadic == true or p.Vararg == true,
				default = p.default or p.Default,
				description = p.description or p.Description,
				meta = p,
			})
		end
	end
	return out
end

local function returnFromMember(member: any): Shape
	local returns = member.returns or member.ret
	if returns == nil then
		return S.nilType
	end
	return typeFromDescriptor(returns)
end

local function makeFunction(member: any): Shape
	local params = paramsFromDb(member.params or member.Parameters)
	local fn = S.fn(params, returnFromMember(member))
	fn.meta = member
	return fn
end

local function makeOverloaded(member: any): Shape
	local rawOverloads = member.overloads
	if type(rawOverloads) ~= "table" or #rawOverloads == 0 then
		return makeFunction(member)
	end
	local overloads = {}
	for _, overload in rawOverloads do
		if type(overload) == "table" then
			table.insert(overloads, makeFunction(overload))
		end
	end
	if #overloads == 1 then return overloads[1] end
	local shape = S.overloaded(overloads)
	shape.meta = member
	return shape
end

local function eventShape(member: any): Shape
	local params = paramsFromDb(member.params or member.Parameters)
	local callback = S.fn(params, S.nilType)
	local connection = classes.RBXScriptConnection or S.any
	local signal = S.signal(params, connection)
	signal.meta = member
	signal.members.Connect = S.fn({ { name = "callback", type = callback } }, connection)
	signal.members.Once = S.fn({ { name = "callback", type = callback } }, connection)
	local waitReturns = {}
	for _, p in params do table.insert(waitReturns, p.type) end
	signal.members.Wait = S.fn({}, if #waitReturns == 0 then S.nilType else if #waitReturns == 1 then waitReturns[1] else S.tuple(waitReturns))
	return signal
end

for className, classShape in pairs(classes) do
	local data = loadClassData(className)
	classShape.meta = data
	local rawMembers = data.members or data.Members or {}
	for memberName, member in pairs(rawMembers) do
		if type(memberName) == "string" and type(member) == "table" then
			local kind = member.kind or member.k or member.MemberType
			if kind == "prop" or kind == "Property" then
				classShape.members[memberName] = {
					tag = "property",
					type = typeFromDescriptor(member.type or member.t or member.ValueType),
					readonly = member.readonly == true or member.ro == true,
					meta = member,
				}
			elseif kind == "method" or kind == "Function" or kind == "Callback" then
				classShape.members[memberName] = makeOverloaded(member)
			elseif kind == "event" or kind == "Event" then
				classShape.members[memberName] = eventShape(member)
			end
		end
	end
end

-- Union-aware member lookup. A member present on one union branch is
-- returned as a union; common members naturally collapse when identical.
local function findMember(owner: Shape?, name: string, seen: { [string]: boolean }?): Shape?
	if owner == nil then return nil end
	if owner.tag == "union" then
		local found = {}
		for _, branch in owner.items do
			local member = findMember(branch, name, seen)
			if member then table.insert(found, member) end
		end
		if #found == 0 then return nil end
		return S.union(found)
	end
	if owner.tag == "object" or owner.tag == "signal" or owner.tag == "datatype" then
		return owner.members and owner.members[name]
	end
	if owner.tag ~= "class" then return nil end
	local member = owner.members[name]
	if member then return member end
	if not owner.super then return nil end
	seen = seen or {}
	if seen[owner.name] then return nil end
	seen[owner.name] = true
	return findMember(classes[owner.super], name, seen)
end

local function collectMembers(owner: Shape?, out: { [string]: Shape }, seen: { [string]: boolean }?)
	if not owner then return end
	if owner.tag == "union" then
		for _, branch in owner.items do collectMembers(branch, out, seen) end
		return
	end
	if owner.tag == "object" or owner.tag == "signal" or owner.tag == "datatype" then
		for name, member in pairs(owner.members) do
			if out[name] == nil then out[name] = member end
		end
		return
	end
	if owner.tag ~= "class" then return end
	seen = seen or {}
	if seen[owner.name] then return end
	seen[owner.name] = true
	for name, member in pairs(owner.members) do
		if out[name] == nil then out[name] = member end
	end
	if owner.super then collectMembers(classes[owner.super], out, seen) end
end

local function classIsA(actual: Shape, expected: Shape): boolean
	if actual == expected then return true end
	if actual.tag ~= "class" or expected.tag ~= "class" then return false end
	local current = actual
	local seen = {}
	while current and current.tag == "class" and current.super do
		if seen[current.name] then break end
		seen[current.name] = true
		current = classes[current.super]
		if current == expected then return true end
	end
	return false
end

local function matches(actual: Shape?, expected: Shape?): boolean
	if expected == nil or expected.tag == "any" then return true end
	if actual == nil then return false end
	if expected.tag == "union" then
		for _, branch in expected.items do if matches(actual, branch) then return true end end
		return false
	end
	if actual.tag == "union" then
		for _, branch in actual.items do if matches(branch, expected) then return true end end
		return true
	end
	if expected.tag == "prim" and actual.tag == "prim" then
		return expected.name == actual.name
	end
	if expected.tag == "class" then return classIsA(actual, expected) end
	if expected.tag == "enum" then return actual.tag == "enum" and actual.name == expected.name end
	if expected.tag == "array" then return actual.tag == "array" and matches(actual.element, expected.element) end
	if expected.tag == "map" then return actual.tag == "map" and matches(actual.key, expected.key) and matches(actual.value, expected.value) end
	if expected.tag == "tuple" then return actual.tag == "tuple" and #actual.items == #expected.items end
	return actual.tag == expected.tag and actual.name == expected.name
end

local function requiredCount(params: { any }): number
	local count = 0
	for _, p in params do
		if not p.optional and not p.variadic then count += 1 end
	end
	return count
end

local function accepts(fn: Shape, info: any): boolean
	local args = info and info.args or {}
	local params = fn.params
	local required = requiredCount(params)
	if #args < required then return false end
	local fixed = 0
	for _, p in params do if not p.variadic then fixed += 1 end end
	if #args > fixed and not (params[#params] and params[#params].variadic) then return false end
	for i, arg in ipairs(args) do
		local p = params[i]
		if p == nil and params[#params] and params[#params].variadic then p = params[#params] end
		if p then
			local actual = info.argType(i)
			if actual and not matches(actual, p.type) then return false end
		end
	end
	return true
end

local function chooseFunction(callee: Shape, info: any): Shape?
	if callee.tag == "fn" then return callee end
	if callee.tag ~= "overload" then return nil end
	local first = callee.overloads[1]
	for _, fn in callee.overloads do
		if accepts(fn, info) then return fn end
	end
	return first
end

local globalsTable: { [string]: Shape } = {}
globalsTable.game = classes.DataModel or S.any
globalsTable.workspace = classes.Workspace or S.any
globalsTable.script = classes[config.scriptClass or "Script"] or classes.Script or S.any
globalsTable.plugin = classes.Plugin or S.any
globalsTable.Enum = enumRoot

local instanceClass = classes.Instance
if instanceClass then
	instanceClass.members.new = S.fn({
		{ name = "className", type = S.string },
		{ name = "parent", type = instanceClass, optional = true },
	}, function(info: any): Shape?
		local name = info and info.stringArg
		return if name then classes[name] or S.any else instanceClass
	end)
end

local dataModel = classes.DataModel
if dataModel then
	dataModel.members.GetService = S.fn({ { name = "className", type = S.string } }, function(info: any): Shape?
		local name = info and info.stringArg
		local data = name and classData[name]
		if data and data.service then return classes[name] end
		return S.any
	end)
end

if config.globals then
	for name, shape in pairs(config.globals) do globalsTable[name] = shape end
end

local classNames = sortedNames(classes)
local serviceNames = {}
for _, name in classNames do
	if classData[name] and classData[name].service then table.insert(serviceNames, name) end
end

local provider = {}

function provider.global(name: string): Shape?
	return globalsTable[name]
end

function provider.member(owner: Shape, name: string, accessor: string): Shape?
	local member = findMember(owner, name)
	if not member then return nil end
	if accessor == ":" then
		if member.tag == "fn" or member.tag == "overload" then return member end
		return nil
	end
	if member.tag == "property" then return member.type end
	return member
end

function provider.call(callee: Shape, info: any): Shape?
	local fn = chooseFunction(callee, info)
	if not fn then return nil end
	local result = fn.returns
	if type(result) == "function" then return result(info) end
	return result
end

function provider.globalCall(name: string, info: any): Shape?
	if name == "typeof" or name == "type" then return S.string end
	return nil
end

function provider.literal(kind: string, value: any): Shape?
	if kind == "string" then return S.string end
	if kind == "number" then return S.number end
	if kind == "boolean" then return S.boolean end
	if kind == "nil" then return S.nilType end
	if kind == "table" then
		local members = {}
		local first: Shape? = nil
		local count = 0
		local named = 0
		for _, field in value.fields do
			if field.name then
				named += 1
				local t = field.type()
				if t then members[field.name] = t end
			else
				count += 1
				if not first then first = field.type() end
			end
		end
		if named == 0 and count > 0 and first then return S.array(first) end
		return S.object(members)
	end
	return nil
end

function provider.named(path: string, optional: boolean): Shape?
	local result: Shape?
	if path == "Enum" then
		result = enumRoot
	else
		result = enumItems[path]
		if not result then
			local enumName = path:match("^Enum%.(.+)$")
			if enumName then result = enumShapes[enumName] end
		end
		if not result then result = classes[path] or datatypes[path] end
	end
	if optional and result then return S.optional(result) end
	return result
end

function provider.index(owner: Shape, key: Shape?): Shape?
	if owner.tag == "array" then return owner.element end
	if owner.tag == "map" then return owner.value end
	if owner.tag == "tuple" then
		if key and key.tag == "prim" and key.name == "number" then
			return S.union(owner.items)
		end
		return nil
	end
	if owner.tag == "union" then
		local values = {}
		for _, branch in owner.items do
			local value = provider.index(branch, key)
			if value then table.insert(values, value) end
		end
		return if #values > 0 then S.union(values) else nil
	end
	return nil
end

function provider.functionType(fn: any, resolveRef: (ref: any) -> Shape?): Shape?
	local params = {}
	for _, p in fn.params do
		if not p.vararg then
			table.insert(params, {
				name = p.name,
				type = if p.annotation then resolveRef(p.annotation) else S.any,
				optional = p.optional == true,
			})
		end
	end
	local returns = if fn.returnType then resolveRef(fn.returnType) else S.nilType
	return S.fn(params, returns)
end

function provider.callbackParam(info: any): Shape?
	local callee = info.callee
	local functions = {}
	if callee.tag == "fn" then
		table.insert(functions, callee)
	elseif callee.tag == "overload" then
		for _, fn in callee.overloads do table.insert(functions, fn) end
	else
		return nil
	end
	local results = {}
	for _, fn in functions do
		local p = fn.params[info.argIndex]
		local cb = p and p.type
		if cb and cb.tag == "fn" then
			local q = cb.params[info.paramIndex]
			if q and q.type then table.insert(results, q.type) end
		end
	end
	return if #results > 0 then S.union(results) else nil
end

local function elements(t: Shape?): (Shape?, Shape?)
	if not t then return nil, nil end
	if t.tag == "array" then return S.number, t.element end
	if t.tag == "map" then return t.key, t.value end
	if t.tag == "tuple" then return S.number, S.union(t.items) end
	if t.tag == "union" then
		local keys, values = {}, {}
		for _, branch in t.items do
			local k, v = elements(branch)
			if k then table.insert(keys, k) end
			if v then table.insert(values, v) end
		end
		return if #keys > 0 then S.union(keys) else nil, if #values > 0 then S.union(values) else nil
	end
	return nil, nil
end

function provider.iterate(info: any): (Shape?, Shape?)
	if info.callName == "pairs" or info.callName == "ipairs" then
		return elements(info.call and info.call.argType(1))
	end
	return elements(info.exprType())
end

function provider.members(owner: Shape, accessor: string): { any }
	local members = {}
	collectMembers(owner, members)
	local items = {}
	for _, name in sortedNames(members) do
		local member = members[name]
		if accessor ~= ":" or member.tag == "fn" or member.tag == "overload" then
			local itemType = if member.tag == "property" then member.type else member
			local kind = if member.tag == "fn" or member.tag == "overload" then "method" elseif member.tag == "signal" then "event" else "property"
			table.insert(items, {
				label = name,
				kind = kind,
				detail = describe(itemType),
				type = itemType,
				meta = member.meta,
			})
		end
	end
	return items
end

function provider.globals(): { any }
	local items = {}
	for _, name in sortedNames(globalsTable) do
		table.insert(items, {
			label = name,
			kind = "global",
			detail = describe(globalsTable[name]),
			type = globalsTable[name],
		})
	end
	return items
end

function provider.stringArgs(req: any): { any }
	local items = {}
	local name = req.name
	if name == "game:GetService" or name == "GetService" then
		for _, service in serviceNames do table.insert(items, { label = service, kind = "service" }) end
	elseif name == "Instance.new" then
		for _, className in classNames do table.insert(items, { label = className, kind = "class" }) end
	end
	return items
end

function provider.typeNames(partial: string): { any }
	local items = {}
	for _, name in sortedNames(classes) do
		table.insert(items, { label = name, kind = "type", type = classes[name] })
	end
	for _, name in sortedNames(datatypes) do
		table.insert(items, { label = name, kind = "type", type = datatypes[name] })
	end
	for _, name in sortedNames(enumShapes) do
		table.insert(items, { label = "Enum." .. name, kind = "type", type = enumShapes[name] })
	end
	return items
end

return provider
end

return ShapeProvider
