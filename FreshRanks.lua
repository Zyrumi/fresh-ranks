-- Fresh Ranks
-- When you learn a higher rank of a spell, every action bar slot holding your
-- previous best rank gets the new rank. Lower ranks you placed on purpose stay.
-- When you learn a brand-new spell, it goes into the first empty slot on a
-- shown action bar. Nothing else on your bars is ever moved or removed.

local MAX_SLOT = 180          -- highest action slot the client uses
local SETTLE_DELAY = 1.0      -- seconds to wait after learning before acting
local RETRY_DELAY = 1.0       -- seconds between retries
local COMBAT_RECHECK = 5.0    -- safety recheck while waiting for combat to end
local MAX_TRIES = 10          -- give up on one learned spell after this many retries
local KNOWN_TRIES = 3         -- retries waiting for the spell book before acting anyway
local READY_DELAY = 3.0       -- seconds after the first loading screen before we act

local PREFIX = "|cff66ccffFresh Ranks:|r "

-- Action bars in the order new spells should fill them, with the number the
-- game shows for each bar in Edit Mode.
local BARS = {
    { names = { "MainActionBar", "MainMenuBar" }, label = 1 },
    { names = { "MultiBarBottomLeft" }, label = 2 },
    { names = { "MultiBarBottomRight" }, label = 3 },
    { names = { "MultiBarRight" }, label = 4 },
    { names = { "MultiBarLeft" }, label = 5 },
    { names = { "MultiBar5" }, label = 6 },
    { names = { "MultiBar6" }, label = 7 },
    { names = { "MultiBar7" }, label = 8 },
}

local PLAYER_BANK = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
local SPELL_ITEM = (Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell) or 1

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local ready = false      -- false until shortly after login, so login noise is ignored
local seen = {}          -- [spellID] = true once known at login or already handled
local best = {}          -- [spell name] = highest rank we know the player has (0 = no rank)
local pending = {}       -- learned spells waiting to be handled
local pendingByID = {}   -- [spellID] = entry in pending
local timerToken = 0     -- only the newest scheduled flush runs
local waitingForCombat = false
local toldAboutCombat = false
local reportedError = false

---------------------------------------------------------------------------
-- Small helpers (each falls back to the older global API if needed)
---------------------------------------------------------------------------

local function Print(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
    end
end

local function SafeCall(fn, ...)
    if not fn then return false end
    return pcall(fn, ...)
end

local function SpellName(spellID)
    if type(spellID) ~= "number" then return nil end
    local ok, name = SafeCall(C_Spell and C_Spell.GetSpellName, spellID)
    if ok and type(name) == "string" and name ~= "" then return name end
    ok, name = SafeCall(GetSpellInfo, spellID)
    if ok and type(name) == "string" and name ~= "" then return name end
    return nil
end

-- "Rank 3" -> 3. Spells without a rank number return nil.
local function RankFromText(text)
    if type(text) ~= "string" then return nil end
    local n = text:match("(%d+)")
    return n and tonumber(n) or nil
end

local function SpellRank(spellID)
    if type(spellID) ~= "number" then return nil end
    local ok, text = SafeCall((C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext, spellID)
    if ok then return RankFromText(text) end
    return nil
end

local function IsKnown(spellID)
    local ok, known = SafeCall(C_SpellBook and C_SpellBook.IsSpellKnown, spellID)
    if ok and known then return true end
    ok, known = SafeCall(IsSpellKnown, spellID)
    if ok and known then return true end
    return false
end

local function IsPassive(spellID)
    local ok, passive = SafeCall(C_Spell and C_Spell.IsSpellPassive, spellID)
    if ok and passive then return true end
    ok, passive = SafeCall(IsPassiveSpell, spellID)
    return (ok and passive) and true or false
end

local function SlotSpell(slot)
    local ok, actionType, id = pcall(GetActionInfo, slot)
    if ok and actionType == "spell" and type(id) == "number" then
        return id
    end
    return nil
end

local function SlotEmpty(slot)
    local ok, has = pcall(HasAction, slot)
    return ok and not has
end

local function CursorEmpty()
    return GetCursorInfo() == nil
end

local function FindBookSlot(spellID)
    local ok, slot, bank = SafeCall(C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell, spellID)
    if ok and type(slot) == "number" then return slot, bank end
    return nil
end

local function BookItem(slot)
    local ok, info = SafeCall(C_SpellBook and C_SpellBook.GetSpellBookItemInfo, slot, PLAYER_BANK)
    if ok and type(info) == "table" then return info end
    return nil
end

local function SkillLines()
    local lines = {}
    local ok, count = SafeCall(C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines)
    if not ok or type(count) ~= "number" then return lines end
    for line = 1, count do
        local okLine, info = SafeCall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if okLine and type(info) == "table" and info.itemIndexOffset and info.numSpellBookItems then
            lines[#lines + 1] = info
        end
    end
    return lines
end

---------------------------------------------------------------------------
-- Spell book
---------------------------------------------------------------------------

-- Calls fn(info) for every spell in the player's spell book tabs.
local function ForEachBookSpell(fn)
    for _, line in ipairs(SkillLines()) do
        for slot = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
            local info = BookItem(slot)
            if info and info.itemType == SPELL_ITEM and type(info.spellID) == "number" then
                fn(info)
            end
        end
    end
end

local function Remember(name, rank)
    if not name then return end
    rank = rank or 0
    if best[name] == nil or rank > best[name] then
        best[name] = rank
    end
end

-- Records what the player already knows. Runs only while logging in.
local function ScanKnownSpells()
    ForEachBookSpell(function(info)
        local id = info.spellID
        seen[id] = true
        Remember(info.name or SpellName(id), SpellRank(id) or RankFromText(info.subName))
    end)
    -- Spells already on the bars count as known too (covers hidden lower ranks).
    if not InCombatLockdown() then
        for slot = 1, MAX_SLOT do
            local id = SlotSpell(slot)
            if id and IsKnown(id) then
                seen[id] = true
                Remember(SpellName(id), SpellRank(id))
            end
        end
    end
end

-- Book slots that belong to professions (never auto-placed).
local function ProfessionBookSlots()
    local slots = {}
    if not (GetProfessions and GetProfessionInfo) then return slots end
    local ok, a, b, c, d, e, f = pcall(GetProfessions)
    if not ok then return slots end
    for _, index in ipairs({ a or false, b or false, c or false, d or false, e or false, f or false }) do
        if index then
            local okInfo, _, _, _, _, numSpells, spellOffset = pcall(GetProfessionInfo, index)
            if okInfo and type(numSpells) == "number" and type(spellOffset) == "number" then
                for s = spellOffset + 1, spellOffset + numSpells do slots[s] = true end
            end
        end
    end
    return slots
end

-- Returns "ok", "wait" (spell book not updated yet) or "skip" (never place it).
local function CanPlaceNewSpell(spellID)
    local bookSlot, bank = FindBookSlot(spellID)
    if not bookSlot then return "wait" end
    if bank ~= nil and bank ~= PLAYER_BANK then return "skip" end
    local info = BookItem(bookSlot)
    if not info then return "wait" end
    if info.itemType ~= SPELL_ITEM then return "skip" end
    if info.isPassive or info.isOffSpec or IsPassive(spellID) then return "skip" end
    if ProfessionBookSlots()[bookSlot] then return "skip" end
    -- It must sit in a normal, shown spell book tab.
    for _, line in ipairs(SkillLines()) do
        if bookSlot > line.itemIndexOffset and bookSlot <= line.itemIndexOffset + line.numSpellBookItems then
            if line.shouldHide or line.isGuild then return "skip" end
            if line.offSpecID and line.offSpecID ~= 0 then return "skip" end
            return "ok"
        end
    end
    return "skip"
end

---------------------------------------------------------------------------
-- Action bars
---------------------------------------------------------------------------

-- Slots 121-144 belong to vehicle, possess and override bars. Never use them.
local function IsNormalSlot(slot)
    return type(slot) == "number" and slot >= 1 and slot <= MAX_SLOT and (slot <= 120 or slot >= 145)
end

-- Shown, ignoring UIParent so hiding the whole UI (Alt+Z) does not count.
local function IsBarShown(frame)
    local f = frame
    while f and f ~= UIParent do
        if not f:IsShown() then return false end
        f = f.GetParent and f:GetParent() or nil
    end
    return true
end

local function ButtonSlot(button)
    local slot = button.action
    if type(slot) ~= "number" and button.CalculateAction then
        local ok, value = pcall(button.CalculateAction, button)
        if ok then slot = value end
    end
    return slot
end

-- Empty slots the player can see, main bar first. Empty buttons may be hidden
-- when "always show buttons" is off, so we check the bar, not the button.
local function VisibleEmptySlots()
    local result, anyBar = {}, false
    for _, bar in ipairs(BARS) do
        local frame
        for _, name in ipairs(bar.names) do
            local f = _G[name]
            if type(f) == "table" and type(f.actionButtons) == "table" and f.IsShown then
                frame = f
                break
            end
        end
        if frame and IsBarShown(frame) then
            anyBar = true
            local buttons = {}
            for _, button in pairs(frame.actionButtons) do
                if type(button) == "table" then buttons[#buttons + 1] = button end
            end
            table.sort(buttons, function(x, y) return (x.index or 0) < (y.index or 0) end)
            local showable = tonumber(frame.numButtonsShowable) or 12
            for _, button in ipairs(buttons) do
                local index = button.index or 0
                local hidden = button.GetAttribute and button:GetAttribute("statehidden")
                if index >= 1 and index <= showable and not hidden then
                    local slot = ButtonSlot(button)
                    if IsNormalSlot(slot) and SlotEmpty(slot) then
                        result[#result + 1] = { slot = slot, label = bar.label }
                    end
                end
            end
        end
    end
    -- No Blizzard bar shown (a bar addon replaced them): bar 1 is slots 1-12 in
    -- nearly every bar addon.
    if not anyBar then
        for slot = 1, 12 do
            if SlotEmpty(slot) then result[#result + 1] = { slot = slot, label = 1 } end
        end
    end
    return result
end

local function NameOnBars(name)
    for slot = 1, MAX_SLOT do
        local id = SlotSpell(slot)
        if id and SpellName(id) == name then return true end
    end
    return false
end

-- Puts spellID into slot. Whatever the slot held before (the old rank) is
-- removed from the cursor. Returns true if the slot now holds that spell rank.
local function PutSpell(spellID, slot)
    if not CursorEmpty() then return false end
    if C_Spell and C_Spell.PickupSpell then
        pcall(C_Spell.PickupSpell, spellID)
    elseif PickupSpell then
        pcall(PickupSpell, spellID)
    end
    local cursorType, cursorID = GetCursorInfo()
    if cursorType ~= "spell" then
        if cursorType ~= nil then ClearCursor() end
        return false
    end
    -- Only place what we meant to pick up.
    if type(cursorID) == "number" and cursorID ~= spellID and SpellName(cursorID) ~= SpellName(spellID) then
        ClearCursor()
        return false
    end
    PlaceAction(slot)
    ClearCursor()
    local placed = SlotSpell(slot)
    if not placed then return false end
    if placed == spellID then return true end
    return SpellName(placed) == SpellName(spellID) and SpellRank(placed) == SpellRank(spellID)
end

---------------------------------------------------------------------------
-- Handling learned spells
---------------------------------------------------------------------------

local Flush

local function Schedule(delay)
    timerToken = timerToken + 1
    local token = timerToken
    C_Timer.After(delay, function()
        if token == timerToken then Flush() end
    end)
end

local function AddEntry(entry)
    pending[#pending + 1] = entry
    pendingByID[entry.spellID] = entry
end

local function RemoveEntry(entry)
    pendingByID[entry.spellID] = nil
    for i = #pending, 1, -1 do
        if pending[i] == entry then table.remove(pending, i) end
    end
end

-- Counts a failed attempt. Returns true if the entry should be tried again.
local function Retry(entry)
    entry.tries = entry.tries + 1
    if entry.tries >= MAX_TRIES then
        RemoveEntry(entry)
        return false
    end
    return true
end

-- Decide whether a learned spell is a new rank or a new spell.
local function Classify(entry)
    entry.name = entry.name or SpellName(entry.spellID)
    if not entry.name then return end
    entry.rank = entry.rank or SpellRank(entry.spellID)
    if entry.kind then return end
    entry.prev = best[entry.name]
    if entry.prev ~= nil or (entry.rank and entry.rank > 1) then
        entry.kind = "rank"
    else
        entry.kind = "new"
    end
end

-- Upgrade every slot of one spell that holds a replaceable rank.
-- Returns changed, failed (number of slots), or nil if the cursor got busy.
local function UpgradeSlots(name, targetID, targetRank, fromRank)
    local changed, failed = 0, 0
    for slot = 1, MAX_SLOT do
        local id = SlotSpell(slot)
        if id and id ~= targetID and SpellName(id) == name then
            local rank = SpellRank(id)
            if rank and rank < targetRank and rank >= fromRank then
                if not CursorEmpty() then return nil end
                if PutSpell(targetID, slot) then
                    changed = changed + 1
                else
                    failed = failed + 1
                end
            end
        end
    end
    return changed, failed
end

-- Highest rank of this spell below targetRank currently on the bars.
local function HighestRankOnBars(name, targetRank)
    local found
    for slot = 1, MAX_SLOT do
        local id = SlotSpell(slot)
        if id and SpellName(id) == name then
            local rank = SpellRank(id)
            if rank and rank < targetRank and (not found or rank > found) then
                found = rank
            end
        end
    end
    return found
end

-- Returns false if something has to be retried later.
local function HandleRankUps(entries)
    local groups, order = {}, {}
    for _, e in ipairs(entries) do
        local g = groups[e.name]
        if not g then
            g = { entries = {} }
            groups[e.name] = g
            order[#order + 1] = e.name
        end
        g.entries[#g.entries + 1] = e
        if e.prev ~= nil and (g.prev == nil or e.prev < g.prev) then g.prev = e.prev end
        if g.fallback == nil and e.fallback ~= nil then g.fallback = e.fallback end
        if not g.top or e.rank > g.top.rank then g.top = e end
    end

    local allDone = true
    for _, name in ipairs(order) do
        local g = groups[name]
        local top = g.top
        -- Without a remembered previous rank, the best rank that was on the bars
        -- when we first looked counts as previous, so deliberate downranks stay.
        if g.prev == nil and g.fallback == nil then
            g.fallback = HighestRankOnBars(name, top.rank) or false
            for _, e in ipairs(g.entries) do e.fallback = g.fallback end
        end
        local fromRank = g.prev or g.fallback or nil
        local changed, failed = 0, 0
        if fromRank and fromRank < top.rank then
            changed, failed = UpgradeSlots(name, top.spellID, top.rank, fromRank)
            if changed == nil then return false end
        end
        top.done = (top.done or 0) + changed
        local again = false
        if failed > 0 then
            again = Retry(top)
            if again then
                for _, e in ipairs(g.entries) do
                    if e ~= top then e.tries = top.tries end
                end
            end
        end
        if again then
            allDone = false
        else
            for _, e in ipairs(g.entries) do RemoveEntry(e) end
            Remember(name, top.rank)
            if top.done > 0 then
                Print(string.format("%s (Rank %d) is now on %d action %s.",
                    name, top.rank, top.done, top.done == 1 and "button" or "buttons"))
            end
        end
    end
    return allDone
end

-- Returns false if something has to be retried later.
local function HandleNewSpell(entry, freeSlots)
    if NameOnBars(entry.name) then
        RemoveEntry(entry)
        Remember(entry.name, entry.rank)
        return true
    end
    -- Skip slots the player filled since we looked.
    local spot
    while #freeSlots > 0 do
        spot = table.remove(freeSlots, 1)
        if SlotEmpty(spot.slot) then break end
        spot = nil
    end
    if not spot then
        RemoveEntry(entry)
        Remember(entry.name, entry.rank)
        Print(string.format("No empty action bar slot for %s. Drag it from your spellbook (P).", entry.name))
        return true
    end
    if not CursorEmpty() then
        table.insert(freeSlots, 1, spot)
        return false
    end
    if PutSpell(entry.spellID, spot.slot) then
        RemoveEntry(entry)
        Remember(entry.name, entry.rank)
        Print(string.format("%s added to action bar %d.", entry.name, spot.label))
        return true
    end
    if not SlotEmpty(spot.slot) then
        -- Something else landed in that slot. Leave it alone and look for a
        -- free slot again on the next try.
        return not Retry(entry)
    end
    table.insert(freeSlots, 1, spot)
    if not Retry(entry) then Remember(entry.name, entry.rank) return true end
    return false
end

local function FlushNow()
    if #pending == 0 then return end
    if not ready then Schedule(RETRY_DELAY) return end
    if InCombatLockdown() then
        waitingForCombat = true
        if not toldAboutCombat then
            toldAboutCombat = true
            Print("Will update your action bars when combat ends.")
        end
        Schedule(COMBAT_RECHECK)
        return
    end
    if not CursorEmpty() then Schedule(RETRY_DELAY) return end

    local now = GetTime()
    local rankUps, newSpells = {}, {}
    local needRetry = false

    local snapshot = {}
    for i = 1, #pending do snapshot[i] = pending[i] end

    for _, e in ipairs(snapshot) do
        if now < e.due then
            needRetry = true
        else
            Classify(e)
            local knownYet = e.name and (IsKnown(e.spellID) or FindBookSlot(e.spellID) ~= nil)
            if not e.name or (e.kind == "rank" and not e.rank) or (not knownYet and e.tries < KNOWN_TRIES) then
                if Retry(e) then needRetry = true end
            elseif e.kind == "rank" then
                if e.prev ~= nil and e.rank <= e.prev then
                    RemoveEntry(e) -- not an upgrade
                else
                    rankUps[#rankUps + 1] = e
                end
            else
                local verdict = CanPlaceNewSpell(e.spellID)
                if verdict == "ok" then
                    newSpells[#newSpells + 1] = e
                elseif verdict == "wait" then
                    if Retry(e) then needRetry = true end
                else
                    RemoveEntry(e)
                    Remember(e.name, e.rank)
                end
            end
        end
    end

    if #rankUps > 0 and not HandleRankUps(rankUps) then needRetry = true end

    if #newSpells > 0 then
        local freeSlots = VisibleEmptySlots()
        for _, e in ipairs(newSpells) do
            if not HandleNewSpell(e, freeSlots) then needRetry = true end
        end
    end

    if needRetry or #pending > 0 then Schedule(RETRY_DELAY) end
end

Flush = function()
    local ok, err = pcall(FlushNow)
    if not ok then
        -- Never leave a spell stuck on the cursor, and never loop on an error.
        local cursorType = GetCursorInfo()
        if cursorType == "spell" then ClearCursor() end
        pending, pendingByID = {}, {}
        if not reportedError then
            reportedError = true
            Print("Something went wrong, so this change was skipped. Please report: " .. tostring(err))
        end
    end
end

local function OnLearned(spellID, isGuildPerk)
    if not ready or type(spellID) ~= "number" or isGuildPerk then return end
    if seen[spellID] or pendingByID[spellID] then return end
    seen[spellID] = true
    local entry = { spellID = spellID, tries = 0, due = GetTime() + SETTLE_DELAY }
    -- Decide now, before later spell book updates change what we know.
    Classify(entry)
    if entry.kind == "rank" and entry.prev ~= nil and entry.rank and entry.rank <= entry.prev then
        return -- not an upgrade
    end
    AddEntry(entry)
    Schedule(SETTLE_DELAY)
end

-- Backup in case the learn event does not fire: a higher rank of a spell we
-- already know showing up in the spell book counts as learned.
local function CheckBookForNewRanks()
    ForEachBookSpell(function(info)
        local id = info.spellID
        if not seen[id] and not pendingByID[id] then
            local name = info.name or SpellName(id)
            local rank = SpellRank(id) or RankFromText(info.subName)
            if name and rank and best[name] ~= nil and rank > best[name] then
                OnLearned(id, false)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("SPELLS_CHANGED")
frame:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")

local readyScheduled = false

local function OnEvent(event, ...)
    if event == "LEARNED_SPELL_IN_SKILL_LINE" then
        local spellID, _, isGuildPerk = ...
        OnLearned(spellID, isGuildPerk)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if waitingForCombat then
            waitingForCombat = false
            toldAboutCombat = false
            Schedule(0.5)
        end
    elseif ready then
        if event == "SPELLS_CHANGED" then CheckBookForNewRanks() end
    else
        -- Logging in: learn what the player already has.
        ScanKnownSpells()
        if event == "PLAYER_ENTERING_WORLD" and not readyScheduled then
            readyScheduled = true
            C_Timer.After(READY_DELAY, function()
                ScanKnownSpells()
                ready = true
            end)
        end
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    local ok, err = pcall(OnEvent, event, ...)
    if not ok and not reportedError then
        reportedError = true
        Print("Something went wrong. Please report: " .. tostring(err))
    end
end)
