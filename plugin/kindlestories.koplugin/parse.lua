-- Pure helpers for llama2.c's run output (no KOReader deps, testable on host).
local M = {}

-- Returns story text and tok/s (number, or nil while still generating).
-- run.c prints "achieved tok/s: X" to stderr right after the last token, no newline.
function M.parse(out)
    local story, tps = out:match("^(.-)%s*achieved tok/s: ([%d%.]+)")
    if story then
        return story, tonumber(tps)
    end
    return out, nil
end

return M
