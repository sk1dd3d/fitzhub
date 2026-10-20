--!nocheck
--[[
    fitz's hub
    file:    FitzHub.lua
    runtime: Roblox executor (client side)
    build:   1.0.0
    game:    Slap Battles (6403373529)

    ui backends are registered through UIBackends / createUI so a second
    library can be dropped in without touching feature code. fluent is the
    first backend; see registerBackend("Fluent").

    layout:
      BUILD          constants
      auth           license gate
      game           place id -> label
      Guard          rate limiting, action envelope
      features       slap battles modules
      ui             backend registry + fluent implementation
      boot           spec, build, globals
]]

local BUILD = {
    version = "1.0.0",
    uiBackend = "Fluent",
    licenseFile = "fitzhub_license.dat",
    licenseKey = "FITZ-0000-0000",
    discord = "https://discord.gg/5pQCshrz6",
    -- accounts that skip the gate entirely
    authorizedUserIds = {
        [11829132322] = "00200200000",
    },
}

-- ---------------------------------------------------------------- services

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local StarterGui = game:GetService("StarterGui")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local VirtualInputManager = game:GetService("VirtualInputManager")

local LocalPlayer = Players.LocalPlayer

-- executor apis are injected as globals into this script's environment.
-- resolve each once at load, every read inside pcall, because some executors
-- have a metatable that throws on unknown globals. never index _G or getgenv()
-- blindly -- either can be a non-table in a given executor.
local function probe(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

local EXEC = {
    loadstring        = probe(function() return loadstring end) or probe(function() return load end),
    request           = probe(function() return request end) or probe(function() return http_request end),
    syn               = probe(function() return syn end),
    http              = probe(function() return http end),
    gethui            = probe(function() return gethui end),
    isfile            = probe(function() return isfile end),
    readfile          = probe(function() return readfile end),
    writefile         = probe(function() return writefile end),
    getrawmetatable   = probe(function() return getrawmetatable end),
    setreadonly       = probe(function() return setreadonly end),
    getnamecallmethod = probe(function() return getnamecallmethod end),
    newcclosure       = probe(function() return newcclosure end),
    setfpscap         = probe(function() return setfpscap end),
    setclipboard      = probe(function() return setclipboard end) or probe(function() return toclipboard end),
    fireclickdetector = probe(function() return fireclickdetector end),
}

local function execFn(name)
    local value = EXEC[name]
    if value ~= nil then return value end
    local ok, genv = pcall(function() return getgenv() end)
    if ok and type(genv) == "table" then
        local okRead, fallback = pcall(function() return genv[name] end)
        if okRead and fallback ~= nil then return fallback end
    end
    return nil
end

local connections = {}
local function track(conn)
    connections[#connections + 1] = conn
    return conn
end

local function guiParent()
    local gethuiFn = execFn("gethui")
    if type(gethuiFn) == "function" then
        local ok, hui = pcall(gethuiFn)
        if ok and hui then return hui end
    end
    return game:GetService("CoreGui")
end

local function notify(title, content)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title = title,
            Text = content,
            Duration = 5,
        })
    end)
end

-- ---------------------------------------------------------------- auth

local function readLicense()
    local isfileFn = execFn("isfile")
    local readfileFn = execFn("readfile")
    if type(isfileFn) ~= "function" or type(readfileFn) ~= "function" then return nil end
    local ok, exists = pcall(isfileFn, BUILD.licenseFile)
    if not ok or not exists then return nil end
    local okRead, data = pcall(readfileFn, BUILD.licenseFile)
    if not okRead or type(data) ~= "string" then return nil end
    return (data:gsub("%s+", ""):upper())
end

local function writeLicense(key)
    local writefileFn = execFn("writefile")
    if type(writefileFn) ~= "function" then return end
    pcall(writefileFn, BUILD.licenseFile, key)
end

local function promptLicense(attempt)
    local gui = Instance.new("ScreenGui")
    gui.Name = "fitz_license_prompt"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 999
    gui.Parent = guiParent()

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromOffset(430, 250)
    frame.Position = UDim2.new(0.5, -215, 0.5, -125)
    frame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 70, 90)
    stroke.Thickness = 1
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -32, 0, 34)
    title.Position = UDim2.fromOffset(16, 14)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.GothamBold
    title.TextSize = 17
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.fromRGB(235, 240, 250)
    title.Text = "fitz's hub | license"
    title.Parent = frame

    local subtitle = Instance.new("TextLabel")
    subtitle.Size = UDim2.new(1, -32, 0, 50)
    subtitle.Position = UDim2.fromOffset(16, 46)
    subtitle.BackgroundTransparency = 1
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextSize = 12
    subtitle.TextWrapped = true
    subtitle.TextXAlignment = Enum.TextXAlignment.Left
    subtitle.TextColor3 = Color3.fromRGB(150, 160, 180)
    subtitle.Text = string.format(
        "get your license key in our discord: %s\nthen paste it below. attempt %d/3",
        BUILD.discord, attempt
    )
    subtitle.Parent = frame

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, -32, 0, 38)
    box.Position = UDim2.fromOffset(16, 106)
    box.BackgroundColor3 = Color3.fromRGB(28, 31, 40)
    box.BorderSizePixel = 0
    box.Font = Enum.Font.Code
    box.TextSize = 14
    box.TextColor3 = Color3.fromRGB(235, 240, 250)
    box.PlaceholderText = "FITZ-XXXX-XXXX"
    box.PlaceholderColor3 = Color3.fromRGB(100, 108, 125)
    box.Text = ""
    box.ClearTextOnFocus = false
    box.Parent = frame

    local boxCorner = Instance.new("UICorner")
    boxCorner.CornerRadius = UDim.new(0, 6)
    boxCorner.Parent = box

    local submit = Instance.new("TextButton")
    submit.Size = UDim2.fromOffset(190, 38)
    submit.Position = UDim2.fromOffset(16, 162)
    submit.BackgroundColor3 = Color3.fromRGB(86, 130, 220)
    submit.BorderSizePixel = 0
    submit.Font = Enum.Font.GothamBold
    submit.TextSize = 14
    submit.TextColor3 = Color3.new(1, 1, 1)
    submit.Text = "activate"
    submit.Parent = frame

    local submitCorner = Instance.new("UICorner")
    submitCorner.CornerRadius = UDim.new(0, 6)
    submitCorner.Parent = submit

    local copyDiscord = Instance.new("TextButton")
    copyDiscord.Size = UDim2.fromOffset(150, 38)
    copyDiscord.Position = UDim2.new(1, -166, 0, 162)
    copyDiscord.BackgroundColor3 = Color3.fromRGB(38, 42, 54)
    copyDiscord.BorderSizePixel = 0
    copyDiscord.Font = Enum.Font.GothamBold
    copyDiscord.TextSize = 13
    copyDiscord.TextColor3 = Color3.fromRGB(200, 208, 222)
    copyDiscord.Text = "copy discord"
    copyDiscord.Parent = frame

    local copyCorner = Instance.new("UICorner")
    copyCorner.CornerRadius = UDim.new(0, 6)
    copyCorner.Parent = copyDiscord

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -32, 0, 24)
    status.Position = UDim2.fromOffset(16, 208)
    status.BackgroundTransparency = 1
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.TextColor3 = Color3.fromRGB(150, 160, 180)
    status.Text = ""
    status.Parent = frame

    copyDiscord.MouseButton1Click:Connect(function()
        local fn = execFn("setclipboard") or execFn("toclipboard")
        if type(fn) == "function" then
            pcall(fn, BUILD.discord)
            status.Text = "copied: " .. BUILD.discord
            status.TextColor3 = Color3.fromRGB(120, 200, 140)
        else
            status.Text = BUILD.discord
        end
    end)

    local result, done = nil, false
    submit.MouseButton1Click:Connect(function()
        result, done = box.Text, true
    end)
    box.FocusLost:Connect(function(enter)
        if enter then
            result, done = box.Text, true
        end
    end)

    pcall(function() box:CaptureFocus() end)

    local deadline = os.clock() + 180
    repeat
        task.wait(0.1)
    until done or os.clock() > deadline or not gui.Parent

    gui:Destroy()
    return result
end

local function authorize()
    if BUILD.authorizedUserIds[LocalPlayer.UserId] then
        return true, "dev-id"
    end

    if readLicense() == BUILD.licenseKey then
        return true, "cached"
    end

    for attempt = 1, 3 do
        local entered = promptLicense(attempt)
        if not entered then break end
        entered = entered:gsub("%s+", ""):upper()
        if entered == BUILD.licenseKey then
            writeLicense(BUILD.licenseKey)
            return true, "license"
        end
    end

    return false, "denied"
end

-- ---------------------------------------------------------------- game

local GAMES = {
    [6403373529] = { name = "Slap Battles", key = "slap" },
}

local function resolveGame()
    local entry = GAMES[game.PlaceId]
    if entry then return entry.name, entry end
    local ok, info = pcall(function()
        return MarketplaceService:GetProductInfo(game.PlaceId, Enum.InfoType.Asset)
    end)
    if ok and type(info) == "table" and type(info.Name) == "string" and info.Name ~= "" then
        return info.Name, nil
    end
    return "Unknown", nil
end

local GAME_LABEL, GAME_ENTRY = resolveGame()

-- ---------------------------------------------------------------- guard

local Guard = {
    lastFire = {},
}

function Guard.fire(remote, minInterval, ...)
    -- type() avoids the typeof narrowing that makes the analyzer treat this as
    -- a bare Instance and reject :FireServer
    if type(remote) ~= "userdata" then return false end
    local now = os.clock()
    local key = remote:GetFullName()
    local last = Guard.lastFire[key] or 0
    local interval = (minInterval or 0) * (0.85 + math.random() * 0.3)
    if now - last < interval then return false end
    Guard.lastFire[key] = now
    local args = table.pack(...)
    return pcall(function()
        remote:FireServer(table.unpack(args, 1, args.n))
    end)
end

function Guard.canAct(requireArena)
    local char = LocalPlayer.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    local rag = char:FindFirstChild("Ragdolled")
    if rag and rag.Value == true then return false end
    if requireArena then
        local arena = char:FindFirstChild("isInArena")
        if arena and arena.Value ~= true then return false end
    end
    return true
end

-- ---------------------------------------------------------------- slap data

local slap = {
    gloveDB = nil,
    querys = nil,
}

local function getGloveDB()
    if slap.gloveDB then return slap.gloveDB end
    local frontend = ReplicatedStorage:FindFirstChild("FRONTEND")
    local databases = frontend and frontend:FindFirstChild("Databases")
    local module = databases and databases:FindFirstChild("Gloves")
    if not module then return {} end
    local ok, db = pcall(require, module)
    if ok and type(db) == "table" then
        slap.gloveDB = db
        return db
    end
    return {}
end

local function num(value, default)
    local n = tonumber(value)
    if n == nil then return default end
    return n
end

local function leaderstatsValue(name)
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    local value = stats and stats:FindFirstChild(name)
    return value and value.Value or nil
end

local function currentGlove()
    return leaderstatsValue("Glove") or "Default"
end

local function gloveList()
    local db = getGloveDB()
    local names = {}
    for name, data in pairs(db) do
        if type(name) == "string" and type(data) == "table" then
            names[#names + 1] = {
                name = name,
                requirement = tonumber(data.SlapRequirement) or 0,
                rarity = data.Rarity,
                kind = data.Type,
            }
        end
    end
    table.sort(names, function(a, b)
        if a.requirement == b.requirement then return a.name < b.name end
        return a.requirement < b.requirement
    end)
    local out = {}
    for _, entry in ipairs(names) do
        out[#out + 1] = entry.name
    end
    return out
end

-- glove stands are lobby models with a ClickDetector; the client-side handler
-- turns that click into the SelectGlove event. clicking the detector is the
-- path the game itself uses, so it needs no network module access.
local function gloveStand(name)
    local lobby = workspace:FindFirstChild("Lobby")
    local stands = lobby and lobby:FindFirstChild("GloveStands")
    if not stands then return nil end

    local direct = stands:FindFirstChild(name)
    if direct then return direct end

    local folded = name:lower():gsub("[^%w]", "")
    for _, child in ipairs(stands:GetChildren()) do
        local candidate = child.Name:lower():gsub("[^%w]", "")
        if candidate == folded then return child end
    end
    return nil
end

local function findClickDetector(root)
    if not root then return nil end
    local direct = root:FindFirstChildOfClass("ClickDetector")
    if direct then return direct end
    for _, child in ipairs(root:GetDescendants()) do
        if child:IsA("ClickDetector") then return child end
    end
    return nil
end

local function equipGlove(name)
    local stand = gloveStand(name)
    if not stand then
        return false, "no stand for " .. tostring(name) .. " in the lobby"
    end

    local detector = findClickDetector(stand)
    if not detector then
        return false, "that stand has no click detector"
    end

    local fireclickdetectorFn = execFn("fireclickdetector")
    if type(fireclickdetectorFn) ~= "function" then
        return false, "executor has no fireclickdetector"
    end

    local ok, err = pcall(fireclickdetectorFn, detector)
    if not ok then
        return false, "click failed: " .. tostring(err)
    end
    return true, "clicked " .. stand.Name
end

local function limbParts(character)
    -- GeneralHit is fired by the game with the touched limb, so feed it limbs
    -- instead of the root. server-side checks accept any part of the victim.
    local parts = {}
    for _, name in ipairs({
        "UpperTorso", "LowerTorso", "Torso", "Head",
        "Left Arm", "Right Arm", "Left Leg", "Right Leg",
    }) do
        local part = character:FindFirstChild(name)
        if part and part:IsA("BasePart") then
            parts[#parts + 1] = part
        end
    end
    if #parts == 0 then
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if hrp then parts[1] = hrp end
    end
    return parts
end

local function inArena(character)
    local arena = character and character:FindFirstChild("isInArena")
    return arena ~= nil and arena.Value == true
end

local function nearestTarget(maxDistance)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return nil, math.huge end
    local limit = num(maxDistance, 14)

    local bestPart, bestDistance = nil, math.huge
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local other = player.Character
            local otherHrp = other and other:FindFirstChild("HumanoidRootPart")
            local hum = other and other:FindFirstChildOfClass("Humanoid")
            if otherHrp and hum and hum.Health > 0 and inArena(other) then
                local distance = (otherHrp.Position - hrp.Position).Magnitude
                if distance < bestDistance and distance <= limit then
                    local limbs = limbParts(other)
                    bestPart = limbs[math.random(1, math.max(#limbs, 1))] or otherHrp
                    bestDistance = distance
                end
            end
        end
    end
    return bestPart, bestDistance
end

local function targetsWithin(radius)
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local out = {}
    if not hrp then return out end
    local limit = num(radius, 20)

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local other = player.Character
            local otherHrp = other and other:FindFirstChild("HumanoidRootPart")
            local hum = other and other:FindFirstChildOfClass("Humanoid")
            if otherHrp and hum and hum.Health > 0 and inArena(other) then
                if (otherHrp.Position - hrp.Position).Magnitude <= limit then
                    local limbs = limbParts(other)
                    if #limbs > 0 then
                        out[#out + 1] = limbs[math.random(1, #limbs)]
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- features

local Features = {}

Features.autoSlap = {
    enabled = false,
    range = 14,
    cps = 8,
    last = 0,
    requireArena = true,
}

-- not every glove routes through GeneralHit. the framework fires a per-glove
-- remote instead (ReaperHit, KSHit, RetroHit, ...), which is why auto slap
-- looked dead on Reaper and Killstreak. the glove database is the only
-- client-side source that names that remote, so try its obvious fields first,
-- then any RemoteEvent stored on the entry whose name ends in "Hit", then a
-- plain <Glove>Hit lookup, and finally GeneralHit.
local HIT_FIELDS = { "HitRemote", "HitEvent", "HitName", "HitRemoteName", "Remote", "Hit" }

-- gloves whose hit remote isn't just <GloveName>Hit
local HIT_ALIASES = {
    Killstreak = "KSHit",
    Reaper = "ReaperHit",
    ["Ultra Instinct"] = "UTGHit",
    Slapple = "SlappleHit",
}

local hitRemoteCache = {}

local function isRemoteEvent(value)
    if type(value) ~= "userdata" then return false end
    local ok, result = pcall(function() return value:IsA("RemoteEvent") end)
    return ok and result == true
end

local function instanceName(value)
    local ok, name = pcall(function() return value.Name end)
    if ok and type(name) == "string" then return name end
    return nil
end

local function resolveHitRemote(gloveName)
    gloveName = tostring(gloveName or "Default")

    local cached = hitRemoteCache[gloveName]
    if cached then return cached.remote, cached.name end

    local entry = getGloveDB()[gloveName]
    if type(entry) == "table" then
        for _, field in ipairs(HIT_FIELDS) do
            local value = entry[field]
            if type(value) == "string" then
                local remote = ReplicatedStorage:FindFirstChild(value)
                if isRemoteEvent(remote) then
                    hitRemoteCache[gloveName] = { remote = remote, name = value }
                    return remote, value
                end
            end
        end
        for _, value in pairs(entry) do
            if isRemoteEvent(value) then
                local name = instanceName(value)
                if name and name:match("Hit$") then
                    hitRemoteCache[gloveName] = { remote = value, name = name }
                    return value, name
                end
            end
        end
    end

    local alias = HIT_ALIASES[gloveName]
    if alias then
        local remote = ReplicatedStorage:FindFirstChild(alias)
        if isRemoteEvent(remote) then
            hitRemoteCache[gloveName] = { remote = remote, name = alias }
            return remote, alias
        end
    end

    local guess = ReplicatedStorage:FindFirstChild(gloveName .. "Hit")
    if isRemoteEvent(guess) then
        hitRemoteCache[gloveName] = { remote = guess, name = guess.Name }
        return guess, guess.Name
    end

    local general = ReplicatedStorage:FindFirstChild("GeneralHit")
    hitRemoteCache[gloveName] = { remote = general, name = "GeneralHit" }
    return general, "GeneralHit"
end

local function fireHit(part, minInterval)
    if not part then return false end
    local remote = resolveHitRemote(currentGlove())
    if not remote then return false end
    return Guard.fire(remote, minInterval or 0.1, part)
end

function Features.autoSlap.start()
    if Features.autoSlap.connection then return end
    Features.autoSlap.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.autoSlap.enabled then return end
        if not Guard.canAct(Features.autoSlap.requireArena) then return end

        local cps = math.max(num(Features.autoSlap.cps, 8), 0.5)
        local interval = 1 / cps
        if os.clock() - Features.autoSlap.last < interval then return end

        local part = nearestTarget(Features.autoSlap.range)
        if not part then return end

        if fireHit(part, interval * 0.9) then
            Features.autoSlap.last = os.clock()
        end
    end))
end

-- slap aura: fires GeneralHit at every valid target inside a radius on each
-- tick. the game's own glove scripts do the same thing on Touched, so a burst
-- of hits per cycle is indistinguishable from a wide glow.
Features.slapAura = {
    enabled = false,
    radius = 22,
    cps = 6,
    last = 0,
    maxTargets = 8,
}

function Features.slapAura.start()
    if Features.slapAura.connection then return end
    Features.slapAura.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.slapAura.enabled then return end
        if not Guard.canAct(false) then return end

        local cps = math.max(num(Features.slapAura.cps, 6), 0.5)
        local interval = 1 / cps
        if os.clock() - Features.slapAura.last < interval then return end
        Features.slapAura.last = os.clock()

        local parts = targetsWithin(Features.slapAura.radius)
        local sent = 0
        for _, part in ipairs(parts) do
            if sent >= num(Features.slapAura.maxTargets, 8) then break end
            if fireHit(part, 0.06) then sent += 1 end
        end
    end))
end

Features.autoAbility = {
    enabled = false,
    key = "E",
    interval = 1.0,
    last = 0,
}

local function tapKey(keyName)
    local keyCode = Enum.KeyCode[keyName]
    if not keyCode then return false end
    local ok = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        task.wait(0.03)
        VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
    end)
    return ok
end

function Features.autoAbility.start()
    if Features.autoAbility.connection then return end
    Features.autoAbility.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.autoAbility.enabled then return end
        if not Guard.canAct(false) then return end
        if os.clock() - Features.autoAbility.last < Features.autoAbility.interval then return end
        Features.autoAbility.last = os.clock()
        tapKey(Features.autoAbility.key)
    end))
end

Features.hitbox = {
    enabled = false,
    size = 5,
    hide = true,
    original = {},
    connection = nil,
}

local function hitboxPart()
    return workspace:FindFirstChild(LocalPlayer.Name .. "_hitbox")
end

local function equippedTool()
    local char = LocalPlayer.Character
    if not char then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if tool then return tool end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    return backpack and backpack:FindFirstChildOfClass("Tool") or nil
end

-- the glove's own touch part is what the game's OnGloveTouch hook watches, so
-- that is the surface worth scaling. workspace.<name>_hitbox only exists for a
-- couple of gloves, which is why the old version looked dead.
local function gloveTouchParts()
    local tool = equippedTool()
    local out = {}
    if not tool then return out end
    for _, child in ipairs(tool:GetDescendants()) do
        if child:IsA("BasePart") then
            if child.Name == "Glove" or child.Name:find("hitbox") or child.Name == "Handle" then
                out[#out + 1] = child
            end
        end
    end
    if #out == 0 then
        local handle = tool:FindFirstChild("Handle")
        if handle and handle:IsA("BasePart") then out[1] = handle end
    end
    return out
end

function Features.hitbox.apply()
    local scale = math.max(num(Features.hitbox.size, 3), 0.5)
    local touched = false

    for _, part in ipairs(gloveTouchParts()) do
        local key = part:GetFullName()
        if not Features.hitbox.original[key] then
            Features.hitbox.original[key] = {
                size = part.Size,
                transparency = part.Transparency,
            }
        end
        part.Size = Vector3.new(scale, scale, scale)
        part.CanCollide = false
        -- the expanded part is a big obvious box otherwise; keep it invisible
        -- so the glove still looks like the glove
        part.Transparency = Features.hitbox.hide and 1 or Features.hitbox.original[key].transparency
        touched = true
    end

    local own = hitboxPart()
    if own then
        local key = own:GetFullName()
        if not Features.hitbox.original[key] then
            Features.hitbox.original[key] = {
                size = own.Size,
                transparency = own.Transparency,
            }
        end
        own.Size = Vector3.new(scale, scale, scale)
        own.CanCollide = false
        own.Massless = true
        own.Transparency = Features.hitbox.hide and 1 or Features.hitbox.original[key].transparency
        touched = true
    end

    return touched
end

function Features.hitbox.restore()
    for path, saved in pairs(Features.hitbox.original) do
        local inst = nil
        local tool = equippedTool()
        if tool then
            for _, child in ipairs(tool:GetDescendants()) do
                if child:GetFullName() == path then inst = child break end
            end
        end
        local own = hitboxPart()
        if own and own:GetFullName() == path then inst = own end
        if inst and inst:IsA("BasePart") then
            if type(saved) == "table" then
                pcall(function()
                    inst.Size = saved.size
                    inst.Transparency = saved.transparency
                end)
            else
                pcall(function() inst.Size = saved end)
            end
        end
    end
    Features.hitbox.original = {}
end

function Features.hitbox.start()
    if Features.hitbox.connection then return end
    Features.hitbox.connection = track(RunService.Heartbeat:Connect(function()
        if Features.hitbox.enabled then
            Features.hitbox.apply()
        end
    end))
end

-- ragdoll can't be cancelled from the client: the server owns the state and
-- re-applies it. what we can do is stop the character from moving while it
-- lasts. anchoring every part the moment the flag flips means client-applied
-- knockback (KnockbackClient calls KnockbackCharacter locally) has nothing to
-- push — the impulse still lands, the assembly just ignores it.
--
-- the freeze is capped so a stuck Ragdolled flag can't leave you anchored
-- forever; once the cap is hit we wait for the flag to clear before re-arming.
local FREEZE_TIMEOUT = 12

Features.antiRagdoll = {
    enabled = false,
    connection = nil,
    frozen = nil,
    frozenAt = 0,
    tripped = false,
}

local function freezeCharacter(character)
    if Features.antiRagdoll.frozen then return end
    local saved = {}
    for _, part in ipairs(character:GetDescendants()) do
        if part:IsA("BasePart") then
            saved[part] = part.Anchored
            pcall(function()
                part.AssemblyLinearVelocity = Vector3.zero
                part.AssemblyAngularVelocity = Vector3.zero
                part.Anchored = true
            end)
        end
    end
    Features.antiRagdoll.frozen = saved
    Features.antiRagdoll.frozenAt = os.clock()
end

local function unfreezeCharacter()
    local saved = Features.antiRagdoll.frozen
    if not saved then return end
    Features.antiRagdoll.frozen = nil
    for part, wasAnchored in pairs(saved) do
        if part and part.Parent then
            pcall(function() part.Anchored = wasAnchored end)
        end
    end
end

local function updateRagdoll(character)
    if not Features.antiRagdoll.enabled then return end
    local flag = character and character:FindFirstChild("Ragdolled")
    if not flag then return end

    -- the game's own ragdoll handler bails out early when this attribute is
    -- set, so setting it keeps the platformstand loop from ever running
    if character:GetAttribute("ignore_ragdolled") ~= true then
        pcall(function() character:SetAttribute("ignore_ragdolled", true) end)
    end

    if flag.Value ~= true then
        unfreezeCharacter()
        Features.antiRagdoll.tripped = false
        return
    end
    if Features.antiRagdoll.tripped then return end

    freezeCharacter(character)
    if Features.antiRagdoll.frozen then
        if os.clock() - Features.antiRagdoll.frozenAt > FREEZE_TIMEOUT then
            unfreezeCharacter()
            Features.antiRagdoll.tripped = true
            return
        end
        -- re-anchor anything the game unanchored mid-ragdoll
        for part in pairs(Features.antiRagdoll.frozen) do
            if part.Parent and not part.Anchored then
                pcall(function() part.Anchored = true end)
            end
        end
    end
end

function Features.antiRagdoll.set(on)
    Features.antiRagdoll.enabled = on
    if Features.antiRagdoll.connection then
        Features.antiRagdoll.connection:Disconnect()
        Features.antiRagdoll.connection = nil
    end
    unfreezeCharacter()
    Features.antiRagdoll.tripped = false

    if not on then
        local old = LocalPlayer.Character
        if old and old:GetAttribute("ignore_ragdolled") then
            pcall(function() old:SetAttribute("ignore_ragdolled", nil) end)
        end
        return true
    end

    local char = LocalPlayer.Character
    if char then updateRagdoll(char) end

    Features.antiRagdoll.connection = track(RunService.Heartbeat:Connect(function()
        local character = LocalPlayer.Character
        if character then updateRagdoll(character) end
    end))

    track(LocalPlayer.CharacterAdded:Connect(function()
        unfreezeCharacter()
        Features.antiRagdoll.tripped = false
    end))
    return true
end

-- immunity -----------------------------------------------------------
--
-- these modules all watch the character and push back against whatever the
-- game is doing to it. they never ask the server for anything, so there is no
-- call for it to reject.

Features.antiVoid = {
    enabled = false,
    drop = 120,
    connection = nil,
    safe = nil,
}

local function updateVoid()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum or hum.Health <= 0 then
        Features.antiVoid.safe = nil
        return
    end

    local rag = char:FindFirstChild("Ragdolled")
    -- any frame standing on solid ground is a position worth returning to
    if hum.FloorMaterial ~= Enum.Material.Air and not (rag and rag.Value == true) then
        Features.antiVoid.safe = hrp.CFrame
        return
    end

    local safe = Features.antiVoid.safe
    if not safe then return end
    local limit = math.max(num(Features.antiVoid.drop, 120), 20)
    if hrp.Position.Y < safe.Position.Y - limit then
        pcall(function() char:PivotTo(safe) end)
    end
end

function Features.antiVoid.set(on)
    Features.antiVoid.enabled = on
    Features.antiVoid.safe = nil
    if Features.antiVoid.connection then
        Features.antiVoid.connection:Disconnect()
        Features.antiVoid.connection = nil
    end
    if not on then return true end
    Features.antiVoid.connection = track(RunService.Heartbeat:Connect(updateVoid))
    return true
end

Features.antiFling = {
    enabled = false,
    max = 900,
    connection = nil,
}

local function updateFling()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local limit = math.max(num(Features.antiFling.max, 900), 100)
    pcall(function()
        if hrp.AssemblyAngularVelocity.Magnitude > limit then
            hrp.AssemblyAngularVelocity = Vector3.zero
        end
        if hrp.AssemblyLinearVelocity.Magnitude > limit * 4 then
            hrp.AssemblyLinearVelocity = Vector3.zero
        end
    end)
end

function Features.antiFling.set(on)
    Features.antiFling.enabled = on
    if Features.antiFling.connection then
        Features.antiFling.connection:Disconnect()
        Features.antiFling.connection = nil
    end
    if not on then return true end
    Features.antiFling.connection = track(RunService.Heartbeat:Connect(updateFling))
    return true
end

Features.antiSlow = {
    enabled = false,
    walkspeed = 16,
    jump = 50,
    connection = nil,
}

local function updateSlow()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return end

    if hum.WalkSpeed < 1 and not Features.speed.enabled then
        hum.WalkSpeed = num(Features.antiSlow.walkspeed, 16)
    end
    if hum.JumpPower < 1 and not Features.speed.jumpEnabled then
        hum.UseJumpPower = true
        hum.JumpPower = num(Features.antiSlow.jump, 50)
    end

    -- a frozen root part is the other way the game holds you still; leave it
    -- alone while ragdolled, since anti ragdoll anchors on purpose
    local hrp = char:FindFirstChild("HumanoidRootPart")
    local rag = char:FindFirstChild("Ragdolled")
    if hrp and hrp.Anchored and not (rag and rag.Value == true) then
        pcall(function() hrp.Anchored = false end)
    end
end

function Features.antiSlow.set(on)
    Features.antiSlow.enabled = on
    if Features.antiSlow.connection then
        Features.antiSlow.connection:Disconnect()
        Features.antiSlow.connection = nil
    end
    if not on then return true end
    Features.antiSlow.connection = track(RunService.Heartbeat:Connect(updateSlow))
    return true
end

-- teleports ----------------------------------------------------------
--
-- every entry here is a remote the dumped client itself fires, so we're only
-- replaying a call the game already makes. unlocks stay server side: if you
-- haven't opened the route the request is simply ignored instead of moving you.
local function remoteAt(...)
    local node = ReplicatedStorage
    for _, segment in ipairs({ ... }) do
        local child = node and node:FindFirstChild(segment)
        if not child then return nil end
        node = child
    end
    return node
end

local TELEPORT_GROUPS = {
    {
        title = "fast travel",
        note = "short hops you unlock by playing the obbies.",
        entries = {
            { title = "Limbo", desc = "travel to limbo", path = { "ClaimLimboFastTravel" } },
            { title = "Retro", desc = "travel to the retro area", path = { "ClaimRetroFastTravel" } },
            { title = "Ice trials", desc = "travel to the ice trials", path = { "IceTrialsFastTravel" } },
            { title = "Friday the 13th", desc = "travel to the event map", path = { "TeleportFriday13th" } },
            { title = "Bounty hunter", desc = "travel to the bounty hunter room", path = { "Events", "suction_obby_tp" } },
        },
    },
    {
        title = "obtainment",
        note = "straight into the obtainment areas.",
        entries = {
            { title = "Slenderman", desc = "go to the slenderman area", path = { "Remotes", "SlendermanObtainmentTeleport" } },
            { title = "Shopkeeper", desc = "go to the shopkeeper area", path = { "Remotes", "ShopkeeperObtainmentTeleport" } },
        },
    },
    {
        title = "arena",
        note = "join a match. a running one will refuse you.",
        entries = {
            { title = "Normal arena", desc = "join the normal arena", path = { "Remotes", "NormalArenaTeleport" } },
            { title = "Glitch realm", desc = "go to the glitch realm", path = { "GlitchTP" }, args = { true } },
        },
    },
    {
        title = "retro obby",
        entries = {
            { title = "Enter", desc = "enter the retro obby", path = { "EnterRetroObby" } },
            { title = "Leave", desc = "leave the retro obby", path = { "LeaveRetroObby" } },
            { title = "Retro TP", desc = "continue the retro obby", path = { "RetroTP" } },
        },
    },
}

Features.teleport = {}

function Features.teleport.send(entry)
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChildOfClass("Humanoid") then
        return false, "no character"
    end

    local remote = remoteAt(table.unpack(entry.path))
    if not remote then
        return false, "missing remote " .. table.concat(entry.path, ".")
    end

    if not Guard.fire(remote, 1, table.unpack(entry.args or {})) then
        return false, "call failed"
    end
    return true, "sent " .. (entry.title or remote.Name)
end

-- WarpTarget is the only teleport that needs a subject. the client fires it
-- with a Player, so we do the same.
function Features.teleport.warp(name)
    local remote = remoteAt("WarpTarget")
    if not remote then return false, "no WarpTarget remote" end

    local target = Players:FindFirstChild(name)
    if not target or target == LocalPlayer then return false, "player left" end
    if not Guard.fire(remote, 1, target) then return false, "call failed" end

    return true, "warping to " .. target.Name
end

-- progression ---------------------------------------------------------
--
-- daily rewards, crates, badge quests and twitter codes all live behind the
-- same _NETWORK dispatcher the game's own interface uses. RemoteFunctions are
-- invoked directly, RemoteEvents fired, and every call is rate limited.

local function netRemote(name)
    local folder = ReplicatedStorage:FindFirstChild("_NETWORK")
    return folder and folder:FindFirstChild(name) or nil
end

local function netCall(name, minInterval, ...)
    local remote = netRemote(name)
    if type(remote) ~= "userdata" then return false, "missing " .. name end

    local now = os.clock()
    local key = "call:" .. name
    local last = Guard.lastFire[key] or 0
    if now - last < (minInterval or 1) then return false, "cooldown" end
    Guard.lastFire[key] = now

    local args = table.pack(...)
    local ok, result = pcall(function()
        return remote:InvokeServer(table.unpack(args, 1, args.n))
    end)
    if not ok then return false, tostring(result) end
    return true, result
end

local function querysModule()
    if slap.querys ~= nil then return slap.querys or nil end
    local backend = ReplicatedStorage:FindFirstChild("BACKEND")
    local shared = backend and backend:FindFirstChild("Shared")
    local module = shared and shared:FindFirstChild("Querys")
    if not module then
        slap.querys = false
        return nil
    end
    local ok, querys = pcall(require, module)
    if ok and type(querys) == "table" then
        slap.querys = querys
        return querys
    end
    slap.querys = false
    return nil
end

local function crateItems()
    local q = querysModule()
    if not q or type(q.GetInventoryItems) ~= "function" then return {} end
    local ok, items = pcall(q.GetInventoryItems, LocalPlayer, "Crate")
    if not ok or type(items) ~= "table" then return {} end
    local out = {}
    for _, item in ipairs(items) do
        if type(item) == "table" and item.itemID then
            out[#out + 1] = item
        end
    end
    return out
end

local function questChains()
    local q = querysModule()
    if not q or type(q.GetQuestChains) ~= "function" then return {} end
    local ok, chains = pcall(q.GetQuestChains)
    if not ok or type(chains) ~= "table" then return {} end
    return chains
end

local function questStatus(id)
    local q = querysModule()
    if not q or type(q.GetBadgeQuestStatus) ~= "function" then return nil end
    local ok, status = pcall(q.GetBadgeQuestStatus, LocalPlayer, id)
    if not ok or status == nil then return nil end
    -- GetBadgeQuestStatus returns an Enum.QuestStatus item; fall back to the
    -- stringified form in case an update swaps it for a plain string
    local okName, name = pcall(function() return status.Name end)
    if okName and type(name) == "string" then return name end
    local text = tostring(status)
    return (text:gsub("^Enum%.QuestStatus%.", ""))
end

Features.progression = {
    autoQuests = false,
    interval = 20,
    last = 0,
    connection = nil,
}

function Features.progression.claimDaily()
    local ok, result = netCall("ClaimDailyReward", 5)
    if not ok then return false, result end
    return true, type(result) == "string" and result or "claimed"
end

function Features.progression.openCrates()
    local crates = crateItems()
    if #crates == 0 then return false, "no crates in inventory" end
    local opened = 0
    for _, item in ipairs(crates) do
        local ok = netCall("OpenCrate", 1.2, item.itemID)
        if ok then opened += 1 end
    end
    if opened == 0 then return false, "all opens failed" end
    return true, string.format("opened %d of %d", opened, #crates)
end

function Features.progression.redeemCode(code)
    code = tostring(code or ""):gsub("%s+", "")
    if code == "" then return false, "enter a code first" end
    local ok, result = netCall("RedeemTwitterCode", 2, code)
    if not ok then return false, result end
    if type(result) == "string" then return true, result end
    return true, "submitted " .. code
end

function Features.progression.tick()
    local chains = questChains()
    if #chains == 0 then return 0, 0 end

    local activated, collected = 0, 0
    for _, id in ipairs(chains) do
        local status = questStatus(id)
        if status == "Rewardable" then
            local remote = netRemote("CollectBadgeQuestReward")
            if remote and Guard.fire(remote, 1, id) then collected += 1 end
        elseif status == "Inactive" then
            local remote = netRemote("ActivateBadgeQuest")
            if remote and Guard.fire(remote, 1, id) then activated += 1 end
        end
    end
    return activated, collected
end

function Features.progression.start()
    if Features.progression.connection then return end
    Features.progression.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.progression.autoQuests then return end
        local interval = math.max(num(Features.progression.interval, 20), 5)
        if os.clock() - Features.progression.last < interval then return end
        Features.progression.last = os.clock()
        local ok, activated, collected = pcall(Features.progression.tick)
        if ok and (activated > 0 or collected > 0) then
            print(string.format("[fitz] quests: %d activated, %d collected", activated, collected))
        end
    end))
end

Features.soulbank = { enabled = false, threshold = 10, connection = nil, last = 0 }

-- killstreak banks up to ten kills for a bigger hit. releasing at max is a
-- free power spike, and the release remote takes no arguments.
function Features.soulbank.start()
    if Features.soulbank.connection then return end
    Features.soulbank.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.soulbank.enabled then return end
        if currentGlove() ~= "Killstreak" then return end
        if os.clock() - Features.soulbank.last < 1 then return end

        local stored = LocalPlayer:GetAttribute("SoulBankKills") or 0
        if tonumber(stored) and tonumber(stored) >= num(Features.soulbank.threshold, 10) then
            local remote = ReplicatedStorage:FindFirstChild("KillstreakSoulbankRelease")
            if remote and isRemoteEvent(remote) then
                Features.soulbank.last = os.clock()
                Guard.fire(remote, 1)
            end
        end
    end))
end

-- a single __namecall patch that several modules can subscribe to. patching
-- twice would mean the second patch wraps the first, and toggling either one
-- off would silently unhook the other.
local Namecall = {
    installed = false,
    listeners = {},
    metas = {},
}

local function namecallApply()
    local getrawmetatableFn = execFn("getrawmetatable")
    local setreadonlyFn = execFn("setreadonly")
    local getnamecallmethodFn = execFn("getnamecallmethod")
    local newcclosureFn = execFn("newcclosure")

    if type(getrawmetatableFn) ~= "function" or type(getnamecallmethodFn) ~= "function" then
        return false, "not supported by this executor"
    end

    local instances = { game }
    -- remotes often live on their own metatable in newer clients
    local okRemote, remote = pcall(function() return game:GetService("ReplicatedStorage") end)
    if okRemote and remote then instances[#instances + 1] = remote end

    local patched = 0
    for _, instance in ipairs(instances) do
        local ok, mt = pcall(getrawmetatableFn, instance)
        if ok and mt and not Namecall.metas[mt] then
            local previous = mt.__namecall
            if type(previous) == "function" then
                local handler = function(self, ...)
                    local method = getnamecallmethodFn()
                    for _, listener in pairs(Namecall.listeners) do
                        local drop = listener(method, self, ...)
                        if drop then return end
                    end
                    return previous(self, ...)
                end
                if type(newcclosureFn) == "function" then
                    handler = newcclosureFn(handler)
                end
                if type(setreadonlyFn) == "function" then setreadonlyFn(mt, false) end
                mt.__namecall = handler
                if type(setreadonlyFn) == "function" then setreadonlyFn(mt, true) end
                Namecall.metas[mt] = previous
                patched += 1
            end
        end
    end

    if patched == 0 then return false, "no metatable access" end
    Namecall.installed = true
    return true
end

local function namecallRestore()
    local setreadonlyFn = execFn("setreadonly")
    for mt, previous in pairs(Namecall.metas) do
        pcall(function()
            if type(setreadonlyFn) == "function" then setreadonlyFn(mt, false) end
            mt.__namecall = previous
            if type(setreadonlyFn) == "function" then setreadonlyFn(mt, true) end
        end)
    end
    Namecall.metas = {}
    Namecall.installed = false
end

function Namecall.add(id, listener)
    Namecall.listeners[id] = listener
    if Namecall.installed then return true end
    return namecallApply()
end

function Namecall.remove(id)
    Namecall.listeners[id] = nil
    if next(Namecall.listeners) == nil then
        namecallRestore()
    end
end

Features.antiKick = { enabled = false }

-- some servers kick on a suspicious call before the round even resolves. we
-- can't stop the server from deciding, but we can drop the kick request that
-- arrives on the client. nothing is hidden: if the server disconnects you at
-- the replication layer instead, this never sees it.
function Features.antiKick.set(on)
    Features.antiKick.enabled = on
    if not on then
        Namecall.remove("antiKick")
        return true
    end
    local ok, err = Namecall.add("antiKick", function(method)
        if method == "Kick" and Features.antiKick.enabled then
            print("[fitz] blocked a kick request")
            return true
        end
        return false
    end)
    if not ok then
        Features.antiKick.enabled = false
        return false, err
    end
    return true
end

Features.stats = { enabled = false, gui = nil, label = nil, connection = nil }

function Features.stats.stop()
    if Features.stats.gui then
        Features.stats.gui:Destroy()
    end
    Features.stats.gui, Features.stats.label = nil, nil
    if Features.stats.connection then
        Features.stats.connection:Disconnect()
        Features.stats.connection = nil
    end
end

function Features.stats.start()
    Features.stats.stop()
    local gui = Instance.new("ScreenGui")
    gui.Name = "fitz_stats"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 50
    gui.Parent = guiParent()

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromOffset(210, 96)
    label.Position = UDim2.new(0, 12, 0, 12)
    label.BackgroundColor3 = Color3.fromRGB(14, 16, 21)
    label.BackgroundTransparency = 0.25
    label.BorderSizePixel = 0
    label.Font = Enum.Font.Code
    label.TextSize = 13
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Top
    label.TextColor3 = Color3.fromRGB(230, 236, 246)
    label.Text = ""
    label.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = label

    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 8)
    pad.PaddingLeft = UDim.new(0, 10)
    pad.Parent = label

    Features.stats.gui, Features.stats.label = gui, label
    Features.stats.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.stats.label then return end
        local slaps = leaderstatsValue("Slaps")
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        Features.stats.label.Text = string.format(
            "slaps   %s\nglove   %s\nhealth  %s\nplayers %d",
            tostring(slaps or "-"),
            tostring(currentGlove()),
            hum and string.format("%d", math.floor(hum.Health)) or "-",
            #Players:GetPlayers()
        )
    end))
end

Features.speed = { enabled = false, value = 24, jump = 60, jumpEnabled = false }

function Features.speed.apply()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    hum.WalkSpeed = Features.speed.enabled and Features.speed.value or 16
    if Features.speed.jumpEnabled then
        hum.UseJumpPower = true
        hum.JumpPower = Features.speed.jump
    end
end

function Features.speed.restore()
    local char = LocalPlayer.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    hum.WalkSpeed = 16
    hum.JumpPower = 50
end

Features.fly = { enabled = false, speed = 60, bv = nil, bg = nil, connection = nil }

function Features.fly.stop()
    if Features.fly.bv then Features.fly.bv:Destroy() end
    if Features.fly.bg then Features.fly.bg:Destroy() end
    Features.fly.bv, Features.fly.bg = nil, nil
    if Features.fly.connection then
        Features.fly.connection:Disconnect()
        Features.fly.connection = nil
    end
end

function Features.fly.start()
    Features.fly.stop()
    local char = LocalPlayer.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local bv = Instance.new("BodyVelocity")
    bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
    bv.Velocity = Vector3.zero
    bv.Parent = hrp

    local bg = Instance.new("BodyGyro")
    bg.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
    bg.P = 1200
    bg.CFrame = hrp.CFrame
    bg.Parent = hrp

    Features.fly.bv, Features.fly.bg = bv, bg
    Features.fly.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.fly.enabled then return end
        local camera = workspace.CurrentCamera
        if not camera then return end
        local move = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += camera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= camera.CFrame.LookVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= camera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += camera.CFrame.RightVector end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.yAxis end
        if move.Magnitude > 0 then
            bv.Velocity = move.Unit * Features.fly.speed
        else
            bv.Velocity = Vector3.zero
        end
        bg.CFrame = camera.CFrame
    end))
    return true
end

Features.noclip = { enabled = false, connection = nil }

function Features.noclip.start()
    if Features.noclip.connection then return end
    Features.noclip.connection = track(RunService.Stepped:Connect(function()
        if not Features.noclip.enabled then return end
        local char = LocalPlayer.Character
        if not char then return end
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end))
end

Features.infiniteJump = { enabled = false, connection = nil }

function Features.infiniteJump.start()
    if Features.infiniteJump.connection then return end
    Features.infiniteJump.connection = track(UserInputService.JumpRequest:Connect(function()
        if not Features.infiniteJump.enabled then return end
        local char = LocalPlayer.Character
        local hum = char and char:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end))
end

Features.gloveLock = { enabled = false, name = nil, connection = nil, last = 0 }

function Features.gloveLock.start()
    if Features.gloveLock.connection then return end
    Features.gloveLock.connection = track(RunService.Heartbeat:Connect(function()
        if not Features.gloveLock.enabled or not Features.gloveLock.name then return end
        if os.clock() - Features.gloveLock.last < 3 then return end
        local current = currentGlove()
        if current ~= Features.gloveLock.name then
            Features.gloveLock.last = os.clock()
            -- stands only exist in the lobby; in-arena swaps have no click path
            equipGlove(Features.gloveLock.name)
        end
    end))
end

Features.esp = {
    enabled = false,
    showGlove = true,
    entries = {},
    connection = nil,
    folder = nil,
}

local function gloveOf(player)
    local stats = player:FindFirstChild("leaderstats")
    local glove = stats and stats:FindFirstChild("Glove")
    return glove and glove.Value or "?"
end

local function espFolder()
    if Features.esp.folder and Features.esp.folder.Parent then
        return Features.esp.folder
    end
    local folder = Instance.new("Folder")
    folder.Name = "fitz_esp"
    folder.Parent = guiParent()
    Features.esp.folder = folder
    return folder
end

local function destroyEsp(player)
    local entry = Features.esp.entries[player]
    if entry then
        if entry.gui then entry.gui:Destroy() end
        Features.esp.entries[player] = nil
    end
end

local function updateEsp()
    if not Features.esp.enabled then return end
    local char = LocalPlayer.Character
    local myHrp = char and char:FindFirstChild("HumanoidRootPart")

    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local other = player.Character
            local hrp = other and other:FindFirstChild("HumanoidRootPart")
            local hum = other and other:FindFirstChildOfClass("Humanoid")
            if hrp and hum and hum.Health > 0 then
                local entry = Features.esp.entries[player]
                if not entry then
                    local gui = Instance.new("BillboardGui")
                    gui.Name = "fitz_esp_" .. player.UserId
                    gui.Size = UDim2.fromOffset(200, 34)
                    gui.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
                    gui.AlwaysOnTop = true
                    gui.Adornee = hrp
                    gui.Parent = espFolder()

                    local label = Instance.new("TextLabel")
                    label.Size = UDim2.fromScale(1, 1)
                    label.BackgroundTransparency = 1
                    label.Font = Enum.Font.GothamBold
                    label.TextSize = 13
                    label.TextStrokeTransparency = 0.4
                    label.TextColor3 = Color3.fromRGB(235, 240, 250)
                    label.Text = ""
                    label.Parent = gui

                    entry = { gui = gui, label = label }
                    Features.esp.entries[player] = entry
                end

                entry.gui.Adornee = hrp
                local parts = { player.Name }
                if Features.esp.showGlove then
                    parts[#parts + 1] = "[" .. tostring(gloveOf(player)) .. "]"
                end
                if myHrp then
                    parts[#parts + 1] = string.format("%dm", math.floor((hrp.Position - myHrp.Position).Magnitude))
                end
                entry.label.Text = table.concat(parts, "  ")
                entry.gui.Enabled = true
            else
                destroyEsp(player)
            end
        end
    end
end

function Features.esp.start()
    if Features.esp.connection then return end
    Features.esp.connection = track(RunService.Heartbeat:Connect(function()
        updateEsp()
    end))
    track(Players.PlayerRemoving:Connect(function(player)
        destroyEsp(player)
    end))
end

function Features.esp.stop()
    local pending = {}
    for player in pairs(Features.esp.entries) do
        pending[#pending + 1] = player
    end
    for _, player in ipairs(pending) do
        destroyEsp(player)
    end
    if Features.esp.folder then
        Features.esp.folder:Destroy()
        Features.esp.folder = nil
    end
end

Features.fullbright = { enabled = false, saved = nil }

local FULLBRIGHT_PROPS = {
    "Brightness", "ClockTime", "GlobalShadows", "Ambient", "OutdoorAmbient", "FogEnd",
}

function Features.fullbright.set(on)
    if on then
        if not Features.fullbright.saved then
            local saved = {}
            for _, prop in ipairs(FULLBRIGHT_PROPS) do
                saved[prop] = Lighting[prop]
            end
            Features.fullbright.saved = saved
        end
        Lighting.Brightness = 3
        Lighting.ClockTime = 12
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(180, 180, 180)
        Lighting.OutdoorAmbient = Color3.fromRGB(180, 180, 180)
        Lighting.FogEnd = 100000
    else
        local saved = Features.fullbright.saved
        if saved then
            for prop, value in pairs(saved) do
                Lighting[prop] = value
            end
            Features.fullbright.saved = nil
        end
    end
    Features.fullbright.enabled = on
end

Features.antiAfk = { enabled = false, connection = nil }

function Features.antiAfk.start()
    if Features.antiAfk.connection then return end
    Features.antiAfk.connection = track(LocalPlayer.Idled:Connect(function()
        if not Features.antiAfk.enabled then return end
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end))
end

Features.remoteLogger = { enabled = false, count = 0 }

local function describeValue(value)
    local kind = typeof(value)
    if kind == "Instance" then
        return string.format("<%s:%s>", value.ClassName, value.Name)
    elseif kind == "string" then
        if #value > 60 then return string.format("%q...", value:sub(1, 60)) end
        return string.format("%q", value)
    elseif kind == "number" or kind == "boolean" or kind == "nil" then
        return tostring(value)
    elseif kind == "Vector3" or kind == "CFrame" or kind == "Color3" then
        return tostring(value)
    elseif kind == "table" then
        return "{table}"
    end
    return "<" .. kind .. ">"
end

function Features.remoteLogger.set(on)
    Features.remoteLogger.enabled = on
    if not on then
        Namecall.remove("logger")
        return true
    end
    local ok, err = Namecall.add("logger", function(method, self, ...)
        if method == "FireServer" or method == "InvokeServer" then
            local args = table.pack(...)
            local parts = {}
            for i = 1, args.n do
                parts[#parts + 1] = describeValue(args[i])
            end
            Features.remoteLogger.count += 1
            print(string.format("[fitz remote] %s:%s(%s)",
                self:GetFullName(), method, table.concat(parts, ", ")))
        end
        return false
    end)
    if not ok then
        Features.remoteLogger.enabled = false
        return false, err
    end
    return true
end

-- ---------------------------------------------------------------- server

local function httpGetJson(url)
    local requestFn = execFn("request") or execFn("http_request")
    if type(requestFn) ~= "function" then
        local syn = execFn("syn")
        requestFn = type(syn) == "table" and syn.request or nil
    end
    if type(requestFn) ~= "function" then
        local http = execFn("http")
        requestFn = type(http) == "table" and http.request or nil
    end
    if type(requestFn) ~= "function" then return nil, "no http request function" end
    local ok, response = pcall(requestFn, { Url = url, Method = "GET" })
    if not ok or type(response) ~= "table" then return nil, "request failed" end
    local body = response.Body or response.body
    if type(body) ~= "string" then return nil, "no body" end
    local okDecode, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not okDecode then return nil, "json decode failed" end
    return data
end

local function serverHop()
    local data, err = httpGetJson(string.format(
        "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true",
        game.PlaceId
    ))
    if not data or type(data.data) ~= "table" then
        return false, err or "no server list"
    end
    local candidates = {}
    for _, server in ipairs(data.data) do
        if server.id ~= game.JobId and (server.playing or 0) < (server.maxPlayers or 16) then
            candidates[#candidates + 1] = server.id
        end
    end
    if #candidates == 0 then return false, "no open servers" end
    local target = candidates[math.random(1, #candidates)]
    pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, target, LocalPlayer)
    end)
    return true
end

local function rejoin()
    pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
    end)
end

local function copyJobId()
    local text = tostring(game.JobId)
    local fn = execFn("setclipboard") or execFn("toclipboard")
    if type(fn) == "function" then
        pcall(fn, text)
        return true
    end
    return false, text
end

-- ---------------------------------------------------------------- ui backends

local UIBackends = {}

local function registerBackend(name, loader)
    UIBackends[name] = loader
end

local function createUI(name)
    local loader = UIBackends[name] or UIBackends.Fluent
    if not loader then return nil, "no ui backend: " .. tostring(name) end
    return loader()
end

local FLUENT_URLS = {
    "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua",
    "https://raw.githubusercontent.com/dawid-scripts/Fluent/master/main.lua",
}

local function httpGetText(url)
    local fn = game.HttpGet or game.HttpGetAsync
    if type(fn) == "function" then
        local ok, text = pcall(function()
            return fn(game, url)
        end)
        if ok and type(text) == "string" then return text end
    end

    -- HttpGet is blocked in some executors; request handles the redirect chain
    local requestFn = execFn("request") or execFn("http_request")
    if type(requestFn) ~= "function" then
        local syn = execFn("syn")
        requestFn = type(syn) == "table" and syn.request or nil
    end
    if type(requestFn) ~= "function" then return nil end

    local ok, response = pcall(requestFn, { Url = url, Method = "GET" })
    if not ok or type(response) ~= "table" then return nil end
    local body = response.Body or response.body
    if type(body) == "string" and #body > 0 then return body end
    return nil
end

local function loadFluent()
    local loadstringFn = execFn("loadstring") or execFn("load")
    if type(loadstringFn) ~= "function" then return nil, "executor has no loadstring" end
    local errors = {}
    for _, url in ipairs(FLUENT_URLS) do
        local source = httpGetText(url)
        if source then
            local ok, factory = pcall(loadstringFn, source)
            if ok and type(factory) == "function" then
                local okRun, lib = pcall(factory)
                if okRun and type(lib) == "table" then
                    return lib
                end
                errors[#errors + 1] = string.format("%s: %s", url, tostring(lib))
            else
                errors[#errors + 1] = string.format("%s: %s", url, tostring(factory))
            end
        else
            errors[#errors + 1] = url .. ": fetch failed"
        end
    end
    return nil, table.concat(errors, " | ")
end

registerBackend("Fluent", function()
    local Fluent, fluentError = loadFluent()
    if not Fluent then
        return nil, "fluent failed to load: " .. tostring(fluentError)
    end

    local okWindow, Window = pcall(function()
        return Fluent:CreateWindow({
            Title = "fitz's hub | " .. GAME_LABEL,
            SubTitle = BUILD.version,
            TabWidth = 160,
            Size = UDim2.fromOffset(620, 500),
            Acrylic = false,
            Theme = "Dark",
            MinimizeKey = Enum.KeyCode.RightControl,
        })
    end)
    if not okWindow or not Window then
        return nil, "CreateWindow failed: " .. tostring(Window)
    end

    local SaveManager = nil
    do
        local source = httpGetText("https://raw.githubusercontent.com/dawid-scripts/Fluent/master/Addons/SaveManager.lua")
        local loadstringFn = execFn("loadstring") or execFn("load")
        if source and type(loadstringFn) == "function" then
            local okLoad, factory = pcall(loadstringFn, source)
            if okLoad and type(factory) == "function" then
                local okRun, manager = pcall(factory)
                if okRun and type(manager) == "table" then
                    SaveManager = manager
                end
            end
        end
    end

    local ui = {
        name = "Fluent",
        options = Fluent.Options,
        library = Fluent,
        window = Window,
        saveManager = SaveManager,
        tabs = {},
    }

    function ui.tab(title, icon)
        local raw = Window:AddTab({ Title = title, Icon = icon })
        ui.tabs[title] = raw
        return raw
    end

    function ui.paragraph(parent, opts)
        return parent:AddParagraph(opts)
    end

    function ui.button(parent, opts)
        return parent:AddButton(opts)
    end

    function ui.toggle(parent, id, opts)
        return parent:AddToggle(id, opts)
    end

    function ui.slider(parent, id, opts)
        return parent:AddSlider(id, opts)
    end

    function ui.dropdown(parent, id, opts)
        return parent:AddDropdown(id, opts)
    end

    function ui.textbox(parent, id, opts)
        return parent:AddInput(id, opts)
    end

    function ui.notify(opts)
        return Fluent:Notify(opts)
    end

    return ui
end)

-- ---------------------------------------------------------------- boot

local function buildUniversal(ui)
    local home = ui.tab("Home", "house")
    local settings = ui.tab("Settings", "settings")
    local server = ui.tab("Server", "server")

    ui.paragraph(home, {
        Title = "fitz's hub | " .. GAME_LABEL,
        Content = string.format(
            "version %s\n\nthere is no dedicated module for this game yet, so you get the general tools.",
            BUILD.version
        ),
    })

    ui.toggle(home, "universalAntiAfk", {
        Title = "Anti-AFK",
        Description = "keeps the session from idling out",
        Default = false,
        Callback = function(state)
            Features.antiAfk.enabled = state
        end,
    })
    Features.antiAfk.start()

    ui.button(server, {
        Title = "Server hop",
        Description = "teleport to a random open server",
        Callback = function()
            local ok, err = serverHop()
            ui.notify({
                Title = ok and "hopping" or "hop failed",
                Content = ok and "teleporting" or tostring(err),
                Duration = 4,
            })
        end,
    })

    ui.button(server, {
        Title = "Rejoin",
        Description = "reconnect to the same job",
        Callback = rejoin,
    })

    ui.button(server, {
        Title = "Copy job id",
        Callback = function()
            local ok, text = copyJobId()
            if not ok and text then
                ui.notify({ Title = "job id", Content = text, Duration = 8 })
            end
        end,
    })

    return { home = home, settings = settings, server = server }
end

local function buildSlap(ui)
    local home = ui.tab("Home", "house")
    local combat = ui.tab("Combat", "swords")
    local gloves = ui.tab("Gloves", "hand")
    local travels = ui.tab("Teleports", "map-pin")
    local progress = ui.tab("Progress", "trending-up")
    local immunity = ui.tab("Immunity", "shield")
    local player = ui.tab("Player", "user")
    local visuals = ui.tab("Visuals", "eye")
    local server = ui.tab("Server", "server")
    local settings = ui.tab("Settings", "settings")

    -- home ---------------------------------------------------------------
    ui.paragraph(home, {
        Title = "fitz's hub | " .. GAME_LABEL,
        Content = string.format(
            "version %s\nserver: %s\n\nenjoy the hub.",
            BUILD.version, tostring(game.JobId)
        ),
    })

    ui.button(home, {
        Title = "Copy job id",
        Description = "share this server",
        Callback = function()
            local ok, text = copyJobId()
            if not ok and text then
                ui.notify({ Title = "job id", Content = text, Duration = 8 })
            end
        end,
    })

    ui.button(home, {
        Title = "Rejoin",
        Callback = rejoin,
    })

    ui.button(home, {
        Title = "Discord",
        Description = "copies the invite",
        Callback = function()
            local fn = execFn("setclipboard") or execFn("toclipboard")
            if type(fn) == "function" then
                pcall(fn, BUILD.discord)
                ui.notify({ Title = "discord", Content = "invite copied", Duration = 4 })
            else
                ui.notify({ Title = "discord", Content = BUILD.discord, Duration = 10 })
            end
        end,
    })

    -- combat -------------------------------------------------------------
    ui.paragraph(combat, {
        Title = "slapping",
        Content = "automatically slaps the closest player for you.",
    })

    ui.toggle(combat, "autoSlap", {
        Title = "Auto slap",
        Description = "slaps the nearest player",
        Default = false,
        Callback = function(state)
            Features.autoSlap.enabled = state
        end,
    })

    ui.slider(combat, "autoSlapRange", {
        Title = "Range",
        Description = "studs",
        Default = 14,
        Min = 4,
        Max = 60,
        Rounding = 1,
        Callback = function(value)
            Features.autoSlap.range = num(value, 14)
        end,
    })

    ui.slider(combat, "autoSlapCps", {
        Title = "Slap speed",
        Description = "how many slaps per second",
        Default = 8,
        Min = 1,
        Max = 30,
        Rounding = 0,
        Callback = function(value)
            Features.autoSlap.cps = num(value, 8)
        end,
    })

    ui.toggle(combat, "autoSlapArena", {
        Title = "Only in arena",
        Default = true,
        Callback = function(state)
            Features.autoSlap.requireArena = state
        end,
    })

    ui.toggle(combat, "autoAbility", {
        Title = "Auto ability",
        Description = "presses your ability for you",
        Default = false,
        Callback = function(state)
            Features.autoAbility.enabled = state
        end,
    })

    ui.dropdown(combat, "abilityKey", {
        Title = "Ability key",
        Values = { "E", "R" },
        Default = "E",
        Multi = false,
        Callback = function(value)
            Features.autoAbility.key = value
        end,
    })

    ui.slider(combat, "abilityInterval", {
        Title = "Ability interval",
        Description = "seconds",
        Default = 1.0,
        Min = 0.2,
        Max = 10,
        Rounding = 2,
        Callback = function(value)
            Features.autoAbility.interval = num(value, 1)
        end,
    })

    ui.slider(combat, "hitboxSize", {
        Title = "Reach",
        Description = "bigger number, bigger reach",
        Default = 5,
        Min = 1,
        Max = 25,
        Rounding = 1,
        Callback = function(value)
            Features.hitbox.size = num(value, 5)
            if Features.hitbox.enabled then Features.hitbox.apply() end
        end,
    })

    ui.toggle(combat, "hitboxExpand", {
        Title = "Bigger hitbox",
        Description = "makes your glove reach further",
        Default = false,
        Callback = function(state)
            Features.hitbox.enabled = state
            if state then
                local ok = Features.hitbox.apply()
                if not ok then
                    ui.notify({
                        Title = "hitbox",
                        Content = "no glove equipped — hold one first",
                        Duration = 4,
                    })
                end
            else
                Features.hitbox.restore()
            end
        end,
    })

    ui.toggle(combat, "hitboxHide", {
        Title = "Invisible hitbox",
        Description = "makes the glove marker invisible",
        Default = true,
        Callback = function(state)
            Features.hitbox.hide = state
            if Features.hitbox.enabled then Features.hitbox.apply() end
        end,
    })

    -- slap aura ----------------------------------------------------------
    ui.paragraph(combat, {
        Title = "slap aura",
        Content = "slaps everyone around you, no aiming needed.",
    })

    ui.toggle(combat, "slapAura", {
        Title = "Slap aura",
        Description = "slaps everyone around you",
        Default = false,
        Callback = function(state)
            Features.slapAura.enabled = state
        end,
    })

    ui.slider(combat, "slapAuraRadius", {
        Title = "Aura radius",
        Description = "studs",
        Default = 22,
        Min = 8,
        Max = 80,
        Rounding = 1,
        Callback = function(value)
            Features.slapAura.radius = num(value, 22)
        end,
    })

    ui.slider(combat, "slapAuraCps", {
        Title = "Aura rate",
        Description = "hits per second",
        Default = 6,
        Min = 1,
        Max = 20,
        Rounding = 0,
        Callback = function(value)
            Features.slapAura.cps = num(value, 6)
        end,
    })

    ui.toggle(combat, "soulbank", {
        Title = "Auto soul bank",
        Description = "releases your banked kills as soon as it fills",
        Default = false,
        Callback = function(state)
            Features.soulbank.enabled = state
        end,
    })

    -- immunity -----------------------------------------------------------
    ui.paragraph(immunity, {
        Title = "immunity",
        Content = "stops the game from moving you where it wants. turn these on and forget about them.",
    })

    ui.toggle(immunity, "antiRagdoll", {
        Title = "Anti ragdoll",
        Description = "you stay put instead of getting knocked around",
        Default = false,
        Callback = function(state)
            local ok, err = Features.antiRagdoll.set(state)
            if not ok then
                ui.notify({ Title = "anti ragdoll", Content = tostring(err), Duration = 4 })
            end
        end,
    })

    ui.toggle(immunity, "antiVoid", {
        Title = "Anti void",
        Description = "pulls you back if you fall too far",
        Default = false,
        Callback = function(state)
            Features.antiVoid.set(state)
        end,
    })

    ui.slider(immunity, "antiVoidDrop", {
        Title = "Void distance",
        Description = "how far you can fall before it saves you",
        Default = 120,
        Min = 20,
        Max = 500,
        Rounding = 0,
        Callback = function(value)
            Features.antiVoid.drop = num(value, 120)
        end,
    })

    ui.toggle(immunity, "antiFling", {
        Title = "Anti fling",
        Description = "stops you from being launched into the sky",
        Default = false,
        Callback = function(state)
            Features.antiFling.set(state)
        end,
    })

    ui.toggle(immunity, "antiSlow", {
        Title = "Anti slow",
        Description = "removes speed and jump debuffs",
        Default = false,
        Callback = function(state)
            Features.antiSlow.set(state)
        end,
    })

    ui.toggle(immunity, "antiKick", {
        Title = "Anti kick",
        Description = "blocks kick requests sent to your client",
        Default = false,
        Callback = function(state)
            local ok, err = Features.antiKick.set(state)
            if not ok then
                ui.notify({ Title = "anti kick", Content = tostring(err), Duration = 4 })
            end
        end,
    })

    -- gloves -------------------------------------------------------------
    local names = gloveList()
    ui.paragraph(gloves, {
        Title = "gloves",
        Content = string.format("%d gloves available.", #names),
    })

    -- fluent rejects a Default that is not in Values, so only pass a known one
    local initial = currentGlove()
    local initialValid = false
    for _, name in ipairs(names) do
        if name == initial then
            initialValid = true
            break
        end
    end

    local picker
    picker = ui.dropdown(gloves, "glovePicker", {
        Title = "Glove",
        Values = names,
        Default = initialValid and initial or (names[1] or nil),
        Multi = false,
    })

    ui.button(gloves, {
        Title = "Equip selected",
        Description = "equips it for you",
        Callback = function()
            local value = picker and picker.Value or nil
            if not value then
                ui.notify({ Title = "equip", Content = "pick a glove first", Duration = 4 })
                return
            end
            local ok, err = equipGlove(tostring(value))
            ui.notify({
                Title = ok and "glove" or "equip failed",
                Content = tostring(err or value),
                Duration = 5,
            })
        end,
    })

    ui.button(gloves, {
        Title = "Equip Default",
        Callback = function()
            local ok, err = equipGlove("Default")
            ui.notify({
                Title = ok and "glove" or "equip failed",
                Content = tostring(err or "Default"),
                Duration = 5,
            })
        end,
    })

    ui.button(gloves, {
        Title = "Glove list",
        Description = "lists every glove you can pick",
        Callback = function()
            local names = gloveList()
            if #names == 0 then
                ui.notify({ Title = "gloves", Content = "could not read the list", Duration = 4 })
                return
            end
            for _, name in ipairs(names) do
                print(string.format("[fitz] glove: %s", name))
            end
            ui.notify({ Title = "gloves", Content = #names .. " found (see console)", Duration = 5 })
        end,
    })

    -- teleports -----------------------------------------------------------
    ui.paragraph(travels, {
        Title = "teleports",
        Content = "one button per destination. if you haven't unlocked it yet, nothing will happen.",
    })

    for _, group in ipairs(TELEPORT_GROUPS) do
        ui.paragraph(travels, { Title = group.title, Content = group.note or "" })
        for _, entry in ipairs(group.entries) do
            ui.button(travels, {
                Title = entry.title,
                Description = entry.desc,
                Callback = function()
                    local ok, message = Features.teleport.send(entry)
                    ui.notify({
                        Title = ok and "teleport" or "teleport failed",
                        Content = tostring(message),
                        Duration = 4,
                    })
                end,
            })
        end
    end

    ui.paragraph(travels, {
        Title = "players",
        Content = "jump straight to someone in the server.",
    })

    local warpPicker
    local function warpValues()
        local values = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LocalPlayer then
                values[plr.Name] = plr.Name
            end
        end
        if next(values) == nil then
            values["--"] = "--"
        end
        return values
    end

    local okPicker
    okPicker, warpPicker = pcall(function()
        return ui.dropdown(travels, "warpPicker", {
            Title = "Warp target",
            Values = warpValues(),
            Multi = false,
        })
    end)
    if not okPicker then warpPicker = nil end

    ui.button(travels, {
        Title = "Refresh players",
        Callback = function()
            local values = warpValues()
            if warpPicker then
                pcall(function() warpPicker:SetValues(values) end)
            end
            ui.notify({ Title = "players", Content = #Players:GetPlayers() .. " in server", Duration = 4 })
        end,
    })

    ui.button(travels, {
        Title = "Warp to selected",
        Callback = function()
            local value = warpPicker and warpPicker.Value or nil
            if not value then
                ui.notify({ Title = "warp", Content = "pick a player first", Duration = 4 })
                return
            end
            local ok, message = Features.teleport.warp(tostring(value))
            ui.notify({
                Title = ok and "warp" or "warp failed",
                Content = tostring(message),
                Duration = 4,
            })
        end,
    })

    -- progress ------------------------------------------------------------
    ui.paragraph(progress, {
        Title = "progression",
        Content = "handles your dailies and bounties for you.",
    })

    ui.button(progress, {
        Title = "Claim daily reward",
        Description = "one per day, resets at 00:00 UTC",
        Callback = function()
            local ok, message = Features.progression.claimDaily()
            ui.notify({
                Title = ok and "daily" or "daily failed",
                Content = tostring(message),
                Duration = 5,
            })
        end,
    })

    ui.button(progress, {
        Title = "Open all crates",
        Description = "opens every crate you own",
        Callback = function()
            local ok, message = Features.progression.openCrates()
            ui.notify({
                Title = ok and "crates" or "crates failed",
                Content = tostring(message),
                Duration = 6,
            })
        end,
    })

    ui.paragraph(progress, {
        Title = "badge quests",
        Content = "starts every bounty for you and grabs the rewards when they finish.",
    })

    ui.toggle(progress, "autoQuests", {
        Title = "Auto badge quests",
        Description = "starts and collects bounties automatically",
        Default = false,
        Callback = function(state)
            Features.progression.autoQuests = state
            if state then
                local ok, activated, collected = pcall(Features.progression.tick)
                if ok then
                    ui.notify({
                        Title = "quests",
                        Content = string.format("%d activated, %d collected", activated, collected),
                        Duration = 5,
                    })
                end
            end
        end,
    })

    ui.slider(progress, "questInterval", {
        Title = "Quest check interval",
        Description = "seconds",
        Default = 20,
        Min = 5,
        Max = 120,
        Rounding = 0,
        Callback = function(value)
            Features.progression.interval = num(value, 20)
        end,
    })

    ui.button(progress, {
        Title = "Run quest pass now",
        Callback = function()
            local ok, activated, collected = pcall(Features.progression.tick)
            ui.notify({
                Title = ok and "quests" or "quests failed",
                Content = ok and string.format("%d activated, %d collected", activated, collected)
                    or tostring(activated),
                Duration = 5,
            })
        end,
    })

    ui.paragraph(progress, {
        Title = "codes",
        Content = "enter a code from the game's socials.",
    })

    local codeBox
    local okBox
    okBox, codeBox = pcall(function()
        return ui.textbox(progress, "twitterCode", {
            Title = "Code",
            Placeholder = "code",
            Callback = function() end,
        })
    end)
    if not okBox then codeBox = nil end

    ui.button(progress, {
        Title = "Redeem code",
        Callback = function()
            local value = codeBox and codeBox.Value or nil
            if not value or tostring(value) == "" then
                ui.notify({ Title = "code", Content = "type a code first", Duration = 4 })
                return
            end
            local ok, message = Features.progression.redeemCode(tostring(value))
            ui.notify({
                Title = ok and "code" or "code failed",
                Content = tostring(message),
                Duration = 6,
            })
        end,
    })

    -- player -------------------------------------------------------------
    ui.toggle(player, "speedToggle", {
        Title = "Walk speed",
        Default = false,
        Callback = function(state)
            Features.speed.enabled = state
            Features.speed.apply()
            if not state then Features.speed.restore() end
        end,
    })

    ui.slider(player, "speedValue", {
        Title = "Speed",
        Default = 24,
        Min = 16,
        Max = 120,
        Rounding = 0,
        Callback = function(value)
            Features.speed.value = num(value, 24)
            if Features.speed.enabled then Features.speed.apply() end
        end,
    })

    ui.toggle(player, "jumpToggle", {
        Title = "Jump power",
        Default = false,
        Callback = function(state)
            Features.speed.jumpEnabled = state
            Features.speed.apply()
        end,
    })

    ui.slider(player, "jumpValue", {
        Title = "Jump power",
        Default = 60,
        Min = 50,
        Max = 200,
        Rounding = 0,
        Callback = function(value)
            Features.speed.jump = num(value, 60)
            if Features.speed.jumpEnabled then Features.speed.apply() end
        end,
    })

    ui.toggle(player, "flyToggle", {
        Title = "Fly",
        Description = "wasd + space, camera relative",
        Default = false,
        Callback = function(state)
            Features.fly.enabled = state
            if state then
                local ok = Features.fly.start()
                if not ok then
                    Features.fly.enabled = false
                    ui.notify({ Title = "fly", Content = "no character", Duration = 4 })
                end
            else
                Features.fly.stop()
            end
        end,
    })

    ui.slider(player, "flySpeed", {
        Title = "Fly speed",
        Default = 60,
        Min = 20,
        Max = 300,
        Rounding = 0,
        Callback = function(value)
            Features.fly.speed = num(value, 60)
        end,
    })

    ui.toggle(player, "noclip", {
        Title = "Noclip",
        Default = false,
        Callback = function(state)
            Features.noclip.enabled = state
        end,
    })

    ui.toggle(player, "infiniteJump", {
        Title = "Infinite jump",
        Default = false,
        Callback = function(state)
            Features.infiniteJump.enabled = state
        end,
    })

    -- visuals ------------------------------------------------------------
    ui.toggle(visuals, "espToggle", {
        Title = "Player ESP",
        Description = "name, glove, distance",
        Default = false,
        Callback = function(state)
            Features.esp.enabled = state
            if not state then Features.esp.stop() end
        end,
    })

    ui.toggle(visuals, "espGlove", {
        Title = "Show glove",
        Default = true,
        Callback = function(state)
            Features.esp.showGlove = state
        end,
    })

    ui.toggle(visuals, "statsHud", {
        Title = "Stats hud",
        Description = "shows your slaps, glove and health on screen",
        Default = false,
        Callback = function(state)
            Features.stats.enabled = state
            if state then Features.stats.start() else Features.stats.stop() end
        end,
    })

    ui.toggle(visuals, "fullbright", {
        Title = "Brightness",
        Description = "brightens the whole map",
        Default = false,
        Callback = function(state)
            Features.fullbright.set(state)
        end,
    })

    -- server -------------------------------------------------------------
    ui.paragraph(server, {
        Title = "server",
        Content = "jump between servers without leaving the game.",
    })

    ui.button(server, {
        Title = "Server hop",
        Description = "moves you to a random open server",
        Callback = function()
            local ok, err = serverHop()
            ui.notify({
                Title = ok and "hopping" or "hop failed",
                Content = ok and "teleporting" or tostring(err),
                Duration = 4,
            })
        end,
    })

    ui.button(server, {
        Title = "Rejoin",
        Callback = rejoin,
    })

    ui.paragraph(server, {
        Title = "session",
        Content = string.format("job id: %s\nplayers: %d/%d",
            tostring(game.JobId), #Players:GetPlayers(), Players.MaxPlayers),
    })

    -- settings -----------------------------------------------------------
    if ui.saveManager then
        pcall(function()
            ui.saveManager:SetLibrary(ui.library)
        end)
        pcall(function()
            ui.saveManager:SetFolder("FitzHub")
        end)
        pcall(function()
            ui.saveManager:BuildConfigSection(settings)
        end)
        pcall(function()
            ui.saveManager:LoadAutoloadConfig()
        end)
    end

    ui.toggle(settings, "antiAfk", {
        Title = "Anti-AFK",
        Default = true,
        Callback = function(state)
            Features.antiAfk.enabled = state
        end,
    })

    ui.toggle(settings, "remoteLogger", {
        Title = "Advanced logging",
        Description = "developer only, leave this off",
        Default = false,
        Callback = function(state)
            local ok, err = Features.remoteLogger.set(state)
            if not ok then
                ui.notify({ Title = "logging", Content = tostring(err), Duration = 4 })
            end
        end,
    })

    ui.slider(settings, "fpsCap", {
        Title = "FPS cap",
        Default = 120,
        Min = 30,
        Max = 240,
        Rounding = 0,
        Callback = function(value)
            local setfpscapFn = execFn("setfpscap")
            if type(setfpscapFn) == "function" then
                pcall(setfpscapFn, value)
            end
        end,
    })

    -- start loops --------------------------------------------------------
    Features.autoSlap.start()
    Features.slapAura.start()
    Features.autoAbility.start()
    Features.hitbox.start()
    Features.noclip.start()
    Features.infiniteJump.start()
    Features.gloveLock.start()
    Features.esp.start()
    Features.antiAfk.start()
    Features.progression.start()
    Features.soulbank.start()
    Features.antiAfk.enabled = true

    track(LocalPlayer.CharacterAdded:Connect(function()
        task.wait(0.2)
        Features.speed.apply()
        if Features.fly.enabled then Features.fly.start() end
    end))

    return { home = home, combat = combat, gloves = gloves, travels = travels, progress = progress, immunity = immunity, player = player, visuals = visuals, server = server, settings = settings }
end

-- ---------------------------------------------------------------- main

local authorized, authReason = authorize()
if not authorized then
    notify("fitz's hub", "no license")
    print("[fitz] license not accepted. join " .. BUILD.discord .. " for a key.")
    print("[fitz] your userid is " .. tostring(LocalPlayer.UserId))
    return
end

local ui, uiError = createUI(BUILD.uiBackend)
if not ui then
    notify("fitz's hub", "ui failed to load")
    warn("[fitz] " .. tostring(uiError))
    return
end

local tabs
if GAME_ENTRY and GAME_ENTRY.key == "slap" then
    tabs = buildSlap(ui)
else
    tabs = buildUniversal(ui)
end

ui.onUnload = function()
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    Features.autoSlap.enabled = false
    Features.slapAura.enabled = false
    Features.autoAbility.enabled = false
    Features.hitbox.enabled = false
    Features.hitbox.restore()
    Features.esp.enabled = false
    Features.esp.stop()
    Features.fly.enabled = false
    Features.fly.stop()
    Features.noclip.enabled = false
    Features.gloveLock.enabled = false
    Features.antiRagdoll.set(false)
    Features.antiVoid.set(false)
    Features.antiFling.set(false)
    Features.antiSlow.set(false)
    Features.antiKick.set(false)
    Features.soulbank.enabled = false
    Features.stats.stop()
    Features.fullbright.set(false)
    Features.remoteLogger.set(false)
    Features.speed.restore()

    pcall(function()
        local window = ui.window
        if window and window.Destroy then window:Destroy() end
    end)
    local genv = probe(function() return getgenv() end)
    if type(genv) == "table" then
        pcall(function() genv.Fitz = nil end)
    end
end

do
    local genv = probe(function() return getgenv() end)
    if type(genv) == "table" then
        pcall(function()
            genv.Fitz = {
                version = BUILD.version,
                game = GAME_LABEL,
                tabs = tabs,
                unload = function() ui.onUnload() end,
            }
        end)
    end
end

ui.notify({
    Title = "fitz's hub",
    Content = string.format("%s | %s", GAME_LABEL, BUILD.version),
    Duration = 5,
})

print(string.format("[fitz] loaded %s on %s (%d) | auth=%s", BUILD.version, GAME_LABEL, game.PlaceId, tostring(authReason)))
