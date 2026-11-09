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
    end)

    describe("generator", function()
        local DIFFS = { "easy", "medium", "hard" }

        local function gen(n, diff, seed)
            math.randomseed(seed * 7919 + n)
            local b = Board:new{ n = n }
            b:generate(diff)
            return b
        end

        -- Difficulty guarantees live in test_difficulty_spec.lua.

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
