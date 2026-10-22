--[[
    gr_sync.lua — fetches a Goodreads shelf through its public RSS feed

    Goodreads no longer hands out API keys, but every shelf of a public
    profile still has an RSS feed that needs no login:

        https://www.goodreads.com/review/list_rss/<user id>?shelf=to-read&page=N

    Each page holds up to 100 books and a page past the end comes back empty.
    The feed is parsed with plain Lua patterns: we only need a handful of
    flat fields from each <item>.
--]]

local Sync = {}

local FEED_URL  = "https://www.goodreads.com/review/list_rss/%s?shelf=%s&page=%d"
local MAX_PAGES = 50 -- 5000 books, a safety net against a feed that never ends

-- ──────────────────────────────────────────────────────────────────────────────
-- Parsing
-- ──────────────────────────────────────────────────────────────────────────────

local NAMED_ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }

--- Encode a Unicode code point as UTF-8 (LuaJIT has no utf8 library).
local function utf8char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + math.floor(cp / 0x1000) % 0x40,
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return "?"
end

--- Strip CDATA and decode XML entities. Goodreads uses both, sometimes
--- entities inside CDATA too, so entities are always decoded.
local function cleanText(s)
    s = s:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    s = s:gsub("&(#?)([xX]?)(%w+);", function(hash, hex, name)
        if hash == "#" then
            local cp = tonumber(name, hex ~= "" and 16 or 10)
            return cp and utf8char(cp)
        end
        return NAMED_ENTITIES[hex .. name]
    end)
    s = s:gsub("%s+", " ")
    return (s:match("^%s*(.-)%s*$"))
end

local function field(item, name)
    local raw = item:match("<" .. name .. ">(.-)</" .. name .. ">")
    if raw then
        local text = cleanText(raw)
        if text ~= "" then return text end
    end
    return nil -- explicitly, so tonumber(field(...)) gets an argument
end

--- Turn one <item> of the feed into a book table.
local function parseItem(item)
    local id = field(item, "book_id")
    local title = field(item, "title")
    if not id or not title then return end

    local cover = field(item, "book_large_image_url") or field(item, "book_medium_image_url")
    -- Books without a cover point at a generic "nophoto" placeholder
    if cover and cover:find("nophoto", 1, true) then cover = nil end

    local added = field(item, "user_date_added")
    -- "Wed, 21 Oct 2026 22:40:55 -0700" -> "21 Oct 2026"
    added = added and added:match("%a+, (%d+ %a+ %d+)") or added

    return {
        id        = id,
        title     = title,
        author    = field(item, "author_name"),
        pages     = tonumber(field(item, "num_pages")),
        rating    = tonumber(field(item, "average_rating")),
        published = field(item, "book_published"),
        added     = added,
        cover_url = cover,
    }
end

--- Parse a feed page into a list of books.
function Sync.parseFeed(xml)
    local books = {}
    for item in xml:gmatch("<item>(.-)</item>") do
        local book = parseItem(item)
        if book then table.insert(books, book) end
    end
    return books
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Network
-- ──────────────────────────────────────────────────────────────────────────────

--- GET a URL. Returns the body, or nil plus an error message.
local function httpGet(url, block_timeout, total_timeout)
    local http       = require("socket.http")
    local socket     = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    socketutil:set_timeout(block_timeout, total_timeout)
    local code, headers, status = socket.skip(1, http.request {
        url    = url,
        method = "GET",
        sink   = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()

    if headers == nil then
        -- describe_error only exists in recent KOReader versions
        local described = socketutil.describe_error
            and socketutil.describe_error(code, block_timeout, total_timeout)
        return nil, described or tostring(status or code or "network unreachable"), code
    end
    if code ~= 200 then
        return nil, tostring(status or code), code
    end
    return table.concat(sink)
end

--- Fetch every book on a shelf.
--- on_page(page_number, books_so_far) is called before each page is requested,
--- so the caller can show progress.
--- Returns the list of books, or nil plus an error message.
function Sync.fetchShelf(user_id, shelf, on_page)
    local socketutil = require("socketutil")
    local books, seen = {}, {}

    for page = 1, MAX_PAGES do
        if on_page then on_page(page, #books) end

        local url = string.format(FEED_URL, user_id, shelf, page)
        local body, err, code = httpGet(url, socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
        if not body then
            if code == 404 then
                return nil, "No Goodreads user with ID " .. user_id .. "."
            end
            return nil, err
        end

        local added = 0
        for _, book in ipairs(Sync.parseFeed(body)) do
            if not seen[book.id] then
                seen[book.id] = true
                table.insert(books, book)
                added = added + 1
            end
        end
        -- An empty page is the end of the shelf. A page of books we've
        -- already seen means the feed ignored ?page=, so stop too.
        if added == 0 then break end
    end

    return books
end

--- Download a book's cover into dir, unless it's already there.
--- Returns the file path, or nil if there's no cover or the download failed.
function Sync.fetchCover(book, dir, allow_download)
    if not book.cover_url then return end
    local path = dir .. "/" .. book.id .. ".jpg"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "file" then return path end
    if not allow_download then return end

    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(dir:match("^(.*)/[^/]+$")) -- the parent cache dir, if missing
        lfs.mkdir(dir)
    end
    local body = httpGet(book.cover_url, 5, 15)
    if not body or body == "" then return end

    local f = io.open(path, "wb")
    if not f then return end
    f:write(body)
    f:close()
    return path
end

return Sync
