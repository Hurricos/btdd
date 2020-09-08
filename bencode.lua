-- bencode.lua: A lua bencoding serializer and de-serializer
--
-- The MIT License (MIT)
--
-- Copyright (c) 2015 Josh Kunz 
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- The main interface is `bencode` and `bdecode` described below. This code
-- should work but is not very well tested. Caveat Emptor.

function char_class_from_string(str)
    local tbl = {}
    for i = 1, #str do
        tbl[string.sub(str,i,i)] = true
    end
    return tbl
end

DIGITS = char_class_from_string("0123456789")

-- For 'nil' elimination
function isdigit(c)
    if DIGITS[c] == true then
        return true
    else
        return false
    end
end

-- Takes: A bencoded string
-- Returns: The structure in the bencoded string as a lua datatype. Type mappings:
--  bencoded int: lua number
--  bencoded bytes: lua string (with raw bytes)
--  bencoded list: lua table where the keys are the indices (starting at 1) in
--                 standard lua style.
--  bencoded dictionary: lua table that contains the mappings. Note, bencoded
--                       dictionaries can only have strings as keys.
function bdecode(str)
    local peek = function ()
        return string.sub(str, 1, 1)
    end
    local eat = function ()
        str = string.sub(str, 2)
    end
    local get = function (what)
        if peek() == what then 
            eat()
            return true
        else return false end
    end

    function _d_int () 
        local istr = ""
        local c = peek()
        local first = true
        while (first and c == "-") or isdigit(c) do
            first = false
            get(c)
            istr = istr .. c
            c = peek()
        end
        return tonumber(istr)
    end

    function d_byte_str()
        length = _d_int()
        assert(length >= 0)
        get(":")
        if length == 0 then
            return ""
        else
            gotten = string.sub(str, 1, length)
            str = string.sub(str, 1 + length)
            return gotten
        end
    end

    function d_int()
        get("i")
        local n = _d_int()
        get("e")
        return n
    end

    function d_value()
        if peek() == "e" then
            return nil
        elseif isdigit(peek()) then
            return d_byte_str()
        elseif peek() == "i" then
            return d_int()
        elseif peek() == "l" then
            return d_list()
        elseif peek() == "d" then
            return d_dict()
        else
            error("Invalid value type: \"" .. peek() .. "\"")
        end
    end


    function d_list()
        get("l")
        local list = {}
        while true do
            local value = d_value()
            if value == nil then
                get("e")
                return list
            else
                table.insert(list, value)
            end
        end
    end

    function d_dict()
        get("d")
        local dict = {}
        while true do
            if peek() == "e" then
                get("e")
                return dict
            else
                local key = d_byte_str()
                local value = d_value()
                assert(value ~= nil)
                dict[key] = value
            end
        end
    end

    local parsed = d_value()
    assert(parsed ~= nil)
    return parsed
end

-- Takes: A lua data structure
-- Returns: A bencoded string that represents the data structure. Type mappings:
--  lua int: bencoded int
--  lua string: bencoded bytes
--  lua table:
--      if the keys in the table are all strings:
--          the table is encoded as a bencoded dictionary
--      otherwise
--          the table is encoded as a list where the elements of the list are
--          defined by order of the elements returned using `ipairs`.
-- Note: bencode(bdecode(bencode(t))) == bencode(t) is true, but
--       bdecode(bencode(t)) is not necessarily == t because bencoded can
--       change the ordering of pairs in a  table (since in a bencoded dictionary
--       the keys must occur in sorted order).
--        function bencode(struct)
function bencode(struct)
    function e_str(s) return string.format("%s:%s", #s, s) end
    function e_int(i) return string.format("i%se", i) end
    function e_list(l)
        local list = "l"
        for _, val in ipairs(l) do
            list = list .. e_value(val)
        end
        list = list .. "e"
        return list
    end
    function e_dict(d)
        local keys = {}
        for k, _ in pairs(d) do
            assert(type(k) == "string")
            table.insert(keys, k)
        end
        table.sort(keys)
        local dict = "d"
        for _, k  in ipairs(keys) do
            dict = dict .. e_str(k)
            dict = dict .. e_value(d[k])
        end
        dict = dict .. "e"
        return dict
    end
    function e_value(v)
        if type(v) == "string" then
            return e_str(v)
        elseif type(v) == "number" then
            return e_int(v)
        elseif type(v) == "table" then
            local allstr = true
            for k, _ in pairs(v) do
                allstr = type(k) == "string"
                if not allstr then break end
            end
            if allstr then 
                return e_dict(v)
            else return e_list(v) end
        else
            error("Un-bencodable type: \"" .. type(v) .. "\"")
        end
    end

    return e_value(struct)
end

function readAll(file)
    local f = assert(io.open(file, "rb"))
    local content = f:read("*all")
    f:close()
    return content
end

function printTable(thing)
    for k,v in pairs(thing) do
        if (type(v) == "table") then
            print (k,printTable(v))
        else
            print (k,v)
        end
    end
end

function doit()
    local t = readAll("/home/hurricos/MR33-NAND.torrent")
    local d = bdecode(t)
    printTable(d)
end

