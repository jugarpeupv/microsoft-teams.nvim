local tmp = vim.fn.tempname() .. "-ms-teams-cache-test"
vim.fn.delete(tmp, "rf")
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_DATA_HOME = tmp .. "/data"

local root = vim.fn.getcwd()
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
require("ms-teams.config").setup()
local cache = require("ms-teams.cache")
local auth = require("ms-teams.auth")
auth.ensure_token_async = function(_, cb) cb("fake-token", nil) end

local teams_path = vim.fn.stdpath("cache") .. "/ms-teams/teams_associated.json"
local calls = {}
local responses = {}

local function reset_graph()
  package.loaded["ms-teams.graph"] = nil
  calls = {}
  return require("ms-teams.graph")
end

local function clear_cache()
  vim.fn.delete(teams_path)
end

local function save_stale(teams)
  local payload = { teams = teams, source = "associated", _ts = os.time() - 90000 }
  vim.fn.mkdir(vim.fn.fnamemodify(teams_path, ":h"), "p")
  vim.fn.writefile({ vim.json.encode(payload) }, teams_path)
end

local function install_system()
  vim.system = function(cmd, _, cb)
    table.insert(calls, cmd)
    local body = table.remove(responses, 1) or { value = {} }
    vim.schedule(function()
      cb({ code = 0, stdout = vim.json.encode(body), stderr = "" })
    end)
    return {}
  end
end

local function call_teams(g, opts)
  local result = {}
  g.list_teams(function(teams, err, meta)
    result.teams, result.err, result.meta = teams, err, meta
  end, opts)
  return result
end

local function wait_for(result)
  return vim.wait(2000, function() return result.meta ~= nil end, 20)
end

install_system()

-- 1. fresh cache: no network at all
clear_cache()
cache.save("teams_associated", { teams = { { id = "t1", displayName = "Engineering" } }, source = "associated" })
local g = reset_graph()
local r = call_teams(g)
assert(wait_for(r), "fresh cache callback did not run")
assert(r.meta.cached and r.meta.source == "associated", "fresh cache meta wrong")
assert(#r.teams == 1 and #calls == 0, "fresh cache still hit Graph")

-- 1b. explicit force still bypasses a fresh cache (R in :MSTeamsTeams)
responses = { { value = { { id = "t2", displayName = "Platform" } } } }
r = call_teams(g, { force = true })
assert(wait_for(r), "forced refresh callback did not run")
assert(r.teams and r.teams[1].id == "t2", "forced refresh did not return network list")
assert(#calls == 1, "force should hit Graph even with a fresh cache")

-- 2. stale cache + 429: return cached associated, never joinedTeams
clear_cache()
save_stale({ { id = "t1", displayName = "Engineering" } })
g = reset_graph()
responses = { { error = { code = "TooManyRequests", message = "Too many requests" } } }
r = call_teams(g)
assert(wait_for(r), "stale cache callback did not run")
assert(r.teams and r.teams[1].id == "t1", "stale associated list not returned")
assert(r.meta.stale and r.meta.partial and r.err == nil, "stale meta wrong")
assert(#calls == 1, "429 should not fall back to joinedTeams when cache exists")
r = call_teams(g)
assert(wait_for(r), "cooldown callback did not run")
assert(#calls == 1, "cooldown did not stop the second request")

-- 2b. 429 on a later page: keep partial list, set stale + cooldown
clear_cache()
save_stale({ { id = "cached1", displayName = "Cached" } })
g = reset_graph()
responses = {
  {
    value = { { id = "p1", displayName = "Page 1" } },
    ["@odata.nextLink"] = "https://graph.microsoft.com/v1.0/me/teamwork/associatedTeams?$skiptoken=X",
  },
  { error = { code = "TooManyRequests", message = "Too many requests" } },
}
r = call_teams(g)
assert(wait_for(r), "partial-page callback did not run")
assert(r.teams and #r.teams == 1 and r.teams[1].id == "p1", "partial page list not returned")
assert(r.meta.partial and r.meta.stale, "partial-page meta should be stale")
assert(#calls == 2, "expected two associatedTeams pages")
r = call_teams(g)
assert(wait_for(r), "cooldown after partial page did not run")
assert(#calls == 2, "partial-page 429 did not set cooldown")
assert(r.teams and r.teams[1].id == "cached1", "cooldown should return cached associated list")
assert(r.meta.cached and r.meta.partial, "partial-page cooldown meta wrong")

-- 3. no cache + 429: fall back to joinedTeams once
clear_cache()
g = reset_graph()
responses = {
  { error = { code = "TooManyRequests", message = "Too many requests" } },
  { value = { { id = "j1", displayName = "Joined Team" } } },
}
r = call_teams(g)
assert(wait_for(r), "joined fallback callback did not run")
assert(r.teams and r.teams[1].id == "j1", "joined fallback not returned")
assert(r.meta.source == "joined" and r.meta.partial, "joined meta wrong")
assert(#calls == 2, "expected one associated + one joined request")

-- 3b. during cooldown the joined fallback is reused without another request
r = call_teams(g)
assert(wait_for(r), "joined cache callback did not run")
assert(r.teams and r.teams[1].id == "j1", "cached joined list not returned")
assert(r.meta.cached and r.meta.partial, "cached joined meta wrong")
assert(#calls == 2, "cooldown should reuse the joined cache")

-- 4. concurrent calls share a single request
clear_cache()
g = reset_graph()
responses = { { value = { { id = "t1", displayName = "Engineering" } } } }
local count, seen = 0, {}
for i = 1, 2 do
  g.list_teams(function(teams, err, meta)
    count = count + 1
    seen[i] = { teams = teams, err = err, meta = meta }
  end)
end
assert(vim.wait(2000, function() return count == 2 end, 20), "inflight callbacks did not run")
assert(#calls == 1, "concurrent calls should share one request")
assert(seen[1].teams and seen[2].teams, "inflight callbacks missing teams")

print("TEAMS_CACHE_OK")
vim.fn.delete(tmp, "rf")
vim.cmd("qa!")
