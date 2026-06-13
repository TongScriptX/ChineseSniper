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

local MAX_SERVER_PAGES = 3
local PAGE_YIELD_SECONDS = 0.1
local MAX_PING = 120
local MIN_FPS = 15

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
            ["User-Agent"] = "Mozilla/5.0",
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

local function isJoinableServer(server)
    return server
        and server.id
        and server.id ~= JobId
        and type(server.playing) == "number"
        and type(server.maxPlayers) == "number"
        and server.playing < server.maxPlayers
end

local function normalizePing(server)
    if type(server.ping) == "number" and server.ping > 0 then
        return server.ping
    end

    return math.huge
end

local function normalizeFps(server)
    if type(server.fps) == "number" and server.fps > 0 then
        return server.fps
    end

    return 0
end

local function isPreferredNearbyServer(server)
    return normalizePing(server) <= MAX_PING and normalizeFps(server) >= MIN_FPS
end

local function isBetterServer(candidate, currentBest)
    if not currentBest then
        return true
    end

    local candidatePreferred = isPreferredNearbyServer(candidate)
    local currentPreferred = isPreferredNearbyServer(currentBest)

    if candidatePreferred ~= currentPreferred then
        return candidatePreferred
    end

    if candidate.playing ~= currentBest.playing then
        return candidate.playing > currentBest.playing
    end

    local candidatePing = normalizePing(candidate)
    local currentPing = normalizePing(currentBest)
    if candidatePing ~= currentPing then
        return candidatePing < currentPing
    end

    return normalizeFps(candidate) > normalizeFps(currentBest)
end

local function formatServerInfo(server)
    return string.format(
        "人数: %d | Ping: %s | FPS: %s | JobId: %s",
        server.playing,
        server.ping ~= nil and tostring(server.ping) or "N/A",
        server.fps ~= nil and tostring(server.fps) or "N/A",
        server.id
    )
end

local function HopToBestNearbyPopulatedServer()
    print("正在寻找高人数且低延迟的服务器...")

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

        for _, server in ipairs(servers) do
            if isJoinableServer(server) and isBetterServer(server, bestServer) then
                bestServer = server
                print("当前最佳服务器 -> " .. formatServerInfo(server))
            end
        end

        cursor = pageData.nextPageCursor
        if not cursor then
            break
        end

        task.wait(PAGE_YIELD_SECONDS)
    end

    if not bestServer then
        warn("没有找到可加入的目标服务器")
        return
    end

    print("准备跳转 -> " .. formatServerInfo(bestServer))

    local ok, tpErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(PlaceId, bestServer.id, LocalPlayer)
    end)

    if not ok then
        warn("传送失败:", tpErr)
    end
end

HopToBestNearbyPopulatedServer()
