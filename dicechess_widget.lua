--[[--
Full-screen UI for Wuerfelschach (Dice Chess): handles both the alternating
setup phase (choose King square, then draft the rest of the back row from a
real chess set's piece pool) and the main game (roll a die, move a piece
from the rolled column, capture the enemy King to win). White sits at the
bottom edge, Black at the top edge. Each player has a status line at their
own edge (Black's is rendered upside-down), and the action buttons only
appear at the edge of the player whose turn it is. An optional chess clock
shows each player's remaining time beside the board, at their own end.
Board logic lives in dicechess_rules; this module is presentation and input.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
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
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen

local GLYPH = {
    [Rules.WHITE] = { K = "♔", Q = "♕", R = "♖", B = "♗", N = "♘", P = "♙" },
    [Rules.BLACK] = { K = "♚", Q = "♛", R = "♜", B = "♝", N = "♞", P = "♟" },
}

-- Die faces double as column labels: unlike digits they read the same from
-- both ends of the board, so neither player has to count columns.
local DIE_FACE = { "⚀", "⚁", "⚂", "⚃", "⚄", "⚅" }

local TARGET_DOT = "•"

local PIECE_CHOICES = {
    { type = "Q", text = _("Queen") },
    { type = "R", text = _("Rook") },
    { type = "B", text = _("Bishop") },
    { type = "N", text = _("Knight") },
}

local STARTING_POOL = { Q = 1, R = 2, B = 2, N = 2 }

local MESSAGE_FONT_SIZE = 17
local DICE_FONT_SIZE = 26
local CLOCK_FONT_SIZE = 22

-- Minutes per player offered in the menu; 0 switches the clock off.
local CLOCK_CHOICES = { 0, 5, 10, 15, 30 }
local CLOCK_SETTING = "dicechess_clock_minutes"

-- Everything that makes up a game in progress. Copied out when the widget
-- closes and back in when it is reopened, so closing does not lose the game.
local STATE_KEYS = {
    "board", "last_double_step", "phase", "setup_turn", "setup_pending_piece",
    "setup_placed", "piece_pool", "current_player", "dice_value", "movable",
    "selected", "forfeit", "awaiting_promotion_move", "winner", "started",
    "clock_left", "clock_started", "timed_out",
}
local saved_state = nil

local function colorName(color)
    return color == Rules.WHITE and _("White") or _("Black")
end

local function pieceLabel(ptype)
    for _, c in ipairs(PIECE_CHOICES) do
        if c.type == ptype then return c.text end
    end
    return ptype
end

local function formatClock(seconds)
    local total = math.ceil(seconds)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

-- One player's clock: a fixed-size box showing the remaining time. Black's
-- is painted rotated by 180 degrees, as there are no upside-down lookalike
-- glyphs for digits. A thick border marks the clock that is running.
local ClockBox = WidgetContainer:extend{
    text = "",
    width = 0,
    height = 0,
    rotated = false,
    running = false,
}

function ClockBox:init()
    local border = self.running and Screen:scaleBySize(3) or Size.border.thin
    self.text_widget = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", CLOCK_FONT_SIZE),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        margin = 0,
        bordersize = border,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.width - 2 * border, h = self.height - 2 * border },
            self.text_widget,
        },
    }
end

function ClockBox:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ClockBox:setText(text)
    self.text_widget:setText(text)
end

function ClockBox:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if not self.rotated then
        self[1]:paintTo(bb, x, y)
        return
    end
    local upright = Blitbuffer.new(self.width, self.height, bb:getType())
    self[1]:paintTo(upright, 0, 0)
    local turned = upright:rotatedCopy(180)
    bb:blitFrom(turned, x, y, 0, 0, self.width, self.height)
    upright:free()
    turned:free()
end

-- A minimal tappable board square: a bordered box with a centered glyph.
local BoardCell = InputContainer:extend{
    text = "",
    background = nil,
    bordersize = nil,
    inverted = false,
    size = 0,
    callback = nil,
}

function BoardCell:init()
    local border = self.bordersize or Size.border.thin
    local inner = self.size - 2 * border
    local scale = Screen:scaleBySize(1)
    local font_size = math.floor((self.size * 0.7) / scale)
    if font_size < 6 then font_size = 6 end

    self.frame = FrameContainer:new{
        width = self.size,
        height = self.size,
        margin = 0,
        bordersize = border,
        color = Blitbuffer.COLOR_BLACK,
        background = self.inverted and Blitbuffer.COLOR_BLACK or self.background or Blitbuffer.COLOR_WHITE,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = inner },
            TextWidget:new{
                text = self.text,
                face = Font:getFace("cfont", font_size),
                fgcolor = self.inverted and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
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
    self.tick = function() self:onTick() end
    if saved_state then
        for _, key in ipairs(STATE_KEYS) do
            self[key] = saved_state[key]
        end
        self:computeLayout()
        if self.clock_started then
            self:startClock()
        end
        self:render("full")
    else
        -- The layout depends on whether there is a clock to make room for.
        self:resetClock()
        self:computeLayout()
        self:newGame()
    end
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
    title:free()

    local msg_width = self.dimen.w - 2 * Size.padding.large
    local longest_message = string.format(_("%s rolled %s, no move."), colorName(Rules.BLACK), DIE_FACE[6])
        .. " " .. string.format(_("Waiting for %s"), colorName(Rules.WHITE))
    local sample_message = TextBoxWidget:new{
        text = longest_message,
        face = Font:getFace("cfont", MESSAGE_FONT_SIZE),
        width = msg_width,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local message_h = sample_message:getSize().h
    sample_message:free()

    local dice_sample = TextWidget:new{
        text = DIE_FACE[6],
        face = Font:getFace("cfont", DICE_FONT_SIZE),
    }
    local label_h = dice_sample:getSize().h
    dice_sample:free()

    local sample_button = Button:new{ text = _("Roll Dice"), width = Screen:scaleBySize(160) }
    local controls_h = sample_button:getSize().h
    sample_button:free()

    -- Bands, top to bottom: title, message(top), controls(top), column
    -- labels, board, column labels, controls(bottom), message(bottom).
    -- The label strips sit flush against the board, which leaves 5 gaps
    -- (the last one below the bottom message). The top message/controls
    -- belong to Black, the bottom ones to White.
    local used_h = title_h + message_h * 2 + controls_h * 2 + label_h * 2 + vpad * 5

    local clock_sample = TextWidget:new{
        text = "00:00",
        face = Font:getFace("cfont", CLOCK_FONT_SIZE),
    }
    local clock_size = clock_sample:getSize()
    clock_sample:free()
    local clock_w = clock_size.w + 2 * Size.padding.large
    local clock_h = clock_size.h + 2 * Size.padding.default
    local clock_gap = Size.padding.large

    local avail_w = self.dimen.w - 2 * Size.margin.default
    if self.clock_left then
        -- One clock on either side of the board keeps the board centered.
        avail_w = avail_w - 2 * (clock_w + clock_gap)
    end
    local avail_h = self.dimen.h - used_h
    if avail_h < Rules.ROWS then avail_h = Rules.ROWS end

    local cell_size = math.floor(math.min(avail_w / Rules.COLS, avail_h / Rules.ROWS))
    if cell_size < 1 then cell_size = 1 end

    self.layout = {
        vpad = vpad,
        msg_width = msg_width,
        message_h = message_h,
        label_h = label_h,
        controls_h = controls_h,
        clock_w = clock_w,
        clock_h = clock_h,
        clock_gap = clock_gap,
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
    self.forfeit = nil
    self.awaiting_promotion_move = nil
    self.winner = nil
    self.timed_out = nil
    self.started = false
    self:resetClock()
    self:render("full")
end

local function clockChoiceText(minutes)
    if minutes == 0 then
        return _("Off")
    end
    return string.format(_("%d min"), minutes)
end

function DiceChessWidget:showMenu()
    local dialog
    dialog = ButtonDialog:new{
        buttons = {
            {
                {
                    text = _("New Game"),
                    callback = function()
                        UIManager:close(dialog)
                        self:confirmNewGame()
                    end,
                },
            },
            {
                {
                    text = string.format(_("Chess clock: %s"),
                        clockChoiceText(G_reader_settings:readSetting(CLOCK_SETTING, 0))),
                    callback = function()
                        UIManager:close(dialog)
                        self:showClockMenu()
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function DiceChessWidget:showClockMenu()
    local current = G_reader_settings:readSetting(CLOCK_SETTING, 0)
    local dialog
    local buttons = {}
    for _, minutes in ipairs(CLOCK_CHOICES) do
        local text = clockChoiceText(minutes)
        if minutes == current then
            text = text .. "  ✓"
        end
        table.insert(buttons, {
            {
                text = text,
                callback = function()
                    UIManager:close(dialog)
                    self:setClockMinutes(minutes)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = _("Time per player. Choosing one resets both clocks."),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function DiceChessWidget:confirmNewGame()
    if not self.started or self.phase == "gameover" then
        self:newGame()
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Start a new game? The current game will be lost."),
        ok_text = _("New game"),
        ok_callback = function() self:newGame() end,
    })
end

-- The player who has to act next, or nil once the game is over.
function DiceChessWidget:activeColor()
    if self.phase == "gameover" then
        return nil
    elseif self.phase == "playing" then
        return self.current_player
    end
    return self.setup_turn
end

-- ---------------------------------------------------------------------
-- Chess clock
-- `clock_left` holds each player's banked seconds (nil when the clock is
-- off). While a turn is running, `turn_start` is the moment it began and
-- the time used since then has not been subtracted from the bank yet.
-- ---------------------------------------------------------------------

function DiceChessWidget:resetClock()
    UIManager:unschedule(self.tick)
    local minutes = G_reader_settings:readSetting(CLOCK_SETTING, 0)
    if minutes > 0 then
        self.clock_left = { [Rules.WHITE] = minutes * 60, [Rules.BLACK] = minutes * 60 }
    else
        self.clock_left = nil
    end
    self.clock_started = false
    self.turn_start = nil
end

function DiceChessWidget:setClockMinutes(minutes)
    G_reader_settings:saveSetting(CLOCK_SETTING, minutes)
    self:resetClock()
    self:computeLayout()
    -- Mid-turn the new clock starts right away, otherwise on the next roll.
    if self.phase == "playing" and self.dice_value then
        self:startClock()
    end
    self:render("full")
end

function DiceChessWidget:remaining(color)
    local left = self.clock_left[color]
    if self.turn_start and color == self.current_player then
        left = left - time.to_number(time.now() - self.turn_start)
    end
    return math.max(left, 0)
end

-- Starts counting down for the current player.
function DiceChessWidget:startClock()
    if not self.clock_left or self.phase ~= "playing" then return end
    self.clock_started = true
    self.turn_start = time.now()
    self:scheduleTick()
end

-- Stops counting and books the time used in the running turn.
function DiceChessWidget:bankClock()
    UIManager:unschedule(self.tick)
    if self.clock_left and self.turn_start then
        self.clock_left[self.current_player] = self:remaining(self.current_player)
    end
    self.turn_start = nil
end

-- Wakes up when the displayed second of the running clock changes.
function DiceChessWidget:scheduleTick()
    UIManager:unschedule(self.tick)
    if not self.turn_start then return end
    local left = self:remaining(self.current_player)
    local delay = left - math.floor(left)
    if delay < 0.05 and left >= 1 then
        delay = delay + 1
    end
    UIManager:scheduleIn(delay, self.tick)
end

function DiceChessWidget:onTick()
    if not self.turn_start or self.phase ~= "playing" then return end
    local color = self.current_player
    local left = self:remaining(color)
    if left <= 0 then
        self:bankClock()
        self.phase = "gameover"
        self.winner = Rules.opponent(color)
        self.timed_out = color
        self.selected = nil
        self.dice_value = nil
        self.movable = nil
        self.awaiting_promotion_move = nil
        self.forfeit = nil
        self:render("full")
        return
    end
    -- Only the running clock's own box is refreshed, with the fast
    -- black-and-white mode, to keep e-ink flicker to a minimum.
    local box = self.clock_boxes and self.clock_boxes[color]
    if box then
        box:setText(formatClock(left))
        UIManager:setDirty(self, function()
            return "fast", box.dimen
        end)
    end
    self:scheduleTick()
end

-- ---------------------------------------------------------------------
-- State transitions
-- ---------------------------------------------------------------------

function DiceChessWidget:placeSetupPiece(row, col)
    local ptype = self.phase == "setup_king" and "K" or self.setup_pending_piece
    self.board[row][col] = { color = self.setup_turn, type = ptype, moved = false }
    self.started = true

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
    if not self.clock_started then
        -- The very first roll of the game starts White's clock.
        self:startClock()
    end
    if #movable == 0 then
        self.forfeit = { color = self.current_player, col = col }
        self:bankClock()
        self.current_player = Rules.opponent(self.current_player)
        self:startClock()
        self.dice_value = nil
        self.movable = nil
        -- A forfeited turn still uses up the opponent's en passant chance.
        self.last_double_step = false
    else
        self.forfeit = nil
        self.dice_value = col
        self.movable = movable
        if #movable == 1 then
            self.selected = movable[1]
        end
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
    self.forfeit = nil
    self:bankClock()
    if captured and captured.type == "K" then
        self.phase = "gameover"
        self.winner = moved_piece.color
        self:render("full")
    else
        self.current_player = Rules.opponent(self.current_player)
        self:startClock()
        -- "partial" lets KOReader flash on its own full-refresh schedule
        -- instead of flashing the whole screen on every single move.
        self:render("partial")
    end
end

function DiceChessWidget:onClose()
    UIManager:close(self)
    return true
end

function DiceChessWidget:onCloseWidget()
    -- The clock is paused while the game is closed.
    self:bankClock()
    saved_state = {}
    for _, key in ipairs(STATE_KEYS) do
        saved_state[key] = self[key]
    end
    UIManager:setDirty(nil, "full")
end

-- ---------------------------------------------------------------------
-- Board interaction helpers
-- ---------------------------------------------------------------------

function DiceChessWidget:movableAt(row, col)
    if not self.movable then return nil end
    for _, mp in ipairs(self.movable) do
        if mp.row == row and mp.col == col then
            return mp
        end
    end
    return nil
end

function DiceChessWidget:selectedMoveTo(row, col)
    if not self.selected then return nil end
    for _, m in ipairs(self.selected.moves) do
        if m.to_row == row and m.to_col == col then
            return m
        end
    end
    return nil
end

function DiceChessWidget:isSetupSquare(row, col)
    if self.phase ~= "setup_king" and self.phase ~= "setup_piece" then return false end
    if self.board[row][col] then return false end
    if row ~= Rules.backRow(self.setup_turn) then return false end
    return self.phase == "setup_king" or self.setup_pending_piece ~= nil
end

function DiceChessWidget:cellCallback(row, col)
    if self:isSetupSquare(row, col) then
        return function() self:placeSetupPiece(row, col) end
    elseif self.phase == "playing" and not self.awaiting_promotion_move then
        if self.selected and row == self.selected.row and col == self.selected.col then
            return function() self:deselect() end
        end
        local move = self:selectedMoveTo(row, col)
        if move then
            return function() self:makeMove(move) end
        end
        -- Also reachable while another piece is selected, so the player can
        -- switch pieces with one tap.
        local mp = self:movableAt(row, col)
        if mp then
            return function() self:selectPiece(mp) end
        end
    end
    return nil
end

-- Returns the background, border size, inversion flag and glyph for a
-- square. The markers are deliberately coarse (thick border, inverted
-- square, dot) because neighbouring gray levels are hard to tell apart on
-- e-ink.
function DiceChessWidget:cellAppearance(row, col)
    local piece = self.board[row][col]
    local look = {
        background = ((row + col) % 2 == 0) and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_GRAY_E,
        text = piece and GLYPH[piece.color][piece.type] or "",
    }
    local thick = Screen:scaleBySize(3)

    if self:isSetupSquare(row, col) then
        look.background = Blitbuffer.COLOR_LIGHT_GRAY
    elseif self.phase == "playing" then
        if self.selected and self.selected.row == row and self.selected.col == col then
            look.inverted = true
        elseif self:selectedMoveTo(row, col) then
            if piece then
                look.bordersize = thick
                look.background = Blitbuffer.COLOR_LIGHT_GRAY
            else
                look.text = TARGET_DOT
            end
        elseif self:movableAt(row, col) then
            look.bordersize = thick
        end
    end
    return look
end

-- ---------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------

-- Status line for the player sitting on `seat`'s side. The active player is
-- told what to do, the other one whom they are waiting for.
function DiceChessWidget:statusText(seat)
    if self.phase == "gameover" then
        if self.timed_out then
            return string.format(_("%s wins on time!"), colorName(self.winner))
        end
        return string.format(_("%s wins!"), colorName(self.winner))
    end

    local active = self:activeColor()
    local name = colorName(active)
    local text
    if seat ~= active then
        text = string.format(_("Waiting for %s"), name)
    elseif self.phase == "setup_king" then
        text = string.format(_("%s: place your King"), name)
    elseif self.phase == "setup_piece" then
        if self.setup_pending_piece then
            text = string.format(_("%s: place your %s"), name, pieceLabel(self.setup_pending_piece))
        else
            text = string.format(_("%s: choose a piece"), name)
        end
    elseif self.awaiting_promotion_move then
        text = string.format(_("%s: promote your pawn"), name)
    elseif self.selected then
        text = string.format(_("%s: tap a square to move"), name)
    elseif self.dice_value then
        text = string.format(_("%s: column %s, tap a piece"), name, DIE_FACE[self.dice_value])
    else
        text = string.format(_("%s: roll the dice"), name)
    end

    if self.forfeit then
        text = string.format(_("%s rolled %s, no move."), colorName(self.forfeit.color), DIE_FACE[self.forfeit.col])
            .. " " .. text
    end
    return text
end

-- `opts.counts` limits the row to piece types still available and shows
-- how many are left (as repeated glyphs, which need no upside-down digits);
-- `opts.chosen` marks the currently picked type; `opts.flip` renders the
-- row for the player at the top edge.
function DiceChessWidget:pieceChoiceRow(on_choose, opts)
    local buttons = {}
    for _, c in ipairs(PIECE_CHOICES) do
        local count = opts.counts and opts.counts[c.type] or 1
        if count > 0 then
            local label = c.text .. " " .. string.rep(GLYPH[opts.color][c.type], count)
            if opts.flip then label = Flip.flip(label) end
            local button = Button:new{
                text = label,
                preselect = opts.chosen == c.type,
                callback = function() on_choose(c.type) end,
            }
            -- Mirror the order as well, so both players see the same row.
            if opts.flip then
                table.insert(buttons, 1, button)
            else
                table.insert(buttons, button)
            end
        end
    end

    local group = HorizontalGroup:new{}
    for i, button in ipairs(buttons) do
        if i > 1 then
            table.insert(group, HorizontalSpan:new{ width = Size.span.horizontal_default })
        end
        table.insert(group, button)
    end
    return group
end

-- Action buttons for `seat`'s edge of the board. Only the player whose turn
-- it is gets any, which both shows whose turn it is and stops the other
-- player from acting for them.
function DiceChessWidget:buildControls(seat)
    if seat ~= self:activeColor() then return nil end
    local flip = seat == Rules.BLACK

    if self.phase == "setup_piece" then
        return self:pieceChoiceRow(function(ptype) self:choosePendingPiece(ptype) end, {
            counts = self.piece_pool[seat],
            chosen = self.setup_pending_piece,
            color = seat,
            flip = flip,
        })
    elseif self.phase == "playing" then
        if self.awaiting_promotion_move then
            return self:pieceChoiceRow(function(ptype) self:choosePromotion(ptype) end, {
                color = seat,
                flip = flip,
            })
        elseif not self.dice_value then
            local label = flip and Flip.flip(_("Roll Dice")) or _("Roll Dice")
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
            local look = self:cellAppearance(row, col)
            table.insert(row_group, BoardCell:new{
                text = look.text,
                size = cell_size,
                background = look.background,
                bordersize = look.bordersize,
                inverted = look.inverted,
                callback = self:cellCallback(row, col),
            })
        end
        table.insert(rows_group, row_group)
    end
    return rows_group
end

-- A strip of die faces naming the columns. The rolled column is inverted;
-- a roll that was just forfeited stays visible in gray until the next roll.
function DiceChessWidget:buildColumnLabels()
    local group = HorizontalGroup:new{}
    for col = 1, Rules.COLS do
        local rolled = self.phase == "playing" and self.dice_value == col
        local forfeited = self.phase == "playing" and self.forfeit and self.forfeit.col == col
        local background = Blitbuffer.COLOR_WHITE
        if rolled then
            background = Blitbuffer.COLOR_BLACK
        elseif forfeited then
            background = Blitbuffer.COLOR_LIGHT_GRAY
        end
        table.insert(group, FrameContainer:new{
            width = self.layout.cell_size,
            height = self.layout.label_h,
            margin = 0,
            bordersize = 0,
            padding = 0,
            background = background,
            CenterContainer:new{
                dimen = Geom:new{ w = self.layout.cell_size, h = self.layout.label_h },
                TextWidget:new{
                    text = DIE_FACE[col],
                    face = Font:getFace("cfont", DICE_FONT_SIZE),
                    fgcolor = rolled and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                },
            },
        })
    end
    return group
end

function DiceChessWidget:buildClock(color)
    local box = ClockBox:new{
        text = formatClock(self:remaining(color)),
        width = self.layout.clock_w,
        height = self.layout.clock_h,
        rotated = color == Rules.BLACK,
        running = self.turn_start ~= nil and color == self.current_player,
    }
    self.clock_boxes[color] = box
    return box
end

-- The board with its column labels and, if the clock is on, one clock on
-- either side: Black's at the top left, White's at the bottom right, which
-- is to the right of the board from each player's own seat.
function DiceChessWidget:buildBoardArea()
    local board = VerticalGroup:new{
        self:buildColumnLabels(),
        self:buildBoard(),
        self:buildColumnLabels(),
    }
    self.clock_boxes = {}
    if not self.clock_left then
        return board
    end
    local side = Geom:new{ w = self.layout.clock_w, h = board:getSize().h }
    return HorizontalGroup:new{
        TopContainer:new{ dimen = side:copy(), self:buildClock(Rules.BLACK) },
        HorizontalSpan:new{ width = self.layout.clock_gap },
        board,
        HorizontalSpan:new{ width = self.layout.clock_gap },
        BottomContainer:new{ dimen = side:copy(), self:buildClock(Rules.WHITE) },
    }
end

-- `flip_for_head` renders an upside-down copy (via Unicode lookalike
-- glyphs) for the player sitting at the board's far end ("the head"), so
-- both seated players can read their status right-side up.
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

-- `refresh` is the UIManager refresh type, "ui" unless given.
function DiceChessWidget:render(refresh)
    local vpad = self.layout.vpad

    local title = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        title = _("Dice Chess"),
        with_bottom_line = true,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local message_top = self:buildMessage(self:statusText(Rules.BLACK), true)
    local controls_top = self:buildControls(Rules.BLACK)
        or VerticalSpan:new{ width = self.layout.controls_h }
    local controls_bottom = self:buildControls(Rules.WHITE)
        or VerticalSpan:new{ width = self.layout.controls_h }
    local message_bottom = self:buildMessage(self:statusText(Rules.WHITE), false)

    local content = VerticalGroup:new{
        title,
        VerticalSpan:new{ width = vpad },
        message_top,
        VerticalSpan:new{ width = vpad },
        controls_top,
        VerticalSpan:new{ width = vpad },
        self:buildBoardArea(),
        VerticalSpan:new{ width = vpad },
        controls_bottom,
        VerticalSpan:new{ width = vpad },
        message_bottom,
    }

    -- The old tree is freed on the next tick, not right away: render() is
    -- usually running inside a tap handler of one of the old tree's own
    -- buttons, which still touches itself after its callback returns.
    local old = self[1]
    if old then
        UIManager:nextTick(function() old:free() end)
    end

    self[1] = FrameContainer:new{
        width = self.dimen.w,
        height = self.dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        content,
    }

    UIManager:setDirty(self, refresh or "ui")
end

return DiceChessWidget
