local function bootstrapCompatibility()
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local fenv = getfenv(1)
    local missing = {}

    local function grab(name)
        for _, source in ipairs({ fenv, genv, _G }) do
            local found, value = pcall(function()
                return source[name]
            end)
            if found and type(value) == "function" then
                return value
            end
        end
        return nil
    end

    local function grabTable(name)
        local found, value = pcall(function()
            return fenv[name] or genv[name]
        end)
        if found and type(value) == "table" then
            return value
        end
        return nil
    end

    local function publish(name, value)
        if not value then
            table.insert(missing, name)
            return
        end
        pcall(function()
            genv[name] = value
        end)
        pcall(function()
            fenv[name] = value
        end)
    end

    local connectionsOf = grab("getconnections") or grab("get_signal_cons")
    publish("getconnections", connectionsOf)
    local writeable = grab("make_writeable")
    local readonly = grab("make_readonly")
    local debugMeta = debug and debug.getmetatable

    publish("getrawmetatable", grab("getrawmetatable") or grab("get_raw_metatable") or debugMeta)

    publish("setreadonly", grab("setreadonly") or grab("set_readonly") or (writeable and readonly and function(target, state)
        if state then
            readonly(target)
        else
            writeable(target)
        end
    end))

    publish("getnamecallmethod", grab("getnamecallmethod") or grab("get_namecall_method"))

    local setIdentity = grab("setthreadidentity") or grab("set_thread_identity")
    local readIdentity = grab("getthreadidentity") or grab("get_thread_identity")

    if setIdentity then
        publish("setthreadidentity", setIdentity)
    end
    if readIdentity then
        publish("getthreadidentity", readIdentity)
    end

    local native = grab("firesignal") or grab("fire_signal")
    local viaConnections = connectionsOf and function(signal, ...)
        for _, connection in ipairs(connectionsOf(signal)) do
            pcall(connection.Fire, connection, ...)
        end
    end

    if native and viaConnections then
        local probe = Instance.new("BindableEvent")
        local landed = false
        probe.Event:Connect(function()
            landed = true
        end)
        pcall(native, probe.Event, true)
        task.wait(0.1)
        probe:Destroy()
        if not landed then
            native = nil
        end
    end

    local fire = native or viaConnections
    publish("firesignal", fire and function(signal, ...)
        if not setIdentity then
            return fire(signal, ...)
        end
        local restore = readIdentity and readIdentity()
        pcall(setIdentity, 2)
        pcall(fire, signal, ...)
        if restore then
            pcall(setIdentity, restore)
        end
    end)

    publish("loadstring", grab("loadstring") or grab("load"))

    local send = grab("request") or grab("http_request")
    if not send then
        local syntax = grabTable("syn") or grabTable("http") or grabTable("fluxus")
        send = syntax and syntax.request
    end

    publish("httpGet", function(url)
        local reached, body = pcall(function()
            return game:HttpGet(url)
        end)
        if reached and type(body) == "string" and #body > 0 then
            return body
        end
        if send then
            local sent, response = pcall(send, { Url = url, Method = "GET" })
            if sent and type(response) == "table" and type(response.Body) == "string" then
                return response.Body
            end
        end
        error("SAGEBAIT: no working HTTP method for " .. tostring(url), 0)
    end)

    local hidden = grab("gethui") or grab("get_hidden_gui")
    local guard = grab("protect_gui")
    if not guard then
        local syntax = grabTable("syn")
        guard = syntax and syntax.protect_gui
    end
    publish("hidegui", function(gui)
        if guard then pcall(guard, gui) end
        if hidden then
            local reached, container = pcall(hidden)
            if reached and typeof(container) == "Instance" then
                gui.Parent = container
                return
            end
        end
        local pulled, core = pcall(game.GetService, game, "CoreGui")
        if pulled and core then
            local placed = pcall(function() gui.Parent = core end)
            if placed then return end
        end
        gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
    end)

    if #missing > 0 then
        warn("SAGEBAIT: this executor has no " .. table.concat(missing, ", ") .. " - features that need them stay off")
    end
end

bootstrapCompatibility()

-- ============================================================================
-- SECTION 1 — RESOURCE REGISTRY
-- One place that tracks every hook, connection, gui, tag and cleanup for THIS run.
-- REGISTRY.runUnload tears it all down in reverse order in one shot.
-- ============================================================================

-- ============================================================================
-- SAGEBAIT central resource registry
-- Every hook, connection, gui, tag and cleanup of THIS run is registered here and
-- torn down in one place (REGISTRY.runUnload), in reverse order of registration.
-- NOTE: exposed as a single top-level local on purpose. The main chunk is at 196 of
-- the 200 local-variable limit (Luau), so the helpers are fields, not extra locals.
-- ============================================================================
local REGISTRY = {
    connections = {},
    hooks = {},        -- array of { mt, key, old, new }; several hooks share "__namecall"
    guis = {},
    tags = {},
    cleanups = {},
    unloading = false, -- set as soon as a teardown starts (re-entrancy guard)
    unloaded = false,  -- set once runUnload has executed
    sessionUnload = nil,
}

function REGISTRY.registerConnection(conn)
    if conn ~= nil then
        local list = REGISTRY.connections
        list[#list + 1] = conn
    end
    return conn
end

-- Connect + register in one step: REGISTRY.bind(signal, fn) == track(signal:Connect(fn))
function REGISTRY.bind(signal, fn)
    return REGISTRY.registerConnection(signal:Connect(fn))
end

-- Saves the current mt[key], installs newFn, remembers mt so unload can restore it.
-- Returns the saved original (what the old code kept in a local `oldNamecall`).
function REGISTRY.registerHook(mt, key, newFn)
    local old = mt[key]
    setreadonly(mt, false)
    mt[key] = newFn
    setreadonly(mt, true)
    local list = REGISTRY.hooks
    list[#list + 1] = { mt = mt, key = key, old = old, new = newFn }
    return old
end

function REGISTRY.registerGui(gui)
    if gui ~= nil then
        local list = REGISTRY.guis
        list[#list + 1] = gui
    end
    return gui
end

function REGISTRY.registerTag(name)
    if name ~= nil then
        local list = REGISTRY.tags
        list[#list + 1] = name
    end
    return name
end

function REGISTRY.registerCleanup(fn)
    if type(fn) == "function" then
        local list = REGISTRY.cleanups
        list[#list + 1] = fn
    end
    return fn
end

-- Disconnect AND drop from both REGISTRY.connections and the public SAGEBAIT_SESSION.links
-- array, so toggling a feature off does not leave a dead connection in either place.
function REGISTRY.disconnect(conn)
    if conn == nil then return end
    pcall(function()
        conn:Disconnect()
    end)
    local list = REGISTRY.connections
    for i = #list, 1, -1 do
        if list[i] == conn then
            table.remove(list, i)
            break
        end
    end
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.SAGEBAIT_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        local links = session.links
        for i = #links, 1, -1 do
            if links[i] == conn then
                table.remove(links, i)
                break
            end
        end
    end
end

function REGISTRY.runUnload()
    if REGISTRY.unloaded then return end
    REGISTRY.unloaded = true
    REGISTRY.unloading = true

    -- 1) feature cleanups, newest first
    for i = #REGISTRY.cleanups, 1, -1 do
        pcall(REGISTRY.cleanups[i])
    end
    REGISTRY.cleanups = {}

    -- 2) hooks, newest first (each one restores the value it replaced -> exact chain unwind)
    for i = #REGISTRY.hooks, 1, -1 do
        local hook = REGISTRY.hooks[i]
        pcall(setreadonly, hook.mt, false)
        pcall(function()
            hook.mt[hook.key] = hook.old
        end)
        pcall(setreadonly, hook.mt, true)
    end
    REGISTRY.hooks = {}

    -- 3) connections, newest first
    for i = #REGISTRY.connections, 1, -1 do
        local conn = REGISTRY.connections[i]
        pcall(function()
            conn:Disconnect()
        end)
    end
    REGISTRY.connections = {}

    -- 4) guis, newest first
    for i = #REGISTRY.guis, 1, -1 do
        local gui = REGISTRY.guis[i]
        pcall(function()
            gui:Destroy()
        end)
    end
    REGISTRY.guis = {}

    -- 5) tagged instances (same sweep the old session.unload did, now fed by REGISTRY.tags)
    pcall(function()
        local tagged = {}
        for _, name in ipairs(REGISTRY.tags) do
            tagged[name] = true
        end
        if not next(tagged) then return end
        local holders = {}
        if type(gethui) == "function" then
            local reached, container = pcall(gethui)
            if reached and container then table.insert(holders, container) end
        end
        table.insert(holders, game:GetService("CoreGui"))
        if workspace.CurrentCamera then
            table.insert(holders, workspace.CurrentCamera)
        end
        local players = game:GetService("Players")
        if players.LocalPlayer then
            local pg = players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
            if pg then table.insert(holders, pg) end
        end
        for _, holder in ipairs(holders) do
            for _, child in ipairs(holder:GetChildren()) do
                if tagged[child.Name] then
                    child:Destroy()
                end
            end
        end
        for _, model in ipairs(workspace:GetChildren()) do
            if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
                for _, child in ipairs(model:GetChildren()) do
                    if tagged[child.Name] then
                        child:Destroy()
                    end
                end
            end
        end
        for _, other in ipairs(players:GetPlayers()) do
            if other.Character then
                for _, child in ipairs(other.Character:GetChildren()) do
                    if tagged[child.Name] then
                        child:Destroy()
                    end
                end
            end
        end
    end)
    REGISTRY.tags = {}
end

-- ============================================================================
-- Central __namecall dispatcher: ONE hook on the game metatable, features register
-- handlers. Handler: fn(self, method, args), args = table.pack(...). Handlers may
-- mutate args and args.n in place, and may return:
--   nil                              -> no interference
--   { replace = true, result = v }   -> terminal: chain stops, v goes back to caller
--   { post = function(result) ... }  -> post-processes the downstream result (may return nil = keep)
-- Entry runs newest installOrder first (what nested hooks used to do).
-- Post runs oldest installOrder first (mirror image of entry).
-- Handlers never call the original __namecall themselves; only the dispatcher does.
-- ============================================================================
local Namecall = { list = {}, orders = {}, seq = 0, installed = false, old = nil }

function Namecall.unwind(posts, r)
    for j = #posts, 1, -1 do
        local out = posts[j](r)
        if out ~= nil then
            r = out
        end
    end
    return r
end

function Namecall.dispatch(self, ...)
    local method = getnamecallmethod()
    local args = table.pack(...)
    local list = Namecall.list
    local posts = {}
    for i = #list, 1, -1 do
        local out = list[i].fn(self, method, args)
        if out then
            if out.post then
                posts[#posts + 1] = out.post
            end
            if out.replace and out.result ~= nil then
                return Namecall.unwind(posts, out.result)
            end
        end
    end
    return Namecall.unwind(posts, Namecall.old(self, table.unpack(args, 1, args.n)))
end

-- installs the single hook once; restored by REGISTRY.runUnload like every other hook
function Namecall.ensure()
    if Namecall.installed then return true end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return false end
    local mt = getrawmetatable(game)
    Namecall.old = REGISTRY.registerHook(mt, "__namecall", Namecall.dispatch)
    Namecall.installed = true
    return true
end

-- ============================================================================
-- SECTION 2 — CENTRAL __NAMECALL DISPATCHER
-- Single hook. Features register/unregister handlers by name. Entry runs newest
-- install order first, post runs oldest first. args.n mutable for handlers that
-- extend the arg list (max_serve).
-- ============================================================================

-- idempotent per name. order = FIRST registration of that name, kept in Namecall.orders
-- even after unregister, so toggling a feature off/on never changes its effect order.
function Namecall.register(name, fn)
    for _, entry in ipairs(Namecall.list) do
        if entry.name == name then return end
    end
    if not Namecall.ensure() then return end
    local order = Namecall.orders[name]
    if not order then
        Namecall.seq = Namecall.seq + 1
        order = Namecall.seq
        Namecall.orders[name] = order
    end
    local list = Namecall.list
    local pos = #list + 1
    for i = 1, #list do
        if list[i].order > order then
            pos = i
            break
        end
    end
    table.insert(list, pos, { name = name, fn = fn, order = order })
end

-- Remove a handler by name. The hook itself stays installed.
function Namecall.unregister(name)
    for i = #Namecall.list, 1, -1 do
        if Namecall.list[i].name == name then
            table.remove(Namecall.list, i)
            return
        end
    end
end

-- ============================================================================
-- SECTION 3 — PUBLIC SESSION
-- SAGEBAIT_SESSION is the cross-run contract. A previous run's unload is called
-- here before this run installs anything, so reloads do not stack.
-- ============================================================================

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local prior = rawget(genv, "SAGEBAIT_SESSION") or genv.SAGEBAIT_SESSION
    local carried = type(prior) == "table" and prior.vault or nil
    if type(prior) == "table" and type(prior.unload) == "function" then
        pcall(prior.unload)
    end
    local mt = getrawmetatable and getrawmetatable(game)
    local pristine = mt and rawget(mt, "__namecall")
    local session = {}
    session.vault = carried
    session.unload = function()
        if REGISTRY.unloading then return end -- re-entrancy guard (Library:Unload <-> session.unload)
        REGISTRY.unloading = true
        if session.vault and session.vault.inventory then
            pcall(function()
                local Knit = require(game:GetService("ReplicatedStorage").Packages.Knit)
                local inventory = Knit.GetController("InventoryController")
                if inventory and inventory.Inventory then
                    inventory.Inventory:set(session.vault.inventory)
                end
            end)
        end
        if session.ui and session.ui.Unload then
            pcall(function()
                session.ui:Unload()
            end)
        end
        for _, link in ipairs(session.links or {}) do
            pcall(function()
                link:Disconnect()
            end)
        end
        -- anything pushed straight into the public session.tags still gets swept
        for _, name in ipairs(session.tags or {}) do
            REGISTRY.registerTag(name)
        end
        REGISTRY.runUnload()
        -- safety net: the pre-session __namecall must be back; force it (and say so) if not
        if mt and pristine and rawget(mt, "__namecall") ~= pristine then
            warn("SAGEBAIT: __namecall was not back to original after runUnload - forcing restore")
            pcall(setreadonly, mt, false)
            mt.__namecall = pristine
            pcall(setreadonly, mt, true)
        end
    end
    REGISTRY.sessionUnload = session.unload
    session.links = {}
    session.tags = {}
    genv.SAGEBAIT_SESSION = session
end

local Library = (function()
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local TweenService = game:GetService("TweenService")
    local GuiService = game:GetService("GuiService")
    local HttpService = game:GetService("HttpService")
    local LocalPlayer = Players.LocalPlayer

    local Theme = {
        Accent = Color3.fromRGB(124, 140, 255),
        AccentSoft = Color3.fromRGB(88, 102, 212),
        Shell = Color3.fromRGB(11, 12, 16),
        ShellTop = Color3.fromRGB(22, 24, 32),
        Panel = Color3.fromRGB(16, 18, 24),
        Raised = Color3.fromRGB(25, 28, 36),
        Sunken = Color3.fromRGB(13, 14, 19),
        Line = Color3.fromRGB(48, 52, 66),
        LineSoft = Color3.fromRGB(33, 36, 46),
        Text = Color3.fromRGB(238, 240, 248),
        SubText = Color3.fromRGB(146, 153, 172),
        Faint = Color3.fromRGB(92, 98, 116),
    }

    local PILL = UDim.new(1, 0)
    local EASE = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

    local Lib = {
        Options = {},
        Toggles = {},
        Theme = Theme,
        CornerRadius = 12,
        ForceCheckbox = false,
        ShowToggleFrameInKeybinds = true,
        NotifySide = "Right",
        Unloaded = false,
        ToggleKeybind = nil,
        DefaultToggleKey = "RightShift",
    }

    local conns = {}
    local panels = {}
    local pickers = {}
    local pages = {}
    local configFolder = "SAGEBAIT"

    local function new(class, props, parent)
        local inst = Instance.new(class)
        for key, value in pairs(props) do
            inst[key] = value
        end
        if parent then
            inst.Parent = parent
        end
        return inst
    end

    local function round(inst, radius, tracked)
        local corner = new("UICorner", { CornerRadius = radius }, inst)
        if tracked then
            table.insert(panels, corner)
        end
        return corner
    end

    local function outline(inst, color, thickness, transparency)
        return new("UIStroke", {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            LineJoinMode = Enum.LineJoinMode.Round,
            Color = color or Theme.Line,
            Thickness = thickness or 1,
            Transparency = transparency or 0,
        }, inst)
    end

    local function pad(inst, left, right, top, bottom)
        return new("UIPadding", {
            PaddingLeft = UDim.new(0, left or 0),
            PaddingRight = UDim.new(0, right or 0),
            PaddingTop = UDim.new(0, top or 0),
            PaddingBottom = UDim.new(0, bottom or 0),
        }, inst)
    end

    local function stack(inst, gap, dir)
        return new("UIListLayout", {
            FillDirection = dir or Enum.FillDirection.Vertical,
            SortOrder = Enum.SortOrder.LayoutOrder,
            Padding = UDim.new(0, gap or 0),
        }, inst)
    end

    local function glide(inst, props, speed)
        local anim = TweenService:Create(inst, speed and TweenInfo.new(speed, Enum.EasingStyle.Quart, Enum.EasingDirection.Out) or EASE, props)
        anim:Play()
        return anim
    end

    local function bind(signal, fn)
        local link = signal:Connect(fn)
        table.insert(conns, link)
        return link
    end

    local function tag()
        return string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
    end

    local Root = new("ScreenGui", {
        Name = tag(),
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        AutoLocalize = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 9999,
    })

    do
        local placed = false
        if type(hidegui) == "function" then
            placed = pcall(hidegui, Root)
        end
        if not placed or not Root.Parent then
            Root.Parent = LocalPlayer:WaitForChild("PlayerGui")
        end
        REGISTRY.registerGui(Root)
        pcall(function()
            UserInputService.MouseIconEnabled = true
        end)
    end

    local TipCard = new("Frame", {
        BackgroundColor3 = Theme.Raised,
        BorderSizePixel = 0,
        AutomaticSize = Enum.AutomaticSize.XY,
        Size = UDim2.fromOffset(0, 0),
        Visible = false,
        ZIndex = 190,
    }, Root)
    round(TipCard, UDim.new(0, 8))
    outline(TipCard, Theme.Line, 1)
    pad(TipCard, 10, 10, 7, 7)

    local TipText = new("TextLabel", {
        BackgroundTransparency = 1,
        AutomaticSize = Enum.AutomaticSize.XY,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "",
        ZIndex = 191,
    }, TipCard)

    local NotifyHolder = new("Frame", {
        AnchorPoint = Vector2.new(1, 0),
        Position = UDim2.new(1, -18, 0, 18),
        Size = UDim2.fromOffset(280, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        ZIndex = 180,
    }, Root)
    stack(NotifyHolder, 8)

    local KeybindFrame = new("Frame", {
        Position = UDim2.fromOffset(24, 120),
        Size = UDim2.fromOffset(190, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundColor3 = Theme.Panel,
        BorderSizePixel = 0,
        Visible = false,
        ZIndex = 60,
    }, Root)
    round(KeybindFrame, UDim.new(0, Lib.CornerRadius), true)
    outline(KeybindFrame, Theme.LineSoft, 1)
    pad(KeybindFrame, 12, 12, 10, 12)
    stack(KeybindFrame, 6)

    new("TextLabel", {
        Size = UDim2.new(1, 0, 0, 16),
        BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextColor3 = Theme.Text,
        TextXAlignment = Enum.TextXAlignment.Left,
        Text = "Keybinds",
        LayoutOrder = 0,
        ZIndex = 61,
    }, KeybindFrame)

    local KeybindList = new("Frame", {
        Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y,
        BackgroundTransparency = 1,
        LayoutOrder = 1,
        ZIndex = 61,
    }, KeybindFrame)
    stack(KeybindList, 4)

    Lib.KeybindFrame = KeybindFrame
    Lib.Root = Root

    local function pointer()
        return UserInputService:GetMouseLocation() + Vector2.new(0, GuiService:GetGuiInset().Y)
    end

    local function attachTip(frame, text)
        if not text or text == "" then
            return
        end
        bind(frame.MouseEnter, function()
            TipText.Text = text
            local at = pointer()
            TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            TipCard.Visible = true
        end)
        bind(frame.MouseMoved, function()
            if TipCard.Visible then
                local at = pointer()
                TipCard.Position = UDim2.fromOffset(at.X + 16, at.Y + 18)
            end
        end)
        bind(frame.MouseLeave, function()
            TipCard.Visible = false
        end)
    end

    function Lib:Notify(payload, seconds)
        local text = payload
        if type(payload) == "table" then
            text = payload.Description or payload.Title or payload.Text or ""
            seconds = seconds or payload.Time
        end

        local card = new("Frame", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            BackgroundTransparency = 1,
            ZIndex = 181,
        }, NotifyHolder)
        round(card, UDim.new(0, 10))
        local edge = outline(card, Theme.Line, 1, 1)
        pad(card, 12, 12, 10, 10)

        local body = new("TextLabel", {
            Size = UDim2.new(1, 0, 0, 0),
            AutomaticSize = Enum.AutomaticSize.Y,
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 12,
            TextColor3 = Theme.Text,
            TextTransparency = 1,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextWrapped = true,
            Text = tostring(text),
            ZIndex = 182,
        }, card)

        glide(card, { BackgroundTransparency = 0 })
        glide(edge, { Transparency = 0 })
        glide(body, { TextTransparency = 0 })

        task.delay(seconds or 4, function()
            if not card.Parent then
                return
            end
            glide(card, { BackgroundTransparency = 1 })
            glide(edge, { Transparency = 1 })
            glide(body, { TextTransparency = 1 })
            task.wait(0.24)
            card:Destroy()
        end)
    end

    function Lib:SetNotifySide(side)
        Lib.NotifySide = side
        if side == "Left" then
            NotifyHolder.AnchorPoint = Vector2.new(0, 0)
            NotifyHolder.Position = UDim2.new(0, 18, 0, 18)
        else
            NotifyHolder.AnchorPoint = Vector2.new(1, 0)
            NotifyHolder.Position = UDim2.new(1, -18, 0, 18)
        end
    end

    local function refreshKeybindList()
        for _, child in ipairs(KeybindList:GetChildren()) do
            if child:IsA("Frame") then
                child:Destroy()
            end
        end
        local order = 0
        for _, picker in ipairs(pickers) do
            if not picker.NoUI and picker.Value and picker.Value ~= "" then
                order = order + 1
                local row = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundTransparency = 1,
                    LayoutOrder = order,
                    ZIndex = 62,
                }, KeybindList)
                new("TextLabel", {
                    Size = UDim2.new(1, -54, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamMedium,
                    TextSize = 11,
                    TextColor3 = Theme.SubText,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Label,
                    ZIndex = 62,
                }, row)
                local chip = new("Frame", {
                    AnchorPoint = Vector2.new(1, 0.5),
                    Position = UDim2.new(1, 0, 0.5, 0),
                    Size = UDim2.fromOffset(52, 18),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    ZIndex = 62,
                }, row)
                round(chip, PILL)
                outline(chip, Theme.Line, 1)
                new("TextLabel", {
                    Size = UDim2.fromScale(1, 1),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 10,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = picker.Value,
                    ZIndex = 63,
                }, chip)
            end
        end
    end

    local function dragify(handle, target)
        local holding, origin, base = false, nil, nil
        bind(handle.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = true
                origin = input.Position
                base = target.Position
            end
        end)
        bind(handle.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                holding = false
            end
        end)
        bind(UserInputService.InputChanged, function(input)
            if not holding then
                return
            end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local shift = input.Position - origin
                target.Position = UDim2.new(base.X.Scale, base.X.Offset + shift.X, base.Y.Scale, base.Y.Offset + shift.Y)
            end
        end)
    end

    dragify(KeybindFrame, KeybindFrame)

    local function makeGroup(holder)
        local Group = { Holder = holder, Order = 0 }

        local function slot(height, auto)
            Group.Order = Group.Order + 1
            local frame = new("Frame", {
                Size = UDim2.new(1, 0, 0, height or 0),
                BackgroundTransparency = 1,
                LayoutOrder = Group.Order,
            }, holder)
            if auto then
                frame.AutomaticSize = Enum.AutomaticSize.Y
            end
            return frame
        end

        local function caption(parent, text)
            return new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 15),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = text,
                LayoutOrder = 0,
            }, parent)
        end

        function Group:AddToggle(index, opts)
            opts = opts or {}
            local row = slot(30)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -54, 1, 0),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, row)

            local box = Lib.ForceCheckbox
            local track = new("Frame", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, 0, 0.5, 0),
                Size = box and UDim2.fromOffset(21, 21) or UDim2.fromOffset(42, 22),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
            }, row)
            round(track, box and UDim.new(0, 6) or PILL)
            local edge = outline(track, Theme.Line, 1)

            local knob = new("Frame", {
                Position = box and UDim2.fromOffset(5, 5) or UDim2.fromOffset(3, 3),
                Size = box and UDim2.fromOffset(11, 11) or UDim2.fromOffset(16, 16),
                BackgroundColor3 = Theme.Faint,
                BorderSizePixel = 0,
            }, track)
            round(knob, box and UDim.new(0, 3) or PILL)
            if not box then
                outline(knob, Theme.Line, 1)
            end

            local hit = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Text = "",
                AutoButtonColor = false,
            }, row)
            attachTip(hit, opts.Tooltip)

            local Toggle = { Value = false, Type = "Toggle", Index = index, Callbacks = {} }

            local function paint()
                if Toggle.Value then
                    glide(track, { BackgroundColor3 = Theme.AccentSoft })
                    glide(edge, { Color = Theme.Accent })
                    glide(knob, { BackgroundColor3 = Theme.Text })
                    glide(label, { TextColor3 = Theme.Text })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(23, 3) })
                    end
                else
                    glide(track, { BackgroundColor3 = Theme.Sunken })
                    glide(edge, { Color = Theme.Line })
                    glide(knob, { BackgroundColor3 = Theme.Faint })
                    glide(label, { TextColor3 = Theme.SubText })
                    if not box then
                        glide(knob, { Position = UDim2.fromOffset(3, 3) })
                    end
                end
            end

            function Toggle:SetValue(value, silent)
                Toggle.Value = value and true or false
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, Toggle.Value)
                end
                for _, fn in ipairs(Toggle.Callbacks) do
                    task.spawn(fn, Toggle.Value)
                end
            end

            function Toggle:OnChanged(fn)
                table.insert(Toggle.Callbacks, fn)
                task.spawn(fn, Toggle.Value)
                return Toggle
            end

            bind(hit.MouseButton1Click, function()
                Toggle:SetValue(not Toggle.Value)
            end)

            Toggle:SetValue(opts.Default and true or false, true)
            if opts.Default then
                if opts.Callback then
                    task.spawn(opts.Callback, true)
                end
            end

            Lib.Toggles[index] = Toggle
            return Toggle
        end

        function Group:AddSlider(index, opts)
            opts = opts or {}
            local wrap = slot(44)
            attachTip(wrap, opts.Tooltip)

            local label = new("TextLabel", {
                Size = UDim2.new(1, -70, 0, 16),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = opts.Text or index,
            }, wrap)

            local readout = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0),
                Position = UDim2.new(1, 0, 0, 0),
                Size = UDim2.fromOffset(70, 16),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Theme.Accent,
                TextXAlignment = Enum.TextXAlignment.Right,
                Text = "0",
            }, wrap)

            local track = new("Frame", {
                Position = UDim2.new(0, 0, 0, 26),
                Size = UDim2.new(1, 0, 0, 10),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
            }, wrap)
            round(track, PILL)
            outline(track, Theme.Line, 1)

            local fill = new("Frame", {
                Size = UDim2.new(0, 0, 1, 0),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
            }, track)
            round(fill, PILL)

            local knob = new("Frame", {
                AnchorPoint = Vector2.new(0.5, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.fromOffset(14, 14),
                BackgroundColor3 = Theme.Text,
                BorderSizePixel = 0,
                ZIndex = 3,
            }, track)
            round(knob, PILL)
            outline(knob, Theme.Accent, 1)

            local minimum = opts.Min or 0
            local maximum = opts.Max or 100
            local digits = opts.Rounding or 0
            local step = 10 ^ digits

            local Slider = { Value = opts.Default or minimum, Type = "Slider", Index = index, Min = minimum, Max = maximum, Callbacks = {} }

            local function paint()
                local span = maximum - minimum
                local ratio = span > 0 and math.clamp((Slider.Value - minimum) / span, 0, 1) or 0
                fill.Size = UDim2.new(ratio, 0, 1, 0)
                knob.Position = UDim2.new(ratio, 0, 0.5, 0)
                readout.Text = tostring(Slider.Value) .. (opts.Suffix or "")
            end

            function Slider:SetValue(value, silent)
                value = tonumber(value) or minimum
                value = math.clamp(value, minimum, maximum)
                value = math.floor(value * step + 0.5) / step
                Slider.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Slider.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Slider:OnChanged(fn)
                table.insert(Slider.Callbacks, fn)
                task.spawn(fn, Slider.Value)
                return Slider
            end

            local sliding = false

            local function seek(x)
                local width = track.AbsoluteSize.X
                if width <= 0 then
                    return
                end
                local ratio = math.clamp((x - track.AbsolutePosition.X) / width, 0, 1)
                Slider:SetValue(minimum + (maximum - minimum) * ratio)
            end

            bind(track.InputBegan, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    sliding = true
                    glide(knob, { Size = UDim2.fromOffset(18, 18) })
                    seek(input.Position.X)
                end
            end)
            bind(UserInputService.InputEnded, function(input)
                if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                    if sliding then
                        sliding = false
                        glide(knob, { Size = UDim2.fromOffset(14, 14) })
                    end
                end
            end)
            bind(UserInputService.InputChanged, function(input)
                if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
                    seek(input.Position.X)
                end
            end)

            Slider:SetValue(opts.Default or minimum, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, Slider.Value)
            end

            Lib.Options[index] = Slider
            return Slider
        end

        function Group:AddDropdown(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 30),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.Text,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = 1,
            }, wrap)
            round(button, PILL)
            local edge = outline(button, Theme.Line, 1)
            pad(button, 14, 30, 0, 0)

            local arrow = new("TextLabel", {
                AnchorPoint = Vector2.new(1, 0.5),
                Position = UDim2.new(1, -12, 0.5, 0),
                Size = UDim2.fromOffset(12, 12),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Theme.Faint,
                Text = ">",
                Rotation = 90,
            }, button)

            local panel = new("Frame", {
                Size = UDim2.new(1, 0, 0, 0),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Visible = false,
                LayoutOrder = 2,
                ClipsDescendants = true,
            }, wrap)
            round(panel, UDim.new(0, 10))
            outline(panel, Theme.Line, 1)

            local scroll = new("ScrollingFrame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, panel)
            stack(scroll, 3)
            pad(scroll, 5, 7, 5, 5)

            local Dropdown = { Value = nil, Type = "Dropdown", Index = index, Values = opts.Values or {}, Callbacks = {}, Open = false }
            local rows = {}

            local function paint()
                button.Text = tostring(Dropdown.Value or "--")
                for value, row in pairs(rows) do
                    if value == Dropdown.Value then
                        glide(row.Frame, { BackgroundColor3 = Theme.AccentSoft })
                        glide(row.Edge, { Transparency = 0, Color = Theme.Accent })
                        glide(row.Label, { TextColor3 = Theme.Text })
                    else
                        glide(row.Frame, { BackgroundColor3 = Theme.Raised })
                        glide(row.Edge, { Transparency = 1, Color = Theme.Line })
                        glide(row.Label, { TextColor3 = Theme.SubText })
                    end
                end
            end

            function Dropdown:SetValue(value, silent)
                Dropdown.Value = value
                paint()
                if silent then
                    return
                end
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Dropdown.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Dropdown:OnChanged(fn)
                table.insert(Dropdown.Callbacks, fn)
                task.spawn(fn, Dropdown.Value)
                return Dropdown
            end

            local function collapse()
                Dropdown.Open = false
                panel.Visible = false
                panel.Size = UDim2.new(1, 0, 0, 0)
                glide(arrow, { Rotation = 90 })
                glide(edge, { Color = Theme.Line })
            end

            function Dropdown:SetValues(values)
                Dropdown.Values = values or {}
                rows = {}
                for _, child in ipairs(scroll:GetChildren()) do
                    if child:IsA("TextButton") then
                        child:Destroy()
                    end
                end
                for order, value in ipairs(Dropdown.Values) do
                    local entry = new("TextButton", {
                        Size = UDim2.new(1, 0, 0, 26),
                        BackgroundColor3 = Theme.Raised,
                        BorderSizePixel = 0,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 12,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = "",
                        AutoButtonColor = false,
                        LayoutOrder = order,
                    }, scroll)
                    round(entry, PILL)
                    local entryEdge = outline(entry, Theme.Line, 1, 1)
                    local entryLabel = new("TextLabel", {
                        Size = UDim2.new(1, -24, 1, 0),
                        Position = UDim2.fromOffset(12, 0),
                        BackgroundTransparency = 1,
                        Font = Enum.Font.GothamMedium,
                        TextSize = 12,
                        TextColor3 = Theme.SubText,
                        TextXAlignment = Enum.TextXAlignment.Left,
                        TextTruncate = Enum.TextTruncate.AtEnd,
                        Text = tostring(value),
                    }, entry)
                    rows[value] = { Frame = entry, Edge = entryEdge, Label = entryLabel }
                    bind(entry.MouseButton1Click, function()
                        Dropdown:SetValue(value)
                        collapse()
                    end)
                end
                paint()
            end

            bind(button.MouseButton1Click, function()
                Dropdown.Open = not Dropdown.Open
                if Dropdown.Open then
                    local height = math.clamp(#Dropdown.Values * 29 + 10, 36, 168)
                    panel.Visible = true
                    panel.Size = UDim2.new(1, 0, 0, 0)
                    glide(panel, { Size = UDim2.new(1, 0, 0, height) })
                    glide(arrow, { Rotation = 270 })
                    glide(edge, { Color = Theme.Accent })
                else
                    collapse()
                end
            end)

            Dropdown:SetValues(opts.Values or {})
            Dropdown:SetValue(opts.Default, true)
            if opts.Default ~= nil and opts.Callback then
                task.spawn(opts.Callback, opts.Default)
            end

            Lib.Options[index] = Dropdown
            return Dropdown
        end

        function Group:AddInput(index, opts)
            opts = opts or {}
            local wrap = slot(0, true)
            stack(wrap, 6)
            attachTip(wrap, opts.Tooltip)

            caption(wrap, opts.Text or index)

            local field = new("TextBox", {
                Size = UDim2.new(1, 0, 0, 30),
                BackgroundColor3 = Theme.Sunken,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.Text,
                PlaceholderColor3 = Theme.Faint,
                PlaceholderText = opts.Placeholder or "",
                TextXAlignment = Enum.TextXAlignment.Left,
                ClearTextOnFocus = false,
                Text = opts.Default or "",
                LayoutOrder = 1,
            }, wrap)
            round(field, PILL)
            local edge = outline(field, Theme.Line, 1)
            pad(field, 14, 14, 0, 0)

            local Input = { Value = opts.Default or "", Type = "Input", Index = index, Callbacks = {} }

            local function push(value)
                Input.Value = value
                if opts.Callback then
                    task.spawn(opts.Callback, value)
                end
                for _, fn in ipairs(Input.Callbacks) do
                    task.spawn(fn, value)
                end
            end

            function Input:SetValue(value, silent)
                value = tostring(value or "")
                field.Text = value
                if silent then
                    Input.Value = value
                    return
                end
                push(value)
            end

            function Input:OnChanged(fn)
                table.insert(Input.Callbacks, fn)
                task.spawn(fn, Input.Value)
                return Input
            end

            bind(field.Focused, function()
                glide(edge, { Color = Theme.Accent })
            end)

            bind(field.FocusLost, function()
                glide(edge, { Color = Theme.Line })
                local value = field.Text
                if opts.Numeric and value ~= "" and not tonumber(value) then
                    field.Text = Input.Value
                    return
                end
                push(value)
            end)

            if not opts.Finished then
                bind(field:GetPropertyChangedSignal("Text"), function()
                    if field:IsFocused() then
                        local value = field.Text
                        if opts.Numeric and value ~= "" and not tonumber(value) then
                            return
                        end
                        push(value)
                    end
                end)
            end

            Lib.Options[index] = Input
            return Input
        end

        function Group:AddButton(a, b)
            local text, action
            if type(a) == "table" then
                text = a.Text
                action = a.Func or a.Callback
            else
                text = a
                action = b
            end

            local wrap = slot(32)
            local button = new("TextButton", {
                Size = UDim2.fromScale(1, 1),
                BackgroundColor3 = Theme.Raised,
                BorderSizePixel = 0,
                Font = Enum.Font.GothamBold,
                TextSize = 12,
                TextColor3 = Theme.Text,
                Text = text or "Button",
                AutoButtonColor = false,
            }, wrap)
            round(button, PILL)
            local edge = outline(button, Theme.Line, 1)

            bind(button.MouseEnter, function()
                glide(button, { BackgroundColor3 = Theme.AccentSoft })
                glide(edge, { Color = Theme.Accent })
            end)
            bind(button.MouseLeave, function()
                glide(button, { BackgroundColor3 = Theme.Raised })
                glide(edge, { Color = Theme.Line })
            end)
            bind(button.MouseButton1Click, function()
                glide(button, { BackgroundColor3 = Theme.Accent }, 0.08)
                task.delay(0.1, function()
                    glide(button, { BackgroundColor3 = Theme.Raised })
                end)
                if action then
                    task.spawn(action)
                end
            end)

            local Button = { Instance = button }
            function Button:SetText(value)
                button.Text = value
            end
            return Button
        end

        function Group:AddDivider()
            local wrap = slot(9)
            local line = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 0, 0.5, 0),
                Size = UDim2.new(1, 0, 0, 1),
                BackgroundColor3 = Theme.LineSoft,
                BorderSizePixel = 0,
            }, wrap)
            round(line, PILL)
            return { Instance = line }
        end

        function Group:AddLabel(text, wrapped)
            local wrap = slot(0, true)

            local label = new("TextLabel", {
                Size = UDim2.new(1, 0, 0, 0),
                AutomaticSize = Enum.AutomaticSize.Y,
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextWrapped = wrapped and true or false,
                Text = text or "",
            }, wrap)

            local Label = { Instance = label }

            function Label:SetText(value)
                label.Text = value
                return Label
            end

            function Label:AddKeyPicker(index, opts)
                opts = opts or {}
                label.Size = UDim2.new(1, -66, 0, 0)

                local chip = new("TextButton", {
                    AnchorPoint = Vector2.new(1, 0),
                    Position = UDim2.new(1, 0, 0, 0),
                    Size = UDim2.fromOffset(62, 22),
                    BackgroundColor3 = Theme.Sunken,
                    BorderSizePixel = 0,
                    Font = Enum.Font.GothamBold,
                    TextSize = 11,
                    TextColor3 = Theme.Accent,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = "",
                    AutoButtonColor = false,
                }, wrap)
                round(chip, PILL)
                local edge = outline(chip, Theme.Line, 1)

                local Picker = {
                    Value = opts.Default or "",
                    Mode = opts.Mode or "Toggle",
                    Type = "KeyPicker",
                    Index = index,
                    Label = opts.Text or text or index,
                    NoUI = opts.NoUI and true or false,
                    Active = false,
                    Callbacks = {},
                    Listening = false,
                }

                local function paint()
                    chip.Text = Picker.Listening and "..." or (Picker.Value ~= "" and Picker.Value or "None")
                    glide(edge, { Color = Picker.Listening and Theme.Accent or Theme.Line })
                end

                function Picker:SetValue(value, silent)
                    if type(value) == "table" then
                        Picker.Mode = value[2] or Picker.Mode
                        value = value[1]
                    end
                    Picker.Value = tostring(value or "")
                    paint()
                    refreshKeybindList()
                    if not silent then
                        for _, fn in ipairs(Picker.Callbacks) do
                            task.spawn(fn, Picker.Value)
                        end
                    end
                end

                function Picker:OnChanged(fn)
                    table.insert(Picker.Callbacks, fn)
                    return Picker
                end

                function Picker:GetState()
                    return Picker.Active
                end

                bind(chip.MouseButton1Click, function()
                    Picker.Listening = true
                    paint()
                end)

                bind(UserInputService.InputBegan, function(input, processed)
                    if Picker.Listening then
                        if input.UserInputType == Enum.UserInputType.Keyboard then
                            Picker.Listening = false
                            if input.KeyCode == Enum.KeyCode.Backspace then
                                Picker:SetValue("")
                            else
                                Picker:SetValue(input.KeyCode.Name)
                            end
                        end
                        return
                    end
                    if processed or Picker.Value == "" then
                        return
                    end
                    if UserInputService:GetFocusedTextBox() then
                        return
                    end
                    if input.UserInputType ~= Enum.UserInputType.Keyboard then
                        return
                    end
                    if input.KeyCode.Name ~= Picker.Value then
                        return
                    end
                    if Picker.Mode == "Toggle" then
                        Picker.Active = not Picker.Active
                    else
                        Picker.Active = true
                    end
                    if opts.Callback then
                        task.spawn(opts.Callback, Picker.Active)
                    end
                end)

                bind(UserInputService.InputEnded, function(input)
                    if Picker.Mode == "Hold" and input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode.Name == Picker.Value then
                        Picker.Active = false
                        if opts.Callback then
                            task.spawn(opts.Callback, false)
                        end
                    end
                end)

                table.insert(pickers, Picker)
                Picker:SetValue(opts.Default or "", true)
                Lib.Options[index] = Picker
                return Picker
            end

            return Label
        end

        return Group
    end

    local Shell, Scale, TabRail, PageHolder, ActiveTab

    function Lib:CreateWindow(config)
        config = config or {}

        Shell = new("Frame", {
            Name = tag(),
            AnchorPoint = Vector2.new(0.5, 0.5),
            Position = UDim2.fromScale(0.5, 0.5),
            Size = UDim2.fromOffset(724, 516),
            BackgroundColor3 = Theme.Shell,
            BorderSizePixel = 0,
            ClipsDescendants = true,
            Visible = false,
        }, Root)
        round(Shell, UDim.new(0, Lib.CornerRadius), true)
        outline(Shell, Theme.Line, 1)
        Scale = new("UIScale", { Scale = 1 }, Shell)

        local function refit()
            if not Scale then return end
            local view = Root.AbsoluteSize
            if view.X < 1 or view.Y < 1 then
                local camera = workspace.CurrentCamera
                view = camera and camera.ViewportSize or Vector2.new(1280, 720)
            end
            local fit = math.min(1, (view.X - 24) / 724, (view.Y - 24) / 516)
            Scale.Scale = math.clamp(math.min(Lib.DPI or 1, fit), 0.35, 2)
        end
        Lib.Refit = refit
        bind(Root:GetPropertyChangedSignal("AbsoluteSize"), refit)
        task.defer(refit)
        new("UIGradient", {
            Rotation = 90,
            Color = ColorSequence.new(Theme.ShellTop, Theme.Shell),
        }, Shell)

        local top = new("Frame", {
            Size = UDim2.new(1, 0, 0, 56),
            BackgroundTransparency = 1,
        }, Shell)
        dragify(top, Shell)

        local logo = new("ImageLabel", {
            Position = UDim2.fromOffset(18, 15),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            ScaleType = Enum.ScaleType.Fit,
            Image = config.Icon and ("rbxassetid://" .. tostring(config.Icon)) or "",
        }, top)
        round(logo, PILL)
        outline(logo, Theme.Line, 1)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 14),
            Size = UDim2.fromOffset(240, 16),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 15,
            TextColor3 = Theme.Text,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Title or "Menu",
        }, top)

        new("TextLabel", {
            Position = UDim2.fromOffset(54, 31),
            Size = UDim2.fromOffset(300, 14),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamMedium,
            TextSize = 11,
            TextColor3 = Theme.Faint,
            TextXAlignment = Enum.TextXAlignment.Left,
            Text = config.Footer or "",
        }, top)

        local setMinimized
        local hideButton = new("TextButton", {
            AnchorPoint = Vector2.new(1, 0.5),
            Position = UDim2.new(1, -18, 0.5, 0),
            Size = UDim2.fromOffset(26, 26),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Font = Enum.Font.GothamBold,
            TextSize = 12,
            TextColor3 = Theme.SubText,
            Text = "X",
            AutoButtonColor = false,
        }, top)
        round(hideButton, PILL)
        local hideEdge = outline(hideButton, Theme.Line, 1)
        bind(hideButton.MouseEnter, function()
            glide(hideButton, { BackgroundColor3 = Theme.AccentSoft })
            glide(hideEdge, { Color = Theme.Accent })
        end)
        bind(hideButton.MouseLeave, function()
            glide(hideButton, { BackgroundColor3 = Theme.Raised })
            glide(hideEdge, { Color = Theme.Line })
        end)
        bind(hideButton.MouseButton1Click, function()
            setMinimized(true)
        end)

        new("Frame", {
            Position = UDim2.fromOffset(0, 56),
            Size = UDim2.new(1, 0, 0, 1),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, Shell)

        TabRail = new("ScrollingFrame", {
            Position = UDim2.fromOffset(0, 57),
            Size = UDim2.new(0, 170, 1, -57),
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            CanvasSize = UDim2.new(),
            AutomaticCanvasSize = Enum.AutomaticSize.Y,
            ScrollBarThickness = 0,
            ScrollingDirection = Enum.ScrollingDirection.Y,
        }, Shell)
        stack(TabRail, 6)
        pad(TabRail, 14, 14, 14, 14)

        local railEdge = new("Frame", {
            Position = UDim2.fromOffset(170, 57),
            Size = UDim2.new(0, 1, 1, -57),
            BackgroundColor3 = Theme.LineSoft,
            BorderSizePixel = 0,
        }, Shell)

        PageHolder = new("Frame", {
            Position = UDim2.fromOffset(171, 57),
            Size = UDim2.new(1, -171, 1, -57),
            BackgroundTransparency = 1,
        }, Shell)

        local minimized = false
        local fullSize = Shell.Size

        -- bolinha flutuante: aparece quando minimizado, arrastável, clique restaura
        local orb = new("TextButton", {
            Name = tag(),
            AnchorPoint = Vector2.new(1, 1),
            Position = UDim2.new(1, -22, 1, -22),
            Size = UDim2.fromOffset(52, 52),
            BackgroundColor3 = Theme.Raised,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Active = true,
            Visible = false,
            ZIndex = 250,
        }, Root)
        round(orb, PILL)
        outline(orb, Theme.Accent, 1.5, 0.3)
        local orbScale = new("UIScale", { Scale = 1 }, orb)
        new("TextLabel", {
            Size = UDim2.fromScale(1, 1),
            BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold,
            TextSize = 20,
            TextColor3 = Theme.Text,
            Text = string.sub(config.Title or "S", 1, 1),
            ZIndex = 251,
        }, orb)

        -- drag da bolinha: o fim do drag é global, porque InputEnded do botão só dispara se o cursor ainda estiver em cima dele
        local orbDragging, orbDragStart, orbCorner, orbMoved = false, nil, nil, false
        bind(orb.InputBegan, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                orbDragging = true
                orbMoved = false
                orbDragStart = input.Position
                orbCorner = orb.AbsolutePosition + orb.AbsoluteSize
            end
        end)
        bind(UserInputService.InputEnded, function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                orbDragging = false
            end
        end)
        bind(UserInputService.InputChanged, function(input)
            if not orbDragging then
                return
            end
            if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
                local shift = input.Position - orbDragStart
                if math.abs(shift.X) + math.abs(shift.Y) > 4 then
                    orbMoved = true
                end
                -- Root.AbsoluteSize pode vir zerado; sem fallback o clamp joga a bolinha pro canto
                local view = Root.AbsoluteSize
                if view.X < 1 or view.Y < 1 then
                    local camera = workspace.CurrentCamera
                    view = camera and camera.ViewportSize or Vector2.new(1280, 720)
                end
                local size = orb.AbsoluteSize
                -- canto inferior direito da bolinha, clampado manualmente pra ficar dentro da tela
                local x = math.min(math.max(orbCorner.X + shift.X, size.X), view.X)
                local y = math.min(math.max(orbCorner.Y + shift.Y, size.Y), view.Y)
                orb.Position = UDim2.fromOffset(x, y)
            end
        end)
        bind(orb.MouseButton1Click, function()
            if orbMoved then
                return
            end
            setMinimized(false)
        end)

        setMinimized = function(state)
            minimized = state and true or false
            if minimized then
                Shell.Visible = false
                orb.Visible = true
                orbScale.Scale = 0.7
                glide(orbScale, { Scale = 1 }, 0.24)
            else
                orb.Visible = false
                Shell.Size = fullSize
                Shell.Visible = true
            end
        end

        local Window = { Instance = Shell }

        function Window:SetMinimized(state)
            setMinimized(state)
        end

        function Window:IsMinimized()
            return minimized
        end

        function Window:AddTab(name)
            local button = new("TextButton", {
                Size = UDim2.new(1, 0, 0, 34),
                BackgroundColor3 = Theme.Panel,
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                Text = "",
                AutoButtonColor = false,
                LayoutOrder = #pages + 1,
            }, TabRail)
            round(button, PILL)
            local edge = outline(button, Theme.Line, 1, 1)

            local mark = new("Frame", {
                AnchorPoint = Vector2.new(0, 0.5),
                Position = UDim2.new(0, 11, 0.5, 0),
                Size = UDim2.fromOffset(3, 0),
                BackgroundColor3 = Theme.Accent,
                BorderSizePixel = 0,
            }, button)
            round(mark, PILL)

            local label = new("TextLabel", {
                Position = UDim2.fromOffset(24, 0),
                Size = UDim2.new(1, -34, 1, 0),
                BackgroundTransparency = 1,
                Font = Enum.Font.GothamMedium,
                TextSize = 12,
                TextColor3 = Theme.SubText,
                TextXAlignment = Enum.TextXAlignment.Left,
                TextTruncate = Enum.TextTruncate.AtEnd,
                Text = name,
            }, button)

            local page = new("Frame", {
                Size = UDim2.fromScale(1, 1),
                BackgroundTransparency = 1,
                Visible = false,
            }, PageHolder)
            pad(page, 14, 14, 14, 0)

            local left = new("ScrollingFrame", {
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(left, 12)
            pad(left, 2, 8, 2, 16)

            local right = new("ScrollingFrame", {
                Position = UDim2.new(0.5, 7, 0, 0),
                Size = UDim2.new(0.5, -7, 1, 0),
                BackgroundTransparency = 1,
                BorderSizePixel = 0,
                CanvasSize = UDim2.new(),
                AutomaticCanvasSize = Enum.AutomaticSize.Y,
                ScrollBarThickness = 2,
                ScrollBarImageColor3 = Theme.Line,
                ScrollingDirection = Enum.ScrollingDirection.Y,
            }, page)
            stack(right, 12)
            pad(right, 2, 8, 2, 16)

            local Tab = { Page = page, Left = left, Right = right, Button = button }

            function Tab:Select()
                for _, other in ipairs(pages) do
                    other.Page.Visible = false
                    glide(other.Button, { BackgroundTransparency = 1 })
                    glide(other.Edge, { Transparency = 1 })
                    glide(other.Label, { TextColor3 = Theme.SubText })
                    glide(other.Mark, { Size = UDim2.fromOffset(3, 0) })
                end
                page.Visible = true
                glide(button, { BackgroundTransparency = 0.86, BackgroundColor3 = Theme.Accent })
                glide(edge, { Transparency = 0.45, Color = Theme.Accent })
                glide(label, { TextColor3 = Theme.Text })
                glide(mark, { Size = UDim2.fromOffset(3, 16) })
                ActiveTab = Tab
            end

            local function makeBox(column, title)
                local box = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundColor3 = Theme.Panel,
                    BorderSizePixel = 0,
                    LayoutOrder = #column:GetChildren(),
                }, column)
                round(box, UDim.new(0, Lib.CornerRadius), true)
                outline(box, Theme.LineSoft, 1)
                pad(box, 14, 14, 12, 14)

                local head = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 20),
                    BackgroundTransparency = 1,
                    LayoutOrder = 0,
                }, box)

                local badge = new("Frame", {
                    AnchorPoint = Vector2.new(0, 0.5),
                    Position = UDim2.new(0, 0, 0.5, 0),
                    Size = UDim2.fromOffset(3, 13),
                    BackgroundColor3 = Theme.Accent,
                    BorderSizePixel = 0,
                }, head)
                round(badge, PILL)

                new("TextLabel", {
                    Position = UDim2.fromOffset(12, 0),
                    Size = UDim2.new(1, -12, 1, 0),
                    BackgroundTransparency = 1,
                    Font = Enum.Font.GothamBold,
                    TextSize = 12,
                    TextColor3 = Theme.Text,
                    TextXAlignment = Enum.TextXAlignment.Left,
                    TextTruncate = Enum.TextTruncate.AtEnd,
                    Text = title or "",
                }, head)

                local body = new("Frame", {
                    Size = UDim2.new(1, 0, 0, 0),
                    AutomaticSize = Enum.AutomaticSize.Y,
                    BackgroundTransparency = 1,
                    LayoutOrder = 1,
                }, box)
                stack(body, 9)
                pad(body, 0, 0, 8, 0)

                stack(box, 0)
                return makeGroup(body)
            end

            function Tab:AddLeftGroupbox(title)
                return makeBox(left, title)
            end

            function Tab:AddRightGroupbox(title)
                return makeBox(right, title)
            end

            bind(button.MouseButton1Click, function()
                Tab:Select()
            end)
            bind(button.MouseEnter, function()
                if ActiveTab ~= Tab then
                    glide(button, { BackgroundTransparency = 0.92, BackgroundColor3 = Theme.Text })
                end
            end)
            bind(button.MouseLeave, function()
                if ActiveTab ~= Tab then
                    glide(button, { BackgroundTransparency = 1 })
                end
            end)

            table.insert(pages, { Page = page, Button = button, Edge = edge, Label = label, Mark = mark })
            if #pages == 1 then
                Tab:Select()
            end
            return Tab
        end

        function Window:SetCornerRadius(radius)
            Lib.CornerRadius = radius
            for _, corner in ipairs(panels) do
                corner.CornerRadius = UDim.new(0, radius)
            end
        end

        function Window:Toggle()
            Shell.Visible = not Shell.Visible
        end

        Lib.Window = Window
        Lib:SetNotifySide(config.NotifySide or "Right")

        Shell.Visible = true
        Shell.Size = UDim2.fromOffset(724, 460)
        glide(Shell, { Size = UDim2.fromOffset(724, 516) }, 0.28)

        return Window
    end

    bind(UserInputService.InputBegan, function(input, processed)
        if processed or Lib.Unloaded or not Shell then
            return
        end
        if input.UserInputType ~= Enum.UserInputType.Keyboard then
            return
        end
        if UserInputService:GetFocusedTextBox() then
            return
        end
        local wanted = Lib.ToggleKeybind and Lib.ToggleKeybind.Value or Lib.DefaultToggleKey
        if wanted ~= "" and input.KeyCode.Name == wanted then
            Shell.Visible = not Shell.Visible
        end
    end)

    function Lib:SetDPIScale(percent)
        Lib.DPI = math.clamp((tonumber(percent) or 100) / 100, 0.5, 2)
        if Lib.Refit then
            Lib.Refit()
        elseif Scale then
            Scale.Scale = Lib.DPI
        end
    end

    function Lib:Unload()
        if Lib.Unloaded then return end
        Lib.Unloaded = true
        for _, link in ipairs(conns) do
            pcall(function()
                link:Disconnect()
            end)
        end
        conns = {}
        Root:Destroy()
        -- full teardown (hooks/connections/guis/tags); no-op when session.unload is what called us
        if not REGISTRY.unloading and REGISTRY.sessionUnload then
            pcall(REGISTRY.sessionUnload)
        end
    end

    local function fileApi()
        if not configFolder then
            return nil
        end
        local write = rawget(_G, "writefile") or writefile
        local read = rawget(_G, "readfile") or readfile
        local list = rawget(_G, "listfiles") or listfiles
        local exists = rawget(_G, "isfile") or isfile
        local folder = rawget(_G, "isfolder") or isfolder
        local mkdir = rawget(_G, "makefolder") or makefolder
        local remove = rawget(_G, "delfile") or delfile
        if type(write) ~= "function" or type(read) ~= "function" or type(list) ~= "function" then
            return nil
        end
        return { write = write, read = read, list = list, exists = exists, folder = folder, mkdir = mkdir, remove = remove }
    end

    function Lib:SetConfigFolder(name)
        configFolder = name
    end

    local function ensureFolder(api)
        if not (api.folder and api.mkdir) then
            return true
        end
        local ok, ready = pcall(function()
            if not api.folder(configFolder) then
                api.mkdir(configFolder)
            end
            if not api.folder(configFolder .. "/configs") then
                api.mkdir(configFolder .. "/configs")
            end
            return api.folder(configFolder .. "/configs") == true
        end)
        if ok and ready then
            return true
        end
        if configFolder then
            Lib:Notify("Config folder not writable")
        end
        configFolder = nil
        return false
    end

    local function collect()
        local dump = { toggles = {}, options = {} }
        for index, toggle in pairs(Lib.Toggles) do
            dump.toggles[index] = toggle.Value
        end
        for index, option in pairs(Lib.Options) do
            if option.Type == "KeyPicker" then
                dump.options[index] = { option.Value, option.Mode }
            else
                dump.options[index] = option.Value
            end
        end
        return dump
    end

    local function restore(dump)
        for index, value in pairs(dump.toggles or {}) do
            local toggle = Lib.Toggles[index]
            if toggle then
                toggle:SetValue(value)
            end
        end
        for index, value in pairs(dump.options or {}) do
            local option = Lib.Options[index]
            if option and option.SetValue then
                option:SetValue(value)
            end
        end
    end

    function Lib:SaveConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        if not configFolder then
            return false
        end
        if not ensureFolder(api) then
            return false
        end
        if api.folder and not api.folder(configFolder .. "/configs") then
            Lib:Notify("Config folder missing")
            return false
        end
        local ok, encoded = pcall(HttpService.JSONEncode, HttpService, collect())
        if not ok then
            return false
        end
        return pcall(api.write, configFolder .. "/configs/" .. name .. ".json", encoded)
    end

    function Lib:LoadConfig(name)
        local api = fileApi()
        if not api or not name or name == "" then
            return false
        end
        local ok, raw = pcall(api.read, configFolder .. "/configs/" .. name .. ".json")
        if not ok or type(raw) ~= "string" then
            return false
        end
        local parsed, dump = pcall(HttpService.JSONDecode, HttpService, raw)
        if not parsed or type(dump) ~= "table" then
            return false
        end
        local restored, restoreErr = pcall(restore, dump)
        if not restored then
            warn("SAGEBAIT: restore error - " .. tostring(restoreErr))
            Lib:Notify("Config restore failed partway")
            return false
        end
        return true
    end

    function Lib:ListConfigs()
        local api = fileApi()
        local found = {}
        if not api then
            return found
        end
        ensureFolder(api)
        local ok, entries = pcall(api.list, configFolder .. "/configs")
        if not ok or type(entries) ~= "table" then
            return found
        end
        for _, path in ipairs(entries) do
            local name = string.match(path, "([^/\\]+)%.json$")
            if name then
                table.insert(found, name)
            end
        end
        return found
    end

    function Lib:LoadAutoloadConfig()
        local api = fileApi()
        if not api then
            return
        end
        local ok, name = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(name) == "string" and name ~= "" then
            Lib:LoadConfig(name)
        end
    end

    function Lib:BuildConfigSection(tab)
        local group = tab:AddRightGroupbox("Configuration")
        local api = fileApi()

        if not api then
            group:AddLabel("This executor has no file API, configs are off", true)
            return group
        end

        local nameBox = group:AddInput("ConfigName", {
            Default = "",
            Text = "Config name",
            Placeholder = "default",
        })

        local picker = group:AddDropdown("ConfigList", {
            Values = Lib:ListConfigs(),
            Default = nil,
            Text = "Saved configs",
        })

        group:AddButton({
            Text = "Create",
            Func = function()
                if Lib:SaveConfig(nameBox.Value) then
                    picker:SetValues(Lib:ListConfigs())
                    Lib:Notify("Saved config " .. nameBox.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Load",
            Func = function()
                if picker.Value and Lib:LoadConfig(picker.Value) then
                    Lib:Notify("Loaded config " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Overwrite",
            Func = function()
                if picker.Value and Lib:SaveConfig(picker.Value) then
                    Lib:Notify("Overwrote config " .. picker.Value)
                end
            end,
        })

        local deleteArmed = false
        local armToken = 0
        local deleteButton
        deleteButton = group:AddButton({
            Text = "Delete",
            Func = function()
                if not deleteArmed then
                    deleteArmed = true
                    armToken = armToken + 1
                    local myToken = armToken
                    deleteButton:SetText("Click again to confirm")
                    task.delay(3, function()
                        if deleteArmed and armToken == myToken then
                            deleteArmed = false
                            deleteButton:SetText("Delete")
                        end
                    end)
                    return
                end
                deleteArmed = false
                deleteButton:SetText("Delete")
                if picker.Value and api.remove and configFolder then
                    pcall(api.remove, configFolder .. "/configs/" .. picker.Value .. ".json")
                    picker:SetValues(Lib:ListConfigs())
                    picker:SetValue(nil, true)
                    Lib:Notify("Deleted config")
                end
            end,
        })

        group:AddButton({
            Text = "Refresh list",
            Func = function()
                picker:SetValues(Lib:ListConfigs())
            end,
        })

        local autoLabel = group:AddLabel("Autoload: none", true)

        group:AddButton({
            Text = "Set as autoload",
            Func = function()
                if picker.Value and configFolder then
                    pcall(api.write, configFolder .. "/autoload.txt", picker.Value)
                    autoLabel:SetText("Autoload: " .. picker.Value)
                end
            end,
        })

        group:AddButton({
            Text = "Clear autoload",
            Func = function()
                if configFolder then
                    pcall(api.write, configFolder .. "/autoload.txt", "")
                end
                autoLabel:SetText("Autoload: none")
            end,
        })

        local ok, current = pcall(api.read, configFolder .. "/autoload.txt")
        if ok and type(current) == "string" and current ~= "" then
            autoLabel:SetText("Autoload: " .. current)
        end

        return group
    end

    return Lib
end)()

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.SAGEBAIT_SESSION
    if type(session) == "table" then
        session.ui = Library
    end
end

-- ============================================================================
-- SECTION 4 — SERVICES, MARKERS AND FEATURE STATE
-- Every module service reference, per-run tag and flag lives here.
-- ============================================================================

local Options = Library.Options
local Toggles = Library.Toggles

Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local CollectionService = game:GetService("CollectionService")

local LocalPlayer = Players.LocalPlayer
local Camera = Workspace.CurrentCamera
local _AC = require(game:GetService("ReplicatedFirst").Controllers.AnimationController)

local MARK = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))
local MARK2 = string.char(math.random(97, 122), math.random(97, 122), math.random(97, 122)) .. tostring(math.random(100000, 999999))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.SAGEBAIT_SESSION
    if type(session) == "table" and type(session.tags) == "table" then
        table.insert(session.tags, MARK)
        table.insert(session.tags, MARK2)
    end
    REGISTRY.registerTag(MARK)
    REGISTRY.registerTag(MARK2)
end

local function track(connection)
    REGISTRY.registerConnection(connection)
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = genv.SAGEBAIT_SESSION
    if type(session) == "table" and type(session.links) == "table" then
        table.insert(session.links, connection)
    end
    return connection
end

local hitboxEnabled = false
local hitboxScale = 5.0
local hitboxReach = 5.0
local hitboxFollow = nil
local hitboxColor = Color3.fromRGB(0, 0, 255)
local hitboxTransparency = 0.3
local hitboxBoxes = {}

local redirectSpikeEnabled = false
local sanjuTiltEnabled = false
local maxChargeEnabled = false
local newSilentSpikeEnabled = false
local newSpikeButton = nil
local stopBallButton = nil
local aimButton = nil
local stopBallVisible = false
local aimVisible = false
local dashButton = nil
local akariDashEnabled = false
local leadFeetEnabled = false
local leadFeetButton = nil
local leadFeetLink = nil
local espJumpEnabled = false
local espHighlights = {}
local espConnections = {}
local desyncEnabled = false
local desyncConnection = nil
local autoReceiveEnabled = false
local Receive = { range = 10, lead = 0.35, stamp = 0, gap = 0.2 }
local maxServeEnabled = false
local airMovement = false
local airMovementSpeed = 16
local bodyVelocity = nil
local autoShiftLockEnabled = false
local shiftLockConnection = nil
local hitEffectEnabled = false
local selectedEffect = "SupernovaScoreEffect"
local hasFired = false
local isLocalHit = false
local hitConnection = nil
local hitConnection2 = nil
local hitRemovedConnection = nil
local effectList = {}
local playerCardEnabled = false
local selectedCard = "UltimateChampionPlayerCard"
local hasFiredCard = false
local isProcessing = false
local cardConnection = nil
local cardList = {}
local selectedJersey = "DragonTuxedoJersey"
local pickedTeam = nil
local jerseyList = {}
local selectedBallSkin = "ClassicBall"
local ballSkinList = {}
local autoSpin = false
local autoAbilitySpin = false
local autoSpinRunning = false
local autoAbilitySpinRunning = false
local desiredStyles = {}
local desiredAbilities = {}
local spinType = "Normal"
local abilitySpinType = "Normal"
local autoApplyJersey = false
local autoApplyBallSkin = false
local fakeSpikeEnabled = false

local originals = {}
local clones = {}
local seen = {}

local linesEnabled = false
local lineDistance = 50
local lines = {}
local lineColors = {
    Color3.fromRGB(255, 0, 0),
    Color3.fromRGB(0, 255, 0),
    Color3.fromRGB(0, 0, 255),
    Color3.fromRGB(255, 165, 0),
    Color3.fromRGB(128, 0, 128),
    Color3.fromRGB(255, 255, 0),
    Color3.fromRGB(139, 0, 0),
    Color3.fromRGB(0, 100, 0)
}

local changedProperties = {}
local oldQualityLevel
local oldSavedQualityLevel
local antilagConnections = {}

local BallService = (function()
    local ok, found = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService
    end)
    if ok and found then return found end
    warn("SAGEBAIT: could not resolve BallService; features that need it stay off")
    return nil
end)()
local Serve = (function()
    local ok, found = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RF.Serve
    end)
    if ok and found then return found end
    warn("SAGEBAIT: could not resolve Serve; features that need it stay off")
    return nil
end)()
local EffectsRemote = (function()
    local ok, found = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.Effects
    end)
    if ok and found then return found end
    warn("SAGEBAIT: could not resolve EffectsRemote; features that need it stay off")
    return nil
end)()
local doMove = (function()
    local ok, found = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    end)
    if ok and found then return found end
    warn("SAGEBAIT: could not resolve doMove; features that need it stay off")
    return nil
end)()
local GameEffectRemote = (function()
    local ok, found = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.GameService.RE.Effect
    end)
    if ok and found then return found end
    warn("SAGEBAIT: could not resolve GameEffectRemote; features that need it stay off")
    return nil
end)()

-- ============================================================================
-- SECTION 5 — FEATURE HANDLERS AND GAMEPLAY LOGIC
-- Each feature (spike variants, hitbox, auto-receive, ESP, vault, config, etc.)
-- registers its own handlers here through Namecall.register / Scheduler.add.
-- ============================================================================

local function fireCardRemote()
    if hasFiredCard or isProcessing then return end
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PlayerCardService.RE.OnFlashCard
    if Remote and firesignal then
        isProcessing = true
        hasFiredCard = true
        pcall(firesignal, Remote.OnClientEvent, {
            ["PlayerCardItemId"] = selectedCard,
            ["Context"] = {
                ["Custom"] = {},
                ["PlacementId"] = "ScoredPoint",
            },
            ["Player"] = LocalPlayer,
        })
        task.wait(0.3)
        hasFiredCard = false
        isProcessing = false
    end
end

local function changePlayerCard()
    if not playerCardEnabled then return end
    if isProcessing then return end
    local located, persistent = pcall(function()
        return LocalPlayer.PlayerGui.Interface.Persistent
    end)
    if not located or not persistent then return end
    local flashFrame = persistent:FindFirstChild("FlashPlayerCardFrame")
    if not flashFrame then return end
    local username = flashFrame:FindFirstChild("Username", true)
    if username and username:IsA("TextLabel") then
        local currentText = string.upper(username.Text or "")
        local playerName = string.upper(LocalPlayer.Name)
        if string.find(currentText, playerName) then
            flashFrame:Destroy()
            task.wait(0.1)
            fireCardRemote()
        end
    end
end

local function enablePlayerCard()
    if cardConnection then return end
    local iface = LocalPlayer.PlayerGui:FindFirstChild("Interface")
    local persistent = iface and iface:FindFirstChild("Persistent")
    if not persistent then return end
    cardConnection = REGISTRY.bind(persistent.ChildAdded, function(child)
        if child.Name == "FlashPlayerCardFrame" then
            task.wait(0.1)
            changePlayerCard()
        end
    end)
end

local function disablePlayerCard()
    if cardConnection then
        REGISTRY.disconnect(cardConnection)
        cardConnection = nil
    end
end

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local SESSION = genv.SAGEBAIT_SESSION
    local playerCardApi = {
        Enable = enablePlayerCard,
        Disable = disablePlayerCard,
        SetCard = function(cardName)
            selectedCard = cardName
        end,
        GetCard = function()
            return selectedCard
        end
    }
    if type(SESSION) == "table" then
        SESSION.PlayerCard = playerCardApi
    end
    -- compat alias for external callers; cleared on unload
    _G.PlayerCard = playerCardApi
    REGISTRY.registerCleanup(function()
        if _G.PlayerCard == playerCardApi then
            _G.PlayerCard = nil
        end
        if type(SESSION) == "table" and SESSION.PlayerCard == playerCardApi then
            SESSION.PlayerCard = nil
        end
    end)
end

local function findFirstPart(model)
    if model.PrimaryPart then
        return model.PrimaryPart
    end
    for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") and descendant.Name ~= MARK and descendant.Name ~= MARK2 then
            return descendant
        end
    end
    return nil
end

-- Short-lived cache for ball lookups. getNearestBall/ballModels run every frame
-- (Heartbeat/RenderStepped) and each one scans Workspace; a 50-100 ms window removes
-- almost all of that work. Invalidated on character change and CLIENT_BALL_* add/remove.
local BallCache = {
    models = nil,       -- last ballModels() result
    modelsAt = 0,
    nearest = nil,      -- last getNearestBall() part; false = "no ball", nil = not cached
    nearestAt = 0,
    TTL_MODELS = 0.1,
    TTL_NEAREST = 0.05,
}

function BallCache.invalidate()
    BallCache.models, BallCache.modelsAt = nil, 0
    BallCache.nearest, BallCache.nearestAt = nil, 0
end

-- Uncached workspace scan for CLIENT_BALL_* models (same set getNearestBall always used).
local function scanWorkspaceBalls()
    local list = {}
    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_%d+$") then
            list[#list + 1] = model
        end
    end
    return list
end

local function ballModels()
    local now = os.clock()
    if BallCache.models and now - BallCache.modelsAt < BallCache.TTL_MODELS then
        return BallCache.models
    end
    local ok, list = pcall(CollectionService.GetTagged, CollectionService, "Ball")
    if not ok or type(list) ~= "table" or not list[1] then
        list = scanWorkspaceBalls()
    end
    BallCache.models, BallCache.modelsAt = list, now
    return list
end

local function reachableBall(params, character)
    if not character then return nil end
    local closest, shortest = nil, hitboxReach
    for _, model in ipairs(params.FilterDescendantsInstances) do
        if model:IsA("Model") then
            local driver = model.PrimaryPart or findFirstPart(model)
            if driver then
                for _, piece in ipairs(character:GetChildren()) do
                    if piece:IsA("BasePart") then
                        local gap = (piece.Position - driver.Position).Magnitude
                        if gap <= shortest then
                            closest, shortest = driver, gap
                        end
                    end
                end
            end
        end
    end
    return closest
end

local function installHitboxHook()
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("hitbox", function(self, method, args)
        if hitboxEnabled and self == Workspace and method == "GetPartsInPart" then
            local probe, params = args[1], args[2]
            if typeof(probe) == "Instance" and typeof(params) == "OverlapParams"
                and params.FilterType == Enum.RaycastFilterType.Include then
                return {
                    post = function(results)
                        if type(results) == "table" and not results[1] then
                            local driver = reachableBall(params, LocalPlayer.Character)
                            if driver then
                                results[1] = driver
                            end
                        end
                        return results
                    end,
                }
            end
        end
    end)
end

local function adornHolder()
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = MARK
        folder.Parent = camera
    end
    return folder
end

-- ============================================================================
-- Visual scheduler: ONE RenderStepped connection drives the visual loops.
-- rateHz >= 60 runs every frame (never throttled, so 60 Hz visuals are not skipped
-- when a frame arrives a few ms early). Lower rates run once their interval elapsed
-- (0.9 factor = 10% tolerance, so 30 Hz is not stuck at 20). Tasks run in insertion
-- order, each under pcall so one failing task cannot stop the others.
-- Gameplay loops (autoReceive, AutoCounter, leadFeet) intentionally stay on Heartbeat.
-- ============================================================================
local Scheduler = { list = {}, byName = {}, conn = nil }

function Scheduler.tick()
    local now = os.clock()
    local list = Scheduler.list -- add/remove swap the table, so this tick keeps its snapshot
    for i = 1, #list do
        local entry = list[i]
        if entry.gap == 0 or now - entry.lastRun >= entry.gap then
            entry.lastRun = now
            local ok, err = pcall(entry.fn)
            if not ok and not entry.warned then
                entry.warned = true
                warn("SAGEBAIT scheduler: task '" .. entry.name .. "' failed: " .. tostring(err))
            end
        end
    end
end

function Scheduler.remove(name)
    local entry = Scheduler.byName[name]
    if not entry then return end
    Scheduler.byName[name] = nil
    local nextList = {}
    for _, other in ipairs(Scheduler.list) do
        if other ~= entry then
            nextList[#nextList + 1] = other
        end
    end
    Scheduler.list = nextList
end

function Scheduler.add(name, fn, rateHz)
    rateHz = rateHz or 60
    Scheduler.remove(name)
    local entry = {
        name = name,
        fn = fn,
        gap = (rateHz >= 60) and 0 or (0.9 / rateHz),
        lastRun = 0,
        warned = false,
    }
    Scheduler.byName[name] = entry
    local nextList = {}
    for i, other in ipairs(Scheduler.list) do
        nextList[i] = other
    end
    nextList[#nextList + 1] = entry
    Scheduler.list = nextList
    Scheduler.start()
end

function Scheduler.start()
    if Scheduler.conn then return end
    Scheduler.conn = REGISTRY.bind(RunService.RenderStepped, Scheduler.tick)
end

function Scheduler.stop()
    if Scheduler.conn then
        pcall(function()
            Scheduler.conn:Disconnect()
        end)
        Scheduler.conn = nil
    end
end
REGISTRY.registerCleanup(Scheduler.stop)

local function installHitboxFollow()
    if hitboxFollow then return end
    hitboxFollow = true
    Scheduler.add("hitbox_follow", function()
        for driver, shell in pairs(hitboxBoxes) do
            if driver.Parent and shell.Parent then
                shell.CFrame = driver.CFrame
            end
        end
    end, 60)
end

local function updateHitboxes(scale)
    if not hitboxEnabled then return end
    hitboxReach = scale or hitboxReach
    installHitboxHook()
    installHitboxFollow()
    local folder = adornHolder()
    local live = {}
    for _, model in ipairs(ballModels()) do
        local driver = model.PrimaryPart or findFirstPart(model)
        if driver then
            live[driver] = true
            local shell = hitboxBoxes[driver]
            if not shell or not shell.Parent then
                shell = Instance.new("Part")
                shell.Name = MARK
                shell.Shape = Enum.PartType.Ball
                shell.Material = Enum.Material.ForceField
                shell.Anchored = true
                shell.CanCollide = false
                shell.CanTouch = false
                shell.CanQuery = false
                shell.CastShadow = false
                shell.Massless = true
                shell.Reflectance = 0
                shell.Parent = folder
                hitboxBoxes[driver] = shell
            end
            shell.Size = Vector3.new(2, 2, 2) * hitboxReach
            shell.CFrame = driver.CFrame
            shell.Color = hitboxColor
            shell.Transparency = hitboxTransparency
        end
    end
    for driver, shell in pairs(hitboxBoxes) do
        if not live[driver] then
            if shell.Parent then
                shell:Destroy()
            end
            hitboxBoxes[driver] = nil
        end
    end
end

local function removeHitboxes()
    Namecall.unregister("hitbox")
    Scheduler.remove("hitbox_follow")
    hitboxFollow = nil
    for driver, shell in pairs(hitboxBoxes) do
        if shell.Parent then
            shell:Destroy()
        end
        hitboxBoxes[driver] = nil
    end
    local camera = Workspace.CurrentCamera or Camera
    local folder = camera:FindFirstChild(MARK)
    if folder then
        folder:Destroy()
    end
end

track(Workspace.ChildAdded:Connect(function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then
        for _ = 1, 40 do
            if findFirstPart(child) then
                break
            end
            task.wait(0.05)
        end
        if hitboxEnabled and child.Parent then
            updateHitboxes(hitboxScale)
        end
    end
end))

if hitboxEnabled then
    updateHitboxes(hitboxScale)
end

local function removeLine(player)
    local data = lines[player]
    if data then
        if data.beam then data.beam:Destroy() end
        if data.target and data.target.Parent then data.target:Destroy() end
        if data.attachment and data.attachment.Parent then data.attachment:Destroy() end
        lines[player] = nil
    end
end

local function updateLine(player, index)
    if not linesEnabled then
        removeLine(player)
        return
    end
    local character = player.Character
    if not character or not character:FindFirstChild("Head") or not character:FindFirstChild("HumanoidRootPart") then
        removeLine(player)
        return
    end
    local head = character.Head
    local rootPart = character.HumanoidRootPart
    if not lines[player] then
        local attachment = Instance.new("Attachment", head)
        local target = Instance.new("Part")
        target.Anchored = true
        target.CanCollide = false
        target.Transparency = 1
        target.Size = Vector3.new(0.1, 0.1, 0.1)
        target.Parent = Workspace
        local targetAttachment = Instance.new("Attachment", target)
        local beam = Instance.new("Beam")
        beam.Attachment0 = attachment
        beam.Attachment1 = targetAttachment
        beam.Width0 = 0.25
        beam.Width1 = 0.25
        beam.FaceCamera = true
        beam.LightEmission = 1
        beam.Transparency = NumberSequence.new(0.3)
        beam.Color = ColorSequence.new(lineColors[(index - 1) % #lineColors + 1])
        beam.Parent = head
        lines[player] = { beam = beam, target = target, attachment = attachment }
    end
    local data = lines[player]
    data.target.Position = head.Position + rootPart.CFrame.LookVector * lineDistance
end

local function linesTick()
    if linesEnabled then
        for index, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer and player.Team ~= LocalPlayer.Team then
                updateLine(player, index)
            else
                removeLine(player)
            end
        end
    else
        for player in pairs(lines) do
            removeLine(player)
        end
    end
end

track(Players.PlayerRemoving:Connect(removeLine))

do
    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local SESSION = genv.SAGEBAIT_SESSION
    local linesApi = {
        SetEnabled = function(value)
            linesEnabled = value
            if value then
                Scheduler.add("lines", linesTick, 30)
            else
                Scheduler.remove("lines")
            end
            if not value then
                for player in pairs(lines) do
                    removeLine(player)
                end
            end
        end,
        SetDistance = function(value)
            lineDistance = value
        end,
        IsEnabled = function()
            return linesEnabled
        end,
        GetDistance = function()
            return lineDistance
        end
    }
    if type(SESSION) == "table" then
        SESSION.Lines = linesApi
    end
    -- compat alias for external callers; cleared on unload
    _G.Lines = linesApi
    REGISTRY.registerCleanup(function()
        if _G.Lines == linesApi then
            _G.Lines = nil
        end
        if type(SESSION) == "table" and SESSION.Lines == linesApi then
            SESSION.Lines = nil
        end
    end)
end

local function isOnGround()
    local character = LocalPlayer.Character
    if not character then return false end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return false end
    local humanoid = character:FindFirstChild("Humanoid")
    if not humanoid then return false end
    return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function getNearestBall()
    local character = LocalPlayer.Character
    if not character then return nil, nil end
    local rootPart = character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return nil, nil end

    local now = os.clock()
    local part = BallCache.nearest
    local fresh = part ~= nil and now - BallCache.nearestAt < BallCache.TTL_NEAREST
        and (part == false or part:IsDescendantOf(Workspace))
    if not fresh then
        local nearestBall = nil
        local nearestDistance = math.huge
        local sawModel = false
        for _, model in ipairs(scanWorkspaceBalls()) do
            sawModel = true
            for _, candidate in ipairs(model:GetDescendants()) do
                if candidate:IsA("BasePart") then
                    local distance = (candidate.Position - rootPart.Position).Magnitude
                    if distance < nearestDistance then
                        nearestDistance = distance
                        nearestBall = candidate
                    end
                    break
                end
            end
        end
        part = nearestBall or false
        -- do not cache "no part yet" while a model exists: parts may still be loading
        if part == false and sawModel then
            BallCache.nearest = nil
        else
            BallCache.nearest, BallCache.nearestAt = part, now
        end
    end

    if not part then return nil, math.huge end
    -- distance is always recomputed from the live root, only the candidate is cached
    return part, (part.Position - rootPart.Position).Magnitude
end

-- getBallId must live after getNearestBall (local function scoping), so it is defined here.
local function getBallId()
    local model = getNearestBall()
    if not model then return nil end
    local parentModel = model
    while parentModel and parentModel.Parent and not parentModel.Name:match("^CLIENT_BALL_%d+$") do
        parentModel = parentModel.Parent
    end
    if parentModel and parentModel.Name:match("^CLIENT_BALL_%d+$") then
        return tonumber(parentModel.Name:match("%d+"))
    end
    return nil
end

-- Invalidation wiring (torn down by REGISTRY.runUnload)
REGISTRY.bind(LocalPlayer.CharacterAdded, function()
    BallCache.invalidate()
end)
REGISTRY.bind(Workspace.ChildAdded, function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then BallCache.invalidate() end
end)
REGISTRY.bind(Workspace.ChildRemoved, function(child)
    if child:IsA("Model") and child.Name:match("^CLIENT_BALL_%d+$") then BallCache.invalidate() end
end)

local function ballDrift(part)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if reached then
        local found, controller = pcall(Knit.GetController, "BallController")
        if found and type(controller) == "table" and type(controller.ActiveBalls) == "table" then
            for _, record in pairs(controller.ActiveBalls) do
                local model = record.Ball
                if model and model.Parent and model:IsAncestorOf(part) and typeof(record.Velocity) == "Vector3" then
                    return record.Velocity
                end
            end
        end
    end
    local now = os.clock()
    local spot, when = Receive.spot, Receive.when
    local same = Receive.part == part
    Receive.part, Receive.spot, Receive.when = part, part.Position, now
    if same and spot and now > when then
        return (part.Position - spot) / (now - when)
    end
    return Vector3.zero
end

local function autoReceive()
    if not autoReceiveEnabled then return end
    if not isOnGround() then return end
    local character = LocalPlayer.Character
    local rootPart = character and character:FindFirstChild("HumanoidRootPart")
    if not rootPart then return end

    local now = os.clock()
    if now - Receive.stamp < Receive.gap then return end

    local ball = getNearestBall()
    if not ball then return end

    local offset = ball.Position - rootPart.Position
    local drift = ballDrift(ball) - rootPart.AssemblyLinearVelocity
    local pull = Vector3.new(0, -Workspace.Gravity, 0)

    local closest = offset.Magnitude
    for step = 1, 12 do
        local moment = step / 12 * Receive.lead
        local reach = (offset + drift * moment + pull * (0.5 * moment * moment)).Magnitude
        if reach < closest then
            closest = reach
        end
    end

    if closest > Receive.range then return end

    local loaded, handlers = pcall(require, game:GetService("ReplicatedFirst").Controllers.GameController.Handlers)
    if loaded and type(handlers) == "table" and handlers.States then
        local states = handlers.States
        if states.IsBusy:get() or states.IsServing:get() then
            return
        end
    end

    if firesignal and doMove then
        firesignal(doMove.OnClientEvent, "Set", false, false)
        Receive.stamp = now
    end
end

track(RunService.Heartbeat:Connect(autoReceive))

track(LocalPlayer.CharacterAdded:Connect(function()
    Receive.stamp = 0
    Receive.part = nil
end))


local function enableRedirectSpike()
    redirectSpikeEnabled = true
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("redirect", function(self, method, args)
        if not BallService then return end
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = args[1]
            if type(data) == "table" and data.Move == "Spike" and redirectSpikeEnabled then
                local dir = Camera.CFrame.LookVector
                data.LookVector = dir
                data.Direction = dir
                if data.MoveDirection then
                    data.MoveDirection = dir
                end
            end
        end
    end)
end

local function disableRedirectSpike()
    redirectSpikeEnabled = false
    Namecall.unregister("redirect")
end

local AutoCorner = {
    enabled = false,
    side = "Auto",
    reach = "All",
}

local function enableSanjuTilt()
    sanjuTiltEnabled = true
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("sanju", function(self, method, args)
        if not BallService then return end
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = args[1]
            if type(data) == "table" and data.Move == "Spike" and sanjuTiltEnabled then
                if data.TiltDirection and data.LookVector then
                    local tiltDir = data.TiltDirection
                    if math.abs(tiltDir.X) > 0.01 or math.abs(tiltDir.Z) > 0.01 then
                        local lookVec = data.LookVector
                        local bend = Vector3.new(tiltDir.X, 0, tiltDir.Z)
                        data.LookVector = Vector3.new(
                            lookVec.X + bend.X * 0.3,
                            lookVec.Y,
                            lookVec.Z + bend.Z * 0.3
                        ).Unit
                        data.TiltDirection = Vector3.new(
                            tiltDir.X * 1.35,
                            tiltDir.Y,
                            tiltDir.Z * 1.35
                        )
                    end
                end
            end
        end
    end)
end

local function disableSanjuTilt()
    sanjuTiltEnabled = false
    Namecall.unregister("sanju")
end

AutoCorner.physics = function()
    local reached, module = pcall(require, ReplicatedStorage.Common.Physics)
    return reached and module or nil
end

AutoCorner.bounds = function()
    local physics = AutoCorner.physics()
    if physics and physics._getCourtlines then
        local found, lines = pcall(physics._getCourtlines)
        if found and lines and lines:IsA("BasePart") then
            return lines.Position, lines.Size * 0.5, lines.Position.Y
        end
    end
    local map = Workspace:FindFirstChild("Map")
    local court = map and map:FindFirstChild("Court")
    if court then
        return court.Position, court.Size * 0.5 - Vector3.new(1, 0, 1), court.Position.Y + court.Size.Y * 0.5
    end
    return nil
end

AutoCorner.trackBall = function(ball, before, elapsed)
    if elapsed <= 0 then return end
    local drift = ball.Position - before
    AutoCorner.drift = drift / elapsed
end

AutoCorner.origin = function()
    local ball = getNearestBall()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not ball then
        return root and root.Position or Vector3.zero
    end

    local drift = AutoCorner.drift
    if not root or typeof(drift) ~= "Vector3" or drift.Magnitude < 1 then
        return ball.Position
    end

    local gap = ball.Position - root.Position
    local closing = drift - root.AssemblyLinearVelocity
    local speed = closing:Dot(closing)
    if speed < 1 then
        return ball.Position
    end

    local reach = math.clamp(-gap:Dot(closing) / speed, 0, 0.45)
    return ball.Position + drift * reach
end

local function cornerPoint()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    local centre, half, surfaceY = AutoCorner.bounds()
    if not root or not centre then return nil end

    local halfX = math.max(half.X - 2, 1)
    local halfZ = math.max(half.Z - 2, 1)

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local deepZ = centre.Z + sign * halfZ
    local leftX = centre.X + sign * halfX
    local rightX = centre.X - sign * halfX

    local pivot = AutoCorner.origin()
    local attackLine = half.Z / 3
    local standoff = math.abs(root.Position.Z - netZ)
    local hugging = 1 - math.clamp(standoff / attackLine, 0, 1)
    AutoCorner.lean = hugging

    local shortZ = centre.Z + sign * halfZ * 0.3
    local reach = AutoCorner.reach
    local wantsNear = reach == "Nearest" or (reach ~= "Back" and hugging > 0)

    local side = AutoCorner.side
    if side == "Left" then
        return Vector3.new(leftX, surfaceY, wantsNear and shortZ or deepZ)
    elseif side == "Right" then
        return Vector3.new(rightX, surfaceY, wantsNear and shortZ or deepZ)
    end

    local corners = {}
    if reach ~= "Nearest" then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, deepZ), reward = 0 }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, deepZ), reward = 0 }
    end
    if wantsNear then
        corners[#corners + 1] = { at = Vector3.new(leftX, surfaceY, shortZ), reward = 0.45 * hugging }
        corners[#corners + 1] = { at = Vector3.new(rightX, surfaceY, shortZ), reward = 0.45 * hugging }
    end

    local eye = Workspace.CurrentCamera or Camera
    local heading = eye and eye.CFrame.LookVector or root.CFrame.LookVector
    heading = Vector3.new(heading.X, 0, heading.Z)
    if heading.Magnitude < 0.01 then
        return corners[1].at
    end
    heading = heading.Unit

    local physics = AutoCorner.physics()
    local bounds = physics and physics._getCourtlines and physics._getCourtlines()

    local guards = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and (not LocalPlayer.Team or player.Team ~= LocalPlayer.Team) then
            local guardRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
            if guardRoot then
                guards[#guards + 1] = Vector3.new(guardRoot.Position.X, surfaceY, guardRoot.Position.Z)
            end
        end
    end

    local aligned = {}
    for _, corner in ipairs(corners) do
        local legal = true
        if bounds and physics.isPositionInCourt then
            local ok, inside = pcall(physics.isPositionInCourt, corner.at, bounds, 0, nil)
            legal = not ok or inside
        end
        if legal then
            local line = Vector3.new(corner.at.X - pivot.X, 0, corner.at.Z - pivot.Z)
            if line.Magnitude > 0.01 then
                local dot = line.Unit:Dot(heading)
                aligned[#aligned + 1] = { spot = corner.at, dot = dot, reward = corner.reward }
            end
        end
    end
    if #aligned == 0 then return corners[1].at end

    local pick
    for _, entry in ipairs(aligned) do
        if not pick or entry.dot > pick.dot then pick = entry end
    end
    local wanted = pick.spot.X >= centre.X

    local best, bestScore
    for _, entry in ipairs(aligned) do
        if (entry.spot.X >= centre.X) == wanted then
            local nearest = 60
            for _, guard in ipairs(guards) do
                local gap = (guard - entry.spot).Magnitude
                if gap < nearest then nearest = gap end
            end
            local score = math.min(nearest, 45) / 45 + entry.reward
            if not bestScore or score > bestScore then
                bestScore = score
                best = entry.spot
            end
        end
    end
    return best or pick.spot
end

AutoCorner.facing = function()
    local spot = cornerPoint()
    if not spot then return nil end
    local pivot = AutoCorner.origin()
    local flat = Vector3.new(spot.X - pivot.X, 0, spot.Z - pivot.Z)

    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if root then
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        local net = collide and collide:FindFirstChild("Net")
        local netZ = net and net.Position.Z
        if netZ then
            local ownSide = (root.Position.Z > netZ) and 1 or -1
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(spot.X - root.Position.X, 0, spot.Z - root.Position.Z)
            end
            if flat.Z * ownSide >= 0 then
                flat = Vector3.new(flat.X, 0, -ownSide * math.max(math.abs(flat.Z), 1))
            end
        end
    end

    if flat.Magnitude < 0.01 then return nil end
    return flat.Unit
end

AutoCorner.installAim = function()
    if AutoCorner.aimed then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("autocorner_aim", function(self, method, args)
        if not BallService then return end
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = args[1]
            if AutoCorner.enabled and type(data) == "table" and (data.Move == "Spike" or data.Move == "ServeSpike") then
                local steer = AutoCorner.steer
                if typeof(steer) == "Vector3" then
                    local flat = Vector3.new(steer.X, 0, steer.Z)
                    if flat.Magnitude > 0.01 then
                        flat = flat.Unit
                        local aim = (flat - Vector3.new(0, 0.35, 0)).Unit
                        data.LookVector = aim
                        data.Direction = aim
                    end
                end
            end
        end
    end)
    AutoCorner.aimed = true
end
AutoCorner.removeAim = function() Namecall.unregister("autocorner_aim"); AutoCorner.aimed = false end

local function enableMaxCharge()
    maxChargeEnabled = true
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("max_charge", function(self, method, args)
        if not BallService then return end
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = args[1]
            if type(data) == "table" and data.Move == "Spike" and maxChargeEnabled then
                data.Charge = 1.0
                data.SpecialCharge = 1.0
            end
        end
    end)
end

local function disableMaxCharge()
    maxChargeEnabled = false
    Namecall.unregister("max_charge")
end

local Hush = {
    active = false,
    links = {},
    damped = {},
    paused = {},
    muted = {},
    loud = {
        [Enum.AnimationPriority.Action] = true,
        [Enum.AnimationPriority.Action2] = true,
        [Enum.AnimationPriority.Action3] = true,
        [Enum.AnimationPriority.Action4] = true,
    },
}

Hush.gag = function(signal)
    if type(getconnections) ~= "function" then return end
    local listed, cons = pcall(getconnections, signal)
    if not listed or type(cons) ~= "table" then return end
    for _, con in ipairs(cons) do
        pcall(function()
            if con.Enabled ~= false then
                con:Disable()
                Hush.paused[#Hush.paused + 1] = con
            end
        end)
    end
end

-- soft = true only mutes (volume 0) and never Stop()s, used for sounds that were already
-- playing so that Hush.stop gives them their volume back and they keep playing.
Hush.quiet = function(inst, soft)
    if not inst:IsA("Sound") then return end
    -- Workspace and the character both hook DescendantAdded: record each sound once,
    -- otherwise restore would put back the already-muted volume of the second record
    if Hush.muted[inst] then return end
    Hush.muted[inst] = true
    Hush.damped[#Hush.damped + 1] = { inst = inst, level = inst.Volume }
    pcall(function()
        inst.Volume = 0
        if not soft then
            inst:Stop()
        end
    end)
end

Hush.start = function()
    if Hush.active then return end
    Hush.active = true

    if EffectsRemote then Hush.gag(EffectsRemote.OnClientEvent) end
    if GameEffectRemote then Hush.gag(GameEffectRemote.OnClientEvent) end

    Hush.animUntil = os.clock() + 0.2
    local character = LocalPlayer.Character
    local animator = character and character:FindFirstChildWhichIsA("Animator", true)
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end
        Hush.links[#Hush.links + 1] = REGISTRY.bind(animator.AnimationPlayed, function(track)
            if not Hush.active or os.clock() > Hush.animUntil then return end
            if Hush.loud[track.Priority] then
                pcall(track.Stop, track, 0)
            end
        end)
    end

    for _, root in ipairs({ Workspace, game:GetService("SoundService"), character }) do
        if root then
            for _, inst in ipairs(root:GetDescendants()) do
                if inst:IsA("Sound") and inst.IsPlaying then
                    Hush.quiet(inst, true)
                end
            end
            Hush.links[#Hush.links + 1] = REGISTRY.bind(root.DescendantAdded, function(inst)
                if Hush.active then
                    Hush.quiet(inst)
                end
            end)
        end
    end
end

Hush.stop = function()
    if not Hush.active then return end
    Hush.active = false
    for _, link in ipairs(Hush.links) do
        pcall(function() link:Disconnect() end)
    end
    Hush.links = {}
    for _, con in ipairs(Hush.paused) do
        pcall(function() con:Enable() end)
    end
    Hush.paused = {}
    for _, record in ipairs(Hush.damped) do
        if record.inst.Parent then
            pcall(function() record.inst.Volume = record.level end)
        end
    end
    Hush.damped = {}
    Hush.muted = {}
end

-- unload must re-enable the game connections Hush.gag disabled and restore muted sounds
REGISTRY.registerCleanup(function()
    if Hush.active then
        Hush.stop()
    end
end)

local function enemyAim()
    local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local centre, half, surfaceY = AutoCorner.bounds()
    if not centre then return nil end

    local map = Workspace:FindFirstChild("Map")
    local collide = map and map:FindFirstChild("BallCollideOnly")
    local net = collide and collide:FindFirstChild("Net")
    local netZ = net and net.Position.Z or centre.Z
    local netTop = net and (net.Position.Y + net.Size.Y * 0.5) or surfaceY

    local index = LocalPlayer.Team and LocalPlayer.Team:GetAttribute("Index")
    local sign
    if index == 1 then
        sign = 1
    elseif index == 2 then
        sign = -1
    else
        sign = (root.Position.Z < netZ) and 1 or -1
    end

    local ball = getNearestBall()
    local origin = ball and ball.Position or (root.Position + Vector3.new(0, 6, 0))
    local headroom = origin.Y - netTop
    local standoff = math.max(math.abs(netZ - origin.Z), 2)
    local drop = math.clamp(0.45 * headroom / standoff, -0.05, 0.30)

    local halfZ = math.max(half.Z - 2, 1)
    local target = Vector3.new(centre.X + (origin.X - centre.X) * 0.25, surfaceY, centre.Z + sign * halfZ * 0.55)

    local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    if flat.Magnitude < 0.01 then return nil end
    return (flat.Unit - Vector3.new(0, drop, 0)).Unit
end

local Silent = { steer = nil, expiry = 0, hooked = false }

Silent.install = function()
    if Silent.hooked then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("silent", function(self, method, args)
        if not BallService then return end
        if self == BallService.RF.Interact and method == "InvokeServer" then
            local data = args[1]
            local steer = Silent.steer
            if type(data) == "table" and typeof(steer) == "Vector3" and os.clock() < Silent.expiry then
                if data.Move == "Spike" or data.Move == "ServeSpike" then
                    data.LookVector = steer
                    data.Direction = steer
                    local ground = Vector3.new(steer.X, 0, steer.Z)
                    if typeof(data.TiltDirection) == "Vector3" and ground.Magnitude > 0.01 then
                        local power = Vector3.new(data.TiltDirection.X, 0, data.TiltDirection.Z).Magnitude
                        if power > 0.05 then
                            local lean = ground.Unit * power
                            data.TiltDirection = Vector3.new(lean.X, data.TiltDirection.Y, lean.Z)
                        end
                    end
                end
            end
        end
    end)
    Silent.hooked = true
end

local newSpikeInFlight = false

local function fireNewSpike()
    if not newSilentSpikeEnabled then return end
    if not firesignal then return end
    if newSpikeInFlight then return end
    local newRemote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    newSpikeInFlight = true
    local hadHitbox = hitboxEnabled
    local armed, armErr = pcall(function()
        Hush.start()
        hitboxEnabled = true
        updateHitboxes(300.0)
        local dir = enemyAim() or Camera.CFrame.LookVector
        Silent.steer = dir
        Silent.expiry = os.clock() + 0.8
        Silent.install()
        firesignal(newRemote.OnClientEvent, "Spike", false, false, dir)
    end)
    task.spawn(function()
        task.wait(0.3)
        pcall(function()
            hitboxEnabled = hadHitbox
            if hadHitbox then
                updateHitboxes(hitboxScale)
            else
                removeHitboxes()
            end
        end)
        pcall(Hush.stop)
        newSpikeInFlight = false
    end)
    if not armed then
        warn("[SAGEBAIT] new spike failed: " .. tostring(armErr))
    end
end

local function createNewSpikeButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    REGISTRY.registerGui(screenGui)
    screenGui.ResetOnSpawn = false
    newSpikeButton = Instance.new("TextButton")
    newSpikeButton.Size = UDim2.new(0, 50, 0, 50)
    newSpikeButton.Position = UDim2.new(0.5, -25, 0.85, -25)
    newSpikeButton.BackgroundColor3 = Color3.fromRGB(255, 165, 0)
    newSpikeButton.Text = "Spike"
    newSpikeButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    newSpikeButton.TextScaled = true
    newSpikeButton.Font = Enum.Font.GothamBold
    newSpikeButton.Parent = screenGui
    newSpikeButton.BackgroundTransparency = 0.2
    newSpikeButton.BorderSizePixel = 0
    newSpikeButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = newSpikeButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    newSpikeButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = newSpikeButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    newSpikeButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            newSpikeButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    newSpikeButton.MouseButton1Click:Connect(function()
        fireNewSpike()
    end)
    newSpikeButton.Visible = false
    return newSpikeButton
end

newSpikeButton = createNewSpikeButton()

local function enableDesync()
    if desyncConnection then return end
    local doMove = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.DoMove
    desyncConnection = REGISTRY.bind(UserInputService.JumpRequest, function()
        if desyncEnabled then
            task.wait(0.03)
            if firesignal then
                firesignal(doMove.OnClientEvent, "Spike", false, false)
            end
        end
    end)
    desyncEnabled = true
end

local function disableDesync()
    if desyncConnection then
        REGISTRY.disconnect(desyncConnection)
        desyncConnection = nil
    end
    desyncEnabled = false
end

local function playDashEffect(direction)
    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local Effect = require(ReplicatedStorage.Content.Effect)
        Effect:Play("KuraiDashFX")({
            Player = LocalPlayer,
            Direction = direction,
        })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

local function akariDash()
    if not akariDashEnabled then return end
    local character = LocalPlayer.Character
    if not character then return end
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local direction, distance = nil, 10
    local ball = getNearestBall()
    if ball then
        local flat = Vector3.new(ball.Position.X - hrp.Position.X, 0, ball.Position.Z - hrp.Position.Z)
        if flat.Magnitude > 0.01 then
            direction = flat.Unit
            distance = math.clamp(flat.Magnitude - 1, 0, 16)
        end
    end
    if not direction then
        local forward = Camera.CFrame.LookVector
        direction = Vector3.new(forward.X, 0, forward.Z).Unit
    end
    playDashEffect(direction)
    local tween = game:GetService("TweenService"):Create(hrp, TweenInfo.new(0.2, Enum.EasingStyle.Linear), {
        CFrame = CFrame.new(hrp.Position + (direction * distance)) * CFrame.Angles(0, math.rad(hrp.Orientation.Y), 0)
    })
    tween:Play()
end

local function createDashButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    REGISTRY.registerGui(screenGui)
    screenGui.ResetOnSpawn = false
    dashButton = Instance.new("TextButton")
    dashButton.Size = UDim2.new(0, 50, 0, 50)
    dashButton.Position = UDim2.new(0.15, -25, 0.8, -25)
    dashButton.BackgroundColor3 = Color3.fromRGB(255, 200, 0)
    dashButton.Text = "⚡"
    dashButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    dashButton.TextScaled = true
    dashButton.Font = Enum.Font.GothamBold
    dashButton.Parent = screenGui
    dashButton.BackgroundTransparency = 0.2
    dashButton.BorderSizePixel = 0
    dashButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = dashButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    dashButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = dashButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    dashButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            dashButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    dashButton.MouseButton1Click:Connect(akariDash)
    dashButton.Visible = false
    return dashButton
end

createDashButton()

local function stopBall()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local lookVector = Vector3.new(0, -1, 0)
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "Block",
            ["SpecialCharge"] = 0,
            ["TiltDirection"] = Vector3.new(-0.1260179579257965, 1, 0.992027997970581),
            ["LookVector"] = lookVector,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["BallId"] = ballId,
            ["Timestamp"] = tick(),
            ["CustomClient"] = {},
        })
    end
end

local function createStopBallButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    REGISTRY.registerGui(screenGui)
    screenGui.ResetOnSpawn = false
    stopBallButton = Instance.new("TextButton")
    stopBallButton.Size = UDim2.new(0, 50, 0, 50)
    stopBallButton.Position = UDim2.new(0.35, -25, 0.8, -25)
    stopBallButton.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    stopBallButton.Text = "Stop"
    stopBallButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    stopBallButton.TextScaled = true
    stopBallButton.Font = Enum.Font.GothamBold
    stopBallButton.Parent = screenGui
    stopBallButton.BackgroundTransparency = 0.2
    stopBallButton.BorderSizePixel = 0
    stopBallButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = stopBallButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    stopBallButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = stopBallButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    stopBallButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            stopBallButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    stopBallButton.MouseButton1Click:Connect(function()
        stopBall()
    end)
    stopBallButton.Visible = stopBallVisible
    return stopBallButton
end

local AutoCounter = (function()
    local ReplicatedFirst = game:GetService("ReplicatedFirst")

    local state = {
        enabled = false,
        move = "Auto",
        netRange = 9,
        lateral = 14,
        reach = 16,
        delay = 0.05,
        cooldown = 0.5,
        autoJump = true,
    }

    local handlers = nil
    local controller = nil
    local firing = false
    local lastFire = 0
    local bindFailedAt = -math.huge

    local function elevate(fn)
        local restore = getthreadidentity and getthreadidentity()
        if setthreadidentity then
            pcall(setthreadidentity, 2)
        end
        local ok = pcall(fn)
        if setthreadidentity and restore then
            pcall(setthreadidentity, restore)
        end
        return ok
    end

    local function bind()
        if handlers and controller then return true end
        if os.clock() - bindFailedAt < 5 then return false end
        elevate(function()
            handlers = require(ReplicatedFirst.Controllers.GameController.Handlers)
            controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        end)
        if handlers ~= nil and controller ~= nil then return true end
        bindFailedAt = os.clock()
        return false
    end

    local function getNet()
        local tagged = CollectionService:GetTagged("Net")[1]
        if tagged and tagged:IsA("BasePart") then
            return tagged
        end
        local map = Workspace:FindFirstChild("Map")
        local collide = map and map:FindFirstChild("BallCollideOnly")
        return collide and collide:FindFirstChild("Net")
    end

    local function ownSide(root, netZ)
        local team = LocalPlayer.Team
        local index = team and team:GetAttribute("Index")
        if index == 1 then return -1 end
        if index == 2 then return 1 end
        return (root.Position.Z >= netZ) and 1 or -1
    end

    local function findThreat(root, net)
        local netZ = net.Position.Z
        local netTop = net.Position.Y + net.Size.Y * 0.5
        local side = ownSide(root, netZ)

        local myGap = (root.Position.Z - netZ) * side
        if myGap < 0 or myGap > state.netRange then return nil end

        local ball = getNearestBall()
        if not ball then return nil end
        if ball.Position.Y < netTop - 3 then return nil end
        if math.abs(ball.Position.Z - netZ) > state.netRange + 6 then return nil end
        if math.abs(ball.Position.X - root.Position.X) > state.lateral then return nil end

        local myTeam = LocalPlayer.Team
        for _, player in ipairs(Players:GetPlayers()) do
            local hostile = player ~= LocalPlayer and (myTeam == nil or player.Team ~= myTeam)
            if hostile then
                local character = player.Character
                local enemyRoot = character and character:FindFirstChild("HumanoidRootPart")
                if enemyRoot and character:GetAttribute("Jumping") then
                    local enemyGap = (enemyRoot.Position.Z - netZ) * side
                    if enemyGap < 0 and -enemyGap <= state.netRange + 4
                        and (ball.Position - enemyRoot.Position).Magnitude <= state.reach
                        and math.abs(enemyRoot.Position.X - root.Position.X) <= state.lateral then
                        return ball, netZ, side
                    end
                end
            end
        end
        return nil
    end

    local function pickMove(ball, netZ, side)
        if state.move ~= "Auto" then return state.move end
        if (ball.Position.Z - netZ) * side > 0 then return "Spike" end
        return "Block"
    end

    local function fire(move)
        if not bind() then return end
        local states = handlers.States
        if states.IsBusy:get() or states.IsStunned:get() or states.IsServing:get() then return end
        if not states.IsPlaying:get() then return end
        if ReplicatedStorage:GetAttribute("ServedByTeam") then return end

        firing = true
        task.spawn(function()
            if state.autoJump and not states.IsJumping:get() then
                elevate(function() controller:PerformJump() end)
            end
            if state.delay > 0 then
                task.wait(state.delay)
            end
            elevate(function()
                controller:DoMove({
                    ActionName = move,
                    IsAerial = true,
                    InputState = Enum.UserInputState.Begin,
                    Metadata = {},
                })
            end)
            lastFire = os.clock()
            firing = false
        end)
    end

    local function step()
        if not state.enabled or firing then return end
        if os.clock() - lastFire < state.cooldown then return end
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not root then return end
        local net = getNet()
        if not net then return end
        local ball, netZ, side = findThreat(root, net)
        if not ball then return end
        fire(pickMove(ball, netZ, side))
    end

    track(RunService.Heartbeat:Connect(step))

    return { state = state }
end)()

local function getNearestTeammate()
    if not LocalPlayer.Team then return nil end
    local nearest = nil
    local shortestDistance = math.huge
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not playerRoot then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Team == LocalPlayer.Team then
            local character = player.Character
            if character then
                local rootPart = character:FindFirstChild("HumanoidRootPart")
                if rootPart then
                    local distance = (rootPart.Position - playerRoot.Position).Magnitude
                    if distance < shortestDistance then
                        shortestDistance = distance
                        nearest = player
                    end
                end
            end
        end
    end
    return nearest
end

local function aim()
    if not BallService then return end
    local ballId = getBallId()
    if not ballId then return end
    local nearestTeammate = getNearestTeammate()
    if not nearestTeammate then return end
    local targetRoot = nearestTeammate.Character:FindFirstChild("HumanoidRootPart")
    local playerRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
    if not targetRoot or not playerRoot then return end
    local direction = (targetRoot.Position - playerRoot.Position).Unit
    local tiltDir = Vector3.new(direction.X, 1, direction.Z)
    local lookVec = Vector3.new(direction.X, 0, direction.Z)
    if lookVec.Magnitude > 0 then
        lookVec = lookVec.Unit
    else
        lookVec = Vector3.new(0.17569558322429657, 9.214759444375886e-08, -0.9844445586204529)
    end
    local Interact = BallService.RF.Interact
    if Interact then
        Interact:InvokeServer({
            ["Charge"] = 1,
            ["Move"] = "JumpSet",
            ["SpecialCharge"] = 0.9999996364706223,
            ["TiltDirection"] = tiltDir,
            ["LookVector"] = lookVec,
            ["MoveDirection"] = Vector3.new(0, 0, 0),
            ["ClientCanRunSpecial"] = false,
            ["From"] = "Client",
            ["Timestamp"] = tick(),
            ["BallId"] = ballId,
            ["CustomClient"] = {},
        })
    end
end

local function createAimButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    REGISTRY.registerGui(screenGui)
    screenGui.ResetOnSpawn = false
    aimButton = Instance.new("TextButton")
    aimButton.Size = UDim2.new(0, 50, 0, 50)
    aimButton.Position = UDim2.new(0.65, -25, 0.8, -25)
    aimButton.BackgroundColor3 = Color3.fromRGB(50, 150, 255)
    aimButton.Text = "Aim"
    aimButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    aimButton.TextScaled = true
    aimButton.Font = Enum.Font.GothamBold
    aimButton.Parent = screenGui
    aimButton.BackgroundTransparency = 0.2
    aimButton.BorderSizePixel = 0
    aimButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = aimButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    aimButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = aimButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    aimButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            aimButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    aimButton.MouseButton1Click:Connect(function()
        aim()
    end)
    aimButton.Visible = aimVisible
    return aimButton
end

local function airMovementTick()
    if not airMovement then
        if bodyVelocity then
            bodyVelocity:Destroy()
            bodyVelocity = nil
        end
        return
    end

    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then
        return
    end

    if not bodyVelocity or bodyVelocity.Parent ~= root then
        if bodyVelocity then
            bodyVelocity:Destroy()
        end
        bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.Name = MARK
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
        bodyVelocity.P = 12500
        bodyVelocity.Parent = root
    end

    local direction = humanoid.MoveDirection
    if direction.Magnitude == 0 then
        if seen.__controls == nil then
            local reached, controls = pcall(function()
                return require(LocalPlayer.PlayerScripts.PlayerModule):GetControls()
            end)
            seen.__controls = (reached and controls) or false
        end
        if seen.__controls then
            local read, raw = pcall(seen.__controls.GetMoveVector, seen.__controls)
            if read and typeof(raw) == "Vector3" and raw.Magnitude > 0 then
                local camera = Workspace.CurrentCamera
                if camera then
                    raw = camera.CFrame:VectorToWorldSpace(raw)
                end
                direction = Vector3.new(raw.X, 0, raw.Z)
            end
        end
    end

    if humanoid.FloorMaterial == Enum.Material.Air and direction.Magnitude > 0 then
        bodyVelocity.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVelocity.Velocity = direction.Unit * airMovementSpeed
    else
        bodyVelocity.MaxForce = Vector3.zero
        bodyVelocity.Velocity = Vector3.zero
    end
end
local function isEnemy(player)
    if player == LocalPlayer then return false end
    if not player.Team or not LocalPlayer.Team then return false end
    return player.Team ~= LocalPlayer.Team
end

local function applyESP(player)
    if not player.Character or espHighlights[player] then return end
    local tone = Color3.fromRGB(255, 72, 72)
    local highlight = Instance.new("Highlight")
    highlight.Name = MARK
    highlight.Adornee = player.Character
    highlight.FillColor = tone
    highlight.FillTransparency = 0.72
    highlight.OutlineTransparency = 0
    highlight.OutlineColor = tone
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = player.Character
    espHighlights[player] = highlight
end

local function removeESP(player)
    if espHighlights[player] then
        espHighlights[player]:Destroy()
        espHighlights[player] = nil
    end
end

local function cleanupConnections(player)
    if espConnections[player] then
        for _, connection in pairs(espConnections[player]) do
            REGISTRY.disconnect(connection)
        end
        espConnections[player] = nil
    end
    removeESP(player)
end

local espCharAdded = {}

local function setupESP(player)
    if player == LocalPlayer then return end
    local function onCharacterAdded(character)
        cleanupConnections(player)
        local humanoid = character:WaitForChild("Humanoid", 3)
        local head = character:WaitForChild("Head", 5)
        if not humanoid or not head then return end
        if not espJumpEnabled then return end
        local stateConnection = humanoid.StateChanged:Connect(function(_, newState)
            if not espJumpEnabled or not isEnemy(player) then
                removeESP(player)
                return
            end
            if newState == Enum.HumanoidStateType.Jumping or newState == Enum.HumanoidStateType.Freefall then
                applyESP(player)
            elseif newState == Enum.HumanoidStateType.Landed or newState == Enum.HumanoidStateType.Running then
                removeESP(player)
            end
        end)
        espConnections[player] = { track(stateConnection) }
    end
    if player.Character then
        onCharacterAdded(player.Character)
    end
    if espCharAdded[player] then
        REGISTRY.disconnect(espCharAdded[player])
    end
    espCharAdded[player] = track(player.CharacterAdded:Connect(onCharacterAdded))
end

-- Defined AFTER setupESP so the local is in scope (before it, `setupESP` would resolve to a nil global).
local function espSetEnabled(state)
    if state then
        for _, player in ipairs(Players:GetPlayers()) do
            setupESP(player)
        end
    else
        for player in pairs(espConnections) do
            cleanupConnections(player)
        end
        for player in pairs(espHighlights) do
            removeESP(player)
        end
        for player, conn in pairs(espCharAdded) do
            REGISTRY.disconnect(conn)
            espCharAdded[player] = nil
        end
    end
end

if espJumpEnabled then
    for _, player in ipairs(Players:GetPlayers()) do
        setupESP(player)
    end
end
track(Players.PlayerAdded:Connect(function(player)
    if espJumpEnabled then
        setupESP(player)
    end
end))

-- ESP polling: ONE task (15 Hz) over all players, replacing a Heartbeat per character.
-- The StateChanged trigger in setupESP still reacts immediately to state changes.
local function espPoll()
    if not espJumpEnabled then
        for player in pairs(espHighlights) do
            removeESP(player)
        end
        return
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local character = player.Character
            local humanoid = character and character:FindFirstChildOfClass("Humanoid")
            if not humanoid or not isEnemy(player) then
                removeESP(player)
            else
                local state = humanoid:GetState()
                if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
                    applyESP(player)
                else
                    removeESP(player)
                end
            end
        end
    end
end
Scheduler.add("esp_jump", espPoll, 15)

local function enableMaxServe()
    maxServeEnabled = true
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    Namecall.register("max_serve", function(self, method, args)
        if not Serve then return end
        if self == Serve and method == "InvokeServer" and maxServeEnabled then
            args[2] = 5
            if args.n < 2 then
                args.n = 2
            end
        end
    end)
end

local function disableMaxServe()
    maxServeEnabled = false
    Namecall.unregister("max_serve")
end

local function leadFeetSlam()
    if not leadFeetEnabled then return end
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local root = character.PrimaryPart
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then return end

    local tuning = { Acceleration = -10000, TerminalVelocity = -300, Duration = 2 }
    local controller = nil

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        local ability = require(ReplicatedStorage.Content.Ability.LeadFeet)
        if type(ability) == "table" and type(ability.Metadata) == "table" then
            tuning = ability.Metadata
        end
        controller = require(ReplicatedStorage.Packages.Knit).GetController("GameController")
        if controller then
            controller.IsBusy:set(false)
        end
        require(ReplicatedStorage.Content.Effect):Play("LeadFeetFX")({ Player = LocalPlayer })
        require(game:GetService("ReplicatedFirst").Controllers.GameController.Actions.Move.Jump).stop()
        if controller then
            controller.IsBusy:set(true)
        end
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end

    if leadFeetLink then
        REGISTRY.disconnect(leadFeetLink)
        leadFeetLink = nil
    end

    local expiry = os.clock() + (tuning.Duration or 2)
    leadFeetLink = REGISTRY.bind(RunService.Heartbeat, function(delta)
        if not root.Parent or humanoid.FloorMaterial ~= Enum.Material.Air or os.clock() >= expiry then
            if controller then
                controller.IsBusy:set(false)
            end
            if leadFeetLink then
                REGISTRY.disconnect(leadFeetLink)
                leadFeetLink = nil
            end
            return
        end
        local velocity = root.AssemblyLinearVelocity
        local drop = math.max(velocity.Y + (tuning.Acceleration or -10000) * delta, tuning.TerminalVelocity or -300)
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, drop, velocity.Z)
    end)
end

local function createLeadFeetButton()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = MARK
    hidegui(screenGui)
    REGISTRY.registerGui(screenGui)
    screenGui.ResetOnSpawn = false
    leadFeetButton = Instance.new("TextButton")
    leadFeetButton.Size = UDim2.new(0, 50, 0, 50)
    leadFeetButton.Position = UDim2.new(0.25, -25, 0.8, -25)
    leadFeetButton.BackgroundColor3 = Color3.fromRGB(0, 255, 200)
    leadFeetButton.Text = "LF"
    leadFeetButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    leadFeetButton.TextScaled = true
    leadFeetButton.Font = Enum.Font.GothamBold
    leadFeetButton.Parent = screenGui
    leadFeetButton.BackgroundTransparency = 0.2
    leadFeetButton.BorderSizePixel = 0
    leadFeetButton.Selectable = false
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = leadFeetButton
    local dragging = false
    local dragStart = nil
    local startPos = nil
    leadFeetButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = leadFeetButton.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    leadFeetButton.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            leadFeetButton.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
        end
    end)
    leadFeetButton.MouseButton1Click:Connect(leadFeetSlam)
    leadFeetButton.Visible = false
    return leadFeetButton
end

createLeadFeetButton()

local function loadJerseys()
    jerseyList = {
        "BlueOnesieJersey", "ClassicJersey", "CursedTournamentTop100Jersey", "CursedTournamentTop1Jersey", "CursedTournamentTop1KJersey", "DragonTuxedoJersey", "NeonJersey", "PajamasJersey", "PastelJersey", "PinkOnesieJersey", "PirateJersey", "RainbowJersey", "RefJersey", "SkeletonJersey", "SkeletonJerseySeason19", "SparkleTimeJersey", "T1TournamentJersey", "TournamentJersey", "TournamentTop100BeachJersey", "TournamentTop10BeachJersey", "TournamentTop1BeachJersey", "TuxedoJersey", "VampireJersey"
    }
    return jerseyList
end

loadJerseys()

local function loadBallSkins()
    ballSkinList = {
        "2026ChocolateEggBall", "2026EasterEggBall", "AcornBall", "AlienBall", "AngelHeadBall", "AngelicBall", "AngryEmojiBall", "AnimeVolleyBall", "ArrowBall", "AuroraBall", "BananaBall", "Basketball", "BeachBall", "BeachGlobeBall", "BlackBall", "BlueAndYellowBall", "BooBall", "BrainBall", "BronzeCannonBall", "BronzeCloverBall", "BronzeCoconutBall", "BronzeEggBall", "BronzeFestivalBall", "BronzeHeartBall", "BronzeOrnamentBall", "BronzeRibcageBall", "BronzeSeashellBall", "BunnyBall", "BunnyEggBall", "CakeBall", "CameraBall", "CandleBall", "CauldronBall", "CelestialOrbBall", "ChocolateBunnyHeadBall", "ChocolateCoveredBall", "ChocolateCoveredNerdBall", "ChocolateEggBall", "ChocolateHeartBall", "ChristmasLightsBall", "ClassicBall", "CloverBall", "ClownBall", "CoalBall", "CoconutBall", "CoralReefBall", "CrabBall", "CrackedBall", "CrackedEasterEggBall", "CraftyBall", "CryoFlareBall", "CursedKrakenEyeBall", "CuteKittyBall", "DarkBatBall", "DecoratedEasterEggBall", "DemonBall", "DevilBall", "DevilHeadBall", "DiamondAcornBall", "DiamondBall", "DiamondCannonBall", "DiamondCloverBall", "DiamondCoconutBall", "DiamondEggBall", "DiamondEyeBall", "DiamondFestivalBall", "DiamondHeartBall", "DiamondRibcageBall", "DiamondSantaBall", "DiamondSeashellBall", "DiamondSnowGlobeBall", "DiamondSnowmanBall", "DiscoBall", "EasterEggBall", "ElectrifiedBall", "EvilEyeBall", "FestivalBall", "FlameBall", "FlowerBall", "FlowerBlossomBall", "FourLeafCloverBall", "Frostball", "GalaxyBall", "GamerBall", "GhostBall", "GiftBall", "GingerbreadBall", "GodBall", "GoldCannonBall", "GoldCoconutBall", "GoldCoinBall", "GoldFestivalBall", "GoldHeartBall", "GoldRibcageBall", "GoldSeashellBall", "GoldenBall", "GoldenClockBall", "GoldenCloverBall", "GoldenDiamondBall", "GoldenEggBall", "GoldenPearlBall", "GoldenSkullBall", "GoldenSnowmanBall", "GoldenStarBall", "GoldenSunEggBall", "GradientBall", "HackerBall", "HamburgerBall", "HauntedBall", "HeadBall", "HeartBall", "HologramBall", "HolyHellBall", "HorseshoeBall", "HourglassBall", "IceCreamBall", "JellyfishBall", "KarasunoBall", "KareemBall", "KoiBall", "Level150Ball", "Level50Ball", "LifebuoyBall", "MagicCrystalBall", "MangoBall", "MechBall", "MoneyBall", "MonkeyBall", "MoonBall", "MoonFireBall", "NebulaBall", "NerdBall", "NewYearsDragonBall", "NinjaBall", "OrnamentBall", "OvergrownCrystalBall", "PaintSplatterBall", "PartyHatBall", "PartySunglassesBall", "PastelSwirlEggBall", "PearlBall", "PhantomBall", "PhoenixBall", "PhonkBall", "PinataBall", "PineappleBall", "PinkBall", "PinkBlossomBall", "PinkFlamingoBall", "PinkSummerHatBall", "PirateHatBall", "PixelBall", "PolyhedralBall", "PotOfGoldBall", "PotionBall", "PumpkinBall", "PurplePhoenixBall", "RainbowBall", "RainbowPrismBall", "RattlingJawBall", "ReaperBall", "RedDragonBall", "RedEyeBall", "RedGreenAndWhiteBall", "ReindeerBall", "RigBall", "RippedBall", "RubberDuckyBall", "SaturnBall", "ScarecrowBall", "ShellBall", "ShinyBunnyEggBall", "ShinyChocolateEggBall", "SilverBall", "SilverCannonBall", "SilverCloverBall", "SilverCoconutBall", "SilverEggBall", "SilverFestivalBall", "SilverHeartBall", "SilverLanternBall", "SilverMikageHeadBall", "SilverRibbonBall", "SilverRibcageBall", "SilverSeashellBall", "SilverTurkeyBall", "SlimeBall", "SnowGlobeBall", "Snowball", "SnowmanBall", "SoccerBall", "SoulBall", "SpikyBall", "SpiritBall", "StainedGlassBall", "SubspaceBall", "SummerHatBall", "SunBall", "SunglassesBall", "SuperSunBall", "TennisBall", "TigerBall", "TimeBall", "TitaniumBall", "TranslucentTurkeyBall", "TrollFaceBall", "TurkeyBall", "TuxedoBall", "UltraFastModeBall", "VIPBall", "ValentineCardBall", "WaterBall", "WhiteEggBall", "WizardHatBall"
    }
    table.sort(ballSkinList)
    return ballSkinList
end

loadBallSkins()

local function applyJersey(id)
    local character = LocalPlayer.Character
    if not character or not character:FindFirstChild("UpperTorso") then
        return false
    end

    local jerseyFolder = ReplicatedStorage:FindFirstChild("Assets")
    jerseyFolder = jerseyFolder and jerseyFolder:FindFirstChild("Jersey")
    if not jerseyFolder then
        return false
    end

    if not seen.__jerseyHook then
        seen.__jerseyHook = REGISTRY.bind(LocalPlayer.CharacterAdded, function(character2)
            pickedTeam = nil
            if character2:WaitForChild("UpperTorso", 10) and autoApplyJersey then
                task.wait(1)
                applyJersey(selectedJersey)
            end
        end)
    end

    local function clearWorn()
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child.Name == "_jerseyInstances"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                child:Destroy()
            end
        end
    end

    if not autoApplyJersey then
        local backup = originals[character]
        if backup then
            clearWorn()
            for _, saved in ipairs(backup) do
                local restored = saved:Clone()
                if restored:IsA("SurfaceGui") then
                    restored.Adornee = character:FindFirstChild("UpperTorso")
                end
                restored.Parent = character
            end
            originals[character] = nil
        end
        pickedTeam = nil
        return true
    end

    if not originals[character] then
        local backup = {}
        for _, child in ipairs(character:GetChildren()) do
            if child.Name == "JerseyFront" or child.Name == "JerseyBack"
                or child:IsA("Clothing") or child:IsA("ShirtGraphic") then
                table.insert(backup, child:Clone())
            end
        end
        originals[character] = backup
    end

    local function resolveTeam()
        local worn = character:FindFirstChildOfClass("Shirt")
        if not worn then
            return nil
        end
        for _, asset in ipairs(jerseyFolder:GetChildren()) do
            for _, team in ipairs(asset:GetChildren()) do
                local shirt = team:FindFirstChild("Shirt")
                if shirt and shirt:IsA("Shirt") and shirt.ShirtTemplate == worn.ShirtTemplate then
                    return team.Name
                end
            end
        end
        return nil
    end

    local loaded, Jersey = pcall(require, ReplicatedStorage.Tools.Jersey)
    if not loaded or type(Jersey) ~= "table" or not Jersey.set then
        return false
    end

    local resolved = resolveTeam()
    if resolved then pickedTeam = resolved end

    local applied, err = pcall(Jersey.set, {
        Player = LocalPlayer,
        Character = character,
        Id = id or selectedJersey,
        TeamName = pickedTeam,
    })
    if not applied then
        warn("[SAGEBAIT] jersey apply failed: " .. tostring(err))
        return false
    end

    pickedTeam = pickedTeam or resolveTeam()
    return true
end

local function sweep()
    local ballFolder = ReplicatedStorage:FindFirstChild("Assets")
    ballFolder = ballFolder and ballFolder:FindFirstChild("Ball")
    if not ballFolder then
        return
    end

    local function strip(model)
        local holder = clones[model]
        if holder then
            holder:Destroy()
            clones[model] = nil
        end
        local saved = originals[model]
        if saved then
            for piece, record in pairs(saved) do
                if piece.Parent then
                    pcall(function()
                        piece[record.field] = record.value
                    end)
                end
            end
            originals[model] = nil
        end
    end

    local function skin(model)
        local driver = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
        local source = ballFolder:FindFirstChild(selectedBallSkin)
        if not driver or not source then
            return
        end

        strip(model)

        local saved = {}
        local function stash(piece, field, value)
            saved[piece] = { field = field, value = piece[field] }
            piece[field] = value
        end
        for _, piece in ipairs(model:GetDescendants()) do
            if piece:IsA("BasePart") then
                if piece.Name ~= MARK then
                    stash(piece, "Transparency", 1)
                end
            elseif piece:IsA("Decal") or piece:IsA("Texture") then
                stash(piece, "Transparency", 1)
            elseif piece:IsA("Trail") or piece:IsA("ParticleEmitter") or piece:IsA("Beam") or piece:IsA("Light") or piece:IsA("Smoke") or piece:IsA("Fire") or piece:IsA("Sparkles") then
                stash(piece, "Enabled", false)
            end
        end
        originals[model] = saved

        local holder = source:Clone()
        holder.Name = MARK2
        holder.Parent = model
        local pieces = {}
        if holder:IsA("BasePart") then
            pieces[#pieces + 1] = holder
        end
        for _, candidate in ipairs(holder:GetDescendants()) do
            if candidate:IsA("BasePart") then
                pieces[#pieces + 1] = candidate
            end
        end

        local anchor = holder:IsA("Model") and holder.PrimaryPart or nil
        if not anchor then
            local bestScore
            for _, candidate in ipairs(pieces) do
                if candidate:IsA("BasePart") then
                    local vol = candidate.Size.X * candidate.Size.Y * candidate.Size.Z
                    local roundish = math.abs(candidate.Size.X - candidate.Size.Y) < 0.5 and math.abs(candidate.Size.Y - candidate.Size.Z) < 0.5
                    local score = vol
                    if candidate:IsA("Part") and candidate.Shape == Enum.PartType.Ball then
                        score = score * 6
                    elseif roundish then
                        score = score * 3
                    end
                    if not bestScore or score > bestScore then
                        bestScore = score
                        anchor = candidate
                    end
                end
            end
        end
        if anchor then
            local offset = holder:GetPivot():ToObjectSpace(anchor.CFrame)
            holder:PivotTo(driver.CFrame * offset:Inverse())
        else
            holder:PivotTo(driver.CFrame)
        end

        for _, part in ipairs(pieces) do
            part.Anchored = false
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Massless = true
            local weld = Instance.new("WeldConstraint")
            weld.Part0 = driver
            weld.Part1 = part
            weld.Parent = part
        end

        clones[model] = holder
    end

    local tracked = {}
    for model in pairs(clones) do
        table.insert(tracked, model)
    end
    for _, model in ipairs(tracked) do
        strip(model)
    end

    if not autoApplyBallSkin then
        return
    end

    for _, model in ipairs(Workspace:GetChildren()) do
        if model:IsA("Model") and model.Name:match("^CLIENT_BALL_") then
            skin(model)
        end
    end

    if not seen.__ballHook then
        seen.__ballHook = REGISTRY.bind(Workspace.ChildAdded, function(child)
            if not autoApplyBallSkin or not child:IsA("Model") or not child.Name:match("^CLIENT_BALL_") then
                return
            end
            task.spawn(function()
                for _ = 1, 40 do
                    if child.PrimaryPart or child:FindFirstChildWhichIsA("BasePart") then
                        break
                    end
                    task.wait(0.05)
                end
                if autoApplyBallSkin and child.Parent then
                    sweep()
                end
            end)
        end)
    end
end

local Kisuki = { enabled = false, hooked = false, charge = 1 }

Kisuki.effect = function(strong)
    local character = LocalPlayer.Character
    if not character or not character.PrimaryPart then return end
    local assets = ReplicatedStorage:FindFirstChild("Assets")
    local effects = assets and assets:FindFirstChild("Effects")
    local module = effects and effects:FindFirstChild("SuperDive")
    if not module then return end

    local restore = getthreadidentity and getthreadidentity()
    if setthreadidentity then
        pcall(setthreadidentity, 2)
    end
    pcall(function()
        task.spawn(require(module), character, { IsStrong = strong })
    end)
    if setthreadidentity and restore then
        pcall(setthreadidentity, restore)
    end
end

Kisuki.install = function()
    if Kisuki.hooked then return end
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, controller = pcall(Knit.GetController, "GameController")
    if not found or type(controller) ~= "table" or type(controller.Dive) ~= "function" then return end

    local passthrough = controller.Dive
    local wrapped = function(self, params, ...)
        if not Kisuki.enabled then
            return passthrough(self, params, ...)
        end

        local blend = math.clamp(Kisuki.charge, 0, 1)
        local styled, special = pcall(require, ReplicatedStorage.Content.Style.Kimiro.Special)
        local tuning = styled and type(special) == "table" and special.Metadata
        if type(tuning) == "table" then
            params = type(params) == "table" and params or {}
            params.MaxForce = tuning.MaxForce
            params.TimeScale = tuning.TimeScale
            params.StretchSpeedFactor = tuning.StretchSpeedFactor
            params.EasingStyle = tuning.EasingStyle
            params.Debounce = tuning.Debounce
            if not params.Target and typeof(tuning.Power) == "NumberRange" then
                local character = LocalPlayer.Character
                local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                local heading = humanoid and humanoid.MoveDirection or Vector3.zero
                if heading.Magnitude < 0.5 and character then
                    heading = character:GetPivot().LookVector
                end
                heading = Vector3.new(heading.X, 0, heading.Z)
                if heading.Magnitude > 0.01 then
                    local reach = tuning.Power.Min + (tuning.Power.Max - tuning.Power.Min) * blend
                    params.Target = heading.Unit * reach
                end
            end
        end

        local outcome = passthrough(self, params, ...)
        if outcome ~= nil then
            Kisuki.effect(blend >= 0.5)
        end
        return outcome
    end
    controller.Dive = wrapped
    REGISTRY.registerCleanup(function()
        if controller.Dive == wrapped then
            controller.Dive = passthrough
        end
        Kisuki.hooked = false
    end)
    Kisuki.hooked = true
end

local Vault = { real = nil, want = {} }

Vault.mark = function(kind, on)
    Vault.want[kind] = on or nil
    -- a second mark while one is still running only flags a re-run, so the want table
    -- is never built from two interleaved passes
    if Vault._busy then
        Vault._dirty = true
        return
    end
    Vault._busy = true
    repeat
        Vault._dirty = false
        local ran, err = pcall(Vault.sync)
        if not ran then
            warn("[SAGEBAIT] vault sync failed: " .. tostring(err))
        end
    until not Vault._dirty
    Vault._busy = false
end

Vault.sync = function()
    if next(Vault.want) ~= nil then
        Vault.wear()
    end

    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Inventory then return end

    local held, current = pcall(function()
        return inventory.Inventory:get()
    end)
    if not held or type(current) ~= "table" then return end

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local session = type(genv.SAGEBAIT_SESSION) == "table" and genv.SAGEBAIT_SESSION or nil

    if not Vault.real then
        local carried = session and session.vault or nil
        if carried and carried.inventory then
            Vault.real = carried.inventory
            Vault.realTitle = carried.title
            Vault.realEquipped = carried.equipped or {}
        else
            local snapshot = {}
            for id, count in pairs(current) do
                snapshot[id] = count
            end
            Vault.real = snapshot
            Vault.realTitle = LocalPlayer:GetAttribute("User_Title")
            local heldWorn, worn = pcall(function()
                return inventory.Equipped:get()
            end)
            local realEquipped = {}
            if heldWorn and type(worn) == "table" then
                for slot, value in pairs(worn) do
                    realEquipped[slot] = value
                end
            end
            Vault.realEquipped = realEquipped
            if session then
                session.vault = {
                    inventory = Vault.real,
                    title = Vault.realTitle,
                    equipped = Vault.realEquipped,
                }
            end
        end
    end

    local wanted = false
    for _ in pairs(Vault.want) do
        wanted = true
        break
    end
    if not wanted then
        pcall(function()
            inventory.Inventory:set(Vault.real)
        end)
        Vault.real = nil
        if session then
            session.vault = nil
        end
        return
    end

    local catalogued, Item = pcall(require, ReplicatedStorage.Content.Item)
    local entities = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    if not catalogued or not entities then return end

    local stocked = {}
    for id, count in pairs(Vault.real) do
        stocked[id] = count
    end
    for _, child in ipairs(entities:GetChildren()) do
        if child:IsA("ModuleScript") and not stocked[child.Name] then
            local read, entry = pcall(require, child)
            if read and type(entry) == "table" and entry.Type then
                for kindName in pairs(Vault.want) do
                    if entry.Type == Item.Type[kindName] then
                        stocked[child.Name] = 1
                        break
                    end
                end
            end
        end
    end
    pcall(function()
        inventory.Inventory:set(stocked)
    end)
end

Vault.typeOf = function(id)
    local module = ReplicatedStorage.Content.Item:FindFirstChild("Entities")
    module = module and module:FindFirstChild(id)
    if not module then return nil end
    local read, entry = pcall(require, module)
    if read and type(entry) == "table" and entry.Type then
        return entry.Type, entry
    end
    return nil
end

Vault.paint = function(kind, id, entry)
    local real = Vault.realEquipped or {}
    if kind == "Title" then
        pcall(function()
            local text = id and ((entry and entry.DisplayName) or id) or Vault.realTitle
            LocalPlayer:SetAttribute("User_Title", text)
        end)
    elseif kind == "ScoreEffect" then
        selectedEffect = id or real.ScoreEffect or "SupernovaScoreEffect"
    elseif kind == "Ball" then
        selectedBallSkin = id or real.Ball or "ClassicBall"
        task.spawn(function()
            pcall(sweep)
        end)
    elseif kind == "Jersey" then
        selectedJersey = id or real.Jersey or "DragonTuxedoJersey"
        pickedTeam = nil
        task.spawn(function()
            pcall(applyJersey, selectedJersey)
        end)
    elseif kind == "PlayerCard" then
        selectedCard = id or real.PlayerCard or "UltimateChampionPlayerCard"
        task.spawn(function()
            pcall(fireCardRemote)
        end)
    end
end

Vault.setSlot = function(kind, id)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if not held or type(worn) ~= "table" then return end
    local dressed = {}
    for slot, value in pairs(worn) do
        dressed[slot] = value
    end
    dressed[kind] = id
    pcall(function()
        inventory.Equipped:set(dressed)
    end)
end

Vault.currentSlot = function(kind)
    local reached, Knit = pcall(require, ReplicatedStorage.Packages.Knit)
    if not reached then return nil end
    local found, inventory = pcall(Knit.GetController, "InventoryController")
    if not found or type(inventory) ~= "table" or not inventory.Equipped then return nil end
    local held, worn = pcall(function()
        return inventory.Equipped:get()
    end)
    if held and type(worn) == "table" then
        return worn[kind]
    end
    return nil
end

Vault.dress = function(id)
    local kind, entry = Vault.typeOf(id)
    if not kind then return false end
    if kind == "Title" or kind == "ScoreEffect" or kind == "Ball" or kind == "Jersey" or kind == "PlayerCard" then
        Vault.paint(kind, id, entry)
    elseif kind ~= "ProfileArt" then
        return false
    end
    Vault.setSlot(kind, id)
    return true
end

Vault.revert = function(kind)
    local realId = Vault.realEquipped and Vault.realEquipped[kind] or nil
    Vault.paint(kind, nil)
    Vault.setSlot(kind, realId)
end

Vault.wear = function()
    if Vault.worn then return end
    if not (getrawmetatable and setreadonly and getnamecallmethod) then return end
    local located, remote = pcall(function()
        return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.InventoryService.RF.Equip
    end)
    if not located or not remote then return end

    Namecall.register("vault_equip", function(self, method, args)
        if self == remote and method == "InvokeServer" then
            local id = args[1]
            if type(id) == "string" and Vault.real then
                local kind, entry = Vault.typeOf(id)
                if not Vault.real[id] then
                    if kind and Vault.currentSlot(kind) == id then
                        Vault.revert(kind)
                        return { replace = true, result = true }
                    end
                    if Vault.dress(id) then
                        return { replace = true, result = true }
                    end
                    -- dress failed: let the real remote through
                elseif kind then
                    Vault.paint(kind, id, entry)
                    if Vault.realEquipped then
                        Vault.realEquipped[kind] = id
                    end
                end
            end
        end
    end)
    Vault.worn = true
end

local effectList = {}
local function loadEffects()
    effectList = {
        "2026ScoreEffect", "AtomicExplosionScoreEffect", "AuroraScoreEffect", "BallPortalScoreEffect", "BananaSlipScoreEffect", "BeachSpiralScoreEffect", "BeachSplashScoreEffect", "BeatOfMadnessScoreEffect", "BinaryScoreEffect", "BlackHoleScoreEffect", "BloodMoonScoreEffect", "BlueHeartScoreEffect", "BotFaceEmojiScoreEffect", "BubbleScoreEffect", "BunnyHopScoreEffect", "CandyCaneScoreEffect", "CandyCrunchScoreEffect", "CannonBallRainScoreEffect", "CauldronSplashScoreEffect", "ChickScoreEffect", "ChocolateBeamScoreEffect", "ChocolateEggHatchingScoreEffect", "ChocolateSpiralScoreEffect", "ChocolateSplashScoreEffect", "CloudburstScoreEffect", "ColonThreeScoreEffect", "ColorfulFireScoreEffect", "CombiningHeartsScoreEffect", "ConfettiBurstScoreEffect", "CookieSplashScoreEffect", "CoolBunnyScoreEffect", "CoralScoreEffect", "CosmicSpiralScoreEffect", "CrabBeamScoreEffect", "CrabScurryScoreEffect", "CryoFlareScoreEffect", "CursedCrateScoreEffect", "CursedScoreEffect", "CyberWaveScoreEffect", "DarkStarScoreEffect", "DiamondScoreEffect", "DivineStrikeScoreEffect", "DynamiteScoreEffect", "EasterBeamScoreEffect", "EasterEggBasketScoreEffect", "EasterSwirlScoreEffect", "EggHatchScoreEffect", "EggMeteorScoreEffect", "EggRainScoreEffect", "ElectricScoreEffect", "EverybodyDanceScoreEffect", "FallingAcornScoreEffect", "FallingAnchorScoreEffect", "FallingAnvilScoreEffect", "FallingPianoScoreEffect", "FishExplosionScoreEffect", "FistSlamScoreEffect", "FlameScoreEffect", "FlamethrowerScoreEffect", "FloppyFishScoreEffect", "FountainScoreEffect", "FourLeafCloverSpiralScoreEffect", "GenieLampScoreEffect", "GhostVortexScoreEffect", "GiantEggDropScoreEffect", "GiantPlayerScoreEffect", "GiantSoccerKickScoreEffect", "GiantTongueScoreEffect", "GlowStickDanceScoreEffect", "GobbleStormScoreEffect", "GoldCoinPopScoreEffect", "GoldScoreEffect", "GoldenConfettiBurstScoreEffect", "GoldenEggPopScoreEffect", "GoldenWaveScoreEffect", "GravyWaveScoreEffect", "GreenEnergyScoreEffect", "GroundCrackScoreEffect", "HakkaScoreEffect", "HeartBeamScoreEffect", "HeartBubbleScoreEffect", "HeartScoreEffect", "HoneyScoreEffect", "IceCreamScoreEffect", "IceScoreEffect", "JohnDoeScoreEffect", "KittySpiralScoreEffect", "KrakenPullScoreEffect", "LaughingScoreEffect", "LavaSplashScoreEffect", "LeafExplosionScoreEffect", "Level100ScoreEffect", "Level200ScoreEffect", "LightShowScoreEffect", "LightningStrikeScoreEffect", "LuckyCloverScoreEffect", "LuckyStrikeScoreEffect", "MagicBurstScoreEffect", "MegaSunbeamScoreEffect", "MetaBlastScoreEffect", "MeteorScoreEffect", "MoneyExplosionScoreEffect", "MoonlightBeamScoreEffect", "MusicNoteStormScoreEffect", "NewYearsWrathScoreEffect", "NinjaStarScoreEffect", "NorthStarScoreEffect", "NukeScoreEffect", "OceanicSpiralScoreEffect", "PalmTreeHammockScoreEffect", "PastelRainbowScoreEffect", "PastelSwirlScoreEffect", "PineappleScoreEffect", "PinkCosmicSpiralScoreEffect", "PinkHeartScoreEffect", "PixelExplosionScoreEffect", "PlayerBubbleScoreEffect", "PlushieScoreEffect", "PotExplosionScoreEffect", "PotionSplashScoreEffect", "PumpkinPieBurstScoreEffect", "PumpkinSmashScoreEffect", "RainbowScoreEffect", "RainbowStarScoreEffect", "RainbowStrikeScoreEffect", "RandomFavoriteScoreEffect", "RankedWinsScoreEffect", "RedDragonScoreEffect", "RosePetalScoreEffect", "SantasWrathScoreEffect", "SeaCreatureExplosionScoreEffect", "Season0ProScoreEffect", "Season10ProScoreEffect", "Season11ProScoreEffect", "Season12ProScoreEffect", "Season13ProScoreEffect", "Season14ProScoreEffect", "Season15ProScoreEffect", "Season16ProScoreEffect", "Season17ProScoreEffect", "Season18ProScoreEffect", "Season19ProScoreEffect", "Season1ProScoreEffect", "Season2ProScoreEffect", "Season3ProScoreEffect", "Season4ProScoreEffect", "Season5ProScoreEffect", "Season6ProScoreEffect", "Season7ProScoreEffect", "Season8ProScoreEffect", "Season9ProScoreEffect", "ShockwaveBlastScoreEffect", "SixSeven2ScoreEffect", "SixSevenScoreEffect", "SkeletonGrabScoreEffect", "SkullScoreEffect", "SlimeSplashScoreEffect", "SnowTornadoScoreEffect", "SpellCasterScoreEffect", "SpiderInfestationScoreEffect", "SpiritExplosionScoreEffect", "SpringSunScoreEffect", "StPatricksBurstScoreEffect", "StormyWaveScoreEffect", "StrobeLightScoreEffect", "SupernovaScoreEffect", "TapDancerScoreEffect", "ThunderstormScoreEffect", "TimeStopperEasterScoreEffect", "TimeStopperScoreEffect", "TongueScoreEffect", "TrampolineScoreEffect", "TreasureChestScoreEffect", "TsunamiScoreEffect", "VioletBeamScoreEffect", "WaterSplashScoreEffect", "WatermelonSmashScoreEffect", "WhirlpoolScoreEffect", "WindBurstScoreEffect", "WolfEmojiScoreEffect", "XDScoreEffect", "XylophoneScoreEffect"
    }
    table.sort(effectList)
    return effectList
end

effectList = loadEffects()

local cardList = {}
local function loadCards()
    cardList = {}
    local ItemEntities = ReplicatedStorage.Content.Item.Entities
    if ItemEntities then
        for _, child in ipairs(ItemEntities:GetChildren()) do
            if child:IsA("ModuleScript") then
                local name = child.Name
                if string.match(name, "Card") or string.match(name, "PlayerCard") then
                    table.insert(cardList, name)
                end
            end
        end
    end
    table.sort(cardList)
    if #cardList == 0 then
        table.insert(cardList, "ContentCreatorPlayerCard")
    end
    return cardList
end

cardList = loadCards()

local function enableHitEffect()
    if hitConnection then return end
    hasFired = false
    isLocalHit = false
    local Remote = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.BallService.RE.HitGround
    REGISTRY.bind(Remote.OnClientEvent, function(...)
        local args = {...}
        local myName = LocalPlayer.Name
        for _, val in pairs(args) do
            if tostring(val) == myName then
                isLocalHit = true
                break
            end
        end
    end)
    local function fireHitRemote(hitPos)
        if hasFired then return end
        if not isLocalHit then return end
        if not hitEffectEnabled then return end
        hasFired = true
        local myUsername = LocalPlayer.Name
        local targetObject = workspace:FindFirstChild(myUsername) or workspace:FindFirstChild("uwuwuwiiwuw6")
        local effectId = selectedEffect
        local hardHit = true
        if effectId == "GroundHit1" or effectId == "GroundHit2" then
            hardHit = effectId == "GroundHit2"
            effectId = nil
        end
        if firesignal then
            firesignal(Remote.OnClientEvent, table.unpack({
                hitPos,
                hardHit,
                false,
                5,
                effectId,
                targetObject,
                Vector3.new(-0.000002088591600113432, 1, -0.000004710930170404026)
            }, 1, 7))
        end
        task.wait(0.5)
        hasFired = false
        isLocalHit = false
    end
    hitConnection = REGISTRY.bind(workspace.ChildAdded, function(child)
        if child.Name == "HitIndicator" then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitConnection2 = REGISTRY.bind(workspace.DescendantAdded, function(child)
        if child.Name == "HitIndicator" and child:IsA("BasePart") then
            if child.Color == Color3.fromRGB(0, 255, 0) then
                fireHitRemote(child.Position)
            end
        end
    end)
    hitRemovedConnection = REGISTRY.bind(workspace.DescendantRemoving, function(child)
        if child.Name == "HitIndicator" then
            hasFired = false
            isLocalHit = false
        end
    end)
end

local function disableHitEffect()
    if hitConnection then
        REGISTRY.disconnect(hitConnection)
        hitConnection = nil
    end
    if hitConnection2 then
        REGISTRY.disconnect(hitConnection2)
        hitConnection2 = nil
    end
    if hitRemovedConnection then
        REGISTRY.disconnect(hitRemovedConnection)
        hitRemovedConnection = nil
    end
    hasFired = false
    isLocalHit = false
end

local function setupCharacter(character)
    local humanoid = character:WaitForChild("Humanoid", 10)
    local rootPart = character:WaitForChild("HumanoidRootPart", 10)
    if not humanoid or not rootPart then return end

    if shiftLockConnection then
        REGISTRY.disconnect(shiftLockConnection)
        shiftLockConnection = nil
    end

    shiftLockConnection = REGISTRY.bind(humanoid:GetPropertyChangedSignal("Jump"), function()
        if humanoid.Jump and (autoShiftLockEnabled or AutoCorner.enabled) then
            task.defer(function()
                local tracked = AutoCorner.enabled and getNearestBall()
                local before = tracked and tracked.Position
                local stamp = os.clock()
                task.wait(0.03)
                if tracked and before and tracked.Parent then
                    AutoCorner.trackBall(tracked, before, os.clock() - stamp)
                end
                local lookVector = AutoCorner.enabled and AutoCorner.facing()
                if not lookVector and autoShiftLockEnabled then
                    lookVector = Vector3.new(Camera.CFrame.LookVector.X, 0, Camera.CFrame.LookVector.Z)
                end
                if lookVector and lookVector.Magnitude > 0 then
                    AutoCorner.steer = lookVector
                    if autoShiftLockEnabled or AutoCorner.enabled then
                        rootPart.CFrame = CFrame.lookAt(rootPart.Position, rootPart.Position + lookVector.Unit)
                        humanoid.AutoRotate = false
                    end
                end
            end)
        else
            humanoid.AutoRotate = false
        end
    end)
end

local function toggleShiftLock(state)
    autoShiftLockEnabled = state
    if not state then
        local char = LocalPlayer.Character
        if char then
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid then
                humanoid.AutoRotate = false
            end
        end
    end
end

if LocalPlayer.Character then
    setupCharacter(LocalPlayer.Character)
end
track(LocalPlayer.CharacterAdded:Connect(setupCharacter))

local function doFakeSpike()
    if not fakeSpikeEnabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if _AC and _AC.PlayAnimation then
        hum.Jump = true
        _AC:PlayAnimation("SpikeJump")

        task.delay(0.28, function()
            _AC:PlayAnimation("Spike")
        end)
    end
end

track(UserInputService.JumpRequest:Connect(function()
    if fakeSpikeEnabled then
        doFakeSpike()
    end
end))

local function startAutoSpin()
    if autoSpinRunning then return end
    autoSpinRunning = true
    coroutine.wrap(function()
        while autoSpin do
            local currentStyle = LocalPlayer.PlayerGui.Interface.Lobby.Styles.TopPanel.DisplayName.Text
            for _, style in ipairs(desiredStyles) do
                if currentStyle == style then
                    autoSpin = false
                    autoSpinRunning = false
                    return
                end
            end
            local args = { [1] = (spinType == "Lucky") }
            local StyleService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.StyleService
            if StyleService then
                local RF = StyleService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
        autoSpinRunning = false
    end)()
end

local function startAutoAbilitySpin()
    if autoAbilitySpinRunning then return end
    autoAbilitySpinRunning = true
    coroutine.wrap(function()
        while autoAbilitySpin do
            local currentAbility = LocalPlayer.PlayerGui.Interface.Lobby.Abilities.TopPanel.DisplayName.Text
            for _, ability in ipairs(desiredAbilities) do
                if currentAbility == ability then
                    autoAbilitySpin = false
                    autoAbilitySpinRunning = false
                    return
                end
            end
            local args = { [1] = (abilitySpinType == "Lucky") }
            local AbilityService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.AbilityService
            if AbilityService then
                local RF = AbilityService:FindFirstChild("RF")
                if RF then
                    local Roll = RF:FindFirstChild("Roll")
                    if Roll then
                        Roll:InvokeServer(unpack(args))
                    end
                end
            end
            task.wait(0)
        end
        autoAbilitySpinRunning = false
    end)()
end

local function enableAntiLag()
    if antilagConnections.job and not antilagConnections.job.cancelled then return end
    local function safeGet(instance, propertyName)
        local reached, value = pcall(function()
            return instance[propertyName]
        end)
        if reached then
            return value
        end
        return nil
    end

    local function safeSet(instance, propertyName, value)
        instance[propertyName] = value
    end

    local function rememberProperty(instance, propertyName)
        if not instance then return end
        local data = changedProperties[instance]
        if not data then
            data = {}
            changedProperties[instance] = data
        end
        if data[propertyName] == nil then
            local current = safeGet(instance, propertyName)
            if current == nil then return false end
            data[propertyName] = current
        end
        return true
    end

    local function rememberAndSet(instance, propertyName, value)
        if not instance then return end
        if not rememberProperty(instance, propertyName) then return end
        safeSet(instance, propertyName, value)
    end

    local function shouldSkip(instance)
        if not instance then return true end
        local character = LocalPlayer.Character
        if character and instance:IsDescendantOf(character) then
            return true
        end
        return false
    end

    local function optimizeInstance(instance)
        if shouldSkip(instance) then return end
        
        if instance:IsA("BasePart") then
            rememberAndSet(instance, "Material", Enum.Material.SmoothPlastic)
            rememberAndSet(instance, "Reflectance", 0)
            rememberAndSet(instance, "CastShadow", false)
            if instance:IsA("MeshPart") then
                rememberAndSet(instance, "RenderFidelity", Enum.RenderFidelity.Performance)
                rememberAndSet(instance, "TextureID", "")
            end
        elseif instance:IsA("Decal") or instance:IsA("Texture") then
            rememberAndSet(instance, "Transparency", 1)
        elseif instance:IsA("ParticleEmitter") or instance:IsA("Trail") or instance:IsA("Beam") or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("PointLight") or instance:IsA("SpotLight") or instance:IsA("SurfaceLight") then
            rememberAndSet(instance, "Enabled", false)
        elseif instance:IsA("SpecialMesh") then
            rememberAndSet(instance, "TextureId", "")
        elseif instance:IsA("SurfaceAppearance") then
            rememberAndSet(instance, "ColorMap", "")
            rememberAndSet(instance, "MetalnessMap", "")
            rememberAndSet(instance, "NormalMap", "")
            rememberAndSet(instance, "RoughnessMap", "")
        end
    end

    local function optimizeLighting()
        rememberAndSet(Lighting, "Technology", Enum.Technology.Compatibility)
        rememberAndSet(Lighting, "GlobalShadows", false)
        rememberAndSet(Lighting, "FogEnd", 1e9)
        rememberAndSet(Lighting, "ShadowSoftness", 0)
        
        for _, effect in ipairs(Lighting:GetChildren()) do
            if effect:IsA("PostEffect") then
                rememberAndSet(effect, "Enabled", false)
            elseif effect:IsA("Atmosphere") then
                rememberAndSet(effect, "Density", 0)
                rememberAndSet(effect, "Haze", 0)
                rememberAndSet(effect, "Glare", 0)
            elseif effect:IsA("Sky") then
                rememberAndSet(effect, "CelestialBodiesShown", false)
                rememberAndSet(effect, "StarCount", 0)
            end
        end
    end

    local function optimizeTerrain()
        local terrain = workspace:FindFirstChildOfClass("Terrain")
        if not terrain then return end
        
        rememberAndSet(terrain, "Decoration", false)
        rememberAndSet(terrain, "WaterWaveSize", 0)
        rememberAndSet(terrain, "WaterWaveSpeed", 0)
        rememberAndSet(terrain, "WaterReflectance", 0)
        rememberAndSet(terrain, "WaterTransparency", 1)
    end

    local function setLowestQuality()
        local rendering = settings().Rendering
        if oldQualityLevel == nil then
            oldQualityLevel = rendering.QualityLevel
        end
        rendering.QualityLevel = Enum.QualityLevel.Level01
        
        local userGameSettings = UserSettings():GetService("UserGameSettings")
        if oldSavedQualityLevel == nil then
            oldSavedQualityLevel = userGameSettings.SavedQualityLevel
        end
        userGameSettings.SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
    end

    setLowestQuality()
    optimizeLighting()
    optimizeTerrain()

    -- Chunked apply: a flat snapshot is taken once, the per-instance work runs in
    -- batches with a yield between them so the UI thread is never blocked.
    local function optimizeChunked(instances, chunkSize, job, onDone)
        task.spawn(function()
            for i = 1, #instances, chunkSize do
                if job.cancelled then return end
                for j = i, math.min(i + chunkSize - 1, #instances) do
                    if job.cancelled then return end
                    pcall(optimizeInstance, instances[j])
                end
                task.wait()
            end
            if not job.cancelled and onDone then
                onDone()
            end
        end)
    end

    local job = { cancelled = false }
    antilagConnections.job = job

    -- connect BEFORE the chunks start, so nothing added during the apply is missed
    local conn = REGISTRY.bind(workspace.DescendantAdded, function(instance)
        if not job.cancelled then
            optimizeInstance(instance)
        end
    end)
    table.insert(antilagConnections, conn)

    local snapshot = workspace:GetDescendants()
    optimizeChunked(snapshot, 200, job, function()
        if antilagConnections.job == job then
            antilagConnections.job = nil
        end
    end)
end

local function disableAntiLag()
    if antilagConnections.job then
        antilagConnections.job.cancelled = true
    end
    for instance, props in pairs(changedProperties) do
        for prop, value in pairs(props) do
            pcall(function()
                instance[prop] = value
            end)
        end
    end
    changedProperties = {}
    
    if oldQualityLevel ~= nil then
        settings().Rendering.QualityLevel = oldQualityLevel
        oldQualityLevel = nil
    end
    
    if oldSavedQualityLevel ~= nil then
        UserSettings():GetService("UserGameSettings").SavedQualityLevel = oldSavedQualityLevel
        oldSavedQualityLevel = nil
    end
    
    for _, conn in ipairs(antilagConnections) do
        if type(conn) == "userdata" or type(conn) == "table" then
            REGISTRY.disconnect(conn)
        end
    end
    antilagConnections = {}
end

-- ============================================================================
-- SECTION 6 — UI CONSTRUCTION
-- Tabs, group boxes, toggles, sliders, dropdowns, key pickers. Every widget
-- pushes into Library.Options / Library.Toggles, which the config system reads.
-- ============================================================================

local Window = Library:CreateWindow({
    Title = "SAGEBAIT",
    Footer = "Volleyball Legends",
    Icon = 76037421850699,
    NotifySide = "Right",
})

local Tabs = {
    Main = Window:AddTab("Main", "user"),
    Character = Window:AddTab("Character", "user"),
    Visuals = Window:AddTab("Visuals", "eye"),
    Misc = Window:AddTab("Misc", "settings"),
    GameJoin = Window:AddTab("Game Join", "gamepad-2"),
    ["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

local UI = {}

UI.LeftGroupBox = Tabs.Main:AddLeftGroupbox("Spike Settings", "crosshair")

UI.LeftGroupBox:AddToggle("redirectspike", {
    Text = "Redirect Spike",
    Tooltip = "Redirect spike to camera direction",
    Default = false,
    Callback = function(Value)
        if Value then
            enableRedirectSpike()
        else
            disableRedirectSpike()
        end
    end,
})

UI.LeftGroupBox:AddToggle("autocorner", {
    Text = "Auto Corner",
    Tooltip = "Aims to the corner sides of the enemy's goal",
    Default = false,
    Callback = function(Value)
        AutoCorner.enabled = Value
        if Value then
            AutoCorner.installAim()
        else
            AutoCorner.removeAim()
        end
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerside", {
    Values = {"Auto", "Left", "Right"},
    Default = "Auto",
    Text = "Corner Side",
    Callback = function(Value)
        AutoCorner.side = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocornerreach", {
    Values = {"All", "Back", "Nearest"},
    Default = "All",
    Text = "Corner Depth",
    Callback = function(Value)
        AutoCorner.reach = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Corner bind"):AddKeyPicker("autocornerbind", {
    Default = "C",
    Mode = "Press",
    Text = "Auto Corner",
    Callback = function()
        local toggle = Toggles.autocorner
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.LeftGroupBox:AddToggle("newspike", {
    Text = "Silent Spike",
    Tooltip = "Spike with no animation or sound",
    Default = false,
    Callback = function(Value)
        newSilentSpikeEnabled = Value
        if newSpikeButton then
            newSpikeButton.Visible = Value
        end
    end,
})

UI.LeftGroupBox:AddLabel("Silent Spike bind"):AddKeyPicker("newspikebind", {
    Default = "R",
    Mode = "Press",
    Text = "Silent Spike",
    Callback = function()
        fireNewSpike()
    end,
})

UI.LeftGroupBox:AddToggle("sanju", {
    Text = "Sanju Tilt",
    Tooltip = "Sanju tilt effect",
    Default = false,
    Callback = function(Value)
        if Value then
            enableSanjuTilt()
        else
            disableSanjuTilt()
        end
    end,
})

UI.LeftGroupBox:AddToggle("maxcharge", {
    Text = "Max Charge Special",
    Tooltip = "Max charge your special",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxCharge()
        else
            disableMaxCharge()
        end
    end,
})

UI.LeftGroupBox:AddToggle("fakespike", {
    Text = "Fake Spike",
    Tooltip = "Auto fake spike when jumping",
    Default = false,
    Callback = function(Value)
        if Value and not (_AC and _AC.PlayAnimation) then
            Library:Notify("Fake Spike unavailable on this client")
            Toggles.fakespike:SetValue(false, true)
            return
        end
        fakeSpikeEnabled = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounter", {
    Text = "Auto Counter",
    Tooltip = "Counters an enemy spike when both of you are at the net",
    Default = false,
    Callback = function(Value)
        AutoCounter.state.enabled = Value
    end,
})

UI.LeftGroupBox:AddDropdown("autocountermove", {
    Values = {"Auto", "Block", "Spike"},
    Default = "Auto",
    Text = "Counter Move",
    Tooltip = "Auto: block while the ball is still on their half, spike once it crosses",
    Callback = function(Value)
        AutoCounter.state.move = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounternetrange", {
    Text = "Counter Net Range",
    Default = 9,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.netRange = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterlateral", {
    Text = "Counter Width",
    Default = 14,
    Min = 4,
    Max = 30,
    Rounding = 1,
    Callback = function(Value)
        AutoCounter.state.lateral = Value
    end,
})

UI.LeftGroupBox:AddSlider("autocounterdelay", {
    Text = "Counter Delay",
    Default = 0.05,
    Min = 0,
    Max = 0.5,
    Rounding = 2,
    Callback = function(Value)
        AutoCounter.state.delay = Value
    end,
})

UI.LeftGroupBox:AddToggle("autocounterjump", {
    Text = "Counter Auto Jump",
    Tooltip = "Jump before the counter, the block hitbox dies the moment you land",
    Default = true,
    Callback = function(Value)
        AutoCounter.state.autoJump = Value
    end,
})

UI.LeftGroupBox:AddLabel("Auto Counter bind"):AddKeyPicker("autocounterbind", {
    Default = "N",
    Mode = "Press",
    Text = "Auto Counter",
    Callback = function()
        local toggle = Toggles.autocounter
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.HitboxGroup = Tabs.Main:AddRightGroupbox("Hitbox Settings", "box")

UI.HitboxGroup:AddToggle("hitboxenable", {
    Text = "Enable Hitbox",
    Tooltip = "Turn Hitbox ON/OFF",
    Default = false,
    Callback = function(Value)
        hitboxEnabled = Value
        if Value then
            updateHitboxes(hitboxScale)
        else
            removeHitboxes()
        end
    end,
})

UI.HitboxGroup:AddSlider("hitboxsize", {
    Text = "Hitbox Size",
    Tooltip = "Reach in studs, the server refuses anything past 20",
    Default = 5,
    Min = 0,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        hitboxScale = Value
        if hitboxEnabled then
            updateHitboxes(Value)
        end
    end,
})

UI.HitboxGroup:AddDropdown("hitboxcolor", {
    Values = {"Invisible", "White", "Green", "Blue", "Red", "Yellow", "Purple", "Orange", "Pink"},
    Default = "Blue",
    Text = "Hitbox Color",
    Callback = function(Value)
        local colors = {
            Invisible = Color3.fromRGB(255, 255, 255),
            White = Color3.fromRGB(255, 255, 255),
            Green = Color3.fromRGB(0, 255, 0),
            Blue = Color3.fromRGB(0, 0, 255),
            Red = Color3.fromRGB(255, 0, 0),
            Yellow = Color3.fromRGB(255, 255, 0),
            Purple = Color3.fromRGB(128, 0, 128),
            Orange = Color3.fromRGB(255, 165, 0),
            Pink = Color3.fromRGB(255, 105, 180)
        }
        local transparencies = {
            Invisible = 1,
            White = 0.3,
            Green = 0.3,
            Blue = 0.3,
            Red = 0.3,
            Yellow = 0.3,
            Purple = 0.3,
            Orange = 0.3,
            Pink = 0.3
        }
        hitboxColor = colors[Value] or Color3.fromRGB(0, 0, 255)
        hitboxTransparency = transparencies[Value] or 0.3
        if hitboxEnabled then
            updateHitboxes(hitboxScale)
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Remove Hitboxes",
    Func = function()
        removeHitboxes()
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Stop Ball",
    Func = function()
        stopBallVisible = not stopBallVisible
        if stopBallButton then
            stopBallButton.Visible = stopBallVisible
        else
            stopBallButton = createStopBallButton()
        end
    end,
})

UI.HitboxGroup:AddButton({
    Text = "Show Aim",
    Func = function()
        aimVisible = not aimVisible
        if aimButton then
            aimButton.Visible = aimVisible
        else
            aimButton = createAimButton()
        end
    end,
})

UI.PerfGroup = Tabs.Main:AddLeftGroupbox("Performance", "gauge")

UI.PerfGroup:AddToggle("antilag", {
    Text = "Anti-Lag",
    Tooltip = "Reduce graphics for better performance",
    Default = false,
    Callback = function(Value)
        if Value then
            enableAntiLag()
        else
            disableAntiLag()
        end
    end,
})

UI.MoveGroup = Tabs.Main:AddRightGroupbox("Movement", "move")

UI.MoveGroup:AddToggle("desync", {
    Text = "Desync",
    Tooltip = "Desync movement",
    Default = false,
    Callback = function(Value)
        if Value then
            enableDesync()
        else
            disableDesync()
        end
    end,
})

UI.MoveGroup:AddToggle("autoreceive", {
    Text = "Auto Receive",
    Tooltip = "Auto receive the ball",
    Default = false,
    Callback = function(Value)
        autoReceiveEnabled = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceiverange", {
    Text = "Receive Range",
    Default = 10,
    Min = 3,
    Max = 20,
    Rounding = 1,
    Callback = function(Value)
        Receive.range = Value
    end,
})

UI.MoveGroup:AddSlider("autoreceivelead", {
    Text = "Receive Lead",
    Default = 0.35,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Receive.lead = Value
    end,
})

UI.MoveGroup:AddLabel("Auto Receive bind"):AddKeyPicker("autoreceivebind", {
    Default = "X",
    Mode = "Press",
    Text = "Auto Receive",
    Callback = function()
        local toggle = Toggles.autoreceive
        if toggle then
            toggle:SetValue(not toggle.Value)
        end
    end,
})

UI.MoveGroup:AddToggle("kisukidive", {
    Text = "Kisuki Dive",
    Tooltip = "Kisuki super dive",
    Default = false,
    Callback = function(Value)
        Kisuki.enabled = Value
        if Value then
            Kisuki.install()
        end
    end,
})

UI.MoveGroup:AddSlider("kisukicharge", {
    Text = "Dive Charge",
    Tooltip = "Lerps Kimiro's real 19.5-45 power range, past 0.5 the FX go strong",
    Default = 1,
    Min = 0,
    Max = 1,
    Rounding = 2,
    Callback = function(Value)
        Kisuki.charge = Value
    end,
})

UI.MoveGroup:AddToggle("akaridash", {
    Text = "Akari Dash",
    Tooltip = "Dash into the ball",
    Default = false,
    Callback = function(Value)
        akariDashEnabled = Value
        if dashButton then
            dashButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Akari Dash bind"):AddKeyPicker("akaridashbind", {
    Default = "F",
    Mode = "Press",
    Text = "Akari Dash",
    Callback = function()
        akariDash()
    end,
})

UI.MoveGroup:AddToggle("leadfeet", {
    Text = "Lead Feet",
    Tooltip = "Slams you down at the ability's own -10000 acceleration",
    Default = false,
    Callback = function(Value)
        leadFeetEnabled = Value
        if leadFeetButton then
            leadFeetButton.Visible = Value
        end
    end,
})

UI.MoveGroup:AddLabel("Lead Feet bind"):AddKeyPicker("leadfeetbind", {
    Default = "G",
    Mode = "Press",
    Text = "Lead Feet",
    Callback = function()
        leadFeetSlam()
    end,
})

UI.MaxServeGroup = Tabs.Main:AddLeftGroupbox("Max Serve", "server")

UI.MaxServeGroup:AddToggle("maxserve", {
    Text = "Max Serve",
    Tooltip = "Max serve power",
    Default = false,
    Callback = function(Value)
        if Value then
            enableMaxServe()
        else
            disableMaxServe()
        end
    end,
})

UI.MaxServeGroup:AddToggle("esp", {
    Text = "Jump ESP",
    Tooltip = "Highlight enemies while they are jumping",
    Default = false,
    Callback = function(Value)
        espJumpEnabled = Value
        espSetEnabled(Value)
    end,
})

UI.DataGroup = Tabs.Main:AddRightGroupbox("Data", "database")

UI.DataGroup:AddButton({
    Text = "Data Rollback",
    Func = function()
        local located, Remote = pcall(function()
            return game:GetService("ReplicatedStorage")
                :WaitForChild("Packages", 5)
                :WaitForChild("_Index", 5)
                :WaitForChild("sleitnick_knit@1.7.0", 5)
                :WaitForChild("knit", 5)
                :WaitForChild("Services", 5)
                :WaitForChild("SettingsService", 5)
                :WaitForChild("RF", 5)
                :WaitForChild("UpdateKeybind", 5)
        end)
        if not located or not Remote then
            Library:Notify("Data Rollback unavailable")
            return
        end
        local invoked = pcall(function()
            Remote:InvokeServer("MouseButton1", true, "Spike\xE2\x80\x8B\x8F")
        end)
        if not invoked then
            Library:Notify("Data Rollback unavailable")
            return
        end
        game:GetService("TeleportService"):Teleport(game.PlaceId)
    end,
})

UI.CharAttrGroup = Tabs.Character:AddLeftGroupbox("Attributes", "sliders-horizontal")

UI.CharAttrGroup:AddInput("divespeed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Dive Speed",
    Placeholder = "0.95",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            num = math.clamp(num, 0.1, 3)
            LocalPlayer:SetAttribute("Multiplier_DiveSpeed", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("jumppower", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Jump Power",
    Placeholder = "1.1",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            num = math.clamp(num, 0.1, 3)
            LocalPlayer:SetAttribute("Multiplier_JumpPower", num)
        end
    end,
})

UI.CharAttrGroup:AddInput("speed", {
    Default = "",
    Numeric = true,
    Finished = true,
    Text = "Speed",
    Placeholder = "0.85",
    Callback = function(Value)
        local num = tonumber(Value)
        if num then
            num = math.clamp(num, 0.1, 3)
            LocalPlayer:SetAttribute("Multiplier_Speed", num)
        end
    end,
})

UI.CharMoveGroup = Tabs.Character:AddRightGroupbox("Movement", "move")

UI.CharMoveGroup:AddToggle("airmove", {
    Text = "Air Movement",
    Tooltip = "Move in the air",
    Default = false,
    Callback = function(Value)
        airMovement = Value
        if Value then
            Scheduler.add("air_movement", airMovementTick, 60)
        else
            Scheduler.remove("air_movement")
            if bodyVelocity then
                bodyVelocity:Destroy()
                bodyVelocity = nil
            end
        end
    end,
})

UI.CharMoveGroup:AddSlider("airspeed", {
    Text = "Air Movement Speed",
    Default = 16,
    Min = 0,
    Max = 100,
    Rounding = 0,
    Callback = function(Value)
        airMovementSpeed = Value
    end,
})

UI.CharMoveGroup:AddToggle("autoshiftlock", {
    Text = "Auto Shift Lock",
    Tooltip = "Auto rotate to camera when jumping",
    Default = false,
    Callback = function(Value)
        toggleShiftLock(Value)
    end,
})

UI.CharMoveGroup:AddToggle("characterlines", {
    Text = "Character Enemy/Team Line",
    Tooltip = "Show colored beams to enemies",
    Default = false,
    Callback = function(Value)
        linesEnabled = Value
        if Value then
            Scheduler.add("lines", linesTick, 30)
        else
            Scheduler.remove("lines")
            for player in pairs(lines) do
                removeLine(player)
            end
        end
    end,
})

UI.CharMoveGroup:AddSlider("linedistance", {
    Text = "Line Distance",
    Default = 50,
    Min = 10,
    Max = 200,
    Rounding = 1,
    Callback = function(Value)
        lineDistance = Value
    end,
})

do
-- Sanity das seleções atuais antes de montar a UI
local function pickVisual(list, wanted)
    for _, entry in ipairs(list) do
        if entry == wanted then return wanted end
    end
    return list[1]
end

selectedEffect   = pickVisual(effectList, selectedEffect)
selectedCard     = pickVisual(cardList, selectedCard)
selectedBallSkin = pickVisual(ballSkinList, selectedBallSkin)
selectedJersey   = pickVisual(jerseyList, selectedJersey)

-- ---------- SCORE EFFECT ----------
UI.VisualScoreGroup = Tabs.Visuals:AddLeftGroupbox("Score Effect", "sparkles")

UI.VisualScoreGroup:AddDropdown("effectselect", {
    Values = effectList,
    Default = selectedEffect,
    Text = "Select Score Effect",
    Callback = function(Value)
        selectedEffect = Value
    end,
})

local scoreEffectToggle
scoreEffectToggle = UI.VisualScoreGroup:AddToggle("scoreeffect", {
    Text = "Score Effect ON",
    Tooltip = "Liga/desliga o efeito de score no hit",
    Default = false,
    Callback = function(Value)
        hitEffectEnabled = Value
        if Value then
            local ok = pcall(enableHitEffect)
            if not ok or not hitConnection then
                hitEffectEnabled = false
                if scoreEffectToggle and scoreEffectToggle.SetValue then
                    scoreEffectToggle:SetValue(false, true)
                end
                Library:Notify("Score effect failed to enable")
                return
            end
            Vault.mark("ScoreEffect", true)
            Vault.setSlot("ScoreEffect", selectedEffect)
        else
            disableHitEffect()
            Vault.mark("ScoreEffect", false)
        end
    end,
})

UI.VisualScoreGroup:AddButton({
    Text = "Apply Score Effect",
    Func = function()
        if not hitEffectEnabled then
            scoreEffectToggle:SetValue(true)
            return
        end
        Vault.mark("ScoreEffect", true)
        Vault.setSlot("ScoreEffect", selectedEffect)
        Library:Notify("Score effect applied: " .. selectedEffect)
    end,
})

-- ---------- PLAYER CARD ----------
UI.PlayerCardGroup = Tabs.Visuals:AddLeftGroupbox("Player Card", "id-card")

UI.PlayerCardGroup:AddDropdown("cardselect", {
    Values = cardList,
    Default = selectedCard,
    Text = "Select Player Card",
    Callback = function(Value)
        selectedCard = Value
    end,
})

UI.PlayerCardGroup:AddButton({
    Text = "Apply Player Card",
    Func = function()
        if not playerCardEnabled then
            playerCardEnabled = true
            pcall(enablePlayerCard)
        end
        Vault.mark("PlayerCard", true)
        Vault.setSlot("PlayerCard", selectedCard)
        task.spawn(function()
            pcall(fireCardRemote)
        end)
        Library:Notify("Player card applied: " .. selectedCard)
    end,
})

UI.PlayerCardGroup:AddToggle("playercard", {
    Text = "PlayerCard Changer",
    Tooltip = "Ativa o replace automático do card quando aparece",
    Default = false,
    Callback = function(Value)
        playerCardEnabled = Value
        if Value then
            enablePlayerCard()
        else
            disablePlayerCard()
        end
        Vault.mark("PlayerCard", Value)
    end,
})

-- ---------- BALL ----------
UI.BallSkinGroup = Tabs.Visuals:AddLeftGroupbox("Ball Changer", "circle")

UI.BallSkinGroup:AddDropdown("ballselect", {
    Values = ballSkinList,
    Default = selectedBallSkin,
    Text = "Select Ball",
    Callback = function(Value)
        selectedBallSkin = Value
    end,
})

UI.BallSkinGroup:AddButton({
    Text = "Apply Ball",
    Func = function()
        autoApplyBallSkin = true
        Vault.mark("Ball", true)
        Vault.setSlot("Ball", selectedBallSkin)
        task.spawn(function()
            pcall(sweep)
        end)
        Library:Notify("Ball applied: " .. selectedBallSkin)
    end,
})

UI.BallSkinGroup:AddToggle("autoapplyball", {
    Text = "Auto Apply Ball",
    Tooltip = "Reaplica automaticamente a skin selecionada",
    Default = false,
    Callback = function(Value)
        autoApplyBallSkin = Value
        sweep()
        Vault.mark("Ball", Value)
    end,
})

-- ---------- JERSEY ----------
UI.JerseyGroup = Tabs.Visuals:AddRightGroupbox("Jersey Changer", "shirt")

UI.JerseyGroup:AddDropdown("jerseyselect", {
    Values = #jerseyList > 0 and jerseyList or {"No Jerseys Found"},
    Default = #jerseyList > 0 and jerseyList[1] or "No Jerseys Found",
    Text = "Select Jersey",
    Callback = function(Value)
        selectedJersey = Value
        pickedTeam = nil
        if autoApplyJersey then
            task.spawn(function()
                pcall(applyJersey, selectedJersey)
            end)
        end
    end,
})

UI.JerseyGroup:AddButton({
    Text = "Apply Jersey",
    Func = function()
        autoApplyJersey = true
        local jerseyToggle = Toggles.autoapplyjersey
        if jerseyToggle and jerseyToggle.SetValue then
            jerseyToggle:SetValue(true, true)
        end
        pickedTeam = nil
        task.spawn(function()
            pcall(applyJersey, selectedJersey)
        end)
        Library:Notify("Jersey applied: " .. selectedJersey)
    end,
})

UI.JerseyGroup:AddToggle("autoapplyjersey", {
    Text = "Auto Apply Jersey",
    Tooltip = "Reaplica automaticamente a jersey selecionada no respawn",
    Default = false,
    Callback = function(Value)
        autoApplyJersey = Value
        applyJersey(selectedJersey)
    end,
})
end


UI.MiscStyleGroup = Tabs.Misc:AddLeftGroupbox("Auto Style Spin", "refresh-cw")

UI.MiscStyleGroup:AddToggle("autostyle", {
    Text = "Auto Style Spin",
    Tooltip = "Auto spin until target style obtained",
    Default = false,
    Callback = function(Value)
        autoSpin = Value
        if Value then
            startAutoSpin()
        end
    end,
})

UI.MiscStyleGroup:AddDropdown("spintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Spin Type",
    Callback = function(Value)
        spinType = Value
    end,
})

UI.MiscStyleGroup:AddInput("targetstyle", {
    Default = "",
    Text = "Target Style (Type manually)",
    Placeholder = "Sanju",
    Callback = function(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscStyleGroup:AddDropdown("stylelist", {
    Values = {
        "Ronin", "Hidari", "Jinko", "Timeskip Hinto", "Timeskip Kyamo",
        "Akuto", "Taichou", "Sanju", "Mikage", "Kazana", "Timeskip Okazu",
        "Kisuki", "Bakuri", "Kyamo", "Okazu", "Hirakumi",
        "Kozai", "Azmei", "Uchikai", "Yokai", "Yogan",
        "Sazuroku", "Kyoshin", "Yomosuke", "Oyatsu", "Tsuchiro",
        "Imaezi", "Tonkura", "Ninyoku", "Hinto", "Hakochi", "Yakisukai", "Sagumi", "Koshoti"
    },
    Default = "Ronin",
    Text = "Style List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetstyle:SetValue(Value)
        desiredStyles = {Value}
    end,
})

UI.MiscAbilityGroup = Tabs.Misc:AddRightGroupbox("Auto Ability Spin", "zap")

UI.MiscAbilityGroup:AddToggle("autoabilityspin", {
    Text = "Auto Ability Spin",
    Tooltip = "Auto spin until target ability obtained",
    Default = false,
    Callback = function(Value)
        autoAbilitySpin = Value
        if Value then
            startAutoAbilitySpin()
        end
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilityspintype", {
    Values = {"Normal", "Lucky"},
    Default = "Normal",
    Text = "Ability Spin Type",
    Callback = function(Value)
        abilitySpinType = Value
    end,
})

UI.MiscAbilityGroup:AddInput("targetability", {
    Default = "",
    Text = "Target Ability (Type manually)",
    Placeholder = "Shield Breaker",
    Callback = function(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscAbilityGroup:AddDropdown("abilitylist", {
    Values = {
        "Shield Breaker", "Magnetic Pull", "Lead Feet", "Extra Touch", "Godly",
        "Redirection Jump", "Curve Spike", "Divine Strength", "Legendary",
        "Steel Block", "Zero Gravity Set", "Rare", "Boom Jump", "Moonball",
        "Common", "Super Sprint", "Team Spirit", "Rolling Thunder"
    },
    Default = "Shield Breaker",
    Text = "Ability List (Select to auto-fill)",
    Callback = function(Value)
        Options.targetability:SetValue(Value)
        desiredAbilities = {Value}
    end,
})

UI.MiscShopGroup = Tabs.Misc:AddLeftGroupbox("Shop", "shopping-bag")

UI.MiscShopGroup:AddButton({
    Text = "Buy Emote",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                pcall(function() Open:InvokeServer("Emote1") end)
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Effect",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                pcall(function() Open:InvokeServer("ScoreEffect1") end)
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Extreme Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                pcall(function() Open:InvokeServer("Extreme") end)
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Medium Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                pcall(function() Open:InvokeServer("Medium") end)
            end
        end
    end,
})

UI.MiscShopGroup:AddButton({
    Text = "Buy Basic Ball",
    Func = function()
        local PackService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PackService.RF
        if PackService then
            local Open = PackService:FindFirstChild("Open")
            if Open then 
                pcall(function() Open:InvokeServer("Basic") end)
            end
        end
    end,
})

UI.MiscClaimGroup = Tabs.Misc:AddRightGroupbox("Claim Rewards", "gift")

UI.MiscClaimGroup:AddButton({
    Text = "Claim Level Rewards",
    Func = function()
        local LevelService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.LevelService
        if LevelService then
            local RF = LevelService:FindFirstChild("RF")
            if RF then
                local ClaimLevelRewards = RF:FindFirstChild("ClaimLevelRewards")
                if ClaimLevelRewards then
                    pcall(function() ClaimLevelRewards:InvokeServer() end)
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Claim Quest Rewards",
    Func = function()
        local QuestService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.QuestService
        if QuestService then
            local RF = QuestService:FindFirstChild("RF")
            if RF then
                local ClaimAll = RF:FindFirstChild("ClaimAll")
                if ClaimAll then
                    pcall(function() ClaimAll:InvokeServer(true) end)
                end
            end
        end
    end,
})

UI.MiscClaimGroup:AddButton({
    Text = "Redeem All Codes",
    Func = function()
        local function fetchNewCodes()
            local success, data = pcall(function()
                return httpGet("https://beebom.com/haikyuu-legends-codes/")
            end)
            if not success or not data then
                return {}
            end
            local newCodes = {}
            local processed = {}
            for line in string.gmatch(data, "[^\n]+") do
                if string.find(line, "(NEW)") then
                    local code = string.match(line, "(%u+[%u%d_]+)")
                    if code and not processed[code] then
                        processed[code] = true
                        table.insert(newCodes, code)
                    end
                end
                if #newCodes >= 3 then
                    break
                end
            end
            return newCodes
        end
        local newCodes = fetchNewCodes()
        if #newCodes > 0 then
            for i, code in pairs(newCodes) do
                local CodeService = ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.CodeService
                if CodeService then
                    local RF = CodeService:FindFirstChild("RF")
                    if RF then
                        local Redeem = RF:FindFirstChild("Redeem")
                        if Redeem then
                            pcall(function() Redeem:InvokeServer(code) end)
                        end
                    end
                end
                task.wait(0.01)
            end
        end
    end,
})

UI.GameJoinGroup = Tabs.GameJoin:AddLeftGroupbox("Game Modes", "gamepad-2")

do
    -- one shared guard path for all Game Join buttons (the RF lookup is resolved on click)
    local function requestJoin(mode, modeName)
        local resolved, PartyService = pcall(function()
            return ReplicatedStorage.Packages._Index["sleitnick_knit@1.7.0"].knit.Services.PartyService
        end)
        if not resolved or not PartyService then
            Library:Notify("Game Join unavailable")
            return
        end
        local RF = PartyService:FindFirstChild("RF")
        if not RF then
            Library:Notify("Game Join unavailable")
            return
        end
        local RequestTeleport = RF:FindFirstChild("RequestTeleport")
        if not RequestTeleport then
            Library:Notify("Game Join unavailable")
            return
        end
        local sent = pcall(function()
            RequestTeleport:InvokeServer(mode)
        end)
        if sent then
            Library:Notify("Joining " .. modeName)
        else
            Library:Notify("Join failed")
        end
    end

    UI.GameJoinGroup:AddButton({
        Text = "Chaos Mode",
        Func = function()
            requestJoin("ChaosMode", "Chaos Mode")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "1v1 Mini Map",
        Func = function()
            requestJoin("OnesMini", "1v1 Mini")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "2v2 Ranked",
        Func = function()
            requestJoin("Twos", "2v2")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "3v3 Ranked",
        Func = function()
            requestJoin("Threes", "3v3")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "4v4 Ranked",
        Func = function()
            requestJoin("Fours", "4v4")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "6v6 Ranked",
        Func = function()
            requestJoin("Sixes", "6v6")
        end,
    })

    UI.GameJoinGroup:AddButton({
        Text = "Training",
        Func = function()
            requestJoin("Training", "Training")
        end,
    })

end

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")

MenuGroup:AddToggle("KeybindMenuOpen", {
    Default = Library.KeybindFrame.Visible,
    Text = "Open Keybind Menu",
    Callback = function(value)
        Library.KeybindFrame.Visible = value
    end,
})

MenuGroup:AddDropdown("NotificationSide", {
    Values = { "Left", "Right" },
    Default = "Right",
    Text = "Notification Side",
    Callback = function(Value)
        Library:SetNotifySide(Value)
    end,
})

MenuGroup:AddDropdown("DPIDropdown", {
    Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" },
    Default = "100%",
    Text = "DPI Scale",
    Callback = function(Value)
        Value = Value:gsub("%%", "")
        local DPI = tonumber(Value)
        Library:SetDPIScale(DPI)
    end,
})

MenuGroup:AddSlider("UICornerSlider", {
    Text = "Corner Radius",
    Default = Library.CornerRadius,
    Min = 0,
    Max = 20,
    Rounding = 0,
    Callback = function(value)
        Window:SetCornerRadius(value)
    end
})

MenuGroup:AddDivider()
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })

MenuGroup:AddButton("Unload", function()
    Library:Unload()
end)

Library.ToggleKeybind = Options.MenuKeybind

-- ============================================================================
-- SECTION 7 — BOOT
-- Wire the config folder, build the config UI and load the autoload config if any.
-- ============================================================================

Library:SetConfigFolder("SAGEBAIT")
Library:BuildConfigSection(Tabs["UI Settings"])
Library:LoadAutoloadConfig()