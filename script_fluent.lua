local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoidRootPart = character:WaitForChild("HumanoidRootPart", 15)
local cachedHumanoid = character:FindFirstChildOfClass("Humanoid")

local GetBridge = require(RS.util.GetBridge)
local ClientData = require(RS.client.modules.ClientData)
local ResourcesConfig = require(RS.shared.config.ResourcesConfig)
local getSkillsData = require(RS.util.getSkillsData)
local LocalPlayer = require(RS.util.LocalPlayer)
local QuestsConfig = require(RS.shared.config.QuestsConfig)

local Fluent
do
    local ok, lib = pcall(function()
        return loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
    end)
    if ok and lib then Fluent = lib end
end
if not Fluent then return end

local bridgenet = RS:WaitForChild("ncxyzero_bridgenet2-fork@1.1.5", 15)
if not bridgenet then return end
local dataRemoteEvent = bridgenet:WaitForChild("dataRemoteEvent", 15)
if not dataRemoteEvent then return end

local ShopsConfig
do
    local ok, result = pcall(function()
        return require(RS.shared.config.ShopsConfig)
    end)
    if ok and result then ShopsConfig = result end
end
if not ShopsConfig then ShopsConfig = {} end

local function safeGetBridge(name)
    local success, result = pcall(function()
        local fn = RS:WaitForChild("_GetBridgeFunction", 10)
        if fn then pcall(function() fn:InvokeServer(name) end) end
        local ok2, bridge = pcall(function()
            return require(RS.package.Bridgenet2).ClientBridge(name)
        end)
        return ok2 and bridge or nil
    end)
    return success and result or nil
end

local shopBridge = safeGetBridge("BuyFromShop")
local blackMarketBridge = safeGetBridge("BuyFromBlackMarketShop")

local totalEarned = 0
local lastSaleAmount = 0
local totalEarnedLabel = nil
local lastSaleLabel = nil

-- getSkillsData() เรียกจาก context นี้ไม่ได้ ("Cannot require a non-RobloxScript module")
-- โบนัสสกิลตลาด (ตอนนี้ +5) เลยเก็บเป็นค่าคงที่ปรับได้ผ่าน UI แทน
local marketSkillBonus = 5

-- หน่วงเวลาแบบสุ่ม ±jitterPercent เพื่อลดความเป็นบอท (0 = ปิด)
local jitterPercent = 0.3
pcall(function() math.randomseed(os.clock() * 1e6 + tick() % 1 * 1e6) end)
local function jwait(base)
    if not base or base <= 0 then task.wait(base) return end
    if jitterPercent <= 0 then task.wait(base) return end
    local f = 1 + (math.random() * 2 - 1) * jitterPercent
    if f < 0.05 then f = 0.05 end
    task.wait(base * f)
end

local function calcSellValue()
    local success, total = pcall(function()
        local totalValue = 0
        local backpack = ClientData.playerProducer:getState().player.backpack
        local stock = ClientData.gameProducer:getState().market.stock
        local nuclearBoosts = ClientData.gameProducer:getState().nuclearMarketBoosts
        for itemId, itemData in backpack do
            local config = ResourcesConfig[itemId]
            if config then
                local amount = itemData.amount
                local stockMult = (stock[itemId] or 1) + marketSkillBonus / 100
                if nuclearBoosts and nuclearBoosts[itemId] then
                    stockMult = stockMult + nuclearBoosts[itemId]
                end
                totalValue = totalValue + math.round(config.Price * stockMult) * amount
            end
        end
        return totalValue
    end)
    return success and total or 0
end

-- ราคาคิดเป็น % เทียบฐาน "ตรงกับที่ป้ายตลาดโชว์" (= (stock + marketPrice_skill/100 - 1) * 100)
-- ถ้าหา stock ของไอเทมไม่เจอ -> คืนค่าต่ำมาก = ไม่ขาย (กันบั๊กเดิมที่ default แล้วขายหมด)
local function getMarketChangePercent(itemId)
    local ok, pct = pcall(function()
        local stockTbl = ClientData.gameProducer:getState().market.stock
        if not stockTbl or stockTbl[itemId] == nil then error("no stock") end
        local mult = stockTbl[itemId] + marketSkillBonus / 100
        return math.round((mult - 1) * 100)
    end)
    return ok and pct or -999
end

local function notifyUser(title, message)
    pcall(function()
        Fluent:Notify({ Title = title, Content = message, Duration = 3 })
    end)
end

local function performAutoSell()
    local earned = calcSellValue()
    if earned > 0 then
        pcall(function() GetBridge("SellAll"):Fire() end)
        totalEarned = totalEarned + earned
        lastSaleAmount = earned
        pcall(function()
            if totalEarnedLabel then totalEarnedLabel:Set("Total Earned: $" .. tostring(totalEarned)) end
            if lastSaleLabel then lastSaleLabel:Set("Last Sale: $" .. tostring(lastSaleAmount)) end
        end)
        print("Sold for $" .. tostring(earned))
    end
end

local function manualSell()
    local earned = calcSellValue()
    if earned > 0 then
        pcall(function() GetBridge("SellAll"):Fire() end)
        totalEarned = totalEarned + earned
        lastSaleAmount = earned
        pcall(function()
            if totalEarnedLabel then totalEarnedLabel:Set("Total Earned: $" .. tostring(totalEarned)) end
            if lastSaleLabel then lastSaleLabel:Set("Last Sale: $" .. tostring(lastSaleAmount)) end
        end)
        notifyUser("Sell", "Sold items for $" .. tostring(earned))
    else
        notifyUser("Sell", "No items to sell")
    end
end

local function sellItemIfAbovePercent(itemId, minPercent)
    local pct = getMarketChangePercent(itemId)
    if pct < minPercent then return false end
    local tool = player.Backpack:FindFirstChild(itemId)
    if not tool then return false end
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    local ok = pcall(function() humanoid:EquipTool(tool) end)
    if not ok then return false end
    task.wait(0.2)
    pcall(function() GetBridge("SellSingularItem"):Fire() end)
    task.wait(0.1)
    pcall(function() humanoid:UnequipTools() end)
    return true
end

local function performSmartSell(minPercent)
    local ok, backpack = pcall(function()
        return ClientData.playerProducer:getState().player.backpack
    end)
    if not ok or not backpack then return end
    local soldAny = false
    for itemId, itemData in pairs(backpack) do
        if itemData and itemData.amount and itemData.amount > 0 then
            if sellItemIfAbovePercent(itemId, minPercent) then
                soldAny = true
                task.wait(0.3)
            end
        end
    end
    if soldAny then
        pcall(function()
            if totalEarnedLabel then totalEarnedLabel:Set("Total Earned: $" .. tostring(totalEarned)) end
            if lastSaleLabel then lastSaleLabel:Set("Last Sale: smart sell") end
        end)
        notifyUser("Smart Sell", "Sold items above " .. minPercent .. "%")
    end
end

local function getPlayerMoney()
    local ok, money = pcall(function()
        return ClientData.playerProducer:getState().player.money
    end)
    return ok and money or nil
end

local function isInStock(shopName, itemName)
    local ok, count = pcall(function()
        local shopsStock = ClientData.playerProducer:getState().player.shopsStock
        if not shopsStock then return nil end
        local shopStock = shopsStock[shopName]
        if not shopStock or not shopStock.stock then return nil end
        return shopStock.stock[itemName]
    end)
    local count2 = ok and count or nil
    if count2 == nil then return true end
    return count2 > 0
end

local function canAfford(price)
    if not price or price <= 0 then return true end
    local money = getPlayerMoney()
    if money == nil then return true end
    return money >= price
end

-- Send ARMY to a capture point.
-- ยืนยันจาก sniffer:
--   normal/bandit army = { { armyIndex = N, capturePoint = point }, "U" }
--   toxic zone army    = { { armyIndex = N, capturePoint = point }, "V" }   <- toxic ใช้ identifier ต่าง!
-- ส่ง capturePoint (Model ของจุดยึด) ตรง ๆ ตามที่เกมยิงจริง
local function sendTroopsToPoint(capturePoint, armyIndex)
    if not capturePoint then return end
    pcall(function()
        dataRemoteEvent:FireServer({
            { armyIndex = armyIndex, capturePoint = capturePoint },
            "U"
        })
    end)
end

local function sendTroopsToToxicPoint(capturePoint, armyIndex)
    if not capturePoint then return end
    pcall(function()
        dataRemoteEvent:FireServer({
            { armyIndex = armyIndex, capturePoint = capturePoint },
            "V"
        })
    end)
end

local CONFIG = {
    Delay         = 1.5,
    BMCheckDelay  = 2,
    BlackMarket   = { Enabled = false, Selected = {}, SelectAll = false },
    Shops         = {},
    RunSpeed      = { Enabled = false, Speed = 50 },
    AutoCollect   = { Enabled = false, Filter = { "All" } },
    AutoConquer   = { Enabled = false, Mode = "None", SpecificBase = "None", ArmyIndex = 2 },
    AutoRaid      = { Enabled = false },
    AutoToxicRaid = { Enabled = false },
    SaveGpu       = { Enabled = false },
    AutoSell      = { Enabled = false },
    SmartSell     = { Enabled = false, MinPercent = 10 },
    AntiAfk       = { Enabled = false },
    AutoRejoin    = { Enabled = false },
}

local shopNames = {}
for shopName, _ in pairs(ShopsConfig) do
    if shopName ~= "BlackMarket" then
        table.insert(shopNames, shopName)
        CONFIG.Shops[shopName] = { Enabled = false, Selected = {}, SelectAll = false }
    end
end
table.sort(shopNames)

-- ============================================================
-- Config save/load (ทำเองทั้งหมด ไม่พึ่ง Rayfield ConfigurationSaving
-- เพราะบาง executor เซฟไม่ติด) เซฟทุกค่าลงไฟล์เดียว + สร้างโฟลเดอร์เองก่อนเขียน
-- ============================================================
local CONFIG_FOLDER   = "PrivateScript"
local CONFIG_PATH     = CONFIG_FOLDER .. "/full_config.json"
-- URL ที่โฮสต์สคริปต์เวอร์ชันล่าสุด (autoexec จะโหลดจากตรงนี้ตอน rejoin)
-- << ถ้าเปลี่ยนที่โฮสต์ ให้แก้บรรทัดนี้
local AUTOEXEC_URL    = "https://raw.githubusercontent.com/vorapoth/yedmun/main/script_fluent.lua"
local AUTOEXEC_NAME   = "PrivateScript_autoload.lua"
local fileApiOk       = (writefile and readfile and isfile) and true or false
local savedConfigData = nil
local applyingConfig  = false

local function ensureFolder()
    pcall(function()
        if makefolder then
            if not (isfolder and isfolder(CONFIG_FOLDER)) then
                makefolder(CONFIG_FOLDER)
            end
        end
    end)
end

local function buildConfigData()
    local data = {
        SaveGpu     = CONFIG.SaveGpu.Enabled,
        AntiAfk     = CONFIG.AntiAfk.Enabled,
        AutoRejoin  = CONFIG.AutoRejoin.Enabled,
        AutoCollect = { Enabled = CONFIG.AutoCollect.Enabled, Filter = CONFIG.AutoCollect.Filter },
        AutoSell    = CONFIG.AutoSell.Enabled,
        SmartSell   = { Enabled = CONFIG.SmartSell.Enabled, MinPercent = CONFIG.SmartSell.MinPercent },
        MarketSkillBonus = marketSkillBonus,
        JitterPercent = math.floor(jitterPercent * 100),
        RunSpeed    = { Enabled = CONFIG.RunSpeed.Enabled, Speed = CONFIG.RunSpeed.Speed },
        AutoConquer = {
            Enabled = CONFIG.AutoConquer.Enabled, Mode = CONFIG.AutoConquer.Mode,
            SpecificBase = CONFIG.AutoConquer.SpecificBase, ArmyIndex = CONFIG.AutoConquer.ArmyIndex,
        },
        AutoRaid      = CONFIG.AutoRaid.Enabled,
        AutoToxicRaid = CONFIG.AutoToxicRaid.Enabled,
        BlackMarket = {
            Enabled   = CONFIG.BlackMarket.Enabled,
            Selected  = CONFIG.BlackMarket.Selected,
            SelectAll = CONFIG.BlackMarket.SelectAll,
        },
        Shops = {},
    }
    for shopName, sc in pairs(CONFIG.Shops) do
        data.Shops[shopName] = { Enabled = sc.Enabled, Selected = sc.Selected, SelectAll = sc.SelectAll }
    end
    return data
end

local function saveConfig()
    if not fileApiOk or applyingConfig then return end
    ensureFolder()
    pcall(function()
        writefile(CONFIG_PATH, HttpService:JSONEncode(buildConfigData()))
    end)
end

local function loadConfigRaw()
    if not fileApiOk then return end
    pcall(function()
        if not isfile(CONFIG_PATH) then return end
        savedConfigData = HttpService:JSONDecode(readfile(CONFIG_PATH))
    end)
end

-- แปลง list <-> set สำหรับ multi-dropdown ของ Fluent
local function arrayToSet(arr)
    local s = {}
    for _, v in ipairs(arr or {}) do s[v] = true end
    return s
end
local function setToList(set)
    local l = {}
    if type(set) == "table" then
        for k, v in pairs(set) do if v then table.insert(l, k) end end
    end
    return l
end

-- ต้องเรียกหลังสร้าง UI เสร็จ (ใช้ Fluent.Options[idx]:SetValue)
local function applyConfig()
    if not savedConfigData then return end
    applyingConfig = true
    local d = savedConfigData
    local function setOpt(idx, value)
        if value == nil then return end
        pcall(function()
            local opt = Fluent.Options[idx]
            if opt then opt:SetValue(value) end
        end)
    end
    setOpt("SaveGpuToggle", d.SaveGpu)
    setOpt("AntiAfkToggle", d.AntiAfk)
    setOpt("AutoRejoinToggle", d.AutoRejoin)
    if d.AutoCollect then
        if d.AutoCollect.Filter then setOpt("CollectFilter", arrayToSet(d.AutoCollect.Filter)) end
        setOpt("AutoCollectToggle", d.AutoCollect.Enabled)
    end
    setOpt("AutoSellToggle", d.AutoSell)
    if d.SmartSell then
        setOpt("SmartSellPercent", d.SmartSell.MinPercent)
        setOpt("SmartSellToggle", d.SmartSell.Enabled)
    end
    setOpt("MarketSkillBonus", d.MarketSkillBonus)
    setOpt("JitterPercent", d.JitterPercent)
    if d.RunSpeed then
        setOpt("RunSpeedValue", d.RunSpeed.Speed)
        setOpt("RunSpeedToggle", d.RunSpeed.Enabled)
    end
    if d.AutoConquer then
        setOpt("ConquerMode", d.AutoConquer.Mode)
        setOpt("ConquerBase", d.AutoConquer.SpecificBase)
        setOpt("ArmyIndex", d.AutoConquer.ArmyIndex)
        setOpt("AutoConquerToggle", d.AutoConquer.Enabled)
    end
    setOpt("AutoRaidToggle", d.AutoRaid)
    setOpt("AutoToxicRaidToggle", d.AutoToxicRaid)
    if d.BlackMarket then
        setOpt("BMItems", d.BlackMarket.SelectAll and { All = true } or arrayToSet(d.BlackMarket.Selected))
        setOpt("BMToggle", d.BlackMarket.Enabled)
    end
    if d.Shops then
        for shopName, sc in pairs(d.Shops) do
            if CONFIG.Shops[shopName] then
                setOpt("Shop_" .. shopName, sc.SelectAll and { All = true } or arrayToSet(sc.Selected))
                setOpt("Shop_" .. shopName .. "_Toggle", sc.Enabled)
            end
        end
    end
    applyingConfig = false
end

local collectCount      = 0
local totalBought       = 0
local lastItemBought    = "None"
local collectLabel      = nil
local totalBoughtLabel  = nil
local lastItemLabel     = nil
local raidStatusLabel   = nil
local antiAfkConnection = nil

local normalRaidActive  = false
local toxicRaidActive   = false

local cachedBuildings       = {}
local cachedBuildingsFolder = nil
local cachedBuildingsFilter = {}

local FARM_BUILDING_NAMES = {
    "FarmWheat", "FarmCorn", "FarmCarrot", "FarmPotato",
    "FarmTomato", "FarmStrawberry", "FarmWatermelon",
    "FarmSunflower", "FarmCotton", "Farm",
}

local function enableAntiAfk()
    pcall(function()
        if getconnections then
            for _, x in pairs(getconnections(player.Idled)) do
                x:Disable()
            end
        end
    end)
    if antiAfkConnection then
        pcall(function() antiAfkConnection:Disconnect() end)
        antiAfkConnection = nil
    end
    local bb = game:GetService("VirtualUser")
    antiAfkConnection = player.Idled:Connect(function()
        bb:CaptureController()
        bb:ClickButton2(Vector2.new())
    end)
end

local function disableAntiAfk()
    if antiAfkConnection then
        pcall(function() antiAfkConnection:Disconnect() end)
        antiAfkConnection = nil
    end
end

-- ===== Auto Rejoin =====
local autoRejoinConns = {}
local function disableAutoRejoin()
    for _, c in ipairs(autoRejoinConns) do
        pcall(function() c:Disconnect() end)
    end
    autoRejoinConns = {}
end
local function enableAutoRejoin()
    disableAutoRejoin()
    local TeleportService = game:GetService("TeleportService")
    local GuiService = game:GetService("GuiService")
    local placeId = game.PlaceId
    local function rejoin()
        -- พยายามเข้าเซิร์ฟเดิมก่อน ถ้าตายค่อย fallback ไปเซิร์ฟใหม่
        local ok = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, game.JobId, player)
        end)
        if not ok then
            pcall(function() TeleportService:Teleport(placeId, player) end)
        end
    end
    table.insert(autoRejoinConns, GuiService.ErrorMessageChanged:Connect(function()
        task.wait(0.5)
        rejoin()
    end))
    -- ถ้า teleport เข้าเซิร์ฟเดิมล้มเหลว ให้เด้งไปเซิร์ฟใหม่แทน
    table.insert(autoRejoinConns, TeleportService.TeleportInitFailed:Connect(function()
        task.wait(1)
        pcall(function() TeleportService:Teleport(placeId, player) end)
    end))
end

local cachedSpecial = nil
local function getSpecial()
    if cachedSpecial and cachedSpecial.Parent then return cachedSpecial end
    cachedSpecial = nil
    local mm = workspace:FindFirstChild("MilitaryMap")
    if not mm then return nil end
    local obj = mm:FindFirstChild("Object")
    if not obj then return nil end
    cachedSpecial = obj:FindFirstChild("Special")
    return cachedSpecial
end

local function getKingOfTheHillBase()
    local special = getSpecial()
    if not special then return nil end
    return special:FindFirstChild("KingOfTheHillBase")
end

local function getToxicKingOfTheHillBase()
    local special = getSpecial()
    if not special then return nil end
    return special:FindFirstChild("ToxicKingOfTheHillBase")
end

local function isBlackMarketOpen()
    local t = workspace:GetServerTimeNow()
    local elapsed = t - math.floor(t / 3600) * 3600
    return elapsed >= 15 and elapsed <= 1200
end

local function updateShopLabels()
    pcall(function()
        if totalBoughtLabel then totalBoughtLabel:Set("Total Bought: " .. totalBought) end
        if lastItemLabel then lastItemLabel:Set("Last Item Bought: " .. lastItemBought) end
    end)
end

local function recordPurchase(itemName)
    totalBought = totalBought + 1
    lastItemBought = itemName
    updateShopLabels()
end

local function shouldBuyItem(shopConfig, itemName)
    if shopConfig.SelectAll then return true end
    if table.find(shopConfig.Selected, "All") then return true end
    for _, selected in ipairs(shopConfig.Selected) do
        if selected == itemName then return true end
    end
    return false
end

local function getPlot()
    local tagged = CollectionService:GetTagged(player.Name .. "-Plot")
    local _, plot = next(tagged)
    if not plot then return nil, nil end
    local plotNumber = plot.Name
    local militaryMap = workspace:FindFirstChild("MilitaryMap")
    if not militaryMap then return plotNumber, nil end
    local playerPlots = militaryMap:FindFirstChild("PlayerPlots")
    if not playerPlots then return plotNumber, nil end
    local plotFolder = playerPlots:FindFirstChild(plotNumber)
    return plotNumber, plotFolder
end

local function getPlotBuildings()
    local _, plotFolder = getPlot()
    if not plotFolder then return nil end
    local plotModel = plotFolder:FindFirstChild("Plot")
    if not plotModel then return nil end
    return plotModel:FindFirstChild("Buildings")
end

local function filtersMatch(a, b)
    if #a ~= #b then return false end
    for i, v in ipairs(a) do
        if b[i] ~= v then return false end
    end
    return true
end

local function getCollectableBuildings(filter)
    local buildings = getPlotBuildings()
    if not buildings then return {} end
    if buildings == cachedBuildingsFolder and filtersMatch(filter, cachedBuildingsFilter) then
        return cachedBuildings
    end
    local result = {}
    local collectAll = table.find(filter, "All") ~= nil
    for _, building in ipairs(buildings:GetChildren()) do
        if building:IsA("Model") then
            local name = building.Name
            local include = false
            if collectAll then
                for _, farmName in ipairs(FARM_BUILDING_NAMES) do
                    if name:find(farmName) then include = true break end
                end
            else
                for _, selected in ipairs(filter) do
                    if name:find(selected) then include = true break end
                end
            end
            if include then table.insert(result, building) end
        end
    end
    cachedBuildings = result
    cachedBuildingsFolder = buildings
    cachedBuildingsFilter = filter
    return result
end

local cachedBandit = nil
local function getBandit()
    if cachedBandit and cachedBandit.Parent then return cachedBandit end
    cachedBandit = nil
    local mm = workspace:FindFirstChild("MilitaryMap")
    if not mm then return nil end
    local obj = mm:FindFirstChild("Object")
    if not obj then return nil end
    cachedBandit = obj:FindFirstChild("Bandit")
    return cachedBandit
end

local function getGarnisonList()
    local names = {}
    local bandit = getBandit()
    if not bandit then return names end
    for _, v in ipairs(bandit:GetChildren()) do
        if v.Name:find("Garnison") then
            table.insert(names, v.Name)
        end
    end
    table.sort(names)
    return names
end

local function isGarnisonOwned(garnisonInstance)
    if not garnisonInstance then return false end
    return garnisonInstance:GetAttribute("Owner") == player.Name
end

local function getGarnisonHP(garnisonInstance)
    if not garnisonInstance then return math.huge end
    return garnisonInstance:GetAttribute("HP") or math.huge
end

local CONQUER_COOLDOWN = 8
local pendingTarget  = nil
local pendingFiredAt = 0

local function smartFireConquer(capturePoint)
    if not capturePoint then return end
    if capturePoint:GetAttribute("Owner") == player.Name then return end
    if capturePoint == pendingTarget and tick() - pendingFiredAt < CONQUER_COOLDOWN then return end
    pendingTarget  = capturePoint
    pendingFiredAt = tick()
    sendTroopsToPoint(capturePoint, CONFIG.AutoConquer.ArmyIndex)
end

local function teleportToInstance(instance)
    if not instance then return end
    local hrp = character and character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local part = nil
    if instance:IsA("BasePart") then
        part = instance
    elseif instance:IsA("Model") then
        part = instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
    else
        part = instance:FindFirstChildWhichIsA("BasePart")
    end
    if part then
        pcall(function() hrp.CFrame = part.CFrame + Vector3.new(0, 5, 0) end)
    end
end

local function updateRaidLabel()
    pcall(function()
        if not raidStatusLabel then return end
        if normalRaidActive and toxicRaidActive then
            raidStatusLabel:Set("Raid Event: ACTIVE + ACTIVE (Toxic)")
        elseif normalRaidActive then
            raidStatusLabel:Set("Raid Event: ACTIVE")
        elseif toxicRaidActive then
            raidStatusLabel:Set("Raid Event: ACTIVE (Toxic)")
        else
            raidStatusLabel:Set("Raid Event: Not Active")
        end
    end)
end

-- ============================================================
-- UI
-- ============================================================

local Window = Fluent:CreateWindow({
    Title = "Private Script",
    SubTitle = "by private user",
    TabWidth = 150,
    Size = UDim2.fromOffset(580, 470),
    Acrylic = true,
    Theme = "Dark",
    MinimizeKey = Enum.KeyCode.RightControl,
})

-- ============================================================
-- Mobile floating toggle button (เรียก UI กลับเมื่อย่อไปแล้ว)
-- ============================================================
do
    local MINIMIZE_KEY = Enum.KeyCode.RightControl
    local UIS = game:GetService("UserInputService")
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui")

    local tgGui = Instance.new("ScreenGui")
    tgGui.Name = "MS_ToggleBtn"
    tgGui.ResetOnSpawn = false
    tgGui.IgnoreGuiInset = true
    tgGui.DisplayOrder = 99999
    tgGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    local okParent = pcall(function() tgGui.Parent = guiParent end)
    if not okParent or not tgGui.Parent then
        pcall(function()
            tgGui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
        end)
    end

    local btn = Instance.new("TextButton")
    btn.Name = "Toggle"
    btn.Size = UDim2.fromOffset(46, 46)
    btn.Position = UDim2.fromOffset(14, 150)
    btn.BackgroundColor3 = Color3.fromRGB(32, 34, 45)
    btn.BackgroundTransparency = 0.1
    btn.Text = "☰"
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextSize = 24
    btn.Font = Enum.Font.GothamBold
    btn.AutoButtonColor = true
    btn.Active = true
    btn.ZIndex = 99999
    btn.Parent = tgGui
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = btn
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(90, 120, 200)
    stroke.Thickness = 1.5
    stroke.Parent = btn

    -- drag (กันบังจอ + ขยับวางที่ถนัด)
    local dragging, dragStart, startPos, moved = false, nil, nil, false
    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            moved = false
            dragStart = input.Position
            startPos = btn.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            if delta.Magnitude > 6 then moved = true end
            btn.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)

    -- หา ScreenGui ของ Fluent (เผื่อ fallback) จากชื่อ Title
    local function findFluentGui()
        for _, g in ipairs(guiParent:GetChildren()) do
            if g:IsA("ScreenGui") and g ~= tgGui then
                for _, d in ipairs(g:GetDescendants()) do
                    if d:IsA("TextLabel") and d.Text == "Private Script" then
                        return g
                    end
                end
            end
        end
        return nil
    end

    local function toggleWindow()
        -- 1) จำลองกด MinimizeKey -> Fluent toggle ย่อ/ขยายเอง (sync กับปุ่ม dash)
        local vim = nil
        pcall(function() vim = game:GetService("VirtualInputManager") end)
        if vim then
            local ok = pcall(function()
                vim:SendKeyEvent(true, MINIMIZE_KEY, false, game)
                task.wait()
                vim:SendKeyEvent(false, MINIMIZE_KEY, false, game)
            end)
            if ok then return end
        end
        -- 2) ลองเมธอด minimize ของ Fluent เอง (ถ้ามี)
        if pcall(function() Window:Minimize() end) then return end
        -- 3) สุดท้าย: ซ่อน/โชว์ ScreenGui ของ Fluent ตรง ๆ
        local fg = findFluentGui()
        if fg then fg.Enabled = not fg.Enabled end
    end

    btn.Activated:Connect(function()
        if moved then moved = false return end
        toggleWindow()
    end)
end

local MainTab    = Window:AddTab({ Title = "Main",     Icon = "" })
local ShopTab    = Window:AddTab({ Title = "Shop",     Icon = "" })
local FeatureTab = Window:AddTab({ Title = "Features", Icon = "" })
local QuestsTab  = Window:AddTab({ Title = "Quests",   Icon = "" })
local ConfigTab  = Window:AddTab({ Title = "Config",   Icon = "" })

-- ป้ายแบบอัปเดตได้ (ห่อ AddParagraph ให้มี :Set เหมือน Rayfield เดิม)
local function makeLabel(tab, title, initial)
    local p = tab:AddParagraph({ Title = title, Content = initial or "" })
    return {
        Set = function(_, text)
            pcall(function()
                if p.SetDesc then p:SetDesc(text)
                elseif p.SetTitle then p:SetTitle(text) end
            end)
        end,
    }
end

-- Fluent ไม่มี section จริง ใช้ paragraph เป็นหัวข้อแทน
local function addHeader(tab, name)
    pcall(function() tab:AddParagraph({ Title = name, Content = "" }) end)
end

-- ===== Main Tab =====
addHeader(MainTab, "Performance")

MainTab:AddToggle("SaveGpuToggle", {
    Title = "Save GPU (Disable 3D Rendering)",
    Default = CONFIG.SaveGpu.Enabled,
    Callback = function(Value)
        CONFIG.SaveGpu.Enabled = Value
        pcall(function() RunService:Set3dRenderingEnabled(not Value) end)
    end,
})

addHeader(MainTab, "Anti AFK")

MainTab:AddToggle("AntiAfkToggle", {
    Title = "Anti AFK",
    Default = CONFIG.AntiAfk.Enabled,
    Callback = function(Value)
        CONFIG.AntiAfk.Enabled = Value
        if Value then enableAntiAfk() else disableAntiAfk() end
    end,
})

MainTab:AddToggle("AutoRejoinToggle", {
    Title = "Auto Rejoin",
    Description = "หลุดแล้วเด้งกลับเซิร์ฟเดิม (ต้องคู่กับ autoexec ถึงรันสคริปต์ต่อ)",
    Default = CONFIG.AutoRejoin.Enabled,
    Callback = function(Value)
        CONFIG.AutoRejoin.Enabled = Value
        if Value then enableAutoRejoin() else disableAutoRejoin() end
    end,
})

addHeader(MainTab, "Auto Collect")

collectLabel = makeLabel(MainTab, "Collected", "0")

MainTab:AddToggle("AutoCollectToggle", {
    Title = "Auto Collect",
    Default = CONFIG.AutoCollect.Enabled,
    Callback = function(Value)
        CONFIG.AutoCollect.Enabled = Value
        if Value then
            local _, plotFolder = getPlot()
            if not plotFolder then
                notifyUser("Auto Collect", "Could not detect your plot!")
                CONFIG.AutoCollect.Enabled = false
                pcall(function() Fluent.Options.AutoCollectToggle:SetValue(false) end)
            end
        end
    end,
})

local farmDropdownOptions = { "All" }
for _, name in ipairs(FARM_BUILDING_NAMES) do
    if name ~= "Farm" then table.insert(farmDropdownOptions, name) end
end

MainTab:AddDropdown("CollectFilter", {
    Title = "Farm Filter",
    Values = farmDropdownOptions,
    Multi = true,
    Default = { All = true },
    Callback = function(Value)
        local list = setToList(Value)
        if #list > 0 then
            CONFIG.AutoCollect.Filter = list
            cachedBuildingsFilter = {}
            saveConfig()
        end
    end,
})

MainTab:AddButton({
    Title = "Manual Collect All Now",
    Callback = function()
        local buildings = getCollectableBuildings(CONFIG.AutoCollect.Filter)
        if #buildings == 0 then
            notifyUser("Collect", "No farm buildings found on your plot")
            return
        end
        local fired = 0
        for _, building in ipairs(buildings) do
            local ok = pcall(function()
                dataRemoteEvent:FireServer({ building, ";" })
            end)
            if ok then
                fired = fired + 1
                collectCount = collectCount + 1
            end
            task.wait(0.1)
        end
        pcall(function()
            if collectLabel then collectLabel:Set("Collected: " .. collectCount) end
        end)
        notifyUser("Collect", "Collected from " .. fired .. " buildings")
    end,
})

addHeader(MainTab, "Sell")

totalEarnedLabel = makeLabel(MainTab, "Total Earned", "$0")
lastSaleLabel    = makeLabel(MainTab, "Last Sale", "$0")

MainTab:AddToggle("AutoSellToggle", {
    Title = "Auto Sell All",
    Default = CONFIG.AutoSell.Enabled,
    Callback = function(Value)
        CONFIG.AutoSell.Enabled = Value
        if Value and CONFIG.SmartSell.Enabled then
            CONFIG.SmartSell.Enabled = false
            pcall(function() Fluent.Options.SmartSellToggle:SetValue(false) end)
            notifyUser("Sell", "Smart Sell disabled -- Auto Sell All is active")
        end
    end,
})

MainTab:AddButton({
    Title = "Sell All Now",
    Callback = manualSell,
})

addHeader(MainTab, "Smart Sell (Per Item)")

MainTab:AddToggle("SmartSellToggle", {
    Title = "Smart Sell (sell item when % reached)",
    Default = CONFIG.SmartSell.Enabled,
    Callback = function(Value)
        CONFIG.SmartSell.Enabled = Value
        if Value and CONFIG.AutoSell.Enabled then
            CONFIG.AutoSell.Enabled = false
            pcall(function() Fluent.Options.AutoSellToggle:SetValue(false) end)
            notifyUser("Sell", "Auto Sell All disabled -- Smart Sell is active")
        end
    end,
})

MainTab:AddSlider("SmartSellPercent", {
    Title = "Min Market %",
    Description = "ขายเมื่อราคา >= % นี้ (สเกลเดียวกับป้ายตลาด)",
    Default = CONFIG.SmartSell.MinPercent,
    Min = -30,
    Max = 50,
    Rounding = 0,
    Callback = function(Value)
        CONFIG.SmartSell.MinPercent = math.floor(Value)
    end,
})
pcall(function() Fluent.Options.SmartSellPercent:SetValue(10) end)

MainTab:AddSlider("MarketSkillBonus", {
    Title = "Market Skill Bonus",
    Description = "offset ให้ตรงป้าย (ปกติ 5, ปรับตอนอัปสกิล)",
    Default = marketSkillBonus,
    Min = 0,
    Max = 50,
    Rounding = 0,
    Callback = function(Value) marketSkillBonus = math.floor(Value) end,
})
pcall(function() Fluent.Options.MarketSkillBonus:SetValue(5) end)

MainTab:AddButton({
    Title = "Smart Sell Now",
    Callback = function()
        performSmartSell(CONFIG.SmartSell.MinPercent)
    end,
})

-- ===== Shop Tab =====
addHeader(ShopTab, "Stats")
totalBoughtLabel = makeLabel(ShopTab, "Total Bought", "0")
lastItemLabel    = makeLabel(ShopTab, "Last Item Bought", "None")

addHeader(ShopTab, "Black Market")

ShopTab:AddToggle("BMToggle", {
    Title = "Auto Buy from Black Market",
    Default = CONFIG.BlackMarket.Enabled,
    Callback = function(Value) CONFIG.BlackMarket.Enabled = Value end,
})

local bmItems = { "All" }
for _, item in ipairs(ShopsConfig.BlackMarket or {}) do
    if item and item.name then table.insert(bmItems, item.name) end
end

ShopTab:AddDropdown("BMItems", {
    Title = "Black Market Items",
    Values = bmItems,
    Multi = true,
    Default = {},
    Callback = function(Value)
        local selected = setToList(Value)
        if table.find(selected, "All") then
            CONFIG.BlackMarket.SelectAll = true
            CONFIG.BlackMarket.Selected = {}
        else
            CONFIG.BlackMarket.SelectAll = false
            CONFIG.BlackMarket.Selected = selected
        end
        saveConfig()
    end,
})

ShopTab:AddButton({
    Title = "Buy Selected Black Market Items Now",
    Callback = function()
        if not blackMarketBridge then notifyUser("Error", "Bridge not available") return end
        if not isBlackMarketOpen() then notifyUser("Black Market", "Black Market is closed right now") return end
        if not CONFIG.BlackMarket.SelectAll and #CONFIG.BlackMarket.Selected == 0 then
            notifyUser("Black Market", "Please select an item first") return
        end
        for _, item in ipairs(ShopsConfig.BlackMarket or {}) do
            if item and item.name and shouldBuyItem(CONFIG.BlackMarket, item.name) then
                if not isInStock("BlackMarket", item.name) then
                    notifyUser("Black Market", item.name .. " is out of stock")
                    continue
                end
                if not canAfford(item.Price or 0) then
                    notifyUser("Black Market", "Can't afford " .. item.name)
                    continue
                end
                pcall(function() blackMarketBridge:Fire({ shop = "BlackMarket", item = item.name }) end)
                recordPurchase(item.name)
                notifyUser("Black Market", "Bought: " .. item.name)
                task.wait(0.2)
            end
        end
    end,
})

for _, shopName in ipairs(shopNames) do
    local items = ShopsConfig[shopName]
    if not items or type(items) ~= "table" then continue end

    addHeader(ShopTab, shopName)

    ShopTab:AddToggle("Shop_" .. shopName .. "_Toggle", {
        Title = "Auto Buy from " .. shopName,
        Default = CONFIG.Shops[shopName].Enabled,
        Callback = function(Value) CONFIG.Shops[shopName].Enabled = Value end,
    })

    local itemNames = { "All" }
    for _, item in ipairs(items) do
        if item and item.name then table.insert(itemNames, item.name) end
    end

    ShopTab:AddDropdown("Shop_" .. shopName, {
        Title = shopName .. " Items",
        Values = itemNames,
        Multi = true,
        Default = {},
        Callback = function(Value)
            local selected = setToList(Value)
            if table.find(selected, "All") then
                CONFIG.Shops[shopName].SelectAll = true
                CONFIG.Shops[shopName].Selected = {}
            else
                CONFIG.Shops[shopName].SelectAll = false
                CONFIG.Shops[shopName].Selected = selected
            end
            saveConfig()
        end,
    })

    ShopTab:AddButton({
        Title = "Buy Selected " .. shopName .. " Items Now",
        Callback = function()
            if not shopBridge then notifyUser("Error", "Bridge not available") return end
            if not CONFIG.Shops[shopName].SelectAll and #CONFIG.Shops[shopName].Selected == 0 then
                notifyUser(shopName, "Please select an item first") return
            end
            for _, item in ipairs(items) do
                if item and item.name and shouldBuyItem(CONFIG.Shops[shopName], item.name) then
                    if not isInStock(shopName, item.name) then
                        notifyUser(shopName, item.name .. " is out of stock")
                        continue
                    end
                    if not canAfford(item.Price or 0) then
                        notifyUser(shopName, "Can't afford " .. item.name)
                        continue
                    end
                    pcall(function() shopBridge:Fire({ shop = shopName, item = item.name }) end)
                    recordPurchase(item.name)
                    notifyUser(shopName, "Bought: " .. item.name)
                    task.wait(0.2)
                end
            end
        end,
    })
end

-- ===== Features Tab =====
addHeader(FeatureTab, "Raid")
raidStatusLabel = makeLabel(FeatureTab, "Raid Event", "Not Active")

FeatureTab:AddToggle("AutoRaidToggle", {
    Title = "Auto Raid Event",
    Default = CONFIG.AutoRaid.Enabled,
    Callback = function(Value)
        CONFIG.AutoRaid.Enabled = Value
        if Value then notifyUser("Auto Raid", "Watching for raid event...") end
    end,
})

FeatureTab:AddToggle("AutoToxicRaidToggle", {
    Title = "Auto Toxic Raid Event",
    Default = CONFIG.AutoToxicRaid.Enabled,
    Callback = function(Value)
        CONFIG.AutoToxicRaid.Enabled = Value
        if Value then notifyUser("Auto Toxic Raid", "Watching for toxic raid event...") end
    end,
})

addHeader(FeatureTab, "Movement")

FeatureTab:AddToggle("RunSpeedToggle", {
    Title = "Enable Run Speed",
    Default = CONFIG.RunSpeed.Enabled,
    Callback = function(Value)
        CONFIG.RunSpeed.Enabled = Value
        if not Value and cachedHumanoid then
            pcall(function() cachedHumanoid.WalkSpeed = 16 end)
        end
    end,
})

FeatureTab:AddSlider("RunSpeedValue", {
    Title = "Run Speed Value",
    Default = CONFIG.RunSpeed.Speed,
    Min = 16,
    Max = 500,
    Rounding = 0,
    Callback = function(Value)
        CONFIG.RunSpeed.Speed = math.floor(Value)
        if CONFIG.RunSpeed.Enabled and cachedHumanoid then
            pcall(function() cachedHumanoid.WalkSpeed = CONFIG.RunSpeed.Speed end)
        end
    end,
})
pcall(function() Fluent.Options.RunSpeedValue:SetValue(50) end)

addHeader(FeatureTab, "Conquest")

FeatureTab:AddToggle("AutoConquerToggle", {
    Title = "Auto Conquer",
    Default = CONFIG.AutoConquer.Enabled,
    Callback = function(Value) CONFIG.AutoConquer.Enabled = Value end,
})

FeatureTab:AddDropdown("ConquerMode", {
    Title = "Conquer Mode",
    Values = { "None", "All Unconquered", "Weakest", "Strongest", "Nearest", "Specific Base" },
    Multi = false,
    Default = 1,
    Callback = function(Value) CONFIG.AutoConquer.Mode = Value end,
})

local garnisonOptions = { "None" }
for _, n in ipairs(getGarnisonList()) do table.insert(garnisonOptions, n) end

FeatureTab:AddDropdown("ConquerBase", {
    Title = "Specific Base",
    Values = garnisonOptions,
    Multi = false,
    Default = 1,
    Callback = function(Value) CONFIG.AutoConquer.SpecificBase = Value end,
})

FeatureTab:AddSlider("ArmyIndex", {
    Title = "Army Index",
    Default = CONFIG.AutoConquer.ArmyIndex,
    Min = 1,
    Max = 10,
    Rounding = 0,
    Callback = function(Value) CONFIG.AutoConquer.ArmyIndex = math.floor(Value) end,
})
pcall(function() Fluent.Options.ArmyIndex:SetValue(2) end)

FeatureTab:AddSlider("JitterPercent", {
    Title = "Timing Jitter %",
    Description = "สุ่มหน่วงเวลา ±% ลดความเป็นบอท (0 = ปิด)",
    Default = 30,
    Min = 0,
    Max = 50,
    Rounding = 0,
    Callback = function(Value) jitterPercent = math.floor(Value) / 100 end,
})
pcall(function() Fluent.Options.JitterPercent:SetValue(30) end)

-- ===== Quests Tab =====
addHeader(QuestsTab, "Active Quests")
local questParagraph = QuestsTab:AddParagraph({ Title = "Quests", Content = "Loading..." })

local function updateQuestsDisplay()
    pcall(function()
        local producer = ClientData.playerProducer
        if not producer then return end
        local questData = producer:getState().player.questData
        local lines = {}
        if not questData or not questData.activeQuests or next(questData.activeQuests) == nil then
            lines = { "No active quests." }
        else
            for questId, data in pairs(questData.activeQuests) do
                local config = QuestsConfig[questId]
                local progress = data.progress or 0
                local maxProgress = config and config.max or 1
                local reward = config and config.reward or "?"
                local description = config and config.description or questId
                local completed = data.completed == true
                local claimable = (progress >= maxProgress) and not completed
                local status = completed and "[+]" or (claimable and "[!]" or "[ ]")
                local state = completed and "Done" or (claimable and "Ready to claim" or "In progress")
                table.insert(lines, string.format(
                    "%s  %s  |  %d / %d  |  %s gems  |  %s",
                    status, description, progress, maxProgress, tostring(reward), state))
            end
        end
        if #lines == 0 then lines = { "No active quests." } end
        pcall(function()
            if questParagraph.SetDesc then questParagraph:SetDesc(table.concat(lines, "\n")) end
        end)
    end)
end

task.spawn(function()
    while true do
        updateQuestsDisplay()
        task.wait(5)
    end
end)

-- ============================================================
-- Config Tab (export / import)
-- ============================================================
addHeader(ConfigTab, "Share Config")

ConfigTab:AddParagraph({
    Title = "วิธีใช้",
    Content = "Export = คัดลอก config ปัจจุบันลงคลิปบอร์ด (และเขียนไฟล์ export_config.json ให้)\nImport = วาง config ลงในช่องด้านล่าง แล้วกดปุ่ม Import",
})

ConfigTab:AddButton({
    Title = "Export (คัดลอก + เขียนไฟล์)",
    Callback = function()
        local okJson, json = pcall(function() return HttpService:JSONEncode(buildConfigData()) end)
        if not okJson then
            notifyUser("Config", "สร้าง config ไม่สำเร็จ")
            return
        end
        local copied = false
        if setclipboard then
            pcall(function() setclipboard(json); copied = true end)
        end
        local wroteFile = false
        if fileApiOk then
            ensureFolder()
            pcall(function() writefile(CONFIG_FOLDER .. "/export_config.json", json); wroteFile = true end)
        end
        if copied and wroteFile then
            notifyUser("Config", "คัดลอกลงคลิปบอร์ด + เขียนไฟล์ export_config.json แล้ว")
        elseif copied then
            notifyUser("Config", "คัดลอกลงคลิปบอร์ดแล้ว")
        elseif wroteFile then
            notifyUser("Config", "เขียนไฟล์ export_config.json แล้ว (executor ไม่รองรับ clipboard)")
        else
            notifyUser("Config", "executor นี้ทั้งคัดลอกและเขียนไฟล์ไม่ได้")
        end
    end,
})

local importText = ""
ConfigTab:AddInput("ConfigImport", {
    Title = "วาง config ที่นี่",
    Default = "",
    Placeholder = "{ ... json config ... }",
    Numeric = false,
    Finished = false,
    Callback = function(text) importText = text end,
})

ConfigTab:AddButton({
    Title = "Import (โหลดจากข้อความ)",
    Callback = function()
        if not importText or importText == "" then
            notifyUser("Config", "วาง config ลงในช่องก่อน")
            return
        end
        local ok, decoded = pcall(function() return HttpService:JSONDecode(importText) end)
        if ok and type(decoded) == "table" then
            savedConfigData = decoded
            applyConfig()
            saveConfig()
            notifyUser("Config", "นำเข้า config สำเร็จ")
        else
            notifyUser("Config", "config ไม่ถูกต้อง อ่านไม่ได้")
        end
    end,
})

addHeader(ConfigTab, "Auto Execute")

ConfigTab:AddParagraph({
    Title = "วิธีใช้",
    Content = "ติดตั้งให้ executor โหลดสคริปต์เองตอนเข้าเกม (ใช้คู่กับ Auto Rejoin)\nสคริปต์จะถูกโหลดจาก URL: เวอร์ชันล่าสุดที่คุณโฮสต์ไว้",
})

ConfigTab:AddButton({
    Title = "ติดตั้ง Auto-Execute",
    Callback = function()
        local loader = 'loadstring(game:HttpGet("' .. AUTOEXEC_URL .. '"))()'
        local wrote = false
        if writefile then
            pcall(function()
                if makefolder and isfolder and not isfolder("autoexec") then
                    makefolder("autoexec")
                end
                writefile("autoexec/" .. AUTOEXEC_NAME, loader)
                wrote = true
            end)
        end
        if setclipboard then pcall(function() setclipboard(loader) end) end
        if wrote then
            notifyUser("Autoexec", "เขียนไฟล์ลงโฟลเดอร์ autoexec แล้ว + ก็อปโลดเดอร์ลงคลิปบอร์ด")
        elseif setclipboard then
            notifyUser("Autoexec", "เขียนไฟล์ไม่ได้ - ก็อปโลดเดอร์ลงคลิปบอร์ดให้แล้ว เอาไปวางใน autoexec ของ executor เอง")
        else
            notifyUser("Autoexec", "executor นี้เขียนไฟล์/คลิปบอร์ดไม่ได้ - ตั้ง autoexec เองด้วยโลดเดอร์ loadstring(game:HttpGet(URL))()")
        end
    end,
})

ConfigTab:AddButton({
    Title = "ลบ Auto-Execute",
    Callback = function()
        if delfile then
            pcall(function() delfile("autoexec/" .. AUTOEXEC_NAME) end)
            notifyUser("Autoexec", "ลบไฟล์ autoexec แล้ว")
        else
            notifyUser("Autoexec", "executor นี้ลบไฟล์อัตโนมัติไม่ได้ - ลบเองจากโฟลเดอร์ autoexec")
        end
    end,
})

-- ============================================================
-- Init
-- ============================================================

loadConfigRaw()
applyConfig()
if not fileApiOk then
    notifyUser("Config", "Executor นี้เซฟไฟล์ไม่ได้ - ค่าจะไม่ถูกบันทึก")
end

task.defer(function()
    if CONFIG.SaveGpu.Enabled then
        pcall(function() RunService:Set3dRenderingEnabled(false) end)
    end
    if CONFIG.AntiAfk.Enabled then enableAntiAfk() end
    if CONFIG.AutoRejoin.Enabled then enableAutoRejoin() end
    if CONFIG.RunSpeed.Enabled and cachedHumanoid then
        pcall(function() cachedHumanoid.WalkSpeed = CONFIG.RunSpeed.Speed end)
    end
end)

-- ============================================================
-- Background loops
-- ============================================================

-- Auto Collect
task.spawn(function()
    while true do
        jwait(1.5)
        if not CONFIG.AutoCollect.Enabled then continue end
        local buildings = getCollectableBuildings(CONFIG.AutoCollect.Filter)
        for _, building in ipairs(buildings) do
            if not CONFIG.AutoCollect.Enabled then break end
            pcall(function() dataRemoteEvent:FireServer({ building, ";" }) end)
            collectCount = collectCount + 1
            jwait(0.1)
        end
        if #buildings > 0 then
            pcall(function()
                if collectLabel then collectLabel:Set("Collected: " .. collectCount) end
            end)
        end
    end
end)

-- Auto Sell All
task.spawn(function()
    while true do
        jwait(5)
        if CONFIG.AutoSell.Enabled and not CONFIG.SmartSell.Enabled then
            performAutoSell()
        end
    end
end)

-- Smart Sell
task.spawn(function()
    while true do
        jwait(5)
        if CONFIG.SmartSell.Enabled and not CONFIG.AutoSell.Enabled then
            performSmartSell(CONFIG.SmartSell.MinPercent)
        end
    end
end)

-- Auto Buy Black Market
task.spawn(function()
    while true do
        jwait(CONFIG.BMCheckDelay)
        if not CONFIG.BlackMarket.Enabled then continue end
        if not CONFIG.BlackMarket.SelectAll and #CONFIG.BlackMarket.Selected == 0 then continue end
        if not blackMarketBridge then continue end
        if not isBlackMarketOpen() then continue end
        for _, item in ipairs(ShopsConfig.BlackMarket or {}) do
            if item and item.name and shouldBuyItem(CONFIG.BlackMarket, item.name) then
                if not isInStock("BlackMarket", item.name) then continue end
                if not canAfford(item.Price or 0) then continue end
                pcall(function()
                    blackMarketBridge:Fire({ shop = "BlackMarket", item = item.name })
                end)
                recordPurchase(item.name)
                jwait(0.2)
            end
        end
    end
end)

-- Auto Buy Shops
task.spawn(function()
    while true do
        jwait(CONFIG.Delay)
        if not shopBridge then continue end
        for _, shopName in ipairs(shopNames) do
            local shopConfig = CONFIG.Shops[shopName]
            if not shopConfig.Enabled then continue end
            if not shopConfig.SelectAll and #shopConfig.Selected == 0 then continue end
            local items = ShopsConfig[shopName]
            if not items or type(items) ~= "table" then continue end
            for _, item in ipairs(items) do
                if item and item.name and shouldBuyItem(shopConfig, item.name) then
                    if not isInStock(shopName, item.name) then continue end
                    if not canAfford(item.Price or 0) then continue end
                    pcall(function()
                        shopBridge:Fire({ shop = shopName, item = item.name })
                    end)
                    recordPurchase(item.name)
                    jwait(0.2)
                end
            end
        end
    end
end)

-- Auto Conquer
task.spawn(function()
    while true do
        jwait(2)
        if not CONFIG.AutoConquer.Enabled then continue end
        if CONFIG.AutoConquer.Mode == "None" then continue end
        if normalRaidActive or toxicRaidActive then continue end
        local bandit = getBandit()
        if not bandit then continue end
        local mode = CONFIG.AutoConquer.Mode
        if mode == "Specific Base" then
            if CONFIG.AutoConquer.SpecificBase == "None" then continue end
            local target = bandit:FindFirstChild(CONFIG.AutoConquer.SpecificBase)
            if target and not isGarnisonOwned(target) then smartFireConquer(target) end
            continue
        end
        local candidates = {}
        for _, v in ipairs(bandit:GetChildren()) do
            if v.Name:find("Garnison") and not isGarnisonOwned(v) then
                table.insert(candidates, v)
            end
        end
        if #candidates == 0 then continue end
        local target = nil
        if mode == "All Unconquered" then
            target = candidates[1]
        elseif mode == "Weakest" then
            local low = math.huge
            for _, v in ipairs(candidates) do
                local hp = getGarnisonHP(v)
                if hp < low then low = hp target = v end
            end
        elseif mode == "Nearest" then
            local hrp = character and character:FindFirstChild("HumanoidRootPart")
            if not hrp then continue end
            local shortest = math.huge
            for _, v in ipairs(candidates) do
                local part = v.PrimaryPart or v:FindFirstChildWhichIsA("BasePart")
                if part then
                    local dist = (hrp.Position - part.Position).Magnitude
                    if dist < shortest then shortest = dist target = v end
                end
            end
        elseif mode == "Strongest" then
            local high = -1
            for _, v in ipairs(candidates) do
                local hp = getGarnisonHP(v)
                if hp > high then high = hp target = v end
            end
        end
        if target then smartFireConquer(target) end
    end
end)

-- Normal Raid
task.spawn(function()
    local lastKoth    = nil
    local raidFiredAt = 0
    while true do
        jwait(3)
        local koth     = getKingOfTheHillBase()
        local isActive = koth ~= nil
        if isActive ~= normalRaidActive then
            normalRaidActive = isActive
            updateRaidLabel()
            if isActive then
                notifyUser("Raid", "Raid event is now active!")
            else
                notifyUser("Raid", "Raid event ended.")
                lastKoth    = nil
                raidFiredAt = 0
            end
        end
        if not CONFIG.AutoRaid.Enabled or not isActive then continue end
        if koth:GetAttribute("Owner") == player.Name then continue end
        if lastKoth ~= koth then
            lastKoth = koth
            notifyUser("Auto Raid", "Raid detected! Teleporting...")
            teleportToInstance(koth)
            task.wait(1)
        end
        if tick() - raidFiredAt >= CONQUER_COOLDOWN then
            sendTroopsToPoint(koth, CONFIG.AutoConquer.ArmyIndex)
            raidFiredAt = tick()
        end
    end
end)

-- Toxic Raid
task.spawn(function()
    local lastToxicKoth    = nil
    local toxicRaidFiredAt = 0
    while true do
        jwait(3)
        local toxicKoth = getToxicKingOfTheHillBase()
        local isActive  = toxicKoth ~= nil
        if isActive ~= toxicRaidActive then
            toxicRaidActive = isActive
            updateRaidLabel()
            if isActive then
                notifyUser("Toxic Raid", "Toxic raid event is now active!")
            else
                notifyUser("Toxic Raid", "Toxic raid event ended.")
                lastToxicKoth    = nil
                toxicRaidFiredAt = 0
            end
        end
        if not CONFIG.AutoToxicRaid.Enabled or not isActive then continue end
        if toxicKoth:GetAttribute("Owner") == player.Name then continue end
        if lastToxicKoth ~= toxicKoth then
            lastToxicKoth = toxicKoth
            notifyUser("Auto Toxic Raid", "Toxic raid detected! Teleporting...")
            teleportToInstance(toxicKoth)
            task.wait(1)
        end
        if tick() - toxicRaidFiredAt >= CONQUER_COOLDOWN then
            sendTroopsToToxicPoint(toxicKoth, CONFIG.AutoConquer.ArmyIndex)
            toxicRaidFiredAt = tick()
        end
    end
end)

-- Run Speed
task.spawn(function()
    while true do
        task.wait(0.5)
        if not CONFIG.RunSpeed.Enabled then continue end
        if not cachedHumanoid or not cachedHumanoid.Parent then continue end
        pcall(function() cachedHumanoid.WalkSpeed = CONFIG.RunSpeed.Speed end)
    end
end)

-- Auto save config (เซฟทุก 2 วิ ครอบทุกค่า)
task.spawn(function()
    while true do
        task.wait(2)
        saveConfig()
    end
end)

-- Character respawn
player.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    cachedHumanoid = nil
    cachedBuildingsFolder = nil
    cachedBuildingsFilter = {}
    cachedBuildings = {}
    local hrp = newCharacter:WaitForChild("HumanoidRootPart", 15)
    if hrp then humanoidRootPart = hrp end
    cachedHumanoid = newCharacter:WaitForChild("Humanoid", 15)
    if cachedHumanoid and CONFIG.RunSpeed.Enabled then
        pcall(function() cachedHumanoid.WalkSpeed = CONFIG.RunSpeed.Speed end)
    end
end)
