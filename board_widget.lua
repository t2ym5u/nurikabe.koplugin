local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local RenderText = require("ui/rendertext")
local Size       = require("ui/size")

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local function lrequire_common(name)
    local key = _dir .. "common/" .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. "common/" .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local gwb            = lrequire_common("grid_widget_base")
local GridWidgetBase = gwb.GridWidgetBase
local drawLine       = gwb.drawLine

local NurikabeBoard = lrequire("board")

local C_BG       = Blitbuffer.COLOR_WHITE
local C_BLACK_BG = Blitbuffer.COLOR_BLACK
local C_WRONG_BG = Blitbuffer.COLOR_GRAY_A
local C_WHITE_BG = Blitbuffer.COLOR_GRAY_E
local C_LINE     = Blitbuffer.COLOR_BLACK
local C_NUM_DARK = Blitbuffer.COLOR_BLACK
local C_NUM_WH   = Blitbuffer.COLOR_WHITE
local C_DOT      = Blitbuffer.COLOR_GRAY_4

local NurikabeBoardWidget = GridWidgetBase:extend{
    board = nil,
}

function NurikabeBoardWidget:init()
    local n   = self.board and self.board.n or 5
    self.cols = n
    self.rows = n
    GridWidgetBase.init(self)

end

function NurikabeBoardWidget:onCellTap(row, col)
    if self.onCellAction then self.onCellAction(row, col, false) end
end

function NurikabeBoardWidget:onCellHold(row, col)
    if self.onCellAction then self.onCellAction(row, col, true) end
end

function NurikabeBoardWidget:paintTo(bb, x, y)
    if not self.board then return end
    self.paint_rect = Geom:new{ x=x, y=y, w=self.dimen.w, h=self.dimen.h }

    local n    = self.board.n
    local cell = self.dimen.w / n

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Cell backgrounds
    for r = 1, n do
        for c = 1, n do
            local cx = x + math.floor((c-1)*cell)
            local cy = y + math.floor((r-1)*cell)
            local cw = math.ceil(cell)
            local ch = math.ceil(cell)
            local u  = self.board.user[r][c]

            if self.board:isShowingSolution() then
                if self.board.solution_black[r][c] then
                    bb:paintRect(cx, cy, cw, ch, C_BLACK_BG)
                end
            elseif u == NurikabeBoard.STATE_BLACK then
                bb:paintRect(cx, cy, cw, ch, C_BLACK_BG)
            elseif self.board.wrong_marks[r][c] then
                bb:paintRect(cx, cy, cw, ch, C_WRONG_BG)
            elseif u == NurikabeBoard.STATE_WHITE and self.board.clues[r][c] == 0 then
                bb:paintRect(cx, cy, cw, ch, C_WHITE_BG)
            end
        end
    end

    -- Grid lines
    local thin  = Size.line.thin  or 1
    local thick = Size.line.thick or 2
    for i = 0, n do
        local lw = (i == 0 or i == n) and thick or thin
        drawLine(bb, x + math.floor(i*cell), y, lw, self.dimen.h, C_LINE)
        drawLine(bb, x, y + math.floor(i*cell), self.dimen.w, lw, C_LINE)
    end

    -- Cell content
    local pad   = self.number_padding or 2
    local inner = math.max(1, math.floor(cell - 2*pad))

    for r = 1, n do
        for c = 1, n do
            local cx    = x + math.floor((c-1)*cell)
            local cy    = y + math.floor((r-1)*cell)
            local cw    = math.ceil(cell)
            local ch    = math.ceil(cell)
            local clue  = self.board.clues[r][c]
            local u     = self.board.user[r][c]
            local show  = self.board:isShowingSolution()

            local is_black_display = show and self.board.solution_black[r][c]
                or (not show and u == NurikabeBoard.STATE_BLACK)

            if clue > 0 then
                -- Draw clue number (bold island seed)
                local text   = tostring(clue)
                local color  = is_black_display and C_NUM_WH or C_NUM_DARK
                local m      = RenderText:sizeUtf8Text(0, inner, self.number_face, text, true, false)
                local base_y = cy + pad + math.floor((inner + m.y_top - m.y_bottom) / 2)
                local base_x = cx + pad + math.floor((inner - m.x) / 2)
                RenderText:renderUtf8Text(bb, base_x, base_y, self.number_face, text, true, false, color)
            elseif not is_black_display and not show
                    and u == NurikabeBoard.STATE_WHITE then
                -- Small dot to mark player-confirmed white cells
                local dot_r = math.max(2, math.floor(cell * 0.12))
                local dot_x = cx + math.floor(cw / 2)
                local dot_y = cy + math.floor(ch / 2)
                bb:paintCircle(dot_x, dot_y, dot_r, C_DOT)
            end
        end
    end
end

return NurikabeBoardWidget
