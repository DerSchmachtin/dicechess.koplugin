# dicechess.koplugin

A [KOReader](https://github.com/koreader/koreader) plugin implementing **Wuerfelschach** (Dice Chess): a two-player, pass-and-play chess variant on a 6-wide, 8-tall board, designed to be playable on a shared e-reader like a Kindle Paperwhite.

Each turn a die decides which column you may move from, so a good plan can be ruined by a bad roll, and a lost position can still be saved by a lucky one. There is no computer opponent: two people sit across from each other with the device between them.

## Rules

- **Board**: 6 columns × 8 rows.
- **Setup**: players alternate placing pieces on their own back row, in the open (visible to both). Each player places their King first, then drafts the remaining 5 squares from a real chess set's piece pool: 1 Queen, 2 Rooks, 2 Bishops, 2 Knights (2 pieces are left unused). Pawns fill the row in front automatically.
- **Turns**: roll a single six-sided die. The result is a column number (1–6). You may only move one of your own pieces that is currently sitting in that column, using normal chess movement (including en passant and promotion to any piece). If none of your pieces in that column has a legal move, your turn is forfeited.
- **Winning**: there is no check or checkmate. Capture the opposing King to win.

## Playing

Open it from **Tools → More tools → Dice Chess**.

1. **Draft**: the status line says whose turn it is to place ("White: place your King", then "choose a piece"). Pick a piece and tap a free square on your back row.
2. **Roll**: tap **Roll Dice**. The status line shows the column, e.g. "Column 4: tap a piece".
3. **Move**: tap one of your pieces in that column, then tap the square to move it to. If nothing in that column can move, the turn passes and the status line notes the forfeit.
4. **Promotion**: a pawn reaching the far row gets a choice of Queen, Rook, Bishop or Knight.

**New Game** starts over after a confirmation. The game is not saved when you close the plugin.

Because both players share one device, the status text is shown twice (normal near White's edge, upside-down near Black's edge) and the Roll Dice and piece-choice controls are duplicated on both sides, so each player can read and act from their own seat.

## Install

1. Download this repository (**Code → Download ZIP**) or clone it.
2. Make sure the folder is named exactly `dicechess.koplugin` (the ZIP unpacks as `dicechess.koplugin-main`, so rename it).
3. Copy the folder into KOReader's `plugins/` directory on your device:
   - Kindle: `koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Android: `koreader/plugins/`
4. Restart KOReader.

## Structure

- `dicechess_rules.lua`: board representation and move generation, no KOReader dependency.
- `dicechess_fliptext.lua`: renders an upside-down-readable copy of a status string for the player on the far side of the board.
- `dicechess_widget.lua`: the full-screen UI: setup draft, board, dice roll, move selection, promotion.
- `main.lua` / `_meta.lua`: plugin registration.

## License

[AGPL-3.0](LICENSE), the same license as KOReader.
