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

-- Counts region-tiling completions (up to `limit`) consistent with the
-- given island clues (each clue is a target size at a fixed seed cell).
-- Grows islands directly (MRV: always extend whichever incomplete island
-- currently has the fewest legal frontier cells, branching over each),
-- mirroring how tryGenerate itself constructs a solution -- an EARLIER
-- version processed cells in fixed row-major order and let a cell join an
-- island only via an already-decided same-island NEIGHBOR, which silently
-- misses any valid shape where the seed isn't that island's row-major-
-- topmost-leftmost cell (islands grow in every direction from the seed, so
-- this is common) and was consequently both wrong (under-counted,
-- sometimes missing the known-valid solution entirely) and pathologically
-- slow at n=10+. Once every island reaches its target size, whatever's
-- left is checked for full black connectivity and no 2x2 block. Returns
-- (solutions_found, exhausted); exhausted=true means node_budget was hit
-- before the search concluded, so the count isn't proof. Mirrors
-- sudokukiller.koplugin/board.lua's countCageSolutions.
local function countSolutions(clues, n, limit, node_budget)
    local islands = {}
    for r = 1, n do for c = 1, n do
        if clues[r][c] > 0 then
            islands[#islands + 1] = { r = r, c = c, target = clues[r][c], cells = { { r, c } } }
        end
    end end
    local num_islands = #islands

    local color = {} -- 0 = undecided, i = island i (black is implicit: still 0 at the end)
    for r = 1, n do
        color[r] = {}
        for c = 1, n do color[r][c] = 0 end
    end
    local island_count = {}
    for i = 1, num_islands do
        island_count[i] = 1
        color[islands[i].r][islands[i].c] = i
    end

    local solutions, nodes, exhausted = 0, 0, false

    local function frontierFor(idx)
        local isl = islands[idx]
        local cands, seen = {}, {}
        for _, cell in ipairs(isl.cells) do
            for _, d in ipairs(DIRS) do
                local nr, nc = cell[1] + d[1], cell[2] + d[2]
                local key = nr * 1000 + nc
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and color[nr][nc] == 0 and not seen[key] then
                    local conflict = false
                    for _, d2 in ipairs(DIRS) do
                        local mr, mc = nr + d2[1], nc + d2[2]
                        if mr >= 1 and mr <= n and mc >= 1 and mc <= n then
                            local v = color[mr][mc]
                            if v > 0 and v ~= idx then conflict = true; break end
                        end
                    end
                    if not conflict then
                        seen[key] = true
                        cands[#cands + 1] = { nr, nc }
                    end
                end
            end
        end
        return cands
    end

    local function finalBlackValid()
        for r = 1, n - 1 do
            for c = 1, n - 1 do
                if color[r][c] == 0 and color[r + 1][c] == 0 and color[r][c + 1] == 0 and color[r + 1][c + 1] == 0 then
                    return false
                end
            end
        end
        local start_r, start_c, total = nil, nil, 0
        for r = 1, n do for c = 1, n do
            if color[r][c] == 0 then
                total = total + 1
                if not start_r then start_r, start_c = r, c end
            end
        end end
        if total == 0 then return true end
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local stack = { { start_r, start_c } }
        visited[start_r][start_c] = true
        local seen = 1
        while #stack > 0 do
            local cur = table.remove(stack)
            for _, d in ipairs(DIRS) do
                local nr, nc = cur[1] + d[1], cur[2] + d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n and color[nr][nc] == 0 and not visited[nr][nc] then
                    visited[nr][nc] = true
                    seen = seen + 1
                    stack[#stack + 1] = { nr, nc }
                end
            end
        end
        return seen == total
    end

    local function search()
        if solutions >= limit or exhausted then return end
        nodes = nodes + 1
        if nodes > node_budget then exhausted = true; return end

        local best_idx, best_frontier, best_len = nil, nil, math.huge
        for i = 1, num_islands do
            if island_count[i] < islands[i].target then
                local frontier = frontierFor(i)
                if #frontier < best_len then
                    best_len, best_frontier, best_idx = #frontier, frontier, i
                    if best_len == 0 then break end
                end
            end
        end

        if not best_idx then
            if finalBlackValid() then solutions = solutions + 1 end
            return
        end
        if best_len == 0 then return end

        local isl = islands[best_idx]
        for _, cell in ipairs(best_frontier) do
            local cr, cc = cell[1], cell[2]
            color[cr][cc] = best_idx
            isl.cells[#isl.cells + 1] = cell
            island_count[best_idx] = island_count[best_idx] + 1
            search()
            island_count[best_idx] = island_count[best_idx] - 1
            isl.cells[#isl.cells] = nil
            color[cr][cc] = 0
            if solutions >= limit or exhausted then return end
        end
    end
    search()
    return solutions, exhausted
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

    local function blackConnectedWithout(er, ec)
        local sr, sc
        for r = 1, n do
            for c = 1, n do
                if cell_island[r][c] == 0 and not (r == er and c == ec) then
                    sr, sc = r, c; break
                end
            end
            if sr then break end
        end
        if not sr then return true end
        local visited = {}
        for r = 1, n do visited[r] = {} end
        local stack = { {sr, sc} }
        visited[sr][sc] = true
        local count = 1
        while #stack > 0 do
            local cell = table.remove(stack)
            for _, d in ipairs(DIRS) do
                local nr, nc = cell[1]+d[1], cell[2]+d[2]
                if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                    and cell_island[nr][nc] == 0 and not (nr == er and nc == ec)
                    and not visited[nr][nc] then
                    visited[nr][nc] = true
                    count = count + 1
                    stack[#stack+1] = {nr, nc}
                end
            end
        end
        local total = 0
        for r = 1, n do
            for c = 1, n do
                if cell_island[r][c] == 0 and not (r == er and c == ec) then
                    total = total + 1
                end
            end
        end
        return count == total
    end

    local growing = true
    while growing do
        growing = false
        for _, id in ipairs(order) do
            local island = islands[id]
            if #island.cells < island.target then
                local candidates = {}
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
                            if ok and blackConnectedWithout(nr, nc) then
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
                    if blackConnectedWithout(pr, pc) then
                        local adj_id, conflict = nil, false
                        for _, d in ipairs(DIRS) do
                            local nr, nc = pr+d[1], pc+d[2]
                            if nr >= 1 and nr <= n and nc >= 1 and nc <= n and cell_island[nr][nc] > 0 then
                                if adj_id and adj_id ~= cell_island[nr][nc] then conflict = true end
                                adj_id = cell_island[nr][nc]
                            end
                        end
                        if not conflict then
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
-- Budget/attempts scale down for larger n: at n=5, most attempts are
-- proven unique almost instantly. At n=10+, with several islands needing
-- simultaneous growth, proving uniqueness is usually computationally
-- infeasible within any budget that keeps generation fast -- empirically,
-- 0/5 trials found a proven-unique layout in 150 attempts x 20k nodes at
-- n=10. Burning the full n=5 budget there would cost ~15-60s per
-- generation for no better odds, so this trades a lower (but nonzero)
-- chance of a *proven* puzzle at large n for bounded, fast generation --
-- the graceful fallback below (prefer the best structurally-valid layout
-- found) means large-n puzzles are exactly as reliable as before this fix,
-- never worse, just not provably unique yet. See
-- spec/solvability_audits/nurikabe_solvability_check.lua for the measured
-- per-size hit rate.
local function uniquenessBudgetFor(n)
    if n <= 6 then return 400, 300000 end
    if n <= 10 then return 30, 20000 end
    return 15, 10000
end

function NurikabeBoard:generate(difficulty)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n   = self.n
    local cfg = DIFF_CONFIG[self.difficulty] or DIFF_CONFIG.easy
    local num_islands = math.max(2, math.floor(n*n * cfg[1] / 100))
    local max_attempts, node_budget = uniquenessBudgetFor(n)

    local clues, solution_black
    local best_clues, best_black
    for attempt = 1, max_attempts do
        local candidate_clues, candidate_black = tryGenerate(n, num_islands, cfg[2], cfg[3])
        if candidate_clues then
            if not best_clues then best_clues, best_black = candidate_clues, candidate_black end
            local solutions, exhausted = countSolutions(candidate_clues, n, 2, node_budget)
            if not exhausted and solutions == 1 then
                clues, solution_black = candidate_clues, candidate_black
                break
            end
        end
        if attempt % 30 == 0 and num_islands > 2 then num_islands = num_islands - 1 end
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

return NurikabeBoard
