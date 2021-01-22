--[[--
Widget that displays a tiny notification at the top of the screen.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Input = Device.input
local Screen = Device.screen

local Notification = InputContainer:new{
    face = Font:getFace("x_smallinfofont"),
    text = "Null Message",
    margin = Size.margin.default,
    padding = Size.padding.default,
    timeout = 2, -- default to 2 seconds
    toast = true, -- closed on any event, and let the event propagate to next top widget
}

function Notification:init()
    if not self.toast then
        -- If not toast, closing is handled in here
        if Device:hasKeys() then
            self.key_events = {
                AnyKeyPressed = { { Input.group.Any },
                    seqtext = "any key", doc = "close dialog" }
            }
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

    -- we construct the actual content here because self.text is only available now
    local text_widget = TextWidget:new{
        text = self.text,
        face = self.face,
    }
    local widget_size = text_widget:getSize()
    self[1] = CenterContainer:new{
        dimen = Geom:new{
            w = Screen:getWidth(),
            h = math.floor(Screen:getHeight() / 10),
        },
        FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            radius = 0,
            margin = self.margin,
            padding = self.padding,
            CenterContainer:new{
                dimen = Geom:new{
                    w = widget_size.w,
                    h = widget_size.h
                },
                text_widget,
            }
        }
    }
end

function Notification:onCloseWidget()
    UIManager:setDirty(nil, function()
        return "ui", self[1][1].dimen
    end)
    return true
end

function Notification:onShow()
    -- triggered by the UIManager after we got successfully shown (not yet painted)
    UIManager:setDirty(self, function()
        return "ui", self[1][1].dimen
    end)
    if self.timeout then
        UIManager:scheduleIn(self.timeout, function() UIManager:close(self) end)
    end
    return true
end

function Notification:onAnyKeyPressed()
    if self.toast then return end -- should not happen
    UIManager:close(self)
    return true
end

function Notification:onTapClose()
    if self.toast then return end -- should not happen
    UIManager:close(self)
    return true
end

return Notification
