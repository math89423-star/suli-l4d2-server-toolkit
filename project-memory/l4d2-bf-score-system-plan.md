---
name: l4d2-bf-score-system-plan
description: BF1 计分系统后续计划 — step1 得分 reward 音效（连杀结算），后续计分玩法（掉率提升/SI 优先攻击）
metadata: 
  node_type: memory
  type: project
  modified: 2026-08-02T03:05:51.549Z
  originSessionId: 866c8f85-5fab-4830-987f-ed0da0dcea7c
---

# L4D2 BF1 计分系统（后续更新计划，2026-08-01 用户提出）

> 用户原话："既然bf有完整的得分reward音效，我们可以尝试设计一些计分不仅仅是播放音效，
> 还可以设计出更有趣的东西，例如计分越高，特感物品掉落概率提升，但是更容易被si优先攻击等。
> 但是这个功能设计较为复杂，可以列入后续计划。step1是要可以播放得分reward音效，
> 后续才是得分可以干什么"

## 愿景

BF1 风格**计分系统**：击杀得分不只是显示（当前 si_hud 横幅 +分 仅展示），
得分本身成为**游戏内资源**，带风险/收益设计：

| 得分效果 | 收益 | 风险/代价 |
|---|---|---|
| 高分 → 特感物品掉落概率提升 | 掉落更多道具 | — |
| 高分 → 更容易被 SI 优先攻击 | — | 特感 AI 集火 |

## 得分基准（实测，2026-08-02）

- **c3m1（死亡中心）4 人打完 = 3300 积分**（用户实测）
- 这是后续一切得分/商店平衡的基准锚点：调商店价格、掉落、积分获取速率时都参照
  这个"一关产出"量级；4 人是基准人数，人数变化时应按比例外推
- 用途举例：商店最贵商品（复活币 12000 / 榴弹 8000）≈ 3.6 / 2.4 关的产出，
  可据此判断商品定价是否合理

## 阶段规划

### Step 1：得分 reward 音效（连杀结算音效）—— ✅ 已完成（2026-08-01 v1.6.6）
- 6 个 BF1 award 音效（bfaward_sound.zip：UI_Award_DogTag/Medal/RankUp/WarBonds +
  UI_PurchaseSuccess + UI_SpottingIcon_PickUp，48k WAV）→ mp3 44.1k/192k → sound/battlefield/bf_streak_*.mp3
- **实现落在 si_hud（非 bf_killfeedback）**：streak 状态机唯一数据源在 si_hud
  （g_iKillStreak/g_fLastStreakKillTime/si_hud_bf_window），跨插件要 forward + 加载顺序依赖，不值
- 结算点：per-client one-shot timer（=bf_window），窗口真结束才播（触发时窗口未结束→重排），
  streak ≥2 按档位播 → 清零；round_end/断线/换图清状态
- 档位：2-3 spotting / 4-5 purchase / 6-8 war_bonds / 9-11 dogtag / 12-14 medal / 15+ rankup
- cvar：si_hud_streak_sound_enable/_volume/_l2/_l4/_l6/_l9/_l12/_l15（空=该档静音）
- v1.7.50 追加：连杀奖励（+30/+50/+100）真实入账 g_iWallet + g_iTotalScore（之前只显示
  不入账）；音效与结算解耦（低分连杀不播音效但奖励照发、结算卡照显）
- FIX L6 档从未响过：实际文件名 bf_award_war_bonds.mp3（带下划线），默认值/cfg 却写
  bf_award_warbonds.mp3 → 客户端 404 静音。已改源码默认 + cfg
- 坑已验证：mp3 进 AddFileToDownloadsTable + PrecacheSound（v4.4.0 模式，免 sound.cache）；
  **precache 在 OnMapStart，reload（late-load）会立即触发一次 OnMapStart，但读的是
  reload 瞬间的 cvar 值——先 rcon 设好 cvar 值再 reload，precache 即用新值**（2026-08-02
  实测，修正旧结论"reload 后必须换图才生效"）；客户端 cl_downloadfilter 必须 all（[[l4d2-cl-downloadfilter-none]]）

### Step 2：计分玩法（复杂，待 step1 完成后再设计）
- 需要先明确"得分"形态：临时（单局/会话内）？持久？——现得分仅横幅显示用，无持久存储
- 特感物品掉落概率：需找/写物品掉落干预（击杀特感时掉落物生成 hook）
- SI 优先攻击：干预特感 AI 目标选择（难度最高，涉及特感 AI 层；现有 PTG/特感战术插件
  是 AI 侧可扩展点，[[l4d2-si-tactical-v4]] / [[l4d2-si-composition-manager]]）
- 设计要点（平衡）：高收益必须配高风险（用户已明确"更容易被si优先攻击"作为代价）；
  数值可调（cvar 化）；防止 24 人服刷分不平衡

## 关联

- [[l4d2-bf-killfeedback]] — 音效插件（v4.4.0，新音效加这）
- [[l4d2-bf-kill-hud]] — si_hud 击杀 HUD（streak 状态机在这）
- [[l4d2-si-tactical-v4]] / [[l4d2-si-composition-manager]] — SI AI 侧扩展点
