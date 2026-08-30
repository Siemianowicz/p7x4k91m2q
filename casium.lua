-- ====================================================================================================
-- CASE PARADISE ALL-IN-ONE AUTO-BUYER, AUTO-REJOIN & AUTO-FARM ENGINE
-- ====================================================================================================
-- Features:
--   1. Batch Case Opening (5x cases at once)
--   2. Priority 1: Candy Case (10 Candy) | Priority 2: Piqru Case ($1,000 Balance/Cash)
--   3. Fixed Auto-Spending Balance (Opens Piqru cases down to configured stop threshold)
--   4. Discord Webhook Reporting (Titan Holo count, Balance, Holos/Tickets, Event Points, Session Stats)
--   5. Force Auto-Rejoin Engine (Rejoins server upon completing case opening)
--   6. Auto-Farming Handoff (Checks currency on rejoin; if none left, launches auto-farming engine)
-- ====================================================================================================

-- ====================================================================================================
-- CONFIGURATION
-- ====================================================================================================
local CONFIG = {
    -- Discord Webhook
    DISCORD_WEBHOOK_URL    = "https://discord.com/api/webhooks/1530628648888041553/yUVjHpL9SHcEukSfveiQUfsJSEjPViw64ssTOlrdRRdiJvy7JvCx1G2jGMwbP46To1CK",
    WEBHOOK_INTERVAL_HOURS = 3,         -- Automatically send/update live dashboard every 3 hours
    
    -- Case Buying & Batching
    BATCH_AMOUNT           = 5,         -- Open 5 cases at once (falls back to 1 if currency < 5x cost)
    AUTO_DETECT_EVENT_CASE = true,      -- Find the current event case from the live Cases module
    EVENT_CASE_OVERRIDE    = "",        -- Force a case ID (e.g. "CandyCase"); "" = auto-detect
    EVENT_CASE_FALLBACK    = "CandyCase",  -- Used only if auto-detect finds nothing
    EVENT_STOP_CURRENCY    = 50,     -- Stop buying event cases when event currency <= this
    PIQRU_STOP_CASH        = 100000,    -- Stop buying Piqru Case when Cash <= 200,000 (saves 200k Coins)
    OPEN_COOLDOWN          = 5.8,       -- MEASURED live: server accepts one open per ~5.8s
    BUY_DELAY              = 6.0,       -- Wait after a SUCCESSFUL open (5.5 still bounced ~1 in 3)
    COOLDOWN_BACKOFF_DELAY = 1.0,       -- Wait after a REJECTED open before retrying
    MAX_CONSECUTIVE_FAILS  = 8,         -- Retire a case ID after this many rejections in a row

    -- Auto-Rejoin & Server Hop Engine
    ENABLE_AUTO_REJOIN     = true,      -- Move servers after finishing case opening
    REJOIN_MODE            = "Hop",     -- "Hop" = jump to a DIFFERENT public server | "Same" = rejoin current server
    REJOIN_DELAY           = 3.0,       -- Seconds to wait before teleporting
    HOP_MIN_PLAYERS        = 1,         -- Skip servers below this player count (0 = allow empty servers)
    HOP_MAX_FILL           = 0.95,      -- Skip servers at/above this % full (avoids full-server teleport failures)
    HOP_REMEMBER_SERVERS   = true,      -- Never hop back into a server already visited (persisted to file)
    HOP_MAX_PAGES          = 3,         -- Pages of 100 servers to pull from the Roblox API
    HOP_MAX_ATTEMPTS       = 5,         -- Teleport attempts before falling back to a plain rejoin
    HOP_RETRY_DELAY        = 6.0,       -- Seconds to let a teleport land before trying the next server
    
    -- Auto Farming Script Integration
    ENABLE_AUTO_FARM       = true,      -- Run a farm engine when no currency is left for cases
    FARM_MODE              = "OnEmpty", -- "OnEmpty" = farm only when broke | "Always" = farm alongside case opening
    AUTO_FARM_SCRIPT_URL   = "",        -- External farm script URL (e.g. "https://raw.githubusercontent.com/...")
    AUTO_FARM_SCRIPT_FILE  = "",        -- OR a local farm script in the executor workspace (e.g. "myfarm.lua")
    FARM_WATCH_INTERVAL    = 5,         -- Seconds between currency checks while farming
    
    -- Client Protections
    ENABLE_ANTI_AFK        = true,      -- Prevent 20-minute Roblox idle disconnect
    MUTE_COOLDOWN_ALERTS   = true,      -- Hide cooldown popups & mute warning SFX
}

-- Boot-stage tracer: writes progress to disk so a hang can be located precisely.
local function bootLog(stage)
    local line = os.date("%X") .. " | BOOT: " .. tostring(stage) .. string.char(10)
    pcall(function()
        if appendfile then appendfile("case_paradise_boot.log", line) end
    end)
end
bootLog("chunk start")

-- Save script source to global for queue_on_teleport re-execution
if isfile and isfile("case_paradise_script.lua") then
    pcall(function() getgenv().CaseParadiseScriptSource = readfile("case_paradise_script.lua") end)
end

-- ====================================================================================================
-- INITIALIZATION & SERVICES
-- ====================================================================================================
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")
local VirtualUser       = game:GetService("VirtualUser")
local HttpService       = game:GetService("HttpService")
local TeleportService   = game:GetService("TeleportService")
local LocalPlayer       = Players.LocalPlayer or Players.PlayerAdded:Wait()

local Remotes           = ReplicatedStorage:WaitForChild("Remotes")
local OpenCaseRemote    = Remotes:WaitForChild("OpenCase")
local PlayerData        = LocalPlayer:WaitForChild("PlayerData")
local PlayerCurrencies  = PlayerData:WaitForChild("Currencies")
local BalanceValue      = PlayerCurrencies:WaitForChild("Balance")
local TicketsValue      = PlayerCurrencies:WaitForChild("Tickets") -- Candy/Holos are both stored in 'Tickets'

-- Session Control Token
bootLog("services resolved")
local CURRENT_SESSION = tick()
getgenv()._ActiveCaseBuyerSession = CURRENT_SESSION

-- Cross-Executor Request Function
local httpRequest = (syn and syn.request) 
    or (http and http.request) 
    or http_request 
    or (fluxus and fluxus.request) 
    or request

-- Cross-Executor Queue On Teleport
local queueOnTeleport = (syn and syn.queue_on_teleport) 
    or queue_on_teleport 
    or (fluxus and fluxus.queue_on_teleport) 
    or queueonteleport

-- ====================================================================================================
-- COOLDOWN MESSAGE & WARNING SOUND SUPPRESSOR
-- ====================================================================================================
if CONFIG.MUTE_COOLDOWN_ALERTS then
    pcall(function()
        local sfx = SoundService:FindFirstChild("SFX")
        if sfx and sfx:FindFirstChild("Warning") then
            sfx.Warning.Volume = 0
        end

        local playingSfx = SoundService:FindFirstChild("PlayingSFX")
        if playingSfx then
            playingSfx.ChildAdded:Connect(function(child)
                if child.Name == "Warning" and child:IsA("Sound") then
                    child.Volume = 0
                    child:Stop()
                end
            end)
            for _, s in ipairs(playingSfx:GetChildren()) do
                if s.Name == "Warning" and s:IsA("Sound") then
                    s.Volume = 0
                    s:Stop()
                end
            end
        end
    end)

    pcall(function()
        local notifs = LocalPlayer:WaitForChild("PlayerGui"):WaitForChild("Notifications")
        local function checkAndHide(desc)
            if desc:IsA("TextLabel") then
                local text = desc.Text:lower()
                if text:find("cooldown") or text:find("wait") or text:find("trying again") then
                    desc.Visible = false
                    if desc.Parent and desc.Parent:IsA("GuiObject") then
                        desc.Parent.Visible = false
                    end
                end
            end
        end

        for _, desc in ipairs(notifs:GetDescendants()) do
            checkAndHide(desc)
        end

        notifs.DescendantAdded:Connect(function(desc)
            checkAndHide(desc)
            task.delay(0.05, function() checkAndHide(desc) end)
        end)
    end)
end

bootLog("suppressor done")

-- ====================================================================================================
-- ANTI-AFK ENGINE
-- ====================================================================================================
if CONFIG.ENABLE_ANTI_AFK then
    -- Reconnect on every server: teleporting destroys the old LocalPlayer, killing the old connection
    if getgenv()._AntiAfkConnection then
        pcall(function() getgenv()._AntiAfkConnection:Disconnect() end)
    end
    pcall(function()
        getgenv()._AntiAfkConnection = LocalPlayer.Idled:Connect(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end)
end

bootLog("anti-afk done")

-- ====================================================================================================
-- EVENT CASE RESOLVER
-- ====================================================================================================
-- Hardcoding a case ID is what broke this script when the Techno event ended and "TechnoCase"
-- vanished from the module. Instead, read the live Cases table and find whatever event case is
-- currently running. Survives the next rotation with no edit.

local EVENT_CASE

local function describeCase(id, d)
    return {
        id       = id,
        price    = d.Price,
        currency = d.Currency or "Tickets",
        category = d.Category or "?",
        name     = d.Name or id,
    }
end

local function resolveEventCase()
    local ok, Cases = pcall(function() return require(ReplicatedStorage.Modules.Cases) end)
    if not ok or type(Cases) ~= "table" then
        warn("[Event Case] Could not require the Cases module.")
        return nil
    end

    -- 1. Explicit override always wins
    if CONFIG.EVENT_CASE_OVERRIDE ~= "" then
        local d = Cases[CONFIG.EVENT_CASE_OVERRIDE]
        if type(d) == "table" and d.Price then
            print("[Event Case] Using override: " .. CONFIG.EVENT_CASE_OVERRIDE)
            return describeCase(CONFIG.EVENT_CASE_OVERRIDE, d)
        end
        warn("[Event Case] Override '" .. tostring(CONFIG.EVENT_CASE_OVERRIDE) .. "' not found in Cases module.")
    end

    -- 2. Auto-detect: a case is "event" if it bills a non-Balance currency, or is a Limited
    --    case whose Category mentions Event. Cheapest wins so we get the most opens per currency.
    if CONFIG.AUTO_DETECT_EVENT_CASE then
        local best
        for key, d in pairs(Cases) do
            if type(d) == "table" and type(d.Price) == "number" and d.Price > 0 then
                local ticketPriced = type(d.Currency) == "string" and d.Currency ~= "Balance"
                local eventCat     = type(d.Category) == "string" and d.Category:find("Event") ~= nil
                if ticketPriced or (eventCat and d.Limited) then
                    if not best or d.Price < best.price then
                        best = describeCase(key, d)
                    end
                end
            end
        end
        if best then
            print(string.format("[Event Case] Auto-detected '%s' (%s) | price=%s %s | category=%s",
                best.id, best.name, tostring(best.price), tostring(best.currency), tostring(best.category)))
            return best
        end
        warn("[Event Case] Auto-detect found no event case in the Cases module.")
    end

    -- 3. Fallback to the last known good ID
    local d = Cases[CONFIG.EVENT_CASE_FALLBACK]
    if type(d) == "table" and d.Price then
        warn("[Event Case] Falling back to '" .. CONFIG.EVENT_CASE_FALLBACK .. "'.")
        return describeCase(CONFIG.EVENT_CASE_FALLBACK, d)
    end

    warn("[Event Case] No usable event case found - event opening disabled this session.")
    return nil
end

bootLog("resolver defined")
EVENT_CASE = resolveEventCase()
bootLog("resolver ran")

-- ====================================================================================================
-- DATA HELPERS & CURRENCY READERS
-- ====================================================================================================
local function getCash()
    return BalanceValue.Value or 0
end

local function getHolos()
    return TicketsValue.Value or 0
end

local function getEventPoints()
    local points = 0
    pcall(function()
        for _, c in ipairs(PlayerCurrencies:GetChildren()) do
            local name = c.Name:lower()
            if (name:find("event") or name:find("point") or name:find("sponsor") or name:find("gingerbread")) and c:IsA("ValueBase") then
                points = points + (c.Value or 0)
            end
        end
    end)
    return points
end

local function countTitanHolos()
    local count = 0
    pcall(function()
        local inventory = PlayerData:FindFirstChild("Inventory")
        if inventory then
            for _, item in ipairs(inventory:GetChildren()) do
                local itemName = item.Name
                local itemVal = item:FindFirstChild("Item")
                if itemVal and itemVal:IsA("StringValue") then
                    itemName = itemVal.Value
                end
                if type(itemName) == "string" then
                    local lowerName = itemName:lower()
                    if lowerName:find("titan") and lowerName:find("holo") then
                        count = count + 1
                    end
                end
            end
        end
    end)
    return count
end

local function formatNumber(n)
    local formatted = tostring(math.floor(n))
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

local function hasCurrencyToOpen()
    local holos = getHolos()
    local cash  = getCash()
    local availableEvent = holos - CONFIG.EVENT_STOP_CURRENCY
    local availableCash  = cash - CONFIG.PIQRU_STOP_CASH
    local eventAffordable = EVENT_CASE ~= nil and availableEvent >= EVENT_CASE.price
    return eventAffordable or (availableCash >= 1000)
end

-- ====================================================================================================
-- MULTI-ACCOUNT REGISTRY & PERSISTENT SINGLE-MESSAGE WEBHOOK
-- ====================================================================================================
local ACCOUNTS_REGISTRY_FILE = "case_paradise_accounts.json"
local WEBHOOK_MSG_ID_FILE    = "case_paradise_msg_id.txt"

local function updateAccountRegistry(candyOpened, piqruOpened, status)
    local accounts = {}
    if isfile and isfile(ACCOUNTS_REGISTRY_FILE) then
        pcall(function()
            local content = readfile(ACCOUNTS_REGISTRY_FILE)
            if content and content ~= "" then
                accounts = HttpService:JSONDecode(content) or {}
            end
        end)
    end

    accounts[LocalPlayer.Name] = {
        Username      = LocalPlayer.Name,
        TitanHolos    = countTitanHolos(),
        Cash          = getCash(),
        Holos         = getHolos(),
        EventPoints   = getEventPoints(),
        CandyOpened   = candyOpened or 0,
        PiqruOpened   = piqruOpened or 0,
        Status        = status or "Opening 5x",
        LastUpdated   = os.time()
    }

    if writefile then
        pcall(function()
            writefile(ACCOUNTS_REGISTRY_FILE, HttpService:JSONEncode(accounts))
        end)
    end

    return accounts
end

local function sendDiscordWebhook(title, statusMessage, colorHex, candyOpened, piqruOpened, currentStatus)
    if not CONFIG.DISCORD_WEBHOOK_URL or CONFIG.DISCORD_WEBHOOK_URL == "" or CONFIG.DISCORD_WEBHOOK_URL:find("YOUR_WEBHOOK") then
        return
    end

    if not httpRequest then
        warn("[Case Paradise] HTTP Request function not supported by executor!")
        return
    end

    task.spawn(function()
        local accounts = updateAccountRegistry(candyOpened, piqruOpened, currentStatus or title)

        local totalAccounts    = 0
        local totalTitanHolos  = 0
        local totalCash        = 0
        local totalHolos       = 0
        local totalEventPoints = 0
        local totalCandyOpens  = 0
        local totalPiqruOpens  = 0

        local sortedAccounts = {}
        for _, acc in pairs(accounts) do
            table.insert(sortedAccounts, acc)
        end
        table.sort(sortedAccounts, function(a, b)
            return (a.TitanHolos or 0) > (b.TitanHolos or 0)
        end)

        local tableLines = {
            string.format("%-18s | %-6s | %-11s | %-8s | %-6s | %-10s", "Account", "Titan", "Cash", "Holos", "Event", "Status"),
            string.rep("-", 72)
        }

        for _, acc in ipairs(sortedAccounts) do
            totalAccounts    = totalAccounts + 1
            totalTitanHolos = totalTitanHolos + (acc.TitanHolos or 0)
            totalCash        = totalCash + (acc.Cash or 0)
            totalHolos       = totalHolos + (acc.Holos or 0)
            totalEventPoints = totalEventPoints + (acc.EventPoints or 0)
            totalCandyOpens  = totalCandyOpens + (acc.CandyOpened or 0)
            totalPiqruOpens  = totalPiqruOpens + (acc.PiqruOpened or 0)

            local uname = tostring(acc.Username)
            if #uname > 18 then uname = string.sub(uname, 1, 15) .. "..." end

            local stat = tostring(acc.Status or "Active")
            if #stat > 10 then stat = string.sub(stat, 1, 10) end

            table.insert(tableLines, string.format(
                "%-18s | %-6s | $%-10s | %-8s | %-6s | %-10s",
                uname,
                formatNumber(acc.TitanHolos or 0),
                formatNumber(acc.Cash or 0),
                formatNumber(acc.Holos or 0),
                formatNumber(acc.EventPoints or 0),
                stat
            ))
        end

        table.insert(tableLines, string.rep("-", 72))
        table.insert(tableLines, string.format(
            "%-18s | %-6s | $%-10s | %-8s | %-6s | %-10s",
            "TOTAL (" .. tostring(totalAccounts) .. " Bots)",
            formatNumber(totalTitanHolos),
            formatNumber(totalCash),
            formatNumber(totalHolos),
            formatNumber(totalEventPoints),
            "All Active"
        ))

        local tableText = "```text\n" .. table.concat(tableLines, "\n") .. "\n```"

        local embed = {
            ["title"]       = "📊 Case Paradise - Live Multi-Account Master Dashboard",
            ["description"] = string.format("**Live Event**: %s\n%s", title, statusMessage or ""),
            ["color"]       = colorHex or 0x00E5FF,
            ["fields"]      = {
                {
                    ["name"]   = "🌐 Combined Farm Totals",
                    ["value"]  = string.format(
                        "🐉 **Total Titan Holos:** `%s`\n💰 **Total Cash:** `$%s`\n🎟️ **Total Holos:** `%s`\n🌟 **Total Event Points:** `%s`\n📦 **Total Cases Opened:** Candy: `%s` | Piqru: `%s`",
                        formatNumber(totalTitanHolos),
                        formatNumber(totalCash),
                        formatNumber(totalHolos),
                        formatNumber(totalEventPoints),
                        formatNumber(totalCandyOpens),
                        formatNumber(totalPiqruOpens)
                    ),
                    ["inline"] = false
                },
                {
                    ["name"]   = "👥 All Connected Accounts (" .. tostring(totalAccounts) .. ")",
                    ["value"]  = tableText,
                    ["inline"] = false
                }
            },
            ["footer"] = {
                ["text"] = "Case Paradise Single-Message Live Hub • Updated " .. os.date("%X")
            }
        }

        local payload = HttpService:JSONEncode({
            ["username"] = "Case Paradise Master Hub",
            ["embeds"]   = { embed }
        })

        local existingMsgId = nil
        if isfile and isfile(WEBHOOK_MSG_ID_FILE) then
            pcall(function()
                local rawId = readfile(WEBHOOK_MSG_ID_FILE)
                if rawId and rawId:match("^%d+$") then
                    existingMsgId = rawId:match("^%d+$")
                end
            end)
        end

        local editSuccess = false
        if existingMsgId then
            local patchUrl = CONFIG.DISCORD_WEBHOOK_URL .. "/messages/" .. existingMsgId
            pcall(function()
                local patchRes = httpRequest({
                    Url     = patchUrl,
                    Method  = "PATCH",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = payload
                })
                if patchRes and (patchRes.StatusCode == 200 or patchRes.StatusCode == 204) then
                    editSuccess = true
                end
            end)
        end

        if not editSuccess then
            pcall(function()
                local postUrl = CONFIG.DISCORD_WEBHOOK_URL .. "?wait=true"
                local postRes = httpRequest({
                    Url     = postUrl,
                    Method  = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = payload
                })
                if postRes and postRes.Body and writefile then
                    local decoded = HttpService:JSONDecode(postRes.Body)
                    if decoded and decoded.id then
                        writefile(WEBHOOK_MSG_ID_FILE, tostring(decoded.id))
                    end
                end
            end)
        end
    end)
end

-- ====================================================================================================
-- SCHEDULED 3-HOUR WEBHOOK DISPATCHER
-- ====================================================================================================
-- The old version waited the full 3h BEFORE its first send, but a server hop resets
-- CURRENT_SESSION and kills this thread - so the report could never actually fire.
-- The deadline now lives on disk and survives hops.
local WEBHOOK_CLOCK_FILE = "case_paradise_last_report.txt"

task.spawn(function()
    while getgenv()._ActiveCaseBuyerSession == CURRENT_SESSION do
        local last = 0
        if isfile and isfile(WEBHOOK_CLOCK_FILE) then
            pcall(function() last = tonumber(readfile(WEBHOOK_CLOCK_FILE)) or 0 end)
        end

        if os.time() - last >= CONFIG.WEBHOOK_INTERVAL_HOURS * 3600 then
            pcall(function()
                sendDiscordWebhook(
                    "Scheduled Report",
                    string.format("Automated %dh farm checkpoint update.", CONFIG.WEBHOOK_INTERVAL_HOURS),
                    0x00E5FF, 0, 0,
                    hasCurrencyToOpen() and "Opening Cases" or "Auto-Farming"
                )
            end)
            if writefile then
                pcall(function() writefile(WEBHOOK_CLOCK_FILE, tostring(os.time())) end)
            end
        end

        task.wait(60)
    end
end)

bootLog("webhook defined")

-- ====================================================================================================
-- SERVER HOP / AUTO-REJOIN ENGINE
-- ====================================================================================================
local VISITED_SERVERS_FILE = "case_paradise_visited.json"

pcall(function()
    math.randomseed(os.time() + math.floor((tick() % 1) * 100000))
end)

local function loadVisitedServers()
    if not CONFIG.HOP_REMEMBER_SERVERS then return {} end
    local visited = {}
    if isfile and isfile(VISITED_SERVERS_FILE) then
        pcall(function()
            local raw = readfile(VISITED_SERVERS_FILE)
            if raw and raw ~= "" then
                visited = HttpService:JSONDecode(raw) or {}
            end
        end)
    end
    return visited
end

local function saveVisitedServers(visited)
    if not (CONFIG.HOP_REMEMBER_SERVERS and writefile) then return end
    pcall(function()
        writefile(VISITED_SERVERS_FILE, HttpService:JSONEncode(visited))
    end)
end

-- GET + JSONDecode. Tries game:HttpGet first, falls back to the executor's request().
local function httpGetJson(url)
    local body
    local ok = pcall(function() body = game:HttpGet(url, true) end)

    if not ok or not body or body == "" then
        if not httpRequest then return nil end
        local res
        local ok2 = pcall(function()
            res = httpRequest({ Url = url, Method = "GET" })
        end)
        if not ok2 or not res or not res.Body then return nil end
        body = res.Body
    end

    local decoded
    local ok3 = pcall(function() decoded = HttpService:JSONDecode(body) end)
    if not ok3 then return nil end
    return decoded
end

local function fetchPublicServers()
    local servers, cursor, pages = {}, nil, 0

    repeat
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100",
            game.PlaceId
        )
        if cursor then url = url .. "&cursor=" .. cursor end

        local data = httpGetJson(url)
        if not data or type(data.data) ~= "table" then break end

        for _, s in ipairs(data.data) do
            table.insert(servers, s)
        end

        cursor = data.nextPageCursor
        pages  = pages + 1
    until not cursor or pages >= CONFIG.HOP_MAX_PAGES

    return servers
end

local function pickHopTarget()
    local visited = loadVisitedServers()
    local servers = fetchPublicServers()

    local function collect(ignoreVisited)
        local out = {}
        for _, s in ipairs(servers) do
            if type(s.id) == "string"
                and s.id ~= game.JobId
                and type(s.playing) == "number"
                and type(s.maxPlayers) == "number"
                and s.playing >= CONFIG.HOP_MIN_PLAYERS
                and s.playing < (s.maxPlayers * CONFIG.HOP_MAX_FILL)
                and (ignoreVisited or not visited[s.id])
            then
                table.insert(out, s)
            end
        end
        return out
    end

    local candidates = collect(false)

    -- Exhausted the pool: wipe hop memory and take a fresh pass rather than stalling
    if #candidates == 0 then
        print("[Server Hop] Every known server already visited. Resetting hop memory.")
        visited = {}
        saveVisitedServers(visited)
        candidates = collect(true)
    end

    if #candidates == 0 then return nil, visited end
    return candidates[math.random(1, #candidates)], visited
end

local function queueScriptForNextServer()
    if not queueOnTeleport then return end
    pcall(function()
        local codeToQueue = getgenv().CaseParadiseScriptSource or [[
            if isfile and isfile("case_paradise_script.lua") then
                loadstring(readfile("case_paradise_script.lua"))()
            end
        ]]
        queueOnTeleport(codeToQueue)
    end)
end

local function forceAutoRejoin()
    if not CONFIG.ENABLE_AUTO_REJOIN then
        print("[Case Paradise] Auto-Rejoin is disabled in configuration.")
        return
    end

    print(string.format("[Auto-Rejoin] Mode '%s' - moving in %.1f seconds...",
        tostring(CONFIG.REJOIN_MODE), CONFIG.REJOIN_DELAY))
    task.wait(CONFIG.REJOIN_DELAY)

    queueScriptForNextServer()

    -- "Same" mode: drop back into a fresh instance of this place
    if CONFIG.REJOIN_MODE ~= "Hop" then
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
        return
    end

    -- "Hop" mode: pick a different public server and jump into it
    local attempts = 0
    while attempts < CONFIG.HOP_MAX_ATTEMPTS do
        attempts = attempts + 1

        local target, visited = pickHopTarget()
        if not target then
            warn("[Server Hop] No eligible server found. Falling back to standard rejoin.")
            pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
            return
        end

        visited[target.id] = true
        saveVisitedServers(visited)

        print(string.format("[Server Hop] Attempt %d/%d -> %s (%d/%d players)",
            attempts, CONFIG.HOP_MAX_ATTEMPTS, target.id, target.playing, target.maxPlayers))

        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, LocalPlayer)
        end)

        -- Teleport is async. Still executing after the grace window means it failed; try the next server.
        task.wait(ok and CONFIG.HOP_RETRY_DELAY or 1)
    end

    warn("[Server Hop] All hop attempts failed. Falling back to standard rejoin.")
    pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
end

bootLog("hop engine defined")

-- ====================================================================================================
-- EXTERNAL FARM SCRIPT INTEGRATION
-- ====================================================================================================
-- Any third-party farm script is launched in its own thread so a blocking `while true` loop inside
-- it can never stall the case opener, the hop engine, or the webhook dispatcher.

local function getFarmSource()
    -- Cached across teleports so a hop does not re-download on every server
    if getgenv()._FarmScriptSource and getgenv()._FarmScriptSource ~= "" then
        return getgenv()._FarmScriptSource
    end

    local src

    if CONFIG.AUTO_FARM_SCRIPT_FILE and CONFIG.AUTO_FARM_SCRIPT_FILE ~= "" then
        if isfile and isfile(CONFIG.AUTO_FARM_SCRIPT_FILE) then
            pcall(function() src = readfile(CONFIG.AUTO_FARM_SCRIPT_FILE) end)
            if src and src ~= "" then
                print("[Farm] Loaded farm script from file: " .. CONFIG.AUTO_FARM_SCRIPT_FILE)
            end
        else
            warn("[Farm] AUTO_FARM_SCRIPT_FILE set but not found in workspace: " .. tostring(CONFIG.AUTO_FARM_SCRIPT_FILE))
        end
    end

    if (not src or src == "") and CONFIG.AUTO_FARM_SCRIPT_URL and CONFIG.AUTO_FARM_SCRIPT_URL ~= "" then
        local ok = pcall(function() src = game:HttpGet(CONFIG.AUTO_FARM_SCRIPT_URL, true) end)
        if ok and src and src ~= "" then
            print("[Farm] Loaded farm script from URL.")
        else
            warn("[Farm] Failed to download farm script from URL.")
            src = nil
        end
    end

    if src and src ~= "" then
        getgenv()._FarmScriptSource = src
    end
    return src
end

-- Returns true if an external farm script was actually launched.
local function launchExternalFarm()
    if getgenv()._ExternalFarmRunning then
        print("[Farm] External farm already running - not starting a second copy.")
        return true
    end

    local src = getFarmSource()
    if not src or src == "" then return false end

    local chunk, compileErr = loadstring(src)
    if not chunk then
        warn("[Farm] External farm script failed to compile: " .. tostring(compileErr))
        return false
    end

    getgenv()._ExternalFarmRunning = true

    -- Own thread: a blocking loop inside the farm script cannot reach us here
    task.spawn(function()
        local ok, err = pcall(chunk)
        getgenv()._ExternalFarmRunning = false
        if not ok then
            warn("[Farm] External farm script errored: " .. tostring(err))
        else
            print("[Farm] External farm script finished.")
        end
    end)

    print("[Farm] External farm script launched in background thread.")
    return true
end

-- Built-in fallback farm, used only when no external script is configured
local function launchBuiltinFarm()
    task.spawn(function()
        getgenv()._AutoFarmRunning = true
        print("[Farm] Built-in AFK & Event farming active.")

        pcall(function()
            if Remotes:FindFirstChild("RequestAFK") then
                Remotes.RequestAFK:InvokeServer()
            end
            if Remotes:FindFirstChild("ReadyAFK") then
                Remotes.ReadyAFK:FireServer()
            end
        end)

        while getgenv()._AutoFarmRunning and getgenv()._ActiveCaseBuyerSession == CURRENT_SESSION do
            pcall(function()
                if Remotes:FindFirstChild("ClaimCategoryIndex") then
                    Remotes.ClaimCategoryIndex:FireServer()
                end
                if Remotes:FindFirstChild("Gingerbread") then
                    Remotes.Gingerbread:FireServer()
                end
            end)
            task.wait(5)
        end

        getgenv()._AutoFarmRunning = false
    end)
end

-- Watches currency while farming and hops back into case opening once it is affordable again.
-- This ALWAYS runs, external farm or not - the old code skipped it whenever a URL was configured,
-- which meant the opener could never come back.
local function startCurrencyWatcher()
    if getgenv()._CurrencyWatcherRunning then return end
    getgenv()._CurrencyWatcherRunning = true

    task.spawn(function()
        while getgenv()._ActiveCaseBuyerSession == CURRENT_SESSION do
            task.wait(CONFIG.FARM_WATCH_INTERVAL)

            if hasCurrencyToOpen() then
                print("[Farm] Currency threshold reached - returning to case opening.")
                sendDiscordWebhook(
                    "Currency Accumulated!",
                    "Farm collected enough currency to open cases. Triggering server hop.",
                    0xFFAA00
                )
                getgenv()._AutoFarmRunning = false
                getgenv()._CurrencyWatcherRunning = false
                forceAutoRejoin()
                return
            end
        end
        getgenv()._CurrencyWatcherRunning = false
    end)
end

local function startAutoFarming()
    print("========================================================================")
    print("[Case Paradise] Launching farm engine...")
    print("========================================================================")

    sendDiscordWebhook(
        "Auto-Farm Engine Active",
        "No currency available to open cases. Player handed over to farming mode.",
        0x00FF88
    )

    if not launchExternalFarm() then
        launchBuiltinFarm()
    end

    startCurrencyWatcher()
end

bootLog("farm section defined")

-- ====================================================================================================
-- MAIN WORKFLOW ENGINE
-- ====================================================================================================
print("========================================================================")
print("[Case Paradise Auto Engine] Initializing...")
print(EVENT_CASE
    and string.format("[Priority 1] %s (%s %s) -> 5x Batch | Stop at %s",
        EVENT_CASE.name, tostring(EVENT_CASE.price), EVENT_CASE.currency,
        formatNumber(CONFIG.EVENT_STOP_CURRENCY))
    or "[Priority 1] NO EVENT CASE DETECTED - event opening disabled")
print(string.format("[Priority 2] Piqru Case ($1,000)   -> 5x Batch | Stop at $%s Cash",
    formatNumber(CONFIG.PIQRU_STOP_CASH)))
print(string.format("[Live Stats] Event currency: %s | Cash: $%s | Titan Holos: %d",
    formatNumber(getHolos()), formatNumber(getCash()), countTitanHolos()))
print(string.format("[Timing] Server cooldown ~%.1fs measured | BUY_DELAY=%.2f | backoff=%.2f",
    CONFIG.OPEN_COOLDOWN, CONFIG.BUY_DELAY, CONFIG.COOLDOWN_BACKOFF_DELAY))
print(string.format("[Farm] Mode: %s | Source: %s", tostring(CONFIG.FARM_MODE),
    (CONFIG.AUTO_FARM_SCRIPT_FILE ~= "" and CONFIG.AUTO_FARM_SCRIPT_FILE)
    or (CONFIG.AUTO_FARM_SCRIPT_URL ~= "" and "URL")
    or "built-in"))
print("========================================================================")

-- "Always" mode: farm runs in parallel with case opening instead of only when broke.
-- Its own thread, so a blocking farm loop cannot stall the opener.
if CONFIG.ENABLE_AUTO_FARM and CONFIG.FARM_MODE == "Always" then
    if not launchExternalFarm() then
        launchBuiltinFarm()
    end
end

bootLog("banner printed")

if not hasCurrencyToOpen() then
    print("[Case Paradise] No currency available to open cases on startup.")
    if CONFIG.ENABLE_AUTO_FARM then
        startAutoFarming()
    else
        print("[Case Paradise] Auto-Farm disabled. Script idling.")
    end
else
    bootLog("entering main loop branch")
    task.spawn(function()
    local function mainLoop()
        local candyOpened, piqruOpened = 0, 0

        -- A case whose ID the server keeps rejecting gets retired for the session instead of
        -- being hammered forever (this is what the dead "TechnoCase" ID used to do).
        local candyDead, piqruDead   = false, false
        local candyFails, piqruFails = 0, 0

        sendDiscordWebhook(
            "Case Opener Started",
            string.format("Opening cases in 5x batches. Initial Candy: %s | Cash: $%s",
                formatNumber(getHolos()), formatNumber(getCash())),
            0x00E5FF,
            candyOpened,
            piqruOpened
        )

        -- The server accepts an open roughly every 6s. A rejected call returns false or nil
        -- (never a populated table), so that is the signal to back off rather than retry instantly.
        local function invokeCase(caseId, amount)
            local ok, res = pcall(function()
                return OpenCaseRemote:InvokeServer(caseId, amount)
            end)
            return ok and type(res) == "table" and next(res) ~= nil, res
        end

        while getgenv()._ActiveCaseBuyerSession == CURRENT_SESSION do
            local availableEvent = getHolos() - CONFIG.EVENT_STOP_CURRENCY
            local availableCash  = getCash()  - CONFIG.PIQRU_STOP_CASH

            -- ----------------------------------------------------------------
            -- PRIORITY 1: CANDY CASE (billed from Currencies.Tickets)
            -- ----------------------------------------------------------------
            if EVENT_CASE and not candyDead and availableEvent >= EVENT_CASE.price then
                -- Server only accepts batch sizes of 1 or 5; 2/3/4 are rejected outright.
                local amountToOpen = (availableEvent >= EVENT_CASE.price * 5
                                      and CONFIG.BATCH_AMOUNT >= 5) and 5 or 1

                if invokeCase(EVENT_CASE.id, amountToOpen) then
                    candyOpened = candyOpened + amountToOpen
                    candyFails  = 0
                    print(string.format("[%s x%d] Opened! Total: %d | Remaining %s: %s",
                        EVENT_CASE.name, amountToOpen, candyOpened, EVENT_CASE.currency, formatNumber(getHolos())))
                    task.wait(CONFIG.BUY_DELAY)
                else
                    candyFails = candyFails + 1
                    if candyFails >= CONFIG.MAX_CONSECUTIVE_FAILS then
                        warn(string.format("[Event Case] Rejected %d times in a row - retiring '%s' for this session.",
                            candyFails, tostring(EVENT_CASE.id)))
                        candyDead = true
                    end
                    task.wait(CONFIG.COOLDOWN_BACKOFF_DELAY)
                end

            -- ----------------------------------------------------------------
            -- PRIORITY 2: PIQRU CASE ($1,000 Cash each)
            -- ----------------------------------------------------------------
            elseif not piqruDead and availableCash >= 1000 then
                local amountToOpen = (availableCash >= 5000 and CONFIG.BATCH_AMOUNT >= 5) and 5 or 1

                if invokeCase("PIQRU", amountToOpen) then
                    piqruOpened = piqruOpened + amountToOpen
                    piqruFails  = 0
                    print(string.format("[Piqru Case x%d] Opened! Total: %d | Remaining Cash: $%s",
                        amountToOpen, piqruOpened, formatNumber(getCash())))
                    task.wait(CONFIG.BUY_DELAY)
                else
                    piqruFails = piqruFails + 1
                    if piqruFails >= CONFIG.MAX_CONSECUTIVE_FAILS then
                        warn(string.format("[Piqru Case] Rejected %d times in a row - retiring 'PIQRU' for this session.",
                            piqruFails))
                        piqruDead = true
                    end
                    task.wait(CONFIG.COOLDOWN_BACKOFF_DELAY)
                end

            -- ----------------------------------------------------------------
            -- FINISHED OPENING ALL AVAILABLE CASES
            -- ----------------------------------------------------------------
            else
                print("========================================================================")
                print(string.format("[Case Opener Finished] Total Candy: %d | Total Piqru: %d", candyOpened, piqruOpened))
                print(string.format("[Final Stats] Candy: %s | Cash: $%s | Titan Holos: %d",
                    formatNumber(getHolos()), formatNumber(getCash()), countTitanHolos()))
                if candyDead or piqruDead then
                    warn(string.format("[Case Opener] Retired this session -> Candy: %s | Piqru: %s",
                        tostring(candyDead), tostring(piqruDead)))
                end
                print("========================================================================")

                sendDiscordWebhook(
                    "Case Opening Complete!",
                    string.format("Finished opening cases. Total Candy: **%d** | Total Piqru: **%d**.", candyOpened, piqruOpened),
                    0xFFD700,
                    candyOpened,
                    piqruOpened
                )

                if CONFIG.ENABLE_AUTO_REJOIN then
                    forceAutoRejoin()
                elseif CONFIG.ENABLE_AUTO_FARM then
                    startAutoFarming()
                end

                break
            end
        end
    end

    -- task.spawn swallows errors, which made a dead loop look like "it just does nothing".
    -- Any crash now surfaces as a warning AND lands on disk.
    local ok, err = xpcall(mainLoop, function(e)
        return tostring(e) .. " | " .. debug.traceback()
    end)
    if not ok then
        warn("[Case Paradise] MAIN LOOP CRASHED: " .. tostring(err))
        pcall(function()
            local line = os.date("%X") .. " | MAIN LOOP CRASH: " .. tostring(err) .. "\n"
            if appendfile then
                appendfile("case_paradise_crash.log", line)
            elseif writefile then
                writefile("case_paradise_crash.log", line)
            end
        end)
    end
    end)
end