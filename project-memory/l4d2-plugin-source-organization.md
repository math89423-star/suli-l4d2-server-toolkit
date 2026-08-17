---
name: l4d2-plugin-source-organization
description: "插件源码组织决策：scripting/ 保持 SourceMod 平铺布局，不拆\"每插件一文件夹\"；多文件插件（HardSI）用子目录，源码目录不留 .smx"
metadata: 
  node_type: memory
  type: project
  originSessionId: 4203ecd8-3ff3-46b2-89ff-a6d930a85ed1
  modified: 2026-08-03T02:15:59.263Z
---

插件源码组织决策（2026-08-03 讨论定稿）：

- **scripting/ 保持 SourceMod 标准平铺布局**（~70 个 .sp 在根目录 + include/ 全局头文件），**不改成"一个插件一个文件夹"**。原因：compile.sh 批量编译只认根目录 `*.sp`；spcomp include 查找依赖源文件同目录 + 全局 include/，全拆分会导致插件间互相 include 断链；社区插件发布格式就是平铺。
- **多文件插件用子目录是正确例外**：`scripting/AI_HardSI_optimized/`（AI_HardSI.sp + 12 个 bt_*.inc 专属头文件 + hardcoop_util.sp），专属头文件不混入全局 include/。
- **约定：源码目录只放 .sp/.inc，编译产物只输出 `compiled/`，运行版在 `plugins/`**（2026-08-03 已清理源码目录 2 个过期 smx + compiled/AI_HardSI_optimized/ 残留，已写入 PLUGINS.md 注意事项）。
- 自研插件靠 `l4d2_` 前缀 + `addons/sourcemod/PLUGINS.md` 分类清单区分，不靠目录结构。
- 相关：[[l4d2-source-code-location-pitfall]]（git 与 /opt/gameservers 两套文件）
