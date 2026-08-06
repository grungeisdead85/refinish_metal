--@ module = true
-- ==========================================
-- REFINISH STEEL: VALID BASE METAL EVALUATOR (WRAPPER)
-- Purpose: Legacy wrapper to maintain compatibility with other scripts.
-- Forwards the request to the new unified boot scanner.
-- ==========================================

function get_valid_bases(allow_divine, allow_mythical, force_recalc)
    if not _G.refinish_valid_bases or force_recalc then
        reqscript('refinish-boot').run_unified_scan(allow_divine, allow_mythical)
    end
    return _G.refinish_valid_bases
end

return _ENV