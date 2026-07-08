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

    -- Grow islands
    local order = {}
    for i = 1, num_islands do order[i] = i end
    shuffle(order)

    for _, id in ipairs(order) do
        local island = islands[id]
        for _ = 1, 200 do
            if #island.cells >= island.target then break end
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
                        if ok then candidates[#candidates+1] = {nr, nc} end
                    end
                end
            end
            if #candidates == 0 then break end
            local pick = candidates[math.random(#candidates)]
            cell_island[pick[1]][pick[2]] = id
            island.cells[#island.cells+1] = pick
        end
        island.target = #island.cells
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

function NurikabeBoard:generate(difficulty)
    self.difficulty      = difficulty or self.difficulty
    self.reveal_solution = false
    self.undo:clear()

    local n   = self.n
    local cfg = DIFF_CONFIG[self.difficulty] or DIFF_CONFIG.easy
    local num_islands = math.max(2, math.floor(n*n * cfg[1] / 100))

    local clues, solution_black
    for attempt = 1, 150 do
        clues, solution_black = tryGenerate(n, num_islands, cfg[2], cfg[3])
        if clues then break end
        if attempt % 30 == 0 and num_islands > 2 then num_islands = num_islands - 1 end
    end

    if not clues then
        -- Fallback: trivial single-island puzzle
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
