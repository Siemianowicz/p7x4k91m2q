-- ====================================================================================================
-- CASE PARADISE - MINIMAL CORE
-- Case opening + auto sell + Discord webhook. Nothing else.
-- ====================================================================================================
local CONFIG = {
    WEBHOOK_URL   = "https://discord.com/api/webhooks/1482520113440755732/rcin7A70aRm-Mr8Vgtl90O1WDQJmi0Uc5IcTqSEbzpFNt4vcfRFAN2ZEd-s_tQBHh8VG",
    WEBHOOK_EVERY = 300,          -- Seconds between webhook updates (0 = only start/finish)

    EVENT_CASE    = "CandyCase",  -- Event case ID; auto-detected if this one is gone
    EVENT_STOP    = 50,        -- Stop opening event cases when event currency <= this
    PIQRU_STOP    = 100000,       -- Stop opening Piqru when Balance <= this

    BUY_DELAY     = 6.0,          -- Server accepts one open per ~5.8s (measured live)
    BACKOFF_DELAY = 1.0,          -- Wait after a rejected open
    MAX_FAILS     = 8,            -- Retire a case after this many rejections in a row

    -- Auto sell -------------------------------------------------------------------------------------
    AUTO_SELL      = true,        -- Sell junk automatically while opening
    SELL_MAX_VALUE = 70000,       -- Sell items worth strictly LESS than this
    SELL_EVERY     = 60,          -- Seconds between sell sweeps
    SELL_BATCH     = 50,          -- Items per Sell call
    SELL_MIN_ITEMS = 10,          -- Do not bother sweeping for fewer than this many sellable items
    KEEP_PATTERNS  = {            -- NEVER sell an item whose ID contains any of these, at any value
        "holo",
        "titan",
    },
}

-- ---------------------------------------------------------------------------------------------------
-- Services
-- ---------------------------------------------------------------------------------------------------
if not game:IsLoaded() then game.Loaded:Wait() end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService       = game:GetService("HttpService")
local LocalPlayer       = Players.LocalPlayer or Players.PlayerAdded:Wait()

local Remotes    = ReplicatedStorage:WaitForChild("Remotes")
local OpenCase   = Remotes:WaitForChild("OpenCase")
local SellRemote = Remotes:WaitForChild("Sell")
local PlayerData = LocalPlayer:WaitForChild("PlayerData")
local Currencies = PlayerData:WaitForChild("Currencies")
local Inventory  = PlayerData:WaitForChild("Inventory")
local Balance    = Currencies:WaitForChild("Balance")
local Tickets    = Currencies:WaitForChild("Tickets")   -- event currency lives here

local httpRequest = (syn and syn.request) or http_request or (fluxus and fluxus.request) or request

local SESSION = tick()
getgenv()._CaseMinSession = SESSION

local function getCandy() return Tickets.Value or 0 end
local function getCash()  return Balance.Value or 0 end

local function fmt(n)
    local s = tostring(math.floor(n))
    local k
    repeat
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return s
end

local totalSold, totalSoldValue = 0, 0

-- ---------------------------------------------------------------------------------------------------
-- Resolve the event case (auto-detects if the configured ID has been removed)
-- ---------------------------------------------------------------------------------------------------
local EVENT_ID, EVENT_PRICE, EVENT_NAME

do
    local ok, Cases = pcall(function() return require(ReplicatedStorage.Modules.Cases) end)
    if ok and type(Cases) == "table" then
        local d = Cases[CONFIG.EVENT_CASE]
        if type(d) == "table" and d.Price then
            EVENT_ID    = CONFIG.EVENT_CASE
            EVENT_PRICE = d.Price
            EVENT_NAME  = d.Name or CONFIG.EVENT_CASE
        else
            -- configured case is gone (this is what happened to TechnoCase) - find the live one
            for key, c in pairs(Cases) do
                if type(c) == "table" and type(c.Price) == "number" and c.Price > 0 then
                    local ticketPriced = type(c.Currency) == "string" and c.Currency ~= "Balance"
                    if ticketPriced and (not EVENT_PRICE or c.Price < EVENT_PRICE) then
                        EVENT_ID    = key
                        EVENT_PRICE = c.Price
                        EVENT_NAME  = c.Name or key
                    end
                end
            end
        end
    end
end

if EVENT_ID then
    print(string.format("[Case] Event case: %s (%s) @ %s", tostring(EVENT_NAME), tostring(EVENT_ID), tostring(EVENT_PRICE)))
else
    warn("[Case] No event case found - only Piqru will run.")
end

-- ---------------------------------------------------------------------------------------------------
-- Auto sell
--   Sell remote  : Remotes.Sell:InvokeServer({ {Name=id, Wear=w, Stattrak=b, Age=t, UUID=u}, ... })
--                  returns nil on failure, non-nil on success
--   Price source : Modules.Items[id].Wears[wear].Normal / .StatTrak   (-1 = variant does not exist)
--   Item data    : PlayerData.Inventory children, attributes UUID / Wear / Stattrak /
--                  TimeObtained (= the "Age" field) / Locked / Escrow
-- ---------------------------------------------------------------------------------------------------
local Items = nil
if CONFIG.AUTO_SELL then
    local ok, mod = pcall(function() return require(ReplicatedStorage.Modules.Items) end)
    if ok and type(mod) == "table" then
        Items = mod
    else
        warn("[Sell] Items module unavailable - auto sell disabled.")
    end
end

-- Inventory instances are named "<ItemId><counter>", e.g. "DesertEagle_HeatTreated389".
-- 91 real item IDs legitimately END in a digit (ButterflyKnife_GammaDopplerPhase2, Money3,
-- NinjasinPyjamasKato2014), so strip ONE digit at a time and take the FIRST (longest) match.
local function resolveId(instName)
    if Items[instName] then return instName end
    local s = instName
    while s:match("%d$") do
        s = s:sub(1, #s - 1)
        if Items[s] then return s end
    end
    return nil
end

local function valueOf(id, wear, stattrak)
    local d = Items[id]
    if not d or type(d.Wears) ~= "table" then return nil end
    local w = d.Wears[wear]
    if type(w) ~= "table" then return nil end
    local v = stattrak and w.StatTrak or w.Normal
    if type(v) ~= "number" or v < 0 then v = w.Normal end
    return type(v) == "number" and v or nil
end

local function isProtected(id)
    local low = id:lower()
    for _, pat in ipairs(CONFIG.KEEP_PATTERNS) do
        if low:find(pat:lower(), 1, true) then return true end
    end
    return false
end

-- Returns soldCount, soldValue
local function sellSweep()
    if not Items then return 0, 0 end

    local toSell, sellValue = {}, 0

    for _, item in ipairs(Inventory:GetChildren()) do
        local id = resolveId(item.Name)
        if id
            and item:GetAttribute("Locked") ~= true
            and item:GetAttribute("Escrow") ~= true
            and item:GetAttribute("JackpotEscrow") ~= true
            and not isProtected(id)
        then
            local wear     = item:GetAttribute("Wear")
            local stattrak = item:GetAttribute("Stattrak") == true
            local value    = valueOf(id, wear, stattrak)
            if value and value < CONFIG.SELL_MAX_VALUE then
                sellValue = sellValue + value
                toSell[#toSell + 1] = {
                    Name     = id,
                    Wear     = wear,
                    Stattrak = stattrak,
                    Age      = item:GetAttribute("TimeObtained") or 0,
                    UUID     = item:GetAttribute("UUID"),
                }
            end
        end
    end

    if #toSell < CONFIG.SELL_MIN_ITEMS then return 0, 0 end

    local sold = 0
    for i = 1, #toSell, CONFIG.SELL_BATCH do
        local batch = {}
        for j = i, math.min(i + CONFIG.SELL_BATCH - 1, #toSell) do
            batch[#batch + 1] = toSell[j]
        end
        local ok, res = pcall(function() return SellRemote:InvokeServer(batch) end)
        if ok and res ~= nil then
            sold = sold + #batch
        end
        task.wait(0.3)
    end

    if sold > 0 then
        totalSold      = totalSold + sold
        totalSoldValue = totalSoldValue + sellValue
        print(string.format("[Sell] Sold %d items (~%s) | session total %d", sold, fmt(sellValue), totalSold))
    end
    return sold, sellValue
end

-- ---------------------------------------------------------------------------------------------------
-- Discord webhook (single message, edited in place)
-- ---------------------------------------------------------------------------------------------------
local MSG_ID_FILE = "case_min_msg_id.txt"

local function sendWebhook(title, colour, eventOpened, piqruOpened)
    if not httpRequest or CONFIG.WEBHOOK_URL == "" then return end

    task.spawn(function()
        local payload = HttpService:JSONEncode({
            username = "Case Paradise",
            embeds = { {
                title = "Case Paradise - " .. tostring(title),
                color = colour or 0x00E5FF,
                fields = {
                    { name = "Account",  value = "`" .. LocalPlayer.Name .. "`", inline = true },
                    { name = "Opened",   value = string.format("Event: `%d`\nPiqru: `%d`", eventOpened or 0, piqruOpened or 0), inline = true },
                    { name = "Currency", value = string.format("Event: `%s`\nCash: `$%s`", fmt(getCandy()), fmt(getCash())), inline = true },
                    { name = "Sold",     value = string.format("`%d` items\n~`%s`", totalSold, fmt(totalSoldValue)), inline = true },
                },
                footer = { text = os.date("%X") },
            } },
        })

        local id
        if isfile and isfile(MSG_ID_FILE) then
            pcall(function() id = readfile(MSG_ID_FILE):match("^%d+$") end)
        end

        local edited = false
        if id then
            pcall(function()
                local r = httpRequest({
                    Url     = CONFIG.WEBHOOK_URL .. "/messages/" .. id,
                    Method  = "PATCH",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = payload,
                })
                edited = r ~= nil and (r.StatusCode == 200 or r.StatusCode == 204)
            end)
        end

        if not edited then
            pcall(function()
                local r = httpRequest({
                    Url     = CONFIG.WEBHOOK_URL .. "?wait=true",
                    Method  = "POST",
                    Headers = { ["Content-Type"] = "application/json" },
                    Body    = payload,
                })
                if r and r.Body and writefile then
                    local decoded = HttpService:JSONDecode(r.Body)
                    if decoded and decoded.id then
                        writefile(MSG_ID_FILE, tostring(decoded.id))
                    end
                end
            end)
        end
    end)
end

-- ---------------------------------------------------------------------------------------------------
-- Sell loop (own thread, so a sweep never disturbs the 6s open cadence)
-- ---------------------------------------------------------------------------------------------------
if CONFIG.AUTO_SELL and Items then
    task.spawn(function()
        while getgenv()._CaseMinSession == SESSION do
            task.wait(CONFIG.SELL_EVERY)
            pcall(sellSweep)
        end
    end)
    print(string.format("[Sell] Auto sell ON - under %s every %ds, keeping: %s",
        fmt(CONFIG.SELL_MAX_VALUE), CONFIG.SELL_EVERY, table.concat(CONFIG.KEEP_PATTERNS, ", ")))
end

-- ---------------------------------------------------------------------------------------------------
-- Open loop
-- ---------------------------------------------------------------------------------------------------
local function invoke(id, amount)
    local ok, res = pcall(function() return OpenCase:InvokeServer(id, amount) end)
    return ok and type(res) == "table" and next(res) ~= nil
end

task.spawn(function()
    local eventOpened, piqruOpened = 0, 0
    local eventDead, piqruDead     = false, false
    local eventFails, piqruFails   = 0, 0
    local lastReport               = os.time()

    sendWebhook("Started", 0x00E5FF, 0, 0)

    local ok, err = pcall(function()
        while getgenv()._CaseMinSession == SESSION do
            local candyLeft = getCandy() - CONFIG.EVENT_STOP
            local cashLeft  = getCash()  - CONFIG.PIQRU_STOP

            if EVENT_ID and not eventDead and candyLeft >= EVENT_PRICE then
                -- server accepts batches of 1 or 5 only
                local n = (candyLeft >= EVENT_PRICE * 5) and 5 or 1
                if invoke(EVENT_ID, n) then
                    eventOpened = eventOpened + n
                    eventFails  = 0
                    print(string.format("[%s x%d] total %d | left %s", tostring(EVENT_NAME), n, eventOpened, fmt(getCandy())))
                    task.wait(CONFIG.BUY_DELAY)
                else
                    eventFails = eventFails + 1
                    if eventFails >= CONFIG.MAX_FAILS then
                        warn("[Case] Event case rejected " .. eventFails .. "x - retiring it.")
                        eventDead = true
                    end
                    task.wait(CONFIG.BACKOFF_DELAY)
                end

            elseif not piqruDead and cashLeft >= 1000 then
                local n = (cashLeft >= 5000) and 5 or 1
                if invoke("PIQRU", n) then
                    piqruOpened = piqruOpened + n
                    piqruFails  = 0
                    print(string.format("[Piqru x%d] total %d | left $%s", n, piqruOpened, fmt(getCash())))
                    task.wait(CONFIG.BUY_DELAY)
                else
                    piqruFails = piqruFails + 1
                    if piqruFails >= CONFIG.MAX_FAILS then
                        warn("[Case] Piqru rejected " .. piqruFails .. "x - retiring it.")
                        piqruDead = true
                    end
                    task.wait(CONFIG.BACKOFF_DELAY)
                end

            else
                -- one final sweep so nothing is left sitting in the inventory
                if CONFIG.AUTO_SELL and Items then pcall(sellSweep) end
                print(string.format("[Case] Done. Event: %d | Piqru: %d | Sold: %d", eventOpened, piqruOpened, totalSold))
                sendWebhook("Finished", 0xFFD700, eventOpened, piqruOpened)
                break
            end

            if CONFIG.WEBHOOK_EVERY > 0 and os.time() - lastReport >= CONFIG.WEBHOOK_EVERY then
                lastReport = os.time()
                sendWebhook("Running", 0x00E5FF, eventOpened, piqruOpened)
            end
        end
    end)

    if not ok then
        warn("[Case] LOOP CRASHED: " .. tostring(err))
        sendWebhook("CRASHED", 0xFF0000, eventOpened, piqruOpened)
    end
end)
