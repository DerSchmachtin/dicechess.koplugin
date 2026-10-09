--[[--
Full-screen UI for Wuerfelschach (Dice Chess): handles both the alternating
setup phase (choose King square, then draft the rest of the back row from a
real chess set's piece pool) and the main game (roll a die, move a piece
from the rolled column, capture the enemy King to win). The status text is
shown twice -- once normal near White's edge, once upside-down near Black's
edge -- so both players can read it from their own seat at a shared device.
Board logic lives in dicechess_rules; this module is presentation and input.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Flip = require("dicechess_fliptext")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local Rules = require("dicechess_rules")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local Screen = Device.screen

local GLYPH = {
    [Rules.WHITE] = { K = "♔", Q = "♕", R = "♖", B = "♗", N = "♘", P = "♙" },
    [Rules.BLACK] = { K = "♚", Q = "♛", R = "♜", B = "♝", N = "♞", P = "♟" },
}

local DIE_FACE = { "⚀", "⚁", "⚂", "⚃", "⚄", "⚅" }

local PIECE_CHOICES = {
    { type = "Q", text = _("Queen") },
    { type = "R", text = _("Rook") },
    { type = "B", text = _("Bishop") },
    { type = "N", text = _("Knight") },
}

local STARTING_POOL = { Q = 1, R = 2, B = 2, N = 2 }

local MAX_CELL_NOMINAL = 46
local MESSAGE_FONT_SIZE = 17
local DICE_FONT_SIZE = 26

local function colorName(color)
    return color == Rules.WHITE and _("White") or _("Black")
end

-- A minimal tappable board square: a bordered box with a centered glyph.
local BoardCell = InputContainer:extend{
    text = "",
    background = nil,
    size = 0,
    callback = nil,
}

function BoardCell:init()
    local scale = Screen:scaleBySize(1)
    local font_size = math.floor((self.size * 0.7) / scale)
    if font_size < 6 then font_size = 6 end

    self.frame = FrameContainer:new{
        width = self.size,
        height = self.size,
        margin = 0,
        bordersize = Size.border.thin,
        color = Blitbuffer.COLOR_BLACK,
        background = self.background or Blitbuffer.COLOR_WHITE,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = self.size, h = self.size },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", font_size),
                fgcolor = Blitbuffer.COLOR_BLACK,
            },
        },
    }
    self.dimen = self.frame:getSize()
    self[1] = self.frame
    if self.callback then
        self.ges_events = {
            TapCell = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
        }
    end
end

function BoardCell:onTapCell()
    if self.callback then
        self.callback()
    end
    return true
end

local DiceChessWidget = InputContainer:extend{}

function DiceChessWidget:init()
    self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self:computeLayout()
    self:newGame()
end

-- Measures every fixed-height UI band exactly once, using worst-case
-- representative content, and caches the result. All later renders reuse
-- these numbers instead of re-measuring live widgets, which is what
-- previously made the board resize/jitter and let long status messages
-- push the Roll Dice button and board off the bottom of the screen.
function DiceChessWidget:computeLayout()
    local vpad = Size.padding.large

    local title = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        title = _("Dice Chess"),
        with_bottom_line = true,
        close_callback = function() end,
        show_parent = self,
    }
    local title_h = title:getSize().h

    local msg_width = self.dimen.w - 2 * Size.padding.large
    local sample_message = TextBoxWidget:new{
        text = _("White forfeits (col 6)"),
        face = Font:getFace("cfont", MESSAGE_FONT_SIZE),
        width = msg_width,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local message_h = sample_message:getSize().h

    local dice_sample = TextWidget:new{
        text = DIE_FACE[6],
        face = Font:getFace("cfont", DICE_FONT_SIZE),
    }
    local dice_h = dice_sample:getSize().h

    local sample_button = Button:new{ text = _("Roll Dice"), width = Screen:scaleBySize(160) }
    local controls_h = sample_button:getSize().h
    local restart_h = controls_h

    -- Bands, top to bottom: title, message(top), controls(top), dice(top),
    -- board, dice(bottom), controls(bottom), message(bottom), restart --
    -- 8 gaps between them. Controls and message are duplicated top/bottom
    -- so both seated players can read status and act from their own edge.
    local used_h = title_h + message_h * 2 + controls_h * 2 + dice_h * 2 + restart_h + vpad * 8

    local avail_w = self.dimen.w - 2 * Size.margin.default
    local avail_h = self.dimen.h - used_h
    if avail_h < Rules.ROWS then avail_h = Rules.ROWS end

    local cell_size = math.floor(math.min(avail_w / Rules.COLS, avail_h / Rules.ROWS))
    local max_cell = math.floor(Screen:scaleBySize(MAX_CELL_NOMINAL))
    if cell_size > max_cell then cell_size = max_cell end
    if cell_size < 1 then cell_size = 1 end

    self.layout = {
        vpad = vpad,
        msg_width = msg_width,
        message_h = message_h,
        dice_h = dice_h,
        controls_h = controls_h,
        restart_h = restart_h,
        cell_size = cell_size,
    }
end

function DiceChessWidget:newGame()
    self.board = Rules.newSetupBoard()
    self.last_double_step = false
    self.phase = "setup_king"
    self.setup_turn = Rules.WHITE
    self.setup_pending_piece = nil
    self.setup_placed = { [Rules.WHITE] = 0, [Rules.BLACK] = 0 }
    self.piece_pool = {
        [Rules.WHITE] = { Q = STARTING_POOL.Q, R = STARTING_POOL.R, B = STARTING_POOL.B, N = STARTING_POOL.N },
        [Rules.BLACK] = { Q = STARTING_POOL.Q, R = STARTING_POOL.R, B = STARTING_POOL.B, N = STARTING_POOL.N },
    }
    self.current_player = Rules.WHITE
    self.dice_value = nil
    self.movable = nil
    self.selected = nil
    self.status_note = nil
    self.awaiting_promotion_move = nil
    self.winner = nil
    self:render(true)
end

function DiceChessWidget:confirmNewGame()
    if self.phase == "setup_king" and self.setup_placed[Rules.WHITE] == 0 and self.setup_placed[Rules.BLACK] == 0 then
        self:newGame()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Start a new game? The current game will be lost."),
        ok_text = _("New game"),
        ok_callback = function() self:newGame() end,
    })
end

-- ---------------------------------------------------------------------
-- State transitions
-- ---------------------------------------------------------------------

function DiceChessWidget:placeSetupPiece(row, col)
    local ptype = self.phase == "setup_king" and "K" or self.setup_pending_piece
    self.board[row][col] = { color = self.setup_turn, type = ptype, moved = false }

    if self.phase == "setup_king" then
        if self.setup_turn == Rules.WHITE then
            self.setup_turn = Rules.BLACK
        else
            self.phase = "setup_piece"
            self.setup_turn = Rules.WHITE
        end
    else
        self.piece_pool[self.setup_turn][ptype] = self.piece_pool[self.setup_turn][ptype] - 1
        self.setup_placed[self.setup_turn] = self.setup_placed[self.setup_turn] + 1
        self.setup_pending_piece = nil
        self.setup_turn = Rules.opponent(self.setup_turn)
        if self.setup_placed[Rules.WHITE] >= Rules.COLS - 1 and self.setup_placed[Rules.BLACK] >= Rules.COLS - 1 then
            self.phase = "playing"
            self.current_player = Rules.WHITE
        end
    end
    self:render()
end

function DiceChessWidget:choosePendingPiece(ptype)
    self.setup_pending_piece = ptype
    self:render()
end

function DiceChessWidget:rollDice()
    local col = Rules.rollDie()
    local movable = Rules.movablePiecesInColumn(self.board, self.current_player, col, self.last_double_step)
    self.selected = nil
    if #movable == 0 then
        local forfeited_color = self.current_player
        self.status_note = string.format(_("%s forfeits (col %d)"), colorName(forfeited_color), col)
        self.current_player = Rules.opponent(self.current_player)
        self.dice_value = nil
        self.movable = nil
    else
        self.status_note = nil
        self.dice_value = col
        self.movable = movable
    end
    self:render()
end

function DiceChessWidget:selectPiece(mp)
    self.selected = mp
    self:render()
end

function DiceChessWidget:deselect()
    self.selected = nil
    self:render()
end

function DiceChessWidget:makeMove(move)
    if move.is_promotion then
        self.awaiting_promotion_move = move
        self:render()
        return
    end
    self:commitMove(move)
end

function DiceChessWidget:choosePromotion(ptype)
    local move = self.awaiting_promotion_move
    self:commitMove(move, ptype)
end

function DiceChessWidget:commitMove(move, promotion_type)
    local captured, moved_piece, new_lds = Rules.applyMove(self.board, move, promotion_type)
    self.last_double_step = new_lds
    self.selected = nil
    self.dice_value = nil
    self.movable = nil
    self.awaiting_promotion_move = nil
    self.status_note = nil
    if captured and captured.type == "K" then
        self.phase = "gameover"
        self.winner = moved_piece.color
    else
        self.current_player = Rules.opponent(self.current_player)
    end
    self:render(true)
end

function DiceChessWidget:onClose()
    UIManager:close(self)
    return true
end

function DiceChessWidget:onCloseWidget()
    UIManager:setDirty(nil, "full")
end

-- ---------------------------------------------------------------------
-- Board interaction helpers
-- ---------------------------------------------------------------------

function DiceChessWidget:cellCallback(row, col)
    if self.phase == "setup_king" or self.phase == "setup_piece" then
        if self.board[row][col] then return nil end
        if row ~= Rules.backRow(self.setup_turn) then return nil end
        if self.phase == "setup_piece" and not self.setup_pending_piece then return nil end
        return function() self:placeSetupPiece(row, col) end
    elseif self.phase == "playing" and not self.awaiting_promotion_move then
        if self.selected then
            if row == self.selected.row and col == self.selected.col then
                return function() self:deselect() end
            end
            for _, m in ipairs(self.selected.moves) do
                if m.to_row == row and m.to_col == col then
                    return function() self:makeMove(m) end
                end
            end
            return nil
        elseif self.movable then
            for _, mp in ipairs(self.movable) do
                if mp.row == row and mp.col == col then
                    return function() self:selectPiece(mp) end
                end
            end
            return nil
        end
    end
    return nil
end

function DiceChessWidget:cellBackground(row, col)
    local base = ((row + col) % 2 == 0) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_GRAY_E

    if self.phase == "setup_king" or self.phase == "setup_piece" then
        local eligible = not self.board[row][col] and row == Rules.backRow(self.setup_turn)
            and (self.phase == "setup_king" or self.setup_pending_piece)
        return eligible and Blitbuffer.COLOR_LIGHT_GRAY or base
    elseif self.phase == "playing" then
        if self.selected then
            if self.selected.row == row and self.selected.col == col then
                return Blitbuffer.COLOR_GRAY_9
            end
            for _, m in ipairs(self.selected.moves) do
                if m.to_row == row and m.to_col == col then
                    return Blitbuffer.COLOR_LIGHT_GRAY
                end
            end
        elseif self.movable then
            for _, mp in ipairs(self.movable) do
                if mp.row == row and mp.col == col then
                    return Blitbuffer.COLOR_GRAY_D
                end
            end
        end
    end
    return base
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

function DiceChessWidget:statusText()
    if self.phase == "setup_king" then
        return string.format(_("%s: place your King"), colorName(self.setup_turn))
    elseif self.phase == "setup_piece" then
        if self.setup_pending_piece then
            local label = self.setup_pending_piece
            for _, c in ipairs(PIECE_CHOICES) do
                if c.type == self.setup_pending_piece then label = c.text end
            end
            return string.format(_("%s: place your %s"), colorName(self.setup_turn), label)
        end
        return string.format(_("%s: choose a piece"), colorName(self.setup_turn))
    elseif self.phase == "playing" then
        if self.awaiting_promotion_move then
            return _("Promote your pawn")
        end
        if self.status_note then
            return self.status_note
        end
        if self.selected then
            return _("Tap a square to move")
        elseif self.dice_value then
            return string.format(_("Column %d: tap a piece"), self.dice_value)
        else
            return string.format(_("%s's turn"), colorName(self.current_player))
        end
    elseif self.phase == "gameover" then
        return string.format(_("%s wins!"), colorName(self.winner))
    end
    return ""
end

function DiceChessWidget:pieceChoiceRow(on_choose, pool, flip_labels)
    local group = HorizontalGroup:new{}
    local first = true
    for _, c in ipairs(PIECE_CHOICES) do
        local count = pool and pool[c.type]
        if not pool or count > 0 then
            if not first then
                table.insert(group, HorizontalSpan:new{ width = Size.span.horizontal_default })
            end
            first = false
            local label = pool and string.format("%s (%d)", c.text, count) or c.text
            if flip_labels then label = Flip.flip(label) end
            table.insert(group, Button:new{
                text = label,
                callback = function() on_choose(c.type) end,
            })
        end
    end
    return group
end

function DiceChessWidget:buildControls(flip_labels)
    if self.phase == "setup_piece" and not self.setup_pending_piece then
        return self:pieceChoiceRow(function(ptype) self:choosePendingPiece(ptype) end, self.piece_pool[self.setup_turn], flip_labels)
    elseif self.phase == "playing" then
        if self.awaiting_promotion_move then
            return self:pieceChoiceRow(function(ptype) self:choosePromotion(ptype) end, nil, flip_labels)
        elseif not self.dice_value then
            local label = flip_labels and Flip.flip(_("Roll Dice")) or _("Roll Dice")
            return Button:new{
                text = label,
                callback = function() self:rollDice() end,
                width = Screen:scaleBySize(160),
            }
        end
    end
    return nil
end

function DiceChessWidget:buildBoard()
    local cell_size = self.layout.cell_size
    local rows_group = VerticalGroup:new{}
    for row = Rules.ROWS, 1, -1 do
        local row_group = HorizontalGroup:new{}
        for col = 1, Rules.COLS do
            local piece = self.board[row][col]
            local text = piece and GLYPH[piece.color][piece.type] or ""
            table.insert(row_group, BoardCell:new{
                text = text,
                size = cell_size,
                background = self:cellBackground(row, col),
                callback = self:cellCallback(row, col),
            })
        end
        table.insert(rows_group, row_group)
    end
    return rows_group
end

-- `flip_for_head` renders an upside-down copy (via Unicode lookalike
-- glyphs) for the player sitting at the board's far end ("the head"), so
-- both seated players can read the current status right-side up.
function DiceChessWidget:buildMessage(text, flip_for_head)
    return TextBoxWidget:new{
        text = flip_for_head and Flip.flip(text) or text,
        face = Font:getFace("cfont", MESSAGE_FONT_SIZE),
        width = self.layout.msg_width,
        height = self.layout.message_h,
        height_adjust = true,
        height_overflow_show_ellipsis = true,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
end

function DiceChessWidget:buildDiceIndicator()
    local text = self.dice_value and DIE_FACE[self.dice_value] or ""
    return CenterContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = self.layout.dice_h },
        TextWidget:new{
            text = text,
            face = Font:getFace("cfont", DICE_FONT_SIZE),
            fgcolor = Blitbuffer.COLOR_BLACK,
        },
    }
end

function DiceChessWidget:render(full_refresh)
    local vpad = self.layout.vpad
    local status = self:statusText()

    local title = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        title = _("Dice Chess"),
        with_bottom_line = true,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local message_top = self:buildMessage(status, true)
    local controls_top = self:buildControls(true)
    local controls_top_slot = controls_top or VerticalSpan:new{ width = self.layout.controls_h }
    local dice_top = self:buildDiceIndicator()
    local board = self:buildBoard()
    local dice_bottom = self:buildDiceIndicator()
    local controls_bottom = self:buildControls(false)
    local controls_bottom_slot = controls_bottom or VerticalSpan:new{ width = self.layout.controls_h }
    local message_bottom = self:buildMessage(status, false)

    local restart_button = Button:new{
        text = _("New Game"),
        callback = function() self:confirmNewGame() end,
        width = Screen:scaleBySize(140),
        text_font_size = 16,
    }

    local content = VerticalGroup:new{
        title,
        VerticalSpan:new{ width = vpad },
        message_top,
        VerticalSpan:new{ width = vpad },
        controls_top_slot,
        VerticalSpan:new{ width = vpad },
        dice_top,
        VerticalSpan:new{ width = vpad },
        board,
        VerticalSpan:new{ width = vpad },
        dice_bottom,
        VerticalSpan:new{ width = vpad },
        controls_bottom_slot,
        VerticalSpan:new{ width = vpad },
        message_bottom,
        VerticalSpan:new{ width = vpad },
        restart_button,
    }

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        content,
    }

    UIManager:setDirty(self, full_refresh and "full" or "ui")
end

return DiceChessWidget
