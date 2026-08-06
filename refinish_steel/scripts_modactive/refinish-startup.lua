-- refinish-startup.lua
-- ==========================================
-- REFINISH METAL: PIPELINE STARTUP
-- ==========================================
-- Rebuilds the full asset pipeline: sweep -> modules -> scan ->
-- index -> index-reaction -> index-entity -> load (autosave only).
--
-- PROMPT RULES (simple, no flag combinations):
--   No args  = manual invocation (hotkey/console).
--              Show prompts based on msg_setting (DEBUG/GUIDED/PASSIVE).
--   'SILENT' = automatic invocation (boot, autosave, tripwire, config).
--              No prompts ever. Pipeline runs, telemetry is written,
--              caller owns the user-facing output.
--
-- Every step is timed and written to _G.refinish_telemetry.startup
-- regardless of prompt mode. The data is always available for the
-- status panel, log, and debug dump.
-- ==========================================

local RefinishPrompt = reqscript('refinish-prompt').RefinishPrompt
local THEME = reqscript('refinish-theme').get_current_theme()
local utils = require('utils')

local args = {...}
local silent = (args[1] == 'SILENT')

local msg_setting = dfhack.persistent.getSiteData('refinish_config_msg')
if not msg_setting or msg_setting == "" then msg_setting = 'GUIDED' end

-- ==========================================
-- TELEMETRY HELPER
-- ==========================================
-- Writes to _G.refinish_telemetry.startup if the table exists.
-- If it doesn't (e.g. manual console invocation before boot),
-- timing still works locally; just isn't persisted.
-- ==========================================
local function tset(key, value)
    if _G.refinish_telemetry and _G.refinish_telemetry.startup then
        _G.refinish_telemetry.startup[key] = value
    end
end


-- ==========================================
-- PIPELINE EXECUTION
-- ==========================================
-- This is the actual work. Always runs the same way regardless
-- of prompt mode. Returns a table of timing results so the
-- prompt section can read them without touching _G.
-- ==========================================
local function run_pipeline()
    print("==================================================")
    print("REFINISH STEEL: INITIATING STARTUP PIPELINE")
    print("==================================================")
    if _G.refinish_log_event then _G.refinish_log_event("STARTUP: Pipeline initiated (Silent: " .. tostring(silent) .. ").") end

    local startup_clock = os.clock()
    local t = startup_clock

    -- ==========================================
    -- STEP 1: ORPHANED GHOST SWEEPER
    -- ==========================================
    -- After a save/reload, JIT-compiled ghost grinder reactions
    -- may have stale suffixes on their job names. This sweep
    -- strips them back to the base reaction code so the watcher
    -- can re-resolve them cleanly.
    -- ==========================================
    local orphaned_jobs_fixed = 0
    local ok, err = pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.CustomReaction then
                local r_name = tostring(job.reaction_name)
                if string.find(r_name, "^REFINISH_STEEL_RXN_LUA_GRIND_") then
                    local base_name = string.match(r_name, "^(REFINISH_STEEL_RXN_LUA_GRIND_[%a]+)")
                    if base_name and r_name ~= base_name then
                        job.reaction_name = base_name
                        orphaned_jobs_fixed = orphaned_jobs_fixed + 1
                    end
                end
            end
        end
    end)
    if not ok then
        print("Refinish Metal Warning: Failed to sweep orphaned jobs - " .. tostring(err))
        if _G.refinish_log_event then _G.refinish_log_event("STARTUP WARNING: Ghost sweep failed -> " .. tostring(err)) end
    end

    local t_sweep = os.clock() - t
    tset('t_sweep', t_sweep)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Ghost sweep complete (%.3fs); %d orphans fixed.", t_sweep, orphaned_jobs_fixed)) end
    t = os.clock()

    -- ==========================================
    -- STEP 2: MODULE PIPELINE
    -- ==========================================
    dfhack.script_environment('refinish-module-engine').run_module_pipeline()
    local t_modules = os.clock() - t
    tset('t_modules', t_modules)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Module pipeline complete (%.3fs).", t_modules)) end
    t = os.clock()

    -- ==========================================
    -- STEP 3: BLUEPRINT SCAN
    -- ==========================================
    dfhack.run_script('refinish-scan')
    local t_scan = os.clock() - t
    tset('t_scan', t_scan)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Blueprint scan complete (%.3fs).", t_scan)) end
    t = os.clock()

    -- ==========================================
    -- STEP 4: MATERIAL INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index')
    local t_idx_mat = os.clock() - t
    tset('t_idx_mat', t_idx_mat)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Material injection complete (%.3fs).", t_idx_mat)) end
    t = os.clock()

    -- ==========================================
    -- STEP 5: REACTION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-reaction')
    local t_idx_rxn = os.clock() - t
    tset('t_idx_rxn', t_idx_rxn)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Reaction injection complete (%.3fs).", t_idx_rxn)) end
    t = os.clock()

    -- ==========================================
    -- STEP 5.5: MODULE PERMISSION EVALUATION
    -- ==========================================
    -- Runs AFTER boot (civ_tech exists) and AFTER reaction
    -- injection (module reaction indexes are resolved). Evaluates
    -- each module reaction against each civ's capabilities and
    -- metal knowledge, injecting permissions only where both
    -- gates pass. Also registers product metals as known, so
    -- core RM's index-entity (Step 6) can see module metals
    -- when gating Refinish permissions.
    -- ==========================================
    local t_mod_perms = 0
    if _G.refinish_module_registry and next(_G.refinish_module_registry) then
        local mod_perm_eval = dfhack.script_environment('refinish-module-evaluate-permissions')
        local mod_perms = mod_perm_eval.evaluate_and_inject()
        t_mod_perms = os.clock() - t
        tset('t_mod_perms', t_mod_perms)
        if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Module permission evaluation complete (%.3fs); %d permissions.", t_mod_perms, mod_perms)) end
        t = os.clock()
        -- Refresh the metals panel if the HUD is open, so module
        -- product metals appear with correct availability colors.
        if _G.refinish_hud_view then
            local metals_panel = _G.refinish_hud_view.router_left.subviews[2]
            if metals_panel and metals_panel.refresh_list then
                metals_panel:refresh_list()
            end
        end
    end

    -- ==========================================
    -- STEP 6: ENTITY PERMISSION INJECTION
    -- ==========================================
    dfhack.run_script('refinish-index-entity')
    local t_idx_ent = os.clock() - t
    tset('t_idx_ent', t_idx_ent)
    if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Entity injection complete (%.3fs).", t_idx_ent)) end
    t = os.clock()

    -- ==========================================
    -- STEP 7: JSON PAYLOAD RESTORE (Autosave only)
    -- ==========================================
    -- In HOTSAVE mode, items already carry their mat_index on the
    -- objects themselves. RAM restoration is sufficient.
    -- ==========================================
    local save_protocol = dfhack.persistent.getSiteData('refinish_config_save_protocol')
    if not save_protocol or save_protocol == "" then save_protocol = 'AUTOSAVE' end

    -- ==========================================
    -- LEGACY MIGRATION GATE
    -- ==========================================
    -- Detects v3.x -> v3.2 upgrade. Forces a one-time load to
    -- rewrite legacy IDs. See full explanation in previous versions.
    -- ==========================================
    local needs_legacy_load = false
    if save_protocol == 'HOTSAVE' then
        local json_peek = require('json')
        local raw_payload = dfhack.persistent.getSiteData("REFINISH_STEEL_PAYLOAD")
        if raw_payload and raw_payload ~= "" then
            local ok, peeked = pcall(json_peek.decode, raw_payload)
            if ok and peeked then
                local sample = nil
                for _, list_name in ipairs({"items", "buildings", "constructions"}) do
                    if peeked[list_name] and #peeked[list_name] > 0 then
                        sample = peeked[list_name][1].mat
                        break
                    end
                end
                if sample then
                    if string.find(sample, "_MAT_SPECIFIC_") then
                        needs_legacy_load = not string.find(sample, "_MAT_SPECIFIC_STEEL_")
                    elseif string.find(sample, "_MAT_COLOUR_") then
                        needs_legacy_load = not string.match(sample, "_STEEL_MV%d")
                    end
                end
            end
        end
    end

    local t_load = 0
    if save_protocol == 'AUTOSAVE' or needs_legacy_load then
        if needs_legacy_load then
            print("Refinish Metal: Legacy save data detected. Forcing one-time data migration...")
            if _G.refinish_log_event then _G.refinish_log_event("STARTUP: Legacy v3.x payload detected. Forcing migration.") end
        end
        dfhack.run_script('refinish-load')
        t_load = os.clock() - t
        tset('t_load', t_load)
        if _G.refinish_log_event then _G.refinish_log_event(string.format("STARTUP: Payload restore complete (%.3fs).", t_load)) end
    end

    -- ==========================================
    -- FINALIZE TELEMETRY
    -- ==========================================
    local t_total = os.clock() - startup_clock
    tset('t_total', t_total)

    -- Update all asset counts from the freshly built pipeline
    if _G.refinish_telemetry and _G.refinish_telemetry.counts then
        local c = _G.refinish_telemetry.counts
        local function tcount(tbl) if not tbl then return 0 end; local n = 0; for _ in pairs(tbl) do n = n + 1 end; return n end

        -- Blueprint counts
        if _G.refinish_blueprint then
            c.bp_materials = tcount(_G.refinish_blueprint.materials)
            c.bp_reactions = tcount(_G.refinish_blueprint.reactions)
            c.bp_categories = tcount(_G.refinish_blueprint.categories)
        end

        -- Active base metals from config
        local json = require('json')
        local bases_raw = dfhack.persistent.getSiteData('refinish_config_bases')
        if bases_raw and bases_raw ~= "" then
            local ok, bases = pcall(json.decode, bases_raw)
            if ok and bases then c.active_bases = tcount(bases) end
        end

        -- Injection counts: compare live array sizes to baseline.
        -- Baseline was captured during boot (before any RM injection).
        local live_inorganics = #df.global.world.raws.inorganics.all
        local live_reactions = #df.global.world.raws.reactions.reactions
        c.inj_materials = live_inorganics - (c.base_inorganics or live_inorganics)
        c.inj_reactions = live_reactions - (c.base_reactions or live_reactions)

        -- Category count: walk the live array (small, fast)
        local cat_count = 0
        for _, cat in ipairs(df.global.world.raws.reactions.reaction_categories) do
            if string.find(cat.id, "REFINISH_STEEL_CAT_") then cat_count = cat_count + 1 end
        end
        c.inj_categories = cat_count

        -- Permission count: walk the player civ's permitted reactions
        -- to count RM entries. Also count total civs that received perms.
        local perm_count = 0
        local civs_unlocked = 0
        local rm_rxn_indexes = {}
        for _, rxn in ipairs(df.global.world.raws.reactions.reactions) do
            if string.find(rxn.code, "REFINISH_STEEL_") then
                rm_rxn_indexes[rxn.index] = true
            end
        end
        for _, civ in ipairs(df.global.world.entities.all) do
            if civ.type == df.historical_entity_type.Civilization and civ.entity_raw then
                local civ_has_rm = false
                for _, pid in ipairs(civ.entity_raw.workshops.permitted_reaction_id) do
                    if rm_rxn_indexes[pid] then
                        perm_count = perm_count + 1
                        civ_has_rm = true
                    end
                end
                if civ_has_rm then civs_unlocked = civs_unlocked + 1 end
            end
        end
        c.inj_permissions = perm_count
        c.civs_unlocked = civs_unlocked
    end

    -- Log the full summary
    if _G.refinish_log_event then
        _G.refinish_log_event(string.format(
            "STARTUP: Pipeline complete (%.3fs); Sweep:%.3f | Mod:%.3f | Scan:%.3f | Mat:%.3f | Rxn:%.3f | ModPerm:%.3f | Ent:%.3f | Load:%.3f",
            t_total, t_sweep, t_modules, t_scan, t_idx_mat, t_idx_rxn, t_mod_perms, t_idx_ent, t_load
        ))
    end

    print(string.format("Refinish Metal: Pipeline complete (%.3fs). Mod is active.", t_total))
    print("==================================================")

    -- Return timing results for the prompt section to use
    return {
        t_total = t_total, t_sweep = t_sweep, t_modules = t_modules,
        t_scan = t_scan, t_idx_mat = t_idx_mat, t_idx_rxn = t_idx_rxn,
        t_mod_perms = t_mod_perms, t_idx_ent = t_idx_ent, t_load = t_load,
        save_protocol = save_protocol, orphaned_jobs_fixed = orphaned_jobs_fixed
    }
end


-- ==========================================
-- ENTRY POINT
-- ==========================================
-- SILENT: Run pipeline, no prompts, return immediately.
-- Manual: Run pipeline, then show result prompt.
--
-- For manual invocations, run_pipeline() is called directly
-- at the top level of the script; NOT inside a ZScreen
-- callback. This guarantees there is no parent modal on the
-- screen stack when the result prompt fires.
-- ==========================================
if silent then
    -- Automatic invocation: just run, caller owns the output.
    run_pipeline()
    return
end

-- Manual invocation: confirm before running. The pipeline and
-- its result prompt run on the next frame so the confirmation
-- dialog is fully off the screen stack first.
RefinishPrompt{
    text = "Initiate startup?\n\nThis will rebuild all materials, reactions, and entity permissions.",
    text_pen = THEME.PRI,
    on_yes = function()
        -- Deferred: let the confirmation prompt fully dismiss before
        -- the pipeline runs and potentially shows its own result prompt.
        dfhack.timeout(1, 'frames', function()
            local timing = run_pipeline()

            if msg_setting == 'DEBUG' then
                local bp_mats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_materials or 0
                local bp_rxns = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_reactions or 0
                local bp_cats = _G.refinish_telemetry and _G.refinish_telemetry.counts and _G.refinish_telemetry.counts.bp_categories or 0

                local report = string.format(
                    "Startup Pipeline Complete (%.3fs)\n\n" ..
                    "--- PIPELINE TIMING ---\n" ..
                    "Ghost Sweep:      %.3fs\n" ..
                    "Module Pipeline:  %.3fs\n" ..
                    "Blueprint Scan:   %.3fs\n" ..
                    "Index Materials:  %.3fs\n" ..
                    "Index Reactions:  %.3fs\n" ..
                    "Module Perms:     %.3fs\n" ..
                    "Index Entities:   %.3fs\n" ..
                    "Restore Payload:  %.3fs\n\n" ..
                    "--- BLUEPRINT ---\n" ..
                    "Materials: %d  |  Reactions: %d  |  Categories: %d\n" ..
                    "Protocol: %s  |  Orphans Fixed: %d",
                    timing.t_total, timing.t_sweep, timing.t_modules, timing.t_scan,
                    timing.t_idx_mat, timing.t_idx_rxn, timing.t_mod_perms,
                    timing.t_idx_ent, timing.t_load,
                    bp_mats, bp_rxns, bp_cats,
                    timing.save_protocol, timing.orphaned_jobs_fixed
                )
                RefinishPrompt{
                    frame_h = 24,
                    frame_w = 60,
                    text = report,
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'GUIDED' then
                RefinishPrompt{
                    frame_h = 10,
                    text = string.format("Refinish Metal is live. Startup completed in %.2fs.", timing.t_total),
                    on_ok = function() end
                }:show()

            elseif msg_setting == 'PASSIVE' then
                dfhack.gui.showAnnouncement(
                    string.format('Refinish Metal: Startup complete (%.2fs).', timing.t_total),
                    THEME.PRI, true
                )
            end
        end)
    end
}:show()