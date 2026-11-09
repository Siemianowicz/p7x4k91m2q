-- ====================================================================================================
-- CASE PARADISE - MIN v2.0
-- Wild Piqru drain + event case drain + titan stocking + webhook + 3D render toggle + auto rejoin.
-- Standalone. Safe to run alongside Cayden305's wrapper if you set his lvlCases=false.
-- ====================================================================================================
local CONFIG = {
    -- Webhook -------------------------------------------------------------------------------------
    WEBHOOK_URL   = "https://discord.com/api/webhooks/1530628648888041553/yUVjHpL9SHcEukSfveiQUfsJSEjPViw64ssTOlrdRRdiJvy7JvCx1G2jGMwbP46To1CK",
    WEBHOOK_EVERY = 300,

    -- Role ----------------------------------------------------------------------------------------
    -- "farm"  = sends titans to the stocking account
    -- "stock" = receives titans, counts them, auto-accepts incoming, enforces the 200 cap
    ROLE           = "farm",
    STOCK_USERNAME = "enforcer1111",            -- << CHANGE THIS to the stocking account's Roblox username (case-insensitive)

    -- Drain (no stops) ----------------------------------------------------------------------------
    EVENT_CASE    = "CyberCase",    -- current rotation (CyberCase/HalloweenCase @ 10 CPU); auto-resolved if gone
    PIQRU_CASE    = "PIQRU",        -- confirmed live 11-09
    PIQRU_WILD    = true,           -- open PIQRU in WILD MODE (4th arg of OpenCase, costs ~19,107 via Misc.WildPrices)
    BUY_DELAY     = 6.0,
    BACKOFF_DELAY = 1.0,
    MAX_FAILS     = 8,

    -- Auto-sell -----------------------------------------------------------------------------------
    AUTO_SELL      = true,
    SELL_MAX_VALUE = 70000,
    SELL_EVERY     = 60,
    SELL_BATCH     = 50,
    SELL_MIN_ITEMS = 10,
    KEEP_PATTERNS  = { "holo", "titan", "kato", "dreamhack", "krakow" },
    KEEP_RARITIES  = { Special = true, Extraordinary = true, Contraband = true },

    -- Titan stocking -----------------------------------------------------------------------------
    TRADE_ENABLED      = true,
    TRADE_HOURLY_LIMIT = 50,          -- max titans each farm acc can send per rolling hour
    STOCK_CAP          = 200,         -- stop sending once the stocking acc holds this many titans
    TITAN_PATTERNS     = { "titan" }, -- substring(s) identifying a titan item
    TRADE_CHECK_EVERY  = 45,          -- seconds between trade attempts / stock count writes
    TRADE_BATCH_MAX    = 10,          -- max titans pushed per attempt (anti-spam)

    -- 3D rendering ---------------------------------------------------------------------------------
    RENDER_OFF_ON_START = true,
    RENDER_TOGGLE_KEY   = Enum.KeyCode.F3,

    -- Auto rejoin ----------------------------------------------------------------------------------
    AUTO_REJOIN     = true,
    AUTO_REJOIN_SEC = 1100,
}

-- ====================================================================================================
-- SERVICES
-- ====================================================================================================
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local TS          = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local lpName      = LocalPlayer.Name

-- Session guard: kill any prior copy
if getgenv()._CaseMinSession then
    getgenv()._CaseMinSession.alive = false
end
local SESSION = { alive = true, id = tick() }
getgenv()._CaseMinSession = SESSION
local function alive() return SESSION.alive end

-- ====================================================================================================
-- UTIL
-- ====================================================================================================
local function log(fmt, ...)
    print("[CP2] " .. string.format(tostring(fmt), ...))
end
local function warnLog(fmt, ...)
    warn("[CP2] " .. string.format(tostring(fmt), ...))
end
local function fmtInt(n)
    n = tonumber(n) or 0
    local s = tostring(math.floor(n))
    while true do
        local new, c = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = new
        if c == 0 then break end
    end
    return s
end

local HTTP_REQ = (syn and syn.request)
    or (http and http.request)
    or (http_request)
    or (request)
    or (fluxus and fluxus.request)

local msgIdPath = "case_min_msg_id.txt"
local msgId     = nil
if isfile and isfile(msgIdPath) then
    local ok, v = pcall(readfile, msgIdPath)
    if ok and v and #v > 0 then msgId = v end
end

local function webhookSend(content)
    if not HTTP_REQ or CONFIG.WEBHOOK_URL == "" then return end
    local body = HttpService:JSONEncode({ content = content })
    local url  = CONFIG.WEBHOOK_URL
    if msgId then
        url = url .. "/messages/" .. msgId
        local ok, res = pcall(HTTP_REQ, {
            Url = url, Method = "PATCH",
            Headers = { ["Content-Type"] = "application/json" },
            Body = body,
        })
        if ok and res and res.StatusCode and res.StatusCode < 300 then return end
        msgId = nil
    end
    local ok, res = pcall(HTTP_REQ, {
        Url = CONFIG.WEBHOOK_URL .. "?wait=true", Method = "POST",
        Headers = { ["Content-Type"] = "application/json" },
        Body = body,
    })
    if ok and res and res.Body then
        local okj, dec = pcall(function() return HttpService:JSONDecode(res.Body) end)
        if okj and dec and dec.id then
            msgId = tostring(dec.id)
            if writefile then pcall(writefile, msgIdPath, msgId) end
        end
    end
end

local function fsWrite(path, body)
    if writefile then pcall(writefile, path, body) end
end
local function fsRead(path)
    if isfile and isfile(path) and readfile then
        local ok, v = pcall(readfile, path)
        if ok then return v end
    end
    return nil
end

-- ====================================================================================================
-- WAIT FOR GAME TREE
-- ====================================================================================================
local Remotes, Modules
local t0 = tick()
while (not Remotes or not Modules) and tick() - t0 < 20 and alive() do
    Remotes = Remotes or RS:FindFirstChild("Remotes")
    Modules = Modules or RS:FindFirstChild("Modules")
    task.wait(0.25)
end
if not Remotes or not Modules then
    warnLog("Remotes/Modules missing after 20s. Bailing.")
    SESSION.alive = false
    return
end

local function safeRequire(mod)
    if not mod then return nil end
    local ok, v = pcall(require, mod)
    if ok then return v end
    return nil
end
local Cases = safeRequire(Modules:FindFirstChild("Cases")) or {}
local Items = safeRequire(Modules:FindFirstChild("Items")) or {}

local OpenCaseR = Remotes:FindFirstChild("OpenCase")
local SellR     = Remotes:FindFirstChild("Sell")
if not OpenCaseR then warnLog("Remotes.OpenCase missing"); SESSION.alive = false; return end

-- ====================================================================================================
-- CASE RESOLUTION
-- ====================================================================================================
local function resolveEventCase()
    local want = CONFIG.EVENT_CASE
    if want and Cases[want] then return want end
    -- cheapest non-Balance case
    local bestName, bestPrice
    for name, data in pairs(Cases) do
        if type(data) == "table" and data.Currency and data.Currency ~= "Balance" then
            local p = tonumber(data.Price) or math.huge
            if not bestPrice or p < bestPrice then
                bestPrice = p; bestName = name
            end
        end
    end
    return bestName
end

local function resolvePiqru()
    if Cases[CONFIG.PIQRU_CASE] then return CONFIG.PIQRU_CASE end
    -- community case with ForBattles=true is the Piqru equivalent
    for name, data in pairs(Cases) do
        if type(data) == "table" and data.ForBattles and name:upper():find("PIQRU") then
            return name
        end
    end
    return nil
end

local WildPrices = RS:FindFirstChild("Misc") and RS.Misc:FindFirstChild("WildPrices")
local function priceOf(caseId, wild)
    if wild and WildPrices then
        local wp = WildPrices:FindFirstChild(caseId)
        if wp then return tonumber(wp.Value) end
    end
    return Cases[caseId] and tonumber(Cases[caseId].Price) or 0
end

local eventCaseId = resolveEventCase()
local piqruCaseId = resolvePiqru()

local eventPrice = eventCaseId and priceOf(eventCaseId, false) or 10
local piqruPrice = piqruCaseId and priceOf(piqruCaseId, CONFIG.PIQRU_WILD) or 1000
local eventCurr  = (eventCaseId and Cases[eventCaseId] and Cases[eventCaseId].Currency) or "?"

log("Event case: %s @ %.1f (%s)", tostring(eventCaseId), eventPrice, eventCurr)
log("Piqru case: %s @ %.1f (wild=%s)", tostring(piqruCaseId), piqruPrice, tostring(CONFIG.PIQRU_WILD))

-- ====================================================================================================
-- CURRENCY HELPERS (Tickets covers Candy/Leaves per CanAffordCase)
-- ====================================================================================================
local function getCurrency(kind)
    local pd = LocalPlayer:FindFirstChild("PlayerData") or RS:FindFirstChild("PlayerData")
    pd = pd and pd:FindFirstChild("Currencies")
    if not pd then return 0 end
    if kind == "Balance" then
        local c = pd:FindFirstChild("Balance")
        return c and c.Value or 0
    end
    -- event cases bill Tickets
    local c = pd:FindFirstChild("Tickets")
    return c and c.Value or 0
end

-- ====================================================================================================
-- 3D RENDERING TOGGLE
-- ====================================================================================================
local rendering = true
local function setRendering(on)
    local ok, err = pcall(function()
        RunService:Set3dRenderingEnabled(on)
    end)
    if ok then
        rendering = on
        log("3D rendering: %s", on and "ON" or "OFF")
    else
        warnLog("3D rendering toggle unavailable: %s", tostring(err))
    end
end

if getgenv()._CaseMinRenderConn then
    pcall(function() getgenv()._CaseMinRenderConn:Disconnect() end)
end
getgenv()._CaseMinRenderConn = UIS.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == CONFIG.RENDER_TOGGLE_KEY then
        setRendering(not rendering)
    end
end)

-- ====================================================================================================
-- ANTI-AFK
-- ====================================================================================================
do
    local ok, VU = pcall(function() return game:GetService("VirtualUser") end)
    if ok and VU then
        if getgenv()._CaseMinAntiAfk then
            pcall(function() getgenv()._CaseMinAntiAfk:Disconnect() end)
        end
        pcall(function()
            getgenv()._CaseMinAntiAfk = LocalPlayer.Idled:Connect(function()
                pcall(function()
                    VU:CaptureController()
                    VU:ClickButton2(Vector2.new())
                end)
            end)
            log("Anti-AFK armed")
        end)
    end
end

-- ====================================================================================================
-- AUTO REJOIN
-- ====================================================================================================
if CONFIG.AUTO_REJOIN then
    task.spawn(function()
        local mySess = SESSION.id
        task.wait(CONFIG.AUTO_REJOIN_SEC)
        if SESSION.id ~= mySess or not alive() then return end
        log("Auto-rejoin after %ds", CONFIG.AUTO_REJOIN_SEC)
        pcall(function() TS:Teleport(game.PlaceId, LocalPlayer) end)
    end)
end

-- ====================================================================================================
-- INVENTORY RESOLUTION
-- ====================================================================================================
local function findInventoryFolder()
    -- Case Paradise stores drops as named instances under a per-player folder.
    local pd = LocalPlayer:FindFirstChild("PlayerData")
    if pd then
        local inv = pd:FindFirstChild("Inventory") or pd:FindFirstChild("Items") or pd:FindFirstChild("Skins")
        if inv then return inv end
    end
    local bp = LocalPlayer:FindFirstChild("Backpack")
    local shared = RS:FindFirstChild("PlayerData") and RS.PlayerData:FindFirstChild(lpName)
    if shared then
        local inv = shared:FindFirstChild("Inventory") or shared:FindFirstChild("Items")
        if inv then return inv end
    end
    return nil
end

local function resolveItemId(instName)
    if Items[instName] then return instName end
    local s = instName
    while s:match("%d$") do
        s = s:sub(1, #s - 1)
        if Items[s] then return s end
    end
    return nil
end

local function itemValue(id, wear, stattrak)
    local d = Items[id]
    if not d or not d.Wears then return 0 end
    local w = d.Wears[wear] or d.Wears["Factory New"] or d.Wears["Minimal Wear"]
    if not w then return 0 end
    local val = stattrak and tonumber(w.StatTrak) or nil
    if not val or val == -1 then val = tonumber(w.Normal) or 0 end
    if val == -1 then val = 0 end
    return val
end

local function isProtected(id)
    local low = id:lower()
    for _, pat in ipairs(CONFIG.KEEP_PATTERNS) do
        if low:find(pat:lower(), 1, true) then return true end
    end
    local d = Items[id]
    if d and d.Rarity and CONFIG.KEEP_RARITIES[d.Rarity] then return true end
    return false
end

local function isTitan(id)
    local low = id:lower()
    for _, pat in ipairs(CONFIG.TITAN_PATTERNS) do
        if low:find(pat:lower(), 1, true) then return true end
    end
    return false
end

local function scanInventory(filter)
    local inv = findInventoryFolder()
    if not inv then return {} end
    local out = {}
    for _, inst in ipairs(inv:GetDescendants()) do
        local id = resolveItemId(inst.Name)
        if id then
            local uuid    = inst:GetAttribute("UUID")
            local wear    = inst:GetAttribute("Wear") or "Factory New"
            local statt   = inst:GetAttribute("Stattrak") or false
            local age     = inst:GetAttribute("TimeObtained") or 0
            local locked  = inst:GetAttribute("Locked") or false
            local escrow  = inst:GetAttribute("Escrow") or false
            local jescrow = inst:GetAttribute("JackpotEscrow") or false
            if uuid and not locked and not escrow and not jescrow then
                local rec = {
                    Inst = inst, Id = id, UUID = uuid,
                    Wear = wear, Stattrak = statt, Age = age,
                    Value = itemValue(id, wear, statt),
                }
                if not filter or filter(rec) then
                    table.insert(out, rec)
                end
            end
        end
    end
    return out
end

-- ====================================================================================================
-- AUTO-SELL
-- ====================================================================================================
local totalSold, totalSoldValue = 0, 0

local function sellSweep(force)
    if not CONFIG.AUTO_SELL or not SellR then return 0 end
    local items = scanInventory(function(r)
        if isProtected(r.Id) then return false end
        return r.Value > 0 and r.Value < CONFIG.SELL_MAX_VALUE
    end)
    if not force and #items < CONFIG.SELL_MIN_ITEMS then return 0 end
    local soldHere, soldValueHere = 0, 0
    local i = 1
    while i <= #items and alive() do
        local batch = {}
        for j = 1, CONFIG.SELL_BATCH do
            local r = items[i]; if not r then break end
            table.insert(batch, {
                Name = r.Id, Wear = r.Wear,
                Stattrak = r.Stattrak, Age = r.Age, UUID = r.UUID,
            })
            i = i + 1
        end
        if #batch == 0 then break end
        local ok, res = pcall(function()
            return SellR:InvokeServer(batch)
        end)
        if ok and res ~= nil then
            for _, b in ipairs(batch) do
                local v = itemValue(b.Name, b.Wear, b.Stattrak)
                soldHere = soldHere + 1
                soldValueHere = soldValueHere + v
            end
        end
        task.wait(0.3)
    end
    if soldHere > 0 then
        totalSold = totalSold + soldHere
        totalSoldValue = totalSoldValue + soldValueHere
        log("Sold %d items for %s", soldHere, fmtInt(soldValueHere))
    end
    return soldHere
end

if CONFIG.AUTO_SELL then
    task.spawn(function()
        local mySess = SESSION.id
        while alive() and SESSION.id == mySess do
            pcall(sellSweep, false)
            for _ = 1, CONFIG.SELL_EVERY do
                if not alive() then return end
                task.wait(1)
            end
        end
    end)
end

-- ====================================================================================================
-- OPENER (event drain + wild piqru drain, no stops)
-- ====================================================================================================
local openedEvent, openedPiqru = 0, 0

local function tryOpen(caseId, amount, wildFlag)
    local ok, res = pcall(function()
        return OpenCaseR:InvokeServer(caseId, amount, true, wildFlag == true)
    end)
    if not ok then return false end
    if type(res) == "table" and next(res) ~= nil then return true end
    return false
end

local function openLoop()
    local mySess = SESSION.id
    local failsE, failsP = 0, 0
    local retiredE, retiredP = false, false
    while alive() and SESSION.id == mySess do
        -- Event case
        if eventCaseId and not retiredE then
            local tickets = getCurrency("Tickets")
            if tickets >= eventPrice then
                local amount = (tickets >= eventPrice * 5) and 5 or 1
                if tryOpen(eventCaseId, amount, false) then
                    openedEvent = openedEvent + amount
                    failsE = 0
                else
                    failsE = failsE + 1
                    if failsE >= CONFIG.MAX_FAILS then
                        retiredE = true
                        warnLog("Event case retired after %d fails", failsE)
                    else
                        task.wait(CONFIG.BACKOFF_DELAY)
                    end
                end
            end
        end
        if not alive() then return end
        task.wait(CONFIG.BUY_DELAY)

        -- Wild Piqru
        if piqruCaseId and not retiredP then
            local cash = getCurrency("Balance")
            if cash >= piqruPrice then
                local amount = (cash >= piqruPrice * 5) and 5 or 1
                if tryOpen(piqruCaseId, amount, CONFIG.PIQRU_WILD) then
                    openedPiqru = openedPiqru + amount
                    failsP = 0
                else
                    failsP = failsP + 1
                    if failsP >= CONFIG.MAX_FAILS then
                        retiredP = true
                        warnLog("Piqru retired after %d fails", failsP)
                    else
                        task.wait(CONFIG.BACKOFF_DELAY)
                    end
                end
            end
        end
        task.wait(CONFIG.BUY_DELAY)
    end
end

-- ====================================================================================================
-- TITAN STOCKING
-- ====================================================================================================
-- Coordination (same PC via Volt workspace files):
--   CP_stock_count.txt  -> "<count>\n<timestamp>\n<username>"   (stock writes; farms read)
--   CP_sent_<user>.txt  -> one timestamp per line of titans this farm acc sent in the last 3600s
--
-- Stock role: counts own titans every TRADE_CHECK_EVERY, writes file, auto-accepts incoming trades.
-- Farm role : respects stock cap + per-acc hourly limit, pushes titans via discovered trade remote.

local STOCK_FILE = "CP_stock_count.txt"
local function sentFilePath()
    return "CP_sent_" .. lpName .. ".txt"
end

local function readStockStatus()
    local raw = fsRead(STOCK_FILE)
    if not raw then return nil end
    local count, ts, who = raw:match("^(%-?%d+)%s*\n(%-?%d+)%s*\n(.-)%s*$")
    count = tonumber(count); ts = tonumber(ts)
    if not count or not ts then return nil end
    return { count = count, ts = ts, who = who or "" }
end

local function writeStockStatus(count)
    fsWrite(STOCK_FILE, string.format("%d\n%d\n%s", count, os.time(), lpName))
end

local function pruneSentLedger()
    local raw = fsRead(sentFilePath()) or ""
    local keep = {}
    local now = os.time()
    for line in raw:gmatch("[^\r\n]+") do
        local n = tonumber(line)
        if n and (now - n) < 3600 then
            table.insert(keep, tostring(n))
        end
    end
    fsWrite(sentFilePath(), table.concat(keep, "\n"))
    return #keep
end

local function recordSent(n)
    local raw = fsRead(sentFilePath()) or ""
    local now = os.time()
    local lines = { raw }
    for _ = 1, n do
        table.insert(lines, tostring(now))
    end
    fsWrite(sentFilePath(), table.concat(lines, "\n"))
end

-- --- Trade remote probe ---------------------------------------------------------------------------
local TRADE_CANDIDATES = {}
local function probeTradeRemotes()
    local scan = Remotes:GetDescendants()
    local byName = {}
    for _, r in ipairs(scan) do
        if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then
            local n = r.Name:lower()
            if n:find("trade") or n:find("gift") or n:find("send") or n:find("offer") then
                table.insert(TRADE_CANDIDATES, r)
                byName[r.Name] = (byName[r.Name] or 0) + 1
            end
        end
    end
    local names = {}
    for _, r in ipairs(TRADE_CANDIDATES) do table.insert(names, r.Name) end
    log("Trade remote candidates: %s", table.concat(names, ", "))
    if #TRADE_CANDIDATES == 0 then
        warnLog("No trade/gift remote found - dumping all remote names to webhook for mapping")
        local all = {}
        for _, r in ipairs(scan) do
            if r:IsA("RemoteEvent") or r:IsA("RemoteFunction") then
                table.insert(all, r.Name)
            end
        end
        webhookSend("**[CP2 probe]** No trade remote matched. All remotes under Remotes:\n```\n"
            .. table.concat(all, ", ") .. "\n```")
    else
        webhookSend("**[CP2 probe]** Trade remote candidates: `" .. table.concat(names, ", ") .. "`")
    end
end

local function invokeTrade(remote, target, items)
    -- Try several common signatures. Returns first non-nil result or nil.
    local attempts = {
        function() return remote:InvokeServer(target, items) end,
        function() return remote:InvokeServer(target.UserId, items) end,
        function() return remote:FireServer(target, items) end,
        function() return remote:FireServer(target.UserId, items) end,
        function() return remote:InvokeServer({ Player = target, Items = items }) end,
        function() return remote:InvokeServer({ Target = target.UserId, Items = items }) end,
    }
    for _, fn in ipairs(attempts) do
        local ok, res = pcall(fn)
        if ok then return res end
    end
    return nil
end

local function findStockPlayer()
    if CONFIG.STOCK_USERNAME == "" then return nil end
    local target = CONFIG.STOCK_USERNAME:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and p.Name:lower() == target then return p end
    end
    return nil
end

-- --- Stock role: count + auto-accept ---------------------------------------------------------------
local function stockLoop()
    local mySess = SESSION.id
    probeTradeRemotes()
    -- Attempt to auto-accept on every trade-like RemoteEvent
    for _, r in ipairs(TRADE_CANDIDATES) do
        if r:IsA("RemoteEvent") then
            pcall(function()
                r.OnClientEvent:Connect(function(...)
                    local args = {...}
                    log("Incoming trade event %s with %d args - attempting auto-accept", r.Name, #args)
                    pcall(r.FireServer, r, "Accept", table.unpack(args))
                    pcall(r.FireServer, r, true, table.unpack(args))
                end)
            end)
        end
    end
    while alive() and SESSION.id == mySess do
        local titans = scanInventory(function(r) return isTitan(r.Id) end)
        writeStockStatus(#titans)
        if #titans >= CONFIG.STOCK_CAP then
            log("Stock at cap: %d titans", #titans)
        end
        for _ = 1, CONFIG.TRADE_CHECK_EVERY do
            if not alive() then return end
            task.wait(1)
        end
    end
end

-- --- Farm role: send titans -----------------------------------------------------------------------
local function farmTradeLoop()
    local mySess = SESSION.id
    probeTradeRemotes()
    while alive() and SESSION.id == mySess do
        if CONFIG.TRADE_ENABLED and CONFIG.STOCK_USERNAME ~= "" then
            local stock = findStockPlayer()
            if stock and #TRADE_CANDIDATES > 0 then
                -- stock cap check
                local status = readStockStatus()
                local okCap = true
                if status and (os.time() - status.ts) < 300 then
                    if status.count >= CONFIG.STOCK_CAP then
                        okCap = false
                    end
                end
                if okCap then
                    -- rate limit
                    local sentThisHour = pruneSentLedger()
                    local budget = CONFIG.TRADE_HOURLY_LIMIT - sentThisHour
                    if budget > 0 then
                        local titans = scanInventory(function(r) return isTitan(r.Id) end)
                        if #titans > 0 then
                            local n = math.min(#titans, budget, CONFIG.TRADE_BATCH_MAX)
                            local pack = {}
                            for i = 1, n do
                                table.insert(pack, {
                                    Name = titans[i].Id,
                                    UUID = titans[i].UUID,
                                    Wear = titans[i].Wear,
                                    Stattrak = titans[i].Stattrak,
                                    Age = titans[i].Age,
                                })
                            end
                            -- try each candidate until one returns non-nil
                            local sent = false
                            for _, r in ipairs(TRADE_CANDIDATES) do
                                local res = invokeTrade(r, stock, pack)
                                if res ~= nil then
                                    sent = true
                                    log("Trade attempt via %s: result=%s", r.Name, tostring(res))
                                    break
                                end
                            end
                            if sent then
                                recordSent(n)
                                log("Sent %d titans to %s (hour used: %d/%d)",
                                    n, stock.Name, sentThisHour + n, CONFIG.TRADE_HOURLY_LIMIT)
                            end
                        end
                    else
                        log("Hourly titan send limit reached for %s", lpName)
                    end
                else
                    log("Stock acc full (%d >= %d) - holding", status.count, CONFIG.STOCK_CAP)
                end
            end
        end
        for _ = 1, CONFIG.TRADE_CHECK_EVERY do
            if not alive() then return end
            task.wait(1)
        end
    end
end

-- ====================================================================================================
-- WEBHOOK SUMMARY
-- ====================================================================================================
local startTime = os.time()

local function summary(status)
    local titans = scanInventory(function(r) return isTitan(r.Id) end)
    local tickets = getCurrency("Tickets")
    local cash    = getCurrency("Balance")
    local lines = {
        string.format("**Case Paradise - %s** `%s`", status or "running", lpName),
        string.format("Role: `%s` | Stock user: `%s`", CONFIG.ROLE, CONFIG.STOCK_USERNAME ~= "" and CONFIG.STOCK_USERNAME or "(not set)"),
        string.format("Event: %s x%d | Piqru: %s x%d (wild=%s)",
            tostring(eventCaseId), openedEvent, tostring(piqruCaseId), openedPiqru, tostring(CONFIG.PIQRU_WILD)),
        string.format("Tickets: %s | Balance: %s", fmtInt(tickets), fmtInt(cash)),
        string.format("Sold: %d (%s) | Titans in bag: %d",
            totalSold, fmtInt(totalSoldValue), #titans),
    }
    if CONFIG.ROLE == "stock" then
        local status = readStockStatus()
        if status then
            table.insert(lines, string.format("Stock file: %d titans @ %ds ago (by %s)",
                status.count, os.time() - status.ts, status.who))
        end
    else
        local sentHour = pruneSentLedger()
        table.insert(lines, string.format("Sent this hour: %d/%d",
            sentHour, CONFIG.TRADE_HOURLY_LIMIT))
    end
    local runtime = os.time() - startTime
    table.insert(lines, string.format("Runtime: %dh%02dm",
        math.floor(runtime / 3600), math.floor(runtime / 60) % 60))
    webhookSend(table.concat(lines, "\n"))
end

if CONFIG.WEBHOOK_EVERY > 0 then
    task.spawn(function()
        local mySess = SESSION.id
        while alive() and SESSION.id == mySess do
            pcall(summary, "running")
            for _ = 1, CONFIG.WEBHOOK_EVERY do
                if not alive() then return end
                task.wait(1)
            end
        end
    end)
end

-- ====================================================================================================
-- BOOT
-- ====================================================================================================
log("CP2 boot. Role=%s Stock=%s", CONFIG.ROLE,
    CONFIG.STOCK_USERNAME ~= "" and CONFIG.STOCK_USERNAME or "(unset)")

if CONFIG.RENDER_OFF_ON_START then
    task.spawn(function()
        task.wait(5)
        setRendering(false)
    end)
end

pcall(summary, "boot")

task.spawn(function()
    local ok, err = xpcall(openLoop, debug.traceback)
    if not ok then
        warnLog("openLoop crashed: %s", tostring(err))
        pcall(webhookSend, "**[CP2]** openLoop CRASHED\n```\n" .. tostring(err) .. "\n```")
    end
end)

if CONFIG.TRADE_ENABLED then
    task.spawn(function()
        if CONFIG.ROLE == "stock" then
            local ok, err = xpcall(stockLoop, debug.traceback)
            if not ok then
                warnLog("stockLoop crashed: %s", tostring(err))
                pcall(webhookSend, "**[CP2]** stockLoop CRASHED\n```\n" .. tostring(err) .. "\n```")
            end
        else
            local ok, err = xpcall(farmTradeLoop, debug.traceback)
            if not ok then
                warnLog("farmTradeLoop crashed: %s", tostring(err))
                pcall(webhookSend, "**[CP2]** farmTradeLoop CRASHED\n```\n" .. tostring(err) .. "\n```")
            end
        end
    end)
end

log("CP2 ready")
