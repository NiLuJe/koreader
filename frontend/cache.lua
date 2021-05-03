--[[
A global LRU cache
]]--

local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5

local CanvasContext = require("document/canvascontext")
if CanvasContext.should_restrict_JIT then
    jit.off(true, true)
end

-- For documentation purposes, here's a battle-tested shell version of calcFreeMem
--[[
    if grep -q 'MemAvailable' /proc/meminfo ; then
        # We'll settle for 85% of available memory to leave a bit of breathing room
        tmpfs_size="$(awk '/MemAvailable/ {printf "%d", $2 * 0.85}' /proc/meminfo)"
    elif grep -q 'Inactive(file)' /proc/meminfo ; then
        # Basically try to emulate the kernel's computation, c.f., https://unix.stackexchange.com/q/261247
        # Again, 85% of available memory
        tmpfs_size="$(awk -v low=$(grep low /proc/zoneinfo | awk '{k+=$2}END{printf "%d", k}') \
            '{a[$1]=$2}
            END{
                printf "%d", (a["MemFree:"]+a["Active(file):"]+a["Inactive(file):"]+a["SReclaimable:"]-(12*low))*0.85;
            }' /proc/meminfo)"
    else
        # Ye olde crap workaround of Free + Buffers + Cache...
        # Take it with a grain of salt, and settle for 80% of that...
        tmpfs_size="$(awk \
            '{a[$1]=$2}
            END{
                printf "%d", (a["MemFree:"]+a["Buffers:"]+a["Cached:"])*0.80;
            }' /proc/meminfo)"
    fi
--]]

-- And here's our simplified Lua version...
local function calcFreeMem()
    local memtotal, memfree, memavailable, buffers, cached

    local meminfo = io.open("/proc/meminfo", "r")
    if meminfo then
        for line in meminfo:lines() do
            if not memtotal then
                memtotal = line:match("^MemTotal:%s-(%d+) kB")
                if memtotal then
                    -- Next!
                    goto continue
                end
            end

            if not memfree then
                memfree = line:match("^MemFree:%s-(%d+) kB")
                if memfree then
                    -- Next!
                    goto continue
                end
            end

            if not memavailable then
                memavailable = line:match("^MemAvailable:%s-(%d+) kB")
                if memavailable then
                    -- Best case scenario, we're done :)
                    break
                end
            end

            if not buffers then
                buffers = line:match("^Buffers:%s-(%d+) kB")
                if buffers then
                    -- Next!
                    goto continue
                end
            end

            if not cached then
                cached = line:match("^Cached:%s-(%d+) kB")
                if cached then
                    -- Ought to be the last entry we care about, we're done
                    break
                end
            end

            ::continue::
        end
        meminfo:close()
    else
        -- Not on Linux?
        return 0, 0
    end

    if memavailable then
        -- Leave a bit of margin, and report 85% of that...
        return math.floor(memavailable * 0.85) * 1024, memtotal * 1024
    else
        -- Crappy Free + Buffers + Cache version, because the zoneinfo approach is a tad hairy...
        -- So, leave an even larger margin, and only report 75% of that...
        return math.floor((memfree + buffers + cached) * 0.75) * 1024, memtotal * 1024
    end
end

local function calcCacheMemSize()
    local min = DGLOBAL_CACHE_SIZE_MINIMUM
    local max = DGLOBAL_CACHE_SIZE_MAXIMUM
    local calc = calcFreeMem() * (DGLOBAL_CACHE_FREE_PROPORTION or 0)
    local size = math.min(max, math.max(min, calc))
    print("Cache size:", size, size / 1024 / 1024)
    return size
end

local cache_path = DataStorage:getDataDir() .. "/cache/"

--[[
-- return a snapshot of disk cached items for subsequent check
--]]
local function getDiskCache()
    local cached = {}
    for key_md5 in lfs.dir(cache_path) do
        local file = cache_path..key_md5
        if lfs.attributes(file, "mode") == "file" then
            cached[key_md5] = file
        end
    end
    return cached
end

local Cache = {
    -- cache configuration:
    max_memsize = calcCacheMemSize(),
    -- cache state:
    current_memsize = 0,
    -- associative cache
    cache = {},
    -- this will hold the LRU order of the cache
    cache_order = {},
    -- disk Cache snapshot
    cached = getDiskCache(),
}

function Cache:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- internal: remove reference in cache_order list
function Cache:_unref(key)
    --print("Cache:_unref", key)
    for i = #self.cache_order, 1, -1 do
        if self.cache_order[i] == key then
            table.remove(self.cache_order, i)
        end
    end
end

-- internal: free cache item
function Cache:_free(key)
    print("Cache:_free", key, self.cache[key])
    if not self.cache[key] then return end
    self.current_memsize = self.current_memsize - self.cache[key].size
    self.cache[key]:onFree()
    self.cache[key] = nil
    print("free'd", key)
end

-- drop an item named via key from the cache
function Cache:drop(key)
    print("Cache: dropping", key, self.current_memsize, self.current_memsize / 1024 / 1024)
    self:_unref(key)
    self:_free(key)
    print("Cache size now:", self.current_memsize, self.current_memsize / 1024 / 1024)
end

function Cache:insert(key, object)
    print("Cache: inserting", object.size, object.size / 1024 / 1024, "at", key)
    -- make sure that one key only exists once: delete existing
    self:drop(key)
    -- guarantee that we have enough memory in cache
    if (object.size > self.max_memsize) then
        logger.warn("too much memory claimed for", key)
        return
    end
    -- delete objects that least recently used
    -- (they are at the end of the cache_order array)
    while self.current_memsize + object.size > self.max_memsize do
        print("Evicting LRU")
        local removed_key = table.remove(self.cache_order)
        self:_free(removed_key)
    end
    -- insert new object in front of the LRU order
    table.insert(self.cache_order, 1, key)
    self.cache[key] = object
    self.current_memsize = self.current_memsize + object.size
    print("Cache size now:", self.current_memsize, self.current_memsize / 1024 / 1024, self.cache[key])
end

--[[
--  check for cache item for key
--  if ItemClass is given, disk cache is also checked.
--]]
function Cache:check(key, ItemClass)
    if self.cache[key] then
        if self.cache_order[1] ~= key then
            -- put key in front of the LRU list
            self:_unref(key)
            table.insert(self.cache_order, 1, key)
        end
        return self.cache[key]
    elseif ItemClass then
        local cached = self.cached[md5(key)]
        if cached then
            local item = ItemClass:new{}
            local ok, msg = pcall(item.load, item, cached)
            if ok then
                self:insert(key, item)
                return item
            else
                logger.warn("discard cache", msg)
            end
        end
    end
end

function Cache:willAccept(size)
    print("Cache:willAccept", size, size / 1024 / 1024)
    -- we only allow single objects to fill 75% of the cache
    if size*4 < self.max_memsize*3 then
        print("true")
        return true
    end
    print("false")
end

function Cache:serialize()
    -- calculate disk cache size
    local cached_size = 0
    local sorted_caches = {}
    for _, file in pairs(self.cached) do
        table.insert(sorted_caches, {file=file, time=lfs.attributes(file, "access")})
        cached_size = cached_size + (lfs.attributes(file, "size") or 0)
    end
    table.sort(sorted_caches, function(v1,v2) return v1.time > v2.time end)
    -- only serialize the most recently used cache
    local cache_size = 0
    for _, key in ipairs(self.cache_order) do
        local cache_item = self.cache[key]

        -- only dump cache item that requests serialization explicitly
        if cache_item.persistent and cache_item.dump then
            local cache_full_path = cache_path..md5(key)
            local cache_file_exists = lfs.attributes(cache_full_path)

            if cache_file_exists then break end

            logger.dbg("dump cache item", key)
            cache_size = cache_item:dump(cache_full_path) or 0
            if cache_size > 0 then break end
        end
    end
    -- set disk cache the same limit as memory cache
    while cached_size + cache_size - self.max_memsize > 0 do
        -- discard the least recently used cache
        local discarded = table.remove(sorted_caches)
        cached_size = cached_size - lfs.attributes(discarded.file, "size")
        os.remove(discarded.file)
    end
    -- disk cache may have changes so need to refresh disk cache snapshot
    self.cached = getDiskCache()
end

-- Blank the cache
function Cache:clear()
    for k, _ in pairs(self.cache) do
        self.cache[k]:onFree()
    end
    self.cache = {}
    self.cache_order = {}
    self.current_memsize = 0
end

-- Terribly crappy workaround: evict half the cache if we appear to be redlining on free RAM...
function Cache:redlineCheck()
    local memfree, memtotal = calcFreeMem()
    print("Free:", memfree, "Total:", memtotal, memfree / memtotal)

    -- Nonsensical values? (!Linux), skip this.
    if memtotal == 0 then
        return
    end

    -- If less that 20% of the total RAM is free, drop half the Cache...
    if memfree / memtotal < 0.20 then
        logger.warn("Running low on memory, evicting half of the cache...")
        for i = #self.cache_order / 2, 1, -1 do
            print("Emergency eviction")
            local removed_key = table.remove(self.cache_order)
            self:_free(removed_key)
        end

        -- And finish by forcing a GC sweep now...
        collectgarbage()
        collectgarbage()
    end
end

-- Refresh the disk snapshot (mainly used by ui/data/onetime_migration)
function Cache:refreshSnapshot()
    self.cached = getDiskCache()
end

return Cache
