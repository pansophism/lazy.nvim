---@diagnostic disable: duplicate-doc-alias
---@diagnostic disable: duplicate-doc-field
---@diagnostic disable: duplicate-set-field

-- interop with the native Neovim cache
if type(package.loaded["vim.cache"]) == "table" then
  return package.loaded["vim.cache"]
end

-- NEOVIM
local uv = vim.loop

local M = {}

---@alias CacheHash {mtime: {sec:number, nsec:number}, size:number}
---@alias CacheEntry {hash:CacheHash, chunk:string}

---@class CacheFindOpts
---@field rtp? boolean Search for modname in the runtime path (defaults to `true`)
---@field patterns? string[] Paterns to use (defaults to `{"/init.lua", ".lua"}`)
---@field paths? string[] Extra paths to search for modname

M.VERSION = 3
M.path = vim.fn.stdpath("cache") .. "/luac"
M.enabled = false
---@type table<string, {total:number, time:number, [string]:number?}?>
M.stats = {
  find = { total = 0, time = 0, not_found = 0 },
}

---@class ModuleCache
---@field _rtp string[]
---@field _rtp_pure string[]
---@field _rtp_key string
local Cache = {
  ---@type table<string, table<string,true>>
  _indexed = {},
  ---@type table<string, string[]>
  _topmods = {},
  _loadfile = loadfile,
}

--- Tracks the time spent in a function
---@private
function M._track(stat, start)
  M.stats[stat] = M.stats[stat] or { total = 0, time = 0 }
  M.stats[stat].total = M.stats[stat].total + 1
  M.stats[stat].time = M.stats[stat].time + uv.hrtime() - start
end

--- slightly faster/different version than vim.fs.normalize
--- we also need to have it here, since the cache will load vim.fs
---@private
function Cache.normalize(path)
  if path:sub(1, 1) == "~" then
    local home = vim.loop.os_homedir() or "~"
    if home:sub(-1) == "\\" or home:sub(-1) == "/" then
      home = home:sub(1, -2)
    end
    path = home .. path:sub(2)
  end
  path = path:gsub("\\", "/"):gsub("/+", "/")
  return path:sub(-1) == "/" and path:sub(1, -2) or path
end

--- Gets the rtp excluding after directories.
--- The result is cached, and will be updated if the runtime path changes.
--- When called from a fast event, the cached value will be returned.
--- @return string[] rtp, boolean updated
---@private
function Cache.get_rtp()
  local start = uv.hrtime()
  if vim.in_fast_event() then
    M._track("get_rtp", start)
    return (Cache._rtp or {}), false
  end
  local updated = false
  local key = vim.go.rtp
  if key ~= Cache._rtp_key then
    Cache._rtp = {}
    for _, path in ipairs(vim.api.nvim_get_runtime_file("", true)) do
      path = Cache.normalize(path)
      -- skip after directories
      if path:sub(-6, -1) ~= "/after" and not (Cache._indexed[path] and vim.tbl_isempty(Cache._indexed[path])) then
        Cache._rtp[#Cache._rtp + 1] = path
      end
    end
    updated = true
    Cache._rtp_key = key
  end
  M._track("get_rtp", start)
  return Cache._rtp, updated
end

--- Returns the cache file name
---@param name string can be a module name, or a file name
---@return string file_name
---@private
function Cache.cache_file(name)
  local ret = M.path .. "/" .. name:gsub("[/\\:]", "%%")
  return ret:sub(-4) == ".lua" and (ret .. "c") or (ret .. ".luac")
end

--- Saves the cache entry for a given module or file
---@param name string module name or filename
---@param entry CacheEntry
---@private
function Cache.write(name, entry)
  local cname = Cache.cache_file(name)
  local f = assert(uv.fs_open(cname, "w", 438))
  local header = {
    M.VERSION,
    entry.hash.size,
    entry.hash.mtime.sec,
    entry.hash.mtime.nsec,
  }
  uv.fs_write(f, table.concat(header, ",") .. "\0")
  uv.fs_write(f, entry.chunk)
  uv.fs_close(f)
end

--- Loads the cache entry for a given module or file
---@param name string module name or filename
---@return CacheEntry?
---@private
function Cache.read(name)
  local start = uv.hrtime()
  local cname = Cache.cache_file(name)
  local f = uv.fs_open(cname, "r", 438)
  if f then
    local hash = uv.fs_fstat(f) --[[@as CacheHash]]
    local data = uv.fs_read(f, hash.size, 0) --[[@as string]]
    uv.fs_close(f)

    local zero = data:find("\0", 1, true)

    ---@type integer[]|{[0]:integer}
    local header = vim.split(data:sub(1, zero - 1), ",")
    if tonumber(header[1]) ~= M.VERSION then
      return
    end
    M._track("read", start)
    return {
      hash = { size = tonumber(header[2]), mtime = { sec = tonumber(header[3]), nsec = tonumber(header[4]) } },
      chunk = data:sub(zero + 1),
    }
  end
  M._track("read", start)
end

--- The `package.loaders` loader for lua files using the cache.
---@param modname string module name
---@return string|function
---@private
function Cache.loader(modname)
  local start = uv.hrtime()
  local modpath, hash = M.find(modname)
  if modpath then
    local chunk, err = M.load(modpath, { hash = hash })
    M._track("loader", start)
    return chunk or error(err)
  end
  M._track("loader", start)
  return "\ncache_loader: module " .. modname .. " not found"
end

--- The `package.loaders` loader for libs
---@param modname string module name
---@return string|function
---@private
function Cache.loader_lib(modname)
  local start = uv.hrtime()
  local modpath = M.find(modname, { patterns = jit.os:find("Windows") and { ".dll" } or { ".so" } })
  ---@type function?, string?
  if modpath then
    -- Making function name in Lua 5.1 (see src/loadlib.c:mkfuncname) is
    -- a) strip prefix up to and including the first dash, if any
    -- b) replace all dots by underscores
    -- c) prepend "luaopen_"
    -- So "foo-bar.baz" should result in "luaopen_bar_baz"
    local dash = modname:find("-", 1, true)
    local funcname = dash and modname:sub(dash + 1) or modname
    local chunk, err = package.loadlib(modpath, "luaopen_" .. funcname:gsub("%.", "_"))
    M._track("loader_lib", start)
    return chunk or error(err)
  end
  M._track("loader_lib", start)
  return "\ncache_loader_lib: module " .. modname .. " not found"
end

--- `loadfile` using the cache
---@param filename? string
---@param mode? "b"|"t"|"bt"
---@param env? table
---@return function?, string?  error_message
---@private
-- luacheck: ignore 312
function Cache.loadfile(filename, mode, env)
  local start = uv.hrtime()
  filename = Cache.normalize(filename)
  mode = nil -- ignore mode, since we byte-compile the lua source files
  local chunk, err = M.load(filename, { mode = mode, env = env })
  M._track("loadfile", start)
  return chunk, err
end

--- Checks whether two cache hashes are the same based on:
--- * file size
--- * mtime in seconds
--- * mtime in nanoseconds
---@param h1 CacheHash
---@param h2 CacheHash
---@private
function Cache.eq(h1, h2)
  return h1 and h2 and h1.size == h2.size and h1.mtime.sec == h2.mtime.sec and h1.mtime.nsec == h2.mtime.nsec
end

--- Loads the given module path using the cache
---@param modpath string
---@param opts? {hash?: CacheHash, mode?: "b"|"t"|"bt", env?:table} (table|nil) Options for loading the module:
---    - hash: (table) the hash of the file to load if it is already known. (defaults to `vim.loop.fs_stat({modpath})`)
---    - mode: (string) the mode to load the module with. "b"|"t"|"bt" (defaults to `nil`)
---    - env: (table) the environment to load the module in. (defaults to `nil`)
---@see |luaL_loadfile()|
---@return function?, string? error_message
function M.load(modpath, opts)
  local start = uv.hrtime()

  opts = opts or {}
  local hash = opts.hash or uv.fs_stat(modpath)
  ---@type function?, string?
  local chunk, err

  if not hash then
    -- trigger correct error
    chunk, err = Cache._loadfile(modpath, opts.mode, opts.env)
    M._track("load", start)
    return chunk, err
  end

  local entry = Cache.read(modpath)
  if entry and Cache.eq(entry.hash, hash) then
    -- found in cache and up to date
    -- selene: allow(incorrect_standard_library_use)
    chunk, err = load(entry.chunk --[[@as string]], "@" .. modpath, opts.mode, opts.env)
    if not (err and err:find("cannot load incompatible bytecode", 1, true)) then
      M._track("load", start)
      return chunk, err
    end
  end
  entry = { hash = hash, modpath = modpath }

  chunk, err = Cache._loadfile(modpath, opts.mode, opts.env)
  if chunk then
    entry.chunk = string.dump(chunk)
    Cache.write(modpath, entry)
  end
  M._track("load", start)
  return chunk, err
end

--- Finds the module path for the given module name
---@param modname string
---@param opts? CacheFindOpts (table|nil) Options for finding a module:
---    - rtp: (boolean) Search for modname in the runtime path (defaults to `true`)
---    - patterns: (string[]) Paterns to use (defaults to `{"/init.lua", ".lua"}`)
---    - paths: (string[]) Extra paths to search for modname (defaults to `{}`)
---@return string? modpath, CacheHash? hash (string|nil) modpath for the module
function M.find(modname, opts)
  local start = uv.hrtime()
  opts = opts or {}

  modname = modname:gsub("/", ".")
  local basename = modname:gsub("%.", "/")
  local idx = modname:find(".", 1, true)

  -- HACK: fix incorrect require statements. Really not a fan of keeping this,
  -- but apparently the regular lua loader also allows this
  if idx == 1 then
    modname = modname:gsub("^%.+", "")
    basename = modname:gsub("%.", "/")
    idx = modname:find(".", 1, true)
  end

  -- get the top-level module name
  local topmod = idx and modname:sub(1, idx - 1) or modname

  -- OPTIM: search for a directory first when topmod == modname
  local patterns = opts.patterns or (topmod == modname and { "/init.lua", ".lua" } or { ".lua", "/init.lua" })
  for p, pattern in ipairs(patterns) do
    patterns[p] = "/lua/" .. basename .. pattern
  end

  -- Checks if the given paths contain the top-level module.
  -- If so, it tries to find the module path for the given module name.
  ---@param paths string[]
  ---@return string? modpath, CacheHash? hash
  ---@private
  local function _find(paths)
    for _, path in ipairs(paths) do
      if M.lsmod(path)[topmod] then
        for _, pattern in ipairs(patterns) do
          local modpath = path .. pattern
          M.stats.find.stat = (M.stats.find.stat or 0) + 1
          local hash = uv.fs_stat(modpath)
          if hash then
            return modpath, hash
          end
        end
      end
    end
  end

  ---@type string?, CacheHash?
  local modpath, hash

  -- always check the rtp first
  if opts.rtp ~= false then
    modpath, hash = _find(Cache._rtp or {})
    if not modpath then
      local rtp, updated = Cache.get_rtp()
      if updated then
        modpath, hash = _find(rtp)
      end
    end
  end

  -- check any additional paths
  if (not modpath) and opts.paths then
    modpath, hash = _find(opts.paths)
  end

  M._track("find", start)
  if modpath then
    return modpath, hash
  end

  -- module not found
  M.stats.find.not_found = M.stats.find.not_found + 1
end

--- Resets the topmods cache for the path
---@param path string path to reset
function M.reset(path)
  Cache._indexed[Cache.normalize(path)] = nil
end

--- Enables the cache:
--- * override loadfile
--- * adds the lua loader
--- * adds the libs loader
--- * remove the Neovim loader
function M.enable()
  if M.enabled then
    return
  end
  M.enabled = true
  vim.fn.mkdir(vim.fn.fnamemodify(M.path, ":p"), "p")
  -- selene: allow(global_usage)
  _G.loadfile = Cache.loadfile
  -- add lua loader
  table.insert(package.loaders, 2, Cache.loader)
  -- add libs loader
  table.insert(package.loaders, 3, Cache.loader_lib)
  -- remove Neovim loader
  for l, loader in ipairs(package.loaders) do
    if loader == vim._load_package then
      table.remove(package.loaders, l)
      break
    end
  end

  -- this will reset the top-mods in case someone adds a new
  -- top-level lua module to a path already on the rtp
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = vim.api.nvim_create_augroup("cache_topmods_reset", { clear = true }),
    callback = function(event)
      local bufname = event.match ---@type string
      local idx = bufname:find("/lua/", 1, true)
      if idx then
        M.reset(bufname:sub(1, idx - 1))
      end
    end,
  })
end

--- Disables the cache:
--- * removes the cache loaders
--- * adds the Neovim loader
function M.disable()
  if not M.enabled then
    return
  end
  M.enabled = false
  -- selene: allow(global_usage)
  _G.loadfile = Cache._loadfile
  ---@diagnostic disable-next-line: no-unknown
  for l, loader in ipairs(package.loaders) do
    if loader == Cache.loader or loader == Cache.loader_lib then
      table.remove(package.loaders, l)
    end
  end
  table.insert(package.loaders, 2, vim._load_package)
  vim.api.nvim_del_augroup_by_name("cache_topmods_reset")
end

--- Return the top-level `/lua/*` modules for this path
---@param path string path to check for top-level lua modules
---@return string[]
function M.lsmod(path)
  if not Cache._indexed[path] then
    local start = uv.hrtime()
    Cache._indexed[path] = {}
    local handle = vim.loop.fs_scandir(path .. "/lua")
    while handle do
      local name, t = vim.loop.fs_scandir_next(handle)
      if not name then
        break
      end
      -- HACK: type is not always returned due to a bug in luv
      t = t or uv.fs_stat(path .. "/lua/" .. name).type
      ---@type string
      local topname
      local ext = name:sub(-4)
      if ext == ".lua" or ext == ".dll" then
        topname = name:sub(1, -5)
      elseif name:sub(-3) == ".so" then
        topname = name:sub(1, -4)
      elseif t == "link" or t == "directory" then
        topname = name
      end
      if topname then
        Cache._indexed[path][topname] = true
        Cache._topmods[topname] = Cache._topmods[topname] or {}
        if not vim.tbl_contains(Cache._topmods[topname], path) then
          table.insert(Cache._topmods[topname], path)
        end
      end
    end
    M._track("lsmod", start)
  end
  return Cache._indexed[path]
end

--- Debug function that wrapps all loaders and tracks stats
function M.profile_loaders()
  for l, loader in pairs(package.loaders) do
    local loc = debug.getinfo(loader, "Sn").source:sub(2)
    package.loaders[l] = function(modname)
      local start = vim.loop.hrtime()
      local ret = loader(modname)
      M._track("loader " .. l .. ": " .. loc, start)
      M._track("loader_all", start)
      return ret
    end
  end
end

--- Prints all cache stats
function M.inspect()
  ---@private
  local function ms(nsec)
    return math.floor(nsec / 1e6 * 1000 + 0.5) / 1000 .. "ms"
  end
  local chunks = {} ---@type string[][]
  ---@type string[]
  local stats = vim.tbl_keys(M.stats)
  table.sort(stats)
  for _, stat in ipairs(stats) do
    vim.list_extend(chunks, {
      { "\n" .. stat .. "\n", "Title" },
      { "* total:    " },
      { tostring(M.stats[stat].total) .. "\n", "Number" },
      { "* time:     " },
      { ms(M.stats[stat].time) .. "\n", "Bold" },
      { "* avg time: " },
      { ms(M.stats[stat].time / M.stats[stat].total) .. "\n", "Bold" },
    })
    for k, v in pairs(M.stats[stat]) do
      if not vim.tbl_contains({ "time", "total" }, k) then
        chunks[#chunks + 1] = { "* " .. k .. ":" .. string.rep(" ", 9 - #k) }
        chunks[#chunks + 1] = { tostring(v) .. "\n", "Number" }
      end
    end
  end
  vim.api.nvim_echo(chunks, true, {})
end

M._Cache = Cache

return M
