-- refinish-module-inject-tool.lua
-- ==========================================
-- TOOL INJECTION
-- ==========================================
-- Injects itemdef_toolst entries into world.raws.itemdefs at runtime,
-- the same way refinish-module-inject.lua injects inorganics.
--
-- Tools are core engine infrastructure, not module property. A module
-- declares tools in its JSON and every other module can reference them
-- by code string, because refinish-module-react.lua already resolves
-- itemdef codes to numeric subtypes by lookup rather than by position.
-- The consumption half was built already. This is the creation half.
--
-- Containers are the first user, but nothing here is container specific.
-- Any tool the schema can describe can be injected, which means reactions
-- can start requiring tools instead of every new capability needing a
-- whole new workshop.
--
-- Load order note: this must run before refinish-module-react.lua builds
-- reagents, because a reagent naming an injected tool needs that tool to
-- already be in the array.
-- ==========================================


-- ==========================================
-- FIELD MAP
-- ==========================================
-- The only place in the tool system that knows itemdef_toolst layout.
-- Left side is the schema key, right side is the struct field.
--
-- CONFIRM THESE BEFORE FIRST RUN. Run refinish-tool-inspect.lua, read
-- refinish_tool_inspect.txt, and correct any right hand value that does
-- not match. Everything below is driven off this table, so a wrong name
-- is a one line fix here rather than a hunt through the file.
--
-- A field listed here that does not exist on the struct is skipped with
-- a log line rather than crashing, so a partly wrong map still injects
-- a usable tool.
-- ==========================================

local FIELD_MAP = {
    name         = "name",
    name_plural  = "name_plural",
    adjective    = "adjective",
    value        = "value",
    tile         = "tile",
    size         = "size",
    material_size = "material_size",
    capacity     = "container_capacity",
}

-- Token flags from item_tool.txt, mapped to members of the flags
-- bitfield. Confirm against step 6 of the inspector output.
local FLAG_MAP = {
    furniture              = "FURNITURE",
    inverted_tile          = "INVERTED_TILE",
    no_default_job         = "NO_DEFAULT_JOB",
    incomplete_item        = "INCOMPLETE_ITEM",
    unimprovable           = "UNIMPROVABLE",
    no_default_improvements = "NO_DEFAULT_IMPROVEMENTS",
    hard_mat               = "HARD_MAT",
    metal_mat              = "METAL_MAT",
    soft_mat               = "SOFT_MAT",
    stone_mat              = "STONE_MAT",
    wood_mat               = "WOOD_MAT",
    sheet_mat              = "SHEET_MAT",
    metal_weapon_mat       = "METAL_WEAPON_MAT",
}


-- ==========================================
-- TOOL USE RESOLUTION
-- ==========================================
-- A TOOL_USE token in the raws is an entry in df.tool_uses. The schema
-- takes the token string, so it resolves through the live enum rather
-- than a hardcoded number table. Numbers shift between DF versions,
-- names do not.
-- ==========================================

local function resolve_tool_use(token)
    local ok, value = pcall(function() return df.tool_uses[token] end)
    if ok and type(value) == "number" then
        return value
    end
    return nil
end


-- ==========================================
-- SAFE FIELD WRITE
-- ==========================================
-- Writing a field that does not exist on a DFHack wrapper throws. Every
-- write is guarded so a field map that is wrong in one place still
-- produces a working tool for every other field.
--
-- Returns true if written, false if the field was missing or refused.
-- ==========================================

local function set_field(struct, field, value, tool_id)
    if value == nil then return false end

    local ok, err = pcall(function() struct[field] = value end)
    if not ok then
        if _G.refinish_log_event then
            _G.refinish_log_event(string.format(
                "TOOL INJECT WARNING: '%s' has no field '%s'. Check FIELD_MAP. (%s)",
                tostring(tool_id), tostring(field), tostring(err)))
        end
        return false
    end
    return true
end


-- ==========================================
-- SUBTYPE CACHE INVALIDATION
-- ==========================================
-- refinish-module-react.lua caches itemdef code to subtype lookups in a
-- module level table built once per session. That is safe while every
-- itemdef comes from raws, because raws never move. It stops being safe
-- the moment tools are injected and cleared across save cycles: the
-- cache would hand out positions for tools that no longer exist, and it
-- would do it silently, because the miss branch only fires when a code
-- is absent from the cache, not when the cached number is stale.
--
-- Same failure shape as the ghost_cache use after free. Called on both
-- ends of every injection and every clear.
-- ==========================================

local function invalidate_subtype_cache()
    -- The react module exposes this if it has been updated. Until then
    -- the global is the handshake, and react checks it before trusting
    -- its own cache.
    _G.refinish_itemdef_cache_dirty = true

    local ok, react = pcall(function() return reqscript('refinish-module-react') end)
    if ok and react and react.invalidate_itemdef_cache then
        pcall(function() react.invalidate_itemdef_cache() end)
    end
end


-- ==========================================
-- OWNERSHIP TEST
-- ==========================================
-- A tool belongs to this engine when its id carries a module prefix.
-- Same predicate shape as rm_owned() for materials, and for the same
-- reason: the clear pass must never touch a vanilla itemdef.
-- ==========================================

local function tool_is_owned(id, prefix)
    if type(id) ~= "string" then return false end
    return id:sub(1, #prefix) == prefix
end


-- ==========================================
-- INJECT
-- ==========================================
-- Builds an itemdef_toolst per definition and appends it to both the
-- tools vector and the all vector.
--
-- Definitions are sorted by key before injection. Non negotiable: pairs()
-- over a table gives hash order, and hash order means a tool lands at a
-- different subtype on every cycle, which breaks every saved item stack
-- that references it. Same rule as materials.
--
-- The id written to the struct is prefix .. key, so MAKING_FUEL_ plus
-- SMALL_BOTTLE gives MAKING_FUEL_SMALL_BOTTLE. Reagents and products
-- name that full string.
--
-- Returns: count injected.
-- ==========================================

function inject_tools(tools, prefix, mod_name)
    if not tools then return 0 end

    local defs = df.global.world.raws.itemdefs.tools
    local all  = df.global.world.raws.itemdefs.all

    -- Stable order. Sort before anything touches the game arrays.
    local sorted = {}
    for _, def in pairs(tools) do
        table.insert(sorted, def)
    end
    table.sort(sorted, function(a, b) return a.key < b.key end)

    local count = 0

    for _, def in ipairs(sorted) do
        local id = prefix .. def.key

        -- Skip anything already present. Re-injecting a live tool would
        -- create a duplicate id and two positions claiming one code.
        local exists = false
        for _, td in ipairs(defs) do
            local ok, existing = pcall(function() return td.id end)
            if ok and existing == id then
                exists = true
                break
            end
        end

        if exists then
            if _G.refinish_log_event then
                _G.refinish_log_event(string.format(
                    "TOOL INJECT: '%s' already present, skipped.", id))
            end
        else
            local t = df.itemdef_toolst:new()

            t.id = id

            -- subtype is the position in the tools vector. Set to the
            -- index this entry is about to occupy, before the insert,
            -- because the insert does not assign it.
            t.subtype = #defs

            -- Scalar fields, all driven off FIELD_MAP.
            for schema_key, field in pairs(FIELD_MAP) do
                set_field(t, field, def[schema_key], id)
            end

            -- Flags. Anything absent from the definition stays at its
            -- constructed default rather than being forced false, because
            -- unlike materials there is no class preset here to restore
            -- a sane baseline afterwards.
            if def.flags then
                for schema_key, flag_name in pairs(FLAG_MAP) do
                    local want = def.flags[schema_key]
                    if want ~= nil then
                        local ok = pcall(function() t.flags[flag_name] = want end)
                        if not ok and _G.refinish_log_event then
                            _G.refinish_log_event(string.format(
                                "TOOL INJECT WARNING: '%s' has no flag '%s'. Check FLAG_MAP.",
                                id, flag_name))
                        end
                    end
                end
            end

            -- Tool uses. Resolved by name through the live enum.
            if def.tool_use then
                for _, token in ipairs(def.tool_use) do
                    local use = resolve_tool_use(token)
                    if use then
                        pcall(function() t.tool_use:insert('#', use) end)
                    elseif _G.refinish_log_event then
                        _G.refinish_log_event(string.format(
                            "TOOL INJECT WARNING: '%s' names unknown TOOL_USE '%s'.",
                            id, tostring(token)))
                    end
                end
            end

            defs:insert('#', t)
            all:insert('#', t)
            count = count + 1
        end
    end

    if count > 0 then
        invalidate_subtype_cache()
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "TOOL INJECT: %d tools injected for %s (prefix %s).",
            count, tostring(mod_name), tostring(prefix)))
    end

    return count
end


-- ==========================================
-- CLEAR
-- ==========================================
-- Removes every owned tool from both vectors, then rewrites the subtype
-- of everything that remains so it matches its new position.
--
-- That rewrite is the whole difficulty. A tool's subtype is its array
-- index, and every item stack in the fort stores that number, so pulling
-- an entry out of the middle silently repoints every stack above it.
-- Injected tools always land at the end, so removing them from the end
-- leaves lower positions untouched, but the loop below does not assume
-- that: it walks backwards and reindexes regardless.
--
-- CALLER OBLIGATION: this must run inside the same save protocol point
-- that clears module materials, and any item instance carrying an owned
-- subtype has to be in the payload before this runs. A save taken with
-- owned tools live in the arrays is the same class of corruption as a
-- save taken with module materials live.
--
-- Returns: count removed.
-- ==========================================

function clear_tools(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    local all  = df.global.world.raws.itemdefs.all

    local count = 0

    -- Backwards, because removing shifts every index above the removal.
    for i = #defs - 1, 0, -1 do
        local ok, id = pcall(function() return defs[i].id end)
        if ok and tool_is_owned(id, prefix) then
            -- Drop from the all vector first, matching by identity of the
            -- id string rather than by object, because DFHack hands back a
            -- fresh wrapper on every access and object comparison fails.
            for j = #all - 1, 0, -1 do
                local ok2, aid = pcall(function() return all[j].id end)
                if ok2 and aid == id then
                    all:erase(j)
                    break
                end
            end

            defs:erase(i)
            count = count + 1
        end
    end

    -- Reindex. Every surviving entry gets a subtype equal to where it
    -- actually sits now.
    for i, td in ipairs(defs) do
        pcall(function() td.subtype = i end)
    end

    if count > 0 then
        invalidate_subtype_cache()
    end

    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "TOOL CLEAR: %d tools removed for prefix %s. %d remain.",
            count, tostring(prefix), #defs))
    end

    return count
end


-- ==========================================
-- PHYSICAL CLEAR CHECK
-- ==========================================
-- Walks the array directly rather than trusting a flag, matching the
-- rule that is already in place for materials. Used by the autosave
-- baseline check and by is_memory_physically_clear().
--
-- Returns true when no owned tool is present.
-- ==========================================

function tools_physically_clear(prefix)
    local defs = df.global.world.raws.itemdefs.tools
    for _, td in ipairs(defs) do
        local ok, id = pcall(function() return td.id end)
        if ok and tool_is_owned(id, prefix) then
            return false
        end
    end
    return true
end


return _ENV
