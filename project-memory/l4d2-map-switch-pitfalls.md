---
name: l4d2-map-switch-pitfalls
description: 三方图切换系统性缺陷——残留 .nuc、vscripts 漏拷、melee 漏拷、无验证、cp 追加不替换
metadata: 
  node_type: memory
  type: reference
  tags: 
    - l4d2
    - maps
    - pitfall
    - scripts
    - switching
  originSessionId: b9b6dac1-f58d-4856-8419-3bbadd708f38
---

# L4D2 三方图切换系统性缺陷

## 踩坑实录

### 2026-07-19 增城切换事故

从 tumtara 切增城时发现：

**残留文件（没清干净）**：
- `scripts/vscripts/coop.nuc` — tumtara 编译缓存
- `scripts/vscripts/versus.nuc` — tumtara 编译缓存
- `scripts/vscripts/tumtara_infected_precache.nut`
- `scripts/vscripts/tumtara_infotext.nut`
- `scripts/vscripts/tumtara_items.nut`

**漏拷文件（没复全）**：
- `scripts/vscripts/f5.nut` — 漏拷
- `scripts/vscripts/fenwei.nut` — 漏拷
- `scripts/vscripts/m4final.nut` — 漏拷
- 等共 8 个 vscripts 文件
- `scripts/melee/` 整个目录漏拷（9 个 txt）

**根因**：手动 `cp -r .../scripts/*` 不可靠 + 没有清理步骤 + 没有验证步骤。

## 七个系统性缺陷

### 1. 只追加不替换

`cp -r` 往目标目录添加文件，永远不会删除已有文件。切一次图多一层残留，三次图 scripts/ 成混合垃圾场。`.nuc` 尤其阴险——引擎优先加载编译缓存，导致跑着新图 BSP 却执行旧图脚本。

### 2. 没有验证步骤

以前的流程：拷 BSP → 拷 missions → 拷 scripts → 完成。从来没有任何 diff、文件计数、日志检查。人眼没法从 50+ 个 .nut 里发现少了 8 个。

### 3. BSP 是焦点，scripts 是盲区

注意力全在 BSP（图能不能加载）和 missions（战役定义对不对），scripts 被当成"拷过去就行"的配角。但 vscripts 承载地图自定义逻辑——触发器、武器生成、特殊事件——缺一个 nut 文件就静默失效，不报错。

### 4. 脚本目录结构不统一

不同三方图的 scripts 目录结构各异：
- 有的只有 `vscripts/*.nut`
- 有的还有 `melee/`、`sounds/` 等子目录
- nuc 编译缓存在不同位置

`cp -r` 只能"追加"，不能"替换"，旧文件永远留在目标目录。

### 5. mission 文件 VDF 格式错误 → 假图

**2026-07-19 天梯2 事故**：`tianti2.txt` 中 `"Map""hls_10"` 缺少键值间的空格，VDF 解析器静默跳过所有 Map 条目。服务器显示 `map: hls_10`，实际没有可加载的关卡 → 客户端连接不上，表现为"假图"。

- **根因**：从 VPK 提取的 missions 文件可能有格式问题（制作者疏忽），没有验证 VDF 语法就直接用
- **症状**：`status` 显示地图名正常，BSP 存在，但客户端无法连接
- **修复**：`"Map""hls_10"` → `"Map" "hls_10"`

**脚本需增加**：切换前用 `grep -P '"Map""' missions/*.txt` 检查格式错误。

### 6. 多次 sm_map 后 String Table 损坏 → 客户端连不上

**2026-07-19 Dark Wood / 天梯2 事故**：连续多次 `sm_map` 切换官图↔三方图后，引擎日志出现 `String Table dictionary for downloadables should be rebuilt, only found 37 of 46 strings in dictionary`。服务器表面正常（map 正确、端口监听），但所有客户端无法连接——表现为进度条卡住或超时。

- **根因**：Source 引擎内部维护一个"可下载资源字符串表"（downloadables string table），每次 `sm_map` 追加条目但不释放。多次跨图切换后表膨胀错乱，新客户端连接时校验失败
- **症状**：`status` 正常，BSP 存在，无 crash，但客户端连不上（和缺陷 #5 表现相同，根因不同）
- **修复**：`docker restart l4d2-server`（不是 down+up），容器重启后引擎重建 String Table 从干净状态开始

**⚠️ 铁律更新**：换图永不用重启容器 —— 但连续切换 ≥3 次三方图后，必须 `docker restart` 重建 String Table。restart ≠ down+up（不重建容器，只重启进程）。

### 7. 有自定义资源的地图不放 VPK → PrecacheModel 静默失败

**2026-07-19 Dark Wood 事故**：服务端只放 BSP+scripts，不放 VPK。Dark Wood 有 2743 个模型 + 1967 个贴图 + 123 个音效，vscripts 中 `PrecacheModel("models/darkwood/dw_staircase01.mdl")` 在服务端找不到文件 → 静默失败 → 引擎不告诉客户端加载这些模型 → 客户端贴图/模型/碰撞全没，楼梯上不去，卡出地图。

- **根因**："服务端不放 VPK"规则被一刀切应用。该规则本意是避免与**工坊 VPK** 版本冲突，但对**非工坊地图**，服务端没有 VPK 就无法 precache 自定义资源
- **辨别方法**：看 VPK 里有没有 `models/`、`materials/`、`sound/` 目录。增城没有（纯脚本逻辑），所以不带 VPK 也能跑。Dark Wood / Dead City / Dear Esther 有大量自定义资源，必须服务端放 VPK
- **修复**：把 VPK 放进 `addons/`，重启容器

**修正后的规则**：
| 地图类型 | 服务端 VPK | 原因 |
|---------|-----------|------|
| 工坊地图（天梯、TUMTaRA） | 不放 | 避免与客户端工坊版本冲突 |
| 非工坊 + 无自定义模型/贴图（增城） | 不放 | 不需要 precache |
| 非工坊 + **有**自定义模型/贴图（Dark Wood） | **必须放** | vscripts PrecacheModel 需要 |

## 关联

**一键脚本** `/home/ubuntu/l4d2-switch-map.sh`：

```bash
/home/ubuntu/l4d2-switch-map.sh --list          # 列出可用地图
/home/ubuntu/l4d2-switch-map.sh gzzc             # 清理→复制→验证→输出 RCON 命令
/home/ubuntu/l4d2-switch-map.sh gzzc --dry-run   # 预览不执行
```

脚本保证四个闭环：
1. **清理** — missions/ 全清 + scripts/vscripts,melee,sounds 全清 + .nuc 全局删除
2. **复制** — find -print0 逐个文件复制，不做 glob 展开
3. **验证** — diff 对比源和目标，缺文件立即报错退出
4. **输出** — 自动提取第一关地图名生成 RCON 命令

## 为什么不用脚本就要出事

- 手动敲命令很容易忘记清理 scripts/melee/（增城有 9 个 melee 文件）
- 手动 `cp -r dir/*` 不保证完整覆盖嵌套结构
- 没人会手动做 diff 验证
- .nuc 残留肉眼不可见（需要 find 才能发现）
- missions/ 残留旧 txt 会导致战役冲突

## 关联

- [[l4d2-howto-thirdparty-maps]] — 已重写为 VPK 直接放 addons 方案
- [[l4d2-deployment-rules]] — 铁律清单

## 最终结论（2026-07-19）

所有七个坑的根因是同一个：**"提取 BSP 放服务端"这个方案本身就是错的。**

正常 L4D2 开服从来不需要提取 BSP——VPK 丢 addons，引擎自己加载一切。铁律 #2 早就写了"禁止拆包"。我们三个月来维护的提取/清理/验证流程，是在用一个复杂系统解决一个不该存在的问题。

新方案：VPK 放 addons，切换就是 `sm_map`。不再有漏拷、残留、格式错误、PrecacheModel 失败。和本地开服一样简单。
