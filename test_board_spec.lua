local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

describe("NurikabeBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)


    local function newBoard(n, diff)
        math.randomseed(42)
        local b = Board:new{ n = n or 5 }
        b:generate(diff or "easy")
        return b
    end

    describe("construction", function()
        it("creates a 5×5 board by default", function()
            local b = Board:new()
            assert.are.equal(5, b.n)
        end)

        it("starts with all cells unknown", function()
            local b = Board:new{ n = 5 }
            for r = 1, b.n do
                for c = 1, b.n do
                    assert.are.equal(Board.STATE_UNKNOWN, b.user[r][c])
                end
            end
        end)
    end)

    describe("generate", function()
        it("has at least one clue cell", function()
            local b = newBoard(5)
            local count = 0
            for r = 1, b.n do
                for c = 1, b.n do
                    if b.clues[r][c] > 0 then count = count + 1 end
                end
            end
            assert.is_true(count >= 1)
        end)

        it("clue values are positive integers", function()
            local b = newBoard(5)
            for r = 1, b.n do
                for c = 1, b.n do
                    local v = b.clues[r][c]
                    assert.is_true(v >= 0)
                    if v > 0 then assert.is_true(v <= b.n * b.n) end
                end
            end
        end)

        it("solution has no 2×2 all-black blocks", function()
            local b = newBoard(5)
            local n = b.n
            for r = 1, n-1 do
                for c = 1, n-1 do
                    local all_black = b.solution_black[r][c] and b.solution_black[r+1][c]
                        and b.solution_black[r][c+1] and b.solution_black[r+1][c+1]
                    assert.is_false(all_black,
                        ("2x2 black block at [%d][%d]"):format(r, c))
                end
            end
        end)

        it("black cells in solution are connected", function()
            local b = newBoard(5)
            local n = b.n

            local start_r, start_c
            for r = 1, n do
                for c = 1, n do
                    if b.solution_black[r][c] then start_r, start_c = r, c; break end
                end
                if start_r then break end
            end

            if not start_r then return end  -- no black cells is vacuously connected

            local visited = {}
            for r = 1, n do visited[r] = {} end
            local stack = {{start_r, start_c}}
            visited[start_r][start_c] = true
            local count = 1
            while #stack > 0 do
                local cell = table.remove(stack)
                for _, d in ipairs({{-1,0},{1,0},{0,-1},{0,1}}) do
                    local nr, nc = cell[1]+d[1], cell[2]+d[2]
                    if nr >= 1 and nr <= n and nc >= 1 and nc <= n
                        and b.solution_black[nr][nc] and not visited[nr][nc] then
                        visited[nr][nc] = true
                        count = count + 1
                        stack[#stack+1] = {nr, nc}
                    end
                end
            end

            local total = 0
            for r = 1, n do
                for c = 1, n do if b.solution_black[r][c] then total = total + 1 end end
            end
            assert.are.equal(total, count, "black cells not fully connected")
        end)
    end)

    describe("setCellState / cycleCellState", function()
        it("can set a non-clue cell to BLACK", function()
            local b = newBoard(5)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] == 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_not_nil(r)
            local ok = b:setCellState(r, c, Board.STATE_BLACK)
            assert.is_true(ok)
            assert.are.equal(Board.STATE_BLACK, b.user[r][c])
        end)

        it("rejects setting a clue cell", function()
            local b = newBoard(5)
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] > 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if not r then return end  -- no clue cell (shouldn't happen)
            local ok, reason = b:setCellState(r, c, Board.STATE_BLACK)
            assert.is_false(ok)
            assert.are.equal("clue_cell", reason)
        end)

        it("cycleCellState cycles UNKNOWN→BLACK→WHITE→UNKNOWN", function()
            local b = Board:new{ n = 5 }
            b.clues = require("grid_utils").emptyGrid(5, 5, 0)
            b.solution_black = require("grid_utils").emptyBoolGrid(5)
            b.user = require("grid_utils").emptyGrid(5, 5, 0)
            b.wrong_marks = require("grid_utils").emptyBoolGrid(5)
            b.user[1][1] = Board.STATE_UNKNOWN
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_BLACK, b.user[1][1])
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_WHITE, b.user[1][1])
            b:cycleCellState(1, 1)
            assert.are.equal(Board.STATE_UNKNOWN, b.user[1][1])
        end)
    end)

    describe("undo", function()
        it("canUndo is false before any action", function()
            local b = newBoard(5)
            assert.is_false(b:canUndo())
        end)

        it("restores previous cell state after undo", function()
            local b = newBoard(5)
            -- Find a non-clue cell
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] == 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            assert.is_not_nil(r)
            b:setCellState(r, c, Board.STATE_BLACK)
            assert.is_true(b:canUndo())
            Board.undo(b)
            assert.are.equal(Board.STATE_UNKNOWN, b.user[r][c])
            assert.is_false(b:canUndo())
        end)
    end)

    describe("checkProgress", function()
        it("marks a wrongly-placed black cell", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            -- Find a solution-white, non-clue cell and mark it black
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if not b.solution_black[rr][cc] and b.clues[rr][cc] == 0 then
                        r, c = rr, cc; goto done
                    end
                end
            end
            ::done::
            if not r then return end
            b.user[r][c] = Board.STATE_BLACK
            b:checkProgress()
            assert.is_true(b.wrong_marks[r][c])
        end)
    end)

    describe("isSolved", function()
        it("returns false for empty board", function()
            local b = newBoard(5)
            assert.is_false(b:isSolved())
        end)

        it("returns true when user matches solution", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            local n = b.n
            for r = 1, n do
                for c = 1, n do
                    if b.solution_black[r][c] then
                        b.user[r][c] = Board.STATE_BLACK
                    else
                        b.user[r][c] = Board.STATE_WHITE
                    end
                end
            end
            assert.is_true(b:isSolved())
        end)
    end)

    describe("serialize / load", function()
        it("round-trips clues and user state", function()
            math.randomseed(42)
            local b = Board:new{ n = 5 }
            b:generate("easy")
            -- Set a non-clue cell
            local r, c
            for rr = 1, b.n do
                for cc = 1, b.n do
                    if b.clues[rr][cc] == 0 then r, c = rr, cc; goto done end
                end
            end
            ::done::
            if r then b.user[r][c] = Board.STATE_BLACK end

            local data = b:serialize()
            local b2   = Board:new{ n = 5 }
            local ok   = b2:load(data)
            assert.is_true(ok)
            assert.are.equal(b.n, b2.n)
            if r then assert.are.equal(Board.STATE_BLACK, b2.user[r][c]) end
            -- Clues preserved
            for rr = 1, b.n do
                for cc = 1, b.n do
                    assert.are.equal(b.clues[rr][cc], b2.clues[rr][cc])
                end
            end
        end)

        it("load returns false for invalid data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
        end)
    end)
    describe("uniqueness check (1.5.0)", function()
        it("counts each island shape once, whatever order it grows in", function()
            -- 2x2, a 3 in a corner: the island is any 3 cells holding it
            -- (3 shapes); the old search also counted the L through both
            -- neighbours twice, once per growth order.
            local clues = { { 3, 0 }, { 0, 0 } }
            local solutions, exhausted = Board.countSolutions(clues, 2, 100, 1e6)
            assert.is_false(exhausted)
            assert.are.equal(3, solutions)
            assert.are.equal(2, (Board.countSolutions({ { 2, 0 }, { 0, 0 } }, 2, 100, 1e6)))
            assert.are.equal(1, (Board.countSolutions({ { 1, 0 }, { 0, 0 } }, 2, 100, 1e6)))
        end)

        it("logic solver: each deduction tier is needed somewhere", function()
            -- 2 in a corner of a 2x2: two ways, never decided -> stuck
            assert.is_false((Board.logicSolve({ { 2, 0 }, { 0, 0 } }, 2, 3)))
            -- all 1s: decided by the basic rules alone
            assert.is_true((Board.logicSolve({ { 1, 0 }, { 0, 1 } }, 2, 1)))
        end)
    end)

    describe("generator (1.6.0)", function()
        local SIZES, DIFFS = { 5, 10, 15 }, { "easy", "medium", "hard" }
        local TIER = { easy = 1, medium = 2, hard = 3 }
        local MAX_ISLAND = { easy = { 4, 5 }, medium = { 5, 7 }, hard = { 6, 9 } }
        local DIRS4 = { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }

        local function gen(n, diff, seed)
            math.randomseed(seed * 7919 + n)
            local b = Board:new{ n = n }
            b:generate(diff)
            return b
        end

        -- islands of the stored solution: one number each, size = number
        local function checkSolution(b)
            local n = b.n
            local sb, clues = b.solution_black, b.clues
            local seen, black, reached = {}, 0, 0
            for r = 1, n do seen[r] = {} end
            local first
            for r = 1, n do for c = 1, n do
                if sb[r][c] then black = black + 1; first = first or { r, c } end
                if r < n and c < n then
                    assert.is_false(sb[r][c] and sb[r + 1][c] and sb[r][c + 1] and sb[r + 1][c + 1],
                        "2x2 river block")
                end
            end end
            -- river connected
            local stack = { first }
            seen[first[1]][first[2]] = true
            while #stack > 0 do
                local p = table.remove(stack)
                reached = reached + 1
                for _, d in ipairs(DIRS4) do
                    local r, c = p[1] + d[1], p[2] + d[2]
                    if r >= 1 and r <= n and c >= 1 and c <= n and sb[r][c] and not seen[r][c] then
                        seen[r][c] = true; stack[#stack + 1] = { r, c }
                    end
                end
            end
            assert.are.equal(black, reached, "river not connected")
            -- islands
            local islands = 0
            for r = 1, n do for c = 1, n do
                if not sb[r][c] and not seen[r][c] then
                    islands = islands + 1
                    local st2, size, number = { { r, c } }, 0, 0
                    seen[r][c] = true
                    while #st2 > 0 do
                        local p = table.remove(st2)
                        size = size + 1
                        local v = clues[p[1]][p[2]]
                        if v > 0 then
                            assert.are.equal(0, number, "two numbers in one island")
                            number = v
                        end
                        for _, d in ipairs(DIRS4) do
                            local rr, cc = p[1] + d[1], p[2] + d[2]
                            if rr >= 1 and rr <= n and cc >= 1 and cc <= n and not sb[rr][cc]
                                and not seen[rr][cc] then
                                seen[rr][cc] = true; st2[#st2 + 1] = { rr, cc }
                            end
                        end
                    end
                    assert.are.equal(number, size, "island size differs from its number")
                end
            end end
            return islands
        end

        it("every size and difficulty: proper, unique, solvable without guessing", function()
            for _, n in ipairs(SIZES) do
                for _, diff in ipairs(DIFFS) do
                    for seed = 1, 3 do
                        local b = gen(n, diff, seed)
                        local where = ("n=%d %s seed=%d"):format(n, diff, seed)
                        local islands = checkSolution(b)
                        -- not the old single-island fallback: many islands,
                        -- none above the level's size cap
                        assert.is_true(islands >= math.floor(n * n / 12), where .. ": too few islands")
                        local cap = MAX_ISLAND[diff][n <= 6 and 1 or 2]
                        for r = 1, n do for c = 1, n do
                            assert.is_true(b.clues[r][c] <= cap, where .. ": island too big")
                        end end
                        -- exactly one solution (independent exact counter)
                        local solutions, exhausted = Board.countSolutions(b.clues, n, 2, 2e6)
                        assert.is_false(exhausted, where)
                        assert.are.equal(1, solutions, where .. ": not unique")
                        -- solvable by deduction alone within the level's tier
                        assert.is_true((Board.logicSolve(b.clues, n, TIER[diff])), where .. ": needs guessing")
                    end
                end
            end
        end)

        it("difficulties differ: Medium needs more than the basic rules, Hard the most", function()
            for _, n in ipairs({ 5, 10 }) do
                local needs = { easy = { 0, 0, 0 }, medium = { 0, 0, 0 }, hard = { 0, 0, 0 } }
                local seeds = 8
                for _, diff in ipairs(DIFFS) do
                    for seed = 1, seeds do
                        local b = gen(n, diff, seed)
                        local t = (Board.logicSolve(b.clues, n, 1)) and 1
                            or (Board.logicSolve(b.clues, n, 2)) and 2 or 3
                        needs[diff][t] = needs[diff][t] + 1
                    end
                end
                assert.are.equal(seeds, needs.easy[1], "Easy must need the basic rules only")
                assert.is_true(needs.medium[2] >= seeds - 1, ("n=%d Medium too easy"):format(n))
                assert.are.equal(0, needs.medium[3], "Medium never needs Hard reasoning")
                assert.is_true(needs.hard[3] >= seeds - 1, ("n=%d Hard too easy"):format(n))
            end
        end)

        it("islands of varied sizes, not mostly 1s (1.7.0)", function()
            -- 1.6.0 had ~70% of islands of one cell at 10x10 and 15x15
            for _, n in ipairs({ 10, 15 }) do
                for _, diff in ipairs(DIFFS) do
                    local islands, ones = 0, 0
                    for seed = 1, 6 do
                        local b = gen(n, diff, seed)
                        for r = 1, n do for c = 1, n do
                            local v = b.clues[r][c]
                            if v > 0 then
                                islands = islands + 1
                                if v == 1 then ones = ones + 1 end
                            end
                        end end
                    end
                    assert.is_true(ones / islands < (n == 10 and 0.62 or 0.66),
                        ("n=%d %s: %d of %d islands are 1s"):format(n, diff, ones, islands))
                end
            end
        end)

        it("a puzzle reported at its level really needs that level (1.7.0)", function()
            local short = 0
            for _, n in ipairs(SIZES) do
                for _, diff in ipairs({ "medium", "hard" }) do
                    for seed = 1, 5 do
                        local b = gen(n, diff, seed)
                        local t = (Board.logicSolve(b.clues, n, 1)) and 1
                            or (Board.logicSolve(b.clues, n, 2)) and 2 or 3
                        assert.are.equal(t < TIER[diff], b.gen_short == true,
                            ("n=%d %s seed=%d"):format(n, diff, seed))
                        if b.gen_short then short = short + 1 end
                    end
                end
            end
            -- rare: about 1 in 50 Medium, 1 in 10-20 Hard puzzles
            assert.is_true(short <= 2, short .. " of 30 puzzles easier than their level")
        end)

        it("same seed, same puzzle (Daily Challenge)", function()
            for _, n in ipairs(SIZES) do
                local a, b = gen(n, "hard", 11), gen(n, "hard", 11)
                for r = 1, n do for c = 1, n do
                    assert.are.equal(a.clues[r][c], b.clues[r][c])
                end end
            end
        end)

        it("generation stays fast", function()
            for _, n in ipairs(SIZES) do
                for _, diff in ipairs(DIFFS) do
                    local worst = 0
                    for seed = 1, 4 do
                        local t0 = os.clock()
                        gen(n, diff, seed + 100)
                        worst = math.max(worst, os.clock() - t0)
                    end
                    -- at most ~0.04 s with LuaJIT on a desktop; generous
                    -- for plain Lua and slow CI
                    assert.is_true(worst < 1.5, ("n=%d diff=%s took %.2fs"):format(n, diff, worst))
                end
            end
        end)

        it("reports progress while generating", function()
            local calls, last = 0, 0
            math.randomseed(3)
            Board:new{ n = 10 }:generate("easy", function(f)
                calls = calls + 1
                assert.is_true(f >= last and f <= 1)
                last = f
            end)
            assert.is_true(calls > 0)
        end)
    end)
end)
