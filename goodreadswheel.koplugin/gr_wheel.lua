--[[
    gr_wheel.lua — the slot-machine dialog

    A real spinning wheel would smear on e-ink, so instead the dialog flips
    through random titles with fast refreshes, slowing down like a reel,
    then settles on the winner with a clean refresh and shows its cover.
--]]

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local ImageWidget     = require("ui/widget/imagewidget")
local InputContainer  = require("ui/widget/container/inputcontainer")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local T               = require("ffi/util").template
local _               = require("gettext")

local FRAMES       = 12   -- titles shown before the winner
local FIRST_DELAY  = 0.05 -- seconds between the first frames
local SLOWDOWN     = 1.25 -- each frame waits this much longer than the last

local Wheel = InputContainer:extend {
    books     = nil, -- list of books from Sync.fetchShelf
    get_cover = nil, -- function(book) -> cover image path or nil
}

function Wheel:init()
    self.width   = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.85)
    self.inner_w = self.width - 2 * (Size.padding.large + Size.border.window)
    self.cover_h = math.floor(Screen:getHeight() * 0.38)

    self.header_face = Font:getFace("smalltfont")
    self.title_face  = Font:getFace("tfont")
    self.author_face = Font:getFace("cfont", 20)
    self.info_face   = Font:getFace("cfont", 16)
    -- Room for three lines of title, so the dialog doesn't change size between frames
    self.title_h = math.ceil(self.title_face.size * 1.3) * 3

    if Device:hasKeys() then
        self.key_events.Close     = { { Device.input.group.Back } }
        self.key_events.SpinAgain = { { "Press" } }
    end
    if Device:isTouchDevice() then
        self.ges_events.TapClose = {
            GestureRange:new {
                ges   = "tap",
                range = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
end

function Wheel:onShow()
    self:spin()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Layout
-- ──────────────────────────────────────────────────────────────────────────────

--- What goes in the cover slot: the cover once settled, a big "?" while spinning.
function Wheel:coverSlot(book, settled)
    local content
    local path = settled and self.get_cover and self.get_cover(book)
    if path then
        self.cover_widget = ImageWidget:new {
            file         = path,
            width        = self.inner_w,
            height       = self.cover_h,
            scale_factor = 0, -- fit inside the slot, keeping aspect ratio
        }
        content = self.cover_widget
    else
        content = TextWidget:new {
            text = settled and _("No cover") or "?",
            face = settled and self.info_face or Font:getFace("tfont", 90),
        }
    end
    return CenterContainer:new {
        dimen = Geom:new { w = self.inner_w, h = self.cover_h },
        content,
    }
end

function Wheel:detailsLine(book)
    local parts = {}
    if book.pages then table.insert(parts, T(_("%1 pages"), book.pages)) end
    if book.rating then table.insert(parts, T(_("%1 avg"), string.format("%.2f", book.rating))) end
    if book.published then table.insert(parts, book.published) end
    return table.concat(parts, " · ")
end

--- Rebuild the dialog around a book.
function Wheel:render(book, settled)
    if self.cover_widget then
        self.cover_widget:free()
        self.cover_widget = nil
    end

    local buttons = ButtonTable:new {
        width       = self.inner_w,
        show_parent = self,
        -- "Spin again" first, so it's the button the 5-way starts on
        buttons = { {
            {
                text     = _("Spin again"),
                enabled  = settled,
                callback = function() self:spin() end,
            },
            {
                text     = _("Close"),
                callback = function() self:onClose() end,
            },
        } },
    }

    local added = settled and book.added and T(_("On your shelf since %1"), book.added) or " "

    self.frame = FrameContainer:new {
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        radius     = Size.radius.window,
        padding    = Size.padding.large,
        VerticalGroup:new {
            align = "center",
            TextWidget:new {
                text = settled and _("Your next read") or _("Spinning…"),
                face = self.header_face,
            },
            VerticalSpan:new { width = Size.span.vertical_large * 2 },
            self:coverSlot(book, settled),
            VerticalSpan:new { width = Size.span.vertical_large * 2 },
            TextBoxWidget:new {
                text      = book.title,
                face      = self.title_face,
                width     = self.inner_w,
                height    = self.title_h,
                alignment = "center",
                height_overflow_show_ellipsis = true,
            },
            TextWidget:new {
                text      = book.author or " ",
                face      = self.author_face,
                max_width = self.inner_w,
            },
            VerticalSpan:new { width = Size.span.vertical_large },
            TextWidget:new {
                text      = self:detailsLine(book) .. " ",
                face      = self.info_face,
                max_width = self.inner_w,
            },
            TextWidget:new {
                text      = added,
                face      = self.info_face,
                max_width = self.inner_w,
            },
            VerticalSpan:new { width = Size.span.vertical_large * 2 },
            buttons,
        },
    }

    self[1] = CenterContainer:new {
        dimen = Geom:new { w = Screen:getWidth(), h = Screen:getHeight() },
        self.frame,
    }
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Spinning
-- ──────────────────────────────────────────────────────────────────────────────

--- Pick a random book, avoiding `not_this` when there's a choice.
function Wheel:randomBook(not_this)
    local n = #self.books
    local book
    repeat
        book = self.books[math.random(n)]
    until book ~= not_this or n == 1
    return book
end

function Wheel:spin()
    if self.spinning then return end
    self.spinning = true

    local winner = self:randomBook(self.winner)
    self.winner = winner
    local frame, shown = 0, nil

    self.step = function()
        frame = frame + 1
        if frame > FRAMES or #self.books == 1 then
            self.spinning = false
            self:render(winner, true)
            -- A flashing refresh clears the ghosting left by the fast frames
            UIManager:setDirty(self, function() return "flashui", self.frame.dimen end)
            return
        end
        shown = self:randomBook(shown)
        self:render(shown, false)
        UIManager:setDirty(self, function() return "fast", self.frame.dimen end)
        UIManager:scheduleIn(FIRST_DELAY * SLOWDOWN ^ frame, self.step)
    end
    self.step()
end

-- ──────────────────────────────────────────────────────────────────────────────
-- Events
-- ──────────────────────────────────────────────────────────────────────────────

function Wheel:onSpinAgain()
    self:spin()
    return true
end

function Wheel:onTapClose(_, ges)
    if self.frame and ges.pos:notIntersectWith(self.frame.dimen) then
        self:onClose()
    end
    return true
end

function Wheel:onClose()
    UIManager:close(self)
    return true
end

function Wheel:onCloseWidget()
    if self.step then
        UIManager:unschedule(self.step)
    end
    if self.cover_widget then
        self.cover_widget:free()
        self.cover_widget = nil
    end
    if self.frame then
        UIManager:setDirty(nil, function() return "ui", self.frame.dimen end)
    end
end

return Wheel
