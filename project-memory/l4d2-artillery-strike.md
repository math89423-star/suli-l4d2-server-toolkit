---
name: l4d2-artillery-strike
description: "火力支援现状（v1.10.0，2026-08-16）：I-绿色雨幕 6500（胆汁+罐双路径）/II-地狱烈火 10000/III-区域轰炸 14500（全榴弹）/IV-AGM导弹 18000（见 l4d2-agm-missile）；v1.10.0 预警 HUD 改游戏内置 Instructor Hint（icon_alert ⚠️ 悬浮落点+边缘指向箭头，替换 PrintHintText）；交互=购买→瞄准→开火确认→8s预警→落罐；头顶隐形实体+高 h 不落地+狭窄长巷等历史坑见下"
metadata:
  node_type: memory
  type: project
  originSessionId: 9497bfe5-ae98-4821-a86e-4b1d5751a883
  modified: 2026-08-16T14:20:00.000Z
---

## v1.10.10 AGM 倒计时从 5 秒开始（2026-08-17，commit 43f9eec，已部署 reload）

**用户最终定稿**："什么都不变，只是把原本的 AGM导弹发射倒计时 8 秒 ->
AGM导弹发射倒计时 5 秒！，从 5 秒倒数，自然结束后，就一直显示 AGM导弹
已发射，注意躲避！直到爆炸"——

- 预警 8 秒、发射音效 remain==3 播放（v1.8.12 设定）**全不动**
- HUD 数字改为 remain-3 映射（remain 8..4 → 显示 5..1）："AGM导弹发射
  倒计时 5 秒！"→4→3→2→1
- 5 秒走完瞬间 = remain==3 = 发射音效响起 = 发射时刻 → 切"AGM导弹已发射，
  注意躲避！"（红图标），**一直显示到爆炸**（T-0 俯冲不再重建，V1_Detonate
  幂等 stop 消退）
- 核心教训：**音效响起=发射=倒计时归零**，绝不出现"音效都响了还提示还有
  3 秒发射"的矛盾（v1.10.9 的 8→1 全程倒计时已推翻）

## v1.10.9 AGM 描述收敛为两类（2026-08-17，commit b278097，已部署 reload）

**用户拍板（重要定稿）**："你一来就直接'AGM导弹发射倒计时X秒'，卡在音效播放时
让X自然变为0，并立即切换到播报'AGM导弹已发射，注意躲避！'爆炸后自然消退
不就行了，因此现在只有两类描述了"——

1. **AGM导弹发射倒计时 X 秒！**（确认后立即显示，X=8→1 全程；发射音效在
   X=3 时响起，不做文案切换，X 自然走完）
2. **AGM导弹已发射，注意躲避！**（T-0 切换，红色 icon_alert_red；超时 =
   俯冲时长+1 + V1_Detonate 幂等 stop 兜底 = 爆炸后自然消退）

废除 v1.10.4/5 的"来袭预警"中间态（那段两段式迭代已全推翻）。非 AGM
（汽油弹/胆汁雨/榴弹雨）保持"X来袭预警 N 秒！"不动。

## v1.10.8 商品名恢复"火力支援X-"前缀（2026-08-17，commit 1b17eed，已部署 reload）

**用户拍板**："火力支援II 火力支援I这个数字前缀描述不要丢"——v1.10.7 直白化
删前缀删过头。最终定稿：**商品名带前缀**（火力支援II-汽油弹 / 火力支援I-
胆汁雨 / 火力支援III-榴弹雨 / 火力支援IV-AGM导弹），**HUD 预警文案不带前缀**
（"汽油弹来袭预警 N 秒！"保持简洁）。classname/kind/价格全不动。

## v1.10.7 商品名与 HUD 名直白化（2026-08-17，commit 3a6c640，已部署 reload）

**用户拍板**："叫胆汁雨，汽油弹，榴弹雨，AGM导弹。并且把商店菜单显示也改改，
去掉文艺描述就直白点，不然路人可能不会轻易尝试"——最终命名定稿：

| kind | classname | 商品名（菜单） | HUD 预警 | HUD 轰炸中 |
|---|---|---|---|---|
| 2 | artillery2 | 汽油弹（10000） | 汽油弹来袭预警 N 秒！ | 汽油弹轰炸进行中！ |
| 3 | artillery3 | 胆汁雨（6500） | 胆汁雨来袭预警 N 秒！ | 胆汁雨轰炸进行中！ |
| 5 | artillery5 | 榴弹雨（14500） | 榴弹雨来袭预警 N 秒！ | 榴弹雨轰炸进行中！ |
| 6 | artillery6 | AGM导弹（18000） | AGM导弹来袭预警 N 秒！→ T-3 起 AGM导弹发射倒计时 | 导弹来袭，正在俯冲！ |

- 商品名去掉"火力支援X-"前缀（分类菜单标题已是"火力支援"，不再冗余）
- Art_KindWarnName 同步（kind 1/4 禁用兜底"空袭"）；AGM T-3 特判文案改用
  kindName 拼（"AGM导弹发射倒计时：%d 秒！"）
- classname/kind/价格/cvar 全不动；外部引用无冲突（loot_drop 的"胆汁罐"是
  掉落表自己的商品名，不动）

## v1.10.6 四种支援 HUD 预警全带名称（2026-08-16，commit 78ab724，已部署 reload）

**用户拍板**："把每一个支援的 hud 都改一下名称，让玩家一眼就能看清是呼叫的
什么支援"——格式统一模仿"导弹来袭预警"：

| kind | 支援 | 预警 HUD | 轰炸开始 HUD |
|---|---|---|---|
| 2 | II-地狱烈火 | 燃烧弹来袭预警 N 秒！ | 燃烧弹轰炸进行中！ |
| 3 | I-绿色雨幕 | 胆汁罐来袭预警 N 秒！ | 胆汁罐轰炸进行中！ |
| 5 | III-区域轰炸 | 榴弹来袭预警 N 秒！ | 榴弹轰炸进行中！ |
| 6 | IV-AGM导弹 | 导弹来袭预警 N 秒！→ T-3 起导弹发射倒计时 | 导弹来袭，正在俯冲！ |

实现：新增 `Art_KindWarnName(kind, buf, size)` 映射（kind 1/4 已禁用兜底
"空袭"）；确认聊天播报同步带名称（"%N 已呼叫燃烧弹火力支援，将在 8 秒后
到来"）；AGM 与非 AGM 倒计时分支重构统一（仅 T-3 起 AGM 特判"发射倒计时"）。

## v1.10.5 AGM 预警期文案带秒数（2026-08-16，commit 56393e3，已部署 reload）

**用户拍板**：预警期文案也要倒计时——T-8~T-4 显示"导弹来袭预警 %d 秒！"
（8→4），T-3 起切"导弹发射倒计时：3/2/1 秒！"（与发射音效同步）。

## v1.10.4 AGM 预警文案与发射音效对齐（2026-08-16，commit 1fc2744，已部署 reload）

**用户拍板**：AGM 发射音效（overpass_jets.wav）在倒计时 **3 秒**时才播放，
"导弹发射倒计时"不该从预警一开始就显示（8s 时导弹根本没发射，用户看到 6s
觉得更不对）。HUD 文案改为：
- **T-8~T-4**：固定"导弹来袭预警！"（黄感叹号）
- **T-3 起**："导弹发射倒计时：3/2/1 秒！"（与音效同步）
- 删除 T-3 的"导弹已发射，正在接近目标！"覆盖（文案已与音效同步）
非 AGM（I/II/III）保持"空袭将在 N 秒后到来"不动。顺带核实服务器实况：
si_hud_art6_warn=8.0、si_hud_art6_dive_time=**1.6**（记忆旧档写 5.0 已过时）。

## v1.10.3 关闭火力支援全部 PrintHintText（2026-08-16，commit 755c064，已部署 reload）

**用户拍板**："既然现在有了新的 hud 就把原来的 printhud 给关闭了"——新 HUD
（instructor hint 感叹号）完全接管屏幕中央。删除瞄准阶段教学提示
（Timer_ArtTeach"[商店] 左键确认轰炸，右键取消" + priming），操作说明并入
购买聊天消息（"已购买 XXX（-N 可用积分）。左键射击确认轰炸，右键取消"）。
火力支援流程 PrintHintText 清零（透视特感商品的 2379/2393 行不动）。
至此火力支援 HUD 全链路 = 游戏内置 instructor hint（⚠️ 感叹号居中倒计时）。

## v1.10.2 修复感叹号堆叠（2026-08-16，commit 769fe52，已部署 reload）

**用户实测**：每过一秒红色感叹号出现一次，旧的不消失、新的被往下挤，一屏堆叠。

**根因**：客户端对重复的 `instructor_server_hint_create` **不自动关旧实例**——
"Serverside Hint" 模板的关闭只认 `instructor_server_hint_stop` 且 hint_name
匹配（close 块 `"string1 is" "string hint_name"`）；每秒只 create 不 stop →
旧实例永不消失。left4dhooks 文档"newest overrides the old"在 L4D2 客户端
实测不成立（v1.10.1 已踩）。

**修复**：`Art_WarnHintShow` 先 `L4D2_StopInstructorHint(同名)` 再 create，
同帧连发无闪烁，屏幕上始终只有一个。教训：**server hint 更新内容必须
stop+create 成对，不能只 create**。

## v1.10.1 预警 HUD 改固定屏幕中央（2026-08-16，commit 6aa950d，已部署 reload）

**用户实测修正**：v1.10.0 的落点锚点方案（info_target + hint_target）实测出现
问题——**背对落点时红色感叹号变成屏幕边缘指向箭头**，用户要求"应该同时只
显示一个，就显示在屏幕中央，把原来的 PrintHud 替换掉"。

**正解**：Instructor Hint 的 flags 带 **STATIC（bit 8）**——instructor_lessons.txt
的 "Serverside Hint" 模板 `"flags has bit" "int 8"` 分支走
`icon_target = player local_player`：提示固定屏幕中央、每玩家各自一个、
无屏幕边缘箭头。改动：`Art_WarnHintShow` target 传 0 + flags =
`L4D2_IHFLAG_STATIC | L4D2_IHFLAG_PULSE_URGENT`；删除 info_target 锚点
实体（g_iArtWarnEntRef）、ART_WARN_HINT_OFFSET。倒计时每秒重建、AGM 俯冲
icon_alert_red、6s 轰炸开始提示、聊天/光圈兜底全部保留。

## v1.10.0 HUD 预警改游戏内置 Instructor Hint（2026-08-16，commit 470848e，已部署 reload）

用户要求："游戏内自带丰富的⚠️预警图标，但我们没用起来，还是呆傻的 PrintHud"——
呼叫支援后的 HUD 提示改用**引擎自带 Instructor Hint 系统**（left4dhooks 封装
`instructor_server_hint_create` 事件，即游戏"按 E 使用/小心！"那套带图标+箭头的
大提示）：

- **图标清单权威源** = `scripts/instructor_lessons.txt`（从 pak01_dir.vpk 解出）：
  `icon_alert`（黄 ⚠️，游戏用于 Notify Pounced/Explain Finale Start 等危险场景）/
  `icon_alert_red`（红紧急，Help Pounced/Explain Panic Button 等）；其余还有
  icon_tip/icon_info/icon_no/icon_shield/icon_medkit 等
- **实现**（l4d2_shop.sp v1.10.0）：
  - 确认后建 `info_target` 锚点实体在落点（`g_iArtWarnEntRef`），倒计时每秒
    `Art_WarnHintShow` 重建 hint（同名单 `l4d2_shop_art_warn` 全服单槽，
    "Serverside Hint" 实例类型 2 = 新者覆盖旧者，无需先 stop）
  - 图标悬浮落点上空 150u（hint_icon_offset）；屏幕外时屏幕边缘自动出指向
    箭头（no_offscreen=false）；force_caption 穿墙可见；PULSE_URGENT 紧急脉动；
    红字 caption
  - AGM 俯冲阶段换 `icon_alert_red` + 超时 = 俯冲时长+1 自动消失；V1_Detonate
    幂等 stop；轰炸开始提示带 6s 超时（不长期占用 hint 单槽）
  - 兜底清理：Timer_ArtNotifyEnd / Art_CleanupAll（换图/卸载）都 Art_WarnHintStop
  - 失败回退：锚点丢失/事件创建失败 → PrintToChatAll 聊天播报，不吞提示
- **局限（已知）**：instructor hint 对**死亡玩家不显示**（Serverside Hint 模板
  未置 can_open_when_dead）——死亡玩家看聊天播报 + 光圈；聊天播报/光圈/音效
  全部保留
- **v1.10.1 修正**：锚定落点实测变屏幕边缘箭头 → 改 STATIC flag 固定屏幕中央
  （见上节）
- **v1.10.2 修正**：每秒重建只 create 不 stop → 客户端堆叠感叹号 → 改先 stop
  再 create（见上节）
- **验证**：空服 reload 无错误；临时测试插件（RegServerCmd sm_tst_hint，已删）
  确认 create=1 事件合法、info_target 生成/销毁正常；客户端实际渲染待玩家实测
- 注意：秒级重建 = 8 次/次呼叫，与游戏自身 hint 冲突时我们的每秒重建会赢回
  （新者覆盖旧者）

## v1.8.5-v1.8.25 三档火力调整（2026-08-15，全部已编译部署，git 已提交）

**v1.8.5（2026-08-15）**：三档全面调整（用户实测后拍板）——
- **范围收紧 20%**：地狱烈火 675→540 / 472.5→378 / 337.5→270；
  绿色雨幕 421.875→337.5 / 295.3125→236.25 / 210.9375→168.75；
  区域轰炸 562.5→450 / 393.75→315 / 281.25→225
- **频率降低**：kind 2/5 都改为每 2 秒一槽（原每秒）
- **价格调整**：绿色雨幕 4500→**6500**、地狱烈火 8500→**10000**、区域轰炸 10000→**14500**
- **区域轰炸改全榴弹**：si_hud_art5_can_pct 默认 50 → **0**（不再掉罐子，纯榴弹雨）

**v1.8.7（2026-08-15）**：地狱烈火再收紧 15%（540→459 / 378→321.3 / 270→229.5，
火焰蔓延实际范围更大）；区域轰炸放大 10%（450→495 / 315→346.5 / 225→247.5）+
频率加快为每 1.5 秒一槽。

**v1.8.8（2026-08-15）**：**绿色雨幕改双路径**——每个时间槽同时生成胆汁瓶（kind 3）
+ 瓦斯/煤气罐（kind 1 池），两类各 1-2 件（原纯胆汁瓶）。绿色雨幕不再是纯控场，
已有爆炸伤害。

**v1.8.18（2026-08-15）**：区域轰炸改回每 2 秒一槽（实测 1.5s×2-3 太快，用户拍板降频）。

**v1.8.19-20（2026-08-15）**：Art_FindCeiling 修复两连——起点 60→200u（起伏地形
误判）+ 穿透上限 4→16（狭窄长巷误拒，见下节 v1.8.20 原文）。

## v1.9.0 目标解析系统重构（2026-08-16，commit 10e4d52，已部署 reload）

任务书驱动（云端 agent 静态分析 → 逐条核实只采纳真问题）。四档全部受益：

**P0 修复（全部落实）**：
1. **Ceiling 净空基准修正**：Art_FindCeiling trace 起点 +200u（防起点嵌地面），
   返回时加回偏移 → 真实净空 750 不再被判 550 → 误拒 <600（v1.8.19 偏移 60→200
   后问题加剧，本版根治）
2. **Aim Hit → Ground Resolve**：Art_AimPoint 拆为 Art_GetAimIntent（原始命中 +
   法线）+ Art_ResolveGround（① 直接瞄地面 normal.z≥0.55 向下确认；② 瞄天花板
   normal.z≤-0.7 → 向下找房间地板，**删除 z-=120 悬空**；③ 墙面 → 沿视线回退
   32/64/96u 各从高处向下探测附近地板）。最终 ground 校验法线 ≥0.45（允许坡地）
3. **Preview/Confirm 一致**：Art_SolveTarget 统一入口 + ArtTargetInfo 缓存
   （g_ArtTarget[client]）+ 0.15s 复用窗口——心跳画圈与开火确认读同一份解析，
   "绿圈看到什么开枪就确认什么"，不再二次 trace 换目标
4. **Spread found 标志**：落罐散布 8 次重试全败 → 回退中心落点（禁最后一个
   invalid 点）；test 命令走同一条 Art_SolveTarget 路径

**P1/P2（采纳）**：AGM Attack Corridor（见 [[l4d2-agm-missile]]）；失败原因分级
提示（净空不足 X u / 无地面 / 无攻击走廊，替代"需要开阔区域"）；aim max dist
ConVar（l4d2_shop_art_aim_max_dist 默认 3000，原 2000 硬编码）；debug cvar
（l4d2_shop_art_debug 0-3：结果日志 + rawHit 红/ground 绿/ceiling 蓝/corridor 白
可视化）；环境分类 enum（OUTDOOR/COVERED_OPEN/INDOOR_HIGH/INDOOR_LOW）；
恢复 tank_kill/tank_damage/surv_inner_radius cvar 实际使用。

**未采纳（有理由）**：Trace Filter 语义指控（核实为误判——SM filter 返回 true=
忽略，现有用法全对）；<600 连续缩放/矮房放行（行为变更，保持二值拒绝但基准
已修准）；瞄天空 end-point probe（保持"瞄天空无效"定稿行为）；商店抽离
fire_support.sp（大重构高风险，后续轮次）；StartSolid 全套（起点抬高已规避）。

**验证**：v1.9.0 编译零错误零警告，14:15 reload 成功（assets 7/7），C5 城区
实战验收待用户上线（c5m2 长街/立面/雨棚/桥下 + AGM 走廊）。

### 当前定稿（v1.9.0，代码默认值）

| 档位 | classname/kind | 价格 | 时长 | 频率 | 半径（out/mid/small） | 圈色 |
|---|---|---|---|---|---|---|
| I-绿色雨幕 | artillery3 / 3 | 6500 | 15s | 每 2s 胆汁瓶+罐子各 1-2 | 337.5/236.25/168.75 | 绿 |
| II-地狱烈火 | artillery2 / 2 | 10000 | 25s | 每 2s 油桶70%+烟花30% | 459/321.3/229.5 | 黄 |
| III-区域轰炸 | artillery5 / 5 | 14500 | 30s | 每 2s 1-3 发榴弹（全榴弹） | 495/346.5/247.5 | 蓝 |
| IV-AGM导弹 | artillery6 / 6 | 18000 | 单发 | 俯冲瞬爆 | 600/450/350（核心×1.38） | 紫 |

- 菜单按价格升序展示（v1.8.1）：I < II < III < IV
- 全服轰炸锁 + 10s 硬冷却 si_hud_art_cooldown；预警统一 8s si_hud_art_warn_time
- AGM 详情、cvar 全表、版本史、素材坑 → **[[l4d2-agm-missile]]**

## v1.8.20 狭窄长巷误拒修复（2026-08-15，已编译部署 reload 生效）

**症状（用户实测）**：狭窄但露天的长巷不能释放火力支援（报"目标无效"）；用户承认有些会炸屋顶但不应完全不能释放。

**根因**：`Art_FindCeiling`（l4d2_shop.sp:2404）向上探天花板时，遇到侧面命中（墙/柱，法线 z>-0.7）会穿透继续向上（2437-2444）。但穿透循环上限 `while (hops < 4)`——**狭窄长巷向上 trace 反复撞两侧墙壁侧面，4 次穿不到天空** → 提前退出返回低 ceiling 值 + `openAbove=false` → 触发拒绝逻辑（2334 `ceiling > 0 && ceiling < ART_CEIL_LOW(600) && !openAbove` → valid=false，2340 报"目标无效"）。

**修复**：穿透上限 `hops < 4` → `hops < 16`（2419 行），让狭窄地形穿过更多侧墙最终识别露天放行。已 reload（17:44，粟藜在线，用户批准）。

**注意**：拒绝逻辑本身（露天窄巷已放行；真正封闭矮房 <600 且上方非开阔仍拒）未改，只放宽穿透探测。若仍有窄巷被拒，看日志 `[artillery] confirm ... ceiling=X openAbove=Y`——ceiling 仍偏低说明 16 次仍不够，或该点确实是封闭结构。

## v1.6.4 双修复（2026-08-03 晚，已编译部署 plugins/，未 reload——1 玩家在线静默规则）

**① 瞄准圈 < 实际轰炸范围（用户实测）**：圈原来 = 落点半径 × 4/3（v1.4.2 设计"光圈>落点圈"），
但玩家看到的轰炸覆盖 = **落点圈 + 每件爆炸物效果半径**（榴弹爆炸 ≈400u / 油桶爆炸+火焰蔓延 ≈500u /
胆汁溅射 ≈400u）→ 落点+效果 >> 圈，实测"轰炸范围远大于瞄准圈"。日志铁证（20:02-20:16 三连测）：
绿色雨幕 r=750（圈1000）、地狱烈火 r=675（圈900）、饱和轰炸 r=562（圈750）。
**用户拍板：圈 = 半径 + 450**（绿色雨幕 1200 / 地狱烈火 1125 / 饱和轰炸 1012）。
另确认 art3 半径 cvar 是 RCON 残留 750/525/375（def 421.875…）——圈和落点同步缩放不受影响。
附带观察：圈画在准星命中点，瞄坡/墙时浮空（target z=3200 那种），罐子落地顺坡滚——轰炸行为本身用户认可。

**② 倒地还能买火力支援（用户实测）**：v1.7.82 的"倒地/死亡拦截"只查 `!IsPlayerAlive(client)`——
**SM 的 IsPlayerAlive 对倒地玩家返回 true（倒地=存活）** → 只拦了死亡没拦倒地。
修复：补 `L4D_IsPlayerIncapacitated(client)`（left4dhooks 已 include，si_hud:962 同款用法）。


`SDKHooks_TakeDamage(ent, ent, buyer, 99999, DMG_BLAST, ...)` —— **(victim=罐子, attacker=罐子, inflictor=召唤者)**。**引擎爆炸伤害归属跟随 inflictor（不是 attacker）**：
- inflictor=召唤者（v1.7.93/98）：99999 全吃必爆 + 伤害全恢复（特感/队友/僵尸，18:09 时代 engine 122-184 实证）+ 击杀 hit 归属=召唤者
- inflictor=ent（v1.7.94 错误改动）：归属=已死实体 → **爆炸伤害全灭**（火炮打不到任何人，19:00 后 13+ 次轰炸零记录）
- 召唤者自己被引擎豁免（归属者豁免）→ 由 l4d2_can_full_damage 插件注入补炸（[[l4d2-can-full-damage]]）
- 已 commit f0b540a（si_hud v1.7.98 含支援2 + can_full_damage v1.2.1 + ff_fix v1.4 清理）；**v1.7.99 命名定价未 commit**

2026-08-02 v1.7.95 已编译、覆盖 plugins/、**已 reload 并验证生效**（19:18 RCON reload；rate=4.0/duration=60.0/radius 750/525/375 全部确认）。**残留坑再次踩中**：radius 三个 cvar 是引擎残留（v1.7.93 测试期 sm_cvar 创建），reload 后卡旧值 500/350/250 → 已 RCON `sm_cvar` 纠正；**下次服务器重启前若再 reload 会回退旧值，需重跑 RCON**（count_*/stagger 残留 cvar 惰性无害）。源码 = git 仓库（scripting/ 即 suli-l4d2-server-toolkit），**未提交**（同文件还挂着 v1.7.94 伤害修复 + 火炮II 回滚，三者一起 commit）。

**交互（v1.7.95 用户拍板简化）**：购买 → 扣款 → 准星瞄准处显示爆炸半径圆圈+光柱+光点（全队可见；天花板 <600 或瞄天空 → 红圈无效）→ **玩家当前武器任意开火（weapon_fire）= 确认轰炸** → 右键/15s 超时/死亡/断线 = 取消退款。**不再切马格南**——删除了整套武器保存/恢复逻辑（g_iArtMagnum、g_sArtPrevWeapon/PrevMelee、g_iArtPrevUpgrade/Clip 5 个全局 + Art_SaveMeleeName + Timer_ArtRestoreCheck + restoreWeapon 参数），彻底消除切枪/恢复武器类问题（v1.7.81-85 一系列 FIX 全部作废删除）。

**机制（v1.7.96 按秒随机）**：着火的 prop_physics + 罐模型（70/30，gascan 排除）从高空坠落，**si_hud_art_duration（默认 30s）内每秒随机 2-3 罐**（常量 ART_CANS_MIN/MAX_PER_SEC 写死，用户拍板；每罐在所属秒内随机偏移 0-0.9s，保证每秒必有掉落）≈ **60-90 罐**（用户调参轨迹：240→180→90-135→60-90，越改越短越少）。错峰定时器逐个生成（每罐一个 DataPack 定时器）；落地定时器 SDKHooks_TakeDamage 99999 DMG_BLAST 强制引爆。**半径全部 ×1.5**：out 500→750 / mid 350→525 / small 250→375（瞄准圈自动同步，TE_SetupBeamRingPoint 读同一 cvar）。室内自适应只缩半径不缩密度。结束播报时刻 = delay + seconds + fallT + burn + 0.15（约 35s）；g_fArtNextBuyTime = 该时刻 + cooldown。**残留坑三连**：radius、rate、duration 全是引擎残留（跨 reload 存活）——代码默认 30.0 + RCON 已设 30.0/750/525/375 双保险；si_hud_art_rate cvar 已从插件删除（残留值 3.0 惰性无害）；重启后代码默认权威。

**cvar 变化**：si_hud_art_count_out/mid/small、si_hud_art_stagger 已删除（引擎残留 cvar 无害）；新增 si_hud_art_rate（1-10）、si_hud_art_duration（5-300）；ART_MAX_CANS 32 → ART_MAX_TOTAL 600（单次硬上限）。cfg/sourcemod/l4d2_si_hud.cfg 是火炮功能之前的旧版（无 si_hud_art_* 条目，AutoExecConfig 不重写已存在文件）→ 代码默认值权威，改默认值 reload 即生效。

**注意事项（待实测）**：①室内封闭矮房（375 半径）240 罐会非常密集，卡顿可调 si_hud_art_rate；②手里有投掷物时左键会先扔出去同时确认轰炸（用户接受的简化）；③连发武器按住左键只确认一次（确认后瞄准即结束）。

**命名定价（v1.8.1 用户定稿，已部署 2026-08-03，commit 7204d1e）**：
- 「火力支援I-炮击」= `artillery`，**4500 分**（v1.7.99 定稿 4000；70% 瓦斯罐 propanecanister001a + 30% 煤气罐 oxygentank01）
- 「火力支援II-燃烧」= `artillery2`，**6500 分**（v1.7.99 定稿 7000；70% 油桶 gascan001a + 30% 烟花 explosive_box001；kind 经 DataPack 从确认时 g_iArtSlot 传到 Timer_ArtSpawnCan 选模型池；两模型都在 precache + can_full_damage 清单，零风险）
- 价格写死在商店表（改价需重编译）；共用半径/冷却 cvar + 全局轰炸锁（一次一场、生效期间禁止重复购买、结束 10s 硬冷却 si_hud_art_cooldown）
- **v1.8.1 时长定稿**：I-炮击 = si_hud_art_duration **30s**（v1.8.0 定稿 35）；II-燃烧 = si_hud_art2_duration **25s**（v1.8.0 定稿 30）。重启后代码默认权威（cfg 无 si_hud_art_* 条目，AutoExecConfig 不重写已存在文件）
- 已实测：支援2 油桶/烟花雨爆炸+伤害+召唤者自伤注入 ✓（prop_physics 正解见 [[l4d2-tank-spawn-explode]]）

**编译坑（本 SM 1.12）**：数学函数名是 SquareRoot/Cosine/Sine（无 Sqrt/Cos/Sin）；HasEntProp 可安全探测属性存在（SetEntProp 对不存在属性会抛错中断回调）；TR_GetFraction 是返回值 native 不是引用传出；变量无前向声明（被提前引用必须声明在引用前，函数可以）。header Changelog 惯例 v1.7.63 后废弃，新功能注释写实现区。

## 火力支援III-胆汁雨（2026-08-03 **v1.2.7 定稿，已 commit 5ea5e5a**）

商店第三支援技能：**3500 分 / 15s（用户定稿），纯控场**。生成 = 引擎工厂 `CVomitJarProjectile::Create`（经典签名条目 3131 行，linux `@_ZN19CVomitJarProjectile6CreateERK6VectorRK6QAngleS2_S2_P20CBaseCombatCharacter`）SDKCall 优先（无投掷语音），解析失败回退 `L4D2_VomitJarPrj`。兜底落地 0.5s 仍存活 → 落地面 + `L4D_DetonateProjectile` 强裂。绿圈预警 + si_hud_art3_*（半径 750/525/375、每秒 1-2 瓶）+ sm_art3test。

**声音噪音定论（2026-08-03 用户破案）**：所有"太吵"声音 = **客户端胆汁 mod 音效**（用户自装 mod 替换碎裂音效，距离衰减实证），**去掉 mod 完全正常**。v1.2.2"落地角色语音"、v1.2.3"投掷语音"推断全是误判。插件声音抑制链（工厂无语音 + 被淋拦截 + 手动阻断窗口）保留无害——被淋拦截（幸存者防淋防群殴）有真实意义。

**坑清单（v1.2.x 实测铁证）**：
- **工厂 Create ≠ 激活**：13:27 日志 100% fallback detonate，`L4D2_VomitJar_Detonate` pre/post、survivor-biled、bile-applied 全 0——瓶子从不自然碎裂，Touch 从不触发（与 artillery2 同根因）。碎裂只走兜底强裂。
- **L4D_DetonateProjectile = 基类 CBaseGrenade::Detonate**（虚表 347）：SDKCall 基类不走子类覆盖 → forward 不触发 → fallback 的碎裂/上胆汁行为以此为界。
- **工厂参数顺序隐患**：代码 (pos, angles, **angVel, vel**, thrower) vs gamedata L4DD:: 权威块 (origin/angles/**velocity, rotation**/owner)——可能反转！直坠零角速度场景（angVel=0, vel=-900）两参数交换不可区分，**改弹道（抛物线/横飞）前必查**。
- **v1.2.6 直接效果版废弃**（Art3_FindLand/Timer_Art3Effect/Art3_SpawnParticle/Art3_BileRadius）：粒子+手动上胆汁方案用户实测"什么都没有"，已回滚未深挖。
- **SM 1.12.0.7220 sound hooks**：二进制支持（HookSound/HookUserMessage 同在），但 include/ 被裁剪无 soundhooks.inc → 需手写 typedef+native 声明。本次未采用（mod 真相后不需要）。

## ⚠️ 高 h 罐子不落地坑（2026-08-03 双层破案，**v1.6.2 定稿已部署已验证**）

**症状**：c4m2 糖厂露天召唤「I-绿色雨幕」，地面看不到罐子/爆炸/胆汁（**听到声音看不到烟雾**）。

**双层根因（日志铁证 L20260803.log）**：
1. **头顶隐形实体（c4m2 空地 z=972）**：v1.6.1 验证循环日志——validate trace（ShopTraceFilter **忽略实体**）从生成点 2317 直达地面 121（全 OK），但 8/8 罐子全停 **z=972**；fallback 的 trace 从 972 出发第一命中就是 972（起点嵌实体内）。**972 = 非世界几何的 invisible 实体**（防飞顶类），ceiling 探测/落点验证都用忽略实体的 filter → 全部检测不到。罐子撞实体**不触发触碰碎裂**（对照 14:12 h=189 撞世界地面碎裂 → 23 条 bile applied）→ 全停 972 等 fallback。
2. **fallback 半碎裂**：`L4D_DetonateProjectile` = `CBaseGrenade::Detonate` **基类**（虚表 347）不喷胆汁——16:54 `dbg after-detonate alive=1` 证明碎裂流程未走完 → 用户听到碎裂声看不到胆汁烟雾。

**v1.6.2 修复（2026-08-03 17:03 部署 reload，用户 17:04 实测成功）**：
1. **头顶实体探测**（Timer_ArtSpawnCan）：从 target 向上 5000u trace **不带 filter**（`TR_TraceRayEx`，MASK_SOLID 含实体）→ 首面即头顶阻挡 → `height = min(height, hit.z - target.z - 50)`（head-block 日志监控）。室内真实天花板 ceiling-150 余量更大 → 保持原值；露天防飞顶（972）→ 2196 钳到 801，罐子从阻挡下方生成 → 直接落地触碰世界 → 引擎完整碎裂。
2. **fallback 延迟触碰**（Timer_Art3GroundTouch）：传送落点后**不立即强裂**，CreateTimer 0.15s 等引擎物理掉落触碰地面 → 自然完整碎裂（bile 全流程）；仍存活（传送未唤醒/悬停）才 L4D_DetonateProjectile 兜底（touch-miss 日志监控兜底频次）。
3. 保留历史修复：v1.6.0 groundZ 直传（commit ff10ff9）+ v1.6.1 validate 世界屋顶重掷 ≤8 次 + 守卫比目标地面；v1.6.0 已钳 kind 2/4/5 到 1500（用户拍板统一 II/III 高度）。

**验证（17:04 c4m2）**：bile applied 30+ 条（引擎碎裂生效）+ 用户确认成功。head-block 未触发（17:04 用户换位不在 972 实体下）——修复 1 待回原位置验证；touch-miss 偶发（那罐半碎裂无视觉，兜底行为）。

**教训**：①L4D2 露天常有 invisible 顶部实体，**一切 trace（向下落点/向上 ceiling/头顶）都要考虑实体**——用忽略实体的 filter 会漏掉"物理挡住弹丸但不触发触碰碎裂"的实体；②`L4D_DetonateProjectile` 是基类半碎裂，要完整碎裂效果（bile）必须走引擎路径（触碰/引信）——**fallback 的职责是"把弹丸送到引擎能碎裂的位置"（传送+延迟触碰）而不是自己炸**；③工厂 Create 弹丸的触碰碎裂只对世界几何/可触碰目标生效。

## 火力支援定稿（2026-08-03 **v1.5.0 最终版,用户拍板"就这样了";热重载生效 15:28,未 commit**）

> v1.5.0（2026-08-03）：火力支援III 改名「饱和轰炸」（仅显示名,classname/kind/价格机制全不变;已编译部署,待 reload）。

**最终三件套(价格/时长/机制全冻结)**:
- **I-绿色雨幕**(kind 3,artillery3,绿圈·控场):**4500 分**/15s,范围=轰炸 75%,每 2 秒 1-2 罐 ≈ 8-16 瓶
- **II-地狱烈火**(kind 2,artillery2,黄圈·燃烧):**8500 分**/25s,油桶+烟花
- **III-饱和轰炸**(kind 5,artillery5,蓝圈·混合):**10000 分**/30s,罐+榴弹 1:1,每秒 2-3 件

**v1.4.6-v1.4.8(2026-08-03,均已 reload 生效)**:①新增投掷品分类(cat=5,菜单第 4 类,火力支援/其他顺移;胆汁 1275/土质炸弹 1350/燃烧瓶 3750 = 850/900/2500 ×1.5)。②医疗类改名**补给品**(药 1250/肾上 1250/电击器 4375/医疗包 3750/弹包 625 = ×1.25;燃烧弹包+高爆弹包移入)。③复活币移入其他类。④火力支援涨价:3500→**4500**/6500→**8500**/7500→**10000**。SHOP_SLOTS 21→24(表尾追加,不动 WALLHACK_SLOT 12)。

**v1.4.5（2026-08-03 用户拍板定名,已 reload 生效）**:弃用"胆汁雨/燃烧/轰炸"直白词 —
**I-绿色雨幕**（原胆汁雨,绿圈·控场）/**II-地狱烈火**（原燃烧,黄圈·燃烧）/**III-饱和轰炸**（原轰炸,蓝圈·罐+榴弹1:1）。
只改显示名+cvar 描述+注释,classname/kind 全不动。播报文本自动跟随表名。

**v1.4.4（2026-08-03,已 reload 生效）**:用户实测"2 和 3 过强"→ III-轰炸涨价 5500→**7500**(其余不变)、II/III 编号对调(价格升序)。

**v1.4.3（2026-08-03 用户拍板,已 reload 生效）**:①按价格重排编号 — I-胆汁雨 3500(原 III-胆汁雨,kind 3)/ II-轰炸 5500(原 V-混合,kind 5)/ III-燃烧 6500(原 II,kind 2);只改显示名+描述,classname/kind/cvar 全不动。②菜单分类顺序=武器/道具/医疗/**火力支援(第4)**/其他(第5)(AddItem 0,1,2,4,3,cat 值不变)。编译坑:**注释里 `**/` 子串会提前终止块注释**(changelog 写 `**火力支援(第4)**/` 报错 1,改方括号)。

**v1.4.2(2026-08-03 用户拍板,已重启生效 14:47)**:①四色瞄准圈 — II-轰炸蓝 / III-燃烧黄 / I-胆汁雨绿 / 无效红(kind 5 原品红→蓝,kind 1/4 已禁用落默认蓝)。②三档圈大小 — Art_RingParams 加 kind 参数,圈 = 各火力轰炸半径 × 4/3:I-胆汁 562.5/393.75/281.25、II-轰炸 750/525/375、III-燃烧 900/630/450(v1.0.7 的 si_hud_art_ring_* cvar 废弃不再读,残留惰性无害)。

**v1.4.1(2026-08-03)**:TEST 期结束恢复原价(0-14 槽 + 火力支援II 6500;I/III 与新商品定稿价不动)。

## 火力支援定稿（2026-08-03 **v1.4.0 已编译部署 plugins/，未 reload 未 commit**）

用户拍板三项定稿(商店只剩 3 种火力支援,菜单新增「火力支援」分类 cat=4,其他 3→4):
- **「火力支援I-轰炸」** = 原 artillery5 改名转正:**5500 分 / 30s**(si_hud_art5_duration 25→30),榴弹:罐子=1:1(can_pct 50),罐子内丙烷:氧气 **50/50**(ART_CAN_PROPANE_PCT 70→50;**新增 ART2_CAN_PROPANE_PCT 70 承接 kind=2 油桶/烟花池原比例**,共用常量会连带改 II),每秒 2-3 件,半径 562.5/393.75/281.25 不变
- **原火力支援I-炮击(artillery) + IV-榴弹雨(artillery4) 已禁用** — 商店表删两行(SHOP_SLOTS 20→18),kind 1/4 代码路径全保留(kind=5 罐子分流依赖 kind=1 路径;恢复只需加回表行);cvar si_hud_art4_* 残留惰性无害
- **「火力支援III-胆汁雨」3500/15s 不变**,范围 = I-轰炸 **75%**(750/525/375→421.875/295.3125/210.9375),**每 2 秒 1-2 罐**(Art_LaunchBarrage 循环步进 2,15s ≈ 8-16 瓶,原每秒 1-2 瓶减半)
- 新增商品:马格南 2000(武器栏,weapon_pistol_magnum)、燃烧弹包 500/高爆弹包 500(其它栏,weapon_upgradepack_incendiary/explosive,走 ShopSpawn 通用路径);表尾追加不动 WALLHACK_SLOT 12;SHOP_SLOTS 18→21
- 其余商品仍全 1 分(TEST 期注释在表头,用户没让恢复)

## 火力支援V-混合轰炸（2026-08-03 **v1.3.0 已实现，等空服；未 commit**）

用户拍板新增（"即掉榴弹也掉瓦斯罐"）——**kind=5，每件随机分流**：`Timer_ArtSpawnCan` 里 `GetRandomInt(1,100) <= si_hud_art5_can_pct`（默认 50%）→ 罐子路径（kind 改为 1 → 丙烷罐 70%/氧气罐 30% 模型池，点火强爆）否则榴弹路径（`Art4_SpawnGrenade`）。品红圈预警（I蓝/II黄/III绿/IV红/V品红）；独立 cvar 组 si_hud_art5_*（duration 25s、半径同 I 562.5/393.75/281.25、can_pct 0-100）；每秒总件数 2-3（ART5_* 常量）；购买拦截含榴弹路径 → 与 IV 同走 Art4_CheckNatives。商品行「火力支援V-混合轰炸」artillery5（TEST 1 分）；SHOP_SLOTS 19→20。sm_art5test（admin 准星单件，DataPack 复用 Timer_ArtSpawnCan 正式 kind=5 分流）。**附带修复 v1.2.0 遗留 bug**：IV 引信高度钳制在 pos 计算之后（只改参数不改落点 → 弹丸仍生成在 1800-2600 半空空爆浪费），v1.3.0 提前到 pos 生成前（kind 4/5 同修，与 sm_art4test 口径一致）——**IV 首次真按 1500 生成，空服实测时留意 IV 效果可能变化**。已编译部署 plugins/（md5 6f94a800，旧 v1.2.7 备份 /tmp/l4d2_shop.smx.bak.v1.2.7），**未 reload（等空服），未 commit**。混合模式物理：罐子 1500u 落 ~1.9s 与榴弹 ~1.2s 引信错峰；榴弹 270 爆炸可能打中空中罐子（500hp 单发炸不死，两发或先烧过会半空提前爆）。

## 火力支援IV-榴弹雨（2026-08-03 v1.2.0 已实现，等空服实测）

用户改拍板实施（"试着做一下我看看效果"）。**left4dhooks 现成 native 直生引擎激活态 grenadelauncher_projectile**：`L4D2_GrenadeLauncherPrj(client, pos, ang, vel, rot, bIncendiary=false)`（= 引擎工厂 CGrenadeLauncher_Projectile::Create 包装；client = 伤害归属）+ 兜底 `L4D_DetonateProjectile(entity)`。**伤害与手持 GL 完全一致**：同类实体 + 同工厂 + m_flDamage=270（artillery2 v1.0.3 属性 dump 实证）+ 相同 falloff/友伤缩放/击杀归属；唯一差别 = 从天而降几乎全是落地溅射，无直击。**引信 ~1.2s → 生成高度特调 ART4_FUSE_HEIGHT=1500u**（-900 初速 ≈1.1s 触地贴近地面空爆；罐子高度 1800-2600 半空空爆浪费；矮房 height 天然 <1500 则落地后弹跳爆，正常）。商品行「火力支援IV-榴弹雨」artillery4（TEST 1 分，价格用户定稿）；红圈预警（I蓝/II黄/III绿/IV红）；独立 cvar 组 si_hud_art4_*（duration 15s、半径 562.5/393.75/281.25 = 有伤害口径同 I/II）；每秒 1-2 发（ART4_GRENADES_* 常量）≈ 15-30 发。kind 链 1/2/3 → 4 贯通（Art_KindOfSlot/瞄准圈色/确认时长/预警色/速率/落罐分支）。native 可用性用 GetFeatureStatus 检查（Art4_CheckNatives，失败购买拦截退款）；兜底 Timer_Art4Detonate = 悬停未爆 → 落地面 + L4D_DetonateProjectile 强爆。测试命令 sm_art4test（admin 准星单发）。**已编译部署 plugins/（md5 40f56bd9），未 reload（等空服），v1.0.2-v1.2.0 均未 commit（用户测试迭代规则）**。left4dhooks.inc 里两个 native 都是 MarkNativeAsOptional + 文档实证（5408/5491 行）。

## 火炮支援II（榴弹炮弹雨）——❌ 4 版失败已禁用；**根因已破案（2026-08-03），支援IV 已接管**

原独立插件 `l4d2_shop_artillery2`（v1.0.0→v1.0.4，源码在 scripting/，smx 在 plugins/disabled/）**失败禁用**（插件已 unload）。**失败根因 = 直生弹丸缺引擎工厂初始化**——破案证据：gamedata Signatures 段有 `CGrenadeLauncher_Projectile::Create`（6 参，比胆汁瓶多一个 int = bIncendiary），且 **left4dhooks 已包装成现成 native `L4D2_GrenadeLauncherPrj(client, pos, ang, vel, rot, bIncendiary)`**（"Creates an **activated** projectile"——激活正是直生缺的）；兜底 native 也现成：`L4D_DetonateProjectile(entity)`（支持 grenadelauncher_projectile）。用户先拍板暂不做，后改主意 → 已实现为支援IV（见上节）。

### 失败排查完整记录（v1.0.0→v1.0.4，全部实测）

| 版本 | 尝试 | 结果 |
|---|---|---|
| v1.0.0 | vel -120 缓落 + m_hThrower | 弹丸从 236 落到 -50（地面 -63，模型贴地）停住不爆，8 发全走 kill fallback |
| v1.0.1 | vel -800 砸地 | 同样贴地停住不爆（推翻"低速不触发 Touch"理论） |
| v1.0.2 | + m_hOwnerEntity=buyer | 仍不爆（推翻 owner=0=世界 理论） |
| v1.0.3 | 诊断对照（**决定性数据**） | ours: eflags=0x204c000 gravity=1.00；发射态: eflags=0x2040000 gravity=0.40。**其余全一致**（solid=2/model=254/damage=270/owner=1/thrower=1/spawnflags=0） |
| v1.0.4 | 清 EFL_IN_BRUSH(0x4000)+EFL_IN_BOUNCE(0x8000) + 还原 gravity 0.4 | 用户反馈仍无效（未复看日志确认 dump） |
| 全程 | 兜底尝试 Explode/Detonate/SelfExplode 输入 | 全部 ignored，只能 Kill |

- eflags 0xC000 来源推测：CreateEntityByName 时实体原点 0,0,0，DispatchSpawn 在原点做 brush 包含检查 → IN_BRUSH；Teleport 后标志不清。**清掉后仍不爆 → 不是根因（或引擎每帧重设）**
- **gl_splash_fix 注入伤害全程是通的**（每次 Kill 都有 GL boom 日志）——缺的只是引擎爆炸特效/音效触发
- **结论**：生成态弹丸缺引擎发射路径（weapon 的 FireProjectile / CProjectileEntity::Create 做的"某件事"）。未试的方向：①VScript SpawnEntityFromTable ②SDKCall SetNextThink/Explode ③prop_physics + 手搓爆炸特效 ④检查 m_bInFlight / 弹丸专属 prop
- **教训**：CreateEntityByName 生成弹丸 ≠ 发射弹丸，属性 dump 对比是唯一靠谱诊断法

### 复用资产（未浪费）

- 独立插件骨架 l4d2_shop_artillery2.sp：瞄准 UI 全套（Art2_*）+ 弹丸生成 + 兜底框架，未来换实体/换触发方式可直接复用
- ext_ API 设计（forward+natives）已验证可行但已撤（v1.7.95 前回滚删除），将来商店拆分可用
