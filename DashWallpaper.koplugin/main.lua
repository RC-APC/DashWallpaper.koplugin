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

-- 开箱即用的内置壁纸源：对应 DashViewer 的三个数据源，壁纸 PNG 由云端按请求 IP 现场生成
local DEFAULT_WALLS = {
    { name = "肿瘤新药动态 · 壁纸", url = "https://9c18b55628f847a3a6628b3e2cada237.app.workbuddy.link/wallpaper" },
    { name = "豆瓣影视新书 · 壁纸", url = "https://9c18b55628f847a3a6628b3e2cada237.app.workbuddy.link/wallpaper?theme=douban" },
    { name = "微信读书榜单 · 壁纸", url = "https://9c18b55628f847a3a6628b3e2cada237.app.workbuddy.link/wallpaper?theme=weread" },
}

-- 内置源随插件升级自动补齐 / 升级 URL。每新增或改 URL 时 +1；
-- 已对齐版本的不再改动，保留用户自己的增删。
local DEFAULTS_VERSION = 2

-- 每日自动更新：轮询间隔（秒）。Kindle 挂起期间 Lua 不运行，所以真正的触发点是
-- 「唤醒后 / 进入休眠前 / 前台每 30 分钟轮询」三处补做，而不是严格的墙上时钟定时任务。
local AUTO_CHECK_SECONDS = 30 * 60
-- 可选更新时间（整点）：到达该时刻后，当天第一次联网时自动下载一次
local AUTO_HOURS = { 0, 5, 6, 7, 8, 9, 12, 18, 21, 23 }

-- 可选城市：中国主要城市 + 世界主要城市。下载壁纸时把所选城市带上，
-- 服务端按城市名取天气，彻底绕开"经反代后请求 IP 变成代理出口（如北京）"的问题。
local CITY_CHOICES = {
    "上海", "北京", "广州", "深圳", "杭州", "成都", "武汉", "南京", "西安", "重庆",
    "苏州", "天津", "长沙", "青岛", "厦门", "宁波", "郑州", "无锡", "福州", "济南",
    "合肥", "昆明", "大连", "哈尔滨", "沈阳", "石家庄", "南宁", "贵阳", "太原", "长春",
    "南昌", "兰州", "海口", "呼和浩特", "银川", "西宁", "乌鲁木齐", "拉萨", "香港", "澳门", "台北",
    "东京", "纽约", "伦敦", "巴黎", "首尔", "新加坡", "曼谷", "悉尼", "墨尔本", "洛杉矶",
    "旧金山", "西雅图", "芝加哥", "波士顿", "多伦多", "温哥华", "柏林", "莫斯科", "迪拜",
    "罗马", "马德里", "阿姆斯特丹", "苏黎世", "维也纳", "斯德哥尔摩", "哥本哈根", "都柏林",
    "雅典", "华沙", "布拉格", "里斯本", "开罗", "伊斯坦布尔", "孟买", "新德里", "吉隆坡",
    "雅加达", "马尼拉", "胡志明市", "河内", "大阪", "京都", "圣保罗", "墨西哥城",
    "布宜诺斯艾利斯", "约翰内斯堡",
}

-- UTF-8 百分号编码：把中文城市名安全放进 URL 查询参数
local function urlEncode(s)
    if not s then return "" end
    s = tostring(s)
    local out = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
            or b == 45 or b == 46 or b == 95 or b == 126 then
            out[#out + 1] = string.char(b)
        else
            out[#out + 1] = string.format("%%%02X", b)
        end
    end
    return table.concat(out)
end

function DashWallpaper:init()
    self.walls = {}
    self.settings = LuaSettings:open(DataStorage:getDataDir() .. "/" .. SETTINGS_FILE)
    self.my_city = self.settings:readSetting("my_city") or "上海"

    -- 每日自动更新的配置（首次运行默认开启，早上 6 点后第一次联网时补做）
    self.auto_enabled = self.settings:readSetting("auto_enabled")
    if self.auto_enabled == nil then self.auto_enabled = true end
    self.auto_hour = tonumber(self.settings:readSetting("auto_hour")) or 6
    self.auto_index = tonumber(self.settings:readSetting("auto_index")) or 1
    self.last_auto_date = self.settings:readSetting("last_auto_date") or ""
    self.last_auto_status = self.settings:readSetting("last_auto_status") or ""

    -- 设置读写整体包一层 pcall：即便存档损坏，也不会让插件在加载期崩溃、从菜单消失
    local ok = pcall(function()
        local walls = self.settings:readSetting("walls")
        if type(walls) ~= "table" then walls = {} end

        -- 内置源随插件升级自动补齐 / 升级 URL（按名称对齐，避免重复）：
        -- 名称不存在 -> 新增；名称存在但 URL 变了 -> 升级 URL。
        -- 仅当已记录的版本号低于当前版本才执行，避免每次启动都写盘、保留用户增删。
        local cur = tonumber(self.settings:readSetting("defaults_version")) or 0
        if cur < DEFAULTS_VERSION then
            for _, d in ipairs(DEFAULT_WALLS) do
                local found = false
                for _, w in ipairs(walls) do
                    if type(w) == "table" and w.name == d.name then
                        if w.url ~= d.url then w.url = d.url end
                        found = true
                        break
                    end
                end
                if not found then
                    walls[#walls + 1] = { name = d.name, url = d.url }
                end
            end
            self.settings:saveSetting("walls", walls)
            self.settings:saveSetting("defaults_version", DEFAULTS_VERSION)
            self.settings:flush()
        end

        local loaded = self.settings:readSetting("walls")
        if type(loaded) == "table" then self.walls = loaded end
    end)

    if not ok then
        -- 存档异常时回退到内置三源，保证插件一定可用、不消失
        self.walls = {
            { name = DEFAULT_WALLS[1].name, url = DEFAULT_WALLS[1].url },
            { name = DEFAULT_WALLS[2].name, url = DEFAULT_WALLS[2].url },
            { name = DEFAULT_WALLS[3].name, url = DEFAULT_WALLS[3].url },
        }
    end

    -- 启动每日自动更新的轮询链：包 pcall，任何异常都不能影响插件加载、菜单注册
    pcall(function() self:autoSchedule(8) end)

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
    -- 菜单按「功能类别」分组，避免十几项混在一屏、分不清用途：
    --   看板壁纸源     = 有哪些看板壁纸 + 点「应用」下载 / 长按删除 / 导入
    --   我的城市       = 壁纸天气按哪个城市
    --   每日自动更新   = 自动下载的开关 / 时间 / 来源 / 状态
    --   使用说明       = 帮助
    -- 分类用 KOReader 原生子菜单实现；会变的值一律 text_func（菜单项表只构建一次并缓存）。
    local t = {}

    -- 组 1：看板壁纸源
    local ws = {}
    if #self.walls == 0 then
        ws[#ws + 1] = { text = "（暂无壁纸源，请先导入）", enabled = false }
    end
    for i, w in ipairs(self.walls) do
        ws[#ws + 1] = {
            text = "应用：" .. w.name,
            callback = function()
                self:applyWall(w)
            end,
            hold_callback = function()
                self:confirmDelete(i, w.name)
            end,
        }
    end
    ws[#ws + 1] = { text = "从文件导入（dashwall_sources.txt）", callback = function() self:addFromFile() end }
    t[#t + 1] = {
        text_func = function()
            return "看板壁纸源：" .. #self.walls .. " 张"
        end,
        sub_item_table = ws,
    }

    -- 组 2：我的城市（壁纸上的天气按该城市显示）
    local ct = {}
    ct[#ct + 1] = {
        text = "恢复默认（上海）",
        callback = function()
            self.my_city = "上海"
            self.settings:saveSetting("my_city", "上海")
            self.settings:flush()
            local top = UIManager:getTopmostVisibleWidget()
            if top then UIManager:close(top, "flashui") end
            UIManager:show(InfoMessage:new{ text = "已恢复默认城市：上海" })
        end,
    }
    for _, c in ipairs(CITY_CHOICES) do
        ct[#ct + 1] = {
            text_func = function()
                return c
            end,
            callback = function()
                self.my_city = c
                self.settings:saveSetting("my_city", c)
                self.settings:flush()
                local top = UIManager:getTopmostVisibleWidget()
                if top then UIManager:close(top, "flashui") end
                UIManager:show(InfoMessage:new{
                    text = "已设置城市：「" .. c .. "」\n下次应用壁纸时生效（天气按该城市）。",
                })
            end,
        }
    end
    t[#t + 1] = {
        text_func = function()
            return "我的城市：" .. self.my_city
        end,
        sub_item_table = ct,
    }

    -- 组 3：每日自动更新
    local ut = {}
    ut[#ut + 1] = {
        text_func = function()
            return "每日自动更新：" .. (self.auto_enabled and "开" or "关")
        end,
        callback = function()
            self.auto_enabled = not self.auto_enabled
            self.settings:saveSetting("auto_enabled", self.auto_enabled)
            self.settings:flush()
        end,
    }
    local ht = {}
    for _, h in ipairs(AUTO_HOURS) do
        ht[#ht + 1] = {
            text_func = function()
                return string.format("%02d:00", h)
            end,
            callback = function()
                self.auto_hour = h
                self.settings:saveSetting("auto_hour", h)
                self.settings:flush()
            end,
        }
    end
    ut[#ut + 1] = {
        text_func = function()
            return "更新时间：" .. string.format("%02d:00", self.auto_hour) .. " 之后"
        end,
        sub_item_table = ht,
    }
    local asrc = {}
    if #self.walls == 0 then
        asrc[#asrc + 1] = { text = "（暂无壁纸源，请先导入）", enabled = false }
    end
    for i, w in ipairs(self.walls) do
        asrc[#asrc + 1] = {
            text = w.name,
            callback = function()
                self.auto_index = i
                self.settings:saveSetting("auto_index", i)
                self.settings:flush()
            end,
        }
    end
    ut[#ut + 1] = {
        text_func = function()
            local w = self.walls[self.auto_index] or self.walls[1]
            return "自动更新源：" .. (w and w.name or "未设置")
        end,
        sub_item_table = asrc,
    }
    ut[#ut + 1] = {
        text = "上次更新状态",
        text_func = function()
            return "上次更新：" .. (self.last_auto_status ~= "" and self.last_auto_status or "尚未执行")
        end,
        callback = function()
            local w = self.walls[self.auto_index] or self.walls[1]
            UIManager:show(InfoMessage:new{
                text = "上次自动更新：" .. (self.last_auto_status ~= "" and self.last_auto_status or "尚未执行")
                    .. "\n今天：" .. os.date("%Y-%m-%d %H:%M")
                    .. "\n更新源：" .. (w and w.name or "未设置")
                    .. "\n\n说明：Kindle 休眠时程序不运行，"
                    .. "\n所以采用「唤醒后 / 休眠前 / 前台每 30 分钟」\n三处补做，保证每天至少更新一次。",
            })
        end,
    }
    ut[#ut + 1] = {
        text = "立即更新一次",
        callback = function()
            UIManager:show(InfoMessage:new{ text = "正在下载当日壁纸…" })
            UIManager:scheduleIn(0.1, function()
                self:runAutoUpdate(true)
                UIManager:show(InfoMessage:new{
                    text = "已执行。结果：" .. (self.last_auto_status ~= "" and self.last_auto_status or "未知"),
                })
            end)
        end,
    }
    t[#t + 1] = {
        text_func = function()
            return "每日自动更新：" .. (self.auto_enabled and "开" or "关")
        end,
        sub_item_table = ut,
    }

    -- 组 4：使用说明
    t[#t + 1] = {
        text = "使用说明",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = "- 看板壁纸源：点「应用」即下载到屏保目录，让 Kindle 进入休眠即可看到\n"
                    .. "- 内置「肿瘤新药」「豆瓣影视新书」「微信读书榜单」三张壁纸\n"
                    .. "- 天气按「我的城市」显示（默认上海，含中国及世界 90+ 城市）\n"
                    .. "- 每日自动更新：默认开启，在设定时刻之后自动下载一次，\n"
                    .. "  触发时机为「启动后 / 唤醒后 / 休眠前 / 前台每 30 分钟」，\n"
                    .. "  保证每天至少更新一次（Kindle 休眠时程序不运行，故为补做机制）\n"
                    .. "- 长按壁纸名称：删除该壁纸源\n"
                    .. "- 新增壁纸源：电脑写好 dashwall_sources.txt（每行 名称<TAB>壁纸URL），\n"
                    .. "  推到 KOReader 数据目录后点「看板壁纸源 -> 从文件导入」\n\n"
                    .. "（本插件只下载写入、不解码图片，故不会像图片模式那样崩出。）\n"
                    .. "若屏保不显示，请在 KOReader 设置里把屏保目录指向写入的路径。",
            })
        end,
    }
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
        -- 探测写入整体包 pcall：即便某个路径不可写或 os.remove 失败，也不影响插件
        local ok, f = pcall(function() return io.open(c .. "/.dashwall_probe", "w") end)
        if ok and f then
            pcall(function() f:close() end)
            pcall(function() os.remove(c .. "/.dashwall_probe") end)
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

-- 给壁纸 URL 追加所选城市参数（服务端按城市名取天气，绕开 IP 反代问题）
function DashWallpaper:withCity(url)
    local city = self.my_city
    if not city or city == "" then city = "上海" end
    local sep = url:find("%?") and "&" or "?"
    return url .. sep .. "city=" .. urlEncode(city)
end

-- 「我的城市」选择已改为主菜单原生子菜单（见 buildSubmenu 的 sub_item_table），
-- 不再用 show(Menu) 弹独立菜单，避免在主菜单（TouchMenu）上下文里崩溃。
-- 城市列表与当前选中项在 buildSubmenu() 里动态生成。

-- 下载并校验：是合法 PNG 才返回字节，否则返回 nil
function DashWallpaper:downloadPng(url, timeout)
    http.TIMEOUT = timeout or 60
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

-- 纯逻辑：下载并写盘，不弹任何提示。返回 ok, 说明
function DashWallpaper:downloadAndSave(w, timeout)
    local raw, used = nil, nil
    for _, u in ipairs(self:candidateUrls(self:withCity(w.url))) do
        raw = self:downloadPng(u, timeout)
        if raw then used = u; break end
    end
    if not raw then
        return false, "下载失败（可能无网络或壁纸未生成）"
    end
    local dir = self:findScreensaverDir()
    local out = dir .. "/dashwallpaper.png"
    local f = io.open(out, "wb")
    if not f then
        return false, "无法写入屏保目录: " .. dir
    end
    f:write(raw)
    f:close()
    local note = ""
    if used and used:match("digest%.png$") then note = "（用 digest.png 预览）" end
    return true, out .. note
end

-- 下载壁纸 PNG 并写入屏保目录（全程不解码图片，绝不触发 imagewidget 崩溃）
function DashWallpaper:applyWall(w)
    UIManager:show(InfoMessage:new{ text = "正在下载壁纸: " .. w.name })
    -- 让提示先渲染出来，再开始阻塞式下载
    UIManager:scheduleIn(0.1, function()
        local ok, msg = self:downloadAndSave(w)
        if not ok then
            UIManager:show(InfoMessage:new{
                text = msg .. "。\n请确认已联网，并等待每日自动部署生成壁纸。\n"
                    .. "（也可先用「看板查看器」确认网络正常。）",
            })
            return
        end
        local note = msg:match("（用 digest%.png 预览）") or ""
        UIManager:show(InfoMessage:new{
            text = "已应用壁纸：「" .. w.name .. "」\n保存到：" .. (msg:gsub("（用 digest%.png 预览）", "")) .. note
                .. "\n\n让 Kindle 进入休眠即可看到。\n（若屏保不显示，请在 KOReader 设置里把屏保目录指向该路径。）",
        })
    end)
end

-- 网络是否可用：取不到 NetworkMgr 或拿不到明确结论时，返回 true 交由下载本身兜底
function DashWallpaper:networkReady()
    local ok, mgr = pcall(function() return require("ui/network/manager") end)
    if not ok or not mgr then return true end
    local st, r = pcall(function()
        if mgr.isOnline and mgr:isOnline() then return true end
        if mgr.isWifiOn and mgr:isWifiOn() then return true end
        if mgr.isConnected and mgr:isConnected() then return true end
        return false
    end)
    if not st then return true end
    return r
end

-- 是否该执行今天的自动更新：开关开 + 今天没做过 + 当前已过设定时刻
function DashWallpaper:shouldAutoRun()
    if not self.auto_enabled then return false end
    local today = os.date("%Y-%m-%d")
    if self.last_auto_date == today then return false end
    local hh = tonumber(os.date("%H")) or 0
    if hh < (tonumber(self.auto_hour) or 6) then return false end
    return true
end

-- 执行一次自动更新（静默，不弹窗打扰）。返回是否真的执行了
function DashWallpaper:runAutoUpdate(force)
    local ok, ran = pcall(function()
        if not force and not self:shouldAutoRun() then return false end
        if not self:networkReady() then
            self.last_auto_status = "待联网（" .. os.date("%m-%d %H:%M") .. "）"
            self.settings:saveSetting("last_auto_status", self.last_auto_status)
            self.settings:flush()
            return false
        end
        local idx = tonumber(self.auto_index) or 1
        local w = self.walls[idx] or self.walls[1]
        if not w then return false end

        -- 先记日期再下载：避免下载卡住时反复重试
        local today = os.date("%Y-%m-%d")
        self.last_auto_date = today
        self.settings:saveSetting("last_auto_date", today)

        -- 休眠前补做时不能卡太久，用较短超时
        local ok_dl, msg = self:downloadAndSave(w, 10)
        if ok_dl then
            self.last_auto_status = "成功 " .. os.date("%m-%d %H:%M")
        else
            -- 失败：清掉日期，30 分钟后再试（当天仍会补做）
            self.last_auto_date = ""
            self.settings:saveSetting("last_auto_date", "")
            self.last_auto_status = "失败 " .. os.date("%m-%d %H:%M") .. "（稍后重试）"
        end
        self.settings:saveSetting("last_auto_status", self.last_auto_status)
        self.settings:flush()
        return true
    end)
    if not ok then
        -- 出错详情保留前 60 字符，方便在菜单「上次更新」里直接看到原因
        local detail = tostring(ran or "?")
        if #detail > 60 then detail = detail:sub(1, 60) .. "…" end
        self.last_auto_status = "异常：" .. detail .. " " .. os.date("%m-%d %H:%M")
        pcall(function()
            self.settings:saveSetting("last_auto_status", self.last_auto_status)
            self.settings:flush()
        end)
        return false
    end
    return ran
end

-- 定时轮询：每 AUTO_CHECK_SECONDS 检查一次，跨过午夜后自动补做
function DashWallpaper:autoSchedule(delay)
    UIManager:scheduleIn(delay or AUTO_CHECK_SECONDS, function()
        self:runAutoUpdate(false)
        self:autoSchedule(AUTO_CHECK_SECONDS)
    end)
end

-- 从休眠唤醒 / 解锁时补做（Kindle 挂起期间 Lua 不运行，只能唤醒后补）
function DashWallpaper:onResume()
    UIManager:scheduleIn(3, function() self:runAutoUpdate(false) end)
    return false
end

-- 进入休眠前先补做一次：保证"本次休眠"屏保就是当天最新的
function DashWallpaper:onSuspend()
    pcall(function() self:runAutoUpdate(false) end)
    return false
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
