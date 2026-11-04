local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local UndoStack  = lrequire_common("undo_stack")
local grid_utils = lrequire_common("grid_utils")
local Hint = lrequire_common("hint")

local emptyGrid     = grid_utils.emptyGrid
local emptyBoolGrid = grid_utils.emptyBoolGrid
local copyGrid      = grid_utils.copyGrid

local STATE_UNKNOWN = 0
local STATE_BLACK   = 1
local STATE_WHITE   = 2

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }

-- ---------------------------------------------------------------------------
-- Validation helpers
-- ---------------------------------------------------------------------------

local function blackConnected(black, n)
    local start_r, start_c
    for r = 1, n do
        for c = 1, n do
            if black[r][c] then start_r, start_c = r, c; goto found end
        end
    end
    ::found::
    if not start_r then return true end

    local visited = {}
    for r = 1, n do visited[r] = {} end
    local stack = {{start_r, start_c}}
    visited[start_r][start_c] = true
    local count = 1
    while #stack > 0 do
        local cell = table.remove(stack)
        for _, d in ipairs(DIRS) do
            local nr, nc = cell[1]+d[1], cell[2]+d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                and black[nr][nc] and not visited[nr][nc] then
                visited[nr][nc] = true
                count = count + 1
                stack[#stack+1] = {nr, nc}
            end
        end
    end

    local total = 0
    for r = 1, n do
        for c = 1, n do if black[r][c] then total = total + 1 end end
    end
    return count == total
end

local function has2x2Black(black, n)
    for r = 1, n-1 do
        for c = 1, n-1 do
            if black[r][c] and black[r+1][c] and black[r][c+1] and black[r+1][c+1] then
                return true
            end
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Exact solution counter (independent check, used by the specs and
-- spec/solvability_audits/nurikabe_solvability_check.lua)
-- ---------------------------------------------------------------------------

-- Counts solutions (up to `limit`) consistent with the given island clues
-- (each clue is a target size at a fixed seed cell): islands of exactly
-- their size, never touching each other, every other cell black, black
-- 4-connected with no 2x2 block. Returns (solutions_found, exhausted);
-- exhausted=true means node_budget was hit before the search concluded,
-- so the count isn't proof.
--
-- Islands are grown with MRV (always extend whichever incomplete island
-- has the fewest cells it could take next), but each branch is binary on
-- one frontier cell: it joins that island, or it is black. A cell next to
-- an island can't belong to any other island (they'd touch), so the two
-- branches cover everything exactly once. (Before 1.5.0 the search
-- branched over every frontier cell in turn, which reached the same island
-- shape once per growth order and counted it that many times -- unique
-- puzzles came out as "2 solutions", so at 10x10 and up nearly nothing
-- was ever proven unique, and the hunt for one cost up to 1.8 s.)
-- Between branches it propagates to a fixpoint; each rule only forces
-- what every solution extending the current grid shares:
--   - a cell next to a complete island, or next to two different islands,
--     is black;
--   - a cell no incomplete island can still reach (through cells it may
--     take, within its remaining size) is black; an island that can't
--     reach enough such cells is a dead end;
--   - more black cells than the clues leave room for, a 2x2 black block,
--     or black cells that can no longer connect through black/undecided
--     cells are dead ends.
-- Cell state: 0 undecided, -1 black, k > 0 island k.
local function countSolutions(clues, n, limit, node_budget)
    local N = n * n
    local nbr = {}
    for r = 1, n do for c = 1, n do
        local l = {}
        for _, d in ipairs(DIRS) do
            local nr, nc = r + d[1], c + d[2]
            if nr >= 1 and nr <= n and nc >= 1 and nc <= n then l[#l + 1] = (nr - 1) * n + nc end
        end
        nbr[(r - 1) * n + c] = l
    end end
    local blocks = {}
    for r = 1, n - 1 do for c = 1, n - 1 do
        local i = (r - 1) * n + c
        blocks[#blocks + 1] = { i, i + 1, i + n, i + n + 1 }
    end end

    local owner, target, size = {}, {}, {}
    local icells = {}                   -- island k -> its cells, in join order
    for i = 1, N do owner[i] = 0 end
    local K, white = 0, 0
    for r = 1, n do for c = 1, n do
        if clues[r][c] > 0 then
            K = K + 1
            local i = (r - 1) * n + c
            owner[i] = K
            target[K], size[K], icells[K] = clues[r][c], 1, { i }
            white = white + clues[r][c]
        end
    end end
    for i = 1, N do         -- two clues side by side: islands touch
        if owner[i] > 0 then
            for _, j in ipairs(nbr[i]) do
                if owner[j] > 0 and owner[j] ~= owner[i] then return 0, false, 0 end
            end
        end
    end
    local max_black = N - white
    if max_black < 0 then return 0, false, 0 end
    local blacks = 0

    local trail, tn = {}, 0
    local changed = false
    local function set(i, v)
        local s = owner[i]
        if s == v then return true end
        if s ~= 0 then return false end
        if v > 0 then
            if size[v] >= target[v] then return false end
            for _, j in ipairs(nbr[i]) do
                local o = owner[j]
                if o > 0 and o ~= v then return false end
            end
            size[v] = size[v] + 1
            local l = icells[v]; l[#l + 1] = i
        else
            if blacks >= max_black then return false end
            blacks = blacks + 1
        end
        owner[i] = v
        tn = tn + 1; trail[tn] = i
        changed = true
        return true
    end
    local function undo(mark)
        while tn > mark do
            local i = trail[tn]
            local v = owner[i]
            if v > 0 then
                size[v] = size[v] - 1
                local l = icells[v]; l[#l] = nil
            else
                blacks = blacks - 1
            end
            owner[i] = 0
            trail[tn] = nil; tn = tn - 1
        end
    end

    -- A cell island k may take: undecided, next to no other island.
    local function eligible(i, k)
        if owner[i] ~= 0 then return false end
        for _, j in ipairs(nbr[i]) do
            local o = owner[j]
            if o > 0 and o ~= k then return false end
        end
        return true
    end

    local reach, dist, queue = {}, {}, {}
    local stamp = 0
    local rstamp = 0
    for i = 1, N do reach[i] = 0; dist[i] = 0 end
    local seen = {}
    for i = 1, N do seen[i] = 0 end

    local function adjacencyProp()
        for i = 1, N do
            if owner[i] == 0 then
                local first, black = nil, false
                for _, j in ipairs(nbr[i]) do
                    local o = owner[j]
                    if o > 0 then
                        if size[o] >= target[o] or (first and first ~= o) then black = true; break end
                        first = o
                    end
                end
                if black and not set(i, -1) then return false end
            end
        end
        return true
    end

    local function reachProp()
        rstamp = rstamp + 1
        for k = 1, K do
            local rem = target[k] - size[k]
            if rem > 0 then
                stamp = stamp + 1
                local qh, qt = 1, 0
                for _, i in ipairs(icells[k]) do
                    seen[i] = stamp; dist[i] = 0
                    qt = qt + 1; queue[qt] = i
                end
                local found = 0
                while qh <= qt do
                    local i = queue[qh]; qh = qh + 1
                    local d = dist[i]
                    if d < rem then
                        for _, j in ipairs(nbr[i]) do
                            if seen[j] ~= stamp and eligible(j, k) then
                                seen[j] = stamp; dist[j] = d + 1
                                reach[j] = rstamp
                                found = found + 1
                                qt = qt + 1; queue[qt] = j
                            end
                        end
                    end
                end
                if found < rem then return false end
            end
        end
        for i = 1, N do
            if owner[i] == 0 and reach[i] ~= rstamp then
                if not set(i, -1) then return false end
            end
        end
        return true
    end

    local function blackProp()
        local start
        for _, b in ipairs(blocks) do
            if owner[b[1]] == -1 and owner[b[2]] == -1 and owner[b[3]] == -1 and owner[b[4]] == -1 then
                return false
            end
        end
        for i = 1, N do if owner[i] == -1 then start = i; break end end
        if not start then return true end
        stamp = stamp + 1
        local qh, qt = 1, 1
        queue[1] = start; seen[start] = stamp
        local got = 1
        while qh <= qt do
            local i = queue[qh]; qh = qh + 1
            for _, j in ipairs(nbr[i]) do
                if seen[j] ~= stamp and owner[j] <= 0 then
                    seen[j] = stamp
                    if owner[j] == -1 then got = got + 1 end
                    qt = qt + 1; queue[qt] = j
                end
            end
        end
        return got == blacks
    end

    local function propagate()
        repeat
            changed = false
            if not adjacencyProp() or not reachProp() or not blackProp() then return false end
        until not changed
        return true
    end

    -- MRV: the incomplete island with the fewest cells it could take next,
    -- and its first such cell.
    local function pick()
        local best_k, best_cell, best_len = nil, nil, math.huge
        stamp = stamp + 1
        for k = 1, K do
            if size[k] < target[k] then
                local len, first = 0, nil
                stamp = stamp + 1
                for _, i in ipairs(icells[k]) do
                    for _, j in ipairs(nbr[i]) do
                        if seen[j] ~= stamp and eligible(j, k) then
                            seen[j] = stamp
                            len = len + 1
                            first = first or j
                        end
                    end
                end
                if len < best_len then
                    best_k, best_cell, best_len = k, first, len
                    if len <= 1 then break end
                end
            end
        end
        return best_k, best_cell
    end

    local solutions, nodes, exhausted = 0, 0, false
    local function search()
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end
        if not propagate() then return end
        local k, cell = pick()
        if not k then
            -- Every island is complete, so reachProp() blackened the rest
            -- and blackProp() checked it.
            solutions = solutions + 1
            return
        end
        if not cell then return end
        local mark = tn
        if set(cell, k) then search() end
        undo(mark)
        if solutions >= limit or exhausted then return end
        if set(cell, -1) then search() end
        undo(mark)
    end
    search()
    return solutions, exhausted, nodes
end

-- ---------------------------------------------------------------------------
-- Logic solver (generation, difficulty)
-- ---------------------------------------------------------------------------

local geo_cache = {}
local function geometry(n)
    local g = geo_cache[n]
    if g then return g end
    local N = n * n
    local nbr = {}
    for r = 1, n do for c = 1, n do
        local l = {}
        if r > 1 then l[#l + 1] = (r - 2) * n + c end
        if r < n then l[#l + 1] = r * n + c end
        if c > 1 then l[#l + 1] = (r - 1) * n + c - 1 end
        if c < n then l[#l + 1] = (r - 1) * n + c + 1 end
        nbr[(r - 1) * n + c] = l
    end end
    local blocks, blocksOf = {}, {}
    for i = 1, N do blocksOf[i] = {} end
    for r = 1, n - 1 do for c = 1, n - 1 do
        local i = (r - 1) * n + c
        local b = { i, i + 1, i + n, i + n + 1 }
        blocks[#blocks + 1] = b
        for t = 1, 4 do local l = blocksOf[b[t]]; l[#l + 1] = b end
    end end
    g = { n = n, N = N, nbr = nbr, blocks = blocks, blocksOf = blocksOf }
    geo_cache[n] = g
    return g
end

-- ---------------------------------------------------------------------------
-- Logic solver
-- ---------------------------------------------------------------------------
-- clue[i] (flat, i = (r-1)*n+c): island size at a numbered cell, else 0.
-- Deduces cells the way a player does, without ever guessing ("suppose this
-- cell is black and see what breaks"), in three tiers:
--  1. a cell next to two islands, next to a complete island, or that would
--     make an island too big is black; the last open cell of a 2x2 black
--     block is white; an incomplete island, a white group without a number
--     or a piece of river with only one way out takes it; a cell no island
--     can reach is black.
--  2. a cell the river must pass through to stay connected is black; for
--     an island missing one or two cells, every cell all its possible
--     completions share is white and every cell they all border is black.
--  3. the same completion reasoning for islands missing more cells.
-- A completion is discarded only if it breaks a rule on sight: covers a
-- black cell, touches a white cell outside it, or closes a 2x2 black block.
-- Every deduction holds in every solution, so a puzzle solved to the last
-- cell has exactly one solution.
-- Returns solved, st (1 white / -1 black / 0 unknown), stats {t1, t2, t3}
-- (rounds that needed each tier), bad (contradiction: no solution).
-- One solver per grid size, its closures and arrays built once and reused
-- (no closure is created inside a loop, so LuaJIT compiles it all).
local solver_cache = {}
local function makeSolver(n)
    local g = geometry(n)
    local N, nbr, blocks, blocksOf = g.N, g.nbr, g.blocks, g.blocksOf
    local NB = #blocks
    local clue                                  -- set per call
    local st, comp, bcomp = {}, {}, {}
    local cl, cstart, csize, ctarget = {}, {}, {}, {}
    local bsize = {}
    local ncomp, nbcomp = 0, 0
    local unknown, total_black, work = 0, 0, 0
    local bad = false
    local pend, pv, np = {}, {}, 0
    local bq = {}
    local ex1, exn = {}, {}
    local dist, dstamp, reach = {}, {}, {}
    local stamp = 0
    local buckets = {}
    local adjc = {}
    local disc, low = {}, {}
    local timer = 0
    local inCnt, nbCnt, mark, seen = {}, {}, {}, {}
    local touched, ntouched = {}, 0
    local shape, ns = {}, 0
    local bl = {}
    local cur_id, S, aborted = 0, 0, false
    local lists = {}                            -- untried lists per depth
    local added = {}                            -- per depth
    for i = 1, N do
        dstamp[i] = 0; reach[i] = 0
        inCnt[i] = 0; nbCnt[i] = 0; mark[i] = 0; seen[i] = false
    end

    local function setc(i, v)
        local s = st[i]
        if s == v then return 0 end
        if s ~= 0 then bad = true; return 0 end
        st[i] = v; unknown = unknown - 1
        return 1
    end
    local function later(i, v) np = np + 1; pend[np] = i; pv[np] = v end
    local function flush()
        local c = 0
        for x = 1, np do c = c + setc(pend[x], pv[x]) end
        np = 0
        return c
    end

    local function components()
        for i = 1, N do comp[i] = 0; bcomp[i] = 0 end
        ncomp, nbcomp = 0, 0
        local top = 0
        for s = 1, N do
            local ss = st[s]
            if ss == 1 and comp[s] == 0 then
                ncomp = ncomp + 1
                local id = ncomp
                comp[s] = id
                local first = top + 1
                top = top + 1; cl[top] = s
                local h = first
                local tgt = 0
                while h <= top do
                    local i = cl[h]; h = h + 1
                    local v = clue[i]
                    if v > 0 then
                        if tgt ~= 0 then bad = true end
                        tgt = v
                    end
                    local nb = nbr[i]
                    for t = 1, #nb do
                        local j = nb[t]
                        if st[j] == 1 and comp[j] == 0 then
                            comp[j] = id; top = top + 1; cl[top] = j
                        end
                    end
                end
                cstart[id] = first
                local sz = top - first + 1
                csize[id] = sz
                ctarget[id] = tgt
                if tgt > 0 and sz > tgt then bad = true end
            elseif ss == -1 and bcomp[s] == 0 then
                nbcomp = nbcomp + 1
                local id = nbcomp
                bcomp[s] = id
                local h, qt = 1, 1
                bq[1] = s
                while h <= qt do
                    local i = bq[h]; h = h + 1
                    local nb = nbr[i]
                    for t = 1, #nb do
                        local j = nb[t]
                        if st[j] == -1 and bcomp[j] == 0 then
                            bcomp[j] = id; qt = qt + 1; bq[qt] = j
                        end
                    end
                end
                bsize[id] = qt
            end
        end
    end

    -- unknown cell j may join white comp id (it touches no other island)
    local function eligible(j, id)
        if st[j] ~= 0 then return false end
        local nb = nbr[j]
        for t = 1, #nb do
            local x = nb[t]
            if st[x] == 1 then
                local c = comp[x]
                if c ~= id and ctarget[c] > 0 then return false end
            end
        end
        return true
    end

    local function reachFrom(id, rs)
        local rem = ctarget[id] - csize[id]
        stamp = stamp + 1
        local ds = stamp
        for d = 0, rem do
            local bk = buckets[d]
            if not bk then bk = { n = 0 }; buckets[d] = bk end
            bk.n = 0
        end
        local b0 = buckets[0]
        for x = cstart[id], cstart[id] + csize[id] - 1 do
            local i = cl[x]
            dstamp[i] = ds; dist[i] = 0
            b0.n = b0.n + 1; b0[b0.n] = i
        end
        for d = 0, rem - 1 do
            local bk = buckets[d]
            local x = 1
            while x <= bk.n do
                local i = bk[x]; x = x + 1
                if dist[i] == d then
                    local nb = nbr[i]
                    for t = 1, #nb do
                        local j = nb[t]
                        local s = st[j]
                        if s == 0 then
                            local nd = d + 1
                            if (dstamp[j] ~= ds or dist[j] > nd) and eligible(j, id) then
                                dstamp[j] = ds; dist[j] = nd; reach[j] = rs
                                local b2 = buckets[nd]; b2.n = b2.n + 1; b2[b2.n] = j
                            end
                        elseif s == 1 then
                            local c = comp[j]
                            if c ~= id and ctarget[c] == 0 then
                                local nd = d + csize[c]
                                if nd <= rem and (dstamp[j] ~= ds or dist[j] > nd) then
                                    local b2 = buckets[nd]
                                    for y = cstart[c], cstart[c] + csize[c] - 1 do
                                        local w = cl[y]
                                        reach[w] = rs; dstamp[w] = ds; dist[w] = nd
                                        b2.n = b2.n + 1; b2[b2.n] = w
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    local function tier1()
        np = 0
        components()
        if bad then return 0 end
        -- next to two islands, or would overfill the island it joins
        for i = 1, N do
            if st[i] == 0 then
                local na, isl, tot, multi = 0, 0, 1, false
                local nb = nbr[i]
                for t = 1, #nb do
                    local j = nb[t]
                    if st[j] == 1 then
                        local c = comp[j]
                        local dup = false
                        for u = 1, na do if adjc[u] == c then dup = true; break end end
                        if not dup then
                            na = na + 1; adjc[na] = c
                            tot = tot + csize[c]
                            local tg = ctarget[c]
                            if tg > 0 then
                                if isl > 0 then multi = true end
                                isl = tg
                            end
                        end
                    end
                end
                if multi or (isl > 0 and tot > isl) then later(i, -1) end
            end
        end
        -- last open cell of a 2x2 black block
        for bi = 1, NB do
            local b = blocks[bi]
            local nbk, u = 0, 0
            for t = 1, 4 do
                local s = st[b[t]]
                if s == -1 then nbk = nbk + 1 elseif s == 0 then u = b[t] end
            end
            if nbk == 3 and u > 0 then later(u, 1) end
        end
        local cnt = flush()
        if cnt > 0 then return cnt end
        -- one way out: islands, white groups without a number, river pieces
        for id = 1, ncomp do
            local tg = ctarget[id]
            if tg == 0 or csize[id] < tg then
                local e, ne = 0, 0
                for x = cstart[id], cstart[id] + csize[id] - 1 do
                    local nb = nbr[cl[x]]
                    for t = 1, #nb do
                        local j = nb[t]
                        if j ~= e and ((tg == 0 and st[j] == 0) or (tg > 0 and eligible(j, id))) then
                            ne = ne + 1; e = j
                            if ne > 1 then break end
                        end
                    end
                    if ne > 1 then break end
                end
                if ne == 0 then bad = true; return 0 end
                if ne == 1 then later(e, 1) end
            end
        end
        if nbcomp > 0 then
            for id = 1, nbcomp do ex1[id] = 0; exn[id] = 0 end
            for i = 1, N do
                local b = bcomp[i]
                if b > 0 and exn[b] < 2 then
                    local nb = nbr[i]
                    for t = 1, #nb do
                        local j = nb[t]
                        if st[j] == 0 and j ~= ex1[b] then
                            exn[b] = exn[b] + 1; ex1[b] = j
                            if exn[b] > 1 then break end
                        end
                    end
                end
            end
            for id = 1, nbcomp do
                if bsize[id] < total_black then
                    if exn[id] == 0 then bad = true; return 0 end
                    if exn[id] == 1 then later(ex1[id], -1) end
                end
            end
        end
        cnt = flush()
        if cnt > 0 then return cnt end
        -- cells no island can reach (an island grows by at most what its
        -- number still allows; a white group without a number it takes in
        -- costs that group's whole size)
        stamp = stamp + 1
        local rs = stamp
        for id = 1, ncomp do
            local tg = ctarget[id]
            if tg > 0 and csize[id] < tg then reachFrom(id, rs) end
        end
        for i = 1, N do
            if st[i] == 0 and reach[i] ~= rs then later(i, -1) end
        end
        for id = 1, ncomp do
            if ctarget[id] == 0 and reach[cl[cstart[id]]] ~= rs then bad = true; np = 0; return 0 end
        end
        return flush()
    end

    -- river articulation: an unknown cell whose whitening would cut the
    -- black cells apart (moving through black/unknown cells) is black.
    local function dfs(i, parent)
        timer = timer + 1
        disc[i], low[i] = timer, timer
        local b = (st[i] == -1) and 1 or 0
        local forced = false
        local nb = nbr[i]
        for t = 1, #nb do
            local j = nb[t]
            if st[j] ~= 1 then
                if disc[j] == 0 then
                    local sb = dfs(j, i)
                    b = b + sb
                    if low[j] < low[i] then low[i] = low[j] end
                    -- the root is black, so a cut-off subtree holding black
                    -- leaves black on both sides of i
                    if low[j] >= disc[i] and sb > 0 and st[i] == 0 then forced = true end
                elseif j ~= parent and disc[j] < low[i] then
                    low[i] = disc[j]
                end
            end
        end
        if forced then later(i, -1) end
        return b
    end
    local function articulation()
        np = 0
        local start = 0
        local nblack = 0
        for i = 1, N do
            disc[i] = 0
            if st[i] == -1 then
                nblack = nblack + 1
                if start == 0 then start = i end
            end
        end
        if start == 0 then return 0 end
        timer = 0
        local got = dfs(start, 0)
        if got < nblack then bad = true; np = 0; return 0 end
        return flush()
    end

    -- island completions (Redelmeier: each completion visited once)
    local function cand(j)
        local s = st[j]
        if s == 0 then return eligible(j, cur_id) end
        if s == 1 then return comp[j] ~= cur_id and ctarget[comp[j]] == 0 end
        return false
    end
    local function record()
        local nbl = 0
        for x = 1, ns do
            local nb = nbr[shape[x]]
            for t = 1, #nb do
                local j = nb[t]
                if mark[j] == 0 then
                    local s = st[j]
                    if s == 1 then          -- would touch a white cell outside
                        for y = 1, nbl do mark[bl[y]] = 0 end
                        return
                    end
                    if s == 0 then mark[j] = 2; nbl = nbl + 1; bl[nbl] = j end
                end
            end
        end
        local okp = true
        for y = 1, nbl do                   -- its border closes a 2x2 block
            local bo = blocksOf[bl[y]]
            for u = 1, #bo do
                local b = bo[u]
                local all = true
                for t = 1, 4 do
                    local c = b[t]
                    if not (st[c] == -1 or mark[c] == 2) then all = false; break end
                end
                if all then okp = false; break end
            end
            if not okp then break end
        end
        if okp then
            S = S + 1
            for x = 1, ns do
                local i = shape[x]
                if inCnt[i] == 0 and nbCnt[i] == 0 then ntouched = ntouched + 1; touched[ntouched] = i end
                inCnt[i] = inCnt[i] + 1
            end
            for y = 1, nbl do
                local j = bl[y]
                if inCnt[j] == 0 and nbCnt[j] == 0 then ntouched = ntouched + 1; touched[ntouched] = j end
                nbCnt[j] = nbCnt[j] + 1
            end
        end
        for y = 1, nbl do mark[bl[y]] = 0 end
    end
    local function rec(depth, nu, left)
        local untried = lists[depth]
        while nu > 0 do
            work = work - 1
            if work <= 0 then aborted = true; return end
            local c = untried[nu]; nu = nu - 1
            mark[c] = 1; ns = ns + 1; shape[ns] = c
            if left == 1 then
                record()
            else
                local nxt = lists[depth + 1]
                if not nxt then nxt = {}; lists[depth + 1] = nxt end
                for x = 1, nu do nxt[x] = untried[x] end
                local k = nu
                local ad = added[depth]
                if not ad then ad = {}; added[depth] = ad end
                local na = 0
                local nb = nbr[c]
                for t = 1, #nb do
                    local j = nb[t]
                    if not seen[j] and cand(j) then
                        seen[j] = true; k = k + 1; nxt[k] = j
                        na = na + 1; ad[na] = j
                    end
                end
                rec(depth + 1, k, left - 1)
                for x = 1, na do seen[ad[x]] = false end
            end
            shape[ns] = nil; ns = ns - 1; mark[c] = 0
            if aborted then return end
        end
    end
    local function enumerate(minrem, maxrem)
        np = 0
        components()
        if bad then return 0 end
        for id = 1, ncomp do
            local tg = ctarget[id]
            local rem = tg - csize[id]
            if tg > 0 and rem >= minrem and rem <= maxrem and work > 0 then
                cur_id, S, aborted = id, 0, false
                ns, ntouched = 0, 0
                for x = cstart[id], cstart[id] + csize[id] - 1 do
                    local i = cl[x]
                    mark[i] = 1; ns = ns + 1; shape[ns] = i; seen[i] = true
                end
                local l0 = lists[1]
                if not l0 then l0 = {}; lists[1] = l0 end
                local ni = 0
                for x = cstart[id], cstart[id] + csize[id] - 1 do
                    local nb = nbr[cl[x]]
                    for t = 1, #nb do
                        local j = nb[t]
                        if not seen[j] and cand(j) then seen[j] = true; ni = ni + 1; l0[ni] = j end
                    end
                end
                local init_n = ni
                local saved = {}
                for x = 1, init_n do saved[x] = l0[x] end
                rec(1, ni, rem)
                for x = 1, init_n do seen[saved[x]] = false end
                for x = cstart[id], cstart[id] + csize[id] - 1 do
                    local i = cl[x]
                    mark[i] = 0; seen[i] = false
                end
                for x = ns, 1, -1 do shape[x] = nil end
                ns = 0
                if not aborted then
                    if S == 0 then bad = true; return 0 end
                    for x = 1, ntouched do
                        local i = touched[x]
                        if st[i] == 0 then
                            if inCnt[i] == S then later(i, 1)
                            elseif nbCnt[i] == S then later(i, -1) end
                        end
                    end
                end
                for x = 1, ntouched do local i = touched[x]; inCnt[i] = 0; nbCnt[i] = 0 end
                local cnt = flush()
                if cnt > 0 or bad then return cnt end
            end
        end
        return 0
    end

    return function(clue_in, max_tier, work_cap, init, meter)
        clue = clue_in
        bad = false
        np = 0
        local nclues, total_white = 0, 0
        for i = 1, N do
            local v = clue[i]
            if v > 0 then
                st[i] = 1; nclues = nclues + 1; total_white = total_white + v
            elseif init then
                st[i] = init[i]
            else
                st[i] = 0
            end
        end
        unknown = 0
        for i = 1, N do if st[i] == 0 then unknown = unknown + 1 end end
        total_black = N - total_white
        local stats = { 0, 0, 0 }
        if total_black < 0 then return false, st, stats, true end
        work = work_cap or 3000
        while unknown > 0 and not bad do
            if meter then meter.rounds = meter.rounds + 1 end
            local c = tier1()
            if bad then break end
            if c > 0 then
                stats[1] = stats[1] + 1
            else
                if max_tier < 2 then break end
                c = articulation()
                if c == 0 and not bad then c = enumerate(1, 2) end
                if bad then break end
                if c > 0 then
                    stats[2] = stats[2] + 1
                else
                    if max_tier < 3 then break end
                    c = enumerate(3, N)
                    if bad then break end
                    if c > 0 then stats[3] = stats[3] + 1 else break end
                end
            end
        end
        -- copy out (st is reused by the next call)
        local out = {}
        for i = 1, N do out[i] = st[i] end
        return (unknown == 0 and not bad), out, stats, bad
    end
end

local function solve(n, clue, max_tier, work_cap, init, meter)
    local s = solver_cache[n]
    if not s then s = makeSolver(n); solver_cache[n] = s end
    return s(clue, max_tier, work_cap, init, meter)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------
-- 1. Seed: start all black and whiten one cell of a 2x2 black block at a
--    time (the most constrained block first), away from other white cells
--    when possible and never cutting the river: a scatter of 1s (a few 2s
--    or 3s where a block leaves no choice). Every white cell is numbered,
--    so it solves at once.
-- 2. Dig: grow an island by one cell, or join two islands through a cell
--    (dropping one of their numbers), a few changes at a time, keeping them
--    only if the puzzle still solves without going beyond the difficulty's
--    tier. Changes that can't be kept are undone, and the island growth
--    stops when nothing else fits (or the work budget runs out). The
--    puzzle is therefore always unique and never needs a guess.

-- removable[i] for every black cell: whitening it leaves the river
-- connected (the non-articulation cells of the connected black region).
local rr_own, rr_disc, rr_low, rr_rem, rr_nbr, rr_timer
local function rrDfs(i, parent)
    rr_timer = rr_timer + 1
    rr_disc[i], rr_low[i] = rr_timer, rr_timer
    local children = 0
    local nb = rr_nbr[i]
    for t = 1, #nb do
        local j = nb[t]
        if rr_own[j] == 0 then
            if rr_disc[j] == 0 then
                children = children + 1
                rrDfs(j, i)
                if rr_low[j] < rr_low[i] then rr_low[i] = rr_low[j] end
                if parent > 0 and rr_low[j] >= rr_disc[i] then rr_rem[i] = false end
            elseif j ~= parent and rr_disc[j] < rr_low[i] then
                rr_low[i] = rr_disc[j]
            end
        end
    end
    if parent == 0 and children > 1 then rr_rem[i] = false end
end
local function riverRemovable(g, own, removable, disc, low)
    rr_own, rr_disc, rr_low, rr_rem, rr_nbr, rr_timer = own, disc, low, removable, g.nbr, 0
    local start = 0
    for i = 1, g.N do
        disc[i] = 0
        removable[i] = own[i] == 0
        if start == 0 and own[i] == 0 then start = i end
    end
    if start > 0 then rrDfs(start, 0) end
    rr_own, rr_disc, rr_low, rr_rem = nil, nil, nil, nil
end

-- island next to black cell x it would join (0 = none), nil if two
local function joinTarget(nbr, own, x)
    local k = 0
    local nb = nbr[x]
    for t = 1, #nb do
        local o = own[nb[t]]
        if o > 0 then
            if k ~= 0 and k ~= o then return nil end
            k = o
        end
    end
    return k
end

local function seedLayout(n)
    local g = geometry(n)
    local N, nbr, blocks = g.N, g.nbr, g.blocks
    local own, size, K = {}, {}, 0
    for i = 1, N do own[i] = 0 end
    local disc, low, removable = {}, {}, {}
    local best, opts = {}, {}
    while true do
        riverRemovable(g, own, removable, disc, low)
        -- the 2x2 black block with the fewest cells that can become a lone
        -- 1, else the fewest that can extend a small island
        local bestv, nbest = math.huge, 0
        for bi = 1, #blocks do
            local b = blocks[bi]
            if own[b[1]] == 0 and own[b[2]] == 0 and own[b[3]] == 0 and own[b[4]] == 0 then
                local iso, join = 0, 0
                for t = 1, 4 do
                    local x = b[t]
                    if removable[x] then
                        local k = joinTarget(nbr, own, x)
                        if k == 0 then iso = iso + 1
                        elseif k and size[k] < 3 then join = join + 1 end
                    end
                end
                local v = iso > 0 and iso or (join > 0 and 10 + join or 100)
                if v < bestv then bestv = v; nbest = 1; best[1] = b
                elseif v == bestv then nbest = nbest + 1; best[nbest] = b end
            end
        end
        if nbest == 0 then break end
        if bestv == 100 then return nil end
        local b = best[math.random(nbest)]
        local no = 0
        for t = 1, 4 do
            local x = b[t]
            if removable[x] then
                local k = joinTarget(nbr, own, x)
                if (bestv < 10 and k == 0) or (bestv >= 10 and k and k > 0 and size[k] < 3) then
                    no = no + 1; opts[no] = x
                end
            end
        end
        local x = opts[math.random(no)]
        local k = joinTarget(nbr, own, x)
        if k == 0 then K = K + 1; k = K; size[k] = 0 end
        own[x] = k; size[k] = size[k] + 1
    end
    return own, size, K
end

-- cfg: tier, max_island, batch (changes per check), radius (local
-- pre-check), budget (solver rounds for the whole call, counted in
-- `meter`). on_progress(fraction) optional.
-- Returns clue (flat), own (flat: island id or 0), island count, stats of
-- the final solve -- or nil if no seed layout could be built.
local function buildPuzzle(n, cfg, meter, on_progress)
    local g = geometry(n)
    local N, nbr = g.N, g.nbr
    local own, size, K
    local clue, pos, cells
    for _ = 1, 20 do
        own, size, K = seedLayout(n)
        if own then
            cells = {}
            for k = 1, K do cells[k] = {} end
            for i = 1, N do local k = own[i]; if k > 0 then local l = cells[k]; l[#l + 1] = i end end
            clue, pos = {}, {}
            for i = 1, N do clue[i] = 0 end
            for k = 1, K do
                local l = cells[k]
                local x = l[math.random(#l)]
                clue[x] = #l; pos[k] = x
            end
            if solve(n, clue, cfg.tier, cfg.work, nil, meter) then break end
            own = nil
        end
    end
    if not own then return nil end
    local nIsl = K
    local nblack = 0
    for i = 1, N do if own[i] == 0 then nblack = nblack + 1 end end

    local seen, q = {}, {}
    -- whitening x keeps the river connected (BFS; for the 2nd+ change of a
    -- batch, after the first has altered the river)
    local function removable(x)
        local start = 0
        local nb = nbr[x]
        for t = 1, #nb do if own[nb[t]] == 0 then start = nb[t]; break end end
        if start == 0 then return false end
        for i = 1, N do seen[i] = false end
        seen[x] = true; seen[start] = true; q[1] = start
        local qh, qt = 1, 1
        while qh <= qt do
            local i = q[qh]; qh = qh + 1
            local nb2 = nbr[i]
            for t = 1, #nb2 do
                local j = nb2[t]
                if own[j] == 0 and not seen[j] then seen[j] = true; qt = qt + 1; q[qt] = j end
            end
        end
        return qt == nblack - 1
    end
    -- the one or two islands next to black cell x (nil if none or more)
    local function adjIslands(x)
        local a, b
        local nb = nbr[x]
        for t = 1, #nb do
            local o = own[nb[t]]
            if o > 0 then
                if not a then a = o
                elseif o ~= a then
                    if not b then b = o elseif o ~= b then return nil end
                end
            end
        end
        return a, b
    end

    local batch = cfg.batch
    local failed = {}
    local cand = {}
    local rem_ok, disc, low = {}, {}, {}
    local loc = {}
    local stats
    while meter.rounds < cfg.budget do
        riverRemovable(g, own, rem_ok, disc, low)
        local nc = 0
        for x = 1, N do
            if rem_ok[x] and not failed[x] then
                local a, b = adjIslands(x)
                if a and size[a] + 1 + (b and size[b] or 0) <= cfg.max_island then
                    nc = nc + 1; cand[nc] = x
                end
            end
        end
        if nc == 0 then break end
        -- a batch of changes far enough apart not to interfere
        local busy, bisl = {}, {}
        local applied = {}
        local tries = 0
        while #applied < batch and tries < 4 * batch do
            tries = tries + 1
            local x = cand[math.random(nc)]
            local a, b = adjIslands(x)
            if not busy[x] and a and not bisl[a] and not (b and bisl[b]) then
                local ns = size[a] + 1 + (b and size[b] or 0)
                if ns <= cfg.max_island and (#applied == 0 or removable(x)) then
                    local rec = { x = x, a = a, b = b, pa = pos[a], va = clue[pos[a]] }
                    own[x] = a; nblack = nblack - 1
                    local ca = cells[a]; ca[#ca + 1] = x
                    if b then
                        rec.pb, rec.vb, rec.nb = pos[b], clue[pos[b]], #ca
                        local cb = cells[b]
                        for t = 1, #cb do own[cb[t]] = a; ca[#ca + 1] = cb[t] end
                        if math.random(2) == 1 then
                            clue[pos[a]] = 0; pos[a] = pos[b]
                        else
                            clue[pos[b]] = 0
                        end
                        nIsl = nIsl - 1
                    end
                    clue[pos[a]] = ns
                    size[a] = ns
                    applied[#applied + 1] = rec
                    busy[x] = true; bisl[a] = true
                    if b then bisl[b] = true end
                    local nb = nbr[x]
                    for t = 1, #nb do busy[nb[t]] = true end
                end
            end
        end
        if #applied == 0 then break end
        -- Cheap pre-check: cells away from the changes are given (they are
        -- the same in the new solution), so if even this fails, the full
        -- solve fails too and is skipped.
        local R = cfg.radius
        for i = 1, N do loc[i] = own[i] > 0 and 1 or -1 end
        for t = 1, #applied do
            local x = applied[t].x
            local xr, xc = math.floor((x - 1) / n) + 1, (x - 1) % n + 1
            for r = math.max(1, xr - R), math.min(n, xr + R) do
                for c = math.max(1, xc - R), math.min(n, xc + R) do loc[(r - 1) * n + c] = 0 end
            end
        end
        local ok = solve(n, clue, cfg.tier, cfg.work, loc, meter)
        local st2
        if ok then
            local full
            ok, full, st2 = solve(n, clue, cfg.tier, cfg.work, nil, meter)
        end
        if ok then
            stats = st2
            batch = math.min(batch * 2, cfg.batch)
            -- the neighbourhood changed: cells that failed nearby may fit now
            for t = 1, #applied do
                local nb = nbr[applied[t].x]
                for u = 1, #nb do
                    local nb2 = nbr[nb[u]]
                    for w = 1, #nb2 do failed[nb2[w]] = nil end
                end
            end
        else
            for t = #applied, 1, -1 do
                local rec = applied[t]
                local a, b, x = rec.a, rec.b, rec.x
                local ca = cells[a]
                clue[pos[a]] = 0
                if b then
                    for u = #ca, rec.nb + 1, -1 do own[ca[u]] = b; ca[u] = nil end
                    clue[rec.pb] = rec.vb
                    pos[b] = rec.pb
                    size[b] = #cells[b]
                    nIsl = nIsl + 1
                end
                ca[#ca] = nil
                own[x] = 0; nblack = nblack + 1
                pos[a] = rec.pa; clue[rec.pa] = rec.va
                size[a] = #ca
            end
            if #applied == 1 then failed[applied[1].x] = true end
            batch = math.max(1, math.floor(#applied / 2))
        end
        if on_progress then on_progress(math.min(1, meter.rounds / cfg.budget)) end
    end
    if not stats then
        local ok0, st0
        ok0, st0, stats = solve(n, clue, cfg.tier, cfg.work)
    end
    return clue, own, nIsl, stats
end

-- ---------------------------------------------------------------------------
-- NurikabeBoard
-- ---------------------------------------------------------------------------

local NurikabeBoard = {}
NurikabeBoard.__index = NurikabeBoard

function NurikabeBoard:new(opts)
    opts = opts or {}
    local n = opts.n or DEFAULT_N
    return setmetatable({
        n               = n,
        difficulty      = opts.difficulty or DEFAULT_DIFFICULTY,
        clues           = emptyGrid(n, n, 0),
        solution_black  = emptyBoolGrid(n),
        user            = emptyGrid(n, n, STATE_UNKNOWN),
        wrong_marks     = emptyBoolGrid(n),
        reveal_solution = false,
        undo            = UndoStack:new{ max_size = 200 },
    }, self)
end

-- Difficulty is the deepest reasoning a puzzle may need (the logic solver's
-- tiers, see solve()) and how big an island may grow: Easy needs only the
-- basic rules, Medium also the river's connectivity and the ways a nearly
-- finished island can end, Hard the ways a bigger island can end. Every
-- level is solvable without guessing and has exactly one solution.
local GEN_CONFIG = {
    easy   = { tier = 1, max_small = 4, max_large = 5 },
    medium = { tier = 2, max_small = 5, max_large = 7 },
    hard   = { tier = 3, max_small = 6, max_large = 9 },
}

-- Work budget in solver rounds (never time, so a seed gives the same puzzle
-- on every device), sized so the slowest case stays around 40 ms on a
-- desktop (about a second on a Kobo).
local function genBudget(n, tier)
    if n <= 6 then return 600 end
    if n <= 10 then return ({ 700, 700, 600 })[tier] or 600 end
    return ({ 1200, 1000, 600 })[tier] or 600
end

-- Last resort, never reached in testing: 1s on every (even, even) cell.
-- Every 2x2 block holds one, the odd rows and columns keep the river
-- connected, and every white cell is numbered, so it is trivially unique.
local function fallbackPuzzle(n)
    local clue, own = {}, {}
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        local w = (r % 2 == 0 and c % 2 == 0)
        clue[i] = w and 1 or 0
        own[i] = w and i or 0
    end end
    return clue, own
end

-- on_progress(fraction), optional: called as the work budget is used
-- (screen.lua wires it to the shared "Generating puzzle…" bar).
function NurikabeBoard:generate(difficulty, on_progress)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n   = self.n
    local gc  = GEN_CONFIG[self.difficulty] or GEN_CONFIG.easy
    local cfg = {
        tier       = gc.tier,
        max_island = n <= 6 and gc.max_small or gc.max_large,
        batch      = 8,
        radius     = 3,
        work       = 3000,
        budget     = genBudget(n, gc.tier),
    }
    local meter = { rounds = 0 }
    local clue, own
    local tries = 0
    -- Medium and Hard retry (budget permitting) until the puzzle really
    -- needs their tier; small grids often come out easier.
    repeat
        local c, o, _k, stats = buildPuzzle(n, cfg, meter, on_progress)
        if c and not clue then clue, own = c, o end
        if c and (cfg.tier == 1 or stats[cfg.tier] > 0) then
            clue, own = c, o
            break
        end
        tries = tries + 1
    until meter.rounds >= cfg.budget / 2 or tries >= 10
    if not clue then clue, own = fallbackPuzzle(n) end

    local clues, solution_black = emptyGrid(n, n, 0), emptyBoolGrid(n)
    for r = 1, n do for c = 1, n do
        local i = (r - 1) * n + c
        clues[r][c] = clue[i]
        solution_black[r][c] = own[i] == 0
    end end
    self.clues          = clues
    self.solution_black = solution_black
    self.user           = emptyGrid(n, n, STATE_UNKNOWN)
    self.wrong_marks    = emptyBoolGrid(n)
end

function NurikabeBoard:setCellState(r, c, state)
    if self.clues[r][c] > 0 then return false, "clue_cell" end
    if r < 1 or r > self.n or c < 1 or c > self.n then return false, "out_of_bounds" end
    local prev = self.user[r][c]
    self.undo:push{ r=r, c=c, prev=prev }
    self.user[r][c]        = state
    self.wrong_marks[r][c] = false
    return true
end

function NurikabeBoard:cycleCellState(r, c)
    local cur  = self.user[r][c]
    local next = (cur + 1) % 3
    return self:setCellState(r, c, next)
end

function NurikabeBoard:canUndo()
    return self.undo:canUndo()
end

function NurikabeBoard:undo()
    local entry = self.undo:pop()
    if not entry then return false, UndoStack.NOTHING_TO_UNDO end
    self.user[entry.r][entry.c]        = entry.prev
    self.wrong_marks[entry.r][entry.c] = false
    return true
end

function NurikabeBoard:checkProgress()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local u  = self.user[r][c]
            local sb = self.solution_black[r][c]
            if u == STATE_BLACK and not sb then
                self.wrong_marks[r][c] = true
            elseif u == STATE_WHITE and sb then
                self.wrong_marks[r][c] = true
            else
                self.wrong_marks[r][c] = false
            end
        end
    end
end

function NurikabeBoard:isSolved()
    local n = self.n
    for r = 1, n do
        for c = 1, n do
            local sb = self.solution_black[r][c]
            local u  = self.user[r][c]
            if sb then
                if u ~= STATE_BLACK then return false end
            else
                if u == STATE_BLACK then return false end
                if u == STATE_UNKNOWN and self.clues[r][c] == 0 then return false end
            end
        end
    end
    return true
end

function NurikabeBoard:validateRules()
    local n          = self.n
    local violations = {}

    local black_mask = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do
            black_mask[r][c] = (self.user[r][c] == STATE_BLACK)
        end
    end

    if not blackConnected(black_mask, n) then
        violations[#violations+1] = "black_disconnected"
    end
    if has2x2Black(black_mask, n) then
        violations[#violations+1] = "2x2_black"
    end

    -- No two islands adjacent: flood-fill from numbered cells
    local cell_island = emptyGrid(n, n, 0)
    local island_id   = 0
    for r = 1, n do
        for c = 1, n do
            if self.clues[r][c] > 0 and cell_island[r][c] == 0 then
                island_id = island_id + 1
                local queue = {{r, c}}
                cell_island[r][c] = island_id
                local qi = 1
                while qi <= #queue do
                    local cr, cc = queue[qi][1], queue[qi][2]
                    qi = qi + 1
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cr+d[1], cc+d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                            and self.user[nr][nc] ~= STATE_BLACK
                            and cell_island[nr][nc] == 0 then
                            cell_island[nr][nc] = island_id
                            queue[#queue+1] = {nr, nc}
                        end
                    end
                end
            end
        end
    end

    local found_adj = false
    for r = 1, n do
        for c = 1, n do
            if not found_adj and cell_island[r][c] > 0 then
                for _, d in ipairs(DIRS) do
                    local nr, nc = r+d[1], c+d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n then
                        local v = cell_island[nr][nc]
                        if v > 0 and v ~= cell_island[r][c] then
                            found_adj = true; break
                        end
                    end
                end
            end
        end
    end
    if found_adj then violations[#violations+1] = "islands_adjacent" end

    return #violations == 0, violations
end

function NurikabeBoard:getRemainingCells()
    local n, count = self.n, 0
    for r = 1, n do
        for c = 1, n do
            if self.user[r][c] == STATE_UNKNOWN and self.clues[r][c] == 0 then
                count = count + 1
            end
        end
    end
    return count
end

function NurikabeBoard:toggleSolution()
    self.reveal_solution = not self.reveal_solution
end

function NurikabeBoard:isShowingSolution()
    return self.reveal_solution
end

-- isSolved() requires every non-clue cell decided, so whites are offered too.
Hint.install(NurikabeBoard, {
    getUser     = function(b, r, c) return b.user[r][c] end,
    getSolution = function(b, r, c)
        return b.solution_black[r][c] and STATE_BLACK or STATE_WHITE
    end,
    isEmpty     = function(v) return v == STATE_UNKNOWN end,
    isGiven     = function(b, r, c) return b.clues[r][c] > 0 end,
    setCell     = function(b, r, c, v) return b:setCellState(r, c, v) end,
    blank       = STATE_UNKNOWN,
})

function NurikabeBoard:serialize()
    local n = self.n
    local sb_out, wm_out = {}, {}
    for r = 1, n do
        sb_out[r], wm_out[r] = {}, {}
        for c = 1, n do
            sb_out[r][c] = self.solution_black[r][c] and true or false
            wm_out[r][c] = self.wrong_marks[r][c]    and true or false
        end
    end
    return {
        n               = n,
        difficulty      = self.difficulty,
        clues           = copyGrid(self.clues, n),
        solution_black  = sb_out,
        user            = copyGrid(self.user, n),
        wrong_marks     = wm_out,
        reveal_solution = self.reveal_solution,
        undo            = self.undo:serialize(),
    }
end

function NurikabeBoard:load(data)
    if type(data) ~= "table" or not data.clues then return false end
    local n         = data.n or DEFAULT_N
    self.n          = n
    self.difficulty = data.difficulty or DEFAULT_DIFFICULTY
    self.clues      = copyGrid(data.clues or {}, n)
    self.user       = copyGrid(data.user  or {}, n)

    self.solution_black = emptyBoolGrid(n)
    if data.solution_black then
        for r = 1, n do
            for c = 1, n do
                local v = data.solution_black[r] and data.solution_black[r][c]
                self.solution_black[r][c] = (v == true or v == 1)
            end
        end
    end

    self.wrong_marks = emptyBoolGrid(n)
    if data.wrong_marks then
        for r = 1, n do
            for c = 1, n do
                local v = data.wrong_marks[r] and data.wrong_marks[r][c]
                self.wrong_marks[r][c] = (v == true or v == 1)
            end
        end
    end

    self.reveal_solution = data.reveal_solution or false
    self.undo = UndoStack:new{ max_size = 200 }
    if data.undo then self.undo:load(data.undo) end
    return true
end

NurikabeBoard.STATE_UNKNOWN = STATE_UNKNOWN
NurikabeBoard.STATE_BLACK   = STATE_BLACK
NurikabeBoard.STATE_WHITE   = STATE_WHITE

-- exposed for the specs and the audit script
NurikabeBoard.countSolutions = countSolutions

-- Logic solve of a 2D clue grid, at most `max_tier` (1-3, default 3).
-- Returns solved, stats {t1, t2, t3}: solver rounds that needed each tier.
function NurikabeBoard.logicSolve(clues, n, max_tier)
    local clue = {}
    for r = 1, n do for c = 1, n do clue[(r - 1) * n + c] = clues[r][c] end end
    local ok, _st, stats = solve(n, clue, max_tier or 3, 3000)
    return ok, stats
end

return NurikabeBoard
