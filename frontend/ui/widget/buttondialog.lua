--[[--
A button dialog widget that shows a grid of buttons.

    @usage
    local button_dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = "First row, left side",
                    callback = function() end,
                    hold_callback = function() end
                },
                {
                    text = "First row, middle",
                    callback = function() end
                },
                {
                    text = "First row, right side",
                    callback = function() end
                }
            },
            {
                {
                    text = "Second row, full span",
                    callback = function() end
                }
            },
            {
                {
                    text = "Third row, left side",
                    callback = function() end
                },
                {
                    text = "Third row, right side",
                    callback = function() end
                }
            }
        }
    }
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local MovableContainer = require("ui/widget/container/movablecontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local util = require("util")

local ButtonDialog = InputContainer:extend{
    buttons = nil,
    width = nil,
    width_factor = nil, -- number between 0 and 1, factor to the smallest of screen width and height
    shrink_unneeded_width = false, -- have 'width' meaning 'max_width'
    shrink_min_width = nil, -- default to ButtonTable's default
    tap_close_callback = nil,
    alpha = nil, -- passed to MovableContainer
    -- If scrolling, prefers using this/these numbers of buttons rows per page
    -- (depending on what the screen height allows) to compute the height.
    rows_per_page = nil, -- number or array of numbers

    title = nil,
    title_align = "left",
    title_face = Font:getFace("x_smalltfont"),
    title_padding = Size.padding.large,
    title_margin = Size.margin.title,
    use_info_style = true, -- set to false to have bold font style of the title
    info_face = Font:getFace("infofont"),
    info_padding = Size.padding.default,
    info_margin = Size.margin.default,
    dismissable = true, -- set to false if any button callback is required
}

function ButtonDialog:init()
    if not self.width then
        if not self.width_factor then
            self.width_factor = 0.9 -- default if no width specified
        end
        self.width = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * self.width_factor)
    end
    if self.dismissable then
        if Device:hasKeys() then
            local back_group = util.tableDeepCopy(Device.input.group.Back)
            if Device:hasFewKeys() then
                table.insert(back_group, "Left")
                self.key_events.Close = { { back_group } }
            else
                table.insert(back_group, "Menu")
                self.key_events.Close = { { back_group } }
            end
        end
        if Device:isTouchDevice() then
            self.ges_events.TapClose = {
                GestureRange:new{
                    ges = "tap",
                    range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(),
                        h = Screen:getHeight(),
                    }
                }
            }
        end
    end

    self.buttontable = ButtonTable:new{
        buttons = self.buttons,
        width = self.width - 2*Size.border.window - 2*Size.padding.button,
        shrink_unneeded_width = self.shrink_unneeded_width,
        shrink_min_width = self.shrink_min_width,
        show_parent = self,
    }
    local buttontable_width = self.buttontable:getSize().w -- may be shrinked

    local title_widget, title_widget_height
    if self.title then
        local title_padding, title_margin, title_face
        if self.use_info_style then
            title_padding = self.info_padding
            title_margin  = self.info_margin
            title_face    = self.info_face
        else
            title_padding = self.title_padding
            title_margin  = self.title_margin
            title_face    = self.title_face
        end
        title_widget = FrameContainer:new{
            padding = title_padding,
            margin = title_margin,
            bordersize = 0,
            TextBoxWidget:new{
                text = self.title,
                width = buttontable_width - 2 * (title_padding + title_margin),
                face = title_face,
                alignment = self.title_align,
            },
        }
        title_widget_height = title_widget:getSize().h + Size.line.medium
    else
        title_widget = VerticalSpan:new{}
        title_widget_height = 0
    end

    -- If the ButtonTable ends up being taller than the screen, wrap it inside a ScrollableContainer.
    -- Ensure some small top and bottom padding, so the scrollbar stand out, and some outer margin
    -- so the this dialog does not take the full height and stand as a popup.
    local max_height = Screen:getHeight() - 2*Size.padding.buttontable - 2*Size.margin.default - title_widget_height
    local height = self.buttontable:getSize().h
    local scontainer, scrollbar_width
    if height > max_height then
        -- Adjust the ScrollableContainer to an integer multiple of the row height
        -- (assuming all rows get the same height), so when scrolling per page,
        -- we always end up seeing full rows.
        self.buttontable:setupGridScrollBehaviour()
        local step_scroll_grid = self.buttontable:getStepScrollGrid()
        local row_height = step_scroll_grid[1].bottom + 1 - step_scroll_grid[1].top
        local fit_rows = math.floor(max_height / row_height)
        if self.rows_per_page then
            if type(self.rows_per_page) == "number" then
                if fit_rows > self.rows_per_page then
                    fit_rows = self.rows_per_page
                end
            else
                for _, nb in ipairs(self.rows_per_page) do
                    if fit_rows >= nb then
                        fit_rows = nb
                        break
                    end
                end
            end
        end
        -- (Comment the next line to test ScrollableContainer behaviour when things do not fit)
        max_height = row_height * fit_rows
        scrollbar_width = ScrollableContainer:getScrollbarWidth()
        self.cropping_widget = ScrollableContainer:new{
            dimen = Geom:new{
                -- We'll be exceeding the provided width in this case (let's not bother
                -- ensuring it, we'd need to re-setup the ButtonTable...)
                w = buttontable_width + scrollbar_width,
                h = max_height,
            },
            show_parent = self,
            step_scroll_grid = step_scroll_grid,
            self.buttontable,
        }
        scontainer = VerticalGroup:new{
            VerticalSpan:new{ width=Size.padding.buttontable },
            self.cropping_widget,
            VerticalSpan:new{ width=Size.padding.buttontable },
        }
    end
    local separator
    if self.title then
        separator = LineWidget:new{
            background = Blitbuffer.COLOR_GRAY,
            dimen = Geom:new{
                w = buttontable_width + (scrollbar_width or 0),
                h = Size.line.medium,
            },
        }
    else
        separator = VerticalSpan:new{}
    end
    self.movable = MovableContainer:new{
        alpha = self.alpha,
        anchor = self.anchor,
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = Size.border.window,
            radius = Size.radius.window,
            padding = Size.padding.button,
            -- No padding at top or bottom to make all buttons
            -- look the same size
            padding_top = 0,
            padding_bottom = 0,
            VerticalGroup:new{
                title_widget,
                separator,
                scontainer or self.buttontable,
            },
        }
    }

    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
end

function ButtonDialog:getContentSize()
    return self.movable.dimen
end

function ButtonDialog:getButtonById(id)
    return self.buttontable:getButtonById(id)
end

function ButtonDialog:getScrolledOffset()
    if self.cropping_widget then
        return self.cropping_widget:getScrolledOffset()
    end
end

function ButtonDialog:setScrolledOffset(offset_point)
    if offset_point and self.cropping_widget then
        return self.cropping_widget:setScrolledOffset(offset_point)
    end
end

function ButtonDialog:setTitle(title)
    self.title = title
    self:free()
    self:init()
    UIManager:setDirty("all", "ui")
end

function ButtonDialog:onShow()
    UIManager:setDirty(self, function()
        return "ui", self.movable.dimen
    end)
end

function ButtonDialog:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "flashui", self.movable.dimen
    end)
end

function ButtonDialog:onClose()
    if self.tap_close_callback then
        self.tap_close_callback()
    end
    UIManager:close(self)
    return true
end

function ButtonDialog:onTapClose(arg, ges)
    if ges.pos:notIntersectWith(self.movable.dimen) then
        self:onClose()
    end
    return true
end

function ButtonDialog:paintTo(...)
    InputContainer.paintTo(self, ...)
    self.dimen = self.movable.dimen
end

function ButtonDialog:_onFocusMove(args)
    if not self.cropping_widget then
        return
    end

    local focus = self.buttontable:getFocusItem()
    if self.dimen and focus and focus.dimen then
        local button_y_offset = focus.dimen.y - self.dimen.y
        self.cropping_widget:_scrollBy(0, button_y_offset)
    end
end

function ButtonDialog:_onPageScrollToRow(row)
    -- ScrollableContainer will pass us the row number of the top widget at the current scroll offset
    self.buttontable:moveFocusTo(1, row)
end

return ButtonDialog
