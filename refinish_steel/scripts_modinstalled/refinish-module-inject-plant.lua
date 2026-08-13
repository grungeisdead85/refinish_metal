--@ module = true
-- refinish-module-inject-plant.lua
-- ==========================================
-- RM MODULE PLANT INJECTION
-- ==========================================
local types = reqscript('refinish-module-types')
local clone_eval = reqscript('refinish-evaluate-clone-source')

local function has_prefix(str, prefix)
    return string.sub(str, 1, #prefix) == prefix
end

-- ==========================================
-- NEUTRAL RESET
-- ==========================================
-- A deep copy of a plant_raw brings over its string anatomy,
-- growth behaviors, and tree metrics. We must scrub the semantic
-- data while leaving the C++ vectors and pointers intact.
local function apply_neutral_reset(plant)
    -- 1. Wipe all bitfield flags (Spring, Biomes, Tree, Mill, etc.)
    for i = 0, #plant.flags - 1 do
        plant.flags[i] = false
    end

    -- 2. Clear anatomical strings
    plant.root_name = ""
    plant.trunk_name = ""
    plant.heavy_branch_name = ""
    plant.light_branch_name = ""
    plant.twig_name = ""
    plant.cap_name = ""

    -- 3. Reset basic tree/shrub metrics
    plant.trunk_period = 0
    plant.heavy_branch_density = 0
    plant.light_branch_density = 0
    plant.max_trunk_height = 0
    plant.heavy_branch_radius = 0
    plant.light_branch_radius = 0
    
    -- 4. General identity wipes
    -- The prefstring vector contains std::string objects, so resizing to 0 is safe.
    plant.prefstring:resize(0) 

    -- ==========================================
    -- NEW: THE DEEP-COPY HAZARDS
    -- ==========================================
    
    -- 5. Sever the Growths Vector (Leaves, Fruit, Flowers, Nuts)
    -- Because assign() shallow-copied the vector of pointers, the clone and 
    -- donor share the same growths. We must clear the vector WITHOUT deleting 
    -- the underlying C++ objects, or we will corrupt the donor plant.
    -- Erasing the vector severs the link safely.
    if plant.growths then
        while #plant.growths > 0 do
            plant.growths:erase(#plant.growths - 1)
        end
    end

    -- 6. Zero out Biome & Spawn Rates
    -- If a donor is highly frequent in the wild, the clone will flood the map.
    plant.frequency = 0
    plant.cluster_size = 0
    plant.underground_depth_min = 0
    plant.underground_depth_max = 0
    
    -- 7. The Raws Vector (Original Raw Text)
    -- DF stores a vector of string pointers representing the raw text used to 
    -- build the item. Like growths, this is shallow-copied. We clear it so 
    -- the clone doesn't echo the donor's raw text in debug dumps.
    if plant.raws then
        while #plant.raws > 0 do
            plant.raws:erase(#plant.raws - 1)
        end
    end
    
    -- NOTE ON INTERNAL MATERIALS (plant.materials)
    -- Do NOT empty the plant.materials vector. DF expects a plant to have 
    -- at least a basic structural material (usually at index 0). If you sever 
    -- the materials vector entirely, the plant will CTD when rendered. 
    -- RM's philosophy here is to let the clone keep the donor's materials 
    -- (e.g., structural, seed, drink) as safe, functional placeholders.
end

-- ==========================================
-- PUBLIC: INJECT PLANTS
-- ==========================================
function inject_plants(plants_defs, prefix, mod_name)
    local raws = df.global.world.raws.plants.all
    local count = 0

    if not plants_defs or #plants_defs == 0 then return 0 end

    for _, pd in ipairs(plants_defs) do
        local full_id = prefix .. pd.key
        
        local donor_class = pd.plant_class or "BASIC_CROP"
        local donor = clone_eval.get_donor('PLANT', donor_class)

        if donor then
            local new_plant = df.plant_raw:new()
            new_plant:assign(donor)
            
            -- Set Identity
            new_plant.id = full_id
            if pd.name then new_plant.name = pd.name end
            if pd.name_plural then new_plant.name_plural = pd.name_plural end
            
            -- WIPE the donor's semantic identity
            apply_neutral_reset(new_plant)

            -- OVERRIDE from schema
            if pd.plant_flags then
                for json_key, state in pairs(pd.plant_flags) do
                    local ok = pcall(function()
                        new_plant.flags[json_key] = state
                    end)
                    if not ok then
                        local err = string.format("[%s] Warning: Invalid plant flag '%s'", mod_name, json_key)
                        if _G.refinish_log_event then _G.refinish_log_event(err) else print(err) end
                    end
                end
            end

            -- Inject into Global Vector
            raws:insert('#', new_plant)
            count = count + 1
        else
            local err = string.format("[%s] Error: No valid plant donor found for class '%s'.", mod_name, donor_class)
            if _G.refinish_log_event then _G.refinish_log_event(err) else print(err) end
        end
    end

    return count
end

-- ==========================================
-- CLEANUP: THE HOTSAVE PROTOCOL
-- ==========================================
function clear_plants(prefix)
    local raws = df.global.world.raws.plants.all
    local count = 0

    for i = #raws - 1, 0, -1 do
        local p = raws[i]
        local ok, id = pcall(function() return p.id end)
        
        if ok and has_prefix(id, prefix) then
            raws:erase(i)
            p:delete()
            count = count + 1
        end
    end
    return count
end

function plants_physically_clear(prefix)
    local raws = df.global.world.raws.plants.all
    for _, p in ipairs(raws) do
        local ok, id = pcall(function() return p.id end)
        if ok and has_prefix(id, prefix) then return false end
    end
    return true
end

return _ENV