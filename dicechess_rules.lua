--[[--
Rules engine for Wuerfelschach (Dice Chess): a chess variant on a 6-wide,
8-tall board where a die roll each turn restricts which column a piece may
be moved from. Pure Lua, no KOReader dependencies, so it can be exercised
by a standalone interpreter as well as from the plugin UI.
]]

math.randomseed(os.time())

local COLS = 6
local ROWS = 8

local WHITE = "w"
local BLACK = "b"

local M = {
    COLS = COLS,
    ROWS = ROWS,
    WHITE = WHITE,
    BLACK = BLACK,
}

-- ---------------------------------------------------------------------
-- Board
-- ---------------------------------------------------------------------

function M.newEmptyBoard()
    local board = {}
    for row = 1, ROWS do
        board[row] = {}
        for col = 1, COLS do
            board[row][col] = false
        end
    end
    return board
end

-- Creates a board with the two pawn rows filled in (row 2 for White, row 7
-- for Black) and both back rows (1 and 8) left empty for the setup phase.
function M.newSetupBoard()
    local board = M.newEmptyBoard()
    for col = 1, COLS do
        board[2][col] = { color = WHITE, type = "P", moved = false }
        board[7][col] = { color = BLACK, type = "P", moved = false }
    end
    return board
end

function M.inBounds(row, col)
    return row >= 1 and row <= ROWS and col >= 1 and col <= COLS
end

function M.backRow(color)
    return color == WHITE and 1 or ROWS
end

function M.pawnRow(color)
    return color == WHITE and 2 or ROWS - 1
end

function M.forwardDir(color)
    return color == WHITE and 1 or -1
end

function M.promotionRow(color)
    return color == WHITE and ROWS or 1
end

function M.opponent(color)
    return color == WHITE and BLACK or WHITE
end

function M.cloneBoard(board)
    local out = {}
    for row = 1, ROWS do
        out[row] = {}
        for col = 1, COLS do
            local p = board[row][col]
            if p then
                out[row][col] = { color = p.color, type = p.type, moved = p.moved }
            else
                out[row][col] = false
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------
-- Move generation
-- A move is: { from_row, from_col, to_row, to_col, capture, en_passant,
--              is_promotion, is_double_step }
-- ---------------------------------------------------------------------

local SLIDE_DIRS = {
    R = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } },
    B = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } },
    Q = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } },
}

local KNIGHT_OFFSETS = {
    { 2, 1 }, { 2, -1 }, { -2, 1 }, { -2, -1 },
    { 1, 2 }, { 1, -2 }, { -1, 2 }, { -1, -2 },
}

local KING_OFFSETS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 },
}

local function addIfLegal(moves, board, color, from_row, from_col, to_row, to_col)
    if not M.inBounds(to_row, to_col) then
        return
    end
    local target = board[to_row][to_col]
    if target and target.color == color then
        return
    end
    moves[#moves + 1] = {
        from_row = from_row, from_col = from_col,
        to_row = to_row, to_col = to_col,
        capture = target ~= false,
    }
end

local function slideMoves(moves, board, color, row, col, dirs)
    for _, d in ipairs(dirs) do
        local r, c = row + d[1], col + d[2]
        while M.inBounds(r, c) do
            local target = board[r][c]
            if not target then
                addIfLegal(moves, board, color, row, col, r, c)
            elseif target.color ~= color then
                addIfLegal(moves, board, color, row, col, r, c)
                break
            else
                break
            end
            r, c = r + d[1], c + d[2]
        end
    end
end

local function pawnMoves(moves, board, color, row, col, last_double_step)
    local dir = M.forwardDir(color)
    local start_row = row + dir

    -- Forward single step (only onto an empty square).
    if M.inBounds(start_row, col) and not board[start_row][col] then
        local promo = start_row == M.promotionRow(color)
        moves[#moves + 1] = {
            from_row = row, from_col = col, to_row = start_row, to_col = col,
            capture = false, is_promotion = promo,
        }
        -- Double step from the pawn's original row.
        local double_row = row + 2 * dir
        if row == M.pawnRow(color) and M.inBounds(double_row, col) and not board[double_row][col] then
            moves[#moves + 1] = {
                from_row = row, from_col = col, to_row = double_row, to_col = col,
                capture = false, is_double_step = true,
            }
        end
    end

    -- Diagonal captures (including en passant).
    for _, dc in ipairs({ -1, 1 }) do
        local tr, tc = row + dir, col + dc
        if M.inBounds(tr, tc) then
            local target = board[tr][tc]
            if target and target.color ~= color then
                moves[#moves + 1] = {
                    from_row = row, from_col = col, to_row = tr, to_col = tc,
                    capture = true, is_promotion = tr == M.promotionRow(color),
                }
            elseif not target and last_double_step
                and last_double_step.row == row and last_double_step.col == tc
                and last_double_step.color ~= color then
                moves[#moves + 1] = {
                    from_row = row, from_col = col, to_row = tr, to_col = tc,
                    capture = true, en_passant = true,
                }
            end
        end
    end
end

-- Generates all pseudo-legal moves for the piece at (row, col). There is no
-- concept of "moving into check" in this variant: capturing the king simply
-- ends the game, so every move that follows the piece's movement pattern is
-- legal.
function M.movesForPiece(board, row, col, last_double_step)
    local piece = board[row][col]
    if not piece then
        return {}
    end
    local moves = {}
    local t = piece.type
    if t == "P" then
        pawnMoves(moves, board, piece.color, row, col, last_double_step)
    elseif t == "N" then
        for _, o in ipairs(KNIGHT_OFFSETS) do
            addIfLegal(moves, board, piece.color, row, col, row + o[1], col + o[2])
        end
    elseif t == "K" then
        for _, o in ipairs(KING_OFFSETS) do
            addIfLegal(moves, board, piece.color, row, col, row + o[1], col + o[2])
        end
    else
        slideMoves(moves, board, piece.color, row, col, SLIDE_DIRS[t])
    end
    return moves
end

-- Returns { {row=, col=, moves={...}}, ... } for every piece of `color`
-- sitting in `column` that has at least one legal move.
function M.movablePiecesInColumn(board, color, column, last_double_step)
    local out = {}
    for row = 1, ROWS do
        local piece = board[row][column]
        if piece and piece.color == color then
            local moves = M.movesForPiece(board, row, column, last_double_step)
            if #moves > 0 then
                out[#out + 1] = { row = row, col = column, moves = moves }
            end
        end
    end
    return out
end

function M.rollDie()
    return math.random(1, COLS)
end

-- Applies `move` to `board` in place. `promotion_type` (one of Q/R/B/N) is
-- required when move.is_promotion is true. Returns the captured piece (or
-- false), and the piece that just moved (with its new state).
function M.applyMove(board, move, promotion_type)
    local piece = board[move.from_row][move.from_col]
    local captured = board[move.to_row][move.to_col]

    if move.en_passant then
        captured = board[move.from_row][move.to_col]
        board[move.from_row][move.to_col] = false
    end

    board[move.from_row][move.from_col] = false
    piece.moved = true
    if move.is_promotion then
        piece.type = promotion_type or "Q"
    end
    board[move.to_row][move.to_col] = piece

    local new_last_double_step = false
    if move.is_double_step then
        new_last_double_step = { row = move.to_row, col = move.to_col, color = piece.color }
    end

    return captured, piece, new_last_double_step
end

return M
