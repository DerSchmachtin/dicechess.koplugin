--[[--
Renders a "readable upside down" copy of a status string using visually
rotated Unicode lookalike letters, so the player sitting at the far end of
a shared device (the board's "head") can read the same message right-side
up from their own seat, without any real widget-rotation support.
]]

local FLIP_MAP = {
    a = "ɐ", b = "q", c = "ɔ", d = "p", e = "ǝ", f = "ɟ", g = "ƃ",
    h = "ɥ", i = "ᴉ", j = "ɾ", k = "ʞ", l = "ꞁ", m = "ɯ", n = "u",
    o = "o", p = "d", q = "b", r = "ɹ", s = "s", t = "ʇ", u = "n",
    v = "ʌ", w = "ʍ", x = "x", y = "ʎ", z = "z",
    ["6"] = "9", ["9"] = "6",
    ["."] = "˙", [","] = "'", ["'"] = ",", ["!"] = "¡", ["?"] = "¿",
    ["("] = ")", [")"] = "(", ["["] = "]", ["]"] = "[",
}

-- Splits a UTF-8 string into an array of its individual characters (each
-- possibly multiple bytes), so multi-byte glyphs (em dash, die faces,
-- accented letters) are kept intact instead of being byte-reversed.
local function utf8Chars(s)
    local chars = {}
    local i = 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        local n
        if b < 0x80 then n = 1
        elseif b >= 0xF0 then n = 4
        elseif b >= 0xE0 then n = 3
        elseif b >= 0xC0 then n = 2
        else n = 1 end
        chars[#chars + 1] = s:sub(i, i + n - 1)
        i = i + n
    end
    return chars
end

local function flipChar(c)
    return FLIP_MAP[c:lower()] or c
end

local M = {}

function M.flip(text)
    local chars = utf8Chars(text)
    local out = {}
    for i = #chars, 1, -1 do
        local c = chars[i]
        if #c == 1 then
            out[#out + 1] = flipChar(c)
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

return M
