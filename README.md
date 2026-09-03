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

1. 点「应用：XX 壁纸」→ 插件下载该壁纸并写入屏保目录；
2. 让设备进入**休眠**，即可看到该看板壁纸；
3. 长按壁纸名称 → 删除该壁纸源；
4. 点「📄 从文件导入（dashwall_sources.txt）」→ 批量添加自定义壁纸源。

若屏保不显示，请在 KOReader「设置 → 屏幕 → 睡眠屏幕 → 壁纸」里把图片文件夹指向插件写入的路径
（默认写入 `<数据目录>/screensaver/dashwallpaper.png`）。

## 开箱即用的内置壁纸源

默认已带三个源（来自作者每日自动部署的云端看板，均带当地天气）：

- **肿瘤新药动态 · 壁纸**
- **豆瓣影视新书 · 壁纸**
- **微信读书榜单 · 壁纸**

> 这些 URL 指向作者本人的 WorkBuddy 公网链接，公开无害；你也可以随时长按删除、再导入自己的壁纸地址。

### 天气按「我的城市」显示（默认上海）

壁纸上的天气由云端按**城市名**现场渲染——**不是按请求 IP**（经 WorkBuddy 反代后服务端看到的 IP 是代理出口，定位会偏到北京等错误位置）。

插件内置「我的城市」设置，默认 **上海**；在子菜单点「📍 我的城市」可一键切换到北京、广州、东京、纽约、伦敦等 **90+ 中国及世界主要城市**，切换后下次应用壁纸即生效。

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

把文件推到 KOReader 数据目录后，进插件点「从文件导入」即可（完全不依赖屏幕键盘，避免软键盘遮挡卡死）。

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

## 兼容性

- 仅依赖 KOReader 内置的 `socket.http` / `ltn12` / `LuaSettings` / `DataStorage`，无外部依赖；
- `ltn12` 引入路径在不同 KOReader 版本略有差异，已做兜底；
- 界面文字为硬编码中文（KOReader 全局 `_` 是数值，`_()` 会崩溃，故未用 gettext）。

## License

MIT —— 见 [LICENSE](LICENSE)。
