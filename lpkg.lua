#!/usr/bin/lua

local olderr = error
local oldipairs = ipairs
local oldpairs = pairs
local fmt = string.format

local function error(...)
    olderr(fmt(...))
end

local function ipairs(tbl)
    oldipairs(tbl)
end

local function pairs(tbl)
    oldpairs(tbl)
end

local function printf(...)
    print(fmt(...))
end

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

local function exec(...)
    local vals = {...}
    local success, _, code = os.execute(fmt(...))
    if not success then
        error("something bad")
    end
    --if errcode ~= 0 then
    --    error(fmt("Error executing command %s", vals[1]))
    --end
end

local function rm(name)
    exec("rm %s", name)
end

local function rmdir(name)
    exec("rm -r %s", name)
end

local function readall(file)
    local f, err = io.open(file)
    if not f then
        error(fmt("got error %q while reading file %q", err, file))
    end
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
    for k, v in string.gmatch(str, "(%w+)=([%w%-%./:\" _]+)") do
        local s = {}
        if string.sub(v, 1, 1) == "\"" then
            v = string.sub(v, 2, -2)
        end
        if v ~= "" then
            local d
            for d in v:gmatch("[%w%-%./:_]+") do
                append(s, d)
            end
            if #s < 2 then
                t[k] = v
            else
                t[k] = s
            end
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
    local str = ""
    local d
    for _, d in ipairs(v) do
        str = fmt("%s,%s", str, s(d))
    end
    return fmt("{%s}", string.sub(str, 2, -1))
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
    local dbf, err = io.open(pkgdb, "w")
    if not dbf then
        error(fmt("got error %q while reading file %q", err, pkgdb))
    end
    dbf:write(dbd)
    dbf:close()
    print("Done saving database")
end

local function load()
    if not db then
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
end

local function fetchpkg(pkg)
    local tar = fmt("%s/%s.tar", dldir, pkg)
    local sig = fmt("%s/%s.sig", dldir, pkg)
    download(fmt("%s/%s.tar.xz", repo, pkg), tar)
    download(fmt("%s/%s.sig", repo, pkg), sig)
    exec("gpgv --homedir %s %s %s", gpgdir, sig, tar)
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
        if type(deps) == "string" then
            deps = { deps }
        end
        for _, v in ipairs(deps) do
            preinstall(v)
        end
    end
    append(toinstall, pkg)
end

local function install(args)
    load()
    local v
    for _, v in ipairs(args) do
        preinstall(v)
    end
    ptbl(toinstall)
    for _, v in ipairs(toinstall) do
        local tar = fmt("%s/%s.tar", dldir, v)
        local cmd = fmt("tar -xvf %s -C %s", tar, rootfs)
        local c = io.popen(cmd)
        local files = {}
        local l
        for l in c:lines() do
            l = string.sub(l, 3, -1)
            if l ~= "" and l ~= ".pkginfo" then
                append(files, l)
            end
        end
        c:close()
        local dbv = {}
        dbv.files = files
        local cdat = parseconf(fmt("%s/.pkginfo", rootfs))
        exec("rm %s/.pkginfo", rootfs)
        dbv.deps = cdat.DEPENDENCIES
        dbv.version = cdat.VERSION
        db[v] = dbv
    end
    saveDB()
    print("Done installing")
end

local function remove(args)
    load()
    --step 1: check for packages that are not installed and create a table of packages to remove
    local remove = {}
    local a
    for _, a in ipairs(args) do
        if not db[a] then
            error("Cannot remove package %q which is not installed", a)
        end
        remove[a] = true
    end
    --step 2: look for packages which depend on what we are trying to remove
    local deps = {}
    local name, dbe
    local kg = true
    for name, dbe in pairs(db) do
        if not remove[name] then
            local p
            local d = {}
            for _, p in ipairs(dbe.deps) do
                if remove[p] then
                    append(d, p)
                end
            end
            if #d > 0 then
                deps[name] = d
                kg = false
            end
        end
    end
    if not kg then
        print("Error: other packages depend on what you are trying to remove")
        local n, p
        for n, d in pairs(deps) do
            if #d == 1 then
                printf("Package %q depends on %q", n, d[1])
            else
                printf("Package %q depends on:", n)
                local p
                for _, p in ipairs(d) do
                    printf("\t%s", p)
                end
            end
        end
    end
    --step 3: check what files can be deleted
    local files = {}
    local p
    for _, p in pairs(db) do
        if remove[p] then
            local f
            for _, f in ipairs(db.files) do
                if files[f] ~= 2 then
                    files[f] = 1
                end
            end
        else
            local f
            for _, f in ipairs(db.files) do
                files[f] = 2
            end
        end
    end
    --step 4: seperate file and directories
    local directories = {}
    local f, c
    for f, c in pairs(files) do
        if c == 1 then
            if string.sub(f, -1, -1) == "/" then
                append(directories, f)
            end
            append(files, f)
        end
    end
    --step 5: delete everything
    print("Deleting. . . ")
    for _, f in ipairs(files) do
        rm(f)
    end
    for _, f in ipairs(directories) do
        rmdir(f)
    end
    print("Done!")
end

local function bootstrap(args)
    if #args ~= 2 then
        print("Usage: lpkg install ROOTFS REPO")
        exitcode = 4
        return
    end
    rootfs = args[1]
    configf = rootfs .. configf
    pkgdb = rootfs .. pkgdb
    db = {}
    gpgdir = "~/.gnupg"
    repo = args[2]
    install({"base"})
end

if #arg < 1 then
    print("No command specified.")
    exitcode = 1
else
    local st = {}
    st.install = install
    st.bootstrap = bootstrap
    st.remove = remove
    local cmds = table.remove(arg, 1)
    local cmd = st[cmds]
    if not cmd then
        print(string.format("Invalid command %q", cmds))
        exitcode = 2
    else
        local ok, err = pcall(cmd, arg)
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
