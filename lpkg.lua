#!/usr/bin/lua

local olderr = error
local fmt = string.format

local function error(...)
    olderr(fmt(...))
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

local rm = os.remove
local rmdir = os.remove

local function readall(file)
    local f, err = io.open(file)
    if not f then
        error(fmt("got error %q while reading file %q", err, file))
    end
    local str = f:read("*all")
    f:close()
    return str
end

local function writeAll(file, data)
    local f, err = io.open(file, "w")
    if not f then
        error(fmt("got error %s while saving file %s", err, file))
    end
    f:write(data)
    f:close()
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
local config
local repo
local lpkgdir = "/etc/lpkg/"
local pins
local installed
local upd = false

local function loadInstalled()
    if installed then return end
    local inst = {}
    for l in io.lines(fmt("%s/installed.list", lpkgdir)) do
        if l ~= "" then
            inst[l] = true
        end
    end
    installed = inst
end

local function loadConf()
    if config then return end
    config = parseconf(configf)
    repo = config.REPO
    if not repo then
        error("Config does not contain repo")
    end
end

local function loadPins()
    if pins then return end
    local p = {}
    for l in io.lines(fmt("%s/pins.list", lpkgdir)) do
        append(p, l)
    end
    pins = p
end

local function load()
    loadConf()
    loadInstalled()
    loadPins()
end

local function checkSig(file, sig)
    exec("minisign -Vm %s -x %s -p %s/key.pub", file, sig, lpkgdir)
end

local function fetchChk(file)
    download(fmt("%s/%s", repo, file), fmt("%s/%s", dldir, file))
    download(fmt("%s/%s.minisig", repo, file), fmt("%s/%s.minisig", dldir, file))
    checkSig(fmt("%s/%s", dldir, file), fmt("%s/%s.minisig", dldir, file))
end

local function fetchInfo(pkg)
    local pkf = fmt("%s.pkginfo", pkg)
    fetchChk(pkf)
    local info = parseconf(fmt("%s/%s", dldir, pkf))
    if info.NAME ~= pkg then
        error("Name mismatch in package info")
    end
    if type(info.DEPENDENCIES) == "string" then
        info.DEPENDENCIES = {info.DEPENDENCIES}
    end
    return info
end

local function getDeps(pkg, ptbl)
    if ptbl[pkg] then
        return
    end
    local info = fetchInfo(pkg)
    ptbl[pkg] = info
    print(s(info))
    if info.DEPENDENCIES then
        local p
        for _, p in ipairs(info.DEPENDENCIES) do
            getDeps(p, ptbl)
        end
    end
end

local function split(str, sep)
    local o = {}
    for str in string.gmatch(str, "([^"..sep.."]+)") do
        append(o, str)
    end
    return o
end

local function compareVersion(v1, v2)
    local n1 = split(v1, ".")
    local n2 = split(v2, ".")
    local i = 1
    while (n1[i] ~= nil) or (n2[i] ~= nil) do
        local a, b = n1[i], n2[i]
        if a == nil then
            a = "-1"
        end
        if b == nil then
            b = "-1"
        end
        a, b = tonumber(a), tonumber(b)
        if a > b then
            return v1
        elseif a < b then
            return v2
        end
    end
    return v1
end

local function chkConflict(ptbl)
    local p, pc, c
    for _, p in pairs(ptbl) do
        pc = p.CONFLICTS
        if pc then
            for _, c in ipairs(pc) do
                if ptbl[c] then
                    error("%s conflicts with %s", p.NAME, c.NAME)
                end
            end
        end
    end
end

local function loadLocalInfo(pkg)
    return loadf(fmt("%s/db/%s.db", lpkgdir, pkg))
end

local function index(arr)
    local i = {}
    for _, v in ipairs(arr) do
        i[v] = true
    end
    return i
end

local function mergeIndexes(...)
    local is = {...}
    local i = {}
    local ind, k
    for _, ind in ipairs(is) do
        for k, _ in pairs(ind) do
            i[k] = true
        end
    end
    return i
end

local function preOp(new, old)
    local kind = {}
    local p, f
    for _, p in pairs(new) do
        if p.FILES then
            append(kind, index(p.FILES))
        end
    end
    kind = mergeIndexes(table.unpack(kind))
    for _, p in pairs(old) do
        if p.FILES then
            for _, f in ipairs(p.FILES) do
                if not kind[f] then
                    exec("rm %s", f)
                end
            end
        end
    end
end

local function addFileList(pkg, tar)
    local t = io.popen(fmt("tar -tf %s --exclude ./.pkginfo", tar))
    local l, fl
    fl = {}
    for l in t:lines() do
        if l ~= "" then
            append(fl, l)
        end
    end
    pkg.FILES = fl
end

local function shouldInstall(pkg)
    local n = pkg.NAME
    if installed[n] and upd then
        local li = loadLocalInfo(n)
        if compareVersion(li.VERSION, pkg.VERSION) ~= li.VERSION then
            return true
        end
    else
        return true
    end
    return false
end

local function fetchPkg(pkg)
    local pkf = fmt("%s/%s.tar.gz", dldir, pkg.NAME)
    download(fmt("%s/%s.tar.gz", repo, pkg.NAME), pkf)
    local hash = split(io.popen(fmt("sha256sum %s", pkf)):read("*line"), " ")[0]
    if hash ~= pkg.SHA256 then
        error("SHA256 mismatch")
    end
    addFileList(pkg, pkf)
end

local function installPkg(pkgname)
    local pkf = fmt("%s/%s.tar.gz", dldir, pkgname)
    exec("tar -xf %s -C %s --exclude ./.pkginfo", pkf, rootfs)
end

local function loadAllDB()
    local db = {}
    local n
    for n, _ in pairs(installed) do
        db[n] = loadLocalInfo(n)
    end
    return db
end

local function saveDB(pkg)
    writeAll(fmt("%s/db/%s.db", lpkgdir, pkg.NAME), s(pkg))
end

local function saveInstalled()
    local inst = ""
    for n, _ in pairs(installed) do
        inst = inst .. n .. "\n"
    end
    writeAll(fmt("%s/installed.list", lpkgdir), inst)
end

local function saveAllDB(db)
    exec("rm %s/db/*.db", lpkgdir)
    local n, p
    for n, p in pairs(db) do
        saveDB(p)
        installed[n] = true
    end
    saveInstalled()
end

local function install(...)
    load()
    local ptbl = {}
    local pkgs = {...}
    if #pkgs == 0 then
        print("Nothing to install")
    end
    print("Resolving dependencies")
    for _, p in ipairs(pkgs) do
        getDeps(p, ptbl)
    end
    print("Checking for conflicts")
    chkConflict(ptbl)
    print("Checking for packages that are already installed")
    for n, _ in pairs(ptbl) do
        if installed[n] then
            ptbl[n] = nil
        end
    end
    print("Downloading packages")
    local p
    for _, p in pairs(ptbl) do
        fetchPkg(p)
    end
    print("Installing packages")
    for n, _ in pairs(ptbl) do
        printf("Installing %s", n)
        installPkg(n)
    end
    print("Saving database entries")
    for n, p in pairs(ptbl) do
        installed[n] = true
        saveDB(p)
    end
    print("Updating list of installed packages")
    saveInstalled()
end

local function bootstrap(repobase, version, arch, root, ...)
    if (not repobase) or (not version) or (not arch) or (not root) then
        print("Missing arguments to lpkg bootstrap")
        exitcode = 65
        return
    end
    exec("mkdir %s", root)
    rootfs = root
    print("Bootstrapping package manager directory")
    exec("mkdir -p %s/etc/lpkg/db", rootfs)
    lpkgdir = fmt("%s/etc/lpkg", rootfs)
    exec("touch %s/pins.list", lpkgdir)
    exec("touch %s/installed.list", lpkgdir)
    local cnf = fmt("REPO=http://%s/%s/%s/pkgs", repobase, version, arch)
    writeAll(fmt("%s/lpkg.conf", lpkgdir), cnf)
    configf = fmt("%s/lpkg.conf", lpkgdir)
    print("Downloading public key over HTTPS")
    download(fmt("https://%s/minisign.pub", repobase), fmt("%s/key.pub", lpkgdir))
    print("Loading configuration")
    load()
    print("Installing system")
    local pkgs = {...}
    if #pkgs == 0 then
        append(pkgs, "base")
    end
    install(table.unpack(pkgs))
    print("Bootstrap complete")
end

if #arg < 1 then
    print("No command specified.")
    exitcode = 1
else
    local st = {}
    st.install = install
    st.bootstrap = bootstrap
    local cmds = table.remove(arg, 1)
    local cmd = st[cmds]
    if not cmd then
        print(string.format("Invalid command %q", cmds))
        exitcode = 2
    else
        local ok, err = pcall(cmd, table.unpack(arg))
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
