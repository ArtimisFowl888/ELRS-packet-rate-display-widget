--[[
  EdgeTX Widget: ELRS Packet Rate Monitor
  Displays the current ExpressLRS packet rate selection reported by the module.
  The widget queries the ELRS module over CRSF telemetry and refreshes automatically.
]]

local DEVICE_ID = 0xEE -- ExpressLRS TX Module
local HANDSET_ELRS = 0xEF -- Address used by the ExpressLRS Lua handset
local CMD_DEVICE_INFO_REQ = 0x28
local CMD_PARAM_CHUNK_REQ = 0x2C
local RESP_DEVICE_INFO = 0x29
local RESP_PARAM_ENTRY = 0x2B

local VALUE = VALUE or 0
local BOOL = BOOL or 1

local getTime = getTime or function() return 0 end
local band = bit32 and bit32.band or function(a, b)
  local res, bit, exp = 0, 1, 0
  while a > 0 or b > 0 do
    local abit, bbit = a % 2, b % 2
    if abit == 1 and bbit == 1 then
      res = res + bit
    end
    bit = bit * 2
    a = math.floor(a / 2)
    b = math.floor(b / 2)
    exp = exp + 1
  end
  return res
end

local function byteToAscii(byte)
  if byte == 0xC0 then
    return "^"
  elseif byte == 0xC1 then
    return "v"
  elseif byte < 32 or byte > 126 then
    return "?"
  end
  return string.char(byte)
end

local function readString(frame, offset)
  local chars = {}
  local pos = offset
  while frame[pos] and frame[pos] ~= 0 do
    chars[#chars + 1] = byteToAscii(frame[pos])
    pos = pos + 1
  end
  if frame[pos] == 0 then
    pos = pos + 1 -- skip terminating null
  end
  return table.concat(chars), pos
end

local function readOptions(frame, offset)
  local options = {}
  local chars = {}
  local pos = offset
  while frame[pos] do
    local byte = frame[pos]
    pos = pos + 1
    if byte == 0 then
      break
    elseif byte == 59 then -- ';'
      options[#options + 1] = table.concat(chars)
      chars = {}
    else
      chars[#chars + 1] = byteToAscii(byte)
    end
  end
  options[#options + 1] = table.concat(chars)
  return options, pos
end

local function readUInt(frame, offset, size)
  local value = 0
  for i = 0, size - 1 do
    value = value * 256 + (frame[offset + i] or 0)
  end
  return value
end

local function normalizeFrame(data)
  if type(data) == "table" then
    return data
  elseif type(data) == "string" then
    local t = {}
    for i = 1, #data do
      t[i] = string.byte(data, i)
    end
    return t
  end
  return {}
end

local function formatPacketLabel(raw)
  if not raw or raw == "" then
    return "Unknown"
  end
  local lower = string.lower(raw)
  -- Normalize spacing around Hz and commas to improve readability
  local label = raw
  if string.find(label, "Hz") then
    label = string.gsub(label, "([0-9])Hz", "%1 Hz")
  end
  label = string.gsub(label, "%s+", " ")
  label = string.gsub(label, "%s+/%s+", "/")
  if string.find(lower, "pkt") then
    label = string.gsub(label, "[Pp][Kk][Tt]", "Pkt")
  end
  if string.find(lower, "packet") then
    label = string.gsub(label, "[Pp]acket", "Packet")
  end
  label = string.gsub(label, "^%s+", "")
  label = string.gsub(label, "%s+$", "")
  return label
end

local function formatTelemLabel(raw)
  if not raw or raw == "" then
    return "Unknown"
  end
  local label = string.gsub(raw, "%s+", " ")
  label = string.gsub(label, "^%s+", "")
  label = string.gsub(label, "%s+$", "")
  label = string.gsub(label, "[Tt]elemetry", "Telem")
  label = string.gsub(label, "[Rr]atio", "Ratio")
  return label
end

local function looksLikePacketRateField(name, values)
  local lname = string.lower(name or "")
  if string.find(lname, "packet rate", 1, true) or string.find(lname, "pkt rate", 1, true) then
    return true
  end
  if type(values) == "table" then
    for i = 1, #values do
      local v = values[i]
      if v then
        local lv = string.lower(v)
        if string.find(lv, "hz") or string.find(lv, "pkt") or string.find(lv, "packet") then
          return true
        end
      end
    end
  end
  return false
end

local function looksLikeTelemetryRatioField(name, values)
  local lname = string.lower(name or "")
  if string.find(lname, "telemetry ratio", 1, true) or string.find(lname, "telem ratio", 1, true) or string.find(lname, "telem", 1, true) then
    return true
  end
  if type(values) == "table" then
    for i = 1, #values do
      local v = values[i]
      if v then
        local lv = string.lower(v)
        if string.find(lv, "tele") or string.find(lv, "ratio") or string.find(lv, "std") or string.find(lv, "no tele") then
          return true
        end
        if string.find(lv, "%d+:%d+") then
          return true
        end
      end
    end
  end
  return false
end

local core = {
  hasCrossfire = type(crossfireTelemetryPush) == "function" and type(crossfireTelemetryPop) == "function",
  deviceId = DEVICE_ID,
  handsetId = HANDSET_ELRS,
  fieldsCount = nil,
  deviceName = nil,
  searchIndex = 1,
  targetFieldId = nil,
  targetFieldName = nil,
  targetOptions = nil,
  targetUnit = "",
  targetRaw = nil,
  targetLabel = nil,
  targetValueIndex = nil,
  teleFieldId = nil,
  teleFieldName = nil,
  teleOptions = nil,
  teleUnit = "",
  teleRaw = nil,
  teleLabel = nil,
  teleValueIndex = nil,
  teleLastUpdate = 0,
  lastUpdate = 0,
  pending = nil,
  nextDevicePoll = 0,
  nextFieldRequest = 0,
  nextValueRequest = 0,
  nextTeleRequest = 0,
  nextRescan = 0,
  requestTimeout = 200,
  scanSpacing = 15,
  rescanDelay = 500,
  refreshInterval = 120,
  staleAfter = 350
}

local function ensureInit()
  if core.initialized then
    return
  end
  core.initialized = true
  if not core.hasCrossfire then
    return
  end
  core.nextDevicePoll = getTime()
  core.nextRescan = getTime() + core.rescanDelay
end

local function pushFrame(command, payload)
  if not core.hasCrossfire then
    return
  end
  crossfireTelemetryPush(command, payload)
end

local function requestDeviceInfo()
  local now = getTime()
  if now >= core.nextDevicePoll then
    pushFrame(CMD_DEVICE_INFO_REQ, { 0x00, 0xEA })
    core.nextDevicePoll = now + 120
  end
end

local function requestField(fieldId, chunk)
  if not core.hasCrossfire then
    return
  end
  local now = getTime()
  core.pending = {
    fieldId = fieldId,
    chunk = chunk or 0,
    buffer = nil,
    started = now
  }
  pushFrame(CMD_PARAM_CHUNK_REQ, { core.deviceId, core.handsetId, fieldId, core.pending.chunk })
end

local function handleDeviceInfo(data)
  local frame = normalizeFrame(data)
  local id = frame[2]
  if not id or id ~= core.deviceId then
    return
  end

  local name, offset = readString(frame, 3)
  core.deviceName = name ~= "" and name or "ExpressLRS"
  if frame[offset + 12] then
    local fieldsCount = frame[offset + 12]
    if fieldsCount ~= core.fieldsCount then
      core.fieldsCount = fieldsCount
      core.searchIndex = 1
      core.targetFieldId = nil
      core.targetFieldName = nil
      core.targetLabel = nil
      core.targetRaw = nil
      core.targetOptions = nil
      core.targetUnit = ""
      core.targetValueIndex = nil
      core.nextValueRequest = 0
      core.teleFieldId = nil
      core.teleFieldName = nil
      core.teleOptions = nil
      core.teleUnit = ""
      core.teleRaw = nil
      core.teleLabel = nil
      core.teleValueIndex = nil
      core.nextTeleRequest = 0
      core.teleLastUpdate = 0
    end
  end
  if readUInt(frame, offset, 4) == 0x454C5253 then
    core.handsetId = HANDSET_ELRS
  else
    core.handsetId = 0xEA
  end
end

local function handleFieldData(fieldData, offset, fieldId)
  local fieldType = band(fieldData[offset + 1] or 0, 0x7F)
  local name
  name, offset = readString(fieldData, offset + 2)

  if fieldType == 9 then
    local values, nextOffset = readOptions(fieldData, offset)
    local valueIndex = fieldData[nextOffset] or 0
    local unit, _ = readString(fieldData, nextOffset + 4)

    local looksLikePacket = looksLikePacketRateField(name, values)
    local looksLikeTelem = looksLikeTelemetryRatioField(name, values)
    if not core.targetFieldId and looksLikePacket then
      core.targetFieldId = fieldId
      core.targetFieldName = name
      core.targetOptions = values
      core.targetUnit = unit
    end
    if not core.teleFieldId and looksLikeTelem then
      core.teleFieldId = fieldId
      core.teleFieldName = name
      core.teleOptions = values
      core.teleUnit = unit
    end

    if core.targetFieldId == fieldId and looksLikePacket then
      core.targetOptions = values
      core.targetUnit = unit
      core.targetValueIndex = valueIndex
      local raw = values[(valueIndex or 0) + 1] or "?"
      core.targetRaw = raw
      core.targetLabel = formatPacketLabel(raw)
      core.lastUpdate = getTime()
    end
    if core.teleFieldId == fieldId and looksLikeTelem then
      core.teleOptions = values
      core.teleUnit = unit
      core.teleValueIndex = valueIndex
      local teleRaw = values[(valueIndex or 0) + 1] or "?"
      core.teleRaw = teleRaw
      core.teleLabel = formatTelemLabel(teleRaw)
      core.teleLastUpdate = getTime()
    end
  end
end

local function handleParameterEntry(data)
  local frame = normalizeFrame(data)
  if (frame[2] ~= core.deviceId) or not core.pending or frame[3] ~= core.pending.fieldId then
    return
  end

  local chunksRemain = frame[4] or 0
  local pending = core.pending
  local fieldData
  local offset

  if chunksRemain > 0 or pending.chunk > 0 then
    pending.buffer = pending.buffer or {}
    for i = 5, #frame do
      pending.buffer[#pending.buffer + 1] = frame[i]
    end
    if chunksRemain > 0 then
      pending.chunk = pending.chunk + 1
      pushFrame(CMD_PARAM_CHUNK_REQ, { core.deviceId, core.handsetId, pending.fieldId, pending.chunk })
      pending.started = getTime()
      return
    else
      fieldData = pending.buffer
      offset = 1
    end
  else
    fieldData = frame
    offset = 5
  end

  core.pending = nil
  if fieldData and #fieldData >= offset + 1 then
    handleFieldData(fieldData, offset, frame[3])
  end
end

local function processTelemetry()
  if not core.hasCrossfire then
    return
  end
  while true do
    local command, payload = crossfireTelemetryPop()
    if not command then
      break
    end
    if command == RESP_DEVICE_INFO then
      handleDeviceInfo(payload)
    elseif command == RESP_PARAM_ENTRY then
      handleParameterEntry(payload)
    end
  end
end

local function scheduleRequests()
  if not core.hasCrossfire then
    return
  end

  local now = getTime()

  if core.pending and now - (core.pending.started or now) > core.requestTimeout then
    core.pending = nil
  end

  if not core.fieldsCount or core.fieldsCount == 0 then
    requestDeviceInfo()
    return
  end

  if core.pending then
    return
  end

  local needScan = (core.targetFieldId == nil) or (core.teleFieldId == nil)
  local packetDue = core.targetFieldId and now >= (core.nextValueRequest or 0)
  local teleDue = core.teleFieldId and now >= (core.nextTeleRequest or 0)

  if packetDue and (not teleDue or (core.nextValueRequest or 0) <= (core.nextTeleRequest or 0)) then
    requestField(core.targetFieldId, 0)
    core.nextValueRequest = now + core.refreshInterval
    return
  end

  if teleDue then
    requestField(core.teleFieldId, 0)
    core.nextTeleRequest = now + core.refreshInterval
    return
  end

  if needScan then
    if core.searchIndex > core.fieldsCount then
      if now >= core.nextRescan then
        core.searchIndex = 1
        core.nextRescan = now + core.rescanDelay
      else
        return
      end
    end
    if now >= core.nextFieldRequest and core.searchIndex <= core.fieldsCount then
      requestField(core.searchIndex, 0)
      core.searchIndex = core.searchIndex + 1
      core.nextFieldRequest = now + core.scanSpacing
    end
  end
end

local function tick(allowRequests)
  ensureInit()
  processTelemetry()
  if allowRequests then
    scheduleRequests()
  end
end

local function getPacketInfo()
  if not core.hasCrossfire then
    return { state = "no_crsf" }
  end
  if not core.fieldsCount or core.fieldsCount == 0 then
    return { state = "waiting", module = core.deviceName }
  end
  if not core.targetFieldId then
    return { state = "scanning", module = core.deviceName }
  end
  if not core.targetLabel then
    return { state = "no_data", module = core.deviceName }
  end

  local now = getTime()
  local age = now - (core.lastUpdate or 0)
  local stale = age > core.staleAfter
  local teleLabel = core.teleLabel
  local teleRaw = core.teleRaw
  local teleStale
  if core.teleFieldId and teleLabel then
    teleStale = (now - (core.teleLastUpdate or 0)) > core.staleAfter
  end
  return {
    state = stale and "stale" or "ready",
    label = core.targetLabel,
    raw = core.targetRaw,
    module = core.deviceName,
    fieldName = core.targetFieldName or "Packet Rate",
    stale = stale,
    teleLabel = teleLabel,
    teleRaw = teleRaw,
    teleFieldName = core.teleFieldName,
    teleStale = teleLabel and teleStale or nil
  }
end

local function fontHeight(flag)
  if flag == DBLSIZE then
    return 18
  elseif flag == MIDSIZE then
    return 12
  elseif flag == SMLSIZE then
    return 8
  end
  return 10
end

local function chooseMainFont(zone)
  if zone.h >= 90 then
    return DBLSIZE
  elseif zone.h >= 45 then
    return MIDSIZE
  else
    return SMLSIZE
  end
end

local function drawCentered(zone, y, text, flags)
  lcd.drawText(zone.x + math.floor(zone.w / 2), y, text, flags + CENTER)
end

local function drawMain(zone, text, stale)
  local font = chooseMainFont(zone)
  local attr = font
  if stale then
    attr = attr + BLINK
  end
  local y = zone.y + math.floor((zone.h - fontHeight(font)) / 2)
  drawCentered(zone, y, text, attr)
end

local function bottomTextY(zone)
  local margin = 1
  local y = zone.y + zone.h - fontHeight(SMLSIZE) - margin
  if y < zone.y then
    return zone.y
  end
  return y
end

local function drawStatus(zone, state, moduleName, showName)
  local messageMap = {
    no_crsf = "CRSF unavailable",
    waiting = "Waiting for ELRS...",
    scanning = "Scanning for packet rate...",
    no_data = "Packet data missing"
  }
  local mainText = messageMap[state] or "Unknown"
  drawMain(zone, mainText, false)
  if showName and moduleName and moduleName ~= "" then
    drawCentered(zone, bottomTextY(zone), moduleName, SMLSIZE)
  end
end

local function updateOptions(widget, options)
  widget.options = options or {}
  if widget.options.ShowName == nil then
    widget.options.ShowName = 1
  end
  if widget.options.ShowTelem == nil then
    widget.options.ShowTelem = 1
  end
end

local function create(zone, options)
  ensureInit()
  local widget = { zone = zone, options = {} }
  updateOptions(widget, options)
  return widget
end

local function update(widget, options)
  updateOptions(widget, options)
end

local function background(_widget)
  tick(true)
end

local function refresh(widget)
  tick(false)
  local info = getPacketInfo()
  if info.state ~= "ready" and info.state ~= "stale" then
    drawStatus(widget.zone, info.state, info.module, widget.options.ShowName ~= 0)
    return
  end

  drawMain(widget.zone, info.label or "Rate ?", info.state == "stale")

  local subParts = {}
  if widget.options.ShowName ~= 0 then
    if info.module and info.module ~= "" then
      subParts[#subParts + 1] = info.module
    end
    if info.raw and info.raw ~= "" and info.raw ~= info.label then
      subParts[#subParts + 1] = info.raw
    end
  end
  if widget.options.ShowTelem ~= 0 and info.teleLabel then
    local teleText = info.teleLabel
    if info.teleRaw and info.teleRaw ~= info.teleLabel then
      teleText = teleText .. " (" .. info.teleRaw .. ")"
    end
    if info.teleStale then
      teleText = teleText .. " *"
    end
    subParts[#subParts + 1] = "Telem " .. teleText
  end
  if #subParts > 0 then
    local subline = table.concat(subParts, " | ")
    drawCentered(widget.zone, bottomTextY(widget.zone), subline, SMLSIZE)
  end
end

return {
  name = "ELRS Packet Rate",
  options = {
    { "ShowName", BOOL, 1 },
    { "ShowTelem", BOOL, 1 }
  },
  create = create,
  update = update,
  background = background,
  refresh = refresh
}
