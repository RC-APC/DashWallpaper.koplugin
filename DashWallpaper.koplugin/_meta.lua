--[[--
_Meta 信息：KOReader 加载插件时读取此文件。
重要：本设备（定制版 MiuRead）的 require("gettext") 不可用（无 .gettext），
因此绝不能使用 _( "..." ) 翻译调用，否则插件加载期直接崩溃、从菜单消失。
这里直接 return 一个 table（现代 KOReader 契约），全部用纯字符串。
--]]--
return {
    name = "DashViewer",
    fullname = "DashViewer 看板查看器",
    description = "在 KOReader 内查看多个云端看板的纯文本摘要。数据源可自由添加 / 删除，适用于任意「产出纯文本的看板」。",
    version = "1.0.0",
    min_api_version = "1.0.0",
}
