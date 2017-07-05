#!/usr/bin/lua

local function ptbl(tbl)
    local i, v
    for i, v in pairs(tbl) do
        if type(v) == "table" then
            print(i .. ":", table.unpack(v))
        else
            print(i .. ":", v)
        end
    end
end

local fmt = string.format
local function exec(...)
    local vals = {...}
    local success, _, code = os.execute(fmt(...)))
    if success then
        error("something bad")
    end
    --if errcode ~= 0 then
    --    error(fmt("Error executing command %s", vals[1]))
    --end
end

local function readall(file)
    local f = io.open(file)
    local str = f:read("*all")
    f:close()
    return str
end

local function append(tbl, val)
    tbl[#tbl + 1] = val
end

local function sleep(time)
    exec(fmt("sleep %f", time))
end

local function download(url, dest)
    exec("wget %s -O %s", url, dest)
end

local tmps = {}

local function tmpdir()
    local t = io.popen("mktemp -d")
    local dir = t:read("*line")
    t:close()
    append(tmps, dir)
    return dir
end

--parseconf parses config syntax
local function parseconf(conffile)
    local str = readall(conffile)
    local t = {}
    local k, v
    for k, v in string.gmatch(str, "(%w+)=([%w%-%./:]+)") do
        local s = {}
        local d
        for d in v:gmatch("[%w%-%./:]+") do
            append(s, d)
        end
        if #s < 2 then
            t[k] = v
        else
            t[k] = s
        end
    end
    return t
end


--serializer
local st = {}
local function s(v)
    return st[type(v)](v)
end
st.string = function(v)
    return fmt("%q", v)
end
st.integer = function(v)
    return fmt("%d", v)
end
st.number = function(v)
    if v == math.floor(v) then
        return st.integer(v)
    else
        return fmt("%f", v)
    end
end
st.array = function(v)
    local str = "{"
    local d
    for _, d in ipairs(v) do
        str = str .. s(d) .. ","
    end
    return string.sub(str, 1, -2) .. "}"
end
st.table = function(v)
    local i = 0
    for _, _ in ipairs(v) do
        i = i + 1
    end
    for _, _ in pairs(v) do
        i = i - 1
    end
    if i == 0 then
        return st.array(v)
    else
        local str = ""
        local k, d
        for k, d in pairs(v) do
            local key = fmt("[%s]", s(k))
            if type(k) == "string" then
                if not k:match("%A") then
                    key = k
                end
            end
            str = fmt("%s,%s=%s", str, key, s(d))
        end
        return fmt("{%s}",string.sub(str, 2, -1))
    end
end
local function loadf(file)
    return load("return " .. readall(file))()
end

local dldir = tmpdir()
local exitcode = 0
local rootfs = "/"
local configf = "/etc/lpkg/lpkg.conf"
local pkgdb = "/etc/lpkg/lpkg.db"
local config
local db
local repo
local gpgdir

local function loadconf()
    config = parseconf(configf)
end

local function loadDB()
    db = loadf(pkgdb)
end
local function saveDB()
    print("Saving database")
    local dbd = s(db)
    local dbf = io.open(pkgdb, "w")
    dbf:write(dbd)
    dbf:close()
    print("Done saving database")
end

local function load()
    loadconf()
    loadDB()
    repo = config.REPO
    if not repo then
        error("Config does not contain repo")
    end
    gpgdir = config.GPGDIR
    if not gpgdir then
        error("Config does not contain gpgdir")
    end
end

local function fetchpkg(pkg)
    local tar = fmt("%s/%s.tar", dldir, pkg)
    local sig = fmt("%s/%s.sig", dldir, pkg)
    download(fmt("%s/%s.tar.xz", repo, pkg), tar)
    download(fmt("%s/%s.sig", repo, pkg), sig)
    exec("gpgv %s %s", sig, tar)
end

local function readdeps(pkg)
    local tar = fmt("%s/%s.tar", dldir, pkg)
    exec("tar -xf %s -C %s ./.pkginfo", tar, dldir)
    local pkginfo = parseconf(fmt("%s/.pkginfo", dldir))
    return pkginfo.DEPENDENCIES
end

local toinstall = {}

local function preinstall(pkg)
    if db[pkg] then
        return
    end
    fetchpkg(pkg)
    local deps = readdeps(pkg)
    db[pkg] = {}
    if deps then
        local v
        for _, v in ipairs(deps) do
            preinstall(v)
        end
    end
    append(toinstall, pkg)
end

local function install()
    load()
    local v
    for _, v in ipairs(arg) do
        preinstall(v)
    end
    for _, v in ipairs(toinstall) do
        local tar = fmt("%s/%s.tar", dldir, v)
        local cmd = fmt("tar -xvf %s -C %s", tar, rootfs)
        local c = io.popen(cmd)
        local files = {}
        local l
        for l in c:lines() do
            append(files, string.sub(l, 3, -1))
        end
        c:close()
        local dbv = {}
        dbv.files = files
        local cdat = parseconf("/.pkginfo")
        exec("rm /.pkginfo")
        dbv.deps = cdat.DEPENDENCIES
        dbv.version = cdat.VERSION
    end
    saveDB()
    print("Done installing")
end

if #arg < 1 then
    print("No command specified.")
    exitcode = 1
else
    local st = {}
    st.install = install
    local cmds = table.remove(arg, 1)
    local cmd = st[cmds]
    if not cmd then
        print(string.format("Invalid command %q", cmds))
        exitcode = 2
    else
        local ok, err = pcall(cmd)
        if not ok then
            print(err)
            exitcode = 3
        end
    end
end



print("Cleaning up. . . ")
local v
for _, v in ipairs(tmps) do
    os.remove(v)
end
os.exit(exitcode)
