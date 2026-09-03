# DashWallpaper（看板壁纸 · KOReader 插件）

把任意「看板壁纸」PNG 下载并应用到 KOReader 屏保目录，让 Kindle / Kobo 在休眠时显示看板内容（肿瘤新药动态、豆瓣影视新书等）。

> 本插件是 [onco_tracker](https://github.com/) 项目的一个独立组件，可单独安装使用。

## 核心设计：只下载、不解码

定制版 KOReader（如部分 Paperwhite / MiuRead 固件）在 Lua 层用 `ImageViewer` 渲染 PNG 时会直接崩出
（`imagewidget.lua:264 cannot render image`）。本插件刻意避开这个雷区：

- **绝不解码、绝不显示任何图片**——只做两件事：`HTTP 拉取字节` → `校验是合法 PNG` → `写入屏保目录`；
- 全程不触发图片解码，因此不会让 KOReader 崩溃；
- 屏保图片由 KOReader 自身的帧缓冲显示，与 Lua 的 ImageViewer 无关（已验证可用）。

## 安装

1. 下载仓库里的 `DashWallpaper.koplugin` 文件夹；
2. 复制到 KOReader 插件目录：
   - Kindle：`/mnt/us/koreader/plugins/`
   - Kobo：`/.adds/koreader/plugins/`
3. 重启 KOReader，「更多工具」菜单里会出现「看板壁纸」（阅读界面顶部菜单同样有）。

## 使用

「更多工具 → 看板壁纸」的菜单按**功能分类**为四组，不会十几项混在一起分不清用途：

```
看板壁纸源：3 张    ← 点进去：三张内置壁纸，点「应用：XX」下载到屏保目录
                     （长按源名=删除该源；底部有「从文件导入」）
我的城市：上海      ← 点进去：一键切换壁纸天气城市（含世界 90+ 城市）
每日自动更新：开     ← 点进去：开关 / 更新时间 / 自动更新源 / 上次更新 / 立即更新一次
使用说明
```

简单三步上手：

1. 点「看板壁纸源」→「应用：肿瘤新药动态 · 壁纸」→ 插件下载并写入屏保目录；
2. 让设备进入**休眠**，即可看到该看板壁纸；
3. 之后交给「每日自动更新」（默认开启）即可，不用再手动点。

若屏保不显示，请在 KOReader「设置 → 屏幕 → 睡眠屏幕 → 壁纸」里把图片文件夹指向插件写入的路径
（默认写入 `<数据目录>/screensaver/dashwallpaper.png`）。

> 为什么不用图标？Kindle 定制版固件的字体不含彩色 emoji，图标会渲染成问号，
> 因此所有菜单项均为纯文字。

## 开箱即用的内置壁纸源

默认已带三个源（来自作者每日自动部署的云端看板，均带当地天气）：

- **肿瘤新药动态 · 壁纸**
- **豆瓣影视新书 · 壁纸**
- **微信读书榜单 · 壁纸**

> 这些 URL 指向作者本人的 WorkBuddy 公网链接，公开无害；你也可以随时长按删除、再导入自己的壁纸地址。

### 天气按「我的城市」显示（默认上海）

壁纸上的天气由云端按**城市名**现场渲染——**不是按请求 IP**（经 WorkBuddy 反代后服务端看到的 IP 是代理出口，定位会偏到北京等错误位置）。

插件内置「我的城市」设置，默认 **上海**；点主菜单「我的城市」进入子菜单，可一键切换到北京、广州、东京、纽约、伦敦等 **90+ 中国及世界主要城市**，切换后下次应用壁纸即生效。

## 每日自动更新

默认**开启**：每天在设定时刻（默认 **06:00**）之后，自动下载一次壁纸并写入屏保目录，无需手动点。

入口：主菜单「每日自动更新」，子菜单内容：

| 子菜单项 | 说明 |
| --- | --- |
| `每日自动更新：开/关` | 点击切换开关 |
| `更新时间：06:00 之后` | 再点进去选整点（0/5/6/7/8/9/12/18/21/23） |
| `自动更新源：…` | 再点进去选要自动下载哪一张壁纸 |
| `上次更新：…` | 点击查看状态（成功 / 失败 / 待联网 / 异常原因） |
| `立即更新一次` | 不等定时，立刻下载一次 |

### 为什么是「补做」而不是严格的定时任务

Kindle 休眠时 KOReader 的 Lua 解释器会随系统挂起**完全停止运行**，任何 `scheduleIn` 定时器都不会在休眠期间触发。
真正可靠的做法是**在能运行的所有时机检查日期，缺了就补做**，本插件在四个时机触发：

1. **KOReader 启动后 8 秒**——开机即补；
2. **从休眠唤醒后 3 秒**——拿起设备的第一时间补；
3. **进入休眠前**——保证「本次休眠」屏保就是当天最新图（超时收紧到 10 秒，不拖慢休眠）；
4. **前台每 30 分钟轮询**——长时间连续使用时跨过午夜也能补做。

判定条件是「开关开 + 当天还没成功做过 + 当前已过设定时刻」，三者都满足才下载，所以**一天最多一次**，不会反复刷流量。
下载失败会清空当天标记，等下一个时机自动重试；状态（含异常原因前 60 字符）可在「📌 上次更新」里直接看到。

自动更新**全程静默**，不弹任何提示，不打断阅读。

## 自定义壁纸源

在电脑上新建 `dashwall_sources.txt`，每行一条：

```
名称<TAB>壁纸URL
```

例如：

```
我的基金看板	https://example.com/wallpaper.png
读书进度	https://example.com/digest.png
```

把文件推到 KOReader 数据目录后，进插件点「看板壁纸源 → 从文件导入」即可（完全不依赖屏幕键盘，避免软键盘遮挡卡死）。

> 地址既可是 `wallpaper.png`，也可直接是 `digest.png` 之类的纯预览图——插件会优先尝试 `wallpaper.png`，缺失时自动回退同目录的 `digest.png`。

## 目录结构

```
DashWallpaper/
├── DashWallpaper.koplugin/   # 插件本体（放进 KOReader 的 plugins/ 目录）
│   ├── _meta.lua             # 插件元信息（名称/版本/描述）
│   └── main.lua              # 插件逻辑
├── README.md
├── LICENSE
└── .gitignore
```

## 开发：改完 Lua 怎么自检

没有 Lua 解释器也能在本地校验，工具在 `kindle/tools/`（Node 环境）：

```bash
# 1) 语法解析（按 Lua 5.1，KOReader 用 LuaJIT）
NODE_PATH=<node workspace>/node_modules node tools/_lua_syntax_check.js DashWallpaper.koplugin/main.lua

# 2) 逻辑冒烟（用 fengari Lua VM 加载真实文件，mock 掉 KOReader 环境，
#    验证自动更新状态机 / 菜单 text_func / 城市切换 / 写盘）
NODE_PATH=<node workspace>/node_modules node tools/_smoke_test_wallpaper.js
```

依赖 `luaparse` 与 `fengari`，装在隔离目录里：`npm install luaparse fengari`。

## 兼容性

- 仅依赖 KOReader 内置的 `socket.http` / `ltn12` / `LuaSettings` / `DataStorage`，无外部依赖；
- `ltn12` 引入路径在不同 KOReader 版本略有差异，已做兜底；
- 界面文字为硬编码中文（KOReader 全局 `_` 是数值，`_()` 会崩溃，故未用 gettext）。

## License

MIT —— 见 [LICENSE](LICENSE)。
