local resolver = require("resty.dns.resolver")
local utils = require("dnsutils")
local fileexists = require("pl.path").exists
  
-- resolver options
local opts

-- recursion level before erroring out
local max_dns_recursion = 20

-- create module table
local _M = {}
-- copy resty based constants for record types
for k,v in pairs(resolver) do
  if type(k) == "string" and k:sub(1,5) == "TYPE_" then
    _M[k] = v
  end
end

-- ==============================================
--    In memory DNS cache
-- ==============================================

-- hostname cache indexed by "hostname:recordtype" returning address list.
-- Result is a list with entries. 
-- Keys only by "hostname" only contain the last succesfull lookup type 
-- for this name, see `resolve`  function.
local cache = {}

-- lookup a single entry in the cache. Invalidates the entry if its beyond its ttl
local cachelookup = function(qname, qtype)
  local now = ngx.time()
  local key = qtype..":"..qname
  local cached = cache[key]
  
  if cached then
    if cached.expire < now then
      -- the cached entry expired
      cache[key] = nil
      cached = nil
    end
  end
  
  return cached
end

-- inserts an entry in the cache, except if the ttl=0, then it deletes it from the cache
local cacheinsert = function(entry)
  local key = entry.type..":"..entry.name
  
  -- determine minimum ttl of all answer records
  local ttl = entry[1].ttl
  for i = 2, #entry do
    ttl = math.min(ttl, entry[i].ttl)
  end
  
  -- special case; 0 ttl is never stored
  if entry.ttl == 0 then
    cache[key] = nil
    return
  end
  
  -- set expire time
  local now = ngx.time()
  entry.expire = now + ttl
  cache[key] = entry
end


-- ==============================================
--    Cache for re-usable DNS resolver objects
-- ==============================================

-- resolver objects cache
local res_avail = {} -- available resolvers
local res_busy = {}  -- resolvers now busy
local res_count = 0  -- total resolver count
local res_max = 10   -- maximum nr of resolvers to retain
local res_top = res_max -- we warn, if count exceeds top

-- implements cached resolvers, so we don't create resolvers upon every request
-- @param same parameters as the openresty `query` methods
-- @return same results as the openresty queries
local function query(qname, r_opts)
  local err, result
  -- get resolver from cache
  local r = next(res_avail)
  if not r then
    -- no resolver left in the cache, so create a new one
    r, err = resolver:new(opts)
    if not r then
      return r, err
    end
    res_busy[r] = r
    res_count = res_count + 1
  else
    -- found one, move it from avail to busy
    res_avail[r] = nil
    res_busy[r] = r
  end
  
  if res_count > res_top then
    res_top = res_count
    ngx.log(ngx.WARN, "DNS client: hit a new maximum of resolvers; "..
      res_top..", whilst cache max size is currently set at; "..res_max)  
  end
  
  result, err = r:resolve(qname, r_opts)
  
  res_busy[r] = nil
  if result and res_count <= res_max then
    -- if successful and within maximum number, reuse resolver
    res_avail[r] = r
  else
    -- failed, or too many, so drop the resolver object
    res_count = res_count - 1
  end
  
  return result, err
end

-- ==============================================
--    Main DNS functions for lookup
-- ==============================================

local cname_opt = { _M.TYPE_CNAME }
local a_opt = { _M.TYPE_A }
local aaaa_opt = { _M.TYPE_AAAA }
local srv_opt = { _M.TYPE_SRV }
local type_order = {
  a_opt,
  aaaa_opt,
  srv_opt,
}

--- initialize resolver. Will parse hosts and resolv.conf files.
-- @param options Same table as the openresty dns resolver, with extra 
-- fields `hosts` and `resolv_conf` containing the filenames to parse.
-- @return true on success, nil+error otherwise
_M.init = function(options)
  local resolv, hosts, err
  
  local hostsfile = options.hosts or utils.DEFAULT_HOSTS
  local resolvconffile = options.resolv_conf or utils.DEFAULT_RESOLV_CONF
  
  if fileexists(hostsfile) then
    hosts, err = utils.parse_hosts(hostsfile)  -- results will be all lowercase!
    if not hosts then return hosts, err end
  else
    ngx.log(ngx.WARN, "Hosts file not found: "..tostring(hostsfile))  
    hosts = {}
  end
  
  -- Populate the DNS cache with the hosts (and aliasses) from the hosts file.
  local ttl = 10*365*24*60*60  -- use ttl of 10 years for hostfile entries
  for name, address in pairs(hosts) do
    if address.ipv4 then 
      cacheinsert({{  -- NOTE: nested list! cache is a list of lists
          name = name,
          address = address.ipv4,
          type = _M.TYPE_A,
          class = 1,
          ttl = ttl,
        }})
    end
    if address.ipv6 then 
      cacheinsert({{  -- NOTE: nested list! cache is a list of lists
          name = name,
          address = address.ipv6,
          type = _M.TYPE_AAAA,
          class = 1,
          ttl = ttl,
        }})
    end
    
    return true
  end
  
  
  if fileexists(resolvconffile) then
    resolv, err = utils.apply_env(utils.parse_resolv_conf(options.resolve_conf))
    if not resolv then return resolv, err end
  else
    ngx.log(ngx.WARN, "Resolv.conf file not found: "..tostring(resolvconffile))  
    resolv = {}
  end
  
  if not options.nameservers and resolv.nameserver then
    options.nameservers = {}
    -- some systems support port numbers in nameserver entries, so must parse those
    for i, address in ipairs(resolv.nameservers) do
      local ip, port = address:match("^([^:]+)%:*(%d*)$")
      port = tonumber(port)
      if port then
        options.nameservers[i] = { ip, port }
      else
        options.nameservers[i] = ip
      end
    end
  end
  
  options.retrans = options.retrans or resolv.attempts
  
  if not options.timeout and resolv.timeout then
    options.timeout = resolv.timeout * 1000
  end
  
  -- options.no_recurse = -- not touching this one for now
  
  opts = options -- store it in our module level global
end

-- will lookup in the cache, or alternatively query dns servers and populate the cache.
-- only looks up the requested type
local function _lookup(qname, r_opts)
  local qtype = r_opts.qtype
  local record = cachelookup(qname, qtype)
  
  if record then
    -- cache hit
    return record  
  else
    -- not found in our cache, so perform query on dns servers
    local answers, err = query(qname, r_opts)
    if not answers then return answers, err end
    
    -- check our answers and store them in the cache
    -- A, AAAA, SRV records may be accompanied by CNAME records
    -- store them all, leaving only the requested type in so we can return that set
    for i = #answers, 1, -1 do -- we're deleting entries, so reverse the traversal
      local answer = answers[i]
      if answer.name ~= qname or answer.type ~= qtype then
        cacheinsert({answer}) -- insert in cache before removing it
        answers[i] = nil
      end
    end
    
    -- now insert actual target record in cache
    cacheinsert(answers)
    return answers
  end
end

-- looks up the name, while following CNAME redirects
local function lookup(qname, r_opts, count)
  count = (count or 0) + 1
  if count > max_dns_recursion then
    return nil, "More than "..max_dns_recursion.." DNS redirects, recursion error?"
  end
  
  local records, err = _lookup(qname, r_opts)
  if records or r_opts.qtype == _M.TYPE_CNAME then
    -- return record found, or the error in case it was a CNAME already
    -- because then there is nothing to follow.
    return records, err
  end
  
  -- try a CNAME
  local records2 = _lookup(qname, cname_opt)
  if not records2 then
    return records, err   -- NOTE: return initial error!
  end
  
  -- CNAME success, now recurse the lookup
  -- For CNAME we assume only one entry. Correct???
  return lookup(records2[1].cname, r_opts, count)
end

--- Resolves a name following CNAME redirects. CNAME will not be followed when
-- the requested type is CNAME.
-- @param qname Same as the openresty `query` method
-- @param r_opts Same as the openresty `query` method (defaults to A type query)
-- @return A list of records
_M.resolve_type = function(qname, r_opts)
  qname = qname:lower()
  if not r_opts then
    r_opts = a_opt
  else
    r_opts.qtype = r_opts.qtype or _M.TYPE_A
  end
  return lookup(qname, r_opts)
end

--- Resolve a name using the following type-order; 1) last succesful lookup type (if any), 
-- 2) A-record, 3) AAAA-record, 4) SRV-record.
-- This will follow CNAME records, but will not resolv any SRV content.
-- @param qname Name to resolve
-- @return A list of records
_M.resolve = function(qname)
  qname = qname:lower()
  local last = cache[qname]  -- check if we have a previous succesful one
  local records, err
  for i = (last and 0 or 1), #type_order do
    local type_opt = ((i == 0) and { qtype = last } or type_order[i])
    records, err = _M.resolve_type(qname, type_opt)
    if records then
      cache[qname] = type_opt.qtype -- set last succesful type resolved
      return records
    end
  end
  -- we failed, clear cache and return last error
  cache[qname] = nil
  return records, err
end

if __TEST then _M.__cache = cache end -- export the local cache in case we're testing
return _M

