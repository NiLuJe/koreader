--[[
Centralizes any and all one time migration concerns.
--]]

local DataStorage = require("datastorage")
local Version = require("version")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

-- Retrieve the last migration version
local from_version = G_reader_settings:readSetting("last_migration_version", 0)

-- Keep this in rough chronological order, with a reference to the PR that implemented the change.

-- Global settings, https://github.com/koreader/koreader/pull/4945 & https://github.com/koreader/koreader/pull/5655
-- Limit the check to the most recent update. ReaderUI calls this one unconditionally to update docsettings, too.
if from_version < Version:getNormalizedVersion("v2019.12") then
    logger.info("Running one-time migration for v2019.12")

    local SettingsMigration = require("ui/data/settings_migration")
    SettingsMigration:migrateSettings(G_reader_settings)
end

-- ScreenSaver, https://github.com/koreader/koreader/pull/7371
if from_version < Version:getNormalizedVersion("v2021.03") then
    logger.info("Running one-time migration for v2021.03")

    -- Migrate settings from 2021.02 or older.
    if G_reader_settings:readSetting("screensaver_type") == "message" then
        G_reader_settings:saveSetting("screensaver_type", "disable")
        G_reader_settings:makeTrue("screensaver_show_message")
    end
    if G_reader_settings:has("screensaver_no_background") then
        if G_reader_settings:isTrue("screensaver_no_background") then
            G_reader_settings:saveSetting("screensaver_background", "none")
        end
        G_reader_settings:delSetting("screensaver_no_background")
    end
    if G_reader_settings:has("screensaver_white_background") then
        if G_reader_settings:isTrue("screensaver_white_background") then
            G_reader_settings:saveSetting("screensaver_background", "white")
        end
        G_reader_settings:delSetting("screensaver_white_background")
    end
end

-- Statistics, https://github.com/koreader/koreader/pull/7471
if from_version < Version:getNormalizedVersion("v2021.03-12") then
    logger.info("Running one-time migration for v2021.03-12")

    local statistics = G_reader_settings:readSetting("statistics", {})
    count = 0
    for _, _ in pairs(statistics) do
        count = count + 1
    end

    -- If we don't have the full set of keys, wipe the table to let the plugin re-initialize it correctly.
    if count < 8 then
        G_reader_settings:delSetting("statistics")
    end
end

-- ScreenSaver, https://github.com/koreader/koreader/pull/7496
if from_version < Version:getNormalizedVersion("v2021.03-35") then
    logger.info("Running one-time migration for v2021.03-35")

    -- Migrate settings from 2021.03 or older.
    if G_reader_settings:has("screensaver_background") then
        G_reader_settings:saveSetting("screensaver_img_background", G_reader_settings:readSetting("screensaver_background"))
        G_reader_settings:delSetting("screensaver_background")
    end
end

-- Fontlist, cache migration, https://github.com/koreader/koreader/pull/7524
if from_version < Version:getNormalizedVersion("v2021.03-43") then
    logger.info("Running one-time migration for v2021.03-43")

    -- NOTE: Before 2021.04, fontlist used to squat our folder, needlessly polluting our state tracking.
    local cache_path = DataStorage:getDataDir() .. "/cache"
    local new_path = cache .. "/fontlist"
    lfs.mkdir(new_path)
    os.rename(cache_path .. "/fontinfo.dat", new_path .. "/fontinfo.dat")
end

-- Calibre, cache migration, https://github.com/koreader/koreader/pull/7528
if from_version < Version:getNormalizedVersion("v2021.03-47") then
    logger.info("Running one-time migration for v2021.03-47")

    -- Ditto for Calibre
    local cache_path = DataStorage:getDataDir() .. "/cache"
    local new_path = cache .. "/calibre"
    lfs.mkdir(new_path)
    os.rename(cache_path .. "/calibre-libraries.lua", new_path .. "/libraries.lua")
    os.rename(cache_path .. "/calibre-books.dat", new_path .. "/books.dat")
end

-- We're done, store the current migration version
G_reader_settings:saveSetting("last_migration_version", Version:getNormalizedCurrentVersion())
