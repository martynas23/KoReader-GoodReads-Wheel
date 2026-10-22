--[[
    Goodreads Wheel plugin for KOReader

    Syncs your Goodreads "Want to Read" shelf and spins a slot machine
    over it to pick your next book.

    License: GNU AGPL v3
--]]

local DataStorage     = require("datastorage")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LuaSettings     = require("luasettings")
local NetworkMgr      = require("ui/network/manager")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger          = require("logger")
local T               = require("ffi/util").template
local _               = require("gettext")

local Sync  = require("gr_sync")
local Wheel = require("gr_wheel")

local SHELF = "to-read"

local GoodreadsWheel = WidgetContainer:extend {
    name        = "goodreadswheel",
    is_doc_only = false,
}

function GoodreadsWheel:init()
    self.settings  = LuaSettings:open(DataStorage:getSettingsDir() .. "/goodreadswheel.lua")
    self.cover_dir = DataStorage:getDataDir() .. "/cache/goodreadswheel"
    math.randomseed(os.time())
    self.ui.menu:registerToMainMenu(self)
end

function GoodreadsWheel:getBooks()
    return self.settings:readSetting("books") or {}
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Menu
-- ──────────────────────────────────────────────────────────────────────────────

function GoodreadsWheel:addToMainMenu(menu_items)
    menu_items.goodreadswheel = {
        text         = _("Goodreads wheel"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text     = _("Spin the wheel"),
                callback = function() self:showWheel() end,
            },
            {
                text_func = function()
                    local books = self:getBooks()
                    if #books == 0 then
                        return _("Sync want-to-read")
                    end
                    return T(_("Sync want-to-read (%1 books)"), #books)
                end,
                help_text_func = function()
                    local last = self.settings:readSetting("last_sync")
                    return last and T(_("Last synced %1."), os.date("%d %b %Y, %H:%M", last))
                        or _("Not synced yet.")
                end,
                callback = function() self:sync() end,
            },
            {
                text_func = function()
                    local user_id = self.settings:readSetting("user_id")
                    return user_id and T(_("Goodreads user ID: %1"), user_id)
                        or _("Set Goodreads user ID")
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    self:editUserId(function() touchmenu_instance:updateItems() end)
                end,
            },
        },
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Actions
-- ──────────────────────────────────────────────────────────────────────────────

function GoodreadsWheel:showWheel()
    local books = self:getBooks()
    if #books == 0 then
        UIManager:show(InfoMessage:new {
            text = _("No books yet. Sync your want-to-read shelf first."),
        })
        return
    end
    UIManager:show(Wheel:new {
        books     = books,
        get_cover = function(book)
            -- Use a cached cover, and only download one if Wi-Fi is already
            -- up: turning it on just for a cover would take too long.
            return Sync.fetchCover(book, self.cover_dir, NetworkMgr:isConnected())
        end,
    })
end

--- Ask for the Goodreads user ID. Accepts the bare number or a profile URL.
function GoodreadsWheel:editUserId(on_saved)
    local dialog
    dialog = InputDialog:new {
        title       = _("Goodreads user ID"),
        input       = self.settings:readSetting("user_id") or "",
        input_hint  = "12345678",
        description = _("The number in your Goodreads profile link, e.g. goodreads.com/user/show/12345678-name. You can also paste the whole link."),
        buttons = { {
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    -- The first run of digits: "12345678" from ".../user/show/12345678-name"
                    local user_id = text:match("(%d+)")
                    if not user_id then
                        UIManager:show(InfoMessage:new {
                            text = _("That doesn't look like a Goodreads user ID."),
                        })
                        return
                    end
                    UIManager:close(dialog)
                    if user_id == self.settings:readSetting("user_id") then return end

                    -- A different user: the old list is someone else's shelf
                    self.settings:saveSetting("user_id", user_id)
                    self.settings:delSetting("books")
                    self.settings:delSetting("last_sync")
                    self.settings:flush()
                    if on_saved then on_saved() end
                    self:sync()
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function GoodreadsWheel:sync()
    local user_id = self.settings:readSetting("user_id")
    if not user_id then
        self:editUserId()
        return
    end
    NetworkMgr:runWhenOnline(function() self:doSync(user_id) end)
end

function GoodreadsWheel:doSync(user_id)
    local progress
    local function showProgress(page, count)
        if progress then UIManager:close(progress) end
        progress = InfoMessage:new {
            text    = T(_("Syncing want-to-read…\nPage %1, %2 books so far."), page, count),
        }
        UIManager:show(progress)
        -- Paint now: the fetch below blocks until the page has downloaded
        UIManager:forceRePaint()
    end

    local ok, books, err = pcall(Sync.fetchShelf, user_id, SHELF, showProgress)
    if progress then UIManager:close(progress) end
    if not ok then
        err = books
        books = nil
    end

    if not books then
        logger.warn("GoodreadsWheel: sync failed:", err)
        UIManager:show(InfoMessage:new {
            text = T(_("Sync failed: %1"), tostring(err)),
        })
        return
    end
    if #books == 0 then
        UIManager:show(InfoMessage:new {
            text = _("No books found. Check that your want-to-read shelf isn't empty and that your Goodreads profile is public (Settings → Privacy → \"Who can view my profile\": anyone)."),
        })
        return
    end

    self.settings:saveSetting("books", books)
    self.settings:saveSetting("last_sync", os.time())
    self.settings:flush()
    UIManager:show(InfoMessage:new {
        text    = T(_("Synced %1 books."), #books),
        timeout = 3,
    })
end

return GoodreadsWheel
