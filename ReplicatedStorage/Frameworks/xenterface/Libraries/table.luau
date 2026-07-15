local _table = table
local table = {}
setmetatable(table, {
	__index = _table
})

function table.filter(t: {}, f: (x: any) -> boolean): {}
	local s = {}
	for i, v in t do
		if f(v) then
			table.insert(s, v)
		end
	end
	return s
end

function table.deepclone(t: {}): {}
	local s = {}
	for i, v in t do
		if type(v) == "table" then
			v = table.deepclone(v)
		end
		s[i] = v
	end
	return s
end

function table.map(t: {}, f: (x: any) -> any): {}
	local s = {}
	for i, v in t do
		s[i] = f(v)
	end
	return s
end

function table.xremove(t: {}, x: any)
	table.remove(t, table.find(t, x))
end

function table.merge(t1, t2)
	return {table.unpack(t1), table.unpack(t2)}
end

function table.remdups(t: {}) --remove duplicates
	local s = {}
	for _, v in t do
		if not table.find(s, v) then
			table.insert(s, v)
		end
	end
	return s
end

return table