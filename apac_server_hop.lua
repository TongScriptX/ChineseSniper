local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local PlaceId = game.PlaceId
local JobId = game.JobId
local LocalPlayer = Players.LocalPlayer

-- 执行器 HTTP 请求函数适配
local function getExecutorEnv()
    if type(getgenv) == "function" then
        local ok, env = pcall(getgenv)
        if ok and type(env) == "table" then
            return env
        end
    end
    return _G
end

local function resolveRequestFunction()
    local executorEnv = getExecutorEnv()
    local candidates = {
        syn and syn.request,
        http and http.request,
        http_request,
        httprequest,
        fluxus and fluxus.request,
        request,
        executorEnv and executorEnv.request,
        executorEnv and executorEnv.http_request,
        executorEnv and executorEnv.httprequest,
    }

    for _, candidate in ipairs(candidates) do
        if type(candidate) == "function" then
            return candidate
        end
    end
end

local function normalizeResponse(response)
    if type(response) ~= "table" then
        return response
    end

    local body = response.Body
    if body == nil then
        body = response.body
    end

    local statusCode = response.StatusCode
    if statusCode == nil then
        statusCode = response.statusCode
    end
    if statusCode == nil then
        statusCode = response.Status
    end
    if statusCode == nil then
        statusCode = response.status
    end

    local success = response.Success
    if success == nil then
        success = response.success
    end
    if success == nil and type(statusCode) == "number" then
        success = statusCode >= 200 and statusCode < 300
    end

    response.Body = body
    response.StatusCode = statusCode
    response.Success = success
    return response
end

local requestfunc = resolveRequestFunction()

if not requestfunc then
    error(
        "未找到可用的 HTTP request 函数。这个脚本是执行器脚本，不支持直接放进 Roblox LocalScript/Studio 运行。"
    )
end

-- ============================================================================
-- 配置
-- ============================================================================
local MAX_SERVER_PAGES = 3
local PAGE_YIELD_SECONDS = 0.1
local MAX_PING = 120
local MIN_FPS = 15

-- 首选目标地区（按优先级排序）
local PREFERRED_REGIONS = {"HK", "TW", "MO", "SG", "JP", "KR"}

-- 地区 → Ping 阈值映射
-- local_max: 该地区玩家连接本地服务器时的最大 Ping
-- nearby_max: 该地区玩家连接邻近服务器时的最大 Ping
local REGION_PING_PROFILES = {
    HK  = { local_max = 60,  nearby_max = 120 },
    TW  = { local_max = 60,  nearby_max = 120 },
    MO  = { local_max = 60,  nearby_max = 120 },
    CN  = { local_max = 80,  nearby_max = 150 },
    SG  = { local_max = 70,  nearby_max = 130 },
    JP  = { local_max = 80,  nearby_max = 150 },
    KR  = { local_max = 80,  nearby_max = 150 },
    US  = { local_max = 150, nearby_max = 280 },
    GB  = { local_max = 200, nearby_max = 300 },
    DE  = { local_max = 200, nearby_max = 300 },
    FR  = { local_max = 200, nearby_max = 300 },
    AU  = { local_max = 120, nearby_max = 220 },
    IN  = { local_max = 120, nearby_max = 220 },
    DEFAULT = { local_max = 120, nearby_max = 200 },
}

-- Roblox 服务器 IP 段 → 地区映射
-- 来源: https://devforum.roblox.com/t/3094401
local IP_REGION_MAP = {
    -- 香港
    { cidr = "128.116.30.0/24",  region = "HK" },
    { cidr = "128.116.118.0/24", region = "HK" },
    -- 新加坡
    { cidr = "128.116.50.0/24",  region = "SG" },
    { cidr = "128.116.97.0/24",  region = "SG" },
    -- 日本（东京）
    { cidr = "128.116.55.0/24",  region = "JP" },
    { cidr = "128.116.120.0/24", region = "JP" },
    -- 美国（西雅图）
    { cidr = "128.116.115.0/24", region = "US" },
    -- 美国（洛杉矶）
    { cidr = "128.116.116.0/24", region = "US" },
    { cidr = "128.116.1.0/24",   region = "US" },
    { cidr = "128.116.63.0/24",  region = "US" },
    -- 美国（圣何塞）
    { cidr = "128.116.117.0/24", region = "US" },
    { cidr = "209.206.42.0/24",  region = "US" },
    { cidr = "209.206.43.0/24",  region = "US" },
    -- 美国（达拉斯）
    { cidr = "128.116.95.0/24",  region = "US" },
    -- 美国（芝加哥）
    { cidr = "128.116.101.0/24", region = "US" },
    { cidr = "128.116.48.0/24",  region = "US" },
    -- 美国（亚特兰大）
    { cidr = "128.116.22.0/24",  region = "US" },
    { cidr = "128.116.99.0/24",  region = "US" },
    -- 美国（迈阿密）
    { cidr = "128.116.45.0/24",  region = "US" },
    { cidr = "128.116.127.0/24", region = "US" },
    -- 美国（阿什本）
    { cidr = "128.116.102.0/24", region = "US" },
    { cidr = "128.116.53.0/24",  region = "US" },
    -- 美国（纽约）
    { cidr = "128.116.32.0/24",  region = "US" },
    -- 英国（伦敦）
    { cidr = "128.116.33.0/24",  region = "GB" },
    { cidr = "128.116.119.0/24", region = "GB" },
    -- 荷兰（阿姆斯特丹）
    { cidr = "128.116.21.0/24",  region = "NL" },
    -- 法国（巴黎）
    { cidr = "128.116.4.0/24",   region = "FR" },
    { cidr = "128.116.122.0/24", region = "FR" },
    -- 德国（法兰克福）
    { cidr = "128.116.5.0/24",   region = "DE" },
    { cidr = "128.116.44.0/24",  region = "DE" },
    { cidr = "128.116.123.0/24", region = "DE" },
    -- 波兰（华沙）
    { cidr = "128.116.31.0/24",  region = "PL" },
    { cidr = "128.116.124.0/24", region = "PL" },
    -- 印度（孟买）
    { cidr = "128.116.104.0/24", region = "IN" },
    -- 澳大利亚（悉尼）
    { cidr = "128.116.51.0/24",  region = "AU" },
}

-- 地区标签
local REGION_LABELS = {
    HK = "🇭🇰 香港",
    TW = "🇹🇼 台湾",
    MO = "🇲🇴 澳门",
    CN = "🇨🇳 大陆",
    SG = "🇸🇬 新加坡",
    JP = "🇯🇵 日本",
    KR = "🇰🇷 韩国",
    US = "🇺🇸 美国",
    GB = "🇬🇧 伦敦",
    NL = "🇳🇱 阿姆斯特丹",
    FR = "🇫🇷 巴黎",
    DE = "🇩🇪 法兰克福",
    PL = "🇵🇱 华沙",
    IN = "🇮🇳 孟买",
    AU = "🇦🇺 悉尼",
    UNKNOWN = "❓ 未知",
}

-- ============================================================================
-- IP 工具函数
-- ============================================================================

local function ipToInteger(ip)
    local a, b, c, d = ip:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
    if not a then return nil end
    a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
    if not (a and b and c and d) then return nil end
    return (a * 16777216) + (b * 65536) + (c * 256) + d
end

-- CIDR 范围计算（纯 Lua 实现，不依赖 bit32 / & 运算符，兼容所有执行器）
-- /n 表示前 n 位为网络位，后 32-n 位为主机位
local function cidrToRange(cidr)
    local ipPart, bits = cidr:match("([%d%.]+)/(%d+)")
    if not (ipPart and bits) then return nil end
    bits = tonumber(bits)
    local ipInt = ipToInteger(ipPart)
    if not ipInt then return nil end

    -- 主机位数 = 32 - 网络位数
    local hostBits = 32 - bits
    -- 主机数量 = 2^hostBits（Lua 双精度浮点，范围足够）
    local hostCount = 2^hostBits

    -- 起始 IP = 当前 IP 去掉主机位（向下取整到网络边界）
    local startIp = ipInt - (ipInt % hostCount)
    -- 结束 IP = 起始 IP + 主机数量 - 1
    local endIp = startIp + hostCount - 1

    return startIp, endIp
end

local function ipInCidr(ip, cidr)
    local ipInt = ipToInteger(ip)
    if not ipInt then return false end
    local startIp, endIp = cidrToRange(cidr)
    if not startIp then return false end
    return ipInt >= startIp and ipInt <= endIp
end

local function getRegionFromIp(ip)
    if not ip then return "UNKNOWN" end
    for _, entry in ipairs(IP_REGION_MAP) do
        if ipInCidr(ip, entry.cidr) then
            return entry.region
        end
    end
    return "UNKNOWN"
end

-- ============================================================================
-- 地区检测
-- ============================================================================

-- 检测玩家地理位置（通过外部 IP 地理 API）
local function detectPlayerRegion()
    local ok, response = pcall(function()
        return requestfunc({
            Url = "http://ip-api.com/json/?fields=status,countryCode,query,country",
            Method = "GET",
            Headers = {
                ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            },
        })
    end)

    if not ok or not response then
        return nil, nil
    end

    local ok2, data = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if not ok2 or not data or data.status ~= "success" then
        return nil, nil
    end

    return data.countryCode, data.country
end

-- 获取当前连接服务器的出口 IP → 推断服务器所在地区
-- 原理: 通过 Roblox 的 HttpService 请求外部服务，请求会经过 Roblox 服务器代理，
-- 外部服务看到的是服务器集群出口 IP，而非玩家 IP
-- 注意: 需要游戏开了 HttpService 才能工作；否则返回 nil
local function getCurrentServerRegion()
    -- 方法 1: 通过 Roblox HttpService（经过 Roblox 代理，能看到服务器出口 IP）
    if type(HttpService.GetAsync) == "function" then
        local ok1, body = pcall(function()
            return HttpService:GetAsync(
                "http://ip-api.com/json/?fields=status,query",
                true  -- nocache
            )
        end)
        if ok1 and body and type(body) == "string" and #body > 0 then
            local ok2, data = pcall(function()
                return HttpService:JSONDecode(body)
            end)
            if ok2 and data and data.status == "success" and data.query then
                local region = getRegionFromIp(data.query)
                if region and region ~= "UNKNOWN" then
                    return region
                end
            end
        end
    end

    -- 方法 2: 通过执行器 HTTP（走玩家本地网络，返回玩家 IP，仅作参考）
    local ok3, response = pcall(function()
        return requestfunc({
            Url = "http://ip-api.com/json/?fields=status,query",
            Method = "GET",
            Headers = {
                ["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            },
        })
    end)

    if not ok3 or not response then
        return nil
    end

    local ok4, data = pcall(function()
        return HttpService:JSONDecode(response.Body)
    end)

    if not ok4 or not data or data.status ~= "success" then
        return nil
    end

    local region = getRegionFromIp(data.query)
    return region
end

-- ============================================================================
-- HTTP / 服务器列表
-- ============================================================================

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

    return normalizeResponse(response), nil
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

-- ============================================================================
-- 服务器筛选器
-- ============================================================================

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

-- 基本的连通性检查（防卡顿）
local function isServerPlayable(server)
    return normalizePing(server) <= MAX_PING and normalizeFps(server) >= MIN_FPS
end

-- ============================================================================
-- 地区感知的服务器排序
-- ============================================================================

-- 根据玩家地区获取 Ping 阈值配置
local function getPingProfile(playerRegion)
    local profile = playerRegion and REGION_PING_PROFILES[playerRegion]
    return profile or REGION_PING_PROFILES.DEFAULT
end

-- 判断服务器的 ping 层级
-- 返回: "local" (本地) / "nearby" (邻近) / "far" (远程)
local function getServerPingTier(server, pingProfile)
    local serverPing = normalizePing(server)
    if serverPing == math.huge then
        return "far"
    end
    if serverPing <= pingProfile.local_max then
        return "local"
    elseif serverPing <= pingProfile.nearby_max then
        return "nearby"
    end
    return "far"
end

-- Ping 层级的数值权重（数字越小优先级越高）
local PING_TIER_WEIGHTS = {
    ["local"] = 0,
    nearby = 1,
    far = 2,
}

-- 判断服务器是否在首选地区内
local function isInPreferredRegions(serverRegion)
    if not serverRegion then return false end
    for _, r in ipairs(PREFERRED_REGIONS) do
        if r == serverRegion then return true end
    end
    return false
end

-- 带地区感知的服务器比较函数
-- 排序优先级:
--   1. Ping 层级 (local > nearby > far)
--   2. 是否在首选地区内 (HK/TW > 其他)
--   3. 玩家人数 (高 > 低)
--   4. Ping 值 (低 > 高)
--   5. FPS (高 > 低)
local function isBetterServer(candidate, currentBest, pingProfile, playerRegion, serverRegionCandidates)
    if not currentBest then
        return true
    end

    -- 基础连通性检查（双方都不可玩或都可玩时不影响排序）
    local candidatePlayable = isServerPlayable(candidate)
    local currentPlayable = isServerPlayable(currentBest)
    if candidatePlayable ~= currentPlayable then
        return candidatePlayable
    end

    -- 层级 1: Ping 层级
    local candidateTier = getServerPingTier(candidate, pingProfile)
    local currentTier = getServerPingTier(currentBest, pingProfile)
    local candidateWeight = PING_TIER_WEIGHTS[candidateTier]
    local currentWeight = PING_TIER_WEIGHTS[currentTier]
    if candidateWeight ~= currentWeight then
        return candidateWeight < currentWeight
    end

    -- 层级 2: 是否为玩家所在首选地区
    -- 如果 playerRegion 是 HK/TW，优先选择该地区的服务器
    if playerRegion and serverRegionCandidates then
        local candidateRegion = serverRegionCandidates[candidate.id]
        local currentRegion = serverRegionCandidates[currentBest.id]
        local candidatePreferred = candidateRegion == playerRegion
        local currentPreferred = currentRegion == playerRegion
        if candidatePreferred ~= currentPreferred then
            return candidatePreferred
        end
    end

    -- 层级 3: 是否在首选地区内 (HK/TW > SG/JP > 其他)
    local candidatePreferred = isInPreferredRegions(
        serverRegionCandidates and serverRegionCandidates[candidate.id]
    )
    local currentPreferred = isInPreferredRegions(
        serverRegionCandidates and serverRegionCandidates[currentBest.id]
    )
    if candidatePreferred ~= currentPreferred then
        return candidatePreferred
    end

    -- 层级 4: 玩家人数
    if candidate.playing ~= currentBest.playing then
        return candidate.playing > currentBest.playing
    end

    -- 层级 5: Ping 值
    local candidatePing = normalizePing(candidate)
    local currentPing = normalizePing(currentBest)
    if candidatePing ~= currentPing then
        return candidatePing < currentPing
    end

    -- 层级 6: FPS
    return normalizeFps(candidate) > normalizeFps(currentBest)
end

-- ============================================================================
-- 日志/展示
-- ============================================================================

local function regionLabel(region)
    return REGION_LABELS[region] or (region or "未识别")
end

local function pingTierLabel(tier)
    if tier == "local" then return "📍 本地"
    elseif tier == "nearby" then return "📍 邻近"
    else return "🌍 远程"
    end
end

local function formatServerInfo(server, tier, region)
    local parts = {
        string.format("人数: %d", server.playing),
        string.format("Ping: %s", server.ping ~= nil and tostring(server.ping) or "N/A"),
        string.format("FPS: %s", server.fps ~= nil and tostring(server.fps) or "N/A"),
    }
    if tier then
        table.insert(parts, pingTierLabel(tier))
    end
    if region then
        table.insert(parts, regionLabel(region))
    end
    table.insert(parts, "JobId: " .. server.id)
    return table.concat(parts, " | ")
end

-- ============================================================================
-- 主函数
-- ============================================================================

local function HopToBestNearbyPopulatedServer()
    print("=== ChineseSniper 服务器跳跃脚本 ===")
    print(string.format("当前 PlaceId: %d", PlaceId))
    print(string.format("当前 JobId: %s", JobId))

    -- ---- 步骤 1: 检测玩家地区 ----
    local playerRegion, playerCountry = detectPlayerRegion()
    if playerRegion then
        print(string.format("检测到玩家地区: %s (%s)",
            regionLabel(playerRegion), playerCountry or ""))
    else
        print("⚠ 未能检测玩家地区，将使用服务器地区作为参考")
    end

    -- ---- 步骤 2: 检测当前服务器地区（备选参考） ----
    local currentServerRegion = getCurrentServerRegion()
    if currentServerRegion then
        print(string.format("当前服务器所在地区: %s", regionLabel(currentServerRegion)))
    else
        print("⚠ 未能检测当前服务器地区")
    end

    -- ---- 步骤 3: 确定 Ping 阈值 ----
    local pingProfile = getPingProfile(playerRegion)
    print(string.format("Ping 阈值配置: 本地 ≤ %dms, 邻近 ≤ %dms",
        pingProfile.local_max, pingProfile.nearby_max))

    -- ---- 步骤 4: 拉取服务器列表 ----
    print("\n正在扫描服务器列表...")

    local allServers = {}
    local cursor = nil

    for page = 1, MAX_SERVER_PAGES do
        local pageData, err = fetchServerPage(cursor)
        if not pageData then
            warn(string.format("第 %d 页拉取失败:", page), err)
            break
        end

        local servers = pageData.data or {}
        if #servers == 0 then
            break
        end

        local beforePage = #allServers
        for _, server in ipairs(servers) do
            if isJoinableServer(server) then
                table.insert(allServers, server)
            end
        end
        local pageAdded = #allServers - beforePage
        print(string.format("第 %d 页: 获取 %d 个可加入服务器 (累计 %d)",
            page, pageAdded, #allServers))

        cursor = pageData.nextPageCursor
        if not cursor then
            break
        end

        task.wait(PAGE_YIELD_SECONDS)
    end

    print(string.format("共扫描到 %d 个可加入服务器", #allServers))

    if #allServers == 0 then
        warn("没有找到可加入的目标服务器")
        return
    end

    -- ---- 步骤 5: 筛选 + 排序 ----
    -- 按 Ping 层级分类统计
    local tierBuckets = { ["local"] = {}, nearby = {}, far = {} }
    for _, server in ipairs(allServers) do
        local tier = getServerPingTier(server, pingProfile)
        table.insert(tierBuckets[tier], server)
    end

    print(string.format("\n服务器分布:"))
    print(string.format("  📍 本地 (Ping ≤ %dms): %d 个", pingProfile.local_max, #tierBuckets["local"]))
    print(string.format("  📍 邻近 (Ping ≤ %dms): %d 个", pingProfile.nearby_max, #tierBuckets.nearby))
    print(string.format("  🌍 远程: %d 个", #tierBuckets.far))

    -- 优先选择本地服务器中人数最多的
    -- 如果没有本地服务器，选择邻近服务器中人数最多的
    -- 都没有则选远程中最好的
    local candidatePool = tierBuckets["local"]
    if #candidatePool == 0 then
        candidatePool = tierBuckets.nearby
    end
    if #candidatePool == 0 then
        candidatePool = tierBuckets.far
    end

    local tierLabel = (candidatePool == tierBuckets["local"]) and "本地" or
                      (candidatePool == tierBuckets.nearby) and "邻近" or "远程"

    -- 从候选池中找出最佳服务器
    local finalBest = nil
    for _, server in ipairs(candidatePool) do
        if isBetterServer(server, finalBest, pingProfile, playerRegion, nil) then
            finalBest = server
        end
    end

    if not finalBest then
        warn("没有找到合适的服务器")
        return
    end

    local bestTier = getServerPingTier(finalBest, pingProfile)
    print(string.format("\n✅ 选择 %s 服务器:", tierLabel))
    print("  " .. formatServerInfo(finalBest, bestTier, nil))

    -- ---- 步骤 6: 跳转 ----
    print("\n准备跳转...")
    task.wait(0.5)

    local ok, tpErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(PlaceId, finalBest.id, LocalPlayer)
    end)

    if not ok then
        warn("传送失败:", tpErr)
    end
end

-- 启动
local ok, err = pcall(HopToBestNearbyPopulatedServer)
if not ok then
    warn("脚本执行失败:", err)
end
