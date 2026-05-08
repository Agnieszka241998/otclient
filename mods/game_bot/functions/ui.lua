local context = G.botContext
if type(context.UI) ~= "table" then
  context.UI = {}
end
local UI = context.UI

local function attachLegacyCheckCompat(widget, recursive)
  if type(widget) ~= "table" then
    return widget
  end

  if type(widget.isOn) == "function" and type(widget.setOn) == "function" then
    if type(widget.isChecked) ~= "function" then
      widget.isChecked = function(self)
        return self:isOn()
      end
    end
    if type(widget.setChecked) ~= "function" then
      widget.setChecked = function(self, value)
        self:setOn(value and true or false)
      end
    end
  end

  if recursive and type(widget.getChildren) == "function" then
    for _, child in ipairs(widget:getChildren()) do
      attachLegacyCheckCompat(child, true)
    end
  end

  return widget
end

context._attachLegacyCheckCompat = attachLegacyCheckCompat

UI.createWidget = function(name, parent)
  if parent == nil then
    parent = context.panel
  end
  local widget = g_ui.createWidget(name, parent)
  widget.botWidget = true
  return attachLegacyCheckCompat(widget, true)
end

UI.createMiniWindow = function(name, parent)
  if parent == nil then
    parent = modules.game_interface.getRightPanel()
  end
  local widget = g_ui.createWidget(name, parent)
  widget:setup()
  widget.botWidget = true
  return attachLegacyCheckCompat(widget, true)
end

UI.createWindow = function(name)
  local widget = g_ui.createWidget(name, g_ui.getRootWidget())
  widget.botWidget = true
  widget:show()
  widget:raise()
  widget:focus()
  return attachLegacyCheckCompat(widget, true)
end
