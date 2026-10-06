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

local MARK = "achieved tok/s: "

-- Like parse, but while the model still writes, drops a tail that may be the start of the
-- "achieved tok/s" line or of a UTF-8 character, so streamed text only ever grows.
function M.settled(out)
    local text, tps = M.parse(out)
    if tps then
        return text, tps
    end
    for n = math.min(#MARK, #text), 1, -1 do
        if text:sub(-n) == MARK:sub(1, n) then
            text = text:sub(1, -n - 1)
            break
        end
    end
    for i = #text, math.max(1, #text - 3), -1 do
        local b = text:byte(i)
        if b < 0x80 then
            break
        elseif b >= 0xC0 then -- a lead byte: keep it only if its whole character is there
            local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
            if #text - i + 1 < need then
                text = text:sub(1, i - 1)
            end
            break
        end
    end
    return text, nil
end

return M
