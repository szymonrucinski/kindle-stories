-- Vendored from kindle-ui baee37244b5f7e612fa4aee52bcb108806f7e207:src/lib/markdown.lua by scripts/sync-kit.sh; edit it there, not here.
--[[--
Markdown -> macui.Doc blocks, and inline markdown/LaTeX -> plain text. Pure: no ui/ requires, so it
runs in the specs (tests/unit/markdown_spec.lua) and in any model module. Moved from alphaxiv_api.lua.

Blocks: { kind = "h"|"p"|"li"|"rule"|"code"|"quote", text }. "code" keeps its lines verbatim
(joined by "\n"); everything else is plain text (no inline styles: Doc has one face per block).
--]]

local Markdown = {}

---@param s any
---@return string|nil
function Markdown.squash(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    return s ~= "" and s or nil
end
local squash = Markdown.squash

-- LaTeX inside $…$ made readable on e-ink: \frac{a}{b} -> a/b, font commands dropped, common
-- symbols as Unicode. ponytail: a symbol table, not a TeX parser; rare macros keep their name.
local TEX = {
    cap = "∩",
    cup = "∪",
    sum = "Σ",
    prod = "Π",
    times = "×",
    cdot = "·",
    leq = "≤",
    le = "≤",
    geq = "≥",
    ge = "≥",
    neq = "≠",
    ne = "≠",
    approx = "≈",
    sim = "~",
    ["in"] = "∈",
    infty = "∞",
    to = "→",
    rightarrow = "→",
    leftarrow = "←",
    pm = "±",
    sqrt = "√",
    partial = "∂",
    nabla = "∇",
    ell = "ℓ",
    ldots = "…",
    cdots = "…",
    dots = "…",
    quad = " ",
    qquad = "  ",
    top = "ᵀ",
    alpha = "α",
    beta = "β",
    gamma = "γ",
    delta = "δ",
    Delta = "Δ",
    epsilon = "ε",
    varepsilon = "ε",
    eta = "η",
    theta = "θ",
    lambda = "λ",
    mu = "μ",
    pi = "π",
    rho = "ρ",
    sigma = "σ",
    Sigma = "Σ",
    tau = "τ",
    phi = "φ",
    varphi = "φ",
    chi = "χ",
    psi = "ψ",
    omega = "ω",
    Omega = "Ω",
}
TEX.left, TEX.right, TEX.bigl, TEX.bigr, TEX.big, TEX.Big = "", "", "", "", "", ""
local FONT_CMDS = {
    mathrm = true,
    text = true,
    textbf = true,
    textit = true,
    mathbf = true,
    mathit = true,
    mathcal = true,
    mathbb = true,
    mathsf = true,
    texttt = true,
    operatorname = true,
    boldsymbol = true,
    emph = true,
}

-- Placeholder bytes keep literal characters away from the clean-up patterns: \1 \2 escaped braces,
-- \3 an escaped dollar (money, not math), \4 an escaped table pipe, \5 a star inside math.
local function delatex(m)
    m = m:gsub("\\{", "\1"):gsub("\\}", "\2")
    for _ = 1, 3 do -- nested fractions and font commands
        m = m:gsub("\\[dt]?frac%s*(%b{})%s*(%b{})", function(a, b)
            a, b = a:sub(2, -2), b:sub(2, -2)
            local function wrap(x)
                return (x:find("[%s%+%-/]") or x:find("\\[dt]?frac")) and ("(" .. x .. ")") or x
            end
            return wrap(a) .. "/" .. wrap(b)
        end)
        m = m:gsub("\\(%a+)%s*(%b{})", function(cmd, arg)
            if FONT_CMDS[cmd] then
                return arg:sub(2, -2)
            end
        end)
    end
    -- grouped super/subscripts keep their grouping: x^{n+1} -> x^(n+1), x_{k} -> x_k
    m = m:gsub("([%^_])(%b{})", function(op, g)
        g = g:sub(2, -2)
        return op .. ((#g == 1 or g:match("^\\%a+$")) and g or ("(" .. g .. ")"))
    end)
    m = m:gsub("\\(%a+)", function(cmd) return TEX[cmd] or cmd end)
    m = m:gsub("\\[,;:!%s]", " "):gsub("\\([|%%#&_])", "%1"):gsub("[{}]", "")
    return (m:gsub("\1", "{"):gsub("\2", "}"):gsub("%*", "\5"))
end

-- Inline markdown and math -> plain text: links keep their words, paired emphasis marks go
-- (a lone star, as in "A* search", stays).
---@param s any
---@return string|nil
function Markdown.plain(s)
    if type(s) ~= "string" then
        return nil
    end
    s = s:gsub("\\%$", "\3")
    s = s:gsub("%$%$(.-)%$%$", delatex):gsub("%$(.-)%$", delatex)
    s = s:gsub("!?%[([^%]]*)%](%b())", "%1")
    s = s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
    s = s:gsub("%*([^%*%s][^%*]-)%*", function(x)
        if not x:find("%s$") then
            return x
        end
    end)
    s = s:gsub("`", ""):gsub("\3", "$"):gsub("\5", "*")
    return squash(s)
end

---@class macui.Block
---@field kind "h"|"p"|"li"|"rule"|"code"|"quote"|"img"
---@field text string|nil

-- Markdown -> Doc blocks: headings (a rule before each top-level one but the first), paragraphs
-- (wrapped lines joined), "- " items, fenced code (verbatim), "> " quotes, "---" rules, table rows
-- as "a · b"; figures and their italic captions dropped (no images in the flow).
---@param md string|nil
---@return macui.Block[]
function Markdown.blocks(md)
    local blocks, para, quote, fence, math = {}, nil, nil, nil, nil
    local P = Markdown.plain
    local function add(kind, text)
        text = P(text)
        if text then
            blocks[#blocks + 1] = { kind = kind, text = text }
        end
    end
    local function flush()
        if para then
            add("p", table.concat(para, " "))
        end
        if quote then
            add("quote", table.concat(quote, " "))
        end
        para, quote = nil, nil
    end
    for line in ((md or "") .. "\n"):gmatch("(.-)\r?\n") do
        if not fence and not math and line:find("!%[") then
            line = line:gsub("!%[[^%]]*%]%b()", "") -- figures go; prose on the same line stays
        end
        local level, head = line:match("^(#+)%s+(.-)%s*$")
        if fence then
            if line:match("^%s*```") then
                if #fence > 0 then
                    blocks[#blocks + 1] = { kind = "code", text = table.concat(fence, "\n") }
                end
                fence = nil
            else
                fence[#fence + 1] = line
            end
        elseif math then
            math[#math + 1] = line
            if line:find("%$%$") then
                add("p", table.concat(math, " "))
                math = nil
            end
        elseif line:match("^%s*```") then
            flush()
            fence = {}
        elseif line:match("^%s*%$%$") and select(2, line:gsub("%$%$", "")) == 1 then
            flush()
            math = { line } -- a display formula over several lines
        elseif not line:match("%S") or line:match("^%s*%*[FT][ia][gb]%a*%.? %d+[%.:]") then
            flush()
        elseif line:match("^%s*>") then
            if para then
                flush()
            end
            quote = quote or {}
            quote[#quote + 1] = line:gsub("^%s*>%s?", "")
        elseif line:match("^%s*([%-%*_])%s*%1%s*%1[%s%-%*_]*$") then
            flush()
            blocks[#blocks + 1] = { kind = "rule" }
        elseif level then
            flush()
            if #level <= 2 and #blocks > 0 and blocks[#blocks].kind ~= "rule" then
                blocks[#blocks + 1] = { kind = "rule" }
            end
            add("h", (head:gsub("%s+#+$", "")))
        elseif line:match("^%s*[%-%*%+]%s+") then
            flush()
            add("li", (line:gsub("^%s*[%-%*%+]%s+", "")))
        elseif line:match("^%s*%d+[%.%)]%s+") then
            flush()
            add("p", line)
        elseif line:match("^%s*|") then
            flush()
            if not line:match("^%s*|[%s%-:|]+$") then
                local inner = line:gsub("\\|", "\4"):match("^%s*|(.-)|?%s*$")
                local cells = {}
                for c in (inner .. "|"):gmatch("([^|]*)|") do
                    cells[#cells + 1] = (squash(c) or "–"):gsub("\4", "|")
                end
                add("p", table.concat(cells, " · "))
            end
        elseif quote then
            quote[#quote + 1] = line -- a lazy continuation of the quote
        elseif not para and line:match("^%s+%S") and #blocks > 0 and blocks[#blocks].kind == "li" then
            blocks[#blocks].text = blocks[#blocks].text .. " " .. (P(line) or "")
        else
            para = para or {}
            para[#para + 1] = line
        end
    end
    flush()
    if math then
        add("p", table.concat(math, " "))
    end
    if fence and #fence > 0 then -- an unclosed fence (a streaming answer mid-block) still shows
        blocks[#blocks + 1] = { kind = "code", text = table.concat(fence, "\n") }
    end
    return blocks
end

return Markdown
