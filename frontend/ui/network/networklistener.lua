local BD = require("ui/bidi")
local Device = require("device")
local Event = require("ui/event")
local EventListener = require("ui/widget/eventlistener")
local Font = require("ui/font")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local NetworkListener = EventListener:extend{}

function NetworkListener:onToggleWifi()
    if not NetworkMgr:isWifiOn() then
        local toggle_im = InfoMessage:new{
            text = _("Turning on Wi-Fi…"),
        }
        UIManager:show(toggle_im)
        UIManager:forceRePaint()

        -- NB Normal widgets should use NetworkMgr:promptWifiOn()
        -- (or, better yet, the NetworkMgr:beforeWifiAction wrappers: NetworkMgr:runWhenOnline() & co.)
        -- This is specifically the toggle Wi-Fi action, so consent is implied.
        local complete_callback = function()
            UIManager:broadcastEvent(Event:new("NetworkConnected"))
        end
        NetworkMgr:turnOnWifi(complete_callback)

        UIManager:close(toggle_im)
    else
        local complete_callback = function()
            UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
        end
        local toggle_im = InfoMessage:new{
            text = _("Turning off Wi-Fi…"),
        }
        UIManager:show(toggle_im)
        UIManager:forceRePaint()

        UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
        NetworkMgr:turnOffWifi(complete_callback)

        UIManager:close(toggle_im)
        UIManager:show(InfoMessage:new{
            text = _("Wi-Fi off."),
            timeout = 1,
        })
    end
end

function NetworkListener:onInfoWifiOff()
    -- That's the end goal
    local complete_callback = function()
        UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
    end
    local toggle_im = InfoMessage:new{
        text = _("Turning off Wi-Fi…"),
    }
    UIManager:show(toggle_im)
    UIManager:forceRePaint()

    UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
    NetworkMgr:turnOffWifi(complete_callback)

    UIManager:close(toggle_im)
    UIManager:show(InfoMessage:new{
        text = _("Wi-Fi off."),
        timeout = 1,
    })
end

function NetworkListener:onInfoWifiOn()
    if not NetworkMgr:isOnline() then
        local toggle_im = InfoMessage:new{
            text = _("Enabling Wi-Fi…"),
        }
        UIManager:show(toggle_im)
        UIManager:forceRePaint()

        -- NB Normal widgets should use NetworkMgr:promptWifiOn()
        -- (or, better yet, the NetworkMgr:beforeWifiAction wrappers: NetworkMgr:runWhenOnline() & co.)
        -- This is specifically the toggle Wi-Fi action, so consent is implied.
        local complete_callback = function()
            UIManager:broadcastEvent(Event:new("NetworkConnected"))
        end
        NetworkMgr:turnOnWifi(complete_callback)

        UIManager:close(toggle_im)
    else
        local info_text
        local current_network = NetworkMgr:getCurrentNetwork()
        -- this method is only available for some implementations
        if current_network and current_network.ssid then
            info_text = T(_("Already connected to network %1."), BD.wrap(current_network.ssid))
        else
            info_text = _("Already connected.")
        end
        UIManager:show(InfoMessage:new{
            text = info_text,
            timeout = 1,
        })
    end
end

-- Everything below is to handle auto_disable_wifi ;).
local default_network_timeout_seconds = 5*60
local max_network_timeout_seconds = 30*60
-- If autostandby is enabled, shorten the timeouts
local auto_standby = G_reader_settings:readSetting("auto_standby_timeout_seconds", -1)
if auto_standby > 0 then
    default_network_timeout_seconds = default_network_timeout_seconds / 2
    max_network_timeout_seconds = max_network_timeout_seconds / 2
end
-- This should be more than enough to catch actual activity vs. noise spread over 5 minutes.
local network_activity_noise_margin = 12 -- unscaled_size_check: ignore

-- Read the statistics/tx_packets sysfs entry for the current network interface.
-- It *should* be the least noisy entry on an idle network...
-- The fact that auto_disable_wifi is only available on devices that expose a
-- net sysfs entry allows us to get away with a Linux-only solution.
function NetworkListener:_getTxPackets()
    -- read tx_packets stats from sysfs (for the right network if)
    local file = io.open("/sys/class/net/" .. NetworkMgr:getNetworkInterfaceName() .. "/statistics/tx_packets", "rb")

    -- file exists only when Wi-Fi module is loaded.
    if not file then return nil end

    local tx_packets = file:read("*number")
    file:close()

    -- Will be nil if NaN, just like we want it
    return tx_packets
end

function NetworkListener:_unscheduleActivityCheck()
    logger.dbg("NetworkListener: unschedule network activity check")
    if self._activity_check_scheduled then
        UIManager:unschedule(self._scheduleActivityCheck)
        self._activity_check_scheduled = nil
        logger.dbg("NetworkListener: network activity check unscheduled")
    end

    -- We also need to reset the stats, otherwise we'll be comparing apples vs. oranges... (i.e., two different network sessions)
    if self._last_tx_packets then
        self._last_tx_packets = nil
    end
    if self._activity_check_delay_seconds then
        self._activity_check_delay_seconds = nil
    end
end

function NetworkListener:_scheduleActivityCheck()
    logger.dbg("NetworkListener: network activity check")
    local keep_checking = true

    local tx_packets = NetworkListener:_getTxPackets()
    if self._last_tx_packets and tx_packets then
        -- Compute noise threshold based on the current delay
        local delay_seconds = self._activity_check_delay_seconds or default_network_timeout_seconds
        local noise_threshold = delay_seconds / default_network_timeout_seconds * network_activity_noise_margin
        local delta = tx_packets - self._last_tx_packets
        -- If there was no meaningful activity (+/- a couple packets), kill the Wi-Fi
        if delta <= noise_threshold then
            logger.dbg("NetworkListener: No meaningful network activity (delta:", delta, "<= threshold:", noise_threshold, "[ then:", self._last_tx_packets, "vs. now:", tx_packets, "]) -> disabling Wi-Fi")
            keep_checking = false
            local complete_callback = function()
                UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
            end
            UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
            NetworkMgr:turnOffWifi(complete_callback)
            -- NOTE: We leave wifi_was_on as-is on purpose, we wouldn't want to break auto_restore_wifi workflows on the next start...
        else
            logger.dbg("NetworkListener: Significant network activity (delta:", delta, "> threshold:", noise_threshold, "[ then:", self._last_tx_packets, "vs. now:", tx_packets, "]) -> keeping Wi-Fi enabled")
        end
    end

    -- If we've just killed Wi-Fi, onNetworkDisconnected will take care of unscheduling us, so we're done
    if not keep_checking then
        return
    end

    -- Update tracker for next iter
    self._last_tx_packets = tx_packets

    -- If it's already been scheduled, increase the delay until we hit the ceiling
    if self._activity_check_delay_seconds then
        self._activity_check_delay_seconds = self._activity_check_delay_seconds + default_network_timeout_seconds

        if self._activity_check_delay_seconds > max_network_timeout_seconds then
            self._activity_check_delay_seconds = max_network_timeout_seconds
        end
    else
        self._activity_check_delay_seconds = default_network_timeout_seconds
    end

    UIManager:scheduleIn(self._activity_check_delay_seconds, self._scheduleActivityCheck, self)
    self._activity_check_scheduled = true
    logger.dbg("NetworkListener: network activity check scheduled in", self._activity_check_delay_seconds, "seconds")
end

function NetworkListener:onNetworkConnected()
    logger.dbg("NetworkListener: onNetworkConnected")
    if Device:hasWifiManager() then
        -- This is for the sake of events that don't emanate from NetworkMgr itself...
        NetworkMgr:setWifiState(true)
        NetworkMgr:setConnectionState(true)
    end

    if not G_reader_settings:isTrue("auto_disable_wifi") then
        return
    end

    -- If the activity check has already been scheduled for some reason, unschedule it first.
    NetworkListener:_unscheduleActivityCheck()

    NetworkListener:_scheduleActivityCheck()
end

function NetworkListener:onNetworkDisconnected()
    logger.dbg("NetworkListener: onNetworkDisconnected")
    if Device:hasWifiManager() then
        NetworkMgr:setWifiState(false)
        NetworkMgr:setConnectionState(false)
    end

    if not G_reader_settings:isTrue("auto_disable_wifi") then
        return
    end

    NetworkListener:_unscheduleActivityCheck()

    -- Reset NetworkMgr's beforeWifiAction marker
    NetworkMgr:clearBeforeActionFlag()
end

-- Also unschedule on suspend (and we happen to also kill Wi-Fi to do so, so resetting the stats is also relevant here)
function NetworkListener:onSuspend()
    self:onNetworkDisconnected()
end

-- If the platform implements NetworkMgr:restoreWifiAsync, run it as needed
if Device:hasWifiRestore() then
    function NetworkListener:onResume()
        if NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
            logger.dbg("NetworkListener: onResume will restore Wi-Fi in the background")
            NetworkMgr:restoreWifiAsync()
            NetworkMgr:scheduleConnectivityCheck()
        end
    end
end

function NetworkListener:onShowNetworkInfo()
    if Device.retrieveNetworkInfo then
        UIManager:show(InfoMessage:new{
            text = Device:retrieveNetworkInfo(),
            -- IPv6 addresses are *loooooong*!
            face = Font:getFace("x_smallinfofont"),
        })
    else
        UIManager:show(InfoMessage:new{
            text = _("Could not retrieve network info."),
            timeout = 3,
        })
    end
end

return NetworkListener
