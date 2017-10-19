#!/usr/bin/lua

local rootfs = "/"
local configf = "/etc/lpkg.d/lpkg.conf"
local config
local db
local lpkgdir
local repo
local https = false


local olderr = error
local fmt = string.format

local function error(...)
    olderr(fmt(...))
end

local function printf(...)
    print(fmt(...))
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
    print(fmt(...))
    local vals = {...}
    local success, _, code = os.execute(fmt(...))
    if not success then
        error("something bad")
    end
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

local function split(str, sep)
    local o = {}
    for str in string.gmatch(str, "([^"..sep.."]+)") do
        append(o, str)
    end
    return o
end

local function addFileList(pkg, tar)
    local t = io.popen(fmt("tar -tf %s --exclude ./.pkginfo", tar))
    local l, fl
    fl = {}
    for l in t:lines() do
        if l ~= "" and l ~= "./" then
            append(fl, l)
        end
    end
    pkg.FILES = fl
end

local function sleep(time)
    exec(fmt("sleep %f", time))
end

local function download(url, dest)
    if https then
        exec("curl https://%s -o %s", url, dest)
    else
        exec("wget http://%s -O %s", url, dest)
    end
end

local tmps = {}

local function tmpdir()
    local t = io.popen("mktemp -d")
    local dir = t:read("*line")
    t:close()
    append(tmps, dir)
    return dir
end

local dldir = tmpdir()

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

local function loadConf()
    if config then return end
    config = parseconf(configf)
    repo = config.REPO
    if not repo then
        error("Config does not contain repo")
    end
    lpkgdir = config.LPKGDIR
    if not lpkgdir then
        lpkgdir = rootfs .. "/etc/lpkg.d"
    end
    https = config.https
    pins = loadf(lpkgdir .. "/pins.list")
end

--concRun runs functions concurrently (can be nested)
local function concRun(...)
    local c = {...}
    for i, f in ipairs(c) do
        c[i] = coroutine.create(f)
    end
    while true do
        local a = false
        for i, t in ipairs(c) do
            if t then
                local ok = coroutine.resume(t)
                if not ok then
                    c[i] = nil
                end
                a = true
            end
        end
        if a then
            sleep(0.1)
        else
            return
        end
    end
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
    if not info.DEPENDENCIES then
        info.DEPENDENCIES = {}
    end
    if type(info.DEPENDENCIES) == "string" then
        info.DEPENDENCIES = {info.DEPENDENCIES}
    end
    return info
end

local function resolveDeps(deptbl, pkgname)
    local info = fetchInfo(pkgname)
    deptbl[pkgname] = info
    local cf = {}
    for _, p in ipairs(info.DEPENDENCIES) do
        if not deptbl[p] then
            append(cf, function()
                resolveDeps(deptbl, p)
            end)
        end
    end
    concRun(table.unpack(cf))
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

local function compareVersion(v1, v2)
    local n1 = split(v1, ".")
    local n2 = split(v2, ".")
    local i = 1
    if v1 == "local" or v2 == "local" then
        return "local"
    end
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

local function diffState(old, new)
    print("Old:", s(old))
    print()
    print("New:", s(new))
    local i, r, u, n = {}, {}, {}, {}
    for n, p in pairs(new) do
        if old[n] then  --either upgrade or nothing
            if compareVersion(old.VERSION, new.VERSION) ~= old.VERSION then
                append(u, p)
            else
                append(n, p)
            end
        else
            append(i, p)
        end
    end
    for n, p in pairs(old) do
        if not new[n] then
            append(r, p)
        end
    end
    return i, r, u, n
end

local function buildFileList(state)
    local l = {}
    for _, p in pairs(state) do
        for _, f in ipairs(p.FILES) do
            append(l, f)
        end
    end
    return l
end

local function index(arr)
    local i = {}
    for _, v in ipairs(arr) do
        i[v] = true
    end
    return i
end

local function deleteOld(old, new)
    local o = buildFileList(old)
    local n = buildFileList(new)
    local ni = index(n)
    for _, f in ipairs(o) do
        if not ni[f] then
            exec("rm -rf %s/%s", rootfs, f)
        end
    end
end

local function list(state)
    local s = ""
    for _, p in ipairs(state) do
        s = s .. p.NAME .. " "
    end
    return s
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

function exists(file)
   local f = io.open(file, "r")
   if f ~= nil then
       io.close(f)
       return true
   else
       return false
   end
end

local function installPkg(pkg)
    local pkf = fmt("%s/%s.tar.gz", dldir, pkg.NAME)
    exec("tar -xf %s -C %s --exclude ./.pkginfo", pkf, rootfs)
    if exists(fmt("%s/.oninstall", rootfs)) then
        if rootfs == "/" then
            exec("/.oninstall")
        else
            exec("chroot %s /.oninstall", rootfs)
        end
        os.remove(fmt("%s/.oninstall", rootfs))
    end
end

local function transaction(old, npins)
    local new = {}
    for _, p in ipairs(npins) do
        resolveDeps(new, p)
    end
    local i, r, u, n = diffState(old, new)
    if #i > 0 then
        printf("To install: %s", list(i))
    end
    if #r > 0 then
        printf("To remove: %s", list(r))
    end
    if #u > 0 then
        printf("To update: %s", list(u))
    end
    --TODO: prompt user
    print("Downloading. . . ")
    local ni = index(n)
    for _, p in ipairs(n) do
        ni[p.NAME].FILES = p.FILES
    end
    ni = nil
    local ex = {}
    for ind, p in ipairs(i) do
        ex[ind] = p
    end
    for _, p in ipairs(u) do
        ex[#ex + 1] = p
    end
    for _, p in ipairs(ex) do
        fetchPkg(p)
    end
    print("Download complete")
    print("Installing packages to root fs")
    for _, p in ipairs(ex) do
        installPkg(p)
    end
    print("Deleting old files. . . ")
    deleteOld(old, new)
    print("Transaction complete")
    return new
end

local function inst(rm, ...)
    loadConf()
    local db = loadf(lpkgdir .. "/db.db")
    local np = {...}
    local npins = {}
    local opins = index(pins)
    if rm then
        for _, p in ipairs(np) do
            if opins[p] then
                opins[p] = false
            end
        end
        for p, g in ipairs(opins) do
            if g then
                append(npins, p)
            end
        end
    else
        for _, p in ipairs(pins) do
            append(npins, p)
        end
        for _, p in pairs(np) do
            if not opins[p] then
                append(npins, p)
            end
        end
    end
    local db = transaction(db, npins)
    print("Saving DB")
    writeAll(fmt("%s/db.db", lpkgdir), s(db))
    writeAll(fmt("%s/pins.list", lpkgdir), s(npins))
    print("Done!")
end

local function install(...)
    local pkgs = {...}
    if #pkgs == 0 then
        print("Nothing to install")
    else
        inst(false, ...)
    end
end

local function update(...)
    local a = {...}
    if #a > 0 then
        error("Update does not take arguments")
    end
    inst()
end

local function remove(...)
    local pkgs = {...}
    if #pkgs == 0 then
        print("Nothing to remove")
    else
        inst(true, ...)
    end
end

local function bootstrap(repobase, version, arch, root, ...)
    if (not repobase) or (not version) or (not arch) or (not root) then
        print("Missing arguments to lpkg bootstrap")
        exitcode = 65
        return
    end
    print("Preparing initial package manager data")
    exec("mkdir -p %s/etc/lpkg.d", root)
    rootfs = root
    lpkgdir = fmt("%s/etc/lpkg.d", rootfs)
    writeAll(lpkgdir .. "/db.db", s({}))
    writeAll(fmt("%s/pins.list", lpkgdir),s({}))
    local cnf = fmt("REPO=%s/%s/%s/pkgs", repobase, version, arch)
    configf = fmt("%s/lpkg.conf", lpkgdir)
    writeAll(configf, cnf)
    print("Downloading public key")
    https = true
    download(fmt("%s/minisign.pub", repobase), fmt("%s/key.pub", lpkgdir))
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
    st.bootstrap = bootstrap
    st.install = install
    st.remove = remove
    st.update = update
    local cmds = table.remove(arg, 1)
    local cmd = st[cmds]
    if not cmd then
        print(string.format("Invalid command %q", cmds))
        exitcode = 2
    else
        cmd(table.unpack(arg))
        --local ok, err = pcall(cmd, table.unpack(arg))
        --if not ok then
        --    print(err)
        --    exitcode = 3
        --end
    end
end

print("Cleaning up. . . ")
local v
for _, v in ipairs(tmps) do
    exec("rm -rf %s", v)
end
os.exit(exitcode)
