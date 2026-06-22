-- Anal_Cocksucker
-- Читает чат Arizona RP и шлёт уведомление в Telegram, когда пора бежать к компу.
-- Меню настроек: команда /pisya
-- made by claude & cikriy67

script_name('Anal_Cocksucker')
script_author('claude & cikriy67')
script_version('1.0')

require 'lib.moonloader'

local imgui    = require 'mimgui'
local sampev   = require 'samp.events'
local effil    = require 'effil'
local dkjson   = require 'dkjson'
local ffi      = require 'ffi'
local encoding = require 'encoding'

-- cjson отдаёт сырой UTF-8 (безопаснее для эмодзи), dkjson — запасной вариант
local cjson_ok, cjson = pcall(require, 'cjson')
local function json_encode(t)
    if cjson_ok then
        local ok, s = pcall(cjson.encode, t)
        if ok and s then return s end
    end
    return dkjson.encode(t)
end

encoding.default = 'CP1251'
local u8 = encoding.UTF8

local new = imgui.new
local VER = '1.0'
local WATERMARK = 'made by claude & cikriy67'

--==============================================================--
--  КОНФИГ (хранится в moonloader/config/Anal_Cocksucker.json)  --
--==============================================================--
local CFG_DIR  = getWorkingDirectory() .. '\\config'
local CFG_PATH = CFG_DIR .. '\\Anal_Cocksucker.json'

local cfg = {
    token    = '',          -- API токен бота от @BotFather
    chat_id  = '',          -- твой Telegram ID от @userinfobot
    enabled  = true,        -- следить за чатом
    keywords = 'на явку',   -- ключевые слова (через запятую)
    cooldown = 30,          -- сек. защита от повторной отправки того же текста
}

local function save_cfg()
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    local f = io.open(CFG_PATH, 'w')
    if not f then return false end
    f:write(dkjson.encode(cfg, { indent = true }))
    f:close()
    return true
end

local function load_cfg()
    local f = io.open(CFG_PATH, 'r')
    if not f then return end
    local data = f:read('*a')
    f:close()
    local t = dkjson.decode(data)
    if type(t) == 'table' then
        for k, v in pairs(t) do cfg[k] = v end
    end
end
load_cfg()

--==============================================================--
--  УТИЛИТЫ                                                     --
--==============================================================--

-- Сообщение в игровой чат (входной текст в UTF-8 -> конвертим в CP1251)
local function addchat(text_utf8)
    sampAddChatMessage(u8:decode('{E91E63}[Anal_Cocksucker]{FFFFFF} ' .. text_utf8), -1)
end

-- Приведение CP1251-строки к нижнему регистру (включая кириллицу и Ё)
local function cp1251_lower(s)
    return (s:gsub('[\168\192-\223]', function(c)
        local b = c:byte()
        if b == 168 then return string.char(184) end -- Ё -> ё
        return string.char(b + 32)                     -- А-Я -> а-я
    end))
end

-- Список ключевых слов в CP1251 нижнем регистре (для сравнения с чатом)
local keywordsCP = {}
local function rebuild_keywords()
    keywordsCP = {}
    for part in tostring(cfg.keywords):gmatch('[^,]+') do
        local trimmed = part:gsub('^%s+', ''):gsub('%s+$', '')
        if #trimmed > 0 then
            keywordsCP[#keywordsCP + 1] = cp1251_lower(u8:decode(trimmed))
        end
    end
end
rebuild_keywords()

--==============================================================--
--  СОСТОЯНИЕ UI                                                --
--==============================================================--
local window        = new.bool(false)
local buf_token     = new.char[128](tostring(cfg.token or ''))
local buf_chat      = new.char[64](tostring(cfg.chat_id or ''))
local buf_kw        = new.char[256](tostring(cfg.keywords or ''))
local cb_enabled    = new.bool(cfg.enabled and true or false)
local cb_show_token = new.bool(false)

local conn_status = { text = 'не проверено', col = { 0.70, 0.70, 0.70, 1 } }
local checking    = false

--==============================================================--
--  АСИНХРОННЫЙ HTTPS (через effil, чтобы не фризить игру)      --
--==============================================================--
local host_path, host_cpath = package.path, package.cpath

local function http_post_async(url, body, on_done)
    local th = effil.thread(function(path, cpath, url, body)
        package.path, package.cpath = path, cpath
        local http  = require 'socket.http'
        local https = require 'ssl.https'
        local ltn12 = require 'ltn12'
        http.TIMEOUT = 10 -- ограничиваем зависание соединения
        local resp = {}
        local ok, code = https.request {
            url     = url,
            method  = 'POST',
            headers = {
                ['Content-Type']   = 'application/json',
                ['Content-Length'] = tostring(#body),
                ['Connection']     = 'close',
            },
            source = ltn12.source.string(body),
            sink   = ltn12.sink.table(resp),
        }
        if ok then
            return true, tonumber(code) or -1, table.concat(resp)
        else
            return false, tostring(code)
        end
    end)(host_path, host_cpath, url, body)

    lua_thread.create(function()
        while true do
            local st = th:status()
            if st == 'completed' then
                local r1, r2, r3 = th:get()
                if r1 == true then
                    on_done(true, r2, r3)      -- success, http_code, body
                else
                    on_done(false, nil, r2)    -- ошибка соединения (r2 = текст)
                end
                return
            elseif st == 'failed' or st == 'canceled' then
                local _, err = th:status()
                on_done(false, nil, tostring(err))
                return
            end
            wait(0)
        end
    end)
end

--==============================================================--
--  TELEGRAM                                                    --
--==============================================================--
local function tg_send(text_utf8, on_done)
    on_done = on_done or function() end
    if cfg.token == '' or cfg.chat_id == '' then
        on_done(false, nil, 'не заполнен токен или ID')
        return
    end
    local url = 'https://api.telegram.org/bot' .. cfg.token .. '/sendMessage'
    local payload = json_encode({
        chat_id                  = cfg.chat_id,
        text                     = text_utf8,
        disable_web_page_preview = true,
    })
    if not payload then
        on_done(false, nil, 'не удалось сформировать запрос')
        return
    end
    http_post_async(url, payload, on_done)
end

-- Разбор ответа Telegram: успех = http 200 и {"ok":true}
local function tg_ok(code, body)
    if code ~= 200 then return false end
    local j = body and dkjson.decode(body) or nil
    return type(j) == 'table' and j.ok == true
end

local function tg_error_desc(body)
    local j = body and dkjson.decode(body) or nil
    if type(j) == 'table' and j.description then return j.description end
    return nil
end

--==============================================================--
--  ПРИМЕНИТЬ НАСТРОЙКИ / ПРОВЕРИТЬ СВЯЗЬ                       --
--==============================================================--
local function apply_and_save()
    cfg.token    = (ffi.string(buf_token):gsub('^%s+', ''):gsub('%s+$', ''))
    cfg.chat_id  = (ffi.string(buf_chat):gsub('^%s+', ''):gsub('%s+$', ''))
    cfg.keywords = ffi.string(buf_kw)
    cfg.enabled  = cb_enabled[0]
    rebuild_keywords()
    return save_cfg()
end

local function do_check()
    if cfg.token == '' or cfg.chat_id == '' then
        conn_status = { text = 'заполни токен и Telegram ID!', col = { 0.95, 0.30, 0.20, 1 } }
        return
    end
    checking = true
    conn_status = { text = 'проверяю...', col = { 0.95, 0.80, 0.20, 1 } }
    local test = '✅ Anal_Cocksucker подключён!\nЕсли ты видишь это сообщение — связь работает, '
              .. 'я напишу сюда, когда в чате будет явка.'
    tg_send(test, function(success, code, body)
        checking = false
        if success and tg_ok(code, body) then
            conn_status = { text = 'связь работает! проверь Telegram', col = { 0.18, 0.80, 0.44, 1 } }
            addchat('{2ECC71}связь с Telegram работает! тестовое сообщение отправлено.')
        else
            local desc = tg_error_desc(body)
            conn_status = {
                text = 'ошибка' .. (code and (' (код ' .. code .. ')') or '') .. (desc and (': ' .. desc) or ''),
                col  = { 0.90, 0.25, 0.20, 1 },
            }
            addchat('{E74C3C}не удалось связаться с Telegram: ' .. tostring(desc or code or body))
        end
    end)
end

--==============================================================--
--  УВЕДОМЛЕНИЕ О ЯВКЕ                                          --
--==============================================================--
local last_text, last_time = '', 0

-- безопасная конвертация CP1251 -> UTF-8 (чат с сервера может содержать любые байты)
local function safe_u8(s)
    local ok, r = pcall(u8, s)
    if ok and type(r) == 'string' then return r end
    return s
end

local function build_notification(raw_cp1251)
    local clean = raw_cp1251:gsub('{%x%x%x%x%x%x}', '')         -- убираем цветовые теги SAMP
    clean = clean:gsub('^%s+', ''):gsub('%s+$', '')
    return '🚨 ПОРА БЕЖАТЬ К КОМПУ! 🚨\n\n'
        .. safe_u8(clean)                                       -- CP1251 -> UTF-8
        .. '\n\n🕒 ' .. os.date('%H:%M:%S')
end

local function notify(raw_cp1251)
    local now = os.time()
    if raw_cp1251 == last_text and (now - last_time) < (tonumber(cfg.cooldown) or 30) then
        return -- тот же текст недавно уже отправляли
    end
    last_text, last_time = raw_cp1251, now
    tg_send(build_notification(raw_cp1251), function(success, code, body)
        if success and tg_ok(code, body) then
            addchat('{2ECC71}явка! уведомление отправлено в Telegram.')
        else
            addchat('{E74C3C}явка поймана, но Telegram не ответил (' .. tostring(code or body) .. ')')
        end
    end)
end

--==============================================================--
--  ХУК ЧАТА                                                    --
--==============================================================--
function sampev.onServerMessage(color, text)
    -- весь разбор в pcall, чтобы ошибка никогда не сломала обработку чата
    pcall(function()
        if not cfg.enabled or #keywordsCP == 0 then return end
        local low = cp1251_lower(text)
        for _, kw in ipairs(keywordsCP) do
            if low:find(kw, 1, true) then
                notify(text)
                break
            end
        end
    end)
    -- ничего не возвращаем -> сообщение проходит в чат как обычно
end

--==============================================================--
--  ТЕМА (немного пафоса)                                       --
--==============================================================--
imgui.OnInitialize(function()
    local style = imgui.GetStyle()
    style.WindowRounding  = 8
    style.ChildRounding   = 8
    style.FrameRounding   = 6
    style.GrabRounding    = 6
    style.PopupRounding    = 6
    style.ScrollbarRounding = 8
    style.WindowPadding   = imgui.ImVec2(16, 16)
    style.FramePadding    = imgui.ImVec2(9, 6)
    style.ItemSpacing     = imgui.ImVec2(8, 8)

    local C = imgui.Col
    local col = style.Colors
    col[C.WindowBg]       = imgui.ImVec4(0.07, 0.07, 0.09, 0.97)
    col[C.Border]         = imgui.ImVec4(0.91, 0.12, 0.39, 0.35)
    col[C.FrameBg]        = imgui.ImVec4(0.16, 0.16, 0.20, 1.00)
    col[C.FrameBgHovered] = imgui.ImVec4(0.24, 0.20, 0.26, 1.00)
    col[C.FrameBgActive]  = imgui.ImVec4(0.30, 0.22, 0.30, 1.00)
    col[C.TitleBg]        = imgui.ImVec4(0.10, 0.10, 0.13, 1.00)
    col[C.TitleBgActive]  = imgui.ImVec4(0.91, 0.12, 0.39, 0.85)
    col[C.Button]         = imgui.ImVec4(0.91, 0.12, 0.39, 0.80)
    col[C.ButtonHovered]  = imgui.ImVec4(0.95, 0.20, 0.47, 0.95)
    col[C.ButtonActive]   = imgui.ImVec4(0.74, 0.09, 0.31, 1.00)
    col[C.CheckMark]      = imgui.ImVec4(0.95, 0.24, 0.52, 1.00)
    col[C.Separator]      = imgui.ImVec4(0.91, 0.12, 0.39, 0.50)
end)

--==============================================================--
--  ОКНО НАСТРОЕК                                               --
--==============================================================--
-- ВАЖНО: файл в UTF-8, поэтому в imgui строки передаём как есть (без u8()).
local mainFrame = imgui.OnFrame(
    function() return window[0] end,
    function()
        local res_x, res_y = getScreenResolution()
        imgui.SetNextWindowPos(imgui.ImVec2(res_x / 2, res_y / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        -- фиксированный размер + Cond.Always: окно не "раздувается" и игнорирует
        -- любой старый размер, сохранённый mimgui в .ini
        imgui.SetNextWindowSize(imgui.ImVec2(470, 600), imgui.Cond.Always)
        imgui.Begin('Anal_Cocksucker  -  ловец явок', window,
            imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

        imgui.TextColored(imgui.ImVec4(0.95, 0.18, 0.45, 1.0), '* ANAL_COCKSUCKER *')
        imgui.SameLine()
        imgui.TextDisabled('v' .. VER)
        imgui.Separator()
        imgui.Spacing()

        if imgui.Checkbox('Следить за чатом и слать в Telegram', cb_enabled) then
            cfg.enabled = cb_enabled[0]
            save_cfg()
        end
        imgui.Spacing()

        imgui.PushItemWidth(-1)

        imgui.Text('API токен бота (от @BotFather):')
        local tflags = cb_show_token[0] and 0 or imgui.InputTextFlags.Password
        imgui.InputText('##token', buf_token, ffi.sizeof(buf_token), tflags)
        imgui.Checkbox('показать токен', cb_show_token)
        imgui.Spacing()

        imgui.Text('Твой Telegram ID (от @userinfobot):')
        imgui.InputText('##chatid', buf_chat, ffi.sizeof(buf_chat))
        imgui.Spacing()

        imgui.Text('Ключевые слова (через запятую):')
        imgui.InputText('##kw', buf_kw, ffi.sizeof(buf_kw))
        imgui.TextDisabled('напр.: на явку, явка, сбор')

        imgui.PopItemWidth()

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if imgui.Button('Сохранить', imgui.ImVec2(135, 30)) then
            apply_and_save()
            addchat('{2ECC71}настройки сохранены.')
        end
        imgui.SameLine()
        if imgui.Button(checking and 'Проверяю...' or 'Проверить связь', imgui.ImVec2(165, 30)) then
            if not checking then
                apply_and_save()
                do_check()
            end
        end

        imgui.Spacing()
        imgui.Text('Статус:')
        imgui.SameLine()
        local c = conn_status.col
        imgui.TextColored(imgui.ImVec4(c[1], c[2], c[3], c[4]), '%s', conn_status.text)

        imgui.Spacing()
        imgui.Separator()
        imgui.TextDisabled('1. Создай бота у @BotFather -> вставь токен сюда.')
        imgui.TextDisabled('2. Узнай свой ID у @userinfobot -> вставь в поле ID.')
        imgui.TextDisabled('3. Напиши своему боту /start, иначе он не сможет писать тебе.')
        imgui.TextDisabled('4. Жми "Проверить связь".')

        -- водяной знак в уголке
        imgui.Spacing()
        local tw = imgui.CalcTextSize(WATERMARK)
        imgui.SetCursorPosX(imgui.GetWindowWidth() - tw.x - 12)
        imgui.TextDisabled(WATERMARK)

        imgui.End()
    end
)
mainFrame.LockPlayer = true -- пока меню открыто, персонаж не бегает

--==============================================================--
--  СТАРТ                                                       --
--==============================================================--
function main()
    while not isSampAvailable() do wait(0) end

    sampRegisterChatCommand('pisya', function()
        window[0] = not window[0]
    end)

    addchat('загружен! меню настроек: {E91E63}/pisya')
    if cfg.token == '' or cfg.chat_id == '' then
        addchat('{F1C40F}бот ещё не настроен - открой /pisya и вбей токен + ID.')
    end

    wait(-1)
end
