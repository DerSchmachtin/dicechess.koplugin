local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local DiceChess = WidgetContainer:extend{
    name = "dicechess",
    is_doc_only = false,
}

function DiceChess:init()
    self.ui.menu:registerToMainMenu(self)
end

function DiceChess:addToMainMenu(menu_items)
    menu_items.dicechess = {
        text = _("Dice Chess"),
        sorting_hint = "more_tools",
        callback = function()
            self:startNewGame()
        end,
    }
end

function DiceChess:startNewGame()
    local DiceChessWidget = require("dicechess_widget")
    UIManager:show(DiceChessWidget:new{})
end

return DiceChess
