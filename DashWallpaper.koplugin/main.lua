--[[--
DashWallpaper —— 把「看板壁纸」下载并应用到 KOReader 屏保的插件。

设计目标：复用 DashViewer 的数据源（肿瘤新药 / 豆瓣等），把这些看板的「壁纸 PNG」
下载到 KOReader 的屏保目录，让 Kindle 休眠时显示看板内容。

关键安全设计（针对定制版 MiuRead / Paperwhite）：
  · 本插件**绝不解码、绝不显示**任何图片（KOReader 的 ImageViewer 在本设备渲染 PNG 会
    直接让程序崩出：imagewidget.lua:264 cannot render image）。
  · 只做两件事：HTTP 拉取字节 → 校验是合法 PNG → 写入屏保目录。整个流程不触发图片解码。
  · 屏保图片由 KOReader 自身的帧缓冲显示，与 Lua 的 ImageViewer 无关，已验证可用。

用法：
  1. 把本 DashWallpaper.koplugin 放进 KOReader 的 plugins 目录：
       Kindle:  /mnt/us/koreader/plugins/
  2. 重启 KOReader，「更多工具」里出现「看板壁纸」。
  3. 点「应用：XX 壁纸」即下载并写入屏保目录；让 Kindle 休眠即可看到。
  4. 新增壁纸源：电脑写好 dashwall_sources.txt（每行 名称<TAB>壁纸URL），推到设备后点「从文件导入」。

注意：界面文字均为硬编码中文，不依赖 gettext 翻译函数（KOReader 全局 _ 是数值，
直接 _() 会崩溃），因此全部使用普通字符串字面量。
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")

-- ltn12 在不同 KOReader 版本里的引入路径略有差异，做个兜底
local ltn12
pcall(function() ltn12 = require("ltn12") end)
if not ltn12 then ltn12 = require("socket.ltn12") end

local DashWallpaper = WidgetContainer:extend{
    name = "dashwallpaper",
    is_doc_only = false,
}

local SETTINGS_FILE = "dashwallpaper.lua"

-- 开箱即用的内置壁纸源：对应 DashViewer 的两个数据源，壁纸 PNG 由云端每日自动生成
local DEFAULT_WALLS = {
    { name = "肿瘤新药动态 · 壁纸", url = "https://2435cc319f464e0eaaded08a80644163.app.workbuddy.link/wallpaper.png" },
    { name = "豆瓣影视新书 · 壁纸", url = "https://b102a44faaf04c8ebaadb30e4783a396.app.workbuddy.link/wallpaper.png" },
}

function DashWallpaper:init()
    self.walls = {}
    self.settings = LuaSettings:open(DataStorage:getDataDir() .. "/" .. SETTINGS_FILE)

    -- 设置读写整体包一层 pcall：即便存档损坏，也不会让插件在加载期崩溃、从菜单消失
    local ok = pcall(function()
        if not self.settings:readSetting("defaults_seeded") then
            local walls = self.settings:readSetting("walls")
            if type(walls) ~= "table" then walls = {} end
            for _, d in ipairs(DEFAULT_WALLS) do
                local has = false
                for _, w in ipairs(walls) do
                    if type(w) == "table" and w.name == d.name then has = true; break end
                end
                if not has then
                    walls[#walls + 1] = { name = d.name, url = d.url }
                end
            end
            self.settings:saveSetting("walls", walls)
            self.settings:saveSetting("defaults_seeded", true)
            self.settings:flush()
        end
        local loaded = self.settings:readSetting("walls")
        if type(loaded) == "table" then self.walls = loaded end
    end)

    if not ok then
        -- 存档异常时回退到内置双源，保证插件一定可用、不消失
        self.walls = {
            { name = DEFAULT_WALLS[1].name, url = DEFAULT_WALLS[1].url },
            { name = DEFAULT_WALLS[2].name, url = DEFAULT_WALLS[2].url },
        }
    end

    self.ui.menu:registerToMainMenu(self)
end

function DashWallpaper:addToMainMenu(menu_items)
    local ok, t = pcall(function() return self:buildSubmenu() end)
    if not ok or type(t) ~= "table" then
        t = { { text = "（看板壁纸异常，请重启 KOReader）", enabled = false } }
    end
    menu_items.dashwallpaper = {
        text = "看板壁纸",
        sorting_hint = "more_tools",
        sub_item_table = t,
    }
end

-- 阅读界面（打开书后的顶部菜单）也要显示，否则只在主页能看到
function DashWallpaper:addToReaderMenu(menu_items)
    local ok, t = pcall(function() return self:buildSubmenu() end)
    if not ok or type(t) ~= "table" then
        t = { { text = "（看板壁纸异常，请重启 KOReader）", enabled = false } }
    end
    menu_items.dashwallpaper = {
        text = "看板壁纸",
        sorting_hint = "more_tools",
        sub_item_table = t,
    }
end

function DashWallpaper:buildSubmenu()
    local t = {}

    -- 各壁纸源
    for i, w in ipairs(self.walls) do
        t[#t + 1] = {
            text = "应用：" .. w.name,
            callback = function()
                self:applyWall(w)
            end,
            hold_callback = function()
                self:confirmDelete(i, w.name)
            end,
        }
    end

    -- 新增壁纸源：仅保留「从文件导入」，避免软键盘遮挡卡死
    t[#t + 1] = { text = "📄 从文件导入（dashwall_sources.txt）", callback = function() self:addFromFile() end }
    t[#t + 1] = {
        text = "❔ 使用说明",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = "• 已内置「肿瘤新药」「豆瓣影视新书」两张壁纸，点「应用」即下载到屏保目录\n"
                    .. "• 让 Kindle 进入休眠即可看到该看板壁纸\n"
                    .. "• 长按壁纸名称：删除该壁纸源\n"
                    .. "• 新增壁纸源：电脑写好 dashwall_sources.txt（每行 名称<TAB>壁纸URL），\n"
                    .. "  推到 KOReader 数据目录后点「从文件导入」\n\n"
                    .. "（本插件只下载写入、不解码图片，故不会像图片模式那样崩出。）\n"
                    .. "若屏保不显示，请在 KOReader 设置里把屏保目录指向写入的路径。",
            })
        end,
    }

    if #self.walls == 0 then
        t[#t + 1] = { text = "（暂无壁纸源，请先导入）", enabled = false }
    end
    return t
end

-- 探测 KOReader 屏保目录：返回第一个可写候选；都不行则创建第一个
function DashWallpaper:findScreensaverDir()
    local data = DataStorage:getDataDir()
    local candidates = {
        data .. "/screensaver",
        data .. "/../screensaver",
        "/mnt/us/koreader/screensaver",
    }
    for _, c in ipairs(candidates) do
        local test = c .. "/.dashwall_probe"
        local f = io.open(test, "w")
        if f then
            f:close()
            os.remove(test)
            return c
        end
    end
    -- 都写不进：尝试创建第一个候选目录再返回
    local c = candidates[1]
    pcall(function() os.execute('mkdir -p "' .. c .. '" >/dev/null 2>&1') end)
    return c
end

-- 候选地址：优先 wallpaper.png，缺失时回退同目录的 digest.png（云端已稳定部署）
function DashWallpaper:candidateUrls(url)
    local urls = { url }
    if url:match("wallpaper%.png$") then
        urls[#urls + 1] = url:gsub("wallpaper%.png$", "digest.png")
    else
        local base = url:match("(.*/)")
        if base then urls[#urls + 1] = base .. "digest.png" end
    end
    return urls
end

-- 下载并校验：是合法 PNG 才返回字节，否则返回 nil
function DashWallpaper:downloadPng(url)
    http.TIMEOUT = 60
    local resp = {}
    local _, code = http.request{
        url = url,
        sink = ltn12.sink.table(resp),
    }
    if code ~= 200 or not resp or #resp == 0 then
        return nil
    end
    local raw = table.concat(resp, "")
    if raw:sub(1, 8) ~= "\137\080\078\071\013\010\026\010" then
        return nil
    end
    return raw
end

-- 下载壁纸 PNG 并写入屏保目录（全程不解码图片，绝不触发 imagewidget 崩溃）
function DashWallpaper:applyWall(w)
    UIManager:show(InfoMessage:new{ text = "正在下载壁纸: " .. w.name })
    local raw = nil
    local used = nil
    for _, u in ipairs(self:candidateUrls(w.url)) do
        raw = self:downloadPng(u)
        if raw then used = u; break end
    end
    if not raw then
        UIManager:show(InfoMessage:new{
            text = "下载失败或地址尚未部署壁纸。\n请确认已联网，并等待每日自动部署生成壁纸。\n"
                .. "（也可先用「看板查看器」确认网络正常。）",
        })
        return
    end

    local dir = self:findScreensaverDir()
    local out = dir .. "/dashwallpaper.png"
    local f = io.open(out, "wb")
    if not f then
        UIManager:show(InfoMessage:new{
            text = "无法写入屏保目录：\n" .. dir
                .. "\n请检查 KOReader 屏保目录权限或设置。",
        })
        return
    end
    f:write(raw)
    f:close()

    local note = ""
    if used and used:match("digest%.png$") then
        note = "\n（当前用的是 digest.png 预览，专用壁纸部署后将自动升级）"
    end
    UIManager:show(InfoMessage:new{
        text = "已应用壁纸：「" .. w.name .. "」\n保存到：" .. out .. note
            .. "\n\n让 Kindle 进入休眠即可看到。\n（若屏保不显示，请在 KOReader 设置里把屏保目录指向该路径。）",
    })
end

-- 从文件批量导入（每行：名称<TAB>URL），完全不依赖屏幕键盘
function DashWallpaper:addFromFile()
    local path = DataStorage:getDataDir() .. "/dashwall_sources.txt"
    local f = io.open(path, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = "未找到文件：\n" .. path .. "\n\n"
                .. "请用电脑新建 dashwall_sources.txt，每行写：\n"
                .. "名称<TAB>壁纸URL\n"
                .. "再把它放进 KOReader 数据目录后重试。",
        })
        return
    end
    local added = 0
    for line in f:lines() do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            local name, url = line:match("^(.-)\t(.-)$")
            if not name then name, url = line, "" end
            if url ~= "" then
                self.walls[#self.walls + 1] = { name = name, url = url }
                added = added + 1
            end
        end
    end
    f:close()
    if added > 0 then
        self.settings:saveSetting("walls", self.walls)
        self.settings:flush()
    end
    UIManager:show(InfoMessage:new{ text = "已从文件导入 " .. added .. " 个壁纸源" })
end

-- 删除确认
function DashWallpaper:confirmDelete(idx, name)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "删除壁纸源「" .. name .. "」？",
        ok_text = "删除",
        cancel_text = "取消",
        callback = function()
            table.remove(self.walls, idx)
            self.settings:saveSetting("walls", self.walls)
            self.settings:flush()
            UIManager:show(InfoMessage:new{ text = "已删除: " .. name })
        end,
    })
end

return DashWallpaper
