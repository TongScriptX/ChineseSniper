local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local PlaceId = game.PlaceId
local JobId = game.JobId
local LocalPlayer = Players.LocalPlayer

local requestfunc =
    syn and syn.request or
    http and http.request or
    http_request or
    fluxus and fluxus.request or
    request

if not requestfunc then
    error("当前执行器不支持 HTTP 请求")
end

local MAX_SERVER_PAGES = 4
local REGION_WORKERS = 6
local SERVER_BATCH_SIZE = 12
local PAGE_YIELD_SECONDS = 0.1

-- 已知 APAC 地区位置 ID
-- 0 = Singapore
-- 5 = Tokyo
-- 7 = Mumbai
-- 9 = Sydney
-- 20 = Osaka
local APAC_LOCATION_IDS = {
    ["0"] = "Singapore",
    ["5"] = "Tokyo",
    ["7"] = "Mumbai",
    ["9"] = "Sydney",
    ["20"] = "Osaka",
}

-- 从公开 RoLocate 数据中裁剪出的 APAC datacenter 映射
local DATACENTER_TO_LOCATION = {
    ["295"] = "0", ["372"] = "0", ["416"] = "0", ["417"] = "0", ["430"] = "0",
    ["440"] = "0", ["441"] = "0", ["455"] = "0", ["456"] = "0", ["462"] = "0",
    ["465"] = "0", ["513"] = "0", ["514"] = "0", ["515"] = "0", ["516"] = "0",
    ["517"] = "0", ["25931"] = "0", ["25939"] = "0", ["26030"] = "0", ["26032"] = "0",
    ["26033"] = "0", ["26034"] = "0", ["26035"] = "0", ["26036"] = "0", ["26037"] = "0",
    ["26125"] = "0", ["26132"] = "0",

    ["337"] = "5", ["377"] = "5", ["425"] = "5", ["25506"] = "5", ["26127"] = "5",

    ["359"] = "7", ["518"] = "7", ["519"] = "7", ["520"] = "7", ["521"] = "7",
    ["533"] = "7", ["534"] = "7", ["26120"] = "7", ["26123"] = "7",

    ["369"] = "9", ["450"] = "9", ["471"] = "9",

    ["25825"] = "20", ["25826"] = "20", ["25827"] = "20", ["25828"] = "20",
    ["25829"] = "20", ["25830"] = "20", ["25832"] = "20", ["25833"] = "20",
    ["25834"] = "20", ["25835"] = "20", ["25837"] = "20", ["25838"] = "20",
    ["25839"] = "20", ["25840"] = "20", ["25841"] = "20", ["25842"] = "20",
    ["25843"] = "20", ["25844"] = "20", ["25845"] = "20", ["25846"] = "20",
    ["25850"] = "20", ["26129"] = "20",
}

local regionCache = {}

local function httpRequest(options)
    local ok, response = pcall(function()
        return requestfunc(options)
    end)

    if not ok then
        return nil, "请求失败: " .. tostring(response)
    end

    if not response then
        return nil, "空响应"
    end

    return response, nil
end

local function getServerLocationName(serverId)
    if regionCache[serverId] ~= nil then
        return regionCache[serverId]
    end

    local response, err = httpRequest({
        Url = "https://gamejoin.roblox.com/v1/join-game-instance",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "Roblox/WinInet",
        },
        Body = HttpService:JSONEncode({
            placeId = PlaceId,
            gameId = serverId,
        })
    })

    if not response then
        warn("获取服务器地区失败:", err)
        regionCache[serverId] = false
        return false
    end

    if response.StatusCode ~= 200 then
        warn("join-game-instance 状态码异常:", response.StatusCode)
        regionCache[serverId] = false
        return false
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if not ok or not data then
        regionCache[serverId] = false
        return false
    end

    local datacenterId = data.joinScript and data.joinScript.DataCenterId
    if not datacenterId then
        regionCache[serverId] = false
        return false
    end

    local locationId = DATACENTER_TO_LOCATION[tostring(datacenterId)]
    if not locationId then
        regionCache[serverId] = false
        return false
    end

    local locationName = APAC_LOCATION_IDS[locationId]
    regionCache[serverId] = locationName or false
    return regionCache[serverId]
end

local function fetchServerPage(cursor)
    local url = "https://games.roblox.com/v1/games/" .. PlaceId .. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
    if cursor and cursor ~= "" then
        url = url .. "&cursor=" .. cursor
    end

    local response, err = httpRequest({
        Url = url,
        Method = "GET",
        Headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = "Mozilla/5.0"
        }
    })

    if not response then
        return nil, err
    end

    if response.StatusCode ~= 200 then
        return nil, "状态码: " .. tostring(response.StatusCode)
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if not ok then
        return nil, "JSON 解析失败"
    end

    return data, nil
end

local function createCandidateList(servers)
    local candidates = {}

    for _, server in ipairs(servers) do
        if server.id ~= JobId and server.playing and server.maxPlayers and server.playing < server.maxPlayers then
            candidates[#candidates + 1] = server
        end
    end

    return candidates
end

local function resolveBestServerInBatch(candidates, bestServer)
    local index = 1
    local activeWorkers = 0
    local batchBest = bestServer
    local finished = false
    local doneEvent = Instance.new("BindableEvent")

    local function finalizeWorker()
        activeWorkers -= 1
        if finished and activeWorkers <= 0 then
            doneEvent:Fire()
        end
    end

    local function worker()
        while true do
            local server = candidates[index]
            index += 1

            if not server then
                break
            end

            if batchBest and server.playing < batchBest.playing then
                break
            end

            local locationName = getServerLocationName(server.id)
            if locationName then
                print(string.format("发现 APAC 服务器 | %s | 人数: %d | JobId: %s", locationName, server.playing, server.id))

                if (not batchBest) or (server.playing > batchBest.playing) then
                    batchBest = {
                        id = server.id,
                        playing = server.playing,
                        location = locationName,
                    }
                end
            end

            task.wait()
        end

        finalizeWorker()
    end

    activeWorkers = math.min(REGION_WORKERS, #candidates)
    if activeWorkers == 0 then
        doneEvent:Destroy()
        return batchBest
    end

    for _ = 1, activeWorkers do
        task.spawn(worker)
    end

    finished = true
    if activeWorkers > 0 then
        doneEvent.Event:Wait()
    end
    doneEvent:Destroy()

    return batchBest
end

local function HopToMostPopulatedAPAC()
    print("正在寻找亚太地区人数最多的服务器...")

    local bestServer = nil
    local cursor = nil

    for _ = 1, MAX_SERVER_PAGES do
        local pageData, err = fetchServerPage(cursor)
        if not pageData then
            warn("拉取服务器列表失败:", err)
            break
        end

        local servers = pageData.data or {}
        if #servers == 0 then
            break
        end

        local candidates = createCandidateList(servers)
        for startIndex = 1, #candidates, SERVER_BATCH_SIZE do
            local batch = {}

            for offset = 0, SERVER_BATCH_SIZE - 1 do
                local server = candidates[startIndex + offset]
                if not server then
                    break
                end

                if bestServer and server.playing < bestServer.playing then
                    break
                end

                batch[#batch + 1] = server
            end

            if #batch == 0 then
                break
            end

            bestServer = resolveBestServerInBatch(batch, bestServer)
            task.wait()
        end

        if bestServer and servers[#servers] and servers[#servers].playing < bestServer.playing then
            break
        end

        cursor = pageData.nextPageCursor
        if not cursor then
            break
        end

        task.wait(PAGE_YIELD_SECONDS)
    end

    if not bestServer then
        warn("没有找到可加入的亚太高人数服务器")
        return
    end

    print(string.format(
        "准备跳转 -> %s | 人数: %d | JobId: %s",
        bestServer.location,
        bestServer.playing,
        bestServer.id
    ))

    local ok, tpErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(PlaceId, bestServer.id, LocalPlayer)
    end)

    if not ok then
        warn("传送失败:", tpErr)
    end
end

HopToMostPopulatedAPAC()
