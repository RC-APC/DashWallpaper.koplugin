--[[--
DashViewer —— 通用「看板查看器」KOReader 插件。

设计目标：让 KOReader 能查看任意云端看板的纯文本摘要，而不局限于某一种。
用法：
  1. 把本 DashViewer.koplugin 文件夹放进 KOReader 的 plugins 目录：
       Kindle:  /mnt/us/koreader/plugins/
       Kobo:    /.adds/koreader/plugins/
  2. 重启 KOReader，主菜单「更多工具」里出现「看板查看器」。
  3. 已内置「肿瘤新药动态」「豆瓣影视新书」「微信读书榜单」三个数据源，开箱即用，无需手动添加。
  4. 数据源仅以纯文字方式显示（本定制 KOReader 图片解码不可用，已移除图片模式）。
  5. 新增数据源请用「从文件导入」：在电脑写好 dashviewer_sources.txt
     （每行：名称<TAB>URL），推到 KOReader 数据目录后点「从文件导入」。

注意：界面文字均为硬编码中文，不依赖 gettext 翻译函数（KOReader 全局 _ 是数值，
直接 _() 会崩溃），因此全部使用普通字符串字面量。
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")

-- ltn12 在不同 KOReader 版本里的引入路径略有差异，做个兜底
local ltn12
pcall(function() ltn12 = require("ltn12") end)
if not ltn12 then ltn12 = require("socket.ltn12") end

local DashViewer = WidgetContainer:extend{
    name = "dashviewer",
    is_doc_only = false,
}

local SETTINGS_FILE = "dashviewer.lua"

-- 开箱即用的内置数据源：装好插件直接就有，无需手动添加
local DEFAULT_FEEDS = {
    { name = "肿瘤新药动态", url = "https://2435cc319f464e0eaaded08a80644163.app.workbuddy.link/digest.txt" },
    { name = "豆瓣影视新书", url = "https://b102a44faaf04c8ebaadb30e4783a396.app.workbuddy.link/digest.txt" },
    { name = "微信读书榜单", url = "https://9c18b55628f847a3a6628b3e2cada237.app.workbuddy.link/weread_digest.txt" },
}

-- 内置源随插件升级自动补齐 / 升级 URL。每新增或改 URL 时 +1；
-- 已对齐版本的不再改动，保留用户自己的增删。
local DEFAULTS_VERSION = 2

function DashViewer:init()
    self.feeds = {}
    self.settings = LuaSettings:open(DataStorage:getDataDir() .. "/" .. SETTINGS_FILE)

    -- 设置读写整体包一层 pcall：即便存档损坏，也不会让插件在加载期崩溃、从菜单消失
    local ok = pcall(function()
        local feeds = self.settings:readSetting("feeds")
        if type(feeds) ~= "table" then feeds = {} end

        -- 兼容旧版 OncoDigest：把老的单 url 设置并入 feeds
        local old_url = self.settings:readSetting("url")
        if type(old_url) == "string" and old_url ~= "" then
            local exist = false
            for _, f in ipairs(feeds) do
                if type(f) == "table" and f.url == old_url then exist = true; break end
            end
            if not exist then
                feeds[#feeds + 1] = { name = "肿瘤新药动态", url = old_url }
            end
        end

        -- 内置源随插件升级自动补齐 / 升级 URL（按名称对齐，避免重复）：
        -- 名称不存在 -> 新增；名称存在但 URL 变了 -> 升级 URL。
        -- 仅当已记录的版本号低于当前版本才执行，避免每次启动都写盘、保留用户增删。
        local cur = tonumber(self.settings:readSetting("defaults_version")) or 0
        if cur < DEFAULTS_VERSION then
            for _, d in ipairs(DEFAULT_FEEDS) do
                local found = false
                for _, f in ipairs(feeds) do
                    if type(f) == "table" and f.name == d.name then
                        if f.url ~= d.url then f.url = d.url end
                        found = true
                        break
                    end
                end
                if not found then
                    feeds[#feeds + 1] = { name = d.name, url = d.url }
                end
            end
            self.settings:saveSetting("feeds", feeds)
            self.settings:saveSetting("defaults_version", DEFAULTS_VERSION)
            self.settings:flush()
        end

        local loaded = self.settings:readSetting("feeds")
        if type(loaded) == "table" then self.feeds = loaded end
    end)

    if not ok then
        -- 存档异常时回退到内置三源，保证插件一定可用、不消失
        self.feeds = {
            { name = DEFAULT_FEEDS[1].name, url = DEFAULT_FEEDS[1].url },
            { name = DEFAULT_FEEDS[2].name, url = DEFAULT_FEEDS[2].url },
            { name = DEFAULT_FEEDS[3].name, url = DEFAULT_FEEDS[3].url },
        }
    end

    self.ui.menu:registerToMainMenu(self)
end

function DashViewer:addToMainMenu(menu_items)
    local ok, t = pcall(function() return self:buildSubmenu() end)
    if not ok or type(t) ~= "table" then
        t = { { text = "（看板查看器异常，请重启 KOReader）", enabled = false } }
    end
    menu_items.dashviewer = {
        text = "看板查看器",
        sorting_hint = "more_tools",
        sub_item_table = t,
    }
end

-- 阅读界面（打开书后的顶部菜单）也要显示，否则只在主页能看到
function DashViewer:addToReaderMenu(menu_items)
    local ok, t = pcall(function() return self:buildSubmenu() end)
    if not ok or type(t) ~= "table" then
        t = { { text = "（看板查看器异常，请重启 KOReader）", enabled = false } }
    end
    menu_items.dashviewer = {
        text = "看板查看器",
        sorting_hint = "more_tools",
        sub_item_table = t,
    }
end

function DashViewer:buildSubmenu()
    local t = {}

    -- 各数据源
    for i, feed in ipairs(self.feeds) do
        t[#t + 1] = {
            text = feed.name,
            callback = function()
                self:fetch(feed)
            end,
            hold_callback = function()
                self:confirmDelete(i, feed.name)
            end,
        }
    end

    -- 新增数据源：仅保留「从文件导入」。
    -- 手动输入（软键盘会被本设备遮挡卡死）与快速添加、图片模式，
    -- 均已移除——图片解码在当前定制 KOReader 上会直接让程序崩出。
    t[#t + 1] = { text = "📄 从文件导入（dashviewer_sources.txt）", callback = function() self:addFromFile() end }
    t[#t + 1] = {
        text = "❔ 使用说明",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = "• 已内置「肿瘤新药动态」「豆瓣影视新书」「微信读书榜单」，装好即可用\n"
                    .. "• 点击数据源名称：以纯文字方式获取并显示最新摘要\n"
                    .. "• 长按数据源名称：删除该数据源\n"
                    .. "• 新增数据源：在电脑写好 dashviewer_sources.txt\n"
                    .. "   （每行：名称<TAB>URL），推到 KOReader 数据目录后，\n"
                    .. "   点「从文件导入」即可。\n\n"
                    .. "（本设备图片解码不可用，故仅提供纯文字显示。）\n\n"
                    .. "数据源只需返回 UTF-8 纯文本，与具体业务无关。",
            })
        end,
    }

    if #self.feeds == 0 then
        t[#t + 1] = { text = "（暂无数据源，请先添加）", enabled = false }
    end
    return t
end

-- 从文件批量导入（每行：名称<TAB>URL），完全不依赖屏幕键盘
function DashViewer:addFromFile()
    local path = DataStorage:getDataDir() .. "/dashviewer_sources.txt"
    local f = io.open(path, "r")
    if not f then
        UIManager:show(InfoMessage:new{
            text = "未找到文件：\n" .. path .. "\n\n"
                .. "请用电脑新建 dashviewer_sources.txt，每行写：\n"
                .. "名称<TAB>URL\n"
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
                self.feeds[#self.feeds + 1] = { name = name, url = url }
                added = added + 1
            end
        end
    end
    f:close()
    if added > 0 then
        self.settings:saveSetting("feeds", self.feeds)
        self.settings:flush()
    end
    UIManager:show(InfoMessage:new{ text = "已从文件导入 " .. added .. " 个数据源" })
end

-- 删除确认
function DashViewer:confirmDelete(idx, name)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = "删除数据源「" .. name .. "」？",
        ok_text = "删除",
        cancel_text = "取消",
        callback = function()
            table.remove(self.feeds, idx)
            self.settings:saveSetting("feeds", self.feeds)
            self.settings:flush()
            UIManager:show(InfoMessage:new{ text = "已删除: " .. name })
        end,
    })
end

-- 拉取并以纯文字方式显示（图片模式已移除：本设备图片解码会让 KOReader 崩出）
function DashViewer:fetch(feed)
    UIManager:show(InfoMessage:new{ text = "正在获取: " .. feed.name })
    http.TIMEOUT = 30
    local resp = {}
    local _, code = http.request{
        url = feed.url,
        sink = ltn12.sink.table(resp),
    }
    if code ~= 200 or not resp or #resp == 0 then
        UIManager:show(InfoMessage:new{
            text = "获取失败 (" .. tostring(code) .. ")\n"
                .. feed.name .. "\n"
                .. "请确认 Kindle 已联网，或地址正确",
        })
        return
    end
    local text = table.concat(resp, "")
    if text:match("^%s*$") then
        text = "（该数据源内容为空）"
    end

    UIManager:show(TextViewer:new{
        title = feed.name,
        text = text,
        text_font_size = 16,
    })
end

return DashViewer
