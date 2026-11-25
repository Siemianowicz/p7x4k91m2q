-- ====================================================================================================
-- CASE PARADISE v4.0 - ONE FILE, EVERY ACCOUNT
-- Cayden305 farming (quests / gifts / clear) + wild PIQRU drain + event drain + sell-all-but-titans
-- + titan stocking (auto-join the stock server, multi-stock failover, caps) + Discord embeds
-- + 3D off + rejoin that reloads itself.
--
-- Load on EVERY account (farms and stocks):   loadstring(readfile("case_paradise_min.lua"))()
--
-- Live settings: edit "cp_settings.json" in the executor workspace. Every account re-reads it every
-- 30s, so changing the stock account (or the webhook) needs no restart. Accounts listed in
-- stock_accounts become stock automatically; everyone else farms.
-- Per-run overrides: getgenv().CP_CONFIG = { DRY_RUN = true } before the loadstring.
-- ====================================================================================================
local DEFAULTS = {
    LOAD_CAYDEN = true,
    SCRIPT_FILE = "case_paradise_min.lua",
    SETTINGS_FILE = "cp_settings.json",
    DRY_RUN = false,

    -- Shared settings (cp_settings.json wins over these, hot reloaded) ----------------------------
    WEBHOOK_URL    = "",            -- the old 1530628648888041553 webhook is deleted, paste a new one
    DROP_MENTION   = "",            -- "@everyone" or "<@discordId>"
    STOCK_ACCOUNTS = {},            -- usernames, in priority order; full or offline ones are skipped
    HOURLY_LIMIT   = 50,            -- farm: max titans sent per hour / stock: max received per hour
    STOCK_CAP      = 200,           -- stock refuses trades at this many titans
    AUTO_JOIN_STOCK = true,         -- farms teleport into the stock's server to deliver titans
    MIN_TITANS_TO_TRAVEL = 5,       -- farm only teleports for a delivery of at least this many

    -- Webhook --------------------------------------------------------------------------------------
    SUMMARY_EVERY = 300,
    DROP_PING     = true,
    DROP_RARITIES = { Special = true, Extraordinary = true, Contraband = true },
    DROP_TITANS   = true,
    TRADE_PING    = true,

    -- Opening ---------------------------------------------------------------------------------------
    EVENT_CASE  = "CyberCase",
    PIQRU_CASE  = "PIQRU",
    PIQRU_WILD  = true,
    BUY_DELAY   = 6.0,
    MAX_FAILS   = 6,
    RETRY_AFTER = 120,

    -- Selling ---------------------------------------------------------------------------------------
    AUTO_SELL     = true,
    SELL_EVERY    = 15,
    SELL_BATCH    = 50,
    KEEP_PATTERNS = { "titan" },

    -- Trading ---------------------------------------------------------------------------------------
    TRADE_ENABLED   = true,
    TRADE_BATCH_MAX = 15,           -- game caps an offer at 15 items
    TRADE_EVERY     = 20,
    STOCK_ACCEPT_ONLY_FARMS = false, -- true = stock only trades with accounts that ran this script on this PC

    -- Client ----------------------------------------------------------------------------------------
    RENDER_OFF_ON_START = true,
    RENDER_TOGGLE_KEY   = Enum.KeyCode.F3,
    ANTI_AFK            = true,
    AUTO_REJOIN         = true,
    AUTO_REJOIN_SEC     = 1100,
}

local SHARED_KEYS = {
    webhook_url = "WEBHOOK_URL", drop_mention = "DROP_MENTION", stock_accounts = "STOCK_ACCOUNTS",
    hourly_limit = "HOURLY_LIMIT", stock_cap = "STOCK_CAP", auto_join_stock = "AUTO_JOIN_STOCK",
    min_titans_to_travel = "MIN_TITANS_TO_TRAVEL",
}

-- ====================================================================================================
-- SERVICES / SESSION
-- ====================================================================================================
local Players     = game:GetService("Players")
local RunService  = game:GetService("RunService")
local UIS         = game:GetService("UserInputService")
local TS          = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local RS          = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local lpName      = LocalPlayer.Name
local VERSION     = "v4.0"

local old = getgenv()._CaseMinSession
if old then
    old.alive = false
    if old.stop then pcall(old.stop) end
end
local conns = {}
local SESSION = { alive = true }
function SESSION.stop()
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    table.clear(conns)
end
getgenv()._CaseMinSession = SESSION
local function alive() return SESSION.alive end
local function on(signal, fn)
    local c = signal:Connect(fn)
    conns[#conns + 1] = c
    return c
end

local function log(fmt, ...) print("[CP] " .. string.format(tostring(fmt), ...)) end
local function warnLog(fmt, ...) warn("[CP] " .. string.format(tostring(fmt), ...)) end

local function fmtInt(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    while true do
        local new, c = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = new
        if c == 0 then break end
    end
    return s
end

local function fsRead(path)
    if not readfile then return nil end
    local ok, v = pcall(readfile, path)
    if ok and type(v) == "string" then return v end
    return nil
end
local function fsWrite(path, body)
    if writefile then pcall(writefile, path, body) end
end
local function jsonRead(path)
    local raw = fsRead(path)
    if not raw or raw == "" then return nil end
    local ok, v = pcall(HttpService.JSONDecode, HttpService, raw)
    return ok and type(v) == "table" and v or nil
end
local function jsonWrite(path, t)
    local ok, s = pcall(HttpService.JSONEncode, HttpService, t)
    if ok then fsWrite(path, s) end
end

-- ====================================================================================================
-- CONFIG: defaults <- cp_settings.json (hot) <- getgenv().CP_CONFIG
-- ====================================================================================================
local CONFIG = table.clone(DEFAULTS)
local overrides = type(getgenv().CP_CONFIG) == "table" and getgenv().CP_CONFIG or {}

local function applySettings(silent)
    local s = jsonRead(CONFIG.SETTINGS_FILE)
    if not s then
        if not fsRead(CONFIG.SETTINGS_FILE) then
            local tpl = {}
            for k, key in pairs(SHARED_KEYS) do tpl[k] = DEFAULTS[key] end
            jsonWrite(CONFIG.SETTINGS_FILE, tpl)
            if not silent then log("created %s, put the stock account(s) and webhook in it", CONFIG.SETTINGS_FILE) end
        end
        s = {}
    end
    local changed = {}
    for k, key in pairs(SHARED_KEYS) do
        local v = s[k]
        if overrides[key] ~= nil then v = overrides[key] end
        if v == nil then v = DEFAULTS[key] end
        if type(v) == type(DEFAULTS[key]) and HttpService:JSONEncode(v) ~= HttpService:JSONEncode(CONFIG[key]) then
            CONFIG[key] = v
            changed[#changed + 1] = key
        end
    end
    if #changed > 0 and not silent then log("settings changed: %s", table.concat(changed, ", ")) end
end
for k, v in pairs(overrides) do if SHARED_KEYS[k] == nil then CONFIG[k] = v end end
applySettings(true)

local function isStockName(name)
    for _, n in ipairs(CONFIG.STOCK_ACCOUNTS) do
        if tostring(n):lower() == name:lower() then return true end
    end
    return false
end
local function role() return isStockName(lpName) and "stock" or "farm" end

-- ====================================================================================================
-- CAYDEN305 FARMING (own thread so it can never stall the rest)
-- ====================================================================================================
if CONFIG.LOAD_CAYDEN and not getgenv()._CP_CaydenLoaded then
    getgenv()._CP_CaydenLoaded = true
    getgenv().autoQuest         = true
    getgenv().autoQuest2        = true
    getgenv().lvlCases          = false -- we open (wild PIQRU)
    getgenv().autoSell          = false -- we sell (titans kept)
    getgenv().winFX             = true
    getgenv().particleNum       = 20
    getgenv().minVal            = 70000
    getgenv().minKey            = Enum.KeyCode.F2
    getgenv().togKey            = Enum.KeyCode.P
    getgenv().autoRejoin        = false -- we rejoin and reload
    getgenv().autoRejoinMinutes = 15
    getgenv().autoClear         = true
    getgenv().autoGifts         = true
    getgenv().invValues         = false
    task.spawn(function()
        local ok, err = pcall(function()
            loadstring(game:HttpGet("https://raw.githubusercontent.com/cayden305/Scripts/refs/heads/main/CaseParadise.lua"))()
        end)
        if ok then log("Cayden farming loaded") else warnLog("Cayden load failed: %s", tostring(err)) end
    end)
end

-- ====================================================================================================
-- GAME TREE
-- ====================================================================================================
local Remotes    = RS:WaitForChild("Remotes", 30)
local Modules    = RS:WaitForChild("Modules", 30)
local PlayerData = LocalPlayer:WaitForChild("PlayerData", 30)
if not (Remotes and Modules and PlayerData) then
    warnLog("game tree missing after 30s, stopping")
    SESSION.alive = false
    return
end
local Inventory  = PlayerData:WaitForChild("Inventory", 30)
local Currencies = PlayerData:WaitForChild("Currencies", 30)

local function safeRequire(m) if not m then return {} end local ok, v = pcall(require, m) return ok and v or {} end
local Cases = safeRequire(Modules:FindFirstChild("Cases"))
local Items = safeRequire(Modules:FindFirstChild("Items"))

local OpenCaseR     = Remotes:WaitForChild("OpenCase", 15)
local SellR         = Remotes:WaitForChild("Sell", 15)
local TradeRequestR = Remotes:FindFirstChild("TradeRequest")
local UpdateOfferR  = Remotes:FindFirstChild("UpdateTradeOffer")
local ChangeStatusR = Remotes:FindFirstChild("ChangeStatusTrade")
local CancelTradeR  = Remotes:FindFirstChild("CancelTrade")
local ReplicateR    = Remotes:FindFirstChild("ReplicateBattle") -- trade window state rides on this one
local WildPrices    = RS:FindFirstChild("Misc") and RS.Misc:FindFirstChild("WildPrices")

local function currency(name)
    local v = Currencies and Currencies:FindFirstChild(name)
    return v and tonumber(v.Value) or 0
end

-- ====================================================================================================
-- ITEMS
-- ====================================================================================================
local function resolveItemId(n)
    if Items[n] then return n end
    local s = n
    while s:match("%d$") do
        s = s:sub(1, #s - 1)
        if Items[s] then return s end
    end
    return nil
end

local function itemValue(id, wear, st)
    local d = Items[id]
    if not d or not d.Wears then return 0 end
    local w = d.Wears[wear] or d.Wears["Factory New"] or d.Wears["Minimal Wear"]
    if not w then return 0 end
    local v = st and tonumber(w.StatTrak) or nil
    if not v or v == -1 then v = tonumber(w.Normal) or 0 end
    return v == -1 and 0 or v
end

local function isKept(id)
    local low = id:lower()
    for _, p in ipairs(CONFIG.KEEP_PATTERNS) do
        if low:find(p:lower(), 1, true) then return true end
    end
    return false
end
local function isTitan(id) return id:lower():find("titan", 1, true) ~= nil end

local function readItem(inst)
    local id = resolveItemId(inst.Name)
    if not id then return nil end
    local uuid = inst:GetAttribute("UUID")
    if not uuid then return nil end
    if inst:GetAttribute("Locked") or inst:GetAttribute("Escrow") or inst:GetAttribute("JackpotEscrow") then return nil end
    local wear = inst:GetAttribute("Wear") or "Factory New"
    local st   = inst:GetAttribute("Stattrak") == true
    return {
        Inst = inst, Id = id, UUID = uuid, Wear = wear, Stattrak = st,
        Age = inst:GetAttribute("TimeObtained") or 0,
        Value = itemValue(id, wear, st),
    }
end

local function scan(filter)
    local out = {}
    for _, inst in ipairs(Inventory:GetChildren()) do
        local r = readItem(inst)
        if r and (not filter or filter(r)) then out[#out + 1] = r end
    end
    return out
end

local function titanCount()
    local n = 0
    for _, inst in ipairs(Inventory:GetChildren()) do
        local id = resolveItemId(inst.Name)
        if id and isTitan(id) then n = n + 1 end
    end
    return n
end

-- ====================================================================================================
-- PERSISTENT STATS (survive rejoins, reset each UTC day)
-- ====================================================================================================
local STATS_FILE = "cp_stats_" .. lpName .. ".json"
local today = os.date("!%Y-%m-%d")
local stats = jsonRead(STATS_FILE)
if not stats or stats.day ~= today then
    stats = { day = today, openedEvent = 0, openedWild = 0, sold = 0, soldValue = 0, sent = 0, received = 0, drops = 0 }
end
local sessionStart = os.time()
local lastCase = "-"
local function saveStats() jsonWrite(STATS_FILE, stats) end
local function bump(k, n)
    if os.date("!%Y-%m-%d") ~= stats.day then
        stats = { day = os.date("!%Y-%m-%d"), openedEvent = 0, openedWild = 0, sold = 0, soldValue = 0, sent = 0, received = 0, drops = 0 }
    end
    stats[k] = (stats[k] or 0) + (n or 1)
end
task.spawn(function() while alive() do task.wait(30) saveStats() end end)

-- ====================================================================================================
-- DISCORD (queued, rate-limit aware, dead-webhook aware)
-- ====================================================================================================
local HTTP_REQ = request or http_request or (syn and syn.request) or (http and http.request) or (fluxus and fluxus.request)

local function httpReq(opts)
    if not HTTP_REQ then return nil end
    local ok, res = pcall(HTTP_REQ, opts)
    if ok and type(res) == "table" then return res end
    return nil
end

local deadWebhook = nil
local function sendJson(url, method, payload)
    if CONFIG.WEBHOOK_URL == "" or deadWebhook == CONFIG.WEBHOOK_URL then return nil end
    local body = HttpService:JSONEncode(payload)
    for _ = 1, 3 do
        local res = httpReq({ Url = url, Method = method, Headers = { ["Content-Type"] = "application/json" }, Body = body })
        if not res then return nil end
        if res.StatusCode == 404 and tostring(res.Body):find("10015", 1, true) then
            deadWebhook = CONFIG.WEBHOOK_URL
            warnLog("webhook is deleted on Discord (Unknown Webhook), put a new one in %s", CONFIG.SETTINGS_FILE)
            return nil
        end
        if res.StatusCode ~= 429 then
            if res.StatusCode >= 300 and res.StatusCode ~= 404 then
                warnLog("webhook HTTP %d: %s", res.StatusCode, tostring(res.Body):sub(1, 160))
            end
            return res
        end
        local okj, d = pcall(HttpService.JSONDecode, HttpService, res.Body or "")
        task.wait(((okj and type(d) == "table" and tonumber(d.retry_after)) or 2) + 0.25)
    end
    return nil
end

local queue = {}
local function enqueue(fn) if #queue < 50 then queue[#queue + 1] = fn end end
task.spawn(function()
    while alive() do
        local job = table.remove(queue, 1)
        if job then
            local ok, err = pcall(job)
            if not ok then warnLog("webhook job failed: %s", tostring(err)) end
            task.wait(1.1)
        else
            task.wait(0.5)
        end
    end
end)

local thumbCache = {}
local function thumbUrl(image)
    local id = tostring(image or ""):match("%d+")
    if not id then return nil end
    if thumbCache[id] ~= nil then return thumbCache[id] or nil end
    local url = false
    local res = httpReq({ Url = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. id .. "&size=420x420&format=Png", Method = "GET" })
    if res and res.Body then
        local ok, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
        if ok and d and d.data and d.data[1] and d.data[1].imageUrl then url = d.data[1].imageUrl end
    end
    thumbCache[id] = url
    return url or nil
end

local function isoNow() return os.date("!%Y-%m-%dT%H:%M:%SZ") end
local function footer() return { text = "Case Paradise " .. VERSION .. " | " .. lpName } end

local function postEmbed(embed, content)
    return sendJson(CONFIG.WEBHOOK_URL, "POST", { content = content, embeds = { embed } })
end

local summaryPath = "cp_summary_" .. lpName .. ".txt"
local summaryId   = fsRead(summaryPath)
local summaryHook = CONFIG.WEBHOOK_URL
local function postSummary(embed)
    if CONFIG.WEBHOOK_URL ~= summaryHook then summaryId, summaryHook = nil, CONFIG.WEBHOOK_URL end
    if summaryId and summaryId ~= "" then
        local res = sendJson(CONFIG.WEBHOOK_URL .. "/messages/" .. summaryId, "PATCH", { embeds = { embed } })
        if res and res.StatusCode and res.StatusCode < 300 then return end
    end
    local res = sendJson(CONFIG.WEBHOOK_URL .. "?wait=true", "POST", { embeds = { embed } })
    if res and res.Body then
        local ok, d = pcall(HttpService.JSONDecode, HttpService, res.Body)
        if ok and d and d.id then
            summaryId = tostring(d.id)
            fsWrite(summaryPath, summaryId)
        end
    end
end

local RARITY_COLOR = {
    Special = 0xE4AE39, Extraordinary = 0xFF8C1A, Contraband = 0xB8860B, Covert = 0xEB4B4B,
    Classified = 0xD32CE6, Restricted = 0x8847FF, ["Mil-Spec"] = 0x4B69FF,
}

-- ====================================================================================================
-- CLIENT: 3D TOGGLE / ANTI-AFK / RELOAD ON EVERY TELEPORT / REJOIN
-- ====================================================================================================
local rendering = true
local function setRendering(state)
    if pcall(function() RunService:Set3dRenderingEnabled(state) end) then rendering = state end
end
on(UIS.InputBegan, function(input, processed)
    if not processed and input.KeyCode == CONFIG.RENDER_TOGGLE_KEY then setRendering(not rendering) end
end)
if CONFIG.RENDER_OFF_ON_START then task.delay(5, function() if alive() then setRendering(false) end end) end

if CONFIG.ANTI_AFK then
    local okVU, VU = pcall(function() return game:GetService("VirtualUser") end)
    if okVU and VU then
        on(LocalPlayer.Idled, function()
            pcall(function() VU:CaptureController() VU:ClickButton2(Vector2.new()) end)
        end)
    end
end

local queued = false
local function requeueSelf()
    if queued then return end
    local q = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
    if q and fsRead(CONFIG.SCRIPT_FILE) then
        queued = true
        local extra = ""
        if next(overrides) then
            local ok, enc = pcall(HttpService.JSONEncode, HttpService, overrides)
            if ok then extra = "getgenv().CP_CONFIG = game:GetService('HttpService'):JSONDecode(" .. string.format("%q", enc) .. ") " end
        end
        pcall(q, extra .. 'loadstring(readfile("' .. CONFIG.SCRIPT_FILE .. '"))()')
    end
end
on(LocalPlayer.OnTeleport, function(state)
    if state == Enum.TeleportState.Started or state == Enum.TeleportState.InProgress then requeueSelf() end
end)

local teleportFailed = nil
on(TS.TeleportInitFailed, function(plr, result, msg)
    if plr == LocalPlayer then
        teleportFailed = tostring(result) .. " " .. tostring(msg)
        queued = false
    end
end)

local busyTrading = false
if CONFIG.AUTO_REJOIN then
    task.spawn(function()
        local due = os.clock() + CONFIG.AUTO_REJOIN_SEC
        while alive() do
            task.wait(5)
            if os.clock() >= due and not busyTrading then
                log("auto rejoin")
                requeueSelf()
                pcall(function() TS:Teleport(game.PlaceId, LocalPlayer) end)
                due = os.clock() + 60
            end
        end
    end)
end

-- ====================================================================================================
-- SPECIAL DROP EMBEDS
-- ====================================================================================================
local incomingTrade = false
on(Inventory.ChildAdded, function(inst)
    task.spawn(function()
        if not CONFIG.DROP_PING then return end
        task.wait(0.3)
        if incomingTrade then return end
        local id = resolveItemId(inst.Name)
        if not id then return end
        local d = Items[id] or {}
        local titan = isTitan(id)
        if not (CONFIG.DROP_RARITIES[d.Rarity] or (CONFIG.DROP_TITANS and titan)) then return end
        local wear  = inst:GetAttribute("Wear") or "?"
        local st    = inst:GetAttribute("Stattrak") == true
        local value = itemValue(id, wear, st)
        local caseName = lastCase
        bump("drops")
        enqueue(function()
            local thumb = thumbUrl(d.Image)
            postEmbed({
                title = titan and "TITAN DROP" or (tostring(d.Rarity or "Special"):upper() .. " DROP"),
                description = "**" .. tostring(d.Name or id) .. "**" .. (st and "  (StatTrak)" or ""),
                color = titan and 0x00E5FF or (RARITY_COLOR[d.Rarity] or 0xE4AE39),
                thumbnail = thumb and { url = thumb } or nil,
                fields = {
                    { name = "Wear",    value = tostring(wear), inline = true },
                    { name = "Value",   value = "$" .. fmtInt(value), inline = true },
                    { name = "Rarity",  value = tostring(d.Rarity or "?"), inline = true },
                    { name = "Case",    value = caseName, inline = true },
                    { name = "Account", value = "||" .. lpName .. "||", inline = true },
                    { name = "Action",  value = isKept(id) and (titan and role() == "farm" and "kept for stock" or "kept") or "auto-sold", inline = true },
                },
                footer = footer(),
                timestamp = isoNow(),
            }, CONFIG.DROP_MENTION ~= "" and CONFIG.DROP_MENTION or nil)
        end)
    end)
end)

-- ====================================================================================================
-- SELL EVERYTHING EXCEPT KEPT ITEMS
-- ====================================================================================================
local function sellOne(r)
    local ok, res = pcall(SellR.InvokeServer, SellR, { { Name = r.Id, Wear = r.Wear, Stattrak = r.Stattrak, Age = r.Age, UUID = r.UUID } })
    return ok and tonumber(res) or nil
end

local function sellSweep()
    if not CONFIG.AUTO_SELL or not SellR or busyTrading then return end
    local items = scan(function(r) return not isKept(r.Id) end)
    if #items == 0 then return end
    if CONFIG.DRY_RUN then
        local sum = 0
        for _, r in ipairs(items) do sum = sum + r.Value end
        log("[DRY] would sell %d items (~$%s)", #items, fmtInt(sum))
        return
    end
    local soldNow, valueNow, i = 0, 0, 1
    while i <= #items and alive() do
        local batch, recs = {}, {}
        while #batch < CONFIG.SELL_BATCH and i <= #items do
            local r = items[i]
            i = i + 1
            if r.Inst.Parent then
                batch[#batch + 1] = { Name = r.Id, Wear = r.Wear, Stattrak = r.Stattrak, Age = r.Age, UUID = r.UUID }
                recs[#recs + 1] = r
            end
        end
        if #batch > 0 then
            local ok, res = pcall(SellR.InvokeServer, SellR, batch)
            if ok and tonumber(res) then valueNow = valueNow + tonumber(res) end
            task.wait(0.5)
            for _, r in ipairs(recs) do
                if not r.Inst.Parent then
                    soldNow = soldNow + 1
                else
                    local got = sellOne(r)
                    if got then soldNow = soldNow + 1 valueNow = valueNow + got end
                    task.wait(0.25)
                end
            end
        end
    end
    if soldNow > 0 then
        bump("sold", soldNow)
        bump("soldValue", valueNow)
        log("sold %d items for $%s", soldNow, fmtInt(valueNow))
    end
    local left = #scan(function(r) return not isKept(r.Id) end)
    if left > 0 then warnLog("%d sellable items still in inventory after sweep", left) end
end

task.spawn(function()
    while alive() do
        local ok, err = pcall(sellSweep)
        if not ok then warnLog("sell sweep error: %s", tostring(err)) end
        task.wait(CONFIG.SELL_EVERY)
    end
end)

-- ====================================================================================================
-- OPENER: every event point and every dollar
-- ====================================================================================================
local function priceOf(id, wild)
    if wild and WildPrices then
        local v = WildPrices:FindFirstChild(id)
        if v then return tonumber(v.Value) end
    end
    return Cases[id] and tonumber(Cases[id].Price) or nil
end

local eventCases = {}
for name, d in pairs(Cases) do
    if type(d) == "table" and d.Currency and d.Currency ~= "Balance" and tonumber(d.Price) then
        eventCases[#eventCases + 1] = { id = name, price = tonumber(d.Price), fails = 0, pausedUntil = 0, wild = false, bill = "Tickets", label = name }
    end
end
table.sort(eventCases, function(a, b)
    local pa = (a.id == CONFIG.EVENT_CASE) and -1 or a.price
    local pb = (b.id == CONFIG.EVENT_CASE) and -1 or b.price
    if pa == pb then return a.id < b.id end
    return pa < pb
end)

local piqruId = Cases[CONFIG.PIQRU_CASE] and CONFIG.PIQRU_CASE or nil
local piqru = piqruId and {
    id = piqruId, price = priceOf(piqruId, CONFIG.PIQRU_WILD), fails = 0, pausedUntil = 0,
    wild = CONFIG.PIQRU_WILD, bill = "Balance", label = piqruId .. (CONFIG.PIQRU_WILD and " (Wild)" or ""),
} or nil

local function tryOpen(c)
    if os.clock() < c.pausedUntil or not c.price then return "skip" end
    local bal = currency(c.bill)
    if bal < c.price then return "broke" end
    local amount = (bal >= c.price * 5) and 5 or 1
    if CONFIG.DRY_RUN then
        log("[DRY] would open %s x%d (balance %s)", c.label, amount, fmtInt(bal))
        c.pausedUntil = os.clock() + 60
        return "dry"
    end
    lastCase = c.label
    local ok, res = pcall(OpenCaseR.InvokeServer, OpenCaseR, c.id, amount, true, c.wild == true)
    if ok and type(res) == "table" and next(res) ~= nil then
        c.fails = 0
        bump(c.bill == "Tickets" and "openedEvent" or "openedWild", amount)
        return "ok"
    end
    c.fails = c.fails + 1
    if c.fails >= CONFIG.MAX_FAILS then
        c.fails = 0
        c.pausedUntil = os.clock() + CONFIG.RETRY_AFTER
        warnLog("%s rejected %d times, pausing %ds", c.label, CONFIG.MAX_FAILS, CONFIG.RETRY_AFTER)
    end
    return "fail"
end

local function openLoop()
    log("event cases: %d | piqru: %s @ %s", #eventCases, piqru and piqru.label or "missing", piqru and fmtInt(piqru.price) or "-")
    while alive() do
        local fired = false
        if not busyTrading then
            for _, c in ipairs(eventCases) do
                local r = tryOpen(c)
                if r == "ok" or r == "fail" then fired = true task.wait(CONFIG.BUY_DELAY) break end
                if r == "broke" then break end -- one Tickets pool for every event case
            end
            if piqru and alive() and not busyTrading then
                local r = tryOpen(piqru)
                if r == "ok" or r == "fail" then fired = true task.wait(CONFIG.BUY_DELAY) end
            end
        end
        if not fired then task.wait(3) end
    end
end

-- ====================================================================================================
-- TITAN STOCKING
-- Game flow (TradingScript): TradeRequest:FireServer(target, nil) -> target answers
-- TradeRequest:FireServer(sender, true|false) -> ReplicateBattle.OnClientEvent(folder, partner) opens the
-- window (folder[name] = BoolValue ready, children = offered items, folder.Value = countdown)
-- -> UpdateTradeOffer:InvokeServer({{Name,Wear,Stattrak,UUID}...}) -> ChangeStatusTrade:FireServer(true)
-- on both sides -> ~5s countdown -> items move. CancelTrade:FireServer(false) aborts.
--
-- Shared workspace files (every client on this PC sees them):
--   cp_stock_<name>.json   stock heartbeat: job, place, titans, full, time   (stock writes every 20s)
--   cp_farm_<name>.json    farm heartbeat: titans waiting, time               (farm writes every 20s)
--   CP_sent_<name>.txt / CP_recv_<name>.txt   rolling-hour ledgers
-- ====================================================================================================
local function newLedger(path)
    local L = { path = path, t = {} }
    for line in (fsRead(path) or ""):gmatch("[^\r\n]+") do
        local n = tonumber(line)
        if n then L.t[#L.t + 1] = n end
    end
    function L:count()
        local now, keep = os.time(), {}
        for _, n in ipairs(self.t) do if now - n < 3600 then keep[#keep + 1] = n end end
        self.t = keep
        return #keep
    end
    function L:nextFreeIn()
        self:count()
        if #self.t < CONFIG.HOURLY_LIMIT then return 0 end
        table.sort(self.t)
        return math.max(0, self.t[#self.t - CONFIG.HOURLY_LIMIT + 1] + 3600 - os.time())
    end
    function L:add(n)
        local now = os.time()
        for _ = 1, n do self.t[#self.t + 1] = now end
        self:count()
        local lines = {}
        for _, v in ipairs(self.t) do lines[#lines + 1] = tostring(v) end
        fsWrite(self.path, table.concat(lines, "\n"))
    end
    return L
end

local myRole = role()
local ledger = newLedger((myRole == "stock" and "CP_recv_" or "CP_sent_") .. lpName .. ".txt")
local function stockFile(name) return "cp_stock_" .. name:lower() .. ".json" end
local function farmFile(name) return "cp_farm_" .. name:lower() .. ".json" end

local trade = { folder = nil, partner = nil, denied = false, cancelled = false }
local stockWatching = {}

local function tradePing(title, desc, color)
    if not CONFIG.TRADE_PING then return end
    enqueue(function()
        postEmbed({ title = title, description = desc, color = color, footer = footer(), timestamp = isoNow() })
    end)
end

local function knownFarm(name)
    local f = jsonRead(farmFile(name))
    return f ~= nil and (os.time() - (tonumber(f.time) or 0)) < 3600
end

-- --- stock side -------------------------------------------------------------------------------------
local function stockRoom()
    return math.min(CONFIG.STOCK_CAP - titanCount(), CONFIG.HOURLY_LIMIT - ledger:count())
end

local function watchStockTrade(folder, partner)
    if stockWatching[folder] then return end
    stockWatching[folder] = true
    busyTrading = true
    incomingTrade = true
    local before = titanCount()
    local readied = false
    local t0 = os.clock()
    while folder.Parent and alive() and os.clock() - t0 < 90 do
        local theirs = folder:FindFirstChild(partner.Name)
        local mine   = folder:FindFirstChild(lpName)
        local offered = theirs and #theirs:GetChildren() or 0
        if offered > stockRoom() then
            log("refusing %d titans from %s (room %d)", offered, partner.Name, stockRoom())
            pcall(CancelTradeR.FireServer, CancelTradeR, false)
            break
        end
        if theirs and theirs.Value == true and offered > 0 and mine and mine.Value ~= true then
            pcall(ChangeStatusR.FireServer, ChangeStatusR, true)
            readied = true
        end
        task.wait(0.4)
    end
    if folder.Parent and os.clock() - t0 >= 90 then pcall(CancelTradeR.FireServer, CancelTradeR, false) end
    task.wait(2)
    local got = titanCount() - before
    if got > 0 then
        ledger:add(got)
        bump("received", got)
        log("received %d titans from %s (stock %d/%d)", got, partner.Name, titanCount(), CONFIG.STOCK_CAP)
        tradePing("TITANS RECEIVED", string.format("**+%d** from ||%s||\nstock **%d/%d**, hour %d/%d",
            got, partner.Name, titanCount(), CONFIG.STOCK_CAP, ledger:count(), CONFIG.HOURLY_LIMIT), 0x57F287)
        if titanCount() >= CONFIG.STOCK_CAP then
            tradePing("STOCK FULL", string.format("||%s|| holds %d titans, farms move to the next stock account", lpName, titanCount()), 0xED4245)
        end
    elseif readied then
        log("trade with %s ended with nothing received", partner.Name)
    end
    stockWatching[folder] = nil
    busyTrading = next(stockWatching) ~= nil
    task.delay(3, function() if not busyTrading then incomingTrade = false end end)
end

-- --- remote listeners (both roles) -------------------------------------------------------------------
if TradeRequestR and ReplicateR then
    on(TradeRequestR.OnClientEvent, function(who, answer)
        if typeof(who) ~= "Instance" or not who:IsA("Player") then return end
        if answer ~= nil then
            if answer ~= true then trade.denied = true end
            return
        end
        if myRole ~= "stock" or not CONFIG.TRADE_ENABLED then return end
        local allowed = (not CONFIG.STOCK_ACCEPT_ONLY_FARMS) or knownFarm(who.Name)
        local ok = allowed and stockRoom() > 0 and not busyTrading
        if CONFIG.DRY_RUN then log("[DRY] would %s trade from %s", ok and "accept" or "deny", who.Name) return end
        pcall(TradeRequestR.FireServer, TradeRequestR, who, ok)
        if not ok then
            log("denied trade from %s (%s)", who.Name, not allowed and "not a farm" or (busyTrading and "busy" or "no room"))
        end
    end)

    on(ReplicateR.OnClientEvent, function(folder, partner)
        if typeof(folder) ~= "Instance" or typeof(partner) ~= "Instance" then return end
        trade.folder, trade.partner = folder, partner
        if myRole == "stock" and CONFIG.TRADE_ENABLED then task.spawn(watchStockTrade, folder, partner) end
    end)

    if CancelTradeR then
        on(CancelTradeR.OnClientEvent, function() trade.cancelled = true end)
    end
end

-- --- farm side --------------------------------------------------------------------------------------
local badJobs = {}

local function pickStock()
    -- first listed stock account that is alive, fresh and has room
    for _, name in ipairs(CONFIG.STOCK_ACCOUNTS) do
        name = tostring(name)
        if name:lower() ~= lpName:lower() then
            local s = jsonRead(stockFile(name))
            local inServer = Players:FindFirstChild(name)
            local fresh = s and (os.time() - (tonumber(s.time) or 0)) < 90
            if fresh and not s.full then
                return name, s, inServer
            elseif not s and inServer then
                return name, nil, inServer -- same server but on another PC, no heartbeat
            end
        end
    end
    return nil
end

local function farmPush(stockPlayer)
    local budget = CONFIG.HOURLY_LIMIT - ledger:count()
    if budget <= 0 then return string.format("hourly limit reached, next slot in %ds", ledger:nextFreeIn()) end
    local titans = scan(function(r) return isTitan(r.Id) end)
    if #titans == 0 then return "no titans" end
    table.sort(titans, function(a, b) return a.Value > b.Value end)
    local n = math.min(#titans, budget, CONFIG.TRADE_BATCH_MAX)
    if CONFIG.DRY_RUN then return string.format("[DRY] would send %d titans to %s", n, stockPlayer.Name) end

    busyTrading = true
    trade.folder, trade.partner, trade.denied, trade.cancelled = nil, nil, false, false
    pcall(TradeRequestR.FireServer, TradeRequestR, stockPlayer, nil)
    local t0 = os.clock()
    while alive() and not trade.folder and not trade.denied and os.clock() - t0 < 20 do task.wait(0.25) end
    local folder = trade.folder
    if not folder or trade.partner ~= stockPlayer then
        busyTrading = false
        if folder then pcall(CancelTradeR.FireServer, CancelTradeR, false) end
        return trade.denied and "stock denied the request" or "no answer from stock"
    end

    local offer = {}
    for i = 1, n do
        offer[i] = { Name = titans[i].Id, Wear = titans[i].Wear, Stattrak = titans[i].Stattrak, UUID = titans[i].UUID }
    end
    pcall(UpdateOfferR.InvokeServer, UpdateOfferR, offer)
    task.wait(1)

    local function moved()
        local m = 0
        for i = 1, n do if not titans[i].Inst.Parent then m = m + 1 end end
        return m
    end
    t0 = os.clock()
    while alive() and folder.Parent and not trade.cancelled and os.clock() - t0 < 45 do
        local mine = folder:FindFirstChild(lpName)
        if mine then
            if #mine:GetChildren() == 0 and os.clock() - t0 > 3 then
                pcall(UpdateOfferR.InvokeServer, UpdateOfferR, offer) -- offer got wiped, put it back
            elseif mine.Value ~= true then
                pcall(ChangeStatusR.FireServer, ChangeStatusR, true)
            end
        end
        if moved() >= n then break end
        task.wait(1)
    end
    if folder.Parent and moved() == 0 then pcall(CancelTradeR.FireServer, CancelTradeR, false) end
    task.wait(2)
    busyTrading = false
    local m = moved()
    if m > 0 then
        ledger:add(m)
        bump("sent", m)
        tradePing("TITANS SENT", string.format("**%d** to ||%s||\nhour %d/%d, %d left on this account",
            m, stockPlayer.Name, ledger:count(), CONFIG.HOURLY_LIMIT, titanCount()), 0x5865F2)
        return string.format("sent %d titans to %s (hour %d/%d)", m, stockPlayer.Name, ledger:count(), CONFIG.HOURLY_LIMIT)
    end
    return trade.cancelled and "trade cancelled" or "trade timed out"
end

local lastTravel = 0
local function farmTick()
    if #CONFIG.STOCK_ACCOUNTS == 0 then return "no stock_accounts in " .. CONFIG.SETTINGS_FILE end
    local titans = titanCount()
    jsonWrite(farmFile(lpName), { titans = titans, job = game.JobId, time = os.time() })
    if titans == 0 then return "no titans" end
    local name, s, here = pickStock()
    if not name then return "every stock account is full or offline" end
    if here then return farmPush(here) end
    if not CONFIG.AUTO_JOIN_STOCK or not s then return name .. " is not in this server" end
    if CONFIG.HOURLY_LIMIT - ledger:count() <= 0 then
        return string.format("hourly limit reached, next slot in %ds", ledger:nextFreeIn())
    end
    if titans < CONFIG.MIN_TITANS_TO_TRAVEL then
        return string.format("%d titans, waiting for %d before joining %s", titans, CONFIG.MIN_TITANS_TO_TRAVEL, name)
    end
    if s.place ~= game.PlaceId or not s.job or s.job == game.JobId then return name .. " heartbeat has no usable server" end
    if badJobs[s.job] and os.clock() < badJobs[s.job] then return name .. "'s server refused us, retrying later" end
    if os.clock() - lastTravel < 120 then return "travel cooldown" end
    if CONFIG.DRY_RUN then return "[DRY] would teleport to " .. name .. "'s server" end
    lastTravel = os.clock()
    teleportFailed = nil
    log("joining %s's server to deliver %d titans", name, titans)
    requeueSelf()
    pcall(function() TS:TeleportToPlaceInstance(s.place, s.job, LocalPlayer) end)
    local t0 = os.clock()
    while alive() and os.clock() - t0 < 25 and not teleportFailed do task.wait(0.5) end
    if teleportFailed then
        badJobs[s.job] = os.clock() + 600
        return "teleport to " .. name .. " failed: " .. teleportFailed
    end
    return "teleporting"
end

local function stockTick()
    local titans = titanCount()
    local full = titans >= CONFIG.STOCK_CAP
    jsonWrite(stockFile(lpName), {
        name = lpName, job = game.JobId, place = game.PlaceId, titans = titans,
        full = full, hour = ledger:count(), players = #Players:GetPlayers(), time = os.time(),
    })
    return string.format("stock %d/%d, hour %d/%d%s", titans, CONFIG.STOCK_CAP, ledger:count(), CONFIG.HOURLY_LIMIT, full and " FULL" or "")
end

local function tradeLoop()
    if not (TradeRequestR and UpdateOfferR and ChangeStatusR and CancelTradeR and ReplicateR) then
        warnLog("trade remotes missing, stocking off")
        return
    end
    local lastMsg, lastAt = nil, 0
    while alive() do
        if CONFIG.TRADE_ENABLED then
            local msg = (myRole == "stock") and stockTick() or farmTick()
            if msg ~= lastMsg or os.clock() - lastAt > 300 then
                log("stocking: %s", msg)
                lastMsg, lastAt = msg, os.clock()
            end
        end
        task.wait(CONFIG.TRADE_EVERY)
    end
end

-- settings hot reload (role flips too: add/remove a name in stock_accounts)
task.spawn(function()
    while alive() do
        task.wait(30)
        applySettings(false)
        local r = role()
        if r ~= myRole then
            log("role changed %s -> %s", myRole, r)
            myRole = r
            ledger = newLedger((myRole == "stock" and "CP_recv_" or "CP_sent_") .. lpName .. ".txt")
        end
    end
end)

-- ====================================================================================================
-- SUMMARY EMBED
-- ====================================================================================================
local function summary(state)
    local runtime = os.time() - sessionStart
    local tradeLine
    if myRole == "stock" then
        tradeLine = string.format("received %d today\nhour %d/%d\nstock %d/%d", stats.received, ledger:count(), CONFIG.HOURLY_LIMIT, titanCount(), CONFIG.STOCK_CAP)
    elseif #CONFIG.STOCK_ACCOUNTS > 0 then
        tradeLine = string.format("sent %d today\nhour %d/%d", stats.sent, ledger:count(), CONFIG.HOURLY_LIMIT)
    else
        tradeLine = "no stock account set"
    end
    enqueue(function()
        postSummary({
            title = "Case Paradise | " .. lpName,
            description = state .. " | role **" .. myRole .. "**" .. (CONFIG.DRY_RUN and " | DRY RUN" or ""),
            color = myRole == "stock" and 0x00E5FF or 0x57F287,
            fields = {
                { name = "Balance",  value = "$" .. fmtInt(currency("Balance")), inline = true },
                { name = "Tickets",  value = fmtInt(currency("Tickets")), inline = true },
                { name = "Titans",   value = tostring(titanCount()), inline = true },
                { name = "Opened today", value = string.format("event %s\nwild piqru %s", fmtInt(stats.openedEvent), fmtInt(stats.openedWild)), inline = true },
                { name = "Sold today",   value = string.format("%s items\n$%s", fmtInt(stats.sold), fmtInt(stats.soldValue)), inline = true },
                { name = "Stocking",     value = tradeLine, inline = true },
                { name = "Special drops today", value = tostring(stats.drops), inline = true },
                { name = "Server",   value = #Players:GetPlayers() .. " players", inline = true },
                { name = "Session",  value = string.format("%dh%02dm", math.floor(runtime / 3600), math.floor(runtime / 60) % 60), inline = true },
            },
            footer = footer(),
            timestamp = isoNow(),
        })
    end)
end

-- ====================================================================================================
-- BOOT
-- ====================================================================================================
local function guarded(name, fn)
    task.spawn(function()
        local ok, err = xpcall(fn, debug.traceback)
        if not ok and alive() then
            warnLog("%s crashed: %s", name, tostring(err))
            enqueue(function()
                postEmbed({ title = name .. " crashed", description = "```" .. tostring(err):sub(1, 1500) .. "```", color = 0xED4245, footer = footer(), timestamp = isoNow() })
            end)
        end
    end)
end

guarded("opener", openLoop)
guarded("stocking", tradeLoop)
task.spawn(function()
    summary("started")
    while alive() do
        task.wait(CONFIG.SUMMARY_EVERY)
        if alive() then summary("running") end
    end
end)

log("%s ready | role=%s | stocks=%s | dry=%s", VERSION, myRole,
    #CONFIG.STOCK_ACCOUNTS > 0 and table.concat(CONFIG.STOCK_ACCOUNTS, ",") or "-", tostring(CONFIG.DRY_RUN))
if CONFIG.WEBHOOK_URL == "" then warnLog("no webhook set, put webhook_url in %s", CONFIG.SETTINGS_FILE) end
