---
name: l4d2-meatwall-hulk
description: 肉山(创意工坊3544093341)分发测试结论:客户端模型预加载死结 + 全部无效方案 + 已放弃部署
metadata: 
  node_type: memory
  type: project
  originSessionId: 78eaa137-f49f-4daf-a707-b9ee52d04853
  modified: 2026-08-02T02:22:08.902Z
---

# L4D2 肉山(Meatwall)分发测试结论(2026-08-01)

创意工坊 3544093341(肉山,废弃内容 Boss)。目标:纯服务端部署、客户端零操作、概率替换部分 Tank(可共存)。**最终结论:放弃部署。** 快网玩家可行(实测闭环),慢网/中途加入玩家被引擎机制锁死,服务端无解。

## 核心死结(放弃原因)

**客户端模型预加载机制**:连接时服务器同步 precache 表 → 客户端立即预加载表内模型 → 本地无文件 → 加载失败 → **进程级失败缓存,本局/本会话不可逆**(重启游戏才能清)。下载晚于进游戏 = 永久 ERROR,任何服务端手段都无法让慢网玩家正确显示。引擎无"推迟 putin"API、无下载完成事件。

## 全部尝试过的方案

1. **host_workshop_collection**:L4D2 不支持(CS:GO/GMod 命令),日志 `Unknown command`。服务器无法推 VPK 给客户端,addons/workshop 仅服务端自用 → 集合分发作废
2. **散文件覆盖 vscript**:scripts/vscripts/ 散文件与 VPK 内同名 vscript **同时加载、无优先级覆盖** → 必须重打包 VPK 才有效
3. **防火墙外部拦截连接**:死锁——客户端从服务器握手获知 fastdl URL,阻断连接 = 阻断下载源头
4. **kick-重连方案**(nginx 日志检测下载完成 → 踢 → 重连秒进):技术上可行但实现复杂,用户否决
5. 影子实体(transmit 过滤):复杂度高,未实现

## 已验证可行的部分(快网玩家)

- 服务器 VPK 自用 + fastdl 散文件 + **延迟换模型**:OnMapStart 只 AddFileToDownloadsTable 不 precache;坦克刷新保持默认模型,延迟 20s(客户端已下完)再 PrecacheModel + SetEntityModel → 成功
- vscript 里 round_start 的 PrecacheModel/PrecacheSound 是客户端首连失败元凶 → 重打包 VPK 剥离后消除
- **音效 vs 模型差异**:音效按需加载(播放时才读)、失败不缓存、自动重试 → 晚下载无感(击杀音效系统正常的原因);模型预加载+永久失败缓存 → 晚下载=ERROR。见 [[l4d2-sound-cache-pitfall]] [[l4d2-precachescriptsound-broken]]
- 下载瓶颈:17MB 音效拖慢下载(总量 35MB),去音效后 19MB

## 未解决的死结

- **慢网玩家**:下载 > 地图加载时间 → 预加载必失败,会话不可逆
- **中途加入玩家**:本局已转换过 → precache 表已污染 → 其会话内任何肉山 ERROR,服务器无解

## 工具与坑

- VPK v1 格式:12 字节头(magic 0x55aa1234 + version + tree_size)+ tree(字符串 + 18 字节条目 CRC32/smallSize/archIdx/offset/length/0xFFFF)+ 数据区(offset 相对数据区起点);脚本 /tmp/vpk_pack.py、/tmp/vpk_extract.py
- steamcmd 下载创意工坊 → ~/Steam/steamapps/workshop/content/550/<id>/ 下是 `xxx_legacy.bin`(35527450 字节)
- 编译用 spcomp64(非 spcomp);SourcePawn 不支持 `char[][] = {...}` 初始化(error 047/163),逐个 AddFileToDownloadsTable

## 现场状态(2026-08-01)

- hulk_test.sp 留在 /home/ubuntu/hulk_test.sp(hulk_chance/hulk_delay/hulk_health,概率 10% + 20s 保护窗口 + 共存)
- 测试服 l4d2-hulk-test 已停,主服 l4d2-server 已恢复
- fastdl 散文件仍在 /opt/gameservers/l4d2/data/(models 253M/materials 927M/sound 246M, 2026-08-02 确认)——与三方图模型混存（models 里有地图目录名如 bcn/bd 等），无法自动区分肉山专属文件；清理需用户指定肉山模型目录名
