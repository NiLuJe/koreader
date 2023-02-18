--[[--
Generic device abstraction.

This module defines stubs for common methods.
--]]

local DataStorage = require("datastorage")
local Geom = require("ui/geometry")
local logger = require("logger")
local ffi = require("ffi")
local util = require("util")
local _ = require("gettext")
local ffiUtil = require("ffi/util")
local C = ffi.C
local T = ffiUtil.template

-- We'll need a bunch of stuff for getifaddrs & co in Device:retrieveNetworkInfo
require("ffi/posix_h")

local function yes() return true end
local function no() return false end

local function isCommand(s)
    return os.execute("command -v "..s.." >/dev/null") == 0
end

local Device = {
    screen_saver_mode = false,
    screen_saver_lock = false,
    is_cover_closed = false,
    model = nil,
    powerd = nil,
    screen = nil,
    input = nil,
    home_dir = nil,
    -- For Kobo, wait at least 15 seconds before calling suspend script. Otherwise, suspend might
    -- fail and the battery will be drained while we are in screensaver mode
    suspend_wait_timeout = 15,

    -- hardware feature tests: (these are functions!)
    hasBattery = yes,
    hasAuxBattery = no,
    hasKeyboard = no,
    hasKeys = no,
    hasDPad = no,
    hasExitOptions = yes,
    hasFewKeys = no,
    hasWifiToggle = yes,
    hasWifiManager = no,
    isDefaultFullscreen = yes,
    isHapticFeedbackEnabled = no,
    isTouchDevice = no,
    hasFrontlight = no,
    hasNaturalLight = no, -- FL warmth implementation specific to NTX boards (Kobo, Cervantes)
    hasNaturalLightMixer = no, -- Same, but only found on newer boards
    hasNaturalLightApi = no,
    hasClipboard = yes, -- generic internal clipboard on all devices
    hasEinkScreen = yes,
    hasExternalSD = no, -- or other storage volume that cannot be accessed using the File Manager
    canHWDither = no,
    canHWInvert = no,
    canDoSwipeAnimation = no,
    canModifyFBInfo = no, -- some NTX boards do wonky things with the rotate flag after a FBIOPUT_VSCREENINFO ioctl
    canUseCBB = yes, -- The C BB maintains a 1:1 feature parity with the Lua BB, except that is has NO support for BB4, and limited support for BBRGB24
    hasColorScreen = no,
    hasBGRFrameBuffer = no,
    canImportFiles = no,
    canShareText = no,
    hasGSensor = no,
    isGSensorLocked = no,
    canToggleMassStorage = no,
    canToggleChargingLED = no,
    canUseWAL = yes, -- requires mmap'ed I/O on the target FS
    canRestart = yes,
    canSuspend = no,
    canStandby = no,
    canPowerSaveWhileCharging = no,
    total_standby_time = 0, -- total time spent in standby
    last_standby_time = 0,
    total_suspend_time = 0, -- total time spent in suspend
    last_suspend_time = 0,
    canReboot = no,
    canPowerOff = no,
    canAssociateFileExtensions = no,

    -- Start and stop text input mode (e.g. open soft keyboard, etc)
    startTextInput = function() end,
    stopTextInput = function() end,

    -- use these only as a last resort. We should abstract the functionality
    -- and have device dependent implementations in the corresponting
    -- device/<devicetype>/device.lua file
    -- (these are functions!)
    isAndroid = no,
    isCervantes = no,
    isKindle = no,
    isKobo = no,
    isPocketBook = no,
    isRemarkable = no,
    isSonyPRSTUX = no,
    isSDL = no,
    isEmulator = no,
    isDesktop = no,

    -- some devices have part of their screen covered by the bezel
    viewport = nil,
    -- enforce portrait orientation of display when FB defaults to landscape
    isAlwaysPortrait = no,
    -- On some devices (eg newer pocketbook) we can force HW rotation on the fly (before each update)
    -- The value here is table of 4 elements mapping the sensible linux constants to whatever
    -- nonsense the device actually has. Canonically it should return { 0, 1, 2, 3 } if the device
    -- matches <linux/fb.h> FB_ROTATE_* constants.
    -- See https://github.com/koreader/koreader-base/blob/master/ffi/framebuffer.lua for full template
    -- of the table expected.
    usingForcedRotation = function() return nil end,
    -- needs full screen refresh when resumed from screensaver?
    needsScreenRefreshAfterResume = yes,

    -- set to yes on devices that support over-the-air incremental updates.
    hasOTAUpdates = no,

    -- For devices that have non-blocking OTA updates, this function will return true if the download is currently running.
    hasOTARunning = no,

    -- set to yes on devices that have a non-blocking isWifiOn implementation
    -- (c.f., https://github.com/koreader/koreader/pull/5211#issuecomment-521304139)
    hasFastWifiStatusQuery = no,

    -- set to yes on devices with system fonts
    hasSystemFonts = no,

    canOpenLink = no,
    openLink = no,
    canExternalDictLookup = no,
}

function Device:extend(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Inverts PageTurn button mappings
-- NOTE: For ref. on Kobo, stored by Nickel in the [Reading] section as invertPageTurnButtons=true
function Device:invertButtons()
    if self:hasKeys() and self.input and self.input.event_map then
        for key, value in pairs(self.input.event_map) do
            if value == "LPgFwd" then
                self.input.event_map[key] = "LPgBack"
            elseif value == "LPgBack" then
                self.input.event_map[key] = "LPgFwd"
            elseif value == "RPgFwd" then
                self.input.event_map[key] = "RPgBack"
            elseif value == "RPgBack" then
                self.input.event_map[key] = "RPgFwd"
            end
        end

        -- NOTE: We currently leave self.input.rotation_map alone,
        --       which will definitely yield fairly stupid mappings in Landscape...
    end
end

function Device:init()
    if not self.screen then
        error("screen/framebuffer must be implemented")
    end

    -- opt-out of CBB if the device is broken with it
    if not self.canUseCBB() then
        local bb = require("ffi/blitbuffer")
        bb.has_cblitbuffer = false
        bb:enableCBB(false)
    end

    if self.hasMultitouch == nil then
        -- default to assuming multitouch when dealing with a touch device
        self.hasMultitouch = self.isTouchDevice
    end

    self.screen.isColorScreen = self.hasColorScreen
    self.screen.isColorEnabled = function()
        if G_reader_settings:has("color_rendering") then
            return G_reader_settings:isTrue("color_rendering")
        else
            return self.screen.isColorScreen()
        end
    end

    self.screen.isBGRFrameBuffer = self.hasBGRFrameBuffer

    if G_reader_settings:has("low_pan_rate") then
        self.screen.low_pan_rate = G_reader_settings:readSetting("low_pan_rate")
    else
        self.screen.low_pan_rate = self.hasEinkScreen()
    end

    logger.info("initializing for device", self.model)
    logger.info("framebuffer resolution:", self.screen:getRawSize())

    if not self.input then
        self.input = require("device/input"):new{device = self}
    end
    if not self.powerd then
        self.powerd = require("device/generic/powerd"):new{device = self}
    end

    -- NOTE: This needs to run *after* implementation-specific event hooks,
    --       especially if those require swapping/mirroring...
    --       (e.g., Device implementations should setup their own hooks *before* calling this via Generic.init(self)).
    if self.viewport then
        logger.dbg("setting a viewport:", self.viewport)
        self.screen:setViewport(self.viewport)
        if self.viewport.x ~= 0 or self.viewport.y ~= 0 then
            self.input:registerEventAdjustHook(
                self.input.adjustTouchTranslate,
                {x = 0 - self.viewport.x, y = 0 - self.viewport.y}
            )
        end
    end

    -- Handle button mappings shenanigans
    if self:hasKeys() then
        if G_reader_settings:isTrue("input_invert_page_turn_keys") then
            self:invertButtons()
        end
    end

    if self:hasGSensor() then
        -- Setup our standard gyro event handler (EV_MSC:MSC_GYRO)
        if G_reader_settings:nilOrFalse("input_ignore_gsensor") then
            self.input.handleGyroEv = self.input.handleMiscGyroEv
        end

        -- Honor the gyro lock
        if G_reader_settings:isTrue("input_lock_gsensor") then
            self:lockGSensor(true)
        end
    end

    -- Screen:getSize is used throughout the code, and that code usually expects getting a real Geom object...
    -- But as implementations come from base, they just return a Geom-like table...
    self.screen.getSize = function()
        local rect = self.screen.getRawSize(self.screen)
        return Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end
end

function Device:setScreenDPI(dpi_override)
    -- Passing a nil resets to defaults and clears the override flag
    self.screen:setDPI(dpi_override)
    self.input.gesture_detector:init()
end

function Device:getDeviceScreenDPI()
    return self.display_dpi
end

function Device:getPowerDevice()
    return self.powerd
end

function Device:rescheduleSuspend()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self.suspend)
    UIManager:scheduleIn(self.suspend_wait_timeout, self.suspend, self)
end

-- Only used on platforms where we handle suspend ourselves.
function Device:onPowerEvent(ev)
    local Screensaver = require("ui/screensaver")
    if self.screen_saver_mode then
        if ev == "Power" or ev == "Resume" then
            if self.is_cover_closed then
                -- don't let power key press wake up device when the cover is in closed state.
                self:rescheduleSuspend()
            else
                logger.dbg("Resuming...")
                local UIManager = require("ui/uimanager")
                UIManager:unschedule(self.suspend)
                if self:hasWifiManager() then
                    local network_manager = require("ui/network/manager")
                    if network_manager.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
                        network_manager:restoreWifiAsync()
                        network_manager:scheduleConnectivityCheck()
                    end
                end
                self:resume()
                local widget_was_closed = Screensaver:close()
                if widget_was_closed and self:needsScreenRefreshAfterResume() then
                    UIManager:scheduleIn(1, function() self.screen:refreshFull() end)
                end
                self.powerd:afterResume()
            end
        elseif ev == "Suspend" then
            -- Already in screen saver mode, no need to update UI/state before
            -- suspending the hardware. This usually happens when sleep cover
            -- is closed after the device was sent to suspend state.
            logger.dbg("Already in screen saver mode, going back to suspend...")
            -- Much like the real suspend codepath below, in case we got here via screen_saver_lock,
            -- make sure we murder WiFi again (because restore WiFi on resume could have kicked in).
            if self:hasWifiToggle() then
                local network_manager = require("ui/network/manager")
                if network_manager:isWifiOn() then
                    network_manager:releaseIP()
                    network_manager:turnOffWifi()
                end
            end
            self:rescheduleSuspend()
        end
    -- else we were not in screensaver mode
    elseif ev == "Power" or ev == "Suspend" then
        self.powerd:beforeSuspend()
        local UIManager = require("ui/uimanager")
        logger.dbg("Suspending...")
        -- Add the current state of the SleepCover flag...
        logger.dbg("Sleep cover is", self.is_cover_closed and "closed" or "open")
        Screensaver:setup()
        Screensaver:show()
        -- NOTE: show() will return well before the refresh ioctl is even *sent*:
        --       the only thing it's done is *enqueued* the refresh in UIManager's stack.
        --       Which is why the actual suspension needs to be delayed by suspend_wait_timeout,
        --       otherwise, we'd potentially suspend (or attempt to) too soon.
        --       On platforms where suspension is done via a sysfs knob, that'd translate to a failed suspend,
        --       and on platforms where we defer to a system tool, it'd probably suspend too early!
        --       c.f., #6676
        if self:needsScreenRefreshAfterResume() then
            self.screen:refreshFull()
        end
        -- NOTE: In the same vein as above, this is delayed to make sure we update the screen first.
        --       (This, unfortunately, means we can't just move this to Device:_beforeSuspend :/).
        UIManager:scheduleIn(0.1, function()
            -- NOTE: This side of the check needs to be laxer, some platforms can handle Wi-Fi without WifiManager ;).
            if self:hasWifiToggle() then
                local network_manager = require("ui/network/manager")
                -- NOTE: wifi_was_on does not necessarily mean that Wi-Fi is *currently* on! It means *we* enabled it.
                --       This is critical on Kobos (c.f., #3936), where it might still be on from KSM or Nickel,
                --       without us being aware of it (i.e., wifi_was_on still unset or false),
                --       because suspend will at best fail, and at worst deadlock the system if Wi-Fi is on,
                --       regardless of who enabled it!
                if network_manager:isWifiOn() then
                    network_manager:releaseIP()
                    network_manager:turnOffWifi()
                end
            end
            -- Only actually schedule suspension if we're still supposed to go to sleep,
            -- because the Wi-Fi stuff above may have blocked for a significant amount of time...
            if self.screen_saver_mode then
                self:rescheduleSuspend()
            end
        end)
    end
end

function Device:showLightDialog()
    local FrontLightWidget = require("ui/widget/frontlightwidget")
    local UIManager = require("ui/uimanager")
    UIManager:show(FrontLightWidget:new{})
end

function Device:info()
    return self.model
end

function Device:install()
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Update is ready. Install it now?"),
        ok_text = _("Install"),
        ok_callback = function()
            local save_quit = function()
                self:saveSettings()
                UIManager:quit(85)
            end
            UIManager:broadcastEvent(Event:new("Exit", save_quit))
        end,
    })
end


-- Hardware specific method to track opened/closed books (nil on book close)
function Device:notifyBookState(title, document) end

-- Hardware specific method for UI to signal allowed/disallowed standby.
-- The device is allowed to enter standby only from within waitForEvents,
-- and only if allowed state is true at the time of waitForEvents() invocation.
function Device:setAutoStandby(isAllowed) end

-- Hardware specific method to set OS-level file associations to launch koreader. Expects boolean map.
function Device:associateFileExtensions(exts)
    logger.dbg("Device:associateFileExtensions():", util.tableSize(exts), "entries, OS handler missing")
end

-- Hardware specific method to handle usb plug in event
function Device:usbPlugIn() end

-- Hardware specific method to handle usb plug out event
function Device:usbPlugOut() end

-- Hardware specific method to suspend the device
function Device:suspend() end

-- Hardware specific method to resume the device
function Device:resume() end

-- NOTE: These two should ideally run in the background, and only trip the action after a small delay,
--       to give us time to quit first.
--       e.g., os.execute("sleep 1 && shutdown -r now &")
-- Hardware specific method to power off the device
function Device:powerOff() end
-- Hardware specific method to reboot the device
function Device:reboot() end

-- Hardware specific method to initialize network manager module
function Device:initNetworkManager() end

function Device:supportsScreensaver() return false end

-- Device specific method to set datetime
function Device:setDateTime(year, month, day, hour, min, sec) end

-- Device specific method if any setting needs being saved
function Device:saveSettings() end

function Device:isAlwaysFullscreen() return true end
function Device:toggleFullscreen() end

-- Simulates suspend/resume
function Device:simulateSuspend() end
function Device:simulateResume() end

-- Put device into standby, input devices (buttons, touchscreen ...) stay enabled
function Device:standby(max_duration) end

--[[--
Device specific method for performing haptic feedback.

@string type Type of haptic feedback. See <https://developer.android.com/reference/android/view/HapticFeedbackConstants.html>.
--]]
function Device:performHapticFeedback(type) end

-- Device specific method for toggling input events
function Device:setIgnoreInput(enable) return true end

-- Device agnostic method for toggling the GSensor
-- (can be reimplemented if need be, but you really, really should try not to. c.f., Kobo, Kindle & PocketBook)
function Device:toggleGSensor(toggle)
    if not self:hasGSensor() then
        return
    end

    if self.input then
        self.input:toggleGyroEvents(toggle)
    end
end

-- Whether or not the GSensor should be locked to the current orientation (i.e. Portrait <-> Inverted Portrait or Landscape <-> Inverted Landscape only)
function Device:lockGSensor(toggle)
    if not self:hasGSensor() then
        return
    end

    if toggle == true then
        -- Lock GSensor to current roientation
        self.isGSensorLocked = yes
    elseif toggle == false then
        -- Unlock GSensor
        self.isGSensorLocked = no
    else
        -- Toggle it
        if self:isGSensorLocked() then
            self.isGSensorLocked = no
        else
            self.isGSensorLocked = yes
        end
    end
end

-- Device specific method for toggling the charging LED
function Device:toggleChargingLED(toggle) end

-- Device specific method for setting the charging LED to the right state
function Device:setupChargingLED() end

-- Device specific method for enabling a specific amount of CPU cores
-- (Should only be implemented on embedded platforms where we can afford to control that without screwing with the system).
function Device:enableCPUCores(amount) end

-- NOTE: For this to work, all three must be implemented, and getKeyRepeat must be run on init (c.f., Kobo)!
-- Device specific method to get the current key repeat setup
function Device:getKeyRepeat() end
-- Device specific method to disable key repeat
function Device:disableKeyRepeat() end
-- Device specific method to restore key repeat
function Device:restoreKeyRepeat() end

--[[
prepare for application shutdown
--]]
function Device:exit()
    self.screen:close()
    require("ffi/input"):closeAll()
end

function Device:getDefaultRoute(interface)
    local fd = io.open("/proc/net/route", "re")
    if not fd then
        return
    end

    local gateway
    local l = 1
    for line in fd:lines() do
        -- Skip the first line (header)
        if l > 1 then
            local fields = {}
            for field in line:gmatch("%S+") do
                table.insert(fields, field)
            end
            -- Check the requested interface or anything that isn't lo
            if (interface and fields[1] == interface) or (not interface and fields[1] ~= "lo") then
                -- We're looking for something that's up & a gateway
                if bit.band(fields[4], C.RTF_UP) ~= 0 and bit.band(fields[4], C.RTF_GATEWAY) ~= 0 then
                    -- Handle the conversion from network endianness hex string into a human-readable numeric form
                    local sockaddr_in = ffi.new("struct sockaddr_in")
                    sockaddr_in.sin_family = C.AF_INET
                    sockaddr_in.sin_addr.s_addr = tonumber(fields[3], 16)
                    local host = ffi.new("char[?]", C.NI_MAXHOST)
                    local s = C.getnameinfo(ffi.cast("struct sockaddr *", sockaddr_in),
                                            ffi.sizeof("struct sockaddr_in"),
                                            host, C.NI_MAXHOST,
                                            nil, 0,
                                            C.NI_NUMERICHOST)
                    if s ~= 0 then
                        logger.err("Device:getDefaultRoute: getnameinfo:", ffi.string(C.gai_strerror(s)))
                        break
                    else
                        gateway = ffi.string(host)
                        -- If we specified an interface, we're done.
                        -- If we didn't, we'll just keep the last gateway in the routing table...
                        if interface then
                            break
                        end
                    end
                end
            end
        end
        l = l + 1
    end
    fd:close()

    return gateway
end

function Device:retrieveNetworkInfo()
    -- We're going to need a random socket for the MAC query ioctl...
    local socket = C.socket(C.PF_INET, C.SOCK_DGRAM, C.IPPROTO_IP);
    if socket == -1 then
        local errno = ffi.errno()
        logger.err("Device:retrieveNetworkInfo: socket:", ffi.string(C.strerror(errno)))
        return
    end

    local ifaddr = ffi.new("struct ifaddrs *[1]")
    if C.getifaddrs(ifaddr) == -1 then
        local errno = ffi.errno()
        logger.err("Device:retrieveNetworkInfo: getifaddrs:", ffi.string(C.strerror(errno)))
        return false
    end

    -- Build a string rope to format the results
    local results = {}
    local interfaces = {}

    -- Loop over all the network interfaces
    local ifa = ifaddr[0]
    while ifa ~= nil do
        -- Skip over loopback or downed interfaces
        if ifa.ifa_addr ~= nil and
           bit.band(ifa.ifa_flags, C.IFF_UP) ~= 0 and
           bit.band(ifa.ifa_flags, C.IFF_LOOPBACK) == 0 then
            local family = ifa.ifa_addr.sa_family
            if family == C.AF_INET or family == C.AF_INET6 then
                local host = ffi.new("char[?]", C.NI_MAXHOST)
                local s = C.getnameinfo(ifa.ifa_addr,
                                        family == C.AF_INET and ffi.sizeof("struct sockaddr_in") or ffi.sizeof("struct sockaddr_in6"),
                                        host, C.NI_MAXHOST,
                                        nil, 0,
                                        C.NI_NUMERICHOST)
                if s ~= 0 then
                    logger.err("Device:retrieveNetworkInfo:", ffi.string(C.gai_strerror(s)))
                else
                    -- Only print the ifname once
                    local ifname = ffi.string(ifa.ifa_name)
                    if not interfaces[ifname] then
                        table.insert(results, T(_("Interface: %1"), ifname))
                        interfaces[ifname] = true
                        -- Get its MAC address
                        local ifr = ffi.new("struct ifreq")
                        ffi.copy(ifr.ifr_ifrn.ifrn_name, ifa.ifa_name, C.IFNAMSIZ)
                        if C.ioctl(socket, C.SIOCGIFHWADDR, ifr) == -1 then
                            local errno = ffi.errno()
                            logger.err("Device:retrieveNetworkInfo: ioctl:", ffi.string(C.strerror(errno)))
                        else
                            local mac = string.format("%02X:%02X:%02X:%02X:%02X:%02X",
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[0], 0xFF),
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[1], 0xFF),
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[2], 0xFF),
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[3], 0xFF),
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[4], 0xFF),
                                                      bit.band(ifr.ifr_ifru.ifru_hwaddr.sa_data[5], 0xFF))
                            table.insert(results, string.format("MAC: %s", mac))
                        end
                    end

                    if family == C.AF_INET then
                        table.insert(results, string.format("IP: %s", ffi.string(host)))
                        local gw = self:getDefaultRoute(ifname)
                        if gw then
                            table.insert(results, T(_("Default gateway: %1"), gw))
                        end
                    else
                        table.insert(results, string.format("IPV6: %s", ffi.string(host)))
                        --- @todo: Build an IPv6 variant of getDefaultRoute that parses /proc/net/ipv6_route
                    end
                end
            end
        end
        ifa = ifa.ifa_next
    end
    C.freeifaddrs(ifaddr[0])
    C.close(socket)

    --- @fixme: Implement the basics for wireless detection/essid, and fold it inside the interface walk?
    local std_out = io.popen('2>/dev/null iwconfig | grep ESSID | cut -d\\" -f2')
    if std_out then
        local ssid = std_out:read("*l")
        std_out:close()
        table.insert(results, string.format("SSID: %s", ssid))
    end

    -- Only ping a single gateway
    --- @fixme: Prefer the wireless interface, if any.
    local default_gw = self:getDefaultRoute()
    if default_gw then
        table.insert(results, T(_("Default gateway: %1"), default_gw)
        -- NOTE: No -w flag available in the old busybox build used on Legacy Kindles (K4 included)...
        local pingok
        if self:isKindle() and self:hasDPad() then
            pingok = os.execute("ping -q -c1 " .. default_gw .. " > /dev/null")
        else
            pingok = os.execute("ping -q -c1 -w2 " .. default_gw .. " > /dev/null")
        end
        if pingok == 0 then
            table.insert(results, _("Gateway ping successful"))
        else
            table.insert(results, _("Gateway ping FAILED"))
        end
    else
        table.insert(results, _("No default gateway to ping"))
    end

    return table.concat(results, "\n")
end

function Device:setTime(hour, min)
        return false
end

-- Return an integer value to indicate the brightness of the environment. The value should be in
-- range [0, 4].
-- 0: dark.
-- 1: dim, frontlight is needed.
-- 2: neutral, turning frontlight on or off does not impact the reading experience.
-- 3: bright, frontlight is not needed.
-- 4: dazzling.
function Device:ambientBrightnessLevel()
    return 0
end

--- Returns true if the file is a script we allow running
--- Basically a helper method to check a specific list of file extensions for executable scripts
---- @string filename
---- @treturn boolean
function Device:canExecuteScript(file)
    local file_ext = string.lower(util.getFileNameSuffix(file))
    if file_ext == "sh" or file_ext == "py"  then
        return true
    end
end

function Device:isValidPath(path)
    return util.pathExists(path)
end

-- Device specific method to check if the startup script has been updated
function Device:isStartupScriptUpToDate()
    return true
end

function Device:getDefaultCoverPath()
    return DataStorage:getDataDir() .. "/cover.jpg"
end

--- Unpack an archive.
-- Extract the contents of an archive, detecting its format by
-- filename extension. Inspired by luarocks archive_unpack()
-- @param archive string: Filename of archive.
-- @param extract_to string: Destination directory.
-- @return boolean or (boolean, string): true on success, false and an error message on failure.
function Device:unpackArchive(archive, extract_to)
    require("dbg").dassert(type(archive) == "string")
    local BD = require("ui/bidi")
    local ok
    if archive:match("%.tar%.bz2$") or archive:match("%.tar%.gz$") or archive:match("%.tar%.lz$") or archive:match("%.tgz$") then
        ok = self:untar(archive, extract_to)
    else
        return false, T(_("Couldn't extract archive:\n\n%1\n\nUnrecognized filename extension."), BD.filepath(archive))
    end
    if not ok then
        return false, T(_("Extracting archive failed:\n\n%1"), BD.filepath(archive))
    end
    return true
end

function Device:untar(archive, extract_to)
    return os.execute(("./tar xf %q -C %q"):format(archive, extract_to))
end

-- Set device event handlers common to all devices
function Device:_setEventHandlers(UIManager)
    if self:canReboot() then
        UIManager.event_handlers.Reboot = function(message_text)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = message_text or _("Are you sure you want to reboot the device?"),
                ok_text = _("Reboot"),
                ok_callback = function()
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("Reboot"))
                    UIManager:nextTick(UIManager.reboot_action)
                end,
            })
        end
    else
        UIManager.event_handlers.Reboot = function() end
    end

    if self:canPowerOff() then
        UIManager.event_handlers.PowerOff = function(message_text)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = message_text or _("Are you sure you want to power off the device?"),
                ok_text = _("Power off"),
                ok_callback = function()
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("PowerOff"))
                    UIManager:nextTick(UIManager.poweroff_action)
                end,
            })
        end
    else
        UIManager.event_handlers.PowerOff = function() end
    end

    if self:canRestart() then
        UIManager.event_handlers.Restart = function(message_text)
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = message_text or _("This will take effect on next restart."),
                ok_text = _("Restart now"),
                ok_callback = function()
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
                cancel_text = _("Restart later"),
            })
        end
    else
        UIManager.event_handlers.Restart = function(message_text)
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = message_text or _("This will take effect on next restart."),
            })
        end
    end

    self:setEventHandlers(UIManager)
end

-- Devices can add additional event handlers by overwriting this method.
function Device:setEventHandlers(UIManager)
    -- These will be most probably overwritten in the device specific `setEventHandlers`
    UIManager.event_handlers.Suspend = function()
        self:_beforeSuspend(false)
    end
    UIManager.event_handlers.Resume = function()
        self:_afterResume(false)
    end
end

-- The common operations that should be performed before suspending the device.
function Device:_beforeSuspend(inhibit)
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    UIManager:flushSettings()
    UIManager:broadcastEvent(Event:new("Suspend"))

    if inhibit ~= false then
        -- Block input events unrelated to power management
        self.input:inhibitInput(true)

        -- Disable key repeat to avoid useless chatter (especially where Sleep Covers are concerned...)
        self:disableKeyRepeat()
    end
end

-- The common operations that should be performed after resuming the device.
function Device:_afterResume(inhibit)
    if inhibit ~= false then
        -- Restore key repeat
        self:restoreKeyRepeat()

        -- Restore full input handling
        self.input:inhibitInput(false)
    end

    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    UIManager:broadcastEvent(Event:new("Resume"))
end

-- The common operations that should be performed when the device is plugged to a power source.
function Device:_beforeCharging()
    -- Leave the kernel some time to figure it out ;o).
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(1, function() self:setupChargingLED() end)
    UIManager:broadcastEvent(Event:new("Charging"))
end

-- The common operations that should be performed when the device is unplugged from a power source.
function Device:_afterNotCharging()
    -- Leave the kernel some time to figure it out ;o).
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(1, function() self:setupChargingLED() end)
    UIManager:broadcastEvent(Event:new("NotCharging"))
end

return Device
