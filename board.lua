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
local shuffle       = grid_utils.shuffle

local STATE_UNKNOWN = 0
local STATE_BLACK   = 1
local STATE_WHITE   = 2

local DEFAULT_N          = 5
local DEFAULT_DIFFICULTY = "easy"

local DIRS = { {-1,0}, {1,0}, {0,-1}, {0,1} }

-- {islands_per_100_cells, min_island_size, max_island_size}
local DIFF_CONFIG = {
    easy   = { 8,  3, 6 },
    medium = { 12, 2, 4 },
    hard   = { 18, 1, 3 },
}

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
-- Generator
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Uniqueness check
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

local function tryGenerate(n, num_islands, min_sz, max_sz)
    local cell_island = emptyGrid(n, n, 0)
    local islands     = {}

    local all_cells = {}
    for r = 1, n do for c = 1, n do all_cells[#all_cells+1] = {r, c} end end
    shuffle(all_cells)

    local placed = 0
    for _, pos in ipairs(all_cells) do
        if placed >= num_islands then break end
        local r, c = pos[1], pos[2]
        if cell_island[r][c] == 0 then
            local ok = true
            for _, d in ipairs(DIRS) do
                local nr, nc = r+d[1], c+d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and cell_island[nr][nc] ~= 0 then
                    ok = false; break
                end
            end
            if ok then
                placed = placed + 1
                local target = math.random(min_sz, max_sz)
                target = math.min(target, math.max(1, math.floor(n*n / num_islands) + 2))
                cell_island[r][c] = placed
                islands[placed] = { id=placed, seed_r=r, seed_c=c, cells={{r,c}}, target=target }
            end
        end
    end
    if placed < num_islands then return nil end

    -- Grow islands round-robin (one cell at a time across all islands, not
    -- one island fully grown before the next) and only accept a growth step
    -- if it does NOT disconnect the remaining black region. The previous
    -- version only checked connectivity once at the very end, after
    -- committing to a full random growth pattern — that almost always cut
    -- black into disconnected pieces (empirically ~100% of attempts at
    -- n=10/15). Checking incrementally means a step that would disconnect
    -- black is simply never taken, so the final check below almost always
    -- already holds.
    local order = {}
    for i = 1, num_islands do order[i] = i end
    shuffle(order)

    -- removable[(r-1)*n+c]: black (r, c) can turn white with the rest of
    -- black still connected, for every cell at once: the non-articulation
    -- cells of a connected black region (Tarjan), or the lone cell of a
    -- 1-cell second component. One O(n^2) pass after each change instead
    -- of a flood fill per candidate cell (1.5.0: that flood fill was most
    -- of the time at 15x15); same answers, so the same puzzles.
    local disc, low, removable = {}, {}, {}
    local function blackRemovable()
        for i = 1, n * n do disc[i] = 0; removable[i] = false end
        local timer = 0
        local cut = {}
        local function dfs(i, parent)
            timer = timer + 1
            disc[i], low[i] = timer, timer
            local children = 0
            local r, c = math.floor((i - 1) / n) + 1, (i - 1) % n + 1
            for _, d in ipairs(DIRS) do
                local nr, nc = r + d[1], c + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and cell_island[nr][nc] == 0 then
                    local j = (nr - 1) * n + nc
                    if disc[j] == 0 then
                        children = children + 1
                        dfs(j, i)
                        if low[j] < low[i] then low[i] = low[j] end
                        if parent and low[j] >= disc[i] then cut[i] = true end
                    elseif j ~= parent and disc[j] < low[i] then
                        low[i] = disc[j]
                    end
                end
            end
            if not parent and children > 1 then cut[i] = true end
        end
        local comps = {}   -- { first cell, size } per black component
        for r = 1, n do for c = 1, n do
            local i = (r - 1) * n + c
            if cell_island[r][c] == 0 and disc[i] == 0 then
                local before = timer
                dfs(i, nil)
                comps[#comps + 1] = { i, timer - before }
            end
        end end
        if #comps == 1 then
            for i = 1, n * n do
                if disc[i] > 0 and not cut[i] then removable[i] = true end
            end
        elseif #comps == 2 then
            -- only a lone cell can go, leaving the other component whole
            for _, comp in ipairs(comps) do
                if comp[2] == 1 then removable[comp[1]] = true end
            end
        end
        return removable
    end

    local black_changed = true
    local growing = true
    while growing do
        growing = false
        for _, id in ipairs(order) do
            local island = islands[id]
            if #island.cells < island.target then
                local candidates = {}
                if black_changed then blackRemovable(); black_changed = false end
                local can_remove = removable
                for _, cell in ipairs(island.cells) do
                    for _, d in ipairs(DIRS) do
                        local nr, nc = cell[1]+d[1], cell[2]+d[2]
                        if nr >= 1 and nr <= n and nc >= 1 and nc <= n and cell_island[nr][nc] == 0 then
                            local ok = true
                            for _, d2 in ipairs(DIRS) do
                                local mr, mc = nr+d2[1], nc+d2[2]
                                if mr >= 1 and mr <= n and mc >= 1 and mc <= n then
                                    local v = cell_island[mr][mc]
                                    if v ~= 0 and v ~= id then ok = false; break end
                                end
                            end
                            if ok and can_remove[(nr - 1) * n + nc] then
                                candidates[#candidates+1] = {nr, nc}
                            end
                        end
                    end
                end
                if #candidates > 0 then
                    local pick = candidates[math.random(#candidates)]
                    cell_island[pick[1]][pick[2]] = id
                    island.cells[#island.cells+1] = pick
                    growing = true
                    black_changed = true
                end
            end
        end
    end
    for _, id in ipairs(order) do
        islands[id].target = #islands[id].cells
    end

    -- Repair pass: growth stopping early (islands ran out of legal moves
    -- before reaching their target) can still leave 2x2-black violations.
    -- Fix each by carving one cell of the block to white — connectivity-
    -- checked the same way growth was, and only when the cell has at most
    -- one distinct island neighbour (extend that island, or start a new
    -- size-1 island if it has none) so this never merges two islands or
    -- creates an illegal adjacency.
    for r = 1, n - 1 do
        for c = 1, n - 1 do
            if cell_island[r][c] == 0 and cell_island[r][c+1] == 0
                and cell_island[r+1][c] == 0 and cell_island[r+1][c+1] == 0 then
                local block_cells = { {r,c}, {r,c+1}, {r+1,c}, {r+1,c+1} }
                for _, pos in ipairs(block_cells) do
                    local pr, pc = pos[1], pos[2]
                    if black_changed then blackRemovable(); black_changed = false end
                    if removable[(pr - 1) * n + pc] then
                        local adj_id, conflict = nil, false
                        for _, d in ipairs(DIRS) do
                            local nr, nc = pr+d[1], pc+d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and cell_island[nr][nc] > 0 then
                                if adj_id and adj_id ~= cell_island[nr][nc] then conflict = true end
                                adj_id = cell_island[nr][nc]
                            end
                        end
                        if not conflict then
                            black_changed = true
                            if adj_id then
                                cell_island[pr][pc] = adj_id
                                local isl = islands[adj_id]
                                isl.cells[#isl.cells+1] = { pr, pc }
                                isl.target = #isl.cells
                            else
                                num_islands = num_islands + 1
                                cell_island[pr][pc] = num_islands
                                islands[num_islands] = {
                                    id = num_islands, seed_r = pr, seed_c = pc,
                                    cells = { { pr, pc } }, target = 1,
                                }
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    local solution_black = emptyBoolGrid(n)
    for r = 1, n do
        for c = 1, n do solution_black[r][c] = (cell_island[r][c] == 0) end
    end

    if not blackConnected(solution_black, n) then return nil end
    if has2x2Black(solution_black, n)        then return nil end

    local clues = emptyGrid(n, n, 0)
    for _, island in ipairs(islands) do
        clues[island.seed_r][island.seed_c] = island.target
    end
    return clues, solution_black
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

-- Nurikabe's clues are structurally 1-per-island (not a partial reveal of a
-- richer solution, unlike most Tier 2 plugins), so there's nothing to dig
-- -- this instead verifies each *candidate* layout tryGenerate produces and
-- retries on ambiguity, same as the existing retry-on-structural-failure
-- loop below. Verified necessary: real ambiguity was measured even though
-- every island's size is fully revealed (see
-- docs/generator_robustness_audit.md's Tier 2 table).
--
-- Budget: attempts, search nodes per uniqueness check, and search nodes
-- for the whole generate() call (counted in nodes, never time, so a seed
-- gives the same puzzle on every device). At n=5 a candidate is settled in
-- a few hundred nodes at most, so ~1 in 3 attempts is proven unique within
-- a handful of tries. At n=10+, with many islands growing at once, most
-- candidates have several solutions and a unique one is rare (and can take
-- 10k+ nodes to prove), so the total is capped and generation falls back
-- to the first structurally valid layout -- exactly what large grids got
-- before 1.5.0, whose (over-counting) check never proved one unique there
-- anyway, after up to 0.5 s of searching (seconds on an e-reader).
-- See spec/solvability_audits/nurikabe_solvability_check.lua for the
-- measured per-size hit rate.
local function uniquenessBudgetFor(n)
    if n <= 6 then return 400, 2000, 20000 end
    if n <= 10 then return 30, 600, 1500 end
    return 15, 300, 600
end

-- on_progress(fraction), optional: called after every attempt (screen.lua
-- wires it to the shared "Generating puzzle…" bar).
function NurikabeBoard:generate(difficulty, on_progress)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n   = self.n
    local cfg = DIFF_CONFIG[self.difficulty] or DIFF_CONFIG.easy
    local num_islands = math.max(2, math.floor(n*n * cfg[1] / 100))
    local max_attempts, node_budget, nodes_left = uniquenessBudgetFor(n)
    local nodes_total = nodes_left

    local clues, solution_black
    local best_clues, best_black
    for attempt = 1, max_attempts do
        local candidate_clues, candidate_black = tryGenerate(n, num_islands, cfg[2], cfg[3])
        if candidate_clues then
            if not best_clues then best_clues, best_black = candidate_clues, candidate_black end
            local solutions, exhausted, used = countSolutions(candidate_clues, n, 2,
                math.min(node_budget, nodes_left))
            if not exhausted and solutions == 1 then
                clues, solution_black = candidate_clues, candidate_black
                break
            end
            nodes_left = nodes_left - used
            if nodes_left <= 0 then break end
        end
        if attempt % 30 == 0 and num_islands > 2 then num_islands = num_islands - 1 end
        if on_progress then
            on_progress(math.max(attempt / max_attempts, 1 - nodes_left / nodes_total))
        end
    end

    if not clues then
        -- No attempt was provably unique within budget -- prefer a real,
        -- structurally valid layout over a degenerate fallback, same
        -- precedent as sudokukiller/kakuro/hitori's graceful-degradation
        -- tiers.
        clues, solution_black = best_clues, best_black
    end

    if not clues then
        -- Fallback: trivial single-island puzzle (only reached if every
        -- attempt failed structurally, not just on uniqueness) -- this is
        -- already provably unique: a single island target=n*n must cover
        -- every cell, so there's only one way to tile it.
        clues = emptyGrid(n, n, 0)
        clues[1][1] = n * n
        solution_black = emptyBoolGrid(n)
    end

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

-- exposed for the specs
NurikabeBoard.countSolutions = countSolutions

return NurikabeBoard
