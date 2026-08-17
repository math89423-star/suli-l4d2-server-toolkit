# L4D2 剿灭得分 v2.5.1（2026-08-17 用户拍板，已部署）

> 商店击杀得分新增"剿灭得分"：波次清缴完成时全体生还者得分，三档互斥 + 时间倍率。
> 部署：13:57 RCON reload specialspawner + tank_wave_mutator（空服），cvar 验证通过。
> v2.5.1（14:20）：时间倍率。
> commit `453a61c`（v2.5.0）+ `6e78734`（v2.5.1）+ `16ef758`（广告修正）。

## v2.5.1 时间倍率（用户设计，替代高光时刻方案）

**背景**：用户原想"特感高光时刻计入额外得分"并联动 skill_detect 插件（高光播报插件）→ 侦察发现该插件 = `l4d2_skill_detect.smx`（Skill Detection by Tabun/Harry，检测 skeet 空爆/crown 砍头/hunterdp 高扑/jockeydp/deathcharge 死亡冲锋/selfclear 自清/instaclear 瞬清/bhop 连跳）→ **用户改主意**："直接把这个插件去掉，高光播报过多还会干扰信息"，改为**按时间计算倍率**。

- **skill_detect 已移除**（unload + smx 移 `plugins/disabled/`，重启不自动加载）；cfg `l4d2_skill_detect.cfg` 残留无害
- 广告第 4 条修正：删"高光操作自动播报(空爆/砍头/冲锋)"，MVP 改"回合结束得分榜统计"
- **时间倍率规则（用户口述）**：从**特感刷新播报（波次开始）**起算，倍率 = 1.5 − 0.015×经过秒数，下限 1.0（≈第 30s 恢复 1×，拖再久不惩罚）——清剿越快奖励越高
- **作用**：剿灭得分（三档 × Tank×3 之后）再乘时间倍率；**v2.5.2 播报不再标注括号内容**（用户拍板"不播了"，倍率只计入得分，播报只显示最终分数）
- **cvar**：`ss_clear_time_mult_start` 1.5 / `ss_clear_time_mult_decay` 0.015
- **实现**：`g_fWaveStartTime` 波次起算点（tmrSpawnSpecial 设置，**retry 波不重置**——区别于 g_fPhaseEnterTime 120s 硬上限锚点）

## 用户设计定稿（v2.5.0，逐字拍板）

1. **三档互斥**（波次清缴完成时全体每位生还者得分）：
   - 完美剿灭 = **350**（波内无人倒地/死亡）
   - 剿灭补偿 = **275**（波内倒地/死亡去重人数 ≥ 生还者队伍 **30%**——用户补充纠正：初始说法"出现倒地死亡就发"作废，≥30% 才发）
   - 剿灭得分（基础）= **200**（其余情况，0 < 倒地 < 30%）
2. **Tank 波次三档 ×3**（1050/600/825）
3. **bot 计入判定**（用户拍板）：基数=波次开始时生还队人数（含 bot），倒地/死亡去重统计含 bot
4. **播报合并进"清剿完毕"消息**（替换原"波次清剿完毕，X 秒后下一波"）：
   - `[特感] 本波次剿灭完成，完美剿灭全体 +350 分，下一波来袭 30 秒`
   - `[特感] 本波次剿灭完成，剿灭补偿全体 +275 分，下一波来袭 30 秒`
   - `[特感] 本波次剿灭完成，剿灭得分全体 +200 分，下一波来袭 30 秒`
   - Tank 波加前缀：`☠Tank波 完美剿灭全体 +1050 分…`

## 实现（specialspawner v2.4.4 → v2.5.0）

- **挂载点**：`EnterRest()` 内（SS_OnWaveRest forward 之后、rest 抽取之后）调 `SettleWaveClearScore(totalCountdown)`——Tank 波清缴被 SS_HoldClearing 挂起，Tank 死完才进 REST，结算自然覆盖 Tank 波
- **波内统计**（tmrSpawnSpecial 波次开始时快照/清零；retry 波不重进，统计延续）：
  - `g_iWaveBase`：基数 = 当前生还队人数（含 bot）
  - `g_iWaveDownDeaths` + `g_bWaveDowned[]`：倒地/死亡**去重**人数（同一人多次倒地/倒后死只算 1）
  - `g_bWaveActive`：仅 PRESSURE/CLEARING 期间计入（REST/IDLE 残留特感造成的倒地归下一波）
  - `g_bWaveStarted`：零波（上限满/全倒）不发分，保持原"波次清剿完毕"播报
- **Tank 波判定**：新 native `SS_MarkWaveTank()`（specialspawner 注册）——tank_wave_mutator v2.5.0 在 Timer_SpawnTank 生成成功（spawned>0）后调用（GetFeatureStatus 守卫，同 SS_HoldClearing 模式）。只认突变 Tank 波，终章导演 Tank 不算
- **入账**：`SH_AddWallet(i, score)` 遍历生还队全体（含 bot，与过关奖励同口径；si_hud 钳上限 30000）
- **cvar**（specialspawner.cfg 自动生成）：
  | cvar | 默认 | 说明 |
  |---|---|---|
  | `ss_clear_score_base` | 200 | 基础档（0=关闭剿灭得分） |
  | `ss_clear_score_perfect` | 350 | 完美档（无倒地/死亡） |
  | `ss_clear_score_comp` | 275 | 补偿档（倒地/死亡≥30%） |
  | `ss_clear_comp_ratio` | 0.30 | 补偿触发比例 |
  | `ss_clear_tank_mult` | 3.0 | Tank 波倍率 |
- 诊断日志：`[SS] Clear score: tier=… score=… downDeaths=…/… base=… tank=… next=…s`（稳定后可移除）

## ⚠ SM 1.12 optional native 三连踩（spcomp 1.12.0.7220）

1. `native int X() = optional;` → **error 442: method aliases are no longer supported**（1.11 语法已移除）
2. `optional native int X();` → 编译**通过但解析器状态被破坏**：后续所有 include（sourcemod.inc/left4dhooks.inc）连环报 error 147（误导性报错，根因是 optional 关键字）
3. **正确姿势**：普通 `native int X(...);` 声明 + `AskPluginLoad2` 里 `MarkNativeAsOptional("X");`（core.inc 官方 API，`__ext_core_SetNTVOptional` 同款机制）→ 插件在 native 缺失时照常加载；**调用前仍须 `GetFeatureStatus(FeatureType_Native, "X")` 守卫**（调用已移除的 native 是运行时错误）

## 待实测验证

- 波次播报合并格式（三档各出现一次）
- 补偿档触发边界：倒地去重 30% 判定（如 8/24 = 0.333 ≥ 0.30 → 补偿；7/24 = 0.292 < 0.30 → 基础）
- Tank 波 ×3 播报（1050/600/825）与冷静期 ×1.5 叠加观感
- 零波/团灭不发分（团灭 round_end 打断自然不发）

相关：[[l4d2-specialspawner-config]] [[l4d2-tank-wave-mutator]] [[l4d2-si-hud-wallet-persistent]] [[l4d2-killfeed-mapend-reward]]

## v2.5.3 播报消失根因修复（2026-08-17 实锤）

- **症状**：剿灭播报消失（玩家在线实测），但积分实际已入账
- **根因**：SettleWaveClearScore 的 LogMessage 格式串 bug——`downDeaths=%d/%d` 缺
  第二个值 + `tank=%s` 传 int → 8 占位符 7 参数 → **每波结算抛 "String formatted
  incorrectly" 异常 → 函数中断 → 后面的 PrintToChatAll 播报永远不执行**
- **为何 v2.5.0 部署时没发现**：13:57 部署后空服休眠（hibernating）无波次，14:16 换图
  波次开跑才触发；errors 日志每波一条（当日 13 条）
- **修复**：补 g_iWaveBase 参数（/%d）+ tank 改 %d；8 格式符 ↔ 8 参数
- **教训**：LogMessage 格式串与参数数必须逐个数（SourcePawn 不检查），且空服休眠期
  验证不了运行时路径——**部署后必须等有玩家的波次确认日志**
- **并发**：另一 agent 同步在改同文件（v2.5.3 director_no_specials 暂停修复，区域
  不冲突），两修复合并在 de58db3 一次提交
