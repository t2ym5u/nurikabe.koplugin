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

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase          = lrequire_common("screen_base")
local MenuHelper          = lrequire_common("menu_helper")
local NurikabeBoard       = lrequire("board")
local NurikabeBoardWidget = lrequire("board_widget")

local GRID_SIZES = { 5, 10, 15 }

local GAME_RULES_EN = _([[
Nurikabe — Rules

Paint some cells black (the "river") and leave others white (the "islands").

Rules:
• Each numbered white cell is the seed of an island of exactly that many white cells.
• All black cells must form one single orthogonally connected group (the river).
• No 2×2 area may be entirely black.
• Islands (groups of white cells) must not touch each other orthogonally — diagonal contact is allowed.

Tap a cell to cycle: Unknown → Black → White → Unknown. Hold to reset to Unknown.
]])

local GAME_RULES_FR = [[
Nurikabe — Règles

Peignez certaines cases en noir (la "rivière") et laissez les autres en blanc (les "îles").

Règles :
• Chaque case blanche numérotée est la source d'une île de exactement ce nombre de cases blanches.
• Toutes les cases noires doivent former un seul groupe orthogonalement connecté (la rivière).
• Aucun carré 2×2 ne peut être entièrement noir.
• Les îles (groupes de cases blanches) ne doivent pas se toucher orthogonalement — le contact en diagonale est autorisé.

Appuyez sur une case pour cycler : Inconnu → Noir → Blanc → Inconnu. Restez appuyé pour remettre à Inconnu.
]]

local NurikabeScreen = ScreenBase:extend{}

function NurikabeScreen:init()
    local state = self.plugin:loadState()
    local n     = self.plugin:getSetting("grid_n", 5)
    self.board  = NurikabeBoard:new{ n = n }
    if not self.board:load(state) then
        self.board:generate(self.plugin:getSetting("difficulty", "easy"))
    end
    self.last_check_result = nil
    ScreenBase.init(self)
end

function NurikabeScreen:serializeState()
    return self.board:serialize()
end

function NurikabeScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Nurikabe"), function()
        return {
            { text = _("New game"),            callback = function() self:onNewGame() end },
            self:makeDailyButtonConfig(),
            { text = self:getGridButtonText(), callback = function() self:openGridMenu() end },
            { text = self:getDiffButtonText(), callback = function() self:openDifficultyMenu() end },
            { text = self:getRevealButtonText(), callback = function() self:toggleSolution() end },
            self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR),
        }
    end)

    -- Controls first: the board is sized from whatever room they leave.
    self.status_text:setMaxWidth(self:getControlsWidth())
    local action_bar = self:buildActionBar({
        { text = _("Check"), callback = function() self:onCheck() end },
        { text = _("Hint"), callback = function() self:onHint() end },
        { id = "undo_button", text = _("Undo"),
          callback = function() self:onUndo() end },
    })
    self.undo_button = action_bar:getButtonById("undo_button")
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        action_bar,
    }

    -- The widget draws its own thick outer border, so the frame only pads.
    local frame_pad   = Size.padding.large
    local frame_extra = 2 * frame_pad
    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = NurikabeBoardWidget:new{
        board        = self.board,
        max_size     = math.min(budget_w, budget_h) - frame_extra,
        onCellAction = function(r, c, is_hold)
            self:onCellAction(r, c, is_hold)
        end,
    }
    local board_frame = FrameContainer:new{
        padding    = frame_pad,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }
    self:_updateUndoButton()

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function NurikabeScreen:onCellAction(r, c, is_hold)
    if self.board:isShowingSolution() then return end
    if is_hold then
        self.board:setCellState(r, c, NurikabeBoard.STATE_UNKNOWN)
    else
        self.board:cycleCellState(r, c)
    end
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:_updateUndoButton()
    self.board_widget:refresh()
    if self.board:isSolved() then
        self:updateStatus(_("Congratulations! Puzzle solved."))
    else
        self:updateStatus()
    end
    self:refreshActionBar()
end

function NurikabeScreen:onNewGame()
    local diff = self.plugin:getSetting("difficulty", "easy")
    local n    = self.plugin:getSetting("grid_n", 5)
    self.board = NurikabeBoard:new{ n = n }
    self.board:generate(diff)
    self.last_check_result = nil
    self.plugin:saveState(self.board:serialize())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function NurikabeScreen:onUndo()
    -- The board's `undo` field (its UndoStack) shadows the :undo() method.
    local ok, msg = NurikabeBoard.undo(self.board)
    if ok then
        self.last_check_result = nil
        self.plugin:saveState(self.board:serialize())
        self:_updateUndoButton()
        self.board_widget:refresh()
        self:updateStatus()
    else
        self:updateStatus(msg)
    end
    self:refreshActionBar()
end

function NurikabeScreen:isRoundOver()
    return self.board:isSolved()
end

-- A hint can place the last cell, so the round may end here.
function NurikabeScreen:onHint()
    ScreenBase.onHint(self)
    self:refreshActionBar()
end

function NurikabeScreen:onCheck()
    self.board:checkProgress()
    local ok, violations = self.board:validateRules()
    self.last_check_result = ok
    self.board_widget:refresh()
    if ok then
        if self.board:isSolved() then
            self:updateStatus(_("Congratulations! Puzzle solved."))
        else
            self:updateStatus(_("No violations found so far."))
        end
    else
        self:updateStatus(T(_("Check: %1 violation(s) found."), #violations))
    end
end

function NurikabeScreen:toggleSolution()
    self.board:toggleSolution()
    self.board_widget:refresh()
    if self.reveal_button then
        self.reveal_button:setText(self:getRevealButtonText(), self.reveal_button.width)
    end
    self:updateStatus()
end

function NurikabeScreen:openGridMenu()
    local sizes = {}
    for _, sz in ipairs(GRID_SIZES) do
        sizes[#sizes+1] = { id = sz, text = sz .. "\xC3\x97" .. sz }
    end
    MenuHelper.openSizeMenu{
        title     = _("Select size"),
        sizes     = sizes,
        current   = self.plugin:getSetting("grid_n", 5),
        parent    = self,
        on_select = function(sz)
            if sz ~= self.board.n then
                self.plugin:saveSetting("grid_n", sz)
                self:onNewGame()
            end
        end,
    }
end

function NurikabeScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "easy"),
        parent    = self,
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            if self.diff_button then
                self.diff_button:setText(self:getDiffButtonText(), self.diff_button.width)
            end
            self:onNewGame()
        end,
    }
end

function NurikabeScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board:isShowingSolution() then
        status = _("Solution is shown; editing is disabled.")
    elseif self.board:isSolved() then
        status = _("Congratulations! Puzzle solved.")
    else
        local remaining = self.board:getRemainingCells()
        local diff      = self.plugin:getSetting("difficulty", "easy")
        local label     = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        status = self:joinStatus(
            T("%1×%1", self.board.n), label, T(_("Unknown: %1"), remaining))
    end
    ScreenBase.updateStatus(self, status)
end

function NurikabeScreen:getGridButtonText()
    return T(_("Size: %1"), self.board.n .. "\xC3\x97" .. self.board.n)
end

function NurikabeScreen:getDiffButtonText()
    local diff  = self.plugin:getSetting("difficulty", "easy")
    local label = MenuHelper.DIFFICULTY_LABELS[diff] or diff
    return T(_("Difficulty: %1"), label)
end

function NurikabeScreen:getRevealButtonText()
    return self.board:isShowingSolution() and _("Hide solution") or _("Show solution")
end

function NurikabeScreen:_updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

return NurikabeScreen
