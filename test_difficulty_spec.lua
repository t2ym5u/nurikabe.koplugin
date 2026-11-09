-- Difficulty guarantees for Nurikabe: every size x level builds quickly,
-- is unique, solves with the game's own logic solver (no trial) within the
-- level's tier, Easy needs the basic rules only, levels are ordered on
-- averages, and a seed always gives the same puzzle without the clock.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, s) return s end })
end
package.path = DIR .. "common/?.lua;" .. DIR .. "?.lua;" .. package.path

-- Runs fn with os.clock/os.time/os.date replaced by functions that fail:
-- a generator must bound its work by counts, never by time.
local function withoutClock(fn)
    local oc, ot, od = os.clock, os.time, os.date
    local function boom(name) return function() error("generator read " .. name, 2) end end
    os.clock, os.time, os.date = boom("os.clock"), boom("os.time"), boom("os.date")
    local ok, err = pcall(fn)
    os.clock, os.time, os.date = oc, ot, od
    if not ok then error(err, 0) end
end

describe("Nurikabe difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    it("logic solver: each deduction tier is needed somewhere", function()
        -- 2 in a corner of a 2x2: two ways, never decided -> stuck
        assert.is_false((Board.logicSolve({ { 2, 0 }, { 0, 0 } }, 2, 3)))
        -- all 1s: decided by the basic rules alone
        assert.is_true((Board.logicSolve({ { 1, 0 }, { 0, 1 } }, 2, 1)))
    end)

    describe("generator", function()
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

        it("levels are ordered on averages: tier needed and harder steps", function()
            for _, n in ipairs({ 5, 10 }) do
                local avg_tier, avg_hard = {}, {}
                local seeds = 6
                for _, diff in ipairs(DIFFS) do
                    local st, sh = 0, 0
                    for seed = 1, seeds do
                        local b = gen(n, diff, seed + 200)
                        local ok, stats = Board.logicSolve(b.clues, n, 3)
                        assert.is_true(ok)
                        local t = (Board.logicSolve(b.clues, n, 1)) and 1
                            or (Board.logicSolve(b.clues, n, 2)) and 2 or 3
                        st = st + t
                        sh = sh + stats[2] + 2 * stats[3]
                    end
                    avg_tier[diff], avg_hard[diff] = st / seeds, sh / seeds
                end
                local where = ("n=%d tier %.2f/%.2f/%.2f, hard steps %.1f/%.1f/%.1f"):format(n,
                    avg_tier.easy, avg_tier.medium, avg_tier.hard,
                    avg_hard.easy, avg_hard.medium, avg_hard.hard)
                assert.is_true(avg_tier.easy < avg_tier.medium and avg_tier.medium < avg_tier.hard, where)
                assert.is_true(avg_hard.easy < avg_hard.medium and avg_hard.medium < avg_hard.hard, where)
            end
        end)

        it("generation never reads the clock", function()
            for _, n in ipairs({ 5, 10 }) do
                for _, diff in ipairs(DIFFS) do
                    withoutClock(function() gen(n, diff, 3) end)
                end
            end
        end)
    end)
end)
