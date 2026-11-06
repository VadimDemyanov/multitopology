instances = 0 -- number of instances of the tap created so far
local random = math.random

package.path = package.path
if os and os.setlocale then
	pcall(os.setlocale, "C", "numeric")
end
json = require "json"


local CONFIG_FILE_NAME = "mtopology.cfg"

-- каталог самого mtopology.lua (снимается один раз, на верхнем уровне чанка)
local SCRIPT_DIR
do
	if type(debug) == "table" and type(debug.getinfo) == "function" then
		local info = debug.getinfo(1, "S")
		local source = info and info.source
		if source then
			if string.sub(source, 1, 1) == "@" then
				source = string.sub(source, 2)
			end
			SCRIPT_DIR = string.match(source, "^(.*)[/\\][^/\\]*$")
		end
	end
end

-- путь к mtopology.cfg: всегда рядом с mtopology.lua
local function configPath()
	if SCRIPT_DIR and SCRIPT_DIR ~= "" then
		return SCRIPT_DIR .. "/" .. CONFIG_FILE_NAME
	end
	return CONFIG_FILE_NAME
end

-- читает mtopology.cfg при старте и возвращает каталог данных
local function loadConfig()
	local path = configPath()
	local fh = io.open(path, "r")
	if not fh then
		error("Multi Topology: не найден конфигурационный файл " .. path ..
			" (он должен лежать рядом с mtopology.lua)", 0)
	end
	local line = fh:read("*l")
	fh:close()

	line = line and string.gsub(line, "^%s*(.-)%s*$", "%1") or ""
	if line == "" then
		error("Multi Topology: файл " .. path .. " пуст, ожидается одна lua-строка с путём к каталогу данных", 0)
	end

	local loader = loadstring or load
	local chunk, err = loader("return " .. line, "@" .. path)
	if not chunk then
		error("Multi Topology: " .. path .. " должен содержать lua-строку с путём к каталогу данных (" .. tostring(err) .. ")", 0)
	end
	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "string" or value == "" then
		error("Multi Topology: " .. path .. " должен содержать непустую lua-строку с путём к каталогу данных", 0)
	end
	return value
end

DATA_PATH = loadConfig()

-- полный путь к файлу данных: dataFilePath("baseNodes.json")
function dataFilePath(file)
	return DATA_PATH .. file
end


td = {}
packet_counter = 0

DEBUG = false
isNewData = false

new_points_ip = {}
new_points_mac = {}
new_points_switch = {}
--[[
{
	"id": "223f9eec-a55a-4d6b-90e6-0572c7bfd610",
	"group": 0,
	"label": "e0:c8",
	"level": 1, -- 1=MAC; 2=IP
	"src_ip": "10.156.17.135",
	"dst_ip": "10.156.17.5",
	"src_mac": "38:e0:8e:90:e0:c8",
	"dst_mac": "",
	"type": "src_mac"
}
]]--

connections = {}
new_connections = {}  -- перекладываем в новый массив для того чтобы избежать ошибки  invalid table sparse array при сериализации этой таблицы
--[[
{
	"source": "4acfae31-461c-4cdf-81b2-cd04cde2fc25",
	"target": "f246ec98-df0b-4278-988a-80b27fbfd377",
	"strength": 0.05,
	"ttl": 128
}
]]--

local connectionType = {
    MACtoMAC = 0.01, -- длинная, для MAC-MAC связей 0.01
    IPtoMAC = 0.01, -- средняя, для IP-MAC связей  0.1
    InsideRouter = 0.7, -- короткая, для внутрироутерных связей 0.8 
	HostToHost = 0.01
}

nodes = {} -- база скленных точек
links = {} -- база связей между nodes

-- удаляем ребро по ССЫЛКЕ на таблицу, а не по индексу.
-- индекс, сохраненный до рекурсивного вызова getNextPoint(), к моменту удаления уже устарел
local MAX_GLUE_DEPTH = 256 -- страховка от циклов в данных и переполнения стека

local function removeConnectionByRef(target)
	for idx = #connections, 1, -1 do
		if connections[idx] == target then
			table.remove(connections, idx)
			return true
		end
	end
	return false
end

-- направление ребра не важно
local function connectionBetweenExists(id_a, id_b)
	if id_a == id_b then
		return true -- петля после склейки считается дубликатом
	end
	for idx = 1, #connections do
		local c = connections[idx]
		if (c.source == id_a and c.target == id_b) or (c.source == id_b and c.target == id_a) then
			return true
		end
	end
	return false
end

-- возвращает true, если ребро действительно перевешено.
local function moveConnectionTo(conn, new_id, side)
	local anchor
	if side == "target" then
		anchor = conn.source
	else
		anchor = conn.target
	end

	if connectionBetweenExists(anchor, new_id) then
		removeConnectionByRef(conn) -- такое ребро уже есть - старое убираем
		return false
	end

	conn[side] = new_id
	conn.finish = true
	return true
end

packet_counter = 0
addr_counter = 1
random_counter = 1 -- будет каждый раз новое число для генератора random
points_counter = 0
conn_counter = 0
rows = {}

function uuid()
	math.randomseed( random_counter )  -- Заменить на random_counter?
	random_counter = random_counter + 1

    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return string.gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format('%x', v)
    end)
end

-- {
-- 	"finish": false,
-- 	"source": "b3c5a705-2a68-45c1-9b9a-cc024749194d",
-- 	"color": "rgba(255, 0, 0, 0.2)",
-- 	"strength": 0.01,
-- 	"src_type": "mac",
-- 	"type": "mm",
-- 	"thickness": 1,
-- 	"src_addr": "c2:01:05:d4:00:01",
-- 	"activate_time": 0,
-- 	"dst_addr": "c2:02:1c:18:00:00",
-- 	"dst_type": "mac",
-- 	"target": "0c8ac8ed-fa62-4d7a-84a5-1376bce16367"
-- },
-- {
-- 	"finish": false,
-- 	"id": "b3c5a705-2a68-45c1-9b9a-cc024749194d",
-- 	"label": "00:01",

-- 	"level": 1,
-- 	"type": "mac",

-- 	"group": 0
-- },
function debug_export_rows(rows)
	temp_rows = {}
	temp_connections = {}

	for i=1, #rows do

		point2 = {}; point2.id = uuid(); point2.group=0; point2.label=rows[i].src_mac; point2.level=1
		point3 = {}; point3.id = uuid(); point3.group=0; point3.label=rows[i].dst_mac; point3.level=1
		table.insert(temp_rows, point2)
		table.insert(temp_rows, point3)
		connection2 = {}; connection2.source=point2.id; connection2.target=point3.id; connection2.strength=0.5; connection2.thickness = 1; connection2.color="rgba(128, 128, 128, 0.2)"
		table.insert(temp_connections, connection2)

		if rows[i].src_ip ~="" and rows[i].dst_ip ~="" then
			point1 = {}; point1.id = uuid(); point1.group=0; point1.label=rows[i].src_ip; point1.level=2
			point4 = {}; point4.id = uuid(); point4.group=0; point4.label=rows[i].dst_ip; point4.level=2
			table.insert(temp_rows, point1)
			table.insert(temp_rows, point4)
			connection1 = {}; connection1.source=point1.id; connection1.target=point2.id; connection1.strength=0.1; connection1.thickness = 1; connection1.color="rgba(128, 128, 128, 0.2)"
			connection3 = {}; connection3.source=point3.id; connection3.target=point4.id; connection3.strength=0.1; connection3.thickness = 1; connection3.color="rgba(128, 128, 128, 0.2)"
			table.insert(temp_connections, connection1)
			table.insert(temp_connections, connection3)
		end

	end

end

function saveNewPoint(file)
	local modelfile = assert(io.open( dataFilePath(file), "w" ))

	local points = {}
	for i=1, #new_points_ip do
		points[#points + 1] = new_points_ip[i]
	end
	for i=1, #new_points_mac do
		points[#points + 1] = new_points_mac[i]
	end
	for i=1, #new_points_switch do
		points[#points + 1] = new_points_switch[i]
	end
	modelfile:write( json.encode(points) )
	modelfile:close()
end


function addPoint(addr, addr_type) -- find Point надо исключить, точки добавляются всегда на маршруте, не нужно искать есть они или нет	
	new_point = {}
	new_point.used = false -- отмечаем у мак-точек в make_net()
	new_point.type = addr_type
	new_point.id = uuid()
	new_point.addr = addr
	new_point.group = 0
	new_point.finish = false

	if addr_type == "ip" then
		new_point.level = 2
		new_point.label = addr
		table.insert(new_points_ip, new_point)
	elseif addr_type == "mac" then
		new_point.label = string.sub(addr, -5 , -1)
		new_point.level = 1
		table.insert(new_points_mac, new_point)
	elseif addr_type == "switch" then
		new_point.label = "switch"
		new_point.level = 3
		new_point.finish = true
		table.insert(new_points_switch, new_point)	
	end

	return new_point
end

function saveConnections(file)
	local modelfile = assert(io.open( dataFilePath(file), "w" ))

	-- обнуляем new_connections
	for i in pairs(new_connections) do
		new_connections[i] = nil
	end

	j=1
	for i in pairs(connections) do
		if connections[i]~=nil then
			new_connections[j]=connections[i]
			j=j+1
		end 
	end 
	modelfile:write( json.encode(new_connections)  )
	modelfile:close()
end


function addConnection(src_point, dst_point, conType, finish)

	-- не сохраняем дубликаты коннекшонов
	-- for key, connection in pairs(connections) do
	-- 	-- пока что делаем ненаправленный граф
	-- 	if (connection.source == src_id and connection.target == dst_id) or (connection.source == dst_id and connection.target == src_id) then
	-- 		--td.text = td.text .. "==============" .. key
	-- 		return nil
	-- 	end
	-- end

	--local id = uuid()

	local new_connection = {}
	new_connection.source = src_point.id
	new_connection.target = dst_point.id
	new_connection.strength = conType

	new_connection.src_addr = src_point.addr
	new_connection.dst_addr = dst_point.addr
	new_connection.src_type = src_point.type
	new_connection.dst_type = dst_point.type

	new_connection.activate_time = 0

	if conType == connectionType.MACtoMAC then
		new_connection.thickness = 1
		new_connection.color = 'rgba(255, 0, 0, 0.2)'
		new_connection.type = "mm"
	elseif conType == connectionType.IPtoMAC then
		new_connection.thickness = 1
		new_connection.color = 	'rgba(50, 50, 50, 0.2)'
		new_connection.type = "hr"
	elseif conType == connectionType.InsideRouter then
		new_connection.thickness = 10
		new_connection.color = 'rgba(255, 0, 0, 0.5)'
		new_connection.type = "ir"
	elseif conType == connectionType.HostToHost then
		new_connection.thickness = 1
		new_connection.color = 	'rgba(50, 50, 50, 0.2)'
		new_connection.type = "hh"
	end

	new_connection.finish = finish
	new_connection.used = false
	new_connection.linkName = ""
	table.insert(connections, new_connection)
end

function activate_connection(data)
	-- ищем соединения с этими адресами
	-- устанавливаем цвет и время установки
	src_ip_id = 0
	dst_ip_id = 0
	src_mac_id = 0
	dst_mac_id = 0
	for k in pairs(new_points_ip) do
		if new_points_ip[k].addr == data.src_ip then
			src_ip_id = new_points_ip[k].id
		end
		if new_points_ip[k].addr == data.dst_ip then
			dst_ip_id = new_points_ip[k].id
		end
	end
	for k in pairs(new_points_mac) do
		if new_points_mac[k].addr == data.src_mac then
			src_mac_id = new_points_mac[k].id
		end
		if new_points_mac[k].addr == data.dst_mac then
			dst_mac_id = new_points_mac[k].id
		end
	end


	for k in pairs(connections) do
		if  (connections[k].source == src_ip_id and connections[k].target == src_mac_id) or (connections[k].target == src_ip_id and connections[k].source == src_mac_id) then
			connections[k].color = "rgba(51, 255, 51, 1)"
			connections[k].activate_time = os.clock()
			connections[k].thickness = 3
		elseif (connections[k].source == src_mac_id and connections[k].target == dst_mac_id) or (connections[k].target == dst_mac_id and connections[k].source == src_mac_id) then
			connections[k].color = "rgba(51, 255, 51, 1)"
			connections[k].activate_time = os.clock()
			connections[k].thickness = 3
		elseif (connections[k].source == dst_mac_id and connections[k].target == dst_ip_id) or (connections[k].target == dst_ip_id and connections[k].source == dst_mac_id) then
			connections[k].color = "rgba(51, 255, 51, 1)"
			connections[k].activate_time = os.clock()
			connections[k].thickness = 3
		end
	end
end

function clear_connections()
	-- пробегаем по всем connections
	-- если оно установлено как активное, то проверяем время установки
	-- если установили более n-секунд назад, то сбрасываем
	timeout = os.clock() - 3
	for k in pairs(connections) do
		if connections[k].activate_time > 0 and connections[k].activate_time < timeout then
			connections[k].activate_time = 0
			if connections[k].type == "mm" then
				connections[k].color = 'rgba(255, 0, 0, 0.2)'
				connections[k].thickness = 1
			elseif connections[k].type == "hr" then
				connections[k].color = 	'rgba(50, 50, 50, 0.2)'	
				connections[k].thickness = 1
			else -- connections[k].type == "ir"
				connections[k].color = 'rgba(255, 0, 0, 0.5)'
				connections[k].thickness = 10
			end
		end 
	end
end


function getMacPointById(id)
	for i in pairs(new_points_mac) do 
		if (new_points_mac[i].id == id) then
			return new_points_mac[i]
		end 
	end
	return nil 
end
function getIpPointById(id)
	for i in pairs(new_points_ip) do 
		if (new_points_ip[i].id == id) then
			return new_points_ip[i]
		end 
	end
	return nil 
end


-- Коммутатор нужен каждой группе из двух и более точек "ip+mac", связанных между собой.
-- Связи этих точек с роутером переносятся на коммутатор: точка - коммутатор - роутер
-- (это делает getNextPoint).
function make_switch()
	-- ШАГ 1: снимок кандидатов ДО любых правок. getNextPoint() перевешивает рёбра,
	-- но src_type/dst_type у них не обновляются, поэтому искать по типам рёбер
	-- после первой группы уже нельзя - там остались устаревшие значения.
	local candidates = {}
	for idx = 1, #connections do
		local c = connections[idx]
		if c.src_type == "ip+mac" and c.dst_type == "ip+mac" then
			table.insert(candidates, c)
		end
	end

	-- ШАГ 2: по одному коммутатору на группу. Группа уже обработана, если её точка
	-- помечена finish (getNextPoint обходит всю связную группу ip+mac целиком).
	for _, c in ipairs(candidates) do
		local start = getMacPointById(c.source)
		if start == nil or start.type ~= "ip+mac" then
			start = getMacPointById(c.target) -- source может быть не MAC-точкой
		end
		if start ~= nil and start.type == "ip+mac" and start.finish ~= true then
			local switch = addPoint("no-addr", "switch") -- новая точка типа "коммутатор"
			getNextPoint(start, switch, 0) --рекурсивно проходим по всем точкам группы и подключаем к коммутатору
		end
	end
end


function findOrAddConnection(point1, point2)
	--td.text = td.text ..  "findOrAddConnection \n"
	if (point1 == nil or point2 == nil) then
		return
	end
	if not connectionBetweenExists(point1.id, point2.id) then
		--td.text = td.text ..  " 5 addConnection\n"
		addConnection(point1, point2, connectionType.HostToHost, true)
	end
end


function getNextPoint(point, switch, depth)
	if point == nil then
		return -- раньше здесь падало на point.finish: getMacPointById() может вернуть nil
	end
	depth = depth or 0
	if depth > MAX_GLUE_DEPTH then
		return -- цикл в данных
	end
	if point.finish == true then
		return
	end
	point.finish = true

	-- ребро ищем заново на каждом шаге: предыдущее могло быть удалено moveConnectionTo,
	local seen = {}
	while true do
		local edge = nil
		for idx = 1, #connections do
			local c = connections[idx]
			if c.finish == false and seen[c] ~= true
			and (c.source == point.id or c.target == point.id) then
				edge = c
				break
			end
		end
		if edge == nil then
			return
		end
		seen[edge] = true

		local other_id, side, other_type
		if edge.target == point.id then
			other_id, side, other_type = edge.source, "target", edge.src_type
		else
			other_id, side, other_type = edge.target, "source", edge.dst_type
		end

		local other_point = getMacPointById(other_id)
		if other_point == nil then
			edge.finish = true -- не MAC-точка: ребро не перевешиваем
		else
			findOrAddConnection(point, switch)
			moveConnectionTo(edge, switch.id, side)
			if other_type == "ip+mac" then
				getNextPoint(other_point, switch, depth + 1)
			end
		end
	end
end


-- rows_sorted = {}
-- function processing_ng(row)
-- 	nested_table = { src_mac = row.src_mac, dst_mac = row.dst_mac, ttl = row.ttl }

-- 	-- rows_sorted[#rows_sorted+1] = { src_ip = row.src_ip, dst_ip = row.dst_ip , path[#path+1] = {nested_table} }
-- 	size = #rows_sorted[row.src_ip][row.dst_ip]
-- 	rows_sorted[row.src_ip][row.dst_ip][size+1] = nested_table
-- 	-- table.insert(rows_sorted[src_ip][dst_ip], rows = row)
-- 	-- debug_export_rows_sorted(rows_sorted)
-- end
-- function debug_export_rows_sorted()
-- end


-- function getJoinedRows(new_row)
-- 	local temp_rows = {}
-- 	for _, row in ipairs(rows) do
-- 		if row.src_ip==new_row.src_ip and row.dst_ip==new_row.dst_ip then
-- 			table.insert(temp_rows, row)
-- 		end
-- 	end

-- 	return temp_rows
-- end

export_points = {}
export_connections = {}
function export_sorted(sorted)
	-- for i, v in sorted do
	-- 	td.text = td.text .. tostring(i) .. ":" .. v.src_ip  .. "==" .. v.dst_ip .."\n"
	-- end

	src_ip_point = {}; src_ip_point.id = uuid(); src_ip_point.group=0; src_ip_point.level=2;
	dst_ip_point = {}; dst_ip_point.id = uuid(); dst_ip_point.group=0; dst_ip_point.level=2;

	
	for i, row in sorted do
	-- for i=1, #rows do
		src_ip_point.label=row.src_ip
		dst_ip_point.label=row.dst_ip

		point2 = {}; point2.id = uuid(); point2.group=0; point2.label=row.src_mac; point2.level=1
		point3 = {}; point3.id = uuid(); point3.group=0; point3.label=row.dst_mac; point3.level=1
		table.insert(export_points, point2)
		table.insert(export_points, point3)

		connection1 = {}; connection1.source=src_ip_point.id; connection1.target=point2.id; connection1.strength=0.1; connection1.thickness = 1; connection1.color="rgba(128, 128, 128, 0.2)"
		connection2 = {}; connection2.source=point2.id; connection2.target=point3.id; connection2.strength=0.5; connection2.thickness = 1; connection2.color="rgba(128, 128, 128, 0.2)"
		connection3 = {}; connection3.source=point3.id; connection3.target=dst_ip_point.id; connection3.strength=0.1; connection3.thickness = 1; connection3.color="rgba(128, 128, 128, 0.2)"
		table.insert(export_connections, connection1)
		table.insert(export_connections, connection2)
		table.insert(export_connections, connection3)

	end

	table.insert(export_points, src_ip_point)
	table.insert(export_points, dst_ip_point)


end
-- function convert()

-- 	-- for i, v in pairs(rows) do
-- 	-- 	print
-- 	-- 	-- path = {src_mac=rows.src_mac, dst_mac=rows.dst_mac, ttl=rows.ttl}
-- 	-- 	table.insert(, path)
-- 	-- end
-- end
function processing(new_row)
	-- getJoinedRows(new_row)
	-- ЭТАП 2. выборка временного массива для сортировки

	-- sorted_array = {}
	local temp_array = {} -- в этот массив копируем строки с одинаковым src_ip и dst_ip

	-- сбрасываем массив соединений
	for k in pairs(connections) do
		connections[k] = nil
	end
	-- сбрасываем массивы точек
	for k in pairs(new_points_ip) do
		new_points_ip[k] = nil
	end
	for k in pairs(new_points_mac) do
		new_points_mac[k] = nil
	end
	for k in pairs(new_points_switch) do
		new_points_switch[k] = nil
	end
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
	for k in pairs(export_connections) do
		export_connections[k] = nil
	end
	for k in pairs(export_points) do
		export_points[k] = nil
	end
-- %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
	-- сбрасываем флаги
	for key, row in pairs(rows) do
		row.used = false
	end

	local key = 1
	while rows[key] do -- пока массив rows еще не обработан
		--td.text = td.text .. "debug: row number:" .. tostring(key) .. "\n"
		if rows[key].used == false then
			if rows[key].src_ip=="" or rows[key].dst_ip=="" then
				mac1 = addPoint(rows[key].src_mac, "mac")
				mac2 = addPoint(rows[key].dst_mac, "mac")
				addConnection(mac1, mac2, connectionType.MACtoMAC, false)
				rows[key].used = true
			else
				temp_src_ip = rows[key].src_ip
				temp_dst_ip = rows[key].dst_ip
				rows[key].used = true
				table.insert(temp_array, rows[key])

				-- это моя функция фильтрации (заменить чем-то луевым)
				i = key + 1
				while rows[i] do
					if rows[i].src_ip==temp_src_ip and rows[i].dst_ip==temp_dst_ip then
						rows[i].used = true
						table.insert(temp_array, rows[i])
					end
					i = i + 1
				end

				-- выгрузка последней IP-точки и соединения до нее
				current_point = addPoint(temp_src_ip, "ip")
				-- №№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№
				sorted = sortByTTL(temp_array, function(t,a,b) return t[b].ttl < t[a].ttl end)
				export_sorted(sorted) -- по идее можно и temp_array выгружать
				-- №№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№№
				-- debug_export_rows(new_row)
				for key, row in sortByTTL(temp_array, function(t,a,b) return t[b].ttl < t[a].ttl end) do
					-- выгружаем начальную и конечную МАК-точки и соединение между ними (но надо проверить что такой точки/соединения еще нет)
					mac1 = addPoint(row.src_mac, "mac")
					mac2 = addPoint(row.dst_mac, "mac")
					addConnection(mac1, mac2, connectionType.MACtoMAC, false)
					-- добавляем соединение между current_point и первой mac-точкой
					if key == 1 then
						addConnection(current_point, mac1, connectionType.IPtoMAC, false)
					else
						-- если ttl уменьшился на 1, то это связь внутри роутера
						-- previos_ttl должен инициализироваться когда key == 1 
						-- td.text = td.text .. "key=" .. key .. "; previos_ttl=" .. previos_ttl .. "; row.ttl=" .. row.ttl .. "\n"	
						if ( previos_ttl - row.ttl ) == 1 then
							addConnection(current_point, mac1, connectionType.InsideRouter, false)
						else
							addConnection(current_point, mac1, connectionType.MACtoMAC, false)
						end
					end
					current_point = mac2
					previos_ttl = row.ttl
				end

				-- выгрузка последней IP-точки и соединения от current_point до нее
				last_point = addPoint(temp_dst_ip, "ip")
				addConnection(current_point, last_point, connectionType.IPtoMAC, false)

				-- сбрасываем временный массив
				for k in pairs(temp_array) do
					temp_array[k] = nil
				end
			end

		end
		key = key + 1
	end

end

function get_data(pinfo, tvb)
	if tostring(pinfo.net_dst) ~= "NONE" and tostring(pinfo.net_dst) ~= "NONE" then
		-- убираем широковещательные и 0.0.0.0 - ОНИ УЖЕ ОТФИЛЬТРОВАНЫ
		-- if tostring(pinfo.net_src) ~="0.0.0.0" and tostring(pinfo.net_dst) ~="0.0.0.0" and tostring(pinfo.net_src) ~="255.255.255.255" and tostring(pinfo.net_dst) ~="255.255.255.255" then
			packet = {}
			packet.src_ip = tostring(pinfo.net_src)
			packet.dst_ip = tostring(pinfo.net_dst)
			packet.src_mac = tostring(pinfo.dl_src)
			packet.dst_mac = tostring(pinfo.dl_dst)
			packet.ttl = tvb(22,1):uint() -- берем TTL из буфера пакета
			packet.used = false -- флаг, используется при копировании общего массива во временный, для сортировки

			-- DEBUG =======================
			-- td.text = tostring(packet_counter)..") "..td.text .. packet.src_mac .. "==" .. packet.src_ip .. "----" .. packet.dst_ip .. "==" .. packet.dst_mac .."\n"
			return packet
		-- end
	else -- no network level
		-- убираем широковещательные - ОНИ УЖЕ ОТФИЛЬТРОВАНЫ
		-- if tostring(pinfo.dl_src) ~="ff:ff:ff:ff:ff:ff" and tostring(pinfo.dl_dst) ~="ff:ff:ff:ff:ff:ff" then
			packet = {}
			packet.src_ip = ""
			packet.dst_ip = ""
			packet.src_mac = tostring(pinfo.dl_src)
			packet.dst_mac = tostring(pinfo.dl_dst)
			packet.ttl = -1
			packet.used = false -- флаг, используется при копировании общего массива во временный, для сортировки

			-- DEBUG =======================
			-- td.text = td.text .. tostring(packet_counter)..") ".. packet.src_mac .. "----"  .. packet.dst_mac .."\n"
			return packet
		-- end
	end

	return nil
end

function mytap_menu()
    instances = instances + 1

	-- ОКНО ОТЛАДКИ
    td.win = TextWindow.new("Debug window " .. instances) -- the window we'll use
    td.text = "" -- the text of the tap
    td.instance = instances -- the instance number of this tap


    -- this tap will be local to the menu_function that called it
 	-- добавлен фильтр "IG bit: Group address (multicast/broadcast)" и IPv6
    local tap = Listener.new("eth", "not (eth.dst.ig == 1) and not ipv6 and not ip.host==0.0.0.0 and not ip.host==255.255.255.255")

    -- callback to remove the tap when the text window closes
    function remove_tap()
        if tap and tap.remove then
            tap:remove()
        end
    end

    td.win:set_atclose(remove_tap)    -- make sure the tap doesn't hang around after the window was closed

	function findOrAddRow(packet)
		for key, row in pairs(rows) do
			if row.src_ip == packet.src_ip and row.dst_ip == packet.dst_ip and row.src_mac == packet.src_mac and row.dst_mac == packet.dst_mac then
				return false
			end
		end
		table.insert(rows, packet)
		if DEBUG then
			debug_export_rows(rows)
		end

		return true
	end

	function sortByTTL(input_array, order)
		local keys = {}	-- сначала делаем массив ключей
		for k in pairs(input_array) do table.insert(keys, k) end
		table.sort(keys, function(a,b) return order(input_array, a, b) end) -- сортируем массив ключей, сравнивая значения, возвращаемые по ключу
    
		local i = 0
		return function()-- return the iterator function
			i = i + 1
			if keys[i] then
				return keys[i], input_array[keys[i]]
			end
		end
	end
	
	function isNotDuplicateConnection(src_id, dst_id)
		for i, connection in ipairs(connections) do
			-- направление соединения не важно
			if (connection.source == src_id and connection.target == dst_id) or (connection.source == dst_id and connection.target == src_id)  then
				return false
			end
		end 
		return true
	end
	
	function make_netNg()
		i = 1
		while new_points_mac[i] ~= nil do
			if new_points_mac[i].used == false then
				new_points_mac[i].used = true
				j = i + 1
				while new_points_mac[j] ~= nil do
					if new_points_mac[j].addr == new_points_mac[i].addr and new_points_mac[j].used == false then 
						k = 1
							while connections[k] ~= nil do
								local removed = false
								if connections[k].source == new_points_mac[j].id then
									if isNotDuplicateConnection(new_points_mac[i].id, connections[k].target) then
										connections[k].source = new_points_mac[i].id
										-- петля: кадры, где eth.src == eth.dst, склеиваются в ребро
										-- "точка - сама с собой". Такое ребро бессмысленно и ломает раскладку.
										if connections[k].target == new_points_mac[i].id then
											table.remove(connections, k)
											removed = true
										end
									else
										table.remove(connections, k)
										removed = true
									end
								elseif connections[k].target == new_points_mac[j].id then
									if isNotDuplicateConnection(connections[k].source, new_points_mac[i].id) then
										connections[k].target = new_points_mac[i].id
										if connections[k].source == new_points_mac[i].id then
											table.remove(connections, k)
											removed = true
										end
									else
										table.remove(connections, k)
										removed = true
									end
								end
								if not removed then
									k = k + 1
								end
							end
						table.remove(new_points_mac, j)
						j = j - 1
					end
					j = j + 1
				end
			end
			i = i + 1
		end


	end

	-- инвариант графа: каждое ребро обязано ссылаться на существующие точки.
	-- возвращает число висячих ребер (до правок join_ip_mac оно было > 0)
	function validate_graph()
		local known = {}
		for _, p in ipairs(new_points_ip) do
			known[p.id] = true
		end
		for _, p in ipairs(new_points_mac) do
			known[p.id] = true
		end
		for _, p in ipairs(new_points_switch) do
			known[p.id] = true
		end

		local bad = 0
		for idx = 1, #connections do
			local c = connections[idx]
			if not (known[c.source] and known[c.target]) then
				bad = bad + 1
			end
		end
		return bad
	end

	function deleteIpPoint(id)
		-- обратный проход: table.remove внутри ipairs() сдвигал индексы,
		-- из-за чего следующий элемент пропускался (и мог быть выход за границы).
		for i = #new_points_ip, 1, -1 do
			if new_points_ip[i].id == id then
				table.remove(new_points_ip, i)
				return true
			end
		end
		return false
	end

	function updateConnectionType(id, type)
		for k, connection in ipairs(connections) do
			if (connections[k].source==id) then
				connections[k].src_type = type
			elseif (connections[k].target==id) then
				connections[k].dst_type = type
			end
		end
	end


	-- число РАЗНЫХ соседей точки, имеющих заданный тип ("ip" или "mac").
	local function neighbourCountOfType(point_id, want_type)
		local set = {}
		for idx = 1, #connections do
			local c = connections[idx]
			local other = nil
			if c.source == point_id then
				other = c.target
			elseif c.target == point_id then
				other = c.source
			end
			if other ~= nil then
				local p
				if want_type == "ip" then
					p = getIpPointById(other)
				else
					p = getMacPointById(other)
				end
				if p ~= nil then
					set[other] = true
				end
			end
		end
		local n = 0
		for _ in pairs(set) do
			n = n + 1
		end
		return n
	end

	-- слияние: MAC-точка забирает адрес IP-точки.
	-- ВСЕ ребра, ссылающиеся на ip_id, перевешиваются на mac_id ДО удаления точки,
	-- иначе в графе остаются ссылки на несуществующий узел.
	local function merge_ip_into_mac(mac_id, ip_id, ip_addr)
		local mac_point = getMacPointById(mac_id)
		if mac_point == nil or getIpPointById(ip_id) == nil then
			return false
		end

		local repointed = {}
		for idx = #connections, 1, -1 do
			local c = connections[idx]
			if c.source == ip_id then
				c.source = mac_id
				c.src_type = "ip+mac"
				c.src_addr = ip_addr
				table.insert(repointed, c)
			elseif c.target == ip_id then
				c.target = mac_id
				c.dst_type = "ip+mac"
				c.dst_addr = ip_addr
				table.insert(repointed, c)
			end
		end

		mac_point.type = "ip+mac" -- "mac+ip"
		mac_point.level = 2
		mac_point.addr = ip_addr
		mac_point.label = ip_addr
		updateConnectionType(mac_id, "ip+mac") --- обновляем типы связей до этой точки

		deleteIpPoint(ip_id)

		-- перевешивание могло дать петлю mac<->mac и дубликат уже существующего ребра
		for _, c in ipairs(repointed) do
			if c.source == c.target then
				removeConnectionByRef(c)
			elseif connectionBetweenExists(c.source, c.target) then
				local duplicate = false
				for idx = 1, #connections do
					local other = connections[idx]
					if other ~= c
					and ((other.source == c.source and other.target == c.target)
					or (other.source == c.target and other.target == c.source)) then
						duplicate = true
						break
					end
				end
				if duplicate then
					removeConnectionByRef(c)
				end
			end
		end

		return true
	end

	function join_ip_mac() -- use arp instead?
		-- Склейка в два прохода: сначала собрать всех кандидатов, ничего не меняя,
		-- потом применить. Иначе правка графа ломает обход, как в make_netNg().
		local merged = true
		while merged do
			merged = false

			-- ФАЗА A: сбор кандидатов
			local candidates = {}
			for idx = 1, #connections do
				local c = connections[idx]
				local ip_id, mac_id, ip_addr
				if c.dst_type == "ip" then
					ip_id, mac_id, ip_addr = c.target, c.source, c.dst_addr
				elseif c.src_type == "ip" then
					ip_id, mac_id, ip_addr = c.source, c.target, c.src_addr
				end

				if ip_id ~= nil
				and getMacPointById(mac_id) ~= nil
				and getIpPointById(ip_id) ~= nil
				and neighbourCountOfType(mac_id, "ip") == 1  -- единственный ip у этого mac
				and neighbourCountOfType(ip_id, "mac") == 1 then -- единственный mac у этого ip
					table.insert(candidates, { ip_id = ip_id, mac_id = mac_id, ip_addr = ip_addr })
				end
			end

			-- ФАЗА B: применение
			for _, cand in ipairs(candidates) do
				if merge_ip_into_mac(cand.mac_id, cand.ip_id, cand.ip_addr) then
					merged = true
				end
			end
		end
	end
	function remove_ip_dup()
		local i = 1
		while connections[i] ~=nil do -- иду по всем connections
			if connections[i].used == false then  --беру ранее не проанализированные и только с IP (вторая точка всегда MAC)
				if connections[i].dst_type=="ip" then
					current_ip = connections[i].dst_addr
					current_mac = connections[i].src_addr
					connections[i].used = true
				elseif connections[i].src_type=="ip" then
					current_ip = connections[i].src_addr
					current_mac = connections[i].dst_addr
					connections[i].used = true
				end

				if connections[i].used == true then
					local j = i + 1
					while connections[j] ~=nil do -- пробегаюсь по всем connections дальше
						if (connections[j].dst_addr == current_ip and connections[j].src_addr == current_mac) then
							deleteIpPoint(connections[j].target)
							table.remove(connections, j)
						elseif (connections[j].src_addr == current_ip and connections[j].dst_addr == current_mac) then
							deleteIpPoint(connections[j].source)
							table.remove(connections, j)
						else
							j = j + 1
						end
					end
				end
			end
			i = i + 1
		end
	end


    -- this function will be called for every packet
    function tap.packet(pinfo, tvb)
		-- td.text = td.text .. tostring(packet_counter) .. "\n"
		packet_counter = packet_counter + 1
		-- td.text = td.text .. tostring(packet_counter) .. "\n"
		-- ЭТАП 0. Извлекаем нужные данные из структур Wireshark
		packet_data = get_data(pinfo, tvb)

		-- ЭТАП 1. проверяем, есть ли такие адреса в базе
		if packet_data then
			-- флаг должен НАКАПЛИВАТЬСЯ до ближайшего tap.draw(): при открытии pcap
			-- Wireshark вызывает packet() для всех пакетов и draw() один раз в конце.
			local added = findOrAddRow(packet_data)
			isNewData = isNewData or added
			-- td.text = td.text.. "findOrAddRow: " .. tostring(temp).." isNewData: " .. tostring(isNewData).."\n"
		end


		-- activate_connection(packet_data)

		-- отладочную инфу перенес сюда из tap.draw()
		-- td.text="1"
		-- td.win:set(td.text)
		-- td.text = "Multispan topology\npackets: " .. tostring(packet_counter) .. "\nsegments: " ..  tostring(#rows) .. "\nip-points: " .. tostring(#new_points_ip).. "\nmac-points: " .. tostring(#new_points_mac) --.."\n---" .. get_filter() .. "\n+++" 

    end

    function tap.draw()

		-- если добавился новый ряд, запускаем пересчет сети
		if isNewData then
			-- td.text = td.text .. tostring(packet_counter)
			isNewData = false
			processing(packet_data) --этапы 4 и 5
			if DEBUG then
				saveConnections("baseLinks_routes.json")
				saveNewPoint("baseNodes_routes.json")
			end

			make_netNg() -- ЭТАП 6
			if DEBUG then
				saveConnections("baseLinks_net.json")
				saveNewPoint("baseNodes_net.json")
			end

			remove_ip_dup()-- ЭТАП 7
			if DEBUG then
				saveConnections("baseLinks_remove_ip.json")
				saveNewPoint("baseNodes_remove_ip.json")
			end


			-- joinIPandMAC()-- ЭТАП 8
			-- td.text = ""
			join_ip_mac()
			if DEBUG then
				saveConnections("baseLinks_join_ip.json")
				saveNewPoint("baseNodes_join_ip.json")
			end

			-- makeSwitch()
			make_switch()

			if DEBUG then
				dangling_count = validate_graph()
			end
		end

		-- activate_connection(packet_data)

		-- отладочную инфу перенес сюда из tap.draw()
		-- td.text="1"
		-- td.win:set(td.text)
		-- td.text = "Multispan topology\npackets: " .. tostring(packet_counter) .. "\nsegments: " ..  tostring(#rows) .. "\nip-points: " .. tostring(#new_points_ip).. "\nmac-points: " .. tostring(#new_points_mac) --.."\n---" .. get_filter() .. "\n+++" 

    -- end

    -- function tap.draw()
        td.win:set(td.text)
  td.text = "Multispan topology\npackets: " .. tostring(packet_counter) .. "\nsegments: " ..  tostring(#rows) .. "\nip-points: " .. tostring(#new_points_ip).. "\nmac-points: " .. tostring(#new_points_mac) --.."\n---" .. get_filter() .. "\n+++"
  if DEBUG then
   td.text = td.text .. "\nlinks: " .. tostring(#connections) .. ", dangling: " .. tostring(dangling_count or 0)
  end

  saveConnections("baseLinks.json")
  saveNewPoint("baseNodes.json")

		--clear_connections()
    end
end

register_menu("Multi Topology", mytap_menu, MENU_TOOLS_UNSORTED)
