--@ module = true
-- refinish-session-guard.lua
-- ==========================================
-- EVERY WORLD RUNS ONE VERSION OF RM AND ITS MODULES
-- ==========================================
-- WHAT WENT WRONG, MEASURED (2026-11-13, DFHack 53.17-r1):
--   1. A WORLD THAT TAKES AN UPDATE STAYS ON ITS OLD FOLDER. region1 was
--      saved on RM 4.2.0 and took the update to RM 4.2.1 (numeric 37) as
--      it loaded, not saved since. Its load order then named version 37
--      but the folder data/installed_mods/refinish_steel (36), and
--      dfhack.findScript found every RM script in (36). DFHack takes a
--      world's script folders from that record (script-manager.lua,
--      get_mod_paths), so the world ran RM 4.2.0. With (36) deleted,
--      DFHack fell back to the newest copy's scripts_modinstalled alone,
--      RM could not find refinish-startup (stderr.log) and never started.
--      DF reported another author's mod the same way in that world
--      (flowing_waves: version 13, folder (11)). Whether DF records the
--      new folder once such a world is saved is not yet known; part 1
--      does not depend on it.
--   2. DFHACK KEEPS EVERY HANDLER FOR THE WHOLE SESSION. A handler in
--      dfhack.onStateChange stays until DF closes, whatever world put it
--      there, and at DF start DFHack loads the newest installed RM's
--      scripts_modinstalled. So a world running one RM version also ran the
--      handlers of any other version loaded earlier in the session: RM
--      4.1.6's built-in Stockhook beside RM 4.2's broke the grey group
--      colours (refinish_session.log, 2026-11-13 00:08 session).
--   3. THE OLD GUARD TRUSTED VERSION NUMBERS. It compared the versions in
--      each world's load order, and only for worlds it had itself seen, so
--      it missed both of the above.
--
-- THE FIX, IN TWO PARTS:
--   PART 1, EACH WORLD LOADS THE VERSION IT USES. DFHack's core asks
--      script-manager's get_mod_paths, looked up by name at every call, for
--      a world's script folders at every world load (Core.cpp
--      loadModScriptPaths, through get_mod_script_paths), and
--      getModSourcePath asks the same function for a mod's folder
--      (refinish-module-engine.lua, refinish-core-payload.lua and
--      making_fuel.lua read their data through it). This file wraps that
--      function: for a mod of the family below, a recorded folder that is
--      missing, or that holds another version than the one the world's
--      load order names, is replaced by the folder that holds that version.
--      It wraps get_active_mods the same way, so code that reads a mod's
--      files from the path it reports (Stockhook's definitions,
--      refinish-stockhook-defs.lua sources) reads that folder too. Every
--      other mod, and every call with no world loaded, passes through
--      untouched.
--   PART 2, ONE VERSION PER SESSION, JUDGED BY THE CODE. At every world
--      load the guard reads, for every family handler registered, the
--      folder its function was defined in (debug.getinfo) and that folder's
--      info.txt. A handler from another version of a family mod this world
--      runs means two versions are loaded at once, and the world is held as
--      before: RM never starts in it, the game is kept paused, and the
--      player is told to close DF without saving. So is a world whose RM
--      startup script cannot be found.
--
-- RUNS from DF start: this file is in RM's scripts_modinstalled, and DFHack
-- loads every module script of the newest RM it finds at DF start
-- (script-manager's reload at SC_CORE_INITIALIZED), so both parts are in
-- place before the first world loads. Its handler key and its _G table are
-- new in RM 4.2.2: RM 4.2.0 and 4.2.1 also carry a refinish-session-guard,
-- which loads again whenever a world uses their folder, and it must not
-- replace this one.

local scriptmanager = require('script-manager')

-- ==========================================
-- THE FAMILY
-- ==========================================
-- Mods that run on RM. Part 1 keeps each on the version its world uses;
-- part 2 compares their handlers. IDs as in their info.txt, lower case.
local FAMILY = {
    refinish_steel = true,
    making_fuel = true,
    making_concrete = true,
    stockhook = true,
    metal_library_injected = true,
    argmod_metallurgy_mineralogy_chemistry_glassmaking_injected = true,
    argmod_mythical_materials_injected = true,
    argmod_glass_ceramics_injected = true,
    argmod_desert_sandstones_compatch_injected = true,
}
local RM_ID = 'refinish_steel'

local GUARD_KEY = 'refinish_session_guard_2'

-- ---- HANDLERS HELD BY NAME ----
-- Used only when the debug library cannot say where a handler was defined:
-- RM's master handler and stockpile windows, RM's built-in Stockhook (RM
-- 4.1.x's written by hand, RM 4.2's generated from the standalone), RM
-- 4.2.0 and 4.2.1's guard, and the standalone Stockhook.
local KNOWN_KEYS = {
    refinish_steel_system = 'rm', refinish_stockpile_windows = 'rm',
    stockhook = 'rm', stockhook_install = 'rm', stockhook_defs = 'rm',
    ['refinish_stockhook:core'] = 'rm', ['refinish_stockhook:install'] = 'rm',
    ['refinish_stockhook:defs'] = 'rm', refinish_session_guard = 'rm',
    ['stockhook:core'] = 'stockhook', ['stockhook:install'] = 'stockhook',
    ['stockhook:defs'] = 'stockhook',
}

-- ==========================================
-- THE SESSION
-- ==========================================
-- On _G: one table for every copy of this file loaded this session, kept
-- until DF closes.
--   version      numeric version of the newest copy of this file loaded;
--                an older copy loading later changes nothing
--   real         DFHack's own get_mod_paths, kept once
--   real_active  DFHack's own get_active_mods, kept once
--   fixes        the folders part 1 replaced at the last call, for the log
--   fix_sig      the family's part of the load order the fixes were found
--   fix_cached   for, and those fixes: an unchanged load order is answered
--                from them
--   info         folder -> what its info.txt says
--   found        "<id>#<numeric>" -> the folder holding that version
--   first        the RM version the first RM world ran, numeric and shown
--   holding      this world is held
--   spoilt       a world has been held this session
--   held         key -> { fn, kind } for each handler held
--   placeholder  the do-nothing function put in a held handler's place
--   message      what the prompt tells the player
--   gen          retires the pause loop and the prompt of a world gone
_G.refinish_session_guard_2 = _G.refinish_session_guard_2 or {}
local G = _G.refinish_session_guard_2
G.held = G.held or {}
G.info = G.info or {}
G.found = G.found or {}
G.placeholder = G.placeholder or function() end

-- ==========================================
-- THE LOG
-- ==========================================
-- RM's session log, in its grammar, as every RM file writes it. Nothing is
-- printed: this file answers no typed command.
local rlog = nil
pcall(function() rlog = reqscript('refinish-log') end)

local function log(typ, msg, subject)
    if not _G.refinish_log_event then return end
    local line
    if rlog then
        line = rlog.compose('REFINISH_METAL', 'SESSION_GUARD', subject, typ, msg)
    else
        line = string.format('REFINISH_METAL SESSION_GUARD %s %s | %s',
            tostring(subject or '-'), tostring(typ or 'UNTYPED'), tostring(msg))
    end
    _G.refinish_log_event(line)
end

-- ==========================================
-- READING A MOD FOLDER
-- ==========================================
-- A folder path without the trailing slash, so one folder is one key.
local function trim(path)
    return (tostring(path or ''):gsub('[/\\]+$', ''))
end

-- What a mod folder's info.txt says: { id = lower case ID, numeric,
-- shown = displayed version }, or nil when the folder has no readable
-- info.txt. A folder that has one is kept for the session; a folder that
-- has none is looked at again next time, since DF may make it meanwhile
-- (an update the player takes copies the new version in).
local function read_info(root)
    if not root then return nil end
    root = trim(root)
    local hit = G.info[root]
    if hit then return hit end
    local ok, v = pcall(scriptmanager.get_mod_info_metadata, root,
        { 'ID', 'NUMERIC_VERSION', 'DISPLAYED_VERSION' })
    if not ok or type(v) ~= 'table' or not v.ID or not tonumber(v.NUMERIC_VERSION) then
        return nil
    end
    hit = { id = tostring(v.ID):lower(), numeric = tonumber(v.NUMERIC_VERSION),
            shown = tostring(v.DISPLAYED_VERSION or v.NUMERIC_VERSION) }
    G.info[root] = hit
    return hit
end

-- The mod folder a script file is in: everything before its
-- scripts_modactive or scripts_modinstalled folder. nil for any file
-- outside a mod (DFHack's own scripts, a chunk with no file).
local function root_of_file(path)
    path = (tostring(path or ''):gsub('^@', ''))
    return path:match('^(.-)[/\\]scripts_mod%a+[/\\]')
end

-- Whose a handler is: the info of the mod folder its function was defined
-- in, or nil when that cannot be read.
local function owner_of(fn)
    if not (debug and debug.getinfo) then return nil end
    local ok, i = pcall(debug.getinfo, fn, 'S')
    if not ok or not i then return nil end
    return read_info(root_of_file(i.source))
end

-- ---- THIS COPY ----
-- The folder and version this file was loaded from. Without the debug
-- library, the folder DFHack gives for RM right now, which at DF start is
-- the copy it loads.
local ME_ROOT = nil
if debug and debug.getinfo then
    -- Called directly: through pcall, level 1 would be pcall itself.
    local i = debug.getinfo(1, 'S')
    if i then ME_ROOT = root_of_file(i.source) end
end
if not ME_ROOT then
    local ok, p = pcall(scriptmanager.getModSourcePath, RM_ID)
    if ok and p then ME_ROOT = trim(p) end
end
local ME = read_info(ME_ROOT)

-- ---- THE NEWEST COPY DOES THE WORK ----
-- An older copy of this file loading later in the session (a world on an
-- older RM that already carried it) installs nothing, so the newest logic
-- stays in charge.
local NEWEST = (G.version == nil) or (ME ~= nil and ME.numeric >= G.version)
if NEWEST and ME then G.version = ME.numeric end

-- ==========================================
-- PART 1: EACH WORLD LOADS THE VERSION IT USES
-- ==========================================
local BASE = dfhack.filesystem.getBaseDir()
local INSTALLED = BASE .. 'data/installed_mods/'
-- Where else a version can be, in the order DFHack lets a later copy of
-- one version win (script-manager.lua, MOD_PATH_ROOTS, read backwards).
local ROOTS = { INSTALLED, BASE .. 'mods/', '../../workshop/content/975370/' }

-- The folder holding version numeric of mod id, or nil. DF's own name for
-- an installed copy, "<ID> (<numeric>)", is tried first; then every folder
-- in the three places. A folder found is kept for the session.
local function folder_for(id, numeric)
    local idl = id:lower()
    local key = idl .. '#' .. tostring(numeric)
    local hit = G.found[key]
    if hit and dfhack.filesystem.isdir(hit) then return hit end
    local cand = INSTALLED .. id .. ' (' .. tostring(numeric) .. ')'
    local ci = read_info(cand)
    if ci and ci.id == idl and ci.numeric == numeric then
        G.found[key] = cand
        return cand
    end
    for _, root in ipairs(ROOTS) do
        local ok, files = pcall(dfhack.filesystem.listdir_recursive, root, 0)
        for _, f in ipairs(ok and files or {}) do
            if f.isdir then
                local fi = read_info(f.path)
                if fi and fi.id == idl and fi.numeric == numeric then
                    G.found[key] = trim(f.path)
                    return G.found[key]
                end
            end
        end
    end
    return nil
end

-- The load order as DFHack's own get_active_mods reads it, with each
-- mod's recorded folder: what part 1 judges by, never its own corrections.
local function recorded_mods()
    local real = G.real_active or scriptmanager.get_active_mods
    local ok, mods = pcall(real)
    if ok and type(mods) == 'table' then return mods end
    return nil
end

-- The folders this world needs replaced: family mods in load order mods
-- whose recorded folder is missing or holds another version than the load
-- order names. id (lower case) -> { id, want, from, from_shown, root }. nil
-- when there is nothing to replace, or no world.
--
-- ---- ASKED OFTEN, WORKED OUT ONCE ----
-- get_active_mods is asked at every Stockhook log line and handler, so the
-- answer is kept against the family's part of the load order, and worked
-- out again only when that changes. Not kept when a version could not be
-- found, so a folder DF makes later is still picked up.
local function fixes_for_world(mods)
    if not dfhack.isWorldLoaded() or type(mods) ~= 'table' then return nil end
    local sig = {}
    for _, m in ipairs(mods) do
        local idl = tostring(m.id):lower()
        if FAMILY[idl] and not m.vanilla then
            sig[#sig + 1] = idl .. '=' .. tostring(m.numeric_version) .. '@' .. tostring(m.path)
        end
    end
    sig = table.concat(sig, ';')
    if G.fix_sig == sig then return G.fix_cached end
    local fixes, complete = nil, true
    for _, m in ipairs(mods) do
        local idl = tostring(m.id):lower()
        local want = tonumber(m.numeric_version)
        if FAMILY[idl] and not m.vanilla and want then
            local from = BASE .. tostring(m.path or '')
            local fi = read_info(from)
            if not (fi and fi.id == idl and fi.numeric == want) then
                local root = folder_for(tostring(m.id), want)
                if root then
                    fixes = fixes or {}
                    fixes[idl] = { id = tostring(m.id), want = want, from = trim(from),
                                   from_shown = fi and fi.shown or nil, root = root }
                else
                    complete = false
                end
            end
        end
    end
    if complete then G.fix_sig, G.fix_cached = sig, fixes end
    return fixes
end

-- A replaced folder as get_active_mods reports paths: relative to DFHack's
-- base folder when it is under it ("data/installed_mods/<name>/", as DF
-- records them), else absolute. The workshop folder is named relative to
-- DF's own folder (script-manager.lua, WORKSHOP_MODS_PATH), so it is put
-- under that.
local function as_reported(root)
    if root:sub(1, #BASE) == BASE then return root:sub(#BASE + 1) .. '/' end
    if root:match('^%.%.[/\\]') then return trim(dfhack.getDFPath()) .. '/' .. root .. '/' end
    return root .. '/'
end

-- One mod's entries from folder root, as DFHack's add_mod_paths makes
-- them: the active folder first, and only folders that exist.
local function entries_from(f, installed_subdir, active_subdir, out)
    for _, sub in ipairs({ active_subdir or false, installed_subdir or false }) do
        if sub then
            local p = f.root .. '/' .. sub
            if dfhack.filesystem.isdir(p) then out[#out + 1] = { id = f.id, path = p } end
        end
    end
end

-- DFHack's list with each replaced mod's entries swapped for the right
-- folder's, in the place the first of them held (or at the end when DFHack
-- listed none: a recorded folder that is gone left the mod out).
local function corrected(list, installed_subdir, active_subdir)
    local fixes = fixes_for_world(recorded_mods())
    G.fixes = fixes
    if not fixes then return list end
    local out, placed = {}, {}
    for _, v in ipairs(list) do
        local idl = tostring(v.id):lower()
        local f = fixes[idl]
        if not f then
            out[#out + 1] = v
        elseif not placed[idl] then
            placed[idl] = true
            entries_from(f, installed_subdir, active_subdir, out)
        end
    end
    for idl, f in pairs(fixes) do
        if not placed[idl] then entries_from(f, installed_subdir, active_subdir, out) end
    end
    return out
end

-- The load order with each replaced mod's path set to the folder used.
-- get_active_mods builds a new list at every call, so it is changed in
-- place. Its versions and names are left as DF has them.
local function reported(mods)
    local fixes = fixes_for_world(mods)
    if not fixes then return mods end
    for _, m in ipairs(mods) do
        local f = fixes[tostring(m.id):lower()]
        if f then m.path = as_reported(f.root) end
    end
    return mods
end

-- ---- THE WRAPPERS ----
-- Anything that goes wrong in them hands back DFHack's own answer: a
-- broken wrapper must never cost a world its scripts.
if NEWEST then
    G.real = G.real or scriptmanager.get_mod_paths
    local real = G.real
    scriptmanager.get_mod_paths = function(installed_subdir, active_subdir)
        local list = real(installed_subdir, active_subdir)
        local ok, out = pcall(corrected, list, installed_subdir, active_subdir)
        if ok and type(out) == 'table' then return out end
        return list
    end
    G.real_active = G.real_active or scriptmanager.get_active_mods
    local real_active = G.real_active
    scriptmanager.get_active_mods = function()
        local mods = real_active()
        if type(mods) ~= 'table' then return mods end
        local ok, out = pcall(reported, mods)
        if ok and type(out) == 'table' then return out end
        return mods
    end
end

-- ==========================================
-- PART 2: ONE VERSION PER SESSION
-- ==========================================
-- ---- WHOSE A HANDLER IS ----
-- 'stockhook' for the standalone Stockhook's, 'rm' for the rest of the
-- family's (RM's built-in Stockhook is RM's), nil for any other mod's.
local function kind_of(key, fn)
    local info = owner_of(fn)
    if info then
        if info.id == 'stockhook' then return 'stockhook' end
        if FAMILY[info.id] then return 'rm' end
        return nil
    end
    return KNOWN_KEYS[key]
end

-- ---- HOLDING AND PUTTING BACK ----
-- Every family handler not already held: its function kept, the
-- placeholder put in its place. Only keys already in the table are
-- written, which is safe while DFHack is calling it (Lua's next allows a
-- change to a field that exists). Returns the keys, sorted, for the log.
local function hold_all()
    local P, found = G.placeholder, {}
    for key, fn in pairs(dfhack.onStateChange) do
        if key ~= GUARD_KEY and type(fn) == 'function' and fn ~= P then
            local kind = kind_of(key, fn)
            if kind then found[#found + 1] = { key = key, fn = fn, kind = kind } end
        end
    end
    local names = {}
    for _, h in ipairs(found) do
        G.held[h.key] = { fn = h.fn, kind = h.kind }
        dfhack.onStateChange[h.key] = P
        names[#names + 1] = tostring(h.key)
    end
    table.sort(names)
    return names
end

-- The standalone Stockhook's handlers back at the held world's unload, each
-- where the placeholder still stands, so a world without RM still has
-- Stockhook. The rest of the family stays held until DF restarts: the
-- other version's top levels have already run, and nothing puts the
-- session back as it was. Returns how many.
local function release_stockhook()
    local n, back = 0, {}
    for key, h in pairs(G.held) do
        if h.kind == 'stockhook' then back[#back + 1] = key end
    end
    for _, key in ipairs(back) do
        if dfhack.onStateChange[key] == G.placeholder then
            dfhack.onStateChange[key] = G.held[key].fn
            n = n + 1
        end
        G.held[key] = nil
    end
    return n
end

-- ---- A HELD WORLD: PAUSED, AND THE PLAYER TOLD ----
-- RM's pipeline never runs in a held world, so RM's materials are not in
-- the raws, and DF settles an item's material at its first service, not at
-- load (refinish_steel.lua, DELAYED STARTUP LOGIC: a liquid read as magma
-- burned a fort on unpause). So the world is kept paused every few frames.
-- 'frames' timers outlive a world's unload, so each loop ends when its
-- generation is gone.
local function keep_paused(gen)
    if gen ~= G.gen or not G.holding then return end
    if dfhack.isMapLoaded() and not df.global.pause_state then
        df.global.pause_state = true
    end
    dfhack.timeout(10, 'frames', function() keep_paused(gen) end)
end

-- The fort's own screen, so the prompt is not drawn over a loading screen
-- (refinish_steel.lua, settled_screen, measured the same need).
local function settled()
    local focus = ''
    pcall(function()
        local f = dfhack.gui.getCurFocus()
        if type(f) == 'table' then f = f[1] end
        focus = tostring(f or '')
    end)
    return dfhack.isMapLoaded() and focus:find('^dwarfmode') ~= nil
end

-- The prompt, once the fort is on screen (or after TELL_WAIT frames
-- regardless), in RM's own prompt and Danger colours (_G.refinish_alert,
-- refinish_steel.lua), else DFHack's message box.
local TELL_WAIT = 6000
local function tell(gen, waited)
    if gen ~= G.gen or not G.holding then return end
    if not settled() and waited < TELL_WAIT then
        dfhack.timeout(30, 'frames', function() tell(gen, waited + 30) end)
        return
    end
    local text = G.message or ('Refinish Metal has not started in this world, and the game is'
        .. ' held paused. Close Dwarf Fortress without saving, then start it again and load'
        .. ' this world.')
    local alert, ok = _G.refinish_alert, false
    if type(alert) == 'function' then ok = pcall(alert, text, 'RISK_H', 16) end
    if not ok then
        pcall(function() require('gui.dialogs').showMessage('REFINISH METAL', text, COLOR_RED) end)
    end
end

-- ---- WHAT THIS WORLD RUNS ----
-- Family mods in this world's load order: id (lower case) -> { id, name,
-- numeric }. Then, for each, the info of the folder getModSourcePath gives
-- now, which part 1 has already set right.
local function family_in_world()
    local ok, mods = pcall(scriptmanager.get_active_mods)
    if not ok or type(mods) ~= 'table' then return nil end
    local active = {}
    for _, m in ipairs(mods) do
        local idl = tostring(m.id):lower()
        if FAMILY[idl] and not m.vanilla then
            active[idl] = { id = tostring(m.id), name = tostring(m.name or m.id),
                            numeric = tonumber(m.numeric_version) }
        end
    end
    return active
end

local function running_versions(active)
    local run = {}
    for idl, m in pairs(active) do
        local ok, p = pcall(scriptmanager.getModSourcePath, m.id)
        local info = ok and p and read_info(p) or nil
        if info then
            run[idl] = { numeric = info.numeric, shown = info.shown, root = trim(p) }
        end
    end
    return run
end

-- ---- THE CHECK ----
-- What is wrong with this world, as a list: { what = 'missing' } when RM's
-- startup script cannot be found, and { what = 'mixed', id, this, other,
-- keys } for each other version of a family mod this world runs whose
-- handlers are registered (keys lists them), or for an RM version other
-- than the one the session's first RM world ran. Empty when nothing is.
local function check_world(active, run)
    local problems = {}
    if not dfhack.findScript('refinish-startup') then
        problems[#problems + 1] = { what = 'missing' }
    end
    -- One entry per mod and other version, so the log names each once.
    local mixed = {}
    local function note(id, this, other, key)
        local k = id .. '#' .. tostring(other)
        local p = mixed[k]
        if not p then
            p = { what = 'mixed', id = id, this = this, other = other, keys = {} }
            mixed[k] = p
            problems[#problems + 1] = p
        end
        p.keys[#p.keys + 1] = key
    end
    if debug and debug.getinfo then
        for key, fn in pairs(dfhack.onStateChange) do
            if type(fn) == 'function' and fn ~= G.placeholder then
                local info = owner_of(fn)
                local here = info and active[info.id] and run[info.id]
                if here and info.numeric ~= here.numeric then
                    note(info.id, here.shown, info.shown, tostring(key))
                end
            end
        end
    end
    local rm = run[RM_ID]
    if rm and G.first and rm.numeric ~= G.first then
        note(RM_ID, rm.shown, G.first_shown, '(an earlier world)')
    end
    for _, p in ipairs(problems) do
        if p.keys then table.sort(p.keys) end
    end
    return problems
end

-- ---- WHAT THE PLAYER IS TOLD ----
local function message_for(problems, active)
    for _, p in ipairs(problems) do
        if p.what == 'missing' then
            local v = active[RM_ID] and active[RM_ID].numeric
            return ("Refinish Metal's files for this world (numeric version %s) could not be"
                .. " found, so Refinish Metal has not started in this world, and the game is"
                .. " held paused. Close Dwarf Fortress without saving, make sure Refinish Metal"
                .. " is installed, then start Dwarf Fortress again and load this world.")
                :format(tostring(v or '?'))
        end
    end
    for _, p in ipairs(problems) do
        if p.what == 'mixed' then
            local name = active[p.id] and active[p.id].name or p.id
            return ("This world uses %s %s, but %s %s is already loaded in this session."
                .. " Dwarf Fortress can run only one version of a mod at a time, so Refinish"
                .. " Metal has not started in this world, and the game is held paused. Close"
                .. " Dwarf Fortress without saving, then start it again and load this world. If"
                .. " Dwarf Fortress offers to update a mod as the world loads, accept the update.")
                :format(name, tostring(p.this), name, tostring(p.other))
        end
    end
    return ("Refinish Metal was held in a world loaded earlier in this session, so it stays held"
        .. " until Dwarf Fortress restarts, and the game is held paused. Close Dwarf Fortress"
        .. " without saving, then start it again and load this world.")
end

-- ==========================================
-- THE HANDLER
-- ==========================================
local function on_state(sc)
    if sc == SC_WORLD_LOADED then
        -- Part 1's work at this load, for the log.
        for _, f in pairs(G.fixes or {}) do
            log('INFO', ('%s: this world uses numeric version %d, but Dwarf Fortress recorded'
                .. ' the folder %s (%s); its scripts load from %s instead.'):format(f.id, f.want,
                f.from, f.from_shown and ('version ' .. f.from_shown) or 'missing', f.root),
                'MOD_PATHS')
        end
        local active = family_in_world()
        if not active or not active[RM_ID] then return end
        local run = running_versions(active)
        local problems = check_world(active, run)
        if #problems == 0 and not G.spoilt then
            local rm = run[RM_ID]
            if rm and G.first == nil then G.first, G.first_shown = rm.numeric, rm.shown end
            log('DETAIL', ('this world runs Refinish Metal %s from %s; no other version is'
                .. ' loaded.'):format(rm and rm.shown or '?', rm and rm.root or '?'))
            return
        end
        -- ---- HOLD THIS WORLD ----
        G.message = message_for(problems, active)
        G.spoilt, G.holding = true, true
        G.gen = (G.gen or 0) + 1
        local names = hold_all()
        local why = {}
        for _, p in ipairs(problems) do
            why[#why + 1] = p.what == 'missing' and 'refinish-startup not found'
                or ('%s %s loaded beside the %s this world runs (%s)'):format(p.id,
                    tostring(p.other), tostring(p.this), table.concat(p.keys, ', '))
        end
        log('ERROR', ('this world is held: %s. %d handler(s) held: %s. The game is kept paused'
            .. ' and the player is told to close Dwarf Fortress without saving.'):format(
            #why > 0 and table.concat(why, '; ') or 'a world was held earlier this session',
            #names, table.concat(names, ', ')))
    elseif sc == SC_MAP_LOADED then
        if G.holding then
            local gen = G.gen
            keep_paused(gen)
            tell(gen, 0)
        end
    elseif sc == SC_WORLD_UNLOADED then
        G.fixes = nil
        if G.holding then
            G.holding = false
            G.gen = (G.gen or 0) + 1
            local n = release_stockhook()
            log('INFO', ('the held world unloaded: %d Stockhook handler(s) put back; RM stays'
                .. ' held until Dwarf Fortress restarts.'):format(n))
        end
    end
end

if NEWEST then
    dfhack.onStateChange[GUARD_KEY] = on_state
end