/**
 * [L4D2] SI HUD — Unified Special Infected HP + Kill Display  v1.7.0
 *
 * Replaces:
 *   - l4d2_bf_killfeedback    (was kill sounds + center text + chat; now bf does sound only)
 *   - L4D_All_Infected_HUD_HP (persistent SI HP HUD)
 *   - l4d2_si_hp_hud          (per-SI HP bar on hit)
 *
 * Three display channels — no conflicts:
 *   - PrintCenterText  (upper-center):        kill banner ☠ (skulls + points) + SI HP on-hit
 *   - PrintToChatAll   (chat area):           colored kill feed
 *   - PrintHintText    (lower-center):        BF1-style kill card "[weapon] ☠ SI name" (v1.6.4)
 *
 * Changelog v1.7.93:
 *   - 可爆炸罐子最终方案（火炮 + 商店罐/桶/烟花）: 直接生成 prop_physics +
 *     罐模型（propanecanister001a / oxygentank01 / gascan001a / explosive_box001）
 *     = 地图罐子等价物。引擎爆炸能力由模型 propdata（physgun_interactions
 *     onbreak:explode_fire）承载，只有 prop_physics 破碎时触发——weapon_* 类名
 *     实体不走该路径（v1.7.90/91 实锤死亡静默消失；v1.7.92 give+drop 转换依赖
 *     槽位/拾取竞态）。社区定论：[L4D1 & L4D2] Weapon Prop Give Fix
 *     (alliedmods t-331053) / disawar1 Physics fix (t-178076)。移除 give+drop
 *     及 Timer_ArtCanDrop/Timer_ShopCanDrop；商店可爆炸类不再需要购买者中转。
 *
 * Changelog v1.7.63:
 *   - 奖励倍率改每档手配，加速曲线 (user 拍板): 旧 mult_step 每档 +1.5
 *     线性步进导致各段奖励增量近似持平（+299/+254/+283/+312/+341），
 *     杀 20 头和杀 100 头每档多拿的钱差不多，高段无激励。现在每档独立
 *     配置倍率 10/14/19/25/32/40（si_hud_streak_bonus_mult_l1..l6，
 *     删除 si_hud_streak_bonus_mult_step）：满档奖励 260/624/995/1483/
 *     2107/2887，增量逐段放大 +260/+364/+371/+488/+624/+780。
 *     段边界与音效档位不变（hw 20/40/55/70/85/100，音效自动跟随）。
 *
 * Changelog v1.7.62:
 *   - 音效档位重构为 L1..L6，对齐人头阶梯 (user 拍板): 旧音效档
 *     si_hud_streak_score_l2..l15（200/400/700/1100/1500/2000 分）是
 *     历史遗留——编号源自更早的连杀数量档（2/4/6/9/12/15 杀），v1.7.4
 *     改成按分数判定时没改名，导致"26 小僵尸 hw=26 落 20-40 段却播 400
 *     档音效"的错位。现在音效档位与奖励共用同一把尺子（hw 段）：
 *     L1=20-39 spotting、L2=40-54 purchase、L3=55-69 war_bonds、
 *     L4=70-84 dogtag、L5=85-99 medal、L6=100+ rankup。删除全部
 *     si_hud_streak_score_l2..l15 cvar；旧 si_hud_streak_sound_l2/l4/l6/
 *     l9/l12/l15 更名 si_hud_streak_sound_l1..l6。v1.7.60 门控保证
 *     hw>=20，结算必有音效（最低 L1），无静默档。
 *
 * Changelog v1.7.61:
 *   - 音效档位改按结算总额判定 (user 实测): 26 小僵尸 (hw=26) 达标发 +350
 *     奖励、结算卡 +490，却因击杀分 140 < L2(200) 落在无声档——奖励已发
 *     但没音效，卡面数字与听觉不匹配。档位判定从 score 改为 score+bonus
 *     （490 → L4 档音效）。v1.7.60 后结算整体已受 hw>=20 门控，v1.7.4 的
 *     "按击杀分防小僵尸刷档"已冗余（hw 门槛本身防刷），档位直接对应该次
 *     结算的总收益。
 *
 * Changelog v1.7.60:
 *   - 结算整体受阈值门控 (user 实测): 之前结算卡只在窗口关闭且 score>0 时
 *     必弹（单杀女巫 500、3 特感 hw=18 也弹"连杀结算"卡），只有奖励入账
 *     被 hw>=20 门控——hw=18 时无奖励却照弹结算卡 +295 误导。现在
 *     hw < 20（未达阈值）窗口关闭只静默重置连杀状态：不弹结算卡、不播
 *     奖励音效；达阈值（hw>=20）才结算（结算卡 + 奖励音效 + 奖励入账）。
 *     单只女巫 (hw=6) 不再触发任何结算。
 *
 * Changelog v1.7.59:
 *   - 统一 Witch 双 hook (user 拍板): 原先 Event_WitchSpawn（v1.7.16 加分
 *     hook）和 OnEntityCreated（v1.7.25 显示 hook）各挂一个
 *     SDKHook_OnTakeDamage，调用顺序不定 → 显示读 g_iDmgPtsKiller 时加分
 *     可能还没入账，击中女巫看不到 +伤害分。合并为一个 WitchTakeDamage
 *     （先加分入账 → 再 ShowWitchHP 显示，同函数内顺序保证），统一从
 *     OnEntityCreated 挂载（游戏事件无关，最可靠）；删除 Event_WitchSpawn
 *     与 Witch_OnTakeDamage。
 *
 * Changelog v1.7.58:
 *   - FIX Witch 死亡误当小僵尸 (user 实测): 引擎对 Witch 死亡也发
 *     infected_death。v1.7.56 修 infected_hurt 时提前 return 不记录实体 →
 *     g_iLastCommonEnt 永不为 witch → Event_InfectedDeath 的排除（v1.7.56
 *     加的）变死代码 → 女巫击杀被当小僵尸：† 横幅覆盖女巫横幅、5 分误入
 *     连杀（† 骷髅）、伤害分网格被误消费。修复：witch 受伤时恢复记录
 *     g_iLastCommonEnt（加分排除保留），死亡排除重新生效；小僵尸击杀卡
 *     读取伤害分前校验实体 classname 非 witch（防串台）。音效侧同步
 *     bf_killfeedback v4.4.4（infected_death 加 witch 守卫）。
 *
 * Changelog v1.7.57:
 *   - 积分/连杀与 HUD 显示解耦 (user 拍板): StackStreakKill 原藏在
 *     BuildBFBanner 里，被 si_hud_kill_hint_enable 门控——关 HUD 时特感/
 *     Tank/Witch 击杀会连击杀分和连杀一起丢，而小僵尸入账在门控外，
 *     行为不对称。现在 SurvivorKilledSI / SurvivorKilledWitch 在 points
 *     计算后立即入账（同小僵尸路径），BuildBFBanner 退化为纯显示函数
 *     （去掉内部调用和无用 points 参数）。
 *
 * Changelog v1.7.56:
 *   - FIX 手枪打 Witch 误显示"† 小僵尸" (user 实测): 引擎对 Witch 受伤也发
 *     infected_hurt（Witch 是 NPC 实体归在 infected 事件）→ si_hud 误当小僵尸
 *     加分+显示，且伤害分被计两次（common 系数 + Witch 系数）。已排除：
 *     Event_InfectedHurt 检查 entityid classname=="witch" 直接跳过；
 *     Event_InfectedDeath 同步排除（g_iLastCommonEnt 回退路径防误判）。
 *
 * Changelog v1.7.55:
 *   - FIX 击杀卡榴弹武器名英文 (user 实测): 引擎对 GL 击杀事件报 WeaponType
 *     值 "grenadelauncher"（无下划线，left4dhooks g_sWeaponTypes 定义），不是
 *     classname 后缀 "grenade_launcher" → 翻译表漏配 → fallback 显示原文英文。
 *     已加别名；两条都映射"榴弹"。
 *
 * Changelog v1.7.54:
 *   - FIX 连杀奖励门槛 (user 实测发现): v1.7.53 的 `if (hw > 0)` 导致 0~20 段
 *     也在计价——2 特感 (hw=12) 错发 12×1.3×10 = 156 奖励。第一档边界
 *     20 人头是门槛: hw < 20 → 奖励 0（3 特感 hw=18 同样不开闸）；达到后
 *     全段计价不变（hw=24 → 320）。
 *
 * Changelog v1.7.53:
 *   - 连杀奖励 = 加权人头 × 阶梯分段 (user 设计, 电费模式): 小僵尸 1 人头 /
 *     特感 6 人头；奖励 = Σ(各段实际人头 × 1.3 × 该段倍率)，段边界
 *     20/40/55/70/85/100，倍率一级 10 每段 +1.5（鼓励多杀）。落在阈值之间
 *     按实际值分段累计——无"差 1 人头跳档"悬崖。例: hw=30 → 410，
 *     hw=60 → 897，hw=100 → 1749。音效档位保持击杀分数制
 *     （200/400/700/1100/1500/2000）。救援不占人头。废弃
 *     si_hud_streak_bonus_l2/l4/l6。
 *
 * Changelog v1.7.52:
 *   - 击杀分公式重做 (user 设计): 基础分 = 特感实际最大血量 × 25%（向上取整，
 *     实时读 m_iMaxHealth，服务器调血后自动跟随）；Tank 1500 / Witch 500 固定
 *     （大头在伤害分）；爆头 ×1.5、满血 ×1.25 倍率制（取代固定 +50，连乘后
 *     统一 ceil——Witch 满血爆头 938 = 500×1.5×1.25）；近战加成取消。
 *     验证例: Tank 爆头 1500×1.5 = 2250。
 *   - 武器倍率 (user): 铁喷 (chrome) 并入木喷 1.5（原走 other 1.0）；
 *     普通手枪/双枪 1.75（新 cvar si_hud_bf_damage_mult_pistol）；马格南不变。
 *   - 废弃 cvar: si_hud_bf_points_smoker/boomer/hunter/jockey/spitter/charger、
 *     si_hud_bf_points_headshot/_melee/_fullhp（源码 + cfg 已清理）。
 *
 * Changelog v1.7.51:
 *   - 救援队友算分 (user 设计): revive_success 监听（拉人/电击统一走此事件），
 *     救援者 +si_hud_points_rescue（默认 75）入账钱包+总分，并计入连杀——
 *     刷新 6 秒窗口 + 累计滚动分（推动音效档位）+ 结算卡显示 "+ 救援 ×N"。
 *   - 档位判定口径定论 (user): 纯击杀分混合总分（小僵尸+特感击杀分同池），
 *     伤害分（打血分）不参与连杀任何环节——已单独入账，连杀是连杀。
 *     打 Tank 血没杀死不推动 award（边界场景作废，用户最终拍板）。
 *
 * Changelog v1.7.50:
 *   - 连杀奖励实际入账 (user 确认): 结算卡 "+累计分+奖励" 的奖励（si_hud_streak_bonus_l2/4/6，
 *     +30/+50/+100）之前只显示不入账（击杀分本就是击杀时即时入账），玩家误以为
 *     有额外奖励 → 现在 streak>=2 结算时真实加进历史积分（排行榜）和钱包（商店），
 *     结算数字 = 本连杀总收益。
 *   - 音效与结算解耦: 低分连杀（score < si_hud_streak_score_l2）之前整个 return
 *     （无音效无结算卡），现在只跳过音效，奖励照发 + 结算卡照显。
 *   - FIX L6 档音效从未播放 (nginx 404 实锤): 默认值/cfg 写成 bf_award_warbonds.mp3，
 *     实际文件名是 bf_award_war_bonds.mp3（带下划线）→ 客户端下载 404 静音，
 *     已改源码默认值 + cfg。
 *
 * Changelog v1.7.48:
 *   - 通道实验 (user 反馈 v1.7.47 的 1.5 反而更小): 引擎对 volume>1.0 处理
 *     异常 → 上限收回 1.0。SNDCHAN_STATIC 疑似走客户端音乐/UI 总线（受玩家
 *     音乐音量衰减）→ PlayStreakSound + PlayClientSound 均换 SNDCHAN_AUTO。
 *
 * Changelog v1.7.47:
 *   - 连杀结算音效调大 (user): 音量上限 1.0 → 2.0，默认 1.0 → 1.5。
 *     原代码把 EmitSoundToClient 音量钳制在 1.0（vol >= 1.0 ? 1.0 : vol），
 *     而 award mp3s 已 loudnorm 到 ~-15 dB —— 放开增益后 1.5x 无削波风险。
 *     改 cfg 中 si_hud_streak_sound_volume 为 1.5 后 reload 生效。
 *   - 残留 cvar 坑 (实测): 该 cvar 已被引擎自动创建（cfg exec），
 *     CreateConVar 拿到已有 cvar 不更新 def/max → 值被钳在 1.0。
 *     修复: SetBounds(ConVarBound_Upper, 2.0) + SetDefault("1.5") 强制重设。
 *
 * Changelog v1.7.46:
 *   - 激光根本原因确认 (errors 日志实锤): L4D2 武器无 m_bHasLaserSight prop
 *     （CS 系列的）——SetEntProp 抛 "Invalid property" 运行时错误中断。
 *     改用 SDKCall CBaseCombatWeapon::SetHasLaserSight（Linux 符号，
 *     gamedata/l4d2_si_hud.txt）；初始化失败回退脚下 spawn 升级包。
 *   - 激光临时调价 1 分测试已完成，已恢复 3500。
 *
 * Changelog v1.7.45:
 *   - FIX 激光购买走退款分支 (实测日志): 菜单打开时 m_hActiveWeapon 读不到
 *     → 改用 GetPlayerWeaponSlot(client, 0) 主武器槽（不受菜单状态影响）。
 *     激光加在主武器上。
 *
 * Changelog v1.7.44:
 *   - 商店新商品：电锯 (weapon_chainsaw) 5000 分，无限购（user）。
 *
 * Changelog v1.7.43:
 *   - FIX 同战役换图积分丢失 (user 实测): L4D2 changelevel 时客户端断线
 *     自动重连 → v1.7.42 的"进服 0"把换图重连当新加入清空钱包。
 *     断线记录 (SteamID, 时间)，20s 内同 ID 重连 = 换图重连 → 恢复存档；
 *     否则 = 真实新加入 → 全默认 0。
 *
 * Changelog v1.7.42:
 *   - 新加入玩家进服一律全默认（0 可用积分 + start 复活币，user）——
 *     不再从持久化文件恢复（防中途进服带旧钱）；持久化恢复只用于
 *     reload 时在线玩家。注：断线重连也视为新加入（进服 0）。
 *
 * Changelog v1.7.41:
 *   - 战役首图（地图名含 m1）→ 可用积分/复活币一律清零（user：m1 首图
 *     开始应该都是 0；补上同前缀重开 c2m5→c2m1 的漏洞）。
 *
 * Changelog v1.7.40:
 *   - FIX 切战役后可用积分仍保留 (user 实测): reload/重启后 g_sPrevCampaign
 *     为空 → 战役切换判定失效（strlen==0 跳过清零）→ 上战役的钱被持久化
 *     恢复。双修复: ①OnPluginStart 初始化当前图前缀（判定基准恢复）；
 *     ②持久化文件存战役标记，恢复时校验（跨战役存档不恢复）。
 *
 * Changelog v1.7.38:
 *   - FIX 激光不生效 (user 实测 v1.7.37 无效): 直接设 m_bHasLaserSight prop
 *     客户端不渲染光束 → 改回升级包但 spawn 在脚下（接触自动拾取，引擎
 *     完整拾取路径，100% 生效）。
 *
 * Changelog v1.7.37:
 *   - 激光瞄准改为直接给当前武器加激光（user 确认，不再掉升级包）：
 *     SetEntProp m_bHasLaserSight；无武器异常时退款。
 *
 * Changelog v1.7.36:
 *   - 全部商品不限购（user）——只有复活币受持有上限 5 约束。
 *
 * Changelog v1.7.35:
 *   - FIX 团灭重开可用积分未重置 (user 实测): 存档/回滚补上钱包——
 *     团灭重开时可用积分回到本图开局值（本图内赚的作废，上图攒的保留；
 *     过关换图仍不清，新战役仍清零）。60s/断线保存自动同步回滚后的值。
 *
 * Changelog v1.7.34:
 *   - 持久化 (user 确认): 钱包 + 复活币按 SteamID 存 KeyValues
 *     (data/si_hud_scores.txt)。保存时机: 断线 / OnPluginEnd(reload) /
 *     60s 周期 / 新战役清零后；进服恢复（无存档 = 新玩家默认 0+start 币）。
 *     彻底解决 reload/重启丢战役资产；reload 后在线玩家也从文件恢复。
 *
 * Changelog v1.7.33:
 *   - 瓦斯罐/煤气罐去掉每图限购（user）→ 无限购（limit 0）。
 *
 * Changelog v1.7.32d (bug fix):
 *   - FIX reload 后复活失效: plugin reload 不触发 OnClientPutInServer，在线玩家
 *     g_iRevivesLeft=0 → 死亡无自动复活，只看到引擎原生的 30s 僵尸重生倒计时
 *     （玩家实测"HUD 显示 30 秒"）。OnPluginStart 末尾补全在线玩家初始化
 *     （复活次数 base + 复活币 start + 钱包/积分清零）。
 *   - bot 排除: 复活判定跳过 IsFakeClient（引擎 bot 有自己的重生逻辑）。
 *
 * Changelog v1.7.32c (bug fix, user tested):
 *   - FIX !buy 菜单不显示: L4D2 引擎菜单 (VguiMenu) 标题不支持 \n 换行 —
 *     多行标题整个菜单不渲染（服务器端 Display 返回 OK，客户端无任何显示；
 *     对照 !csm 用 Panel 单行标题正常）。标题改单行即修复。
 *     排障链路: 命令触发日志 → Display 返回值日志 → 对照 Panel → 标题单行。
 *
 * Changelog v1.7.32:
 *   - 排行榜播报（45s + 地图结束结算）末尾追加商店入口提醒：
 *     "输入 !shop 或 !buy 打开商店，用可用积分兑换补给/武器"（user）。
 *
 * Changelog v1.7.31b (static review fixes):
 *   - FIX 丢钱 Bug: 复活币持有上限检查在扣款之后 → 达上限购买扣 12000 不给币；
 *     检查移到扣款前。
 *   - FIX 限购泄漏: OnClientDisconnect 未清 g_iShopBought → 下个进服玩家
 *     继承"已购满"。
 *   - FIX 越界风险: witch 实体索引写入/读取 (ShowWitchHP / witch kill card /
 *     WitchTakeDamage) 无 < 2048 检查 → 补上（SourcePawn 越界=运行时错误）。
 *   - FIX 句柄: 复活计时器 + 倒计时 DataPack 加 TIMER_FLAG_NO_MAPCHANGE
 *     （换图不再留下悬挂句柄/泄漏 dp）。
 *
 * Changelog v1.7.31:
 *   - 新加入玩家 = 全默认状态 (user)：0 可用积分 + si_hud_respawn_coin_start
 *     (2) 枚复活币 + base 复活次数；显式初始化全部槽位。
 *
 * Changelog v1.7.30:
 *   - 每图开始积分存档 (user："每一个Map开始时，要有一个存档")：
 *     OnMapStart 拍快照（本关积分/特/死/友伤/被黑），团灭重开
 *     (round_start 且非新图加载 = 同图 restart) 回滚到快照 + 复活次数回初始
 *     + 杀旧计时器。钱包/复活币为战役级资源不受影响。
 *
 * Changelog v1.7.29:
 *   - 复活币持有上限 5 枚 (user, si_hud_respawn_coin_max)：购买前检查
 *     （达上限拒绝购买），进入游戏/新图时 clamp；消耗复活币时播报剩余数量。
 *
 * Changelog v1.7.28:
 *   - RESPAWN LIMIT (user): 每图初始 si_hud_respawn_base (2) 次自动复活
 *     (=3 条命), 复活延迟 si_hud_respawn_delay 15s (was 35 via l4d2_auto_
 *     respawn — 该插件已卸载，功能并入本插件: 倒计时提示 + 复活传送队友)。
 *     次数用完 → 消耗复活币 (死亡时自动)；都没有 → 躺尸等电击器/过关，
 *     电击器回归价值。
 *   - 商店新商品 复活币 12000 (无限购, classname 空 = 不 spawn, 余额+1)。
 *   - 积分语义修正 (user): 排行榜积分每关从 0 算 (OnMapEnd 清零)；可用积分
 *     (钱包) 战役内跨图保留，新战役 (地图前缀变化) 才清零；复活币同战役级。
 *   - 播报 (排行榜/结算) 追加: 可用积分 + 复活币余额 + 本图剩余复活次数。
 *   - 电击器/医疗包价格 3000 → 4000 (user)。
 *
 * Changelog v1.7.27:
 *   - SCORE SHOP (!shop / !buy): spend the CURRENT score (g_iWallet) —
 *     瓦斯罐 800, 煤气罐 800, 汽油桶 2000, 止痛药 2000, 肾上腺素 2000,
 *     电击器 3000, 医疗包 3000, 激光瞄准 3500 (个人效果), M60 5000,
 *     榴弹发射器 8000. Prices/limits compile-time in g_ShopTable; per-map
 *     purchase limits; items drop in front of the buyer (trace + glow);
 *     heavy weapon models precached on map start.
 *   - TWO score tracks (BF style, user spec): g_iTotalScore = HISTORICAL
 *     (scoreboard shows this only; NO LONGER resets on map end — 跨图累计),
 *     g_iWallet = CURRENT (spendable; also survives map end — 跨图攒大件).
 *     Both reset on disconnect; server restart clears memory (no persistence).
 *   - Complements loot_drop v1.7.0 (user loot table: common 1% vomitjar/
 *     pipe bomb 50/50; SI 7% across 5 independent rolls; Tank 必掉
 *     medkit+M60/GL+3 throwables; Witch 4选1).
 *
 * Changelog v1.7.26:
 *   - Scoreboard name back to GREEN (user): \x07RRGGBB renders as literal
 *     text "38B6FF" in L4D2 chat — only \x01-\x05 color codes work. The
 *     space separation and green numbers stay.
 *
 * Changelog v1.7.25:
 *   - SI/Witch kill cards show the killer's FULL kill score (user "还有
 *     特感呢"): own damage share on that target + kill points
 *     ("[MAGNUM] ☠ HUNTER +117" = 100 kill + 17 dmg).
 *   - Damage-point buffer refactored to per-killer grid
 *     g_iDmgPtsKiller[killer][entity]: every display (SI HP line, Witch HP
 *     line, common kill line, SI/Witch kill cards) now shows ONLY the
 *     killer's own share — multi-killer fights no longer inflate numbers.
 *   - Scoreboard style (user): numbers GREEN, labels default color, name
 *     BLUE (\x0738B6FF — \x07RGB works in chat), spaces between labels
 *     and numbers ("1748 分 特 6 死 0 友伤 0 被黑 0").
 *
 * Changelog v1.7.24:
 *   - FIXED the "kill line shows +5" bug (root cause from v1.7.23 debug
 *     logs): the L4D2 infected_death event HAS NO entity field — GetInt
 *     "entityid" returns 0 (hurt carries ent=126 pts=13, death carries
 *     ent=0). The kill line now looks the dmg pts up via the killer's
 *     last-hit common entity (g_iLastCommonEnt): a kill always belongs to
 *     the last common the killer hit (one-shot = same entity hurt→death).
 *     Shotgun multi-kills: only the LAST kill is exact (acceptable).
 *
 * Changelog v1.7.23:
 *   - Damage points ÷10 (user): both coeff cvars 1.0 → 0.1 — a 50hp common
 *     scores 5 dmg pts (not 50), so headshot kills (10) no longer look
 *     trivial next to raw damage. 10 damage = 1 point for all targets.
 *   - DEBUG LogMessage on common hit/kill (entityid/pts/dmgPts) — hunting
 *     the "kill line still shows +5" report (dmgPts not surfacing).
 *
 * Changelog v1.7.22:
 *   - BF-style hit feedback for commons (user): EVERY damage tick shows
 *     its score — "† 小僵尸 +52" (dmg pts only) on every hit, no kill
 *     required (BF1/BFV pop the damage score on each hit). Same-frame
 *     kills overwrite with the +92 kill line (hurt fires before death).
 *
 * Changelog v1.7.21:
 *   - Common kill line shows the FULL kill score (user spec): this target's
 *     damage points (dmg × weapon mult — magnum 50hp = 87) PLUS the fixed
 *     kill points (5/10) → "† 小僵尸 +92" per "50×1.75 + 5". The damage
 *     pts for commons were already scored on hit; now they also SURFACE on
 *     the kill line (commons have no HP row to show them on). Same buffer
 *     g_iDmgPts[entity], consumed with the kill.
 *
 * Changelog v1.7.20:
 *   - Damage points NOW VISIBLE in the hit area (user: "hit区域还是只有
 *     击杀得分"): the SI HP line appends "+N" (e.g. "HUNTER [|||||     ]
 *     132/250 +8") — same for the Witch HP line. Buffer g_iDmgPts[2048]
 *     keyed by ENTITY index (SI client idx + Witch entity idx), accumulated
 *     per hurt event, consumed+zeroed by the per-frame HP display, fully
 *     cleared on round end (mid-frame-dead victims cannot leak). Only
 *     populated when the HP display is on (else nothing consumes it).
 *     Commons damage points deliberately NOT shown (horde spam).
 *
 * Changelog v1.7.19:
 *   - Settle tally ALSO flashes in the center hit area for 2s (user) with
 *     the icon version "† 小僵尸 ×3、☠ 特感 ×2、+430分" (center/HUD font
 *     has those glyphs); the chat line stays plain-text (Verdana lacks
 *     ☠/†; × renders wrong there → ASCII "x").
 *
 * Changelog v1.7.18:
 *   - Settle tally: × (U+00D7) → ASCII "x" (user saw it render wrong in
 *     chat); prefix "[战地]" → "[得分]" (user: unified with the scoreboard
 *     "[得分榜]" style — half-width brackets).
 *
 * Changelog v1.7.17:
 *   - Streak window si_hud_bf_window 10s → 6s (user: 10s too long).
 *
 * Changelog v1.7.16:
 *   - BF-style damage points (user): everyone who damages an SI (incl.
 *     Tank) earns score — tank/charger fights are fair, not just the final
 *     killer. points = dmg_health × weapon mult × si_hud_bf_damage_coeff
 *     (default 1.0: 1 damage = 1 point, weapon mults deviate). Goes to
 *     the scoreboard total only — NOT the streak
 *     (award = kill streaks), NOT the chat (spam). Witch + commons excluded
 *     (no player_hurt events). Kill points do NOT scale by weapon (user).
 *   - Weapon-class damage multipliers: AR 1.0 / SMG 1.5 / magnum+melee
 *     1.75 / pump shotgun 1.5 / auto shotguns + snipers 0.75 / other 1.0.
 *   - Streak settle record moved to the killer's OWN chat box (user): the
 *     old 2s center card vanished before the longer award sounds ended.
 *     Chat lines persist, so the tally stays visible while the sound plays.
 *   - Common infected HP damage ALSO earns damage points (user) via the
 *     infected_hurt event (commons fire no player_hurt). Independent coeff
 *     cvar si_hud_bf_damage_coeff_common (default 1.0); watch the board —
 *     at 1.0, horde-mowing out-scores SI kills.
 *   - Witch damage points via SDKHooks_OnTakeDamage (witch_spawn hook) —
 *     she is an NPC: no player_hurt, no infected_hurt.
 *   - CHAT-SAFE chars (user): the chat font (Verdana) has NO Box Drawing
 *     (═ → "?") and NO ☠ (U+2620 → "?") — scoreboard dividers are now
 *     ASCII "-", the settle tally dropped †/☠ icons (plain text, × stays:
 *     U+00D7 is Latin-1). Icons stay in the center channel (HUD font OK).
 *
 * Changelog v1.7.15:
 *   - Player names shown in green (user); names are sanitized (control
 *     chars stripped) so a crafted name cannot inject color codes.
 *
 * Changelog v1.7.14:
 *   - Scoreboard switched to compact single-line rows (user choice): the
 *     L4D2 chat font is proportional (Verdana), so space-padded column
 *     alignment can never work. "#1 Ellis：680分 特5 死0 友伤8 被黑0".
 *     Removed PadRight/DisplayWidth/TruncateToWidth.
 *
 * Changelog v1.7.13:
 *   - REAL alignment fix: removed the / color codes from inside the
 *     scoreboard rows — L4D2 chat renders them as invisible placeholders
 *     (~1 col each), so the row had 2 extra columns vs the header and every
 *     column after the colored score shifted. Now only the shared
 *     "[得分榜]" prefix is colored; alignment is pure spaces.
 *
 * Changelog v1.7.12:
 *   - Alignment FIX (user screenshotted): header column widths now equal
 *     the data column widths (特感/死亡 3, 友伤 4, 被黑 3 — the CJK labels
 *     are 2 cols each and were padded wider than the %-Nd columns), and
 *     separators are 1 space on both header and rows.
 *
 * Changelog v1.7.11:
 *   - Long player names no longer shift the columns: over-width names are
 *     truncated to the column width (width-2 + "…", never splitting a
 *     UTF-8 codepoint).
 *
 * Changelog v1.7.10:
 *   - Scoreboard number columns left-aligned (user) to match the header.
 *
 * Changelog v1.7.9:
 *   - Scoreboard stats now survive until MAP end (round_end only resets the
 *     streak state — a wipe-restart keeps the map's tally).
 *   - Map-end final broadcast: checkpoint/finale finish (map_transition)
 *     force-broadcasts the scoreboard once; other changelevel paths
 *     (vote / wipe-mapchange) fall back to OnMapEnd. Flag prevents double.
 *
 * Changelog v1.7.8:
 *   - Scoreboard rendered as an aligned TABLE: columns padded by display
 *     width (CJK = 2 cols, ASCII = 1) with ═/─ borders and a header row —
 *     "# | 玩家 | 得分 | 特感 | 死亡 | 友伤 | 被黑", sorted by score.
 *
 * Changelog v1.7.7:
 *   - Scoreboard now shows FIVE stats per player, sorted by total score:
 *     score (分), SI kills (特), deaths (死), friendly-fire damage (友伤),
 *     killed-by-teammate count (被黑, user: "被队友击杀次数").
 *     Tracked in player_death (deaths + blacked) and player_hurt
 *     (survivor→survivor damage); SI kills via StackStreakKill.
 *
 * Changelog v1.7.6:
 *   - Chat scoreboard (user): type !rank / !score / !top in the Y-key chat —
 *     top si_hud_scoreboard_top (6) scorers, a divider line, then your own
 *     score + rank ("[得分榜] #1 粟藜 1234分 / ---- / 你的得分：456分（第 12 名）").
 *     ALSO auto-broadcast per-player every si_hud_scoreboard_interval (45s,
 *     0=off; interval change needs reload). Backed by session total
 *     g_iTotalScore (all kill points incl. commons), reset per round/map end/disconnect.
 *
 * Changelog v1.7.5:
 *   - Settle card is now a text tally (user): "† 小僵尸 ×3、☠ 特感 ×2、+430分"
 *     — commons first, zero-count entries omitted, total = kills + streak bonus.
 *
 * Changelog v1.7.4:
 *   - Icon row rework (user): SI skulls (☠) and common daggers (†) counted
 *     SEPARATELY (3 commons + 1 SI → "☠ †††", not 4 skulls); one row of up
 *     to si_hud_icons_max (15) icons, over that shows "+N" (not "N+x").
 *     Commons now also grow the icon row (two-line display like the SI card).
 *   - Award tiers now trigger on the SETTLED SCORE, not the kill count
 *     (si_hud_streak_score_l2..l15, defaults 200/400/700/1100/1500/2000):
 *     common spam (5-10 pts) cannot climb tiers; a single Tank/Witch kill
 *     (500+) lands in tier 4. Streak count is still shown on the settle
 *     card. Keep: common scoring 5/10, commons refresh the window (user).
 *
 * Changelog v1.7.3:
 *   - Common infected fully taken over: kills now score (5 base + 5 headshot,
 *     cvar si_hud_bf_points_common/_common_hs), stack the streak (→ the
 *     streak window and the award settle), and show a short center line
 *     (si_hud_common_time 1.0s): "† 小僵尸 +5" (U+2020 dagger marks commons;
 *     headshot shows ★ U+2605 — same "gold" marker as the SI card, center
 *     text has no color codes). No chat feed (spam). Headshot kill sound
 *     unchanged. Streak stack logic extracted to StackStreakKill().
 *
 * Changelog v1.7.2:
 *   - User tuning: streak window si_hud_bf_window 4.0 → 10.0 (the streak-
 *     interrupt timeout); kill card stays at si_hud_killcard_time 2.0.
 *   - Scoring overhaul (BF1/BF5 reference): per-class base points by
 *     difficulty + max HP (Boomer/Smoker 75, Hunter/Jockey 100, Spitter 125,
 *     Charger 150, Witch/Tank 500) + headshot +50 / melee +50 / full-HP +50
 *     (SI never hurt before dying — tracked via player_hurt, reset on
 *     player_spawn/round_end/map end). Tank now gets bonuses too; Witch
 *     gets headshot/melee (no full-HP: player_hurt never fires for NPCs).
 *   - Streak settle display (BF1 multi-kill bonus): when the window closes
 *     with streak >= 2, alongside the award sound the killer sees
 *     "☠☠ 连杀结算 ×3 +430" (accumulated score + streak bonus
 *     +30/+50/+100 for 2-3/4-5/6+) for 2s on the center channel.
 *   - Volume: si_hud_streak_sound_volume 0.9 → 1.0; all six award mp3s
 *     re-mastered to uniform loudness (loudnorm mean ≈ -15 dB, previously
 *     -15 to -26 dB) and re-shipped as bf_award_*.mp3 (new names force
 *     clients to re-download; old bf_streak_* files deleted).
 *
 * Changelog v1.7.1:
 *   - User decision: the kill card leaves PrintHintText for good. Banner +
 *     card merge into ONE two-line PrintCenterText message (BF5-style:
 *     "☠☠☠ 爆头击杀 +150" over "[M16] ☠ HUNTER 猎人"), shown for
 *     si_hud_killcard_time (2.0s) then cleared with " " — the center
 *     channel has no shadow box, no priming bug, and clears instantly.
 *     The hint channel is a dead end on L4D2: ~10s engine display (NOT the
 *     ~4s of CS:GO) that cannot be shortened without the "" purge that
 *     garbles the next CJK hint. (HudMsg/ShowHudText/game_text are dead
 *     too — L4D2 client font/splitscreen bugs, AM thread p=2792713.
 *     KeyHintText shows nothing on this build either.)
 *   - Dropped the "(head shot)" suffix: headshots now show a GOLD ☠
 *     (BF5-style; center text does parse \x07RRGGBB colors — mode 13).
 *     The headshot point bonus already existed (si_hud_bf_points_headshot).
 *   - si_hud_banner_time deprecated: banner + card now share one message
 *     timed by si_hud_killcard_time (default 2.0s).
 *   - SOUND FIX (streak award was silent): the play/precache path stripped
 *     the .mp3 extension — L4D2 resolves bare sound names to .wav only, so
 *     precache and playback both failed silently. Now keeps the full path
 *     (verified pattern from bf_killfeedback v4.2.0) + SOUND_FROM_PLAYER.
 *   - bf_streak_spotting.mp3 was mastered at -18.4dB peak (8x quieter than
 *     the other awards) — re-mastered to -1.6dB and shipped as
 *     bf_streak_spotting_v2.mp3 (new name so clients re-download it).
 *
 * Changelog v1.7.0:
 *   - REAL FIX (user retested v1.6.9: garble STILL there, ~10s straight):
 *     the "" purge was the root cause all along. PrintHintText("") destroys
 *     the client's hint display list and resets the channel to its initial
 *     empty state; the next CJK hint sent on the channel — no matter how it
 *     is preceded by a " " prime — renders garbled. (v1.6.8/1.6.9 only
 *     removed same-frame collisions BETWEEN the purge and other messages,
 *     which is why they changed nothing.) Proof from history: the card was
 *     never garbled before v1.6.6 introduced the purge (v1.6.4/1.6.5 used
 *     natural fade-out). Fix: REMOVE ALL ACTIVE CLEARING. The card now fades
 *     out with the engine's fixed ~4s hint timer — text and shadow box are
 *     one element and fade together, nothing lingers. si_hud_killcard_time
 *     is DEPRECATED (the engine hint duration is fixed at ~4s and cannot be
 *     shortened; the cvar is kept only so existing cfg files don't error).
 *
 * Changelog v1.6.9:
 *   - FIX (v1.6.8 did NOT fix the user's garble): v1.6.8's guard only blocked
 *     the "prime + purge same frame" race. The OTHER collision — a card being
 *     displayed and purged in the SAME frame — was left open: Frame_ShowKillCard
 *     runs at frame start and resets g_bKillCardQueued, so when an expiry
 *     deadline lands in the card's display frame the timer still sends "" ,
 *     and card + "" hit the client in one tick. Any same-tick display+purge
 *     can corrupt the hint render state (same family as the v3.5.1 CJK-tear
 *     fix — two PrintHintText messages in one frame resizing the box).
 *     Fix: a perpetual RequestFrame chain keeps a per-frame counter; the card
 *     records the frame it was displayed in, and Timer_HideKillCard skips the
 *     clear when it expires in that same frame (the newer card's own timer
 *     clears it). This is order-independent — no reliance on event-vs-timer
 *     sequencing inside a frame. Also fixed the si_hud_version ConVar never
 *     updating (CreateConVar doesn't overwrite existing cvars — the runtime
 *     value still said 1.6.5; plugin Version field was already correct).
 *
 * Changelog v1.6.8:
 *   - FIX (user feedback): kill card text shows GARBLED (乱码) when
 *     si_hud_killcard_time is reduced. Root cause: a frame race between the
 *     hide timer and the card prime. Timer_HideKillCard fires at END of the
 *     frame its deadline falls in and sends PrintHintText("") which PURGES
 *     the client's whole hint list. If a kill lands in that same frame, the
 *     kill's " " prime was already sent mid-frame — the wire order becomes
 *     " " → "" → card, the purge deletes the prime, and the card becomes the
 *     FIRST hint on an idle channel → CJK renders garbled (priming bug).
 *     Smaller killcard_time → kills collide with expiry frames more often.
 *     Fix: Timer_HideKillCard now skips the clear while g_bKillCardQueued is
 *     set (a newer kill's prime is in flight — its own hide timer will clear
 *     the card). The prime survives, so the card always replaces a live hint.
 *
 * Changelog v1.6.7:
 *   - ADD: BF1-style rolling score counter — the kill banner now shows the
 *     ACCUMULATED streak score (100 → 250 → 400 …) instead of the single
 *     kill's points, so the number visibly grows with every kill inside the
 *     window (BF1's "animated score counter" feel). Resets when the streak
 *     settles (with the award sound), on round_end, map end and disconnect.
 *
 * Changelog v1.6.6:
 *   - FIX (user feedback): kill card lingered ~4s despite the v1.6.5 clear.
 *     Root cause: the KeyHintText count=0 clear is IGNORED by the L4D2 client
 *     (card waited out the engine's fixed ~4s hint timer). Replacement:
 *     CHudHintDisplay::AddHint treats an EMPTY-STRING hint as "clear the whole
 *     display list" (PurgeAndDeleteElements) — so ClearHintBox now sends
 *     PrintHintText(""). Note " " (space) does NOT work — a space is a
 *     non-empty hint that lingers 4s (v1.4.1 finding). Card now hides after
 *     si_hud_killcard_time (2.0s) for real.
 *   - ADD: BF1 streak award sounds (Step 1 of the score system). When a kill
 *     streak settles (window si_hud_bf_window ends with streak >= 2), the
 *     killer hears the BF1 award sound for their streak tier:
 *       streak 2-3   → bf_streak_spotting.mp3   (UI_SpottingIcon_PickUp)
 *       streak 4-5   → bf_streak_purchase.mp3   (UI_PurchaseSuccess)
 *       streak 6-8   → bf_streak_war_bonds.mp3  (UI_Award_WarBonds)
 *       streak 9-11  → bf_streak_dogtag.mp3     (UI_Award_DogTag)
 *       streak 12-14 → bf_streak_medal.mp3      (UI_Award_Medal)
 *       streak 15+   → bf_streak_rankup.mp3     (UI_Award_RankUp)
 *     Per-client one-shot settle timer; window-gap re-checks on fire. Streak
 *     resets on settle and on round_end. Sounds distributed via
 *     AddFileToDownloadsTable + PrecacheSound (same channel as v4.4.0 mode,
 *     no sound.cache needed). New cvars si_hud_streak_sound_enable/_volume/
 *     _l2/_l4/_l6/_l9/_l12/_l15 (empty path = tier silent).
 *
 * Changelog v1.6.5:
 *   - TIMING (user feedback): kill card hides after si_hud_killcard_time
 *     (2.0s) and the center banner after si_hud_banner_time (1.0s).
 *   - Card clear via KeyHintText count=0 (protocol-level, EXPERIMENTAL):
 *     HintText and KeyHintText share the client's hint display list
 *     (CHudHintDisplay), so sending an empty KeyHintText removes the card
 *     AND its shadow box immediately — no 4s engine hint timer, no empty
 *     box. If this proves ineffective on this build, the card simply falls
 *     back to natural fade-out (harmless, just stays ~4s).
 *   - New cvar si_hud_banner_time (default 1.0) — center banner duration.
 *
 * Changelog v1.6.4:
 *   - REWORK (user feedback): kill card back on PrintHintText — the hint's
 *     dark shadow box IS the BF1-style card background the user wants
 *     (lower-center, shadowed box). Never actively clear it: v1.4.1 proved
 *     PrintHintText(" ") leaves an EMPTY BOX on screen — the "clear" message
 *     is itself a 4s single-slot hint whose empty text keeps the box alive.
 *     Natural fade-out is the only clean end: text + box fade together
 *     (same element). The ☠ skull banner stays on PrintCenterText.
 *   - Kill card is single-slot REPLACE on the engine side: every new hint
 *     resets the fixed 4s display timer, so rapid kills refresh instantly
 *     (no queue lag). First-hint priming bug handled per card: prime " "
 *     (invisible) then show the real card next frame (v1.6.0 pattern).
 *   - Removed: killcard clear timer / KillKillHintTimer (no active clear).
 *   - BuildKillDisplay → BuildKillCard (card line only; streak skulls and
 *     points live in the center banner via BuildBFBanner).
 *
 * Changelog v1.6.0:
 *   - ADD: BF1-style kill card on PrintHintText (lower-center) — big type
 *     word (KILL / HEADSHOT / MELEE / TANK / WITCH) + SI name + points.
 *     The hint's dark shadow box doubles as the card background (that's the
 *     BF1 look); we NEVER actively clear it (v1.4.1: even " " leaves the box
 *     for seconds) — natural fade-out only. First-hint priming bug handled
 *     by sending an invisible space prime, then the real card next frame.
 *   - The ☠ skull banner on PrintCenterText (upper-center) is kept as-is.
 *
 * Changelog v1.6.1:
 *   - REWORK kill card format (user feedback): single line
 *     "[weapon] ☠ SI name" (headshot: "[weapon] ☠ SI name(head shot)")
 *     — dropped the big type word + points line.
 *   - ADD auto-clear: card hides after si_hud_killcard_time (default 2.5s)
 *     via PrintHintText(" ") — text vanishes immediately; the shadow box
 *     lingers until its natural fade (engine limitation, v1.4.1).
 *
 * Changelog v1.6.2:
 *   - FIX: shadow box lingering after card text cleared — PrintHintText
 *     CANNOT be cleanly cleared on this engine (v1.4.1 finding: even " "
 *     leaves the dark box until natural fade). Migrated the kill card onto
 *     the PrintCenterText channel, merged with the ☠ skull banner as ONE
 *     multi-line message (skull row on the upper line, card on the lower
 *     line). PrintCenterText has no shadow box and clears instantly with
 *     " " (already proven v1.4.1). Kill card timer reuses Timer_HideHP.
 *
 * Changelog v1.4.1:
 *   - FIX: kill confirm reverted from PrintHintText to PrintCenterText.
 *     PrintHintText shadow box cannot be truly cleared — even " " (space)
 *     keeps the dark background box visible, and the engine only fades it
 *     after several seconds. PrintCenterText has no shadow → clean clear.
 *   - FIX: SoundCooldownOK no longer blocks HUD/chat display. Sound cooldown
 *     now only gates the EmitSoundToClient call, not the entire kill handler.
 *
 * Changelog v1.5.0:
 *   - BF-style kill banner replaces the plain "☠ 特感名" kill confirm:
 *     line 1 = ☠ skull row, one skull per kill inside the streak window
 *     (BF5-style side-by-side, capped at 6); line 2 = kill type · SI name
 *     + points. Points: SI 100 / headshot +50 / melee +50 / Tank 500 /
 *     Witch 500, all cvar-tunable. Same gate: si_hud_kill_hint_enable.
 *
 * Changelog v1.3.2:
 *   - FIX: Frame_ShowHurtVictims no longer clears PrintCenterText when all victims
 *     died (shown==0), which was overwriting the kill-confirm message
 *   - CHANGE: kill confirm format — "💀 特感名 后缀" instead of "[武器] KILL ..."
 *     (SI kills, Witch kills, suicide / environment deaths)
 *
 * Changelog v1.3.1:
 *   - FIX: hitting ONE SI no longer shows HP of ALL SI — only the hit victim(s)
 *   - AoE / penetration: same-frame hits are batched via RequestFrame, all hit
 *     victims shown together; duplicate hits (e.g. shotgun pellets) deduplicated
 *
 * Changelog v1.3.0:
 *   - SI HP now shows ONLY when you damage the SI (on-hit), not persistent
 *   - HP auto-hides after si_hud_hp_interval seconds (default 0.5 s)
 *   - Kill confirm moved from PrintHintText to PrintCenterText — eliminates
 *     the hint-box shadow artifact that PrintHintText leaves on clear
 *
 * Dependencies: sourcemod + sdktools
 * Pure server-side. No client files needed.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>   // v1.7.28: L4D_RespawnPlayer（复活系统并入本插件）
#include <float>         // v1.7.80: 火炮 Sqrt/Cos/Sin

#define PLUGIN_VERSION "1.7.93"

// ============================================================================
// ConVar handles
// ============================================================================

ConVar g_cvEnable;
ConVar g_cvHPEnable;
ConVar g_cvHPInterval;
ConVar g_cvHPShowWitch;
ConVar g_cvChatEnable;
ConVar g_cvKillHintEnable;
ConVar g_cvKillCardEnable;
ConVar g_cvKillCardTime;
ConVar g_cvBFWindow;
ConVar g_cvBFPointsBasePct;        // v1.7.52: 基础分 = 特感实际血量 × %
ConVar g_cvBFHeadshotMult;         // v1.7.52: 爆头击杀倍率
ConVar g_cvBFFullHPMult;            // v1.7.52: 满血击杀倍率
ConVar g_cvBFPointsTank;            // v1.7.52: Tank 固定击杀分
ConVar g_cvBFPointsWitch;           // v1.7.52: Witch 固定击杀分
ConVar g_cvDmgMultPistol;           // v1.7.52: 手枪伤害倍率
ConVar g_cvStreakHwL1;             // v1.7.53: 加权人头档位阈值
ConVar g_cvStreakHwL2;
ConVar g_cvStreakHwL3;
ConVar g_cvStreakHwL4;
ConVar g_cvStreakHwL5;
ConVar g_cvStreakHwL6;
ConVar g_cvStreakBonusMultL1;      // v1.7.53: 一级档位倍率
ConVar g_cvStreakBonusMultL2;      // v1.7.63: 每档手配倍率（替换 mult_step 步进）
ConVar g_cvStreakBonusMultL3;
ConVar g_cvStreakBonusMultL4;
ConVar g_cvStreakBonusMultL5;
ConVar g_cvStreakBonusMultL6;
ConVar g_cvStreakBonusCoeff;       // v1.7.53: 奖励公式系数 1.3
ConVar g_cvCommonEnable;
ConVar g_cvCommonTime;
ConVar g_cvBFPointsCommon;
ConVar g_cvBFPointsCommonHS;
ConVar g_cvIconsMax;
// v1.7.16: BF-style damage points — weapon-class damage multipliers
ConVar g_cvDamageEnable;
ConVar g_cvDamageCoeff;
ConVar g_cvDamageCoeffCommon;
ConVar g_cvDmgMultAR;
ConVar g_cvDmgMultSMG;
ConVar g_cvDmgMultMagnum;
ConVar g_cvDmgMultMelee;
ConVar g_cvDmgMultPump;
ConVar g_cvDmgMultAuto;
ConVar g_cvDmgMultSniper;
ConVar g_cvDmgMultOther;
ConVar g_cvPointsRescue;                 // v1.7.51: 救援奖励分
ConVar g_cvScoreboardEnable;
ConVar g_cvScoreboardTop;
ConVar g_cvScoreboardInterval;
ConVar g_cvShopEnable;         // v1.7.27
ConVar g_cvRespawnEnable;      // v1.7.28
ConVar g_cvRespawnBase;        // v1.7.28
ConVar g_cvRespawnDelay;       // v1.7.28
ConVar g_cvRespawnCoinMax;     // v1.7.29: 复活币持有上限
ConVar g_cvRespawnCoinStart;   // v1.7.31: 新玩家初始复活币
// v1.7.80: 火炮支援1（!shop 特殊商品）
ConVar g_cvArtEnable;
ConVar g_cvArtTargetTime;
// v1.7.80: 火炮支援1状态（实现区见文件末尾）——提前声明因 ShopBuy/OnMapStart
// 在其实现之前引用（SourcePawn 变量无前向声明，函数可以）
#define ART_AIM_MAX_DIST     2000.0   // 准星 trace 最远距离
#define ART_CEIL_CLEAR       4096.0   // 向上探测上限（无遮挡 = 室外）
#define ART_CEIL_LOW         600.0    // 天花板 < 600 且上方非开阔 → 无效（拒绝确认）
#define ART_CEIL_MID         900.0    // 天花板 ≥ 900 → 中等规模
#define ART_GRAVITY          800.0    // 引擎重力 u/s²（落时 t=sqrt(2h/g)）
#define ART_MAX_CANS         32       // 单次空袭罐数上限（防 cvar 误配）
#define ART_CAN_PROPANE_PCT  70       // 罐型混合：70% 瓦斯罐 + 30% 煤气罐
#define ART_TICK_INT         0.05     // 瞄准心跳间隔（标记更新 + 右键/超时/死亡检测）

bool      g_bArtAiming[MAXPLAYERS + 1];       // 瞄准指示中
int       g_iArtSlot[MAXPLAYERS + 1];         // 商店槽位（取消退款用）
int       g_iArtPrice[MAXPLAYERS + 1];        // 购买价格（取消退款用）
int       g_iArtMagnum[MAXPLAYERS + 1];       // 服务器马格南 entref（0 = 用的是玩家自己的）
int       g_iArtMarker[MAXPLAYERS + 1];       // env_sprite 标记 entref
Handle    g_hArtAimTimer[MAXPLAYERS + 1];     // 瞄准心跳
float     g_fArtAimEnd[MAXPLAYERS + 1];       // 超时 GameTime
char      g_sArtPrevWeapon[MAXPLAYERS + 1][32]; // 原副武器 classname（恢复用）
char      g_sArtPrevMelee[MAXPLAYERS + 1][64];  // v1.7.81: 原近战种类名（m_MeleeWeaponName，精确恢复）
int       g_iArtPrevUpgrade[MAXPLAYERS + 1];  // v1.7.82: 原副武器升级位全量（激光/高爆/燃烧）
int       g_iArtPrevClip[MAXPLAYERS + 1];     // v1.7.82: 原副武器弹匣 m_iClip1（-1 = 不恢复）
ArrayList g_hArtCans;                         // 活跃罐子 entref（换图/卸载兜底清理）
int       g_iBeamLaser;                       // precache 的 beam 模型索引（OnMapStart）
int       g_iBeamHalo;
float     g_fArtNextBuyTime;                  // v1.7.80: 下次可购买 GameTime（轰炸中+冷却=禁止全体购买）
ConVar g_cvArtCountOut;
ConVar g_cvArtCountMid;
ConVar g_cvArtCountSmall;
ConVar g_cvArtRadiusOut;
ConVar g_cvArtRadiusMid;
ConVar g_cvArtRadiusSmall;
ConVar g_cvArtHeightMin;
ConVar g_cvArtHeightMax;
ConVar g_cvArtDelay;
ConVar g_cvArtStagger;
ConVar g_cvArtBurn;
ConVar g_cvArtCooldown;   // v1.7.80: 轰炸结束后的全局硬冷却（用户：10 秒）
ConVar g_cvSoundSI;
ConVar g_cvSoundHeadshot;
ConVar g_cvSoundTank;
ConVar g_cvSoundWitch;
ConVar g_cvSoundMelee;
ConVar g_cvSoundCommonHS;
ConVar g_cvSoundVolume;
ConVar g_cvSoundCooldown;

// ── BF1 streak award sounds (v1.6.6) ───────────────────────

ConVar g_cvStreakEnable;
ConVar g_cvStreakVol;
ConVar g_cvStreakSnd1;
ConVar g_cvStreakSnd2;
ConVar g_cvStreakSnd3;
ConVar g_cvStreakSnd4;
ConVar g_cvStreakSnd5;
ConVar g_cvStreakSnd6;

// ============================================================================
// Global state
// ============================================================================

Handle    g_hHPHideTimer[MAXPLAYERS + 1];             // per-client HP/banner hide timer
Handle    g_hStreakTimer[MAXPLAYERS + 1];            // per-client streak settle timer (v1.6.6)
float     g_fLastKillSoundTime[MAXPLAYERS + 1];       // sound cooldown
int       g_iKillStreak[MAXPLAYERS + 1];              // BF banner: kills in current streak
int       g_iStreakScore[MAXPLAYERS + 1];             // BF banner: rolling score in current streak (v1.6.7)
int       g_iRescueStreak[MAXPLAYERS + 1];            // v1.7.51: 连杀窗口内救援次数（结算卡显示）
float     g_fLastStreakKillTime[MAXPLAYERS + 1];      // BF banner: last streak-kill time
int       g_iCommonStreak[MAXPLAYERS + 1];            // v1.7.4: common streak count (separate icons from SI skulls, shared window)
int       g_iTotalScore[MAXPLAYERS + 1];              // v1.7.6: 本关积分 (scoreboard; 每关从 0 算, OnMapEnd 清零)
int       g_iWallet[MAXPLAYERS + 1];                  // v1.7.27: 可用积分 (商店钱包; 战役内跨图保留, 新战役清零)
// v1.7.28: 复活次数系统（用户：每图初始 2 次=3 条命，复活 15s；复活币 12000 无限购；
// 次数用完不自动复活 → 电击器回归价值）
int       g_iRevivesLeft[MAXPLAYERS + 1];             // 本图剩余自动复活次数（OnMapStart 重置 base）
int       g_iReviveCoins[MAXPLAYERS + 1];             // 复活币余额（战役内保留，新战役清零，断线清零）
Handle    g_hRespawnTimer[MAXPLAYERS + 1];            // 复活计时器
char      g_sPrevCampaign[16];                        // 上一张图的战役前缀（前缀变化 = 新战役 → 清钱包/复活币）
// v1.7.30: 每图开始积分存档（团灭重开回滚到开局状态）
// v1.7.35: 可用积分（钱包）一并存档回滚（用户实测团灭后 wallet 未重置）
bool      g_bFreshMapStart;                           // OnMapStart 置 true，round_start 消费
int       g_iSaveTotalScore[MAXPLAYERS + 1];
int       g_iSaveSIKills[MAXPLAYERS + 1];
int       g_iSaveDeaths[MAXPLAYERS + 1];
int       g_iSaveFFDamage[MAXPLAYERS + 1];
int       g_iSaveBlacked[MAXPLAYERS + 1];
int       g_iSaveWallet[MAXPLAYERS + 1];
int       g_iSIKills[MAXPLAYERS + 1];                 // v1.7.7: session SI/Witch/Tank kills
int       g_iDeaths[MAXPLAYERS + 1];                  // v1.7.7: survivor deaths
int       g_iFFDamage[MAXPLAYERS + 1];                // v1.7.7: friendly-fire damage dealt
int       g_iBlacked[MAXPLAYERS + 1];                 // v1.7.7: killed by a teammate (被黑)
bool      g_bMapEndBroadcasted;                        // v1.7.9: map-end scoreboard already broadcast
float     g_fSIHurtAt[MAXPLAYERS + 1];                // v1.7.2: last hurt time per SI (0.0 = untouched → full-HP kill bonus)
ArrayList g_hHurtVictims[MAXPLAYERS + 1];             // per-client victims hit this frame (AoE batch)
bool      g_bFrameQueued[MAXPLAYERS + 1];             // per-client: RequestFrame already pending
// v1.7.25: per-killer damage points, keyed [killer][victim-entity]
// (entity covers SI client indexes + Witch NPC entity + common entity).
// Every consumer (SI HP line / Witch HP line / kill cards / common kill
// line) reads ONLY the killer's own share — multi-killer fights no longer
// inflate anyone's number. Accumulated per hurt event, consumed (zeroed)
// by whichever display reads it. Totals only, no streak/chat.
int       g_iDmgPtsKiller[MAXPLAYERS + 1][2048];
// v1.7.24: the L4D2 infected_death event HAS NO entity field (GetInt
// "entityid" → 0, proven by debug logs) — so the common kill line cannot
// look up the dead body's dmg pts. Instead: remember the LAST common the
// killer hit — the kill always belongs to that entity (one-shot kills are
// hurt-then-death on the same entity). Verified via [common-hit]/[common-kill]
// debug logs: hit carries ent=126 pts=13, death carries ent=0 → this fixes
// the lookup. Shotgun multi-kills: only the LAST kill is exact.
int       g_iLastCommonEnt[MAXPLAYERS + 1];

// ============================================================================
// v1.7.27: score shop (!shop) — 消费"当前积分"(g_iWallet) 兑换补给/武器
// 积分双轨（BF 同款）：g_iTotalScore = 历史积分（排行榜，跨图累计不清零）；
// g_iWallet = 当前积分（钱包，消费用，跨图不清零攒大件）。
// 价格/限购写死在此表（改价格需重编译）；掉落（loot_drop v1.7.0）出小件。
// ============================================================================

#define SHOP_SLOTS      17

enum struct ShopItem
{
    char name[32];      // 显示名
    char classname[64]; // 实体 classname（空 = 特殊商品：复活币）
    int  price;         // 价格（当前积分）
    int  limit;         // 每图限购次数（0 = 无限）
    int  cat;           // v1.7.64: 菜单分类 0=武器 1=道具 2=医疗 3=其他
}

// 商品表（价格用户定稿 2026-08-01 修订：电击器/医疗包 4000, 复活币 12000 无限购）
ShopItem g_ShopTable[SHOP_SLOTS] = {
    // v1.7.36 (user): 全部商品不限购（limit 0）——只有复活币受持有上限
    // (si_hud_respawn_coin_max 5) 约束
    { "瓦斯罐",      "weapon_propanetank",             800,  0,  1 },
    { "煤气罐",      "weapon_oxygentank",              800,  0,  1 },
    { "汽油桶",      "weapon_gascan",                 5000,  0,  1 },   // v1.7.72: 灌油关卡逃生价值，用户定稿 5000
    { "止痛药",      "weapon_pain_pills",             2000,  0,  2 },
    { "肾上腺素",    "weapon_adrenaline",             2000,  0,  2 },
    { "电击器",      "weapon_defibrillator",          4000,  0,  2 },
    { "医疗包",      "weapon_first_aid_kit",          4000,  0,  2 },
    { "激光瞄准",    "weapon_upgradepack_laser_sight", 3500,  0,  0 },   // v1.7.79: 恢复正式价 3500
    { "M60 轻机枪",  "weapon_rifle_m60",              5000,  0,  0 },
    { "电锯",        "weapon_chainsaw",               5000,  0,  0 },   // v1.7.44
    { "榴弹发射器",  "weapon_grenade_launcher",       8000,  0,  0 },
    { "复活币",      "",                              12000,  0,  3 },
    { "透视特感",    "wallhack",                      6000,   0,  3 },   // v1.7.79: 恢复正式价 6000（全局蓝色高亮 3 分钟，可续费至 15 分钟）
    { "近战盲盒",    "melee_box",                     3000,   0,  0 },   // v1.7.79: 恢复正式价 3000（随机一把非电锯近战）
    { "烟花",        "weapon_fireworkcrate",          2500,   0,  1 },   // v1.7.72: 道具类（用户定稿 2500）
    { "火炮支援1", "artillery",                     1,     0,  3 },   // v1.7.93: 用户定稿——正式命名火炮支援1，价格暂定 1 分（随时可调）
    { "火炮支援II",  "ext_artillery2",                1,     0,  3 }     // v1.7.93: 榴弹炮弹雨（独立插件 l4d2_shop_artillery2 接管；TEMP-TEST 1 分，测完恢复 8000）
};

int       g_iShopBought[MAXPLAYERS + 1][SHOP_SLOTS];   // 每图已购次数（OnMapEnd 清零）

// v1.7.72: 近战盲盒奖池（12 把，不含电锯）——2D 字符数组初始化规则
// （spcomp64 实测）：尺寸全显式 + 行数必须与初始化行数一致（[12][16] 配
// 2 行 → error 047；const + 省略首维 → parse error）
// v1.7.76 FIX: 抽取下标用显式常量 MELEE_POOL_COUNT——sizeof(x)/sizeof(x[])
// 在全局数组上实测算出 0（GetRandomInt(0,0) 永远棒球棍）
#define MELEE_POOL_COUNT   12
char g_MeleePool[MELEE_POOL_COUNT][16] = {
    "baseball_bat", "cricket_bat", "crowbar", "electric_guitar",
    "fireaxe", "frying_pan", "golfclub", "katana",
    "knife", "machete", "tonfa", "shovel"
};

// v1.7.64: 透视特感（!shop 特殊商品）——购买者独占的克隆轮廓透视
#define WALLHACK_SLOT       12      // g_ShopTable 槽位（= 透视特感）
// v1.7.80: 火炮支援1（!shop 特殊商品）——BFV 式瞄准轰炸
#define ARTILLERY_SLOT      15      // g_ShopTable 槽位（= 火炮支援1）
// v1.7.93: 火炮支援II（!shop 特殊商品）——榴弹炮弹雨，独立插件接管
#define ARTILLERY2_SLOT     16      // g_ShopTable 槽位（= 火炮支援II，classname ext_ 前缀）
#define WALLHACK_DURATION   180.0   // v1.7.67: 3 分钟（用户定稿，原 300=5 分钟）
#define WALLHACK_CAP        900.0   // v1.7.69: 可续费，单次效果累计上限 15 分钟（用户定稿）
bool      g_bWallhack[MAXPLAYERS + 1];          // 透视生效中
float     g_fWallhackEnd[MAXPLAYERS + 1];       // v1.7.69: 效果结束的 GameTime（续费累计）
Handle    g_hWallhackTimer[MAXPLAYERS + 1];     // 到期计时器
Handle    g_hWallhackWarnTimer[MAXPLAYERS + 1]; // v1.7.68: 结束前 30 秒提醒计时器
Handle    g_hWallhackSyncTimer;                 // 补光心跳（0.5s，无购买者自动停）
ArrayList g_hWitchList;                         // 当前 Witch 实体索引（OnEntityCreated 维护）
Handle    g_hShopMenu[MAXPLAYERS + 1];          // 当前打开的商店菜单（!buy 切换用）

// v1.7.34: 持久化——钱包/复活币按 SteamID 存 KeyValues（data/si_hud_scores.txt），
// reload/重启不丢；保存时机: 断线 / OnPluginEnd(reload) / 60s 周期 / 新战役清零后
char      g_sSavePath[PLATFORM_MAX_PATH];

// v1.7.40: 前向声明（OnPluginStart/持久化区在 GetMapPrefix 定义之前使用）
void GetMapPrefix(const char[] map, char[] out, int maxlen);

// v1.7.43: 换图重连识别——L4D2 changelevel 时客户端断线自动重连，
// 会被 OnClientPostAdminCheck 当成"新加入"清空钱包。断线时记录
// (SteamID, 时间)，重连时 20s 内同 ID 匹配 = 换图重连 → 恢复存档。
char      g_sDiscAuth[MAXPLAYERS + 1][32];
float     g_fDiscTime[MAXPLAYERS + 1];

// v1.7.46: L4D2 激光无 networked prop（m_bHasLaserSight 是 CS 系列的，
// 在 L4D2 上 SetEntProp 抛 "Invalid property"）——只能调用引擎虚函数
// CBaseCombatWeapon::SetHasLaserSight（Linux 符号，gamedata/l4d2_si_hud.txt）
Handle    g_hGameConfSetLaser;
Handle    g_hSetLaserCall;

// ============================================================================
// Plugin Info
// ============================================================================

public Plugin myinfo =
{
    name        = "[L4D2] SI HUD",
    author      = "suli",
    description = "SI HP + kill confirm (PrintCenterText) + chat feed + sounds",
    version     = PLUGIN_VERSION,
    url         = ""
};

// v1.7.93: 商店扩展 API——外部插件商品（classname "ext_" 前缀）通过
// SH_OnShopItemBuy forward 接管购买，积分用 SH_GetWallet/SH_AddWallet 读写。
// 用途: 火炮支援II 榴弹雨（l4d2_shop_artillery2.smx，独立插件维护）。
// 扩展插件需在 AskPluginLoad2 里 RegPluginLibrary("l4d2_shop_ext")（可选），
// forward/native 由 SM 自动绑定，无需显式加载依赖。
// forward 返回值: Plugin_Handled = 接管（扣款已在上游完成）;
// Plugin_Stop = 拒绝且已自行提示（si_hud 静默退款）; Plugin_Continue = 拒绝。
forward Action SH_OnShopItemBuy(int client, int slot, const char[] classname, int price);
native int  SH_GetWallet(int client);
native void SH_AddWallet(int client, int amount);   // 负 = 扣分

Handle g_hShopBuyForward;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("SH_GetWallet", Native_SH_GetWallet);
    CreateNative("SH_AddWallet", Native_SH_AddWallet);
    RegPluginLibrary("l4d2_si_hud");
    return APLRes_Success;
}

public int Native_SH_GetWallet(Handle plugin, int numParams)
{
    return g_iWallet[GetNativeCell(1)];
}

public int Native_SH_AddWallet(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
        return 0;
    int amount = GetNativeCell(2);
    if (amount > 0 && g_iWallet[client] + amount < 0)
        g_iWallet[client] = 0;
    else
        g_iWallet[client] += amount;
    if (g_iWallet[client] < 0)
        g_iWallet[client] = 0;
    return g_iWallet[client];
}

// ============================================================================
// OnPluginStart
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("si_hud_version", PLUGIN_VERSION,
        "SI HUD version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    // v1.7.93: 外部商品购买 forward（reload 时旧句柄已在 OnPluginEnd 关闭）
    g_hShopBuyForward = CreateGlobalForward("SH_OnShopItemBuy", ET_Event,
        Param_Cell, Param_Cell, Param_String, Param_Cell);

    g_cvEnable = CreateConVar("si_hud_enable", "1",
        "Master switch (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Persistent HP display (PrintCenterText) ─────────

    g_cvHPEnable = CreateConVar("si_hud_hp_enable", "1",
        "Show persistent SI HP via PrintCenterText.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvHPInterval = CreateConVar("si_hud_hp_interval", "0.5",
        "HP display duration in seconds (on-hit mode: auto-hides after this long).",
        FCVAR_NOTIFY, true, 0.2, true, 5.0);

    g_cvHPShowWitch = CreateConVar("si_hud_hp_show_witch", "0",
        "Include Witch in HP display (0=off, 1=on).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── Kill feedback ───────────────────────────────────

    g_cvChatEnable = CreateConVar("si_hud_chat_enable", "1",
        "PrintToChatAll kill feed.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillHintEnable = CreateConVar("si_hud_kill_hint_enable", "1",
        "PrintCenterText kill banner for attacker (☠ skulls + type + points).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillCardEnable = CreateConVar("si_hud_killcard_enable", "1",
        "Kill card line (second line of the center kill feedback, v1.7.1): [weapon] ☠ SI name (gold ☠ on headshot).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvKillCardTime = CreateConVar("si_hud_killcard_time", "2.0",
        "Kill feedback (banner + kill card, one center message) display duration in seconds before the center clear.", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    CreateConVar("si_hud_banner_time", "1.0",
        "DEPRECATED (v1.7.1): banner and kill card share one message timed by si_hud_killcard_time. Kept so cfg files don't error.", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    // ── BF-style kill banner (skulls + points) ─────────

    g_cvBFWindow = CreateConVar("si_hud_bf_window", "6.0",
        "Kill streak window (s) — the streak-interrupt timeout: kills within this time stack skulls; when it closes the streak settles (award sound + settle score).", FCVAR_NOTIFY, true, 1.0, true, 30.0);

    // v1.7.52 (user): 击杀分重做——基础分 = 特感实际最大血量 ×
    // si_hud_bf_points_base_pct (25%)，向上取整；Tank 固定 1500 / Witch 固定
    // 500（大头在伤害分）；爆头 ×1.5、满血 ×1.25 倍率制（取代固定 +50），
    // 近战加成取消（近战优势已有伤害分倍率 1.75）。
    g_cvBFPointsBasePct = CreateConVar("si_hud_bf_points_base_pct", "25",
        "Kill base points = SI actual max HP × this %% (ceiled). Tank/Witch fixed below.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvBFPointsTank = CreateConVar("si_hud_bf_points_tank", "1500",
        "Kill points: Tank fixed (damage points are the main share).", FCVAR_NOTIFY, true, 0.0, true, 100000.0);
    g_cvBFPointsWitch = CreateConVar("si_hud_bf_points_witch", "500",
        "Kill points: Witch fixed.", FCVAR_NOTIFY, true, 0.0, true, 100000.0);
    g_cvBFHeadshotMult = CreateConVar("si_hud_bf_headshot_mult", "1.5",
        "Kill points multiplier: headshot kill (was fixed +50).", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_cvBFFullHPMult = CreateConVar("si_hud_bf_fullhp_mult", "1.25",
        "Kill points multiplier: full-HP kill — SI never hurt before dying (stacks with headshot).", FCVAR_NOTIFY, true, 1.0, true, 10.0);

    // v1.7.53 (user): 连杀奖励 = 加权人头档位制。小僵尸 1 人头 / 特感 6 人头，
    // 档位 20/40/55/70/85/100；奖励 = 该档阈值 × si_hud_streak_bonus_coeff (1.3)
    // × 档位倍率（一级 si_hud_streak_bonus_mult_l1 = 10，每档 +1.5，鼓励多杀）。
    g_cvStreakHwL1 = CreateConVar("si_hud_streak_hw_l1", "20",
        "Weighted-head bonus tier 1 threshold (SI×6 + common×1).", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakHwL2 = CreateConVar("si_hud_streak_hw_l2", "40",
        "Weighted-head bonus tier 2 threshold.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakHwL3 = CreateConVar("si_hud_streak_hw_l3", "55",
        "Weighted-head bonus tier 3 threshold.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakHwL4 = CreateConVar("si_hud_streak_hw_l4", "70",
        "Weighted-head bonus tier 4 threshold.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakHwL5 = CreateConVar("si_hud_streak_hw_l5", "85",
        "Weighted-head bonus tier 5 threshold.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakHwL6 = CreateConVar("si_hud_streak_hw_l6", "100",
        "Weighted-head bonus tier 6 threshold.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvStreakBonusMultL1 = CreateConVar("si_hud_streak_bonus_mult_l1", "10",
        "Bonus formula: tier-1 multiplier (reward = heads × coeff × mult).", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    // v1.7.63 (user 拍板): 每档手配倍率，加速曲线——10/14/19/25/32/40，
    // 满档奖励 260/624/995/1483/2107/2887，高段增量逐段放大（+260/+364/
    // +371/+488/+624/+780），替代旧 mult_step 线性步进。
    g_cvStreakBonusMultL2 = CreateConVar("si_hud_streak_bonus_mult_l2", "14",
        "Bonus formula: tier-2 multiplier.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvStreakBonusMultL3 = CreateConVar("si_hud_streak_bonus_mult_l3", "19",
        "Bonus formula: tier-3 multiplier.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvStreakBonusMultL4 = CreateConVar("si_hud_streak_bonus_mult_l4", "25",
        "Bonus formula: tier-4 multiplier.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvStreakBonusMultL5 = CreateConVar("si_hud_streak_bonus_mult_l5", "32",
        "Bonus formula: tier-5 multiplier.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvStreakBonusMultL6 = CreateConVar("si_hud_streak_bonus_mult_l6", "40",
        "Bonus formula: tier-6 multiplier.", FCVAR_NOTIFY, true, 1.0, true, 100.0);
    g_cvStreakBonusCoeff = CreateConVar("si_hud_streak_bonus_coeff", "1.3",
        "Bonus formula coefficient.", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    // v1.7.51: 救援奖励分 (user)——救援队友计入连杀（刷新窗口+滚动分+结算卡）
    g_cvPointsRescue = CreateConVar("si_hud_points_rescue", "75",
        "Rescue score: reviving a teammate (revive_success) awards this, stacking the streak window.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);

    // v1.7.3: common infected fully taken over — they score, stack the
    // streak (and the award settle), and show a center kill line (†).
    g_cvCommonEnable = CreateConVar("si_hud_common_enable", "1",
        "Common infected kill line on the center channel (†).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCommonTime = CreateConVar("si_hud_common_time", "1.0",
        "Common infected kill line display duration in seconds (shorter than the SI card — no spam).", FCVAR_NOTIFY, true, 0.2, true, 5.0);
    g_cvBFPointsCommon = CreateConVar("si_hud_bf_points_common", "5",
        "BF banner points: common infected kill.", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvBFPointsCommonHS = CreateConVar("si_hud_bf_points_common_hs", "5",
        "BF banner points: common infected headshot bonus (total = base + this).", FCVAR_NOTIFY, true, 0.0, true, 10000.0);

    // v1.7.4: icon row cap — SI skulls (☠) and common daggers (†) counted
    // separately, one row of up to this many icons; over it shows "+N".
    g_cvIconsMax = CreateConVar("si_hud_icons_max", "15",
        "Max kill icons on one line (☠ skulls + † daggers, separate segments); over this shows +N.", FCVAR_NOTIFY, true, 1.0, true, 30.0);

    // v1.7.16: BF-style damage points — hurting an SI (incl. Tank) earns
    // score, so tank/charger fights are fair (not just the final killer).
    // Damage points go to the scoreboard total only — NOT the streak
    // (award = kill streaks), NOT the chat (spam). Witch excluded (NPC
    // Witch fires no player_hurt); commons excluded (no player_hurt).
    g_cvDamageEnable = CreateConVar("si_hud_bf_damage_enable", "1",
        "Damage points: earn score for damaging SI (incl. Tank).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDamageCoeff = CreateConVar("si_hud_bf_damage_coeff", "0.1",
        "Damage points coefficient: points = dmg_health × weapon mult × this (0.1 = 10 damage = 1 point — user: 血量分全部/10, a 50hp common scores 5, not 50).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDamageCoeffCommon = CreateConVar("si_hud_bf_damage_coeff_common", "0.1",
        "Common infected damage points coefficient (infected_hurt): amount × weapon mult × this (0.1, same as SI — a 50hp common = 5 dmg pts; kill pts 5/10 stay unchanged).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultAR = CreateConVar("si_hud_bf_damage_mult_ar", "1.0",
        "Damage mult: assault rifles (rifle/ak47/desert/sg552).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultSMG = CreateConVar("si_hud_bf_damage_mult_smg", "1.5",
        "Damage mult: SMGs (smg/silenced/mp5).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultMagnum = CreateConVar("si_hud_bf_damage_mult_magnum", "1.75",
        "Damage mult: magnum pistol.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultPistol = CreateConVar("si_hud_bf_damage_mult_pistol", "1.75",
        "Damage mult: pistols (pistol/dual_pistols) — user: 手枪 1.75.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultMelee = CreateConVar("si_hud_bf_damage_mult_melee", "1.75",
        "Damage mult: melee weapons.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultPump = CreateConVar("si_hud_bf_damage_mult_pump", "1.5",
        "Damage mult: pump shotgun.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultAuto = CreateConVar("si_hud_bf_damage_mult_auto", "0.75",
        "Damage mult: auto shotguns (autoshotgun/spas).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultSniper = CreateConVar("si_hud_bf_damage_mult_sniper", "0.75",
        "Damage mult: snipers (hunting/military/awp/scout).", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvDmgMultOther = CreateConVar("si_hud_bf_damage_mult_other", "1.0",
        "Damage mult: everything else (pistol etc.).", FCVAR_NOTIFY, true, 0.0, true, 10.0);

    // v1.7.62: score-based award tiers (si_hud_streak_score_l2..l15) REMOVED —
    // sound tiers now follow the hw segments (L1..L6) directly, one ladder
    // for both bonus amount and sound (user 拍板, 2026-08-02).

    // v1.7.6: Y-key chat scoreboard — !rank / !score / !top
    g_cvScoreboardEnable = CreateConVar("si_hud_scoreboard_enable", "1",
        "Enable the chat scoreboard (!rank / !score / !top).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvScoreboardTop = CreateConVar("si_hud_scoreboard_top", "6",
        "Scoreboard shows this many top entries, then a divider and your own score.", FCVAR_NOTIFY, true, 1.0, true, 24.0);
    g_cvScoreboardInterval = CreateConVar("si_hud_scoreboard_interval", "45.0",
        "Auto-broadcast the scoreboard to every survivor every N seconds (0=off).", FCVAR_NOTIFY, true, 0.0, true, 600.0);

    // v1.7.27: score shop — !shop / !buy (prices are compile-time in g_ShopTable)
    g_cvShopEnable = CreateConVar("si_hud_shop_enable", "1",
        "Enable the score shop (!shop / !buy).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // v1.7.28: respawn limit — 每图初始复活次数 + 复活秒数 + 总开关
    //（替代 l4d2_auto_respawn；复活币商店 12000 无限购）
    g_cvRespawnEnable = CreateConVar("si_hud_respawn_enable", "1",
        "Enable the limited auto-respawn system (replaces l4d2_auto_respawn).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRespawnBase = CreateConVar("si_hud_respawn_base", "2",
        "Auto-respawn count per player per map (3 lives total with the initial one).", FCVAR_NOTIFY, true, 0.0, true, 20.0);
    g_cvRespawnDelay = CreateConVar("si_hud_respawn_delay", "15.0",
        "Seconds before auto respawn (was 35 in l4d2_auto_respawn).", FCVAR_NOTIFY, true, 5.0, true, 300.0);
    g_cvRespawnCoinMax = CreateConVar("si_hud_respawn_coin_max", "5",
        "Max revive coins a player may hold (checked on buy / join / map start).", FCVAR_NOTIFY, true, 0.0, true, 20.0);
    g_cvRespawnCoinStart = CreateConVar("si_hud_respawn_coin_start", "2",
        "Revive coins a NEW player joins with (full default state: 0 wallet + these coins).", FCVAR_NOTIFY, true, 0.0, true, 20.0);

    // v1.7.80: 火炮支援1（!shop 特殊商品；v1.7.93 用户定稿命名，价格暂定 1 分）
    g_cvArtEnable = CreateConVar("si_hud_art_enable", "1",
        "Enable the artillery strike shop item (0=off, purchase refunded).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvArtTargetTime = CreateConVar("si_hud_art_target_time", "15.0",
        "Seconds to designate the strike target with the magnum before auto-cancel+refund.", FCVAR_NOTIFY, true, 3.0, true, 60.0);
    g_cvArtCountOut = CreateConVar("si_hud_art_count_out", "12",
        "Cans dropped in open areas (no ceiling within 4096 units).", FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_cvArtCountMid = CreateConVar("si_hud_art_count_mid", "8",
        "Cans dropped indoors with ceiling >= 900 units.", FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_cvArtCountSmall = CreateConVar("si_hud_art_count_small", "5",
        "Cans dropped indoors with ceiling 600-900 units.", FCVAR_NOTIFY, true, 1.0, true, 32.0);
    g_cvArtRadiusOut = CreateConVar("si_hud_art_radius_out", "500.0",
        "Spread radius (units) of the open-area strike; also the target ring radius.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusMid = CreateConVar("si_hud_art_radius_mid", "350.0",
        "Spread radius for ceiling >= 900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtRadiusSmall = CreateConVar("si_hud_art_radius_small", "250.0",
        "Spread radius for ceiling 600-900.", FCVAR_NOTIFY, true, 50.0, true, 1500.0);
    g_cvArtHeightMin = CreateConVar("si_hud_art_height_min", "1800.0",
        "Min drop height (units) for open areas.", FCVAR_NOTIFY, true, 400.0, true, 8000.0);
    g_cvArtHeightMax = CreateConVar("si_hud_art_height_max", "2600.0",
        "Max drop height (units) for open areas.", FCVAR_NOTIFY, true, 400.0, true, 8000.0);
    // v1.7.93: si_hud_art_damage 已删除——爆炸伤害由模型 propdata 决定（原版 200 falloff）
    g_cvArtDelay = CreateConVar("si_hud_art_delay", "0.5",
        "Seconds between confirm and the first can spawning.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvArtStagger = CreateConVar("si_hud_art_stagger", "1.0",
        "Seconds between each can spawn (barrage cadence).", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvArtBurn = CreateConVar("si_hud_art_burn", "2.0",
        "Secs the can keeps burning after landing (burns out, then detonates).", FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvArtCooldown = CreateConVar("si_hud_art_cooldown", "10.0",
        "Global hard cooldown after a strike ends before anyone can buy again (user: 10s).", FCVAR_NOTIFY, true, 0.0, true, 300.0);

    // ── Kill sounds (all empty = off by default) ────────

    g_cvSoundSI = CreateConVar("si_hud_sound_si", "",
        "Default SI kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundHeadshot = CreateConVar("si_hud_sound_headshot", "",
        "SI headshot kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundTank = CreateConVar("si_hud_sound_tank", "",
        "Tank kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundWitch = CreateConVar("si_hud_sound_witch", "",
        "Witch kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundMelee = CreateConVar("si_hud_sound_melee", "",
        "Melee SI kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundCommonHS = CreateConVar("si_hud_sound_common_hs", "",
        "Common infected headshot kill sound (empty=off).", FCVAR_NOTIFY);

    g_cvSoundVolume = CreateConVar("si_hud_sound_volume", "0.8",
        "Sound volume (0.0 – 1.0).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvSoundCooldown = CreateConVar("si_hud_sound_cooldown", "0.1",
        "Min seconds between kill sounds per client.", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    // ── BF1 streak award sounds (v1.6.6) ────────────────

    g_cvStreakEnable = CreateConVar("si_hud_streak_sound_enable", "1",
        "Play the BF1 award sound when a kill streak settles (streak >= 2).", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvStreakVol = CreateConVar("si_hud_streak_sound_volume", "1.0",
        "Streak award sound volume, independent of si_hud_sound_volume. Keep ≤ 1.0 — engine handles >1.0 unpredictably.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    // v1.7.47 FIX (engine-residue cvar): a cfg exec once auto-created this cvar
    // in the engine before the plugin loaded; CreateConVar returns the existing
    // cvar WITHOUT updating bounds — force them (no server restart).
    g_cvStreakVol.SetBounds(ConVarBound_Upper, true, 1.0);

    // v1.7.2: all six awards re-mastered to a uniform loudness (loudnorm,
    // mean ≈ -15 dB) and re-shipped under the bf_award_* names so clients
    // are forced to re-download them (old bf_streak_* files deleted).
    // v1.7.62 (user): 音效档位 = 人头阶梯段位 L1..L6（与奖励同一把尺子）。
    // 段位编号直接对应 hw 段：L1=20-39、L2=40-54、L3=55-69、L4=70-84、
    // L5=85-99、L6=100+。
    g_cvStreakSnd1 = CreateConVar("si_hud_streak_sound_l1", "battlefield/bf_award_spotting.mp3",
        "Award sound tier L1 (hw 20-39, smallest bonus) — file relative to sound/, empty=off.", FCVAR_NOTIFY);
    g_cvStreakSnd2 = CreateConVar("si_hud_streak_sound_l2", "battlefield/bf_award_purchase.mp3",
        "Award sound tier L2 (hw 40-54).", FCVAR_NOTIFY);
    g_cvStreakSnd3 = CreateConVar("si_hud_streak_sound_l3", "battlefield/bf_award_war_bonds.mp3",
        "Award sound tier L3 (hw 55-69).", FCVAR_NOTIFY);
    g_cvStreakSnd4 = CreateConVar("si_hud_streak_sound_l4", "battlefield/bf_award_dogtag.mp3",
        "Award sound tier L4 (hw 70-84).", FCVAR_NOTIFY);
    g_cvStreakSnd5 = CreateConVar("si_hud_streak_sound_l5", "battlefield/bf_award_medal.mp3",
        "Award sound tier L5 (hw 85-99).", FCVAR_NOTIFY);
    g_cvStreakSnd6 = CreateConVar("si_hud_streak_sound_l6", "battlefield/bf_award_rankup.mp3",
        "Award sound tier L6 (hw 100+, biggest bonus).", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_si_hud");

    // ── Events ──────────────────────────────────────────

    HookEvent("player_hurt",    Event_PlayerHurt);
    HookEvent("player_spawn",   Event_PlayerSpawn);
    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("infected_hurt",  Event_InfectedHurt);    // v1.7.16: common damage points
    HookEvent("revive_success", Event_ReviveSuccess);   // v1.7.51: 救援算分
    HookEvent("round_end",      Event_RoundEnd);
    HookEvent("round_start",    Event_RoundStart);      // v1.7.30: 团灭重开判定
    HookEvent("player_team",    Event_PlayerTeam);      // v1.7.64: 闲置/换队 → 透视失效
    HookEvent("map_transition", Event_MapTransition);   // v1.7.9
    HookEvent("weapon_fire",    Event_WeaponFire);      // v1.7.80: 火炮马格南射击 = 确认轰炸

    // v1.7.85 FIX: reload 后 OnMapStart 不重跑 → g_iBeamLaser/g_iBeamHalo 归 0 →
    // 心跳 TE_SetupBeamRingPoint(0,...) 发送空模型索引 → segfault（17:28:36 第三方图
    // 瞄准中崩溃实锤 "Segmentation fault (core dumped)"）→ OnPluginStart 补 precache
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr");

    RegAdminCmd("sm_streak_test", Cmd_StreakTest, ADMFLAG_ROOT,
        "sm_streak_test — debug: play the L2 streak sound + the SI kill sound directly");

    // v1.7.6: chat scoreboard (Y key) — !rank / !score / !top
    RegConsoleCmd("sm_rank", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");
    RegConsoleCmd("sm_score", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");
    RegConsoleCmd("sm_top", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");

    // v1.7.27: score shop — !shop / !buy
    RegConsoleCmd("sm_shop", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");
    RegConsoleCmd("sm_buy", Cmd_Shop, "Open the score shop (spend score on supplies/weapons).");

    // v1.7.39d DEBUG: 直接测 m_bHasLaserSight prop 有效性（绕过商店/钱包）
    RegConsoleCmd("sm_laser_test", Cmd_LaserTest,
        "DEBUG: SetEntProp m_bHasLaserSight on current weapon + readback log");

    // v1.7.6: periodic per-player broadcast (45s default; 0=off via cvar
    // check inside the callback; interval change needs plugin reload)
    CreateTimer(45.0, Timer_ScoreboardBroadcast, INVALID_HANDLE, TIMER_REPEAT);

    // v1.7.32d FIX: plugin reload 不触发 OnClientPutInServer —— 已在线的玩家
    // 复活次数/复活币/钱包全是 0（reload 清零副作用）。补全初始化：
    // 复活次数回 base，钱包/复活币从持久化文件恢复（v1.7.34）。
    ScoreSave_Init();
    g_hWitchList = new ArrayList();          // v1.7.64: 透视特感 Witch 实体表
    WallhackClearGlow();                     // v1.7.67: reload 安全网——清掉残留特感发光（防 reload 后光不灭）
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            g_iRevivesLeft[i] = g_cvRespawnBase.IntValue;
            g_iTotalScore[i] = 0;
            g_iSIKills[i] = 0;
            g_iDeaths[i] = 0;
            g_iFFDamage[i] = 0;
            g_iBlacked[i] = 0;
            ScoreLoad_Player(i);   // v1.7.34: 恢复钱包/复活币
        }
    }

    // v1.7.34: 周期持久化（防崩溃丢数据 + 中途进服玩家恢复接近实时的值）
    CreateTimer(60.0, Timer_ScoreSave, INVALID_HANDLE, TIMER_REPEAT);

    // v1.7.40 FIX: reload/重启后 g_sPrevCampaign 为空 → 之后的战役切换判定
    // 失效（strlen==0 跳过清零）→ 上一战役的钱被持久化恢复。初始化当前图前缀
    char initMap[64];
    GetCurrentMap(initMap, sizeof(initMap));
    GetMapPrefix(initMap, g_sPrevCampaign, sizeof(g_sPrevCampaign));

    // v1.7.46: SDKCall SetHasLaserSight（激光只能走引擎函数）
    g_hGameConfSetLaser = LoadGameConfigFile("l4d2_si_hud");
    if (g_hGameConfSetLaser == null)
    {
        LogError("[shop-laser] 无法加载 gamedata/l4d2_si_hud.txt —— 激光购买将回退为脚下 spawn 升级包");
    }
    else
    {
        StartPrepSDKCall(SDKCall_Entity);
        PrepSDKCall_SetFromConf(g_hGameConfSetLaser, SDKConf_Signature, "SetHasLaserSight");
        PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
        g_hSetLaserCall = EndPrepSDKCall();
        if (g_hSetLaserCall == null)
            LogError("[shop-laser] SetHasLaserSight SDKCall 初始化失败 —— 回退脚下 spawn");
    }
}

// ============================================================================
// v1.7.34: 持久化 —— 钱包/复活币按 SteamID 存 KeyValues
// ============================================================================

public void OnPluginEnd()
{
    // reload/卸载前保存所有在线玩家（reload 不触发 OnClientDisconnect）。
    // ⚠ reload 顺序: OnPluginEnd 先于 OnPluginStart → g_sSavePath 还是空串，
    // 必须先重新 Init（BuildPath 纯函数可重复调用）。
    ScoreSave_Init();
    ScoreSave_All();
    WallhackEndAll();                        // v1.7.64: 卸载/reload 清理透视克隆
    Art_CleanupAll();                        // v1.7.80: 卸载/reload 清理火炮瞄准状态/残留罐子
    if (g_hShopBuyForward != null)           // v1.7.93: 外部商品 forward 句柄
    {
        CloseHandle(g_hShopBuyForward);
        g_hShopBuyForward = null;
    }
}

void ScoreSave_Init()
{
    BuildPath(Path_SM, g_sSavePath, sizeof(g_sSavePath), "data/si_hud_scores.txt");
}

void ScoreSave_Player(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
        return;

    char auth[32];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false))
        return;

    KeyValues kv = new KeyValues("si_hud_scores");
    if (FileExists(g_sSavePath))
        kv.ImportFromFile(g_sSavePath);

    kv.JumpToKey(auth, true);
    kv.SetNum("wallet", g_iWallet[client]);
    kv.SetNum("coins", g_iReviveCoins[client]);
    // v1.7.40: 存档所属战役（恢复时校验，防跨战役恢复旧钱）
    kv.SetString("campaign", g_sPrevCampaign);
    kv.Rewind();
    kv.ExportToFile(g_sSavePath);
    delete kv;
}

void ScoreSave_All()
{
    for (int i = 1; i <= MaxClients; i++)
        ScoreSave_Player(i);
}

void ScoreLoad_Player(int client)
{
    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;

    // 默认（无存档/新玩家）：0 可用积分 + start 枚复活币（v1.7.31 用户定）
    g_iWallet[client] = 0;
    g_iReviveCoins[client] = g_cvRespawnCoinStart.IntValue;

    if (!FileExists(g_sSavePath))
        return;

    char auth[32];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false))
        return;

    KeyValues kv = new KeyValues("si_hud_scores");
    if (!kv.ImportFromFile(g_sSavePath))
    {
        delete kv;
        return;
    }

    // v1.7.40: 存档战役校验——存档战役 ≠ 当前战役 → 不恢复（跨战役的钱作废）
    char savedCampaign[16];
    char curMap[64];
    GetCurrentMap(curMap, sizeof(curMap));
    char curPrefix[16];
    GetMapPrefix(curMap, curPrefix, sizeof(curPrefix));

    if (kv.JumpToKey(auth))
    {
        kv.GetString("campaign", savedCampaign, sizeof(savedCampaign));
        if (strlen(savedCampaign) > 0 && !StrEqual(savedCampaign, curPrefix))
        {
            // 跨战役存档：保持默认（0 + start 币），不恢复
            g_iWallet[client] = 0;
            g_iReviveCoins[client] = g_cvRespawnCoinStart.IntValue;
        }
        else
        {
            g_iWallet[client] = kv.GetNum("wallet", 0);
            g_iReviveCoins[client] = kv.GetNum("coins", g_cvRespawnCoinStart.IntValue);
            int coinMax = g_cvRespawnCoinMax.IntValue;   // 上限 clamp
            if (g_iReviveCoins[client] > coinMax)
                g_iReviveCoins[client] = coinMax;
        }
    }
    delete kv;
}

public Action Timer_ScoreSave(Handle timer)
{
    ScoreSave_All();
    return Plugin_Continue;
}

// Debug (v1.7.1): play the streak award sound directly, bypassing the whole
// streak logic, so a silent streak can be bisected: if this is silent the
// play/precache path is broken; if it plays, the streak settle logic is.
public Action Cmd_StreakTest(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;

    char l1[PLATFORM_MAX_PATH], si[PLATFORM_MAX_PATH];
    g_cvStreakSnd1.GetString(l1, sizeof(l1));
    g_cvSoundSI.GetString(si, sizeof(si));

    PlayStreakSound(client, l1);
    PlayClientSound(client, si);

    LogMessage("[streak_test] L1='%s' SI='%s' emitted to %N", l1, si, client);
    PrintToChat(client, "\x04[streak test]\x01 L1='%s'  SI='%s'", l1, si);
    return Plugin_Handled;
}

// ============================================================================
// v1.7.6: chat scoreboard — !rank / !score / !top (Y key)
// ============================================================================

// v1.7.9: force-broadcast the scoreboard to every survivor (map end).
void BroadcastScoreboard()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
            ShowScoreboardTo(i);
    }
}

// v1.7.6: periodic broadcast — every player gets the scoreboard to their
// own chat every si_hud_scoreboard_interval seconds (no cross-player spam).
public Action Timer_ScoreboardBroadcast(Handle timer)
{
    if (!g_cvEnable.BoolValue || !g_cvScoreboardEnable.BoolValue)
        return Plugin_Continue;
    if (g_cvScoreboardInterval.FloatValue <= 0.0)
        return Plugin_Continue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2)
            ShowScoreboardTo(i);
    }
    return Plugin_Continue;
}

public Action Cmd_Scoreboard(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;
    if (!g_cvEnable.BoolValue || !g_cvScoreboardEnable.BoolValue)
        return Plugin_Handled;

    ShowScoreboardTo(client);
    return Plugin_Handled;
}

void ShowScoreboardTo(int client)
{
    int count = 0;
    int clients[MAXPLAYERS + 1];
    int scores[MAXPLAYERS + 1];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == 2 && g_iTotalScore[i] > 0)
        {
            clients[count] = i;
            scores[count] = g_iTotalScore[i];
            count++;
        }
    }

    if (count == 0)
    {
        PrintToChat(client, "\x04[得分榜]\x01 还没有得分，杀点特感吧！");
        return;
    }

    // insertion sort, descending by score (teams ≤ 24 players)
    for (int i = 1; i < count; i++)
    {
        int keyScore = scores[i];
        int keyClient = clients[i];
        int j = i - 1;
        while (j >= 0 && scores[j] < keyScore)
        {
            scores[j + 1] = scores[j];
            clients[j + 1] = clients[j];
            j--;
        }
        scores[j + 1] = keyScore;
        clients[j + 1] = keyClient;
    }

    int top = g_cvScoreboardTop.IntValue;
    if (top > count) top = count;

    // v1.7.14: compact single-line rows — the L4D2 chat font is proportional
    // (Verdana), so space-padded columns can never align; label-based rows
    // look clean in any font. Colors are fine now (no alignment to break).
    PrintToChat(client, "\x04[得分榜]\x01 ------------------------------------");

    char name[64];
    for (int k = 0; k < top; k++)
    {
        int c = clients[k];
        GetClientName(c, name, sizeof(name));
        // v1.7.15: strip control chars from the name so a crafted name
        // cannot inject color codes / newlines into chat.
        // v1.7.25 (user): name GREEN, numbers GREEN, labels default color,
        // spaces between labels and numbers ("1748 分 特 6 …").
        // v1.7.26: \x07RRGGBB does NOT work in L4D2 chat (renders the raw
        // "38B6FF" text) — only \x01-\x05 are safe. Blue was a no-go.
        for (int i = 0; name[i] != '\0'; i++)
        {
            if (name[i] < 0x20)
                name[i] = '?';
        }
        PrintToChat(client, "\x04[得分榜]\x01 \x05#%d\x01 \x03%s\x01：\x03%d\x01 分 特 \x03%d\x01 死 \x03%d\x01 友伤 \x03%d\x01 被黑 \x03%d\x01",
            k + 1, name, scores[k],
            g_iSIKills[c], g_iDeaths[c], g_iFFDamage[c], g_iBlacked[c]);
    }

    PrintToChat(client, "\x04[得分榜]\x01 ------------------------------------");

    // v1.7.6 (user): divider line, then own stats (with rank)
    int myRank = -1;
    for (int k = 0; k < count; k++)
    {
        if (clients[k] == client) { myRank = k; break; }
    }
    if (myRank >= 0)
        PrintToChat(client, "\x04[得分榜]\x01 你的战绩：\x03%d\x01 分 特 \x03%d\x01 死 \x03%d\x01 友伤 \x03%d\x01 被黑 \x03%d\x01（第 \x05%d\x01 名）",
            scores[myRank], g_iSIKills[client], g_iDeaths[client],
            g_iFFDamage[client], g_iBlacked[client], myRank + 1);
    else
        PrintToChat(client, "\x04[得分榜]\x01 你的战绩：0 分");

    // v1.7.28 (user): 播报计入可用积分 + 复活币（战役内资源，新战役清零）
    // v1.7.70 (user): 去掉"复活 X 次"，只显示复活币剩余数量
    PrintToChat(client, "\x04[得分榜]\x01 可用积分 \x03%d\x01  复活币 \x03%d\x01 枚",
        g_iWallet[client], g_iReviveCoins[client]);
    // v1.7.32 (user): 积分总结后提醒玩家商店入口
    PrintToChat(client, "\x04[得分榜]\x01 输入 \x05!shop\x01 或 \x05!buy\x01 打开商店，用可用积分兑换补给/武器");
}

// ============================================================================
// OnMapStart / OnMapEnd
// ============================================================================

public void OnMapStart()
{
    g_bMapEndBroadcasted = false;          // v1.7.9
    g_bFreshMapStart = true;               // v1.7.30: 本次 round_start 是新图开局

    // Precache configured sounds
    PrecacheCvarSound(g_cvSoundSI);
    PrecacheCvarSound(g_cvSoundHeadshot);
    PrecacheCvarSound(g_cvSoundTank);
    PrecacheCvarSound(g_cvSoundWitch);
    PrecacheCvarSound(g_cvSoundMelee);
    PrecacheCvarSound(g_cvSoundCommonHS);
    PrecacheCvarSound(g_cvStreakSnd1);
    PrecacheCvarSound(g_cvStreakSnd2);
    PrecacheCvarSound(g_cvStreakSnd3);
    PrecacheCvarSound(g_cvStreakSnd4);
    PrecacheCvarSound(g_cvStreakSnd5);
    PrecacheCvarSound(g_cvStreakSnd6);

    // v1.7.27: shop heavy weapons — precache models (non-campaign maps don't
    // precache M60 / grenade launcher; without this the items spawn invisible)
    PrecacheModel("models/w_models/weapons/w_m60.mdl");
    PrecacheModel("models/v_models/v_m60.mdl");
    PrecacheModel("models/w_models/weapons/w_grenade_launcher.mdl");
    PrecacheModel("models/v_models/v_grenade_launcher.mdl");
    // v1.7.44: chainsaw (电锯 5000)
    PrecacheModel("models/w_models/weapons/w_chainsaw.mdl");
    PrecacheModel("models/v_models/v_chainsaw.mdl");
    // v1.7.46b: 激光升级包附件模型（三方图可能缺 precache → 升级包隐形/不 spawn）
    PrecacheModel("models/w_models/weapons/w_laser_sights.mdl");
    // v1.7.72: 近战盲盒——12 把近战世界模型 precache（与 M60/榴弹同坑：
    // 非战役图不 precache → 生成的近战隐形）
    PrecacheModel("models/weapons/melee/w_bat.mdl");
    PrecacheModel("models/weapons/melee/w_cricket_bat.mdl");
    PrecacheModel("models/weapons/melee/w_crowbar.mdl");
    PrecacheModel("models/weapons/melee/w_guitar.mdl");
    PrecacheModel("models/weapons/melee/w_fireaxe.mdl");
    PrecacheModel("models/weapons/melee/w_frying_pan.mdl");
    PrecacheModel("models/weapons/melee/w_golfclub.mdl");
    PrecacheModel("models/weapons/melee/w_katana.mdl");
    PrecacheModel("models/weapons/melee/w_knife.mdl");
    PrecacheModel("models/weapons/melee/w_machete.mdl");
    PrecacheModel("models/weapons/melee/w_tonfa.mdl");
    PrecacheModel("models/weapons/melee/w_shovel.mdl");
    // v1.7.72: 烟花（道具类）——非战役图缺 precache 会隐形（M60/榴弹同坑）
    PrecacheModel("models/w_models/weapons/w_firework_crate.mdl");
    // v1.7.80: 火炮支援1——瞄准标记特效（TE 模型必须 precache，否则光柱/圆圈不渲染）
    g_iBeamLaser = PrecacheModel("sprites/laserbeam.vmt");
    g_iBeamHalo = PrecacheModel("sprites/halo01.vmt");
    PrecacheModel("sprites/glow01.spr");
    // v1.7.93: 火炮/商店罐子 = prop_physics + 罐模型（地图罐子等价物）→ 手动 precache 模型
    PrecacheModel("models/props_junk/propanecanister001a.mdl");
    PrecacheModel("models/props_equipment/oxygentank01.mdl");
    PrecacheModel("models/props_junk/gascan001a.mdl");          // v1.7.93: 商店汽油桶
    PrecacheModel("models/props_junk/explosive_box001.mdl");    // v1.7.93: 商店烟花
    // v1.7.85: 日志确认 precache 结果（reload 后 OnPluginStart 也 precache，防归 0）
    LogMessage("[artillery] beam precache laser=%d halo=%d", g_iBeamLaser, g_iBeamHalo);

    // HP display is now on-hit only (player_hurt → RefreshHPForClient → 0.5s hide).
    // Persistent timer is no longer started — SI HP only shows when you damage them.

    // v1.7.28: 战役判定——地图前缀变化 = 切换新战役 → 清可用积分 + 复活币
    // （用户：可用积分不随 map 切换清理，只重新开始战役/切换新战役才清理）
    char map[64];
    GetCurrentMap(map, sizeof(map));
    char prefix[16];
    GetMapPrefix(map, prefix, sizeof(prefix));
    // v1.7.41 (user): 战役首图（地图名含 m1，官图 cXm1 + 三方图 m1 命名）
    // → 一律清零（新战役起点；补上同前缀重开 c2m5→c2m1 的前缀判定漏洞）
    bool isFirstMap = (StrContains(map, "m1") != -1);
    if (isFirstMap || (strlen(g_sPrevCampaign) > 0 && !StrEqual(prefix, g_sPrevCampaign)))
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            g_iWallet[i] = 0;
            g_iReviveCoins[i] = 0;
        }
        ScoreSave_All();                 // v1.7.34: 清零同步写回文件（进服恢复无歧义）
        PrintToChatAll("\x04[商店]\x01 新战役开始：可用积分与复活币已结算清零");
    }
    strcopy(g_sPrevCampaign, sizeof(g_sPrevCampaign), prefix);

    // v1.7.28: 每图重置复活次数（初始 base 次 = base+1 条命）
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iRevivesLeft[i] = g_cvRespawnBase.IntValue;
        KillRespawnTimer(i);
        // v1.7.29: 复活币持有上限 clamp（用户：上限 5 枚，进服/新图/消耗时检查）
        int coinMax = g_cvRespawnCoinMax.IntValue;
        if (g_iReviveCoins[i] > coinMax)
            g_iReviveCoins[i] = coinMax;
    }

    // v1.7.30: 每图开始存档（用户："每一个Map开始时，要有一个存档"）——
    // 此时 OnMapEnd 已把本关积分清零，存档 = 开局 0 分状态；团灭重开回滚用
    SaveScoreState();
}

void SaveScoreState()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iSaveTotalScore[i] = g_iTotalScore[i];
        g_iSaveSIKills[i] = g_iSIKills[i];
        g_iSaveDeaths[i] = g_iDeaths[i];
        g_iSaveFFDamage[i] = g_iFFDamage[i];
        g_iSaveBlacked[i] = g_iBlacked[i];
        g_iSaveWallet[i] = g_iWallet[i];        // v1.7.35
    }
}

void RestoreScoreState()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iTotalScore[i] = g_iSaveTotalScore[i];
        g_iSIKills[i] = g_iSaveSIKills[i];
        g_iDeaths[i] = g_iSaveDeaths[i];
        g_iFFDamage[i] = g_iSaveFFDamage[i];
        g_iBlacked[i] = g_iSaveBlacked[i];
        g_iWallet[i] = g_iSaveWallet[i];        // v1.7.35: 可用积分回滚到本图开局值
        // 复活次数一并回到开局初始（防旧回合计时器复活已死玩家）
        g_iRevivesLeft[i] = g_cvRespawnBase.IntValue;
        KillRespawnTimer(i);
    }
}

public void GetMapPrefix(const char[] map, char[] out, int maxlen)
{
    int idx = FindCharInString(map, '_');
    if (idx <= 0 || idx >= maxlen)
        strcopy(out, maxlen, map);
    else
    {
        strcopy(out, maxlen, map);
        out[idx] = '\0';
    }
}

public void OnMapEnd()
{
    // v1.7.9: fallback broadcast for map changes that never fired
    // map_transition (vote / changelevel / wipe-mapchange paths).
    if (g_cvEnable.BoolValue && g_cvScoreboardEnable.BoolValue && !g_bMapEndBroadcasted)
    {
        BroadcastScoreboard();
        g_bMapEndBroadcasted = true;
    }

    // HP hide timers are TIMER_FLAG_NO_MAPCHANGE — auto-cleaned on map end.
    // Clean up per-client AoE batch state and streak settle timers
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bFrameQueued[i] = false;
        delete g_hHurtVictims[i];
        KillStreakTimer(i);
        g_iKillStreak[i] = 0;
        g_iCommonStreak[i] = 0;            // v1.7.4
        g_iStreakScore[i] = 0;
        g_iRescueStreak[i] = 0;            // v1.7.51
        // v1.7.28: 排行榜积分每关从 0 算（用户）；可用积分/复活币战役内保留
        g_iTotalScore[i] = 0;              // v1.7.6: 本关积分每关清零
        g_iRevivesLeft[i] = 0;             // v1.7.28: 本图次数（OnMapStart 重置）
        KillRespawnTimer(i);               // v1.7.28
        g_iSIKills[i] = 0;                 // v1.7.7
        g_iDeaths[i] = 0;
        g_iFFDamage[i] = 0;
        g_iBlacked[i] = 0;
        g_fLastStreakKillTime[i] = 0.0;
        g_fSIHurtAt[i] = 0.0;              // v1.7.2: full-HP bonus state
        g_iLastCommonEnt[i] = 0;           // v1.7.24
    }
    // v1.7.25: clear the per-killer damage-point buffer — the WHOLE grid
    // (killers × entity range, SI client idx + Witch/common entities) so
    // pts from a victim that died mid-frame (never displayed) cannot leak
    // into the next round's display.
    for (int i = 0; i <= MaxClients; i++)
        for (int j = 0; j < 2048; j++)
            g_iDmgPtsKiller[i][j] = 0;
    // v1.7.27: shop purchase counters reset per map (score also resets above)
    for (int i = 1; i <= MaxClients; i++)
        for (int j = 0; j < SHOP_SLOTS; j++)
            g_iShopBought[i][j] = 0;
    g_bMapEndBroadcasted = false;          // v1.7.9: fresh map, fresh flag
    Art_CleanupAll();                      // v1.7.80: 换图清理残留火炮罐子/瞄准状态
}

// ============================================================================
// round_end — reset streak state (matches the documented "streak resets
// per round" behavior; kills after the round ends must not settle an award)
// ============================================================================

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // v1.7.9: only the streak state resets here — the scoreboard stats
    // (score / SI kills / deaths / FF / blacked) survive until MAP end,
    // so a wipe-restart does not wipe the round's tally.
    for (int i = 1; i <= MaxClients; i++)
    {
        KillStreakTimer(i);
        g_iKillStreak[i] = 0;
        g_iCommonStreak[i] = 0;            // v1.7.4
        g_iStreakScore[i] = 0;
        g_iRescueStreak[i] = 0;            // v1.7.51
        g_fLastStreakKillTime[i] = 0.0;
        g_fSIHurtAt[i] = 0.0;              // v1.7.2
    }
    return Plugin_Continue;
}

// v1.7.30: 团灭重开判定——round_start 时若没有 OnMapStart（同图 restart），
// 回滚本关积分到地图开局快照（用户："这个map团灭了，要回到map初始时积分状态"）
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    WallhackEndAll();                        // v1.7.64: 换图/团灭重开 → 透视效果失效（静默）
    if (!g_bFreshMapStart)
    {
        RestoreScoreState();
        PrintToChatAll("\x04[得分榜]\x01 团灭重开：本关积分已回滚到开局状态");
    }
    g_bFreshMapStart = false;
    return Plugin_Continue;
}

// v1.7.9: checkpoint/finale finish — force ONE scoreboard broadcast before
// the map ends (the last chance to see this map's tally).
public Action Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue || !g_cvScoreboardEnable.BoolValue)
        return Plugin_Continue;
    if (!g_bMapEndBroadcasted)
    {
        BroadcastScoreboard();
        g_bMapEndBroadcasted = true;
    }
    return Plugin_Continue;
}

// ============================================================================
// OnClientPutInServer / OnClientDisconnect
// ============================================================================

public void OnClientPutInServer(int client)
{
    // v1.7.31 (user): 新加入玩家 = 全默认状态 —— 0 可用积分 + start 复活币 + base 复活次数
    // v1.7.34: 钱包/复活币恢复移到 OnClientPostAdminCheck（此时 Steam auth 才可用）
    g_iRevivesLeft[client] = g_cvRespawnBase.IntValue;
    g_bWallhack[client] = false;             // v1.7.64
    g_iTotalScore[client] = 0;
    g_iSIKills[client] = 0;
    g_iDeaths[client] = 0;
    g_iFFDamage[client] = 0;
    g_iBlacked[client] = 0;
}

public void OnClientPostAdminCheck(int client)
{
    // v1.7.43: 换图重连判定——20s 内同 SteamID 断线过 = changelevel 自动重连
    // → 恢复存档（同战役换图不丢钱）；否则 = 真实新加入 → 全默认 0
    char auth[32];
    bool reconnect = false;
    if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false))
    {
        float now = GetGameTime();
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_fDiscTime[i] > 0.0 && StrEqual(g_sDiscAuth[i], auth)
                && now - g_fDiscTime[i] < 20.0)
            {
                reconnect = true;
                g_fDiscTime[i] = 0.0;   // 消费记录
                break;
            }
        }
    }

    if (reconnect)
    {
        // v1.7.34: 从持久化文件恢复（存档战役校验在 ScoreLoad_Player 内）
        ScoreLoad_Player(client);
    }
    else
    {
        // v1.7.42 (user): 新加入玩家 = 全默认状态（0 可用积分 + start 复活币）
        g_iWallet[client] = 0;
        g_iReviveCoins[client] = g_cvRespawnCoinStart.IntValue;
    }
}

public void OnClientDisconnect(int client)
{
    ArtEndDesignate(client, true, false);   // v1.7.80: 断线取消火炮瞄准（退款+不恢复武器，须在 ScoreSave 前）
    ScoreSave_Player(client);            // v1.7.34: 断线保存（必须在清零前）
    // v1.7.43: 记录断线 SteamID + 时间（换图重连识别用）
    if (GetClientAuthId(client, AuthId_Steam2, g_sDiscAuth[client], sizeof(g_sDiscAuth[]), false))
        g_fDiscTime[client] = GetGameTime();
    else
        g_fDiscTime[client] = 0.0;
    g_fLastKillSoundTime[client] = 0.0;
    g_iKillStreak[client] = 0;
    g_iCommonStreak[client] = 0;           // v1.7.4
    g_iStreakScore[client] = 0;
    g_iRescueStreak[client] = 0;           // v1.7.51
    g_iTotalScore[client] = 0;             // v1.7.6 (本关积分断线清零，防槽位泄漏)
    g_iWallet[client] = 0;                 // v1.7.27 (可用积分断线清零)
    g_iRevivesLeft[client] = 0;            // v1.7.28
    g_iReviveCoins[client] = 0;            // v1.7.28
    KillRespawnTimer(client);              // v1.7.28
    WallhackEnd(client, true);             // v1.7.64: 断线清理透视（克隆/计时器）
    g_hShopMenu[client] = null;            // v1.7.64: 断线菜单句柄失效
    // v1.7.31b fix: 限购计数断线清零（否则下个进服玩家继承"已购满"）
    for (int j = 0; j < SHOP_SLOTS; j++)
        g_iShopBought[client][j] = 0;
    g_iSIKills[client] = 0;                // v1.7.7
    g_iDeaths[client] = 0;
    g_iFFDamage[client] = 0;
    g_iBlacked[client] = 0;
    g_fLastStreakKillTime[client] = 0.0;
    g_fSIHurtAt[client] = 0.0;             // v1.7.2
    KillHPHideTimer(client);
    KillStreakTimer(client);
    g_bFrameQueued[client] = false;
    delete g_hHurtVictims[client];
}

// ============================================================================
// Event: player_hurt — immediate HP refresh for the attacker
// ============================================================================

// v1.7.16: weapon-class damage multiplier for the damage points. Kill
// points do NOT scale (user decision) — only the damage score uses this.
// AR 1.0 / SMG 1.5 / magnum+melee 1.75 / pump 1.5 / auto shotguns + snipers
// 0.75 / everything else (pistol etc.) 1.0. Weak guns pay more per HP.
float GetDamageMult(int client)
{
    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon < 1 || !IsValidEntity(weapon))
        return g_cvDmgMultOther.FloatValue;

    char cls[32];
    GetEdictClassname(weapon, cls, sizeof(cls));
    if (StrEqual(cls, "weapon_rifle") || StrEqual(cls, "weapon_rifle_ak47")
        || StrEqual(cls, "weapon_rifle_desert") || StrEqual(cls, "weapon_rifle_sg552"))
        return g_cvDmgMultAR.FloatValue;
    if (StrEqual(cls, "weapon_smg") || StrEqual(cls, "weapon_smg_silenced")
        || StrEqual(cls, "weapon_smg_mp5"))
        return g_cvDmgMultSMG.FloatValue;
    if (StrEqual(cls, "weapon_pistol_magnum"))
        return g_cvDmgMultMagnum.FloatValue;
    // v1.7.52 (user): 手枪（含双枪）1.75
    if (StrEqual(cls, "weapon_pistol") || StrEqual(cls, "weapon_dual_pistols"))
        return g_cvDmgMultPistol.FloatValue;
    if (StrEqual(cls, "weapon_melee"))
        return g_cvDmgMultMelee.FloatValue;
    if (StrEqual(cls, "weapon_pumpshotgun") || StrEqual(cls, "weapon_shotgun_chrome"))   // v1.7.52: 铁喷 1.5
        return g_cvDmgMultPump.FloatValue;
    if (StrEqual(cls, "weapon_autoshotgun") || StrEqual(cls, "weapon_shotgun_spas"))
        return g_cvDmgMultAuto.FloatValue;
    if (StrEqual(cls, "weapon_hunting_rifle") || StrEqual(cls, "weapon_sniper_military")
        || StrEqual(cls, "weapon_sniper_awp") || StrEqual(cls, "weapon_sniper_scout"))
        return g_cvDmgMultSniper.FloatValue;
    return g_cvDmgMultOther.FloatValue;
}

public Action Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    // v1.7.2: track SI hurt time for the full-HP kill bonus — runs
    // independent of the HP display gate below (the bonus must not stop
    // working just because the HP HUD is disabled).
    int hurtVictim = GetClientOfUserId(event.GetInt("userid"));
    if (g_cvEnable.BoolValue
        && hurtVictim >= 1 && hurtVictim <= MaxClients
        && IsClientInGame(hurtVictim) && GetClientTeam(hurtVictim) == 3)
    {
        g_fSIHurtAt[hurtVictim] = GetGameTime();
    }

    // v1.7.7: friendly-fire damage tally (survivor → survivor)
    int ffAttacker = GetClientOfUserId(event.GetInt("attacker"));
    if (ffAttacker >= 1 && ffAttacker <= MaxClients
        && IsClientInGame(ffAttacker) && GetClientTeam(ffAttacker) == 2
        && hurtVictim >= 1 && hurtVictim <= MaxClients
        && GetClientTeam(hurtVictim) == 2)
    {
        g_iFFDamage[ffAttacker] += event.GetInt("dmg_health");
    }

    // v1.7.16: BF-style damage points — every survivor who damages an SI
    // (incl. Tank) earns score, scaled by weapon class. Runs before the HP
    // gate (damage scoring must not depend on the HP display cvar). Does
    // NOT touch the streak (award = kill streaks) and shows no chat spam —
    // it feeds the scoreboard total only.
    int dmgAttacker = GetClientOfUserId(event.GetInt("attacker"));
    if (g_cvEnable.BoolValue && g_cvDamageEnable.BoolValue
        && dmgAttacker >= 1 && dmgAttacker <= MaxClients
        && IsClientInGame(dmgAttacker) && GetClientTeam(dmgAttacker) == 2
        && hurtVictim >= 1 && hurtVictim <= MaxClients
        && IsClientInGame(hurtVictim) && GetClientTeam(hurtVictim) == 3)
    {
        int dmg = event.GetInt("dmg_health");
        if (dmg > 0)
        {
            int pts = RoundToFloor(dmg * GetDamageMult(dmgAttacker)
                * g_cvDamageCoeff.FloatValue);
            if (pts > 0)
            {
                g_iTotalScore[dmgAttacker] += pts;
                g_iWallet[dmgAttacker] += pts;      // v1.7.27
                // v1.7.25: display copy, per-killer — only accumulated
                // when the HP display is on (else nothing consumes it and
                // it would go stale).
                if (g_cvHPEnable.BoolValue)
                    g_iDmgPtsKiller[dmgAttacker][hurtVictim] += pts;
            }
        }
    }

    if (!g_cvEnable.BoolValue || !g_cvHPEnable.BoolValue)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
        return Plugin_Continue;
    if (GetClientTeam(victim) != 3)
        return Plugin_Continue;

    // On-hit HP refresh — batch per-frame for AoE (multiple hits same frame)
    if (g_hHurtVictims[attacker] == null)
        g_hHurtVictims[attacker] = new ArrayList();
    g_hHurtVictims[attacker].Push(victim);

    if (!g_bFrameQueued[attacker])
    {
        g_bFrameQueued[attacker] = true;
        RequestFrame(Frame_ShowHurtVictims, GetClientUserId(attacker));
    }
    return Plugin_Continue;
}

// ============================================================================
// OnEntityCreated — hook OnTakeDamage on Witch entities (single hook)
// (player_hurt never fires for NPCs like Witch; the Witch lives in the
// infected event system and the common path excludes her — her damage
// points go through this hook only)
// ============================================================================

public void OnEntityCreated(int entity, const char[] classname)
{
    if (!g_cvEnable.BoolValue)
        return;
    if (StrContains(classname, "witch") == -1)
        return;
    if (entity <= 0)   // v1.7.64: 防脏索引进 Witch 表（透视同步计时器每 tick 会校验，但 0 会抛异常）
        return;
    SDKHook(entity, SDKHook_OnTakeDamage, WitchTakeDamage);
    // v1.7.64: 记录 Witch 实体（透视克隆目标；脏条目由同步计时器校验剔除）
    if (g_hWitchList != null && g_hWitchList.FindValue(entity) == -1)
        g_hWitchList.Push(entity);
}

// v1.7.64: Witch 实体销毁时从表剔除（同步计时器每 tick 也会懒校验）
public void OnEntityDestroyed(int entity)
{
    if (g_hWitchList != null)
    {
        int idx = g_hWitchList.FindValue(entity);
        if (idx != -1)
            g_hWitchList.Erase(idx);
    }
}

// v1.7.2: SI (re)spawn resets the hurt tracker — a fresh SI starts as
// "untouched" for the full-HP kill bonus.
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client >= 1 && client <= MaxClients && GetClientTeam(client) == 3)
        g_fSIHurtAt[client] = 0.0;
    return Plugin_Continue;
}

// ============================================================================
// Event: player_death — SI kill feedback
// ============================================================================

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    // ── Branch A: SI player death ──────────────────────

    if (victim >= 1 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == 3)
    {
        bool validAtk = (attacker >= 1 && attacker <= MaxClients
                      && IsClientInGame(attacker) && GetClientTeam(attacker) == 2);

        if (validAtk)
            SurvivorKilledSI(attacker, victim, event);
        else
            SISystemDeath(victim, event);

        return Plugin_Continue;
    }

    // ── Branch B: Witch death (detected by entityid) ───

    int entityid = event.GetInt("entityid");
    if (entityid > 0 && IsWitchEntity(entityid))
    {
        if (attacker >= 1 && attacker <= MaxClients
            && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
        {
            SurvivorKilledWitch(attacker, event, entityid);
        }
        return Plugin_Continue;
    }

    // ── Branch C (v1.7.7): survivor death stats ──────

    if (victim >= 1 && victim <= MaxClients
        && IsClientInGame(victim) && GetClientTeam(victim) == 2)
    {
        g_iDeaths[victim]++;
        if (g_bWallhack[victim])             // v1.7.64: 死亡 → 透视效果丢失（用户规则）
            WallhackEnd(victim);
        if (attacker >= 1 && attacker <= MaxClients
            && attacker != victim && IsClientInGame(attacker)
            && GetClientTeam(attacker) == 2)
        {
            g_iBlacked[victim]++;          // 被队友击杀（被黑）
        }

        // v1.7.28: 复活次数判定——次数用完且无复活币 → 躺尸等电击器/过关
        // v1.7.32d: 跳过 bot（引擎有自己的 bot 重生逻辑，复活 bot 会干扰）
        if (g_cvRespawnEnable.BoolValue && !IsFakeClient(victim))
        {
            if (g_iRevivesLeft[victim] > 0)
            {
                g_iRevivesLeft[victim]--;
                ScheduleRespawn(victim, true);
            }
            else if (g_iReviveCoins[victim] > 0)
            {
                g_iReviveCoins[victim]--;
                ScheduleRespawn(victim, false);
                PrintToChat(victim, "\x04[复活]\x01 复活次数已用完，消耗 \x05复活币\x01 x1（剩余 \x03%d\x01 枚）",
                    g_iReviveCoins[victim]);
            }
            else
            {
                PrintToChat(victim, "\x04[复活]\x01 本图复活次数已用完（初始 \x03%d\x01 次 + 复活币 \x03%d\x01 枚）——等待电击器或队友",
                    g_cvRespawnBase.IntValue, g_iReviveCoins[victim]);
            }
        }
    }
    return Plugin_Continue;
}

// ============================================================================
// Event: infected_hurt — common infected damage points (v1.7.16)
// ============================================================================

// v1.7.16 (user): commons' HP damage counts into the damage points too.
// Commons fire NO player_hurt — infected_hurt is their equivalent
// (fields: entityid / attacker / amount / type). Same rules as SI damage:
// points = amount × weapon mult × si_hud_bf_damage_coeff_common (default
// 1.0 = 1:1 like SI). Scoreboard total only — no streak, no chat spam.
// WARNING in the cvar help: commons are unlimited, so at 1.0 horde-mowing
// out-scores SI kills (melee 1.75 × ~50hp = 87 一刀 vs 击杀 5 分).
public Action Event_InfectedHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue || !g_cvDamageEnable.BoolValue)
        return Plugin_Continue;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    // v1.7.56 (bug): 引擎对 Witch 受伤也发 infected_hurt（Witch 是 NPC 实体，
    // 归在 infected 事件里）—— 手枪打 Witch 被误当小僵尸加分 + 显示 "† 小僵尸"，
    // 且伤害分被计两次（此处 common 系数 + WitchTakeDamage 的 witch 系数）。
    // Witch 伤害分走 WitchTakeDamage（SDKHooks），这里直接排除。
    int entId = event.GetInt("entityid");
    if (entId >= 1 && entId < 2048)
    {
        char cls[16];
        GetEntityClassname(entId, cls, sizeof(cls));
        if (StrEqual(cls, "witch"))
        {
            // v1.7.58 (bug): v1.7.56 提前 return 不记录 → g_iLastCommonEnt
            // 永不为 witch → Event_InfectedDeath 的排除变死代码 → Witch 死亡
            // 被误当小僵尸：† 横幅覆盖女巫横幅 + 5 分入账 + † 骷髅。
            // 这里只记录实体供死亡排除（加分排除保留，防双计分）。
            g_iLastCommonEnt[attacker] = entId;
            return Plugin_Continue;
        }
    }

    int amount = event.GetInt("amount");
    if (amount <= 0)
        return Plugin_Continue;

    int pts = RoundToFloor(amount * GetDamageMult(attacker) * g_cvDamageCoeffCommon.FloatValue);
    if (pts > 0)
    {
        g_iTotalScore[attacker] += pts;
        g_iWallet[attacker] += pts;             // v1.7.27
        // v1.7.22: BF-style hit feedback — EVERY hit shows its damage-score
        // even without a kill (user: "只要造成伤害了，就有得分反馈"; BF1/BFV
        // pop the damage score near the crosshair on every hit). Commons
        // have no HP row, so the line is "† 小僵尸 +52" (damage pts only;
        // the kill line adds the fixed kill pts → +92). Same short channel
        // as the common kill line (common_time 1s); a same-frame kill
        // overwrites it with the +92 kill line (death fires after hurt).
        if (g_cvKillHintEnable.BoolValue && g_cvCommonEnable.BoolValue)
        {
            char msg[96];
            Format(msg, sizeof(msg), "† 小僵尸 +%d", pts);
            KillHPHideTimer(attacker);
            PrintCenterText(attacker, msg);
            g_hHPHideTimer[attacker] = CreateTimer(g_cvCommonTime.FloatValue,
                Timer_HideHP, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
        }
        // v1.7.21: display copy for the kill line — commons have NO HP
        // display row, so their damage points surface when the kill line
        // shows "† 小僵尸 +92" (= dmg pts + kill pts, user spec
        // "50×1.75 + 5"). NO hp_enable gate here — consumed by the kill
        // line, not by the HP display.
        int entity = event.GetInt("entityid");
        if (entity >= 1 && entity < 2048)
        {
            g_iDmgPtsKiller[attacker][entity] += pts;   // v1.7.25: per-killer
            g_iLastCommonEnt[attacker] = entity;        // v1.7.24: kill-line lookup
        }
    }
    return Plugin_Continue;
}

// ============================================================================
// WitchTakeDamage — unified Witch OnTakeDamage hook (v1.7.59)
// ============================================================================

// The Witch is an NPC (not a player entity) — player_hurt never fires for
// her and she is not a common, so neither event covers her. Hooks via
// OnEntityCreated; the hook lives as long as the entity does (freed on
// kill/despawn automatically).
//
// v1.7.59: single hook does BOTH scoring and display — score into the
// g_iDmgPtsKiller grid FIRST, then ShowWitchHP consumes it, so the +pts
// always shows on the Witch HP line (order was undefined with two hooks).
public Action WitchTakeDamage(int victim, int &attacker, int &inflictor,
                              float &damage, int &damagetype)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;
    if (damage <= 0.0)
        return Plugin_Continue;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    // ── score (independent of the HP display gate) ──
    if (g_cvDamageEnable.BoolValue)
    {
        // Same coefficient as SI (1.0 = 1:1): Witch 500 HP fully burned =
        // ~500 pts, matching her kill score.
        int pts = RoundToFloor(damage * GetDamageMult(attacker)
            * g_cvDamageCoeff.FloatValue);
        if (pts > 0)
        {
            g_iTotalScore[attacker] += pts;
            g_iWallet[attacker] += pts;             // v1.7.27
            // v1.7.25: display copy for ShowWitchHP / witch kill card
            // (victim = witch ENTITY idx)
            // v1.7.31b fix: 实体索引 < 2048 才写（SourcePawn 越界 = 运行时错误）
            if (g_cvHPEnable.BoolValue && victim >= 1 && victim < 2048)
                g_iDmgPtsKiller[attacker][victim] += pts;
        }
    }

    // ── display — same hook, score already in the grid so +pts is ready ──
    if (g_cvHPEnable.BoolValue && g_cvHPShowWitch.BoolValue)
        ShowWitchHP(attacker, victim);

    return Plugin_Continue;
}

// ============================================================================
// Event: infected_death — common infected headshot sound
// ============================================================================

public Action Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    bool headshot = event.GetBool("headshot");

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker))
        return Plugin_Continue;
    if (GetClientTeam(attacker) != 2)
        return Plugin_Continue;

    // v1.7.56 (bug): 排除 Witch —— 引擎对 Witch 死亡也可能发 infected_death
    //（回退路径 g_iLastCommonEnt 此时 = Witch 实体），会误显示 "† 小僵尸"。
    int witchEnt = g_iLastCommonEnt[attacker];
    if (witchEnt >= 1 && witchEnt < 2048)
    {
        char cls[16];
        GetEntityClassname(witchEnt, cls, sizeof(cls));
        if (StrEqual(cls, "witch"))
        {
            g_iLastCommonEnt[attacker] = 0;
            g_iDmgPtsKiller[attacker][witchEnt] = 0;
            return Plugin_Continue;
        }
    }

    // v1.7.3: common infected are fully taken over — they score points,
    // stack the streak (→ award settle), and show a center kill line.
    // † (U+2020 dagger) marks a common kill; ★ (U+2605) marks a headshot —
    // same as the SI card (center text has NO color codes, so "gold" is
    // ★, verified v1.7.1). No chat feed for commons (spam).
    int points = g_cvBFPointsCommon.IntValue;
    if (headshot) points += g_cvBFPointsCommonHS.IntValue;
    if (points > 0)
        StackStreakKill(attacker, points, true);

    if (g_cvKillHintEnable.BoolValue && g_cvCommonEnable.BoolValue)
    {
        // v1.7.4: two-line like the SI card — icon row on top (★/† prefix
        // on the second line marks THIS kill's headshot).
        // v1.7.21 (user): the line shows the FULL kill score — this target's
        // damage points (dmg × weapon mult, e.g. magnum 50hp = 87) PLUS the
        // fixed kill points (5/10): "† 小僵尸 +92" per "50×1.75 + 5".
        // v1.7.24: infected_death has NO entity field → look the pts up via
        // the killer's last-hit common entity instead.
        int ent = g_iLastCommonEnt[attacker];
        int dmgPts = 0;
        if (ent >= 1 && ent < 2048)
        {
            // v1.7.58: 防 witch 伤害分串台——last-ent 可能是 Witch 实体（打
            // witch 后未再碰小僵尸，实体已死索引未复用），其伤害分存在同一
            // 张网格里，不校验会被当成小僵尸伤害分显示。
            char cls[16];
            GetEntityClassname(ent, cls, sizeof(cls));
            if (!StrEqual(cls, "witch"))
            {
                dmgPts = g_iDmgPtsKiller[attacker][ent];   // v1.7.25: per-killer
                g_iDmgPtsKiller[attacker][ent] = 0;        // consumed with the kill
            }
            g_iLastCommonEnt[attacker] = 0;
        }
        int showPts = points + dmgPts;

        char icons[80];
        BuildStreakIcons(icons, sizeof(icons), attacker);
        char msg[160];
        if (headshot)
            Format(msg, sizeof(msg), "%s\n★ 小僵尸 +%d", icons, showPts);
        else
            Format(msg, sizeof(msg), "%s\n† 小僵尸 +%d", icons, showPts);

        KillHPHideTimer(attacker);
        PrintCenterText(attacker, msg);
        g_hHPHideTimer[attacker] = CreateTimer(g_cvCommonTime.FloatValue, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
    }

    // Headshot kill sound (existing; empty = off).
    if (headshot)
    {
        char sound[PLATFORM_MAX_PATH];
        g_cvSoundCommonHS.GetString(sound, sizeof(sound));
        if (sound[0] != '\0' && SoundCooldownOK(attacker))
            PlayClientSound(attacker, sound);
    }
    return Plugin_Continue;
}

// ============================================================================
// ============================================================================
// Frame callback: show all victims hit this frame (batched for AoE / penetration)
// ============================================================================

void Frame_ShowHurtVictims(any userId)
{
    int client = GetClientOfUserId(userId);
    g_bFrameQueued[client] = false;

    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
    {
        delete g_hHurtVictims[client];
        return;
    }

    ArrayList list = g_hHurtVictims[client];
    if (list == null || list.Length == 0)
        return;

    // Deduplicate: same victim can be hurt multiple times in one frame
    // (e.g. shotgun pellets). Keep only the first occurrence.
    int count = list.Length;
    for (int i = count - 1; i >= 1; i--)
    {
        int v = list.Get(i);
        for (int j = 0; j < i; j++)
        {
            if (list.Get(j) == v)
            {
                list.Erase(i);
                break;
            }
        }
    }

    char msg[512];
    msg[0] = '\0';
    int shown;

    for (int i = 0; i < list.Length; i++)
    {
        int victim = list.Get(i);
        if (victim < 1 || victim > MaxClients
            || !IsClientInGame(victim) || GetClientTeam(victim) != 3
            || !IsPlayerAlive(victim))
            continue;
        if (!g_cvHPShowWitch.BoolValue && IsTankOrWitch(victim) == 2)
            continue;

        int hp    = GetClientHealth(victim);
        int maxHp = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
        if (maxHp <= 0) maxHp = 1;

        char siName[64];
        GetSIName(victim, siName, sizeof(siName));

        float ratio = float(hp) / float(maxHp);
        int barLen  = RoundToFloor(ratio * 10.0);
        if (barLen < 0)  barLen = 0;
        if (barLen > 10) barLen = 10;

        char bar[16];
        int k;
        for (k = 0; k < barLen; k++) bar[k] = '|';
        for (; k < 10; k++) bar[k] = ' ';
        bar[10] = '\0';

        char line[128];
        // v1.7.25: append THIS killer's share of damage points on this
        // victim (consumed here — per-frame copy, no double-count).
        int pts = g_iDmgPtsKiller[client][victim];
        g_iDmgPtsKiller[client][victim] = 0;
        if (pts > 0)
            Format(line, sizeof(line), "%s  [%s] %d/%d +%d\n",
                siName, bar, hp, maxHp, pts);
        else
            Format(line, sizeof(line), "%s  [%s] %d/%d\n",
                siName, bar, hp, maxHp);
        StrCat(msg, sizeof(msg), line);
        shown++;
    }

    list.Clear();

    // Only show HP if at least one victim is still alive.
    // When shown==0 (all victims died this frame), do NOT clear
    // PrintCenterText — the kill-confirm message from player_death
    // is already there and would be overwritten.
    if (shown > 0)
    {
        PrintCenterText(client, msg);

        // Auto-hide HP after configured duration
        KillHPHideTimer(client);
        g_hHPHideTimer[client] = CreateTimer(g_cvHPInterval.FloatValue, Timer_HideHP,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// ShowWitchHP — called when attacker directly damages a Witch entity
// ============================================================================

void ShowWitchHP(int client, int witch)
{
    if (!IsClientInGame(client) || GetClientTeam(client) != 2)
        return;
    if (!IsValidEntity(witch))
        return;

    int hp = GetEntProp(witch, Prop_Data, "m_iHealth");
    if (hp <= 0) return;
    int maxHp = GetEntProp(witch, Prop_Data, "m_iMaxHealth");
    if (maxHp <= 0) maxHp = 1;

    float ratio = float(hp) / float(maxHp);
    int barLen = RoundToFloor(ratio * 10.0);
    if (barLen < 0) barLen = 0;
    if (barLen > 10) barLen = 10;

    char bar[16];
    int k;
    for (k = 0; k < barLen; k++) bar[k] = '|';
    for (; k < 10; k++) bar[k] = ' ';
    bar[10] = '\0';

    char msg[256];
    // v1.7.25: Witch damage points on the HP line — killer's own share.
    // v1.7.31b fix: 实体索引边界检查
    int pts = 0;
    if (witch >= 1 && witch < 2048)
    {
        pts = g_iDmgPtsKiller[client][witch];
        g_iDmgPtsKiller[client][witch] = 0;
    }
    if (pts > 0)
        Format(msg, sizeof(msg), "WITCH  女巫  [%s] %d/%d +%d\n",
            bar, hp, maxHp, pts);
    else
        Format(msg, sizeof(msg), "WITCH  女巫  [%s] %d/%d\n",
            bar, hp, maxHp);

    PrintCenterText(client, msg);
    KillHPHideTimer(client);
    g_hHPHideTimer[client] = CreateTimer(g_cvHPInterval.FloatValue, Timer_HideHP,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// ============================================================================
// Kill feedback: survivor killed SI — PrintCenterText (upper-center, no shadow)
// ============================================================================

void SurvivorKilledSI(int attacker, int victim, Event event)
{
    bool headshot = event.GetBool("headshot");

    char weaponEnt[64], weaponDisplay[64], playerName[64], siName[64];
    event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
    GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
    GetClientName(attacker, playerName, sizeof(playerName));
    GetSIName(victim, siName, sizeof(siName));

    bool melee  = IsMeleeWeapon(weaponEnt);
    bool isTank = (IsTankOrWitch(victim) == 1);

    // v1.7.52 (user): 击杀分 = 基础(血×25% ceil) × 爆头1.5 × 满血1.25；
    // 近战加成取消。倍率链合并后统一向上取整（938 = 500×1.5×1.25 例）。
    int points = PointsForSI(victim);
    float mult = 1.0;
    if (headshot) mult *= g_cvBFHeadshotMult.FloatValue;
    if (g_fSIHurtAt[victim] == 0.0) mult *= g_cvBFFullHPMult.FloatValue;
    if (mult != 1.0)
        points = RoundToCeil(points * mult);

    // ── Streak & score (v1.7.57: independent of HUD display) ──
    // StackStreakKill 移出 kill_hint 门控（原藏在 BuildBFBanner 里，关 HUD
    // 会连击杀分和连杀一起丢）——与 Event_InfectedDeath 一致：先入账，后显示。
    if (points > 0)
        StackStreakKill(attacker, points, false);

    // ── Sound (independent cooldown, does NOT block HUD/chat) ──

    if (SoundCooldownOK(attacker))
    {
        char sound[PLATFORM_MAX_PATH];
        if (isTank)
            PickSound(sound, sizeof(sound), g_cvSoundTank, g_cvSoundSI);
        else if (headshot)
            PickSound(sound, sizeof(sound), g_cvSoundHeadshot, g_cvSoundSI);
        else if (melee)
            PickSound(sound, sizeof(sound), g_cvSoundMelee, g_cvSoundSI);
        else
            g_cvSoundSI.GetString(sound, sizeof(sound));

        PlayClientSound(attacker, sound);
    }

    // ── Suffix ──────────────────────────────────────────

    char suffix[32];
    if (isTank && headshot)       suffix = "  爆头 ★";
    else if (isTank && melee)     suffix = "  近战 ★";
    else if (isTank)              suffix = "  ★";
    else if (headshot && melee)   suffix = "  爆头近战";
    else if (headshot)            suffix = "  爆头";
    else if (melee)               suffix = "  近战";

    // ── Chat ────────────────────────────────────────────

    if (g_cvChatEnable.BoolValue)
    {
        char chatMsg[256];
        Format(chatMsg, sizeof(chatMsg),
            "\x04%s\x01  [%s] KILL \x03%s\x01%s",
            playerName, weaponDisplay, siName, suffix);
        PrintToChatAll(chatMsg);
    }

    // ── Kill display (v1.7.1) ──
    // ONE PrintCenterText message, two lines (BF5-style):
    //   line 1: banner — ☠☠☠ skull row + type + rolling score (BuildBFBanner)
    //   line 2: card   — [weapon] ☠ SI name (gold ☠ = headshot) (BuildKillCard)
    // Shown si_hud_killcard_time then cleared with " " — the center channel
    // has no shadow box, no priming bug, and clears instantly. The hint
    // channel was abandoned in v1.7.1 (dead end on L4D2, see changelog).

    if (g_cvKillHintEnable.BoolValue)
    {
        char banner[192];
        BuildBFBanner(banner, sizeof(banner), attacker,
            isTank ? "坦克击杀" : headshot ? "爆头击杀" : melee ? "近战击杀" : "击杀",
            siName);

        char msg[256];
        if (g_cvKillCardEnable.BoolValue)
        {
            char card[192];
            BuildKillCard(card, sizeof(card), weaponDisplay, siName, headshot);
            // v1.7.25 (user): the SI kill card shows THIS killer's full
            // kill score — their damage share on this target + kill points
            // (e.g. magnum 100hp → 17 dmg pts + 100 kill = "+117").
            int dmgPts = g_iDmgPtsKiller[attacker][victim];
            g_iDmgPtsKiller[attacker][victim] = 0;
            if (dmgPts > 0)
            {
                char tmp[32];
                Format(tmp, sizeof(tmp), " +%d", points + dmgPts);
                StrCat(card, sizeof(card), tmp);
            }
            Format(msg, sizeof(msg), "%s\n%s", banner, card);
        }
        else
        {
            strcopy(msg, sizeof(msg), banner);
        }

        KillHPHideTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, msg);
        g_hHPHideTimer[attacker] = CreateTimer(g_cvKillCardTime.FloatValue, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// Kill feedback: survivor killed Witch
// ============================================================================

void SurvivorKilledWitch(int attacker, Event event, int witchEnt)
{
    bool headshot = event.GetBool("headshot");

    char weaponEnt[64], weaponDisplay[64], playerName[64];
    event.GetString("weapon", weaponEnt, sizeof(weaponEnt));
    GetWeaponDisplayName(weaponEnt, weaponDisplay, sizeof(weaponDisplay));
    GetClientName(attacker, playerName, sizeof(playerName));

    // ── Sound (independent cooldown) ────────────────────

    if (SoundCooldownOK(attacker))
    {
        char sound[PLATFORM_MAX_PATH];
        PickSound(sound, sizeof(sound), g_cvSoundWitch, g_cvSoundSI);
        PlayClientSound(attacker, sound);
    }

    char suffix[16];
    if (headshot) suffix = "  爆头";

    // v1.7.2: Witch scores its base + headshot/melee bonuses (BF style).
    // No full-HP bonus: player_hurt never fires for NPC Witch entities.
    // v1.7.52: Witch 固定 500；爆头 ×1.5；无满血（NPC 不触发 player_hurt）
    int points = g_cvBFPointsWitch.IntValue;
    if (headshot)
        points = RoundToCeil(points * g_cvBFHeadshotMult.FloatValue);

    // v1.7.57: 与 SI 同——入账移出 HUD 门控，kill_hint 关闭时女巫击杀仍计连杀
    if (points > 0)
        StackStreakKill(attacker, points, false);

    if (g_cvChatEnable.BoolValue)
    {
        char chatMsg[256];
        Format(chatMsg, sizeof(chatMsg),
            "\x04%s\x01  [%s] KILL \x03WITCH 女巫\x01%s",
            playerName, weaponDisplay, suffix);
        PrintToChatAll(chatMsg);
    }

    // [v1.7.1] Same merged two-line layout as SurvivorKilledSI.

    if (g_cvKillHintEnable.BoolValue)
    {
        char banner[192];
        BuildBFBanner(banner, sizeof(banner), attacker,
            "女巫击杀", "WITCH 女巫");

        char msg[256];
        if (g_cvKillCardEnable.BoolValue)
        {
            char card[192];
            BuildKillCard(card, sizeof(card), weaponDisplay, "WITCH 女巫", headshot);
            // v1.7.25: same as the SI card — killer's damage share + kill pts.
            // v1.7.31b fix: 实体索引边界检查
            int dmgPts = 0;
            if (witchEnt >= 1 && witchEnt < 2048)
            {
                dmgPts = g_iDmgPtsKiller[attacker][witchEnt];
                g_iDmgPtsKiller[attacker][witchEnt] = 0;
            }
            if (dmgPts > 0)
            {
                char tmp[32];
                Format(tmp, sizeof(tmp), " +%d", points + dmgPts);
                StrCat(card, sizeof(card), tmp);
            }
            Format(msg, sizeof(msg), "%s\n%s", banner, card);
        }
        else
        {
            strcopy(msg, sizeof(msg), banner);
        }

        KillHPHideTimer(attacker);
        delete g_hHurtVictims[attacker];
        PrintCenterText(attacker, msg);
        g_hHPHideTimer[attacker] = CreateTimer(g_cvKillCardTime.FloatValue, Timer_HideHP,
            GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
    }
}

// ============================================================================
// System death: SI suicide / environment kill
// ============================================================================

void SISystemDeath(int victim, Event event)
{
    char siName[64], victimName[64];
    GetSIName(victim, siName, sizeof(siName));
    GetClientName(victim, victimName, sizeof(victimName));

    int rawAttacker = event.GetInt("attacker");
    bool suicide = (rawAttacker == event.GetInt("userid"));

    if (g_cvChatEnable.BoolValue)
    {
        char chatMsg[256];
        if (suicide)
            Format(chatMsg, sizeof(chatMsg),
                "\x04%s\x01  [\x03%s\x01]  \x05自杀了", victimName, siName);
        else
            Format(chatMsg, sizeof(chatMsg),
                "\x04%s\x01  [\x03%s\x01]  \x05死于意外", victimName, siName);
        PrintToChatAll(chatMsg);
    }

    // [v1.4.1] Reverted to PrintCenterText — no shadow box to get stuck.

    if (g_cvKillHintEnable.BoolValue)
    {
        char killMsg[128];
        if (suicide)
            Format(killMsg, sizeof(killMsg), "☠ %s  自杀了", siName);
        else
            Format(killMsg, sizeof(killMsg), "☠ %s  死于意外", siName);

        for (int i = 1; i <= MaxClients; i++)
        {
            if (IsClientInGame(i) && GetClientTeam(i) == 2)
            {
                KillHPHideTimer(i);
                delete g_hHurtVictims[i];
                PrintCenterText(i, killMsg);
                g_hHPHideTimer[i] = CreateTimer(2.5, Timer_HideHP,
                    GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
            }
        }
    }
}

// ============================================================================
// Kill card — PrintHintText (lower-center, shadow box = BF1-style
// background), v1.6.4. Card line only: "[weapon] ☠ SI name" (+ "(head shot)").
// Streak skulls and points live in the center banner (BuildBFBanner).
// ☠ = U+2620 (3-byte BMP; the 4-byte 💀 does not render on Source).
// ============================================================================

void BuildKillCard(char[] buffer, int maxlen,
                   const char[] weapon, const char[] siName, bool headshot)
{
    // v1.7.1: "(head shot)" suffix dropped — a headshot is now a ★ (U+2605,
    // the closest BMP glyph to a gold star; center text has NO color codes,
    // verified with the hud test plugin — \x07FFD700 was not parsed).
    // The headshot point bonus is already in the banner (bf_points_headshot).
    if (headshot)
        Format(buffer, maxlen, "[%s] ★ %s", weapon, siName);
    else
        Format(buffer, maxlen, "[%s] ☠ %s", weapon, siName);
}

// ============================================================================
// Kill card — merged into the center message (v1.7.1); see BuildKillCard.
// The PrintHintText machinery (prime/RequestFrame/queued flag) was removed
// entirely — the hint channel is a dead end on L4D2 (see changelog).
// ============================================================================


// ============================================================================
// BF-style kill banner — "☠☠☠" skull row (one skull per kill in the streak
// window, BF5-style side-by-side) + type line with points
// ============================================================================

// v1.7.2: one streak stack point for ALL kill sources (SI / Witch / common)
// — common infected also build the streak and the award settle.
// v1.7.4: SI and common counts are SEPARATE (icons are counted per type),
// but they share one window timer, one rolling score, one settle.
void StackStreakKill(int client, int points, bool isCommon)
{
    // Streak: kills inside the window stack icons; window gap resets BOTH
    float now = GetGameTime();
    if (now - g_fLastStreakKillTime[client] > g_cvBFWindow.FloatValue)
    {
        g_iKillStreak[client] = 0;
        g_iCommonStreak[client] = 0;     // v1.7.4: separate count, shared window
        g_iStreakScore[client] = 0;      // v1.6.7: rolling score resets with the streak
        g_iRescueStreak[client] = 0;     // v1.7.51: rescue count shares the window
    }
    if (isCommon)
        g_iCommonStreak[client]++;
    else
    {
        g_iKillStreak[client]++;
        g_iSIKills[client]++;              // v1.7.7: scoreboard SI kill count
    }
    g_fLastStreakKillTime[client] = now;

    // v1.6.7: BF1-style rolling score counter — the banner shows the
    // ACCUMULATED streak score (100 → 250 → 400 …), not the single kill's
    // points. Resets when the streak settles (Timer_StreakSettle) or on
    // round_end. This is the "animated score counter" feedback BF1 is known
    // for — the number visibly grows with every kill in the window.
    g_iStreakScore[client] += points;
    g_iTotalScore[client] += points;      // v1.7.6: scoreboard accumulation (历史积分)
    g_iWallet[client] += points;          // v1.7.27: 当前积分（钱包）

    // v1.6.6: schedule the streak settle — when the window closes the
    // killer hears the BF1 award sound for their score tier.
    ScheduleStreakSettle(client);
}

// v1.7.51 (user): 救援队友算分——救援计入连杀（刷新 6 秒窗口 + 累计滚动分 +
// 结算卡显示），奖励分直接入账钱包/总分。revive_success 覆盖拉人（被扑/骑/
// 舌头/挂边）和电击（L4D2 无专门 defib 事件，实锤也走 revive_success），
// 统一 si_hud_points_rescue 分（默认 75）。
public Action Event_ReviveSuccess(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnable.BoolValue)
        return Plugin_Continue;

    int reviver = GetClientOfUserId(event.GetInt("reviver"));
    if (reviver < 1 || reviver > MaxClients || !IsClientInGame(reviver)
        || GetClientTeam(reviver) != 2)
        return Plugin_Continue;

    int revived = GetClientOfUserId(event.GetInt("revived"));
    if (revived == reviver)
        return Plugin_Continue;            // 防御：defib 不能自电，正常不会相等

    int pts = g_cvPointsRescue.IntValue;
    if (pts <= 0)
        return Plugin_Continue;

    // 与击杀共享窗口重置逻辑：窗口过期则清空连杀状态
    float now = GetGameTime();
    if (now - g_fLastStreakKillTime[reviver] > g_cvBFWindow.FloatValue)
    {
        g_iKillStreak[reviver] = 0;
        g_iCommonStreak[reviver] = 0;
        g_iStreakScore[reviver] = 0;
        g_iRescueStreak[reviver] = 0;
    }
    g_iRescueStreak[reviver]++;
    g_iStreakScore[reviver] += pts;        // 推动音效档位判定（纯击杀+救援混合分）
    g_iTotalScore[reviver] += pts;         // 历史积分（排行榜）
    g_iWallet[reviver] += pts;             // 当前积分（商店钱包）
    g_fLastStreakKillTime[reviver] = now;  // 救援刷新连杀窗口
    ScheduleStreakSettle(reviver);

    PrintToChat(reviver, "\x04[得分]\x01 你救起了 \x03%N\x01，+\x03%d\x01分", revived, pts);
    return Plugin_Continue;
}

// v1.7.4: one icon row, SI skulls (☠) and common daggers (†) as separate
// segments — "3 commons + 1 SI" shows "☠ †††", NOT 4 skulls. Up to
// si_hud_icons_max icons in the row; over that shows "+N".
void BuildStreakIcons(char[] buffer, int maxlen, int client)
{
    int si = g_iKillStreak[client];
    int cm = g_iCommonStreak[client];
    int total = si + cm;
    int cap = g_cvIconsMax.IntValue;
    if (cap < 1) cap = 1;

    buffer[0] = '\0';
    int shown = 0;
    for (int k = 0; k < si && shown < cap; k++, shown++)
        StrCat(buffer, maxlen, "☠");           // BMP U+2620 — renders
    if (cm > 0 && shown < cap)
        StrCat(buffer, maxlen, " ");           // segment gap: skulls | daggers
    for (int k = 0; k < cm && shown < cap; k++, shown++)
        StrCat(buffer, maxlen, "†");           // U+2020 dagger (user choice)

    if (total > cap)
    {
        char over[16];
        Format(over, sizeof(over), " +%d", total - cap);
        StrCat(buffer, maxlen, over);
    }
}

// v1.7.57: pure display — streak/score stacking moved OUT to the callers
// (SurvivorKilledSI / SurvivorKilledWitch, before the HUD gate), so kills
// still count when si_hud_kill_hint_enable is off (same as commons).
void BuildBFBanner(char[] buffer, int maxlen, int client,
                   const char[] type, const char[] siName)
{
    char icons[80];
    BuildStreakIcons(icons, sizeof(icons), client);

    Format(buffer, maxlen, "%s\n%s · %s  +%d", icons, type, siName, g_iStreakScore[client]);
}

// ============================================================================
// BF1 streak award sounds (v1.6.6)
// ============================================================================

void ScheduleStreakSettle(int client)
{
    if (!g_cvStreakEnable.BoolValue)
        return;
    KillStreakTimer(client);
    g_hStreakTimer[client] = CreateTimer(g_cvBFWindow.FloatValue, Timer_StreakSettle,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_StreakSettle(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    g_hStreakTimer[client] = null;
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2)
        return Plugin_Stop;

    float now = GetGameTime();
    // The window did not close yet (a kill landed near the fire time) — wait
    // another full window. Negative now-last means a map change reset the
    // game time: give up (OnMapEnd already reset streak state).
    if (now < g_fLastStreakKillTime[client]
        || now - g_fLastStreakKillTime[client] < g_cvBFWindow.FloatValue)
    {
        if (now < g_fLastStreakKillTime[client])
            return Plugin_Stop;
        g_hStreakTimer[client] = CreateTimer(g_cvBFWindow.FloatValue, Timer_StreakSettle,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    int siCount = g_iKillStreak[client];       // v1.7.5: separate counts for the settle card
    int commonCount = g_iCommonStreak[client];
    int rescueCount = g_iRescueStreak[client]; // v1.7.51
    int streak = siCount + commonCount;        // combined for the multi-kill bonus
    int score = g_iStreakScore[client];   // v1.7.2: capture before reset — settle display
    g_iKillStreak[client] = 0;            // settle: reset for the next run
    g_iCommonStreak[client] = 0;          // v1.7.4
    g_iRescueStreak[client] = 0;          // v1.7.51
    g_iStreakScore[client] = 0;           // v1.6.7: rolling score resets on settle
    g_fLastStreakKillTime[client] = 0.0;
    LogMessage("[streak] %N settle kills=%d rescues=%d score=%d", client, streak, rescueCount, score);   // debug
    if (score <= 0)
        return Plugin_Stop;

    // v1.7.53 (user): 连杀奖励 = 加权人头 × 阶梯分段（电费模式）——小僵尸 1
    // 人头、特感 6 人头；奖励 = Σ(各段实际人头 × 1.3 × 该段倍率)，段边界
    // 20/40/55/70/85/100，倍率一级 10 每段 +1.5；落在阈值之间按实际值分段
    // 累计（无跳档悬崖）。每段 ceil 累加。救援不占人头（贡献已在滚动分）。
    // v1.7.54 (user fix): 第一档边界是门槛——hw < l1（20 人头）不开闸，
    // 奖励为 0（2 特感 hw=12 之前错发 156）；达到门槛后全段计价
    // （例 hw=24 → 320 = 20×13 + 4×14.5 不变）。
    int hw = siCount * 6 + commonCount;
    int bonus = 0;
    if (hw >= g_cvStreakHwL1.IntValue)
    {
        float segEdge[6];
        segEdge[0] = g_cvStreakHwL1.FloatValue;
        segEdge[1] = g_cvStreakHwL2.FloatValue;
        segEdge[2] = g_cvStreakHwL3.FloatValue;
        segEdge[3] = g_cvStreakHwL4.FloatValue;
        segEdge[4] = g_cvStreakHwL5.FloatValue;
        segEdge[5] = g_cvStreakHwL6.FloatValue;
        // v1.7.63: 每档手配倍率（10/14/19/25/32/40）——加速曲线，替代
        // mult_step 线性步进（1.5/档 → 各段增量近似持平，高段无激励）。
        float segMult[6];
        segMult[0] = g_cvStreakBonusMultL1.FloatValue;
        segMult[1] = g_cvStreakBonusMultL2.FloatValue;
        segMult[2] = g_cvStreakBonusMultL3.FloatValue;
        segMult[3] = g_cvStreakBonusMultL4.FloatValue;
        segMult[4] = g_cvStreakBonusMultL5.FloatValue;
        segMult[5] = g_cvStreakBonusMultL6.FloatValue;
        float coeff = g_cvStreakBonusCoeff.FloatValue;
        float prev = 0.0;
        float remain = float(hw);
        for (int k = 0; k < 6; k++)
        {
            float seg = remain;
            if (seg > segEdge[k] - prev)
                seg = segEdge[k] - prev;        // 段内人头（本段上界截断）
            if (seg > 0.0)
                bonus += RoundToCeil(seg * coeff * segMult[k]);
            remain -= seg;
            if (remain <= 0.0)
                break;
            prev = segEdge[k];
        }
        if (remain > 0.0)                        // 超出最后一段上界
            bonus += RoundToCeil(remain * coeff * segMult[5]);
    }
    // v1.7.60 (user): 结算整体受阈值门控——hw < 20（3 特感 = 18、单只女巫 =
    // 6）窗口关闭时只静默重置连杀状态（上方已完成），不弹"连杀结算"卡、
    // 不播奖励音效。之前结算卡只看 score>0，hw=18 无奖励也弹卡 +295 误导。
    // 连杀状态已在上方重置，这里直接退出即可。
    if (bonus <= 0)
        return Plugin_Stop;
    g_iTotalScore[client] += bonus;   // 历史积分（排行榜）
    g_iWallet[client] += bonus;       // 当前积分（商店钱包）
    LogMessage("[streak] %N bonus +%d credited (hw=%d)", client, bonus, hw);

    // v1.7.62 (user): 音效档位 = 人头阶梯段位 L1..L6——与奖励同一把尺子，
    // 段位直接决定播哪首歌。v1.7.60 门控保证 hw >= L1，所以结算必有音效
    // （最低 L1 spotting，无静默档）。26 小僵尸 (hw=26) → L1 段。
    char sound[PLATFORM_MAX_PATH];
    ConVar cv;
    if (hw >= g_cvStreakHwL6.IntValue)      cv = g_cvStreakSnd6;
    else if (hw >= g_cvStreakHwL5.IntValue) cv = g_cvStreakSnd5;
    else if (hw >= g_cvStreakHwL4.IntValue) cv = g_cvStreakSnd4;
    else if (hw >= g_cvStreakHwL3.IntValue) cv = g_cvStreakSnd3;
    else if (hw >= g_cvStreakHwL2.IntValue) cv = g_cvStreakSnd2;
    else                                    cv = g_cvStreakSnd1;   // hw 20-39
    if (cv != null)
    {
        cv.GetString(sound, sizeof(sound));
        if (sound[0] != '\0')
            PlayStreakSound(client, sound);
    }

    // v1.7.2: settle display — BF1-style streak score record. BF1 awards a
    // bonus on multi-kills (Double +30 / Triple +50 / Multi +100); show the
    // accumulated kill score + that bonus while the award sound plays.
    // v1.7.50: total = score + bonus 现在与入账一致 — 累计分击杀时已入账，奖励
    // 结算时入账，玩家看到的结算数字 = 本连杀的总收益。
    ShowStreakSettle(client, siCount, commonCount, rescueCount, score, bonus);
    return Plugin_Stop;
}

// v1.7.5 (user): settle record is a text tally —
//   "† 小僵尸 ×3、☠ 特感 ×2、+430分"
// Commons first (user order), zero-count entries omitted, score = kills + bonus.
// v1.7.16 (user): shown in the killer's OWN chat box — chat lines persist,
// so the tally stays visible for the whole award sound (the old 2s center
// card vanished before the longer sounds ended).
void ShowStreakSettle(int client, int siCount, int commonCount,
                      int rescueCount, int score, int bonus)
{
    int total = score + bonus;

    // Center "hit" area (v1.7.19, user): the settle also flashes there for
    // 2s. The center/HUD font HAS the icons (☠ † ×) — chat does not, so
    // the two channels use different text: icons here, plain text in chat.
    char cpart[128];
    cpart[0] = '\0';
    if (commonCount > 0)
        Format(cpart, sizeof(cpart), "† 小僵尸 ×%d", commonCount);
    if (siCount > 0)
    {
        char tmp[64];
        Format(tmp, sizeof(tmp), "%s☠ 特感 ×%d",
            cpart[0] != '\0' ? "、" : "", siCount);
        StrCat(cpart, sizeof(cpart), tmp);
    }
    if (rescueCount > 0)                       // v1.7.51: 救援计入结算卡
    {
        char tmp[64];
        Format(tmp, sizeof(tmp), "%s+ 救援 ×%d",
            cpart[0] != '\0' ? "、" : "", rescueCount);
        StrCat(cpart, sizeof(cpart), tmp);
    }
    char cmsg[160];
    if (cpart[0] != '\0')
        Format(cmsg, sizeof(cmsg), "%s、+%d分", cpart, total);
    else
        Format(cmsg, sizeof(cmsg), "+%d分", total);
    KillHPHideTimer(client);
    PrintCenterText(client, cmsg);
    g_hHPHideTimer[client] = CreateTimer(2.0, Timer_HideHP,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    // Chat (Verdana-safe: no ☠/† — renders as "?"; × (U+00D7) also wrong
    // per user — ASCII "x" only).
    char parts[128];
    parts[0] = '\0';
    if (commonCount > 0)
        Format(parts, sizeof(parts), "小僵尸 x%d", commonCount);
    if (siCount > 0)
    {
        char tmp[64];
        Format(tmp, sizeof(tmp), "%s特感 x%d",
            parts[0] != '\0' ? "、" : "", siCount);
        StrCat(parts, sizeof(parts), tmp);
    }
    if (rescueCount > 0)                       // v1.7.51
    {
        char tmp[64];
        Format(tmp, sizeof(tmp), "%s救援 x%d",
            parts[0] != '\0' ? "、" : "", rescueCount);
        StrCat(parts, sizeof(parts), tmp);
    }

    if (parts[0] != '\0')
        PrintToChat(client, "\x04[得分]\x01 连杀结算：%s、\x03+%d分\x01", parts, total);
    else
        PrintToChat(client, "\x04[得分]\x01 连杀结算：\x03+%d分\x01", total);
}

void PlayStreakSound(int client, const char[] sound)
{
    float vol = g_cvStreakVol.FloatValue;
    if (vol <= 0.0)
        return;

    // v1.7.1 FIX: full path (with .mp3) — bare names resolve to .wav only.
    // v1.7.49 SPATIAL TEST: SOUND_FROM_PLAYER (non-spatialized) → entity=client
    // (spatialized). Engine sounds that players hear as LOUD (e.g. the incap
    // thud) are spatialized from entities — non-spatialized UI sounds suffer a
    // fixed attenuation. Listener = source (distance 0) → attenuation ≈ 1.0.
    // Volume stays ≤ 1.0: engine handles >1.0 unpredictably (实测, user-confirmed).
    EmitSoundToClient(client, sound, client, SNDCHAN_AUTO,
        SNDLEVEL_NORMAL, SND_NOFLAGS, vol);
}

void KillStreakTimer(int client)
{
    if (g_hStreakTimer[client] != null)
    {
        KillTimer(g_hStreakTimer[client]);
        g_hStreakTimer[client] = null;
    }
}

// ============================================================================
// Sound helpers
// ============================================================================

void PrecacheCvarSound(ConVar cv)
{
    char path[PLATFORM_MAX_PATH];
    cv.GetString(path, sizeof(path));
    if (path[0] == '\0')
        return;

    // v1.7.1 FIX: keep the FULL file name (with .mp3). The engine does NOT
    // resolve a bare name to an mp3 — it looks for the .wav only, so stripping
    // the extension silently failed precache (and playback). Verified working
    // path (bf_killfeedback v4.2.0): PrecacheSound with the full path.
    char dl[PLATFORM_MAX_PATH];
    Format(dl, sizeof(dl), "sound/%s", path);
    AddFileToDownloadsTable(dl);

    if (PrecacheSound(path, true))
        LogMessage("[SI HUD] Precached: %s", path);
    else
        LogError("[SI HUD] FAILED to precache: %s — check file exists in sound/", path);
}

bool SoundCooldownOK(int client)
{
    float now = GetGameTime();
    if (now - g_fLastKillSoundTime[client] < g_cvSoundCooldown.FloatValue)
        return false;
    g_fLastKillSoundTime[client] = now;
    return true;
}

void PickSound(char[] buffer, int maxlen, ConVar primary, ConVar fallback)
{
    primary.GetString(buffer, maxlen);
    if (buffer[0] == '\0')
        fallback.GetString(buffer, maxlen);
}

void PlayClientSound(int client, const char[] sound)
{
    if (sound[0] == '\0')
        return;

    float vol = g_cvSoundVolume.FloatValue;
    if (vol <= 0.0)
        return;

    // v1.7.1 FIX: full path (with .mp3) — bare names resolve to .wav only.
    // v1.7.49: SOUND_FROM_PLAYER → entity=client (spatialized, same as
    // PlayStreakSound — non-spatialized UI sounds attenuate).
    EmitSoundToClient(client, sound, client, SNDCHAN_AUTO,
        SNDLEVEL_NORMAL, SND_NOFLAGS, vol >= 1.0 ? 1.0 : vol);
}

// ============================================================================
// SI name lookup (by m_zombieClass)
// ============================================================================

// v1.7.52 (user): 基础分 = 特感实际最大血量 × si_hud_bf_points_base_pct (25%),
// 向上取整；Tank/Witch 固定（1500/500，大头在伤害分）。血量实时读
// m_iMaxHealth——服务器调过特感血量（[[l4d2-si-health]] 配置）则按调后算。
int PointsForSI(int victim)
{
    int zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zombieClass == 8)              // Tank
        return g_cvBFPointsTank.IntValue;
    if (zombieClass == 7)              // Witch
        return g_cvBFPointsWitch.IntValue;
    int maxHP = GetEntProp(victim, Prop_Data, "m_iMaxHealth");
    if (maxHP <= 0)
        maxHP = 100;                   // 读不到防御值
    return RoundToCeil(maxHP * g_cvBFPointsBasePct.FloatValue / 100.0);
}

void GetSIName(int client, char[] buffer, int maxlen)
{
    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    switch (zombieClass)
    {
        case 1:  strcopy(buffer, maxlen, "SMOKER  烟鬼");
        case 2:  strcopy(buffer, maxlen, "BOOMER  胖子");
        case 3:  strcopy(buffer, maxlen, "HUNTER  猎人");
        case 4:  strcopy(buffer, maxlen, "SPITTER 口水");
        case 5:  strcopy(buffer, maxlen, "JOCKEY  猴子");
        case 6:  strcopy(buffer, maxlen, "CHARGER 牛");
        case 7:  strcopy(buffer, maxlen, "WITCH  女巫");
        case 8:  strcopy(buffer, maxlen, "TANK  坦克");
        default: strcopy(buffer, maxlen, "特感");
    }
}

// ============================================================================
// Weapon display name
// ============================================================================

void GetWeaponDisplayName(const char[] weapon, char[] buffer, int maxlen)
{
    if (StrEqual(weapon, "pistol"))              { strcopy(buffer, maxlen, "手枪");     return; }
    if (StrEqual(weapon, "dual_pistols"))        { strcopy(buffer, maxlen, "手枪");     return; }
    if (StrEqual(weapon, "pistol_magnum"))       { strcopy(buffer, maxlen, "马格南");   return; }
    if (StrEqual(weapon, "smg"))                 { strcopy(buffer, maxlen, "UZI");      return; }
    if (StrEqual(weapon, "smg_silenced"))        { strcopy(buffer, maxlen, "MAC-10");   return; }
    if (StrEqual(weapon, "smg_mp5"))             { strcopy(buffer, maxlen, "MP5");      return; }
    if (StrEqual(weapon, "pumpshotgun"))         { strcopy(buffer, maxlen, "木喷");     return; }
    if (StrEqual(weapon, "shotgun_chrome"))      { strcopy(buffer, maxlen, "铁喷");     return; }
    if (StrEqual(weapon, "autoshotgun"))         { strcopy(buffer, maxlen, "M1014");    return; }
    if (StrEqual(weapon, "shotgun_spas"))        { strcopy(buffer, maxlen, "SPAS");     return; }
    if (StrEqual(weapon, "rifle"))               { strcopy(buffer, maxlen, "M16");      return; }
    if (StrEqual(weapon, "rifle_sg552"))         { strcopy(buffer, maxlen, "SG552");    return; }
    if (StrEqual(weapon, "rifle_desert"))        { strcopy(buffer, maxlen, "SCAR");     return; }
    if (StrEqual(weapon, "rifle_ak47"))          { strcopy(buffer, maxlen, "AK47");     return; }
    if (StrEqual(weapon, "hunting_rifle"))       { strcopy(buffer, maxlen, "猎枪");     return; }
    if (StrEqual(weapon, "sniper_military"))     { strcopy(buffer, maxlen, "军狙");     return; }
    if (StrEqual(weapon, "sniper_awp"))          { strcopy(buffer, maxlen, "AWP");      return; }
    if (StrEqual(weapon, "sniper_scout"))        { strcopy(buffer, maxlen, "SCOUT");    return; }
    if (StrEqual(weapon, "melee"))               { strcopy(buffer, maxlen, "近战");     return; }
    if (StrEqual(weapon, "chainsaw"))            { strcopy(buffer, maxlen, "电锯");     return; }
    if (StrEqual(weapon, "pipe_bomb"))           { strcopy(buffer, maxlen, "土制");     return; }
    if (StrEqual(weapon, "molotov"))             { strcopy(buffer, maxlen, "燃烧瓶");   return; }
    if (StrEqual(weapon, "vomitjar"))            { strcopy(buffer, maxlen, "胆汁");     return; }
    if (StrEqual(weapon, "grenade_launcher"))    { strcopy(buffer, maxlen, "榴弹");     return; }
    // v1.7.50: 引擎对 GL 击杀事件报 WeaponType 值 "grenadelauncher"（无下划线，
    // 见 left4dhooks g_sWeaponTypes[WEAPONTYPE_GRENADELAUNCHER]），不是 classname
    // 后缀 "grenade_launcher" —— 缺这条击杀卡一直 fallback 显示英文。
    if (StrEqual(weapon, "grenadelauncher"))     { strcopy(buffer, maxlen, "榴弹");     return; }
    if (StrEqual(weapon, "prop_minigun"))        { strcopy(buffer, maxlen, "固定机枪"); return; }
    if (StrEqual(weapon, "prop_mounted_machine_gun")) { strcopy(buffer, maxlen, "固定机枪"); return; }
    if (StrEqual(weapon, "rifle_m60"))           { strcopy(buffer, maxlen, "M60");      return; }
    if (StrEqual(weapon, "inferno")
     || StrEqual(weapon, "entityflame"))          { strcopy(buffer, maxlen, "火焰");     return; }
    strcopy(buffer, maxlen, weapon);
}

// ============================================================================
// Entity type checks
// ============================================================================

/** Returns 1=Tank, 2=Witch, 0=other SI */
int IsTankOrWitch(int client)
{
    int zombieClass = GetEntProp(client, Prop_Send, "m_zombieClass");
    if (zombieClass == 8) return 1;
    if (zombieClass == 7) return 2;
    return 0;
}

bool IsWitchEntity(int entity)
{
    if (entity <= 0 || !IsValidEntity(entity))
        return false;
    char cls[32];
    GetEntityClassname(entity, cls, sizeof(cls));
    return (StrContains(cls, "witch") != -1);
}

bool IsMeleeWeapon(const char[] weapon)
{
    return StrEqual(weapon, "melee") || StrEqual(weapon, "chainsaw");
}

// ============================================================================
// Center text hide timer — clears PrintCenterText (HP display & kill confirm)
// ============================================================================

Action Timer_HideHP(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    g_hHPHideTimer[client] = null;
    if (client > 0 && IsClientInGame(client))
        PrintCenterText(client, " ");
    return Plugin_Stop;
}

void KillHPHideTimer(int client)
{
    if (g_hHPHideTimer[client] != null)
    {
        KillTimer(g_hHPHideTimer[client]);
        g_hHPHideTimer[client] = null;
    }
}

// ============================================================================
// v1.7.27: score shop — !shop / !buy
// 消费"当前积分"(g_iWallet) 兑换补给/武器；每图限购（OnMapEnd 清零）；
// 价格/限购在 g_ShopTable（编译期）。历史积分(g_iTotalScore) 只显示不消费。
// 分工：掉落（loot_drop v1.7.0）出小件 + Tank 必掉武器；商店补确定性购买。
// ============================================================================

public bool ShopTraceFilter(int entity, int contentsMask, any data)
{
    return entity != data;
}

// v1.7.93: 可爆炸类 classname → prop_physics 模型映射（返回 true = 可爆炸类）
bool Art_ExplosiveModel(const char[] cls, char[] model, int maxlen)
{
    if (StrEqual(cls, "weapon_propanetank"))
        strcopy(model, maxlen, "models/props_junk/propanecanister001a.mdl");
    else if (StrEqual(cls, "weapon_oxygentank"))
        strcopy(model, maxlen, "models/props_equipment/oxygentank01.mdl");
    else if (StrEqual(cls, "weapon_gascan"))
        strcopy(model, maxlen, "models/props_junk/gascan001a.mdl");
    else if (StrEqual(cls, "weapon_fireworkcrate"))
        strcopy(model, maxlen, "models/props_junk/explosive_box001.mdl");
    else
        return false;
    return true;
}

// spawn 单个商品（trace 落地面 + glow + 重武器弹药）
int ShopSpawn(const char[] cls, float pos[3])
{
    // v1.7.93: 可爆炸类商品（罐/桶/烟花）直接生成 prop_physics + 对应模型
    // （= 地图罐子等价物，可捡可扔可炸）：死亡/点燃过热 → 引擎爆炸。
    // weapon_* 类名不可 break/ignite/explode（v1.7.92 give+drop 转换依赖
    // 槽位/拾取竞态，弃用——见 Timer_ArtSpawnCan v1.7.93 注释）。
    char model[PLATFORM_MAX_PATH];
    bool explosive = Art_ExplosiveModel(cls, model, sizeof(model));

    int ent;
    if (explosive)
    {
        ent = CreateEntityByName("prop_physics");
        if (ent != -1)
            DispatchKeyValue(ent, "model", model);
    }
    else
    {
        ent = CreateEntityByName(cls);
    }
    if (ent == -1) return -1;

    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    Handle tr = TR_TraceRayFilterEx(from, view_as<float>({ 90.0, 0.0, 0.0 }),
        MASK_SOLID, RayType_Infinite, ShopTraceFilter, ent);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(to, tr);
        to[2] += 5.0;
    }
    else
    {
        to = from;
    }
    delete tr;

    DispatchSpawn(ent);
    TeleportEntity(ent, to, NULL_VECTOR, NULL_VECTOR);

    if (StrEqual(cls, "weapon_grenade_launcher"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 30);
    else if (StrEqual(cls, "weapon_rifle_m60"))
        SetEntProp(ent, Prop_Send, "m_iExtraPrimaryAmmo", 150);

    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24));

    // v1.7.93: 可爆炸类商品（瓦斯罐/煤气罐/汽油桶/烟花）——prop_physics 罐子
    // 强制可破坏（正血量），枪直接打爆走引擎死亡爆炸（原版音效/伤害/友伤缩放）。
    // 普通武器（M60/电锯等）不可破坏，不在此列。
    if (explosive)
    {
        SetEntProp(ent, Prop_Data, "m_takedamage", 2);
        SetEntProp(ent, Prop_Data, "m_iHealth", 100);
    }

    return ent;
}

// v1.7.72: 近战盲盒——生成指定近战武器（melee_script_name keyvalue 必须
// 在 DispatchSpawn 前；trace 落地面 + glow 与 ShopSpawn 一致）
int SpawnMelee(const char[] meleeName, float pos[3])
{
    int ent = CreateEntityByName("weapon_melee");
    if (ent == -1)
        return -1;

    // v1.7.77 FIX: 只用 melee_script_name keyvalue（v1.7.76 加的双保险
    // SetEntPropString m_MeleeWeaponName 在 spawn 前不存在该 prop →
    // 抛异常：不生成 + 购买后菜单不重开，日志实锤 "Property not found"）
    DispatchKeyValue(ent, "melee_script_name", meleeName);
    LogMessage("[melee-box] spawn melee=%s ent=%d", meleeName, ent);

    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    Handle tr = TR_TraceRayFilterEx(from, view_as<float>({ 90.0, 0.0, 0.0 }),
        MASK_SOLID, RayType_Infinite, ShopTraceFilter, ent);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(to, tr);
        to[2] += 5.0;
    }
    else
    {
        to = from;
    }
    delete tr;

    DispatchSpawn(ent);
    TeleportEntity(ent, to, NULL_VECTOR, NULL_VECTOR);

    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 800);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", 50 | (255 << 8) | (50 << 16) | (255 << 24));

    return ent;
}

void ShopBuy(int client, int slot)
{
    if (slot < 0 || slot >= SHOP_SLOTS) return;
    if (!IsClientInGame(client) || GetClientTeam(client) != 2) return;

    // DEBUG v1.7.43b: 全量购买日志（排障激光分支不执行）
    LogMessage("[shop-buy] client=%N slot=%d cls='%s' price=%d wallet=%d",
        client, slot, g_ShopTable[slot].classname, g_ShopTable[slot].price, g_iWallet[client]);

    int price = g_ShopTable[slot].price;
    if (g_iWallet[client] < price)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 需要 \x03%d\x01 当前积分，你只有 \x03%d\x01",
            g_ShopTable[slot].name, price, g_iWallet[client]);
        return;
    }
    if (g_ShopTable[slot].limit > 0
        && g_iShopBought[client][slot] >= g_ShopTable[slot].limit)
    {
        PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 本图已购满（%d/%d）",
            g_ShopTable[slot].name, g_iShopBought[client][slot], g_ShopTable[slot].limit);
        return;
    }

    // 复活币持有上限检查（必须在扣款前——v1.7.31b fix：原来在扣款后，
    // 达上限购买会扣分不给币）
    if (g_ShopTable[slot].classname[0] == '\0'
        && g_iReviveCoins[client] >= g_cvRespawnCoinMax.IntValue)
    {
        PrintToChat(client, "\x04[商店]\x01 复活币已达持有上限 \x03%d\x01 枚，无法再购买",
            g_cvRespawnCoinMax.IntValue);
        return;
    }

    // v1.7.69: 透视特感——生效期间可续费，累计上限 15 分钟（900 秒）
    if (StrEqual(g_ShopTable[slot].classname, "wallhack") && g_bWallhack[client])
    {
        float now = GetGameTime();
        if (g_fWallhackEnd[client] - now >= WALLHACK_CAP)
        {
            PrintToChat(client, "\x04[商店]\x01 特感透视已达上限 \x0315 分钟\x01（900 秒），无法继续续费");
            return;
        }
    }

    // v1.7.78: 激光——主武器已有激光 → 拦截（扣款前检查；用户实测重复购买
    // 会白扣款）
    if (StrEqual(g_ShopTable[slot].classname, "weapon_upgradepack_laser_sight"))
    {
        int weapon = GetPlayerWeaponSlot(client, 0);
        if (weapon > 0 && IsValidEntity(weapon))
        {
            int upgrade = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
            if (upgrade & 4)   // 位值 4 = 激光（1=燃烧弹 2=高爆弹 4=激光）
            {
                PrintToChat(client, "\x04[商店]\x01 你的主武器已装备激光，无需重复购买");
                return;
            }
        }
    }

    g_iWallet[client] -= price;
    g_iShopBought[client][slot]++;

    // 复活币（classname 空）：不 spawn 物品，余额 +1 枚（战役内保留）
    if (g_ShopTable[slot].classname[0] == '\0')
    {
        g_iReviveCoins[client]++;
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05复活币\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），复活币余额 \x03%d\x01 枚",
            price, g_iWallet[client], g_iReviveCoins[client]);
        return;
    }

    // v1.7.49: 激光直接上主武器——L4D2 激光 = 武器升级位 m_upgradeBitVec
    // （netprops dump 实锤 offset 6116, networked）。位值：1=燃烧弹 2=高爆弹 4=激光。
    // 排障链（2026-08-02）：SetEntProp m_bHasLaserSight 无此 prop / upgrade_laser_sight
    // 脚下 spawn 被用户否决（激光堆拾取物）/ SDKCall SetHasLaserSight 是 CS:GO 符号不存在。
    if (StrEqual(g_ShopTable[slot].classname, "weapon_upgradepack_laser_sight"))
    {
        int weapon = GetPlayerWeaponSlot(client, 0);
        if (weapon <= 0 || !IsValidEntity(weapon))
        {
            // 无主武器（异常）——退款
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 购买失败（未持有武器），积分已退回");
            return;
        }

        int upgrade = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
        SetEntProp(weapon, Prop_Send, "m_upgradeBitVec", upgrade | 4);
        LogMessage("[shop-laser] m_upgradeBitVec %d -> %d weapon=%d client=%N",
            upgrade, upgrade | 4, weapon, client);
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05激光瞄准\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），激光已装备到当前主武器",
            price, g_iWallet[client]);
        return;
    }

    // v1.7.64: 透视特感——不 spawn 物品，直接激活购买者视角（5 分钟）
    if (StrEqual(g_ShopTable[slot].classname, "wallhack"))
    {
        WallhackStart(client, price);
        return;
    }

    // v1.7.72: 近战盲盒——随机掉落一把非电锯近战武器
    if (StrEqual(g_ShopTable[slot].classname, "melee_box"))
    {
        char picked[32];
        strcopy(picked, sizeof(picked), g_MeleePool[GetRandomInt(0, MELEE_POOL_COUNT - 1)]);

        float pos[3], ang[3], fwd[3];
        GetClientEyePosition(client, pos);
        GetClientEyeAngles(client, ang);
        GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
        pos[0] += fwd[0] * 70.0;
        pos[1] += fwd[1] * 70.0;
        pos[2] -= 20.0;

        int ent = SpawnMelee(picked, pos);
        if (ent <= 0)
        {
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 近战盲盒生成失败，积分已退回");
            return;
        }
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05近战盲盒\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01）：开出 \x05%s\x01",
            price, g_iWallet[client], picked);
        return;
    }

    // v1.7.80: 火炮支援1——进入瞄准指示（服务器马格南设计器，射击确认轰炸）。
    // 不 spawn 实体；扣款已在上游完成，取消/超时/死亡/断线由 ArtEndDesignate 退款。
    if (StrEqual(g_ShopTable[slot].classname, "artillery"))
    {
        // v1.7.82: 倒地/死亡状态拦截（用户边界审查）——倒地/死亡无法开火确认，
        // 买了也立即被心跳退款，直接拒绝更清晰
        if (!IsPlayerAlive(client))
        {
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 倒地/死亡状态无法使用\x05火炮支援1\x01，积分已退回");
            return;
        }
        // v1.7.80: 全局硬冷却——轰炸中/结束后 si_hud_art_cooldown 秒内全体禁止购买（用户拍板）
        float wait = g_fArtNextBuyTime - GetGameTime();
        if (!g_cvArtEnable.BoolValue || wait > 0.0)
        {
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            if (wait > 0.0)
                PrintToChat(client, "\x04[商店]\x01 \x05火炮支援1\x01 冷却中，\x03%d\x01 秒后可购买",
                    RoundToCeil(wait));
            else
                PrintToChat(client, "\x04[商店]\x01 \x05火炮支援1\x01 不可用，积分已退回");
            return;
        }
        if (g_bArtAiming[client])
        {
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            PrintToChat(client, "\x04[商店]\x01 你已在瞄准中，请先确认或取消（右键）");
            return;
        }
        ArtStartDesignate(client, slot, price);
        return;
    }

    // v1.7.93: 外部插件商品（classname 以 "ext_" 开头，如 ext_artillery2）——
    // Fire 全局 forward SH_OnShopItemBuy，由外部插件接管（扣款已在上游完成）。
    // 返回值约定: Plugin_Handled = 接管成功（外部插件自行后续退款）;
    // Plugin_Stop = 外部插件拒绝且已自行提示（静默退款）;
    // Plugin_Continue = 拒绝/未安装（退款 + 通用不可用提示）。
    if (StrContains(g_ShopTable[slot].classname, "ext_") == 0)
    {
        Action ret = Plugin_Continue;
        if (g_hShopBuyForward != null)
        {
            Call_StartForward(g_hShopBuyForward);
            Call_PushCell(client);
            Call_PushCell(slot);
            Call_PushString(g_ShopTable[slot].classname);
            Call_PushCell(price);
            Call_Finish(ret);
        }
        if (ret != Plugin_Handled)
        {
            g_iWallet[client] += price;
            g_iShopBought[client][slot]--;
            if (ret != Plugin_Stop)
                PrintToChat(client, "\x04[商店]\x01 \x05%s\x01 当前不可用，积分已退回",
                    g_ShopTable[slot].name);
        }
        return;
    }

    // 落点：玩家面前 70 单位（购买时刻的方向）
    float pos[3], ang[3], fwd[3];
    GetClientEyePosition(client, pos);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    pos[0] += fwd[0] * 70.0;
    pos[1] += fwd[1] * 70.0;
    pos[2] -= 20.0;

    ShopSpawn(g_ShopTable[slot].classname, pos);   // v1.7.93: 可爆炸类商品直接生成 prop_physics

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05%s\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），物品已放在你面前",
        g_ShopTable[slot].name, price, g_iWallet[client]);
}

// v1.7.64: 商店菜单分类（武器/道具/医疗/其他）——分类菜单 → 商品菜单；
// 再输入一次 !buy/!shop → 关闭当前菜单（用户需求）
int    g_iShopCat[MAXPLAYERS + 1];    // 当前打开的商品分类（购买后重开同分类刷新）

void OpenShopMenu(int client)
{
    Menu menu = new Menu(ShopCatMenuHandler);
    // v1.7.32c FIX: title 必须单行 — L4D2 VguiMenu 标题不支持 \n，
    // 多行标题 → 整个菜单不渲染（用户实测 !buy 无反应，!csm 的 Panel 单行正常）
    menu.SetTitle("商店: 可用积分 %d  复活币 %d 枚",
        g_iWallet[client], g_iReviveCoins[client]);
    menu.AddItem("0", "武器类");
    menu.AddItem("1", "道具类");
    menu.AddItem("2", "医疗类");
    menu.AddItem("3", "其他");
    menu.ExitButton = true;
    g_hShopMenu[client] = menu;
    menu.Display(client, 20);
}

void ShopCategoryMenu(int client, int cat)
{
    if (cat < 0 || cat > 3) cat = 3;
    g_iShopCat[client] = cat;
    char catNames[4][16] = { "武器类", "道具类", "医疗类", "其他" };
    Menu menu = new Menu(ShopItemMenuHandler);
    char title[96];
    Format(title, sizeof(title), "%s: 可用积分 %d  复活币 %d 枚",
        catNames[cat], g_iWallet[client], g_iReviveCoins[client]);
    menu.SetTitle(title);

    char info[4];
    char line[96];
    for (int i = 0; i < SHOP_SLOTS; i++)
    {
        if (g_ShopTable[i].cat != cat)
            continue;
        int price = g_ShopTable[i].price;
        int limit = g_ShopTable[i].limit;
        if (i == WALLHACK_SLOT && g_bWallhack[client])
        {
            Format(line, sizeof(line), "%s (%d分) [透视生效中·可续费]", g_ShopTable[i].name, price);
        }
        else if (limit <= 0)
        {
            if (g_iWallet[client] < price)
                Format(line, sizeof(line), "%s (%d分) [积分不足]", g_ShopTable[i].name, price);
            else
                Format(line, sizeof(line), "%s (%d分) [无限购]", g_ShopTable[i].name, price);
        }
        else
        {
            int left = limit - g_iShopBought[client][i];
            if (left <= 0)
                Format(line, sizeof(line), "%s (%d分) [已购满]", g_ShopTable[i].name, price);
            else if (g_iWallet[client] < price)
                Format(line, sizeof(line), "%s (%d分) [积分不足]", g_ShopTable[i].name, price);
            else
                Format(line, sizeof(line), "%s (%d分) [可购 x%d]", g_ShopTable[i].name, price, left);
        }

        if (i == ARTILLERY_SLOT && g_iWallet[client] >= price)   // v1.7.80: 火炮提示使用方式
            Format(line, sizeof(line), "%s ·马格南射击轰炸", line);
        else if (i == ARTILLERY2_SLOT && g_iWallet[client] >= price)   // v1.7.93: 榴弹雨提示使用方式
            Format(line, sizeof(line), "%s ·马格南射击轰炸", line);

        IntToString(i, info, sizeof(info));
        menu.AddItem(info, line);
    }
    // v1.7.75: 用 SM 原生按钮——ExitBackButton=8 返回上一页（社区插件同款，
    // 见 survivor_chat_select.sp 注释"显示数字8返回上一页选项"），ExitButton
    // 退出。原生按钮不占商品槽位 → 位置恒定 8/9 且无填充空行
    // （v1.7.73 自定义项位置漂移；v1.7.74 空白占位渲染出空行，均废弃）
    menu.ExitBackButton = true;
    menu.ExitButton = true;
    g_hShopMenu[client] = menu;
    menu.Display(client, 20);
}

public int ShopCatMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    // CancelMenu 触发的回调 client/item 是 -3（取消标记）——必须挡在 GetItem 前，
    // 否则数组越界崩溃（用户实测 !buy 关不掉菜单，日志 index -3 实锤）
    if (action == MenuAction_Select && item >= 0 && client >= 1)
    {
        char info[4];
        menu.GetItem(item, info, sizeof(info));
        ShopCategoryMenu(client, StringToInt(info));
    }
    else if (action == MenuAction_Cancel || action == MenuAction_End)
    {
        if (client >= 1 && g_hShopMenu[client] == menu)   // 只清自己（旧菜单 End 不覆盖新菜单句柄）
            g_hShopMenu[client] = null;
        if (action == MenuAction_End)   // 只删一次（Cancel 后必跟 End）
            delete menu;
    }
    return 0;
}

public int ShopItemMenuHandler(Menu menu, MenuAction action, int client, int item)
{
    // CancelMenu 触发回调时 client/item 是 -3——同上防护
    if (action == MenuAction_Select && item >= 0 && client >= 1)
    {
        char info[8];
        menu.GetItem(item, info, sizeof(info));
        ShopBuy(client, StringToInt(info));
        if (IsClientInGame(client) && !g_bArtAiming[client])   // v1.7.80: 火炮瞄准中不重开菜单（避免遮挡瞄准视野）
            ShopCategoryMenu(client, g_iShopCat[client]);   // 刷新余额/状态（留在当前分类）
    }
    else if (action == MenuAction_Cancel || action == MenuAction_End)
    {
        // v1.7.75: 原生 8=返回上一页（MenuCancel_ExitBack）——重开分类页
        if (action == MenuAction_Cancel && item == MenuCancel_ExitBack && client >= 1)
        {
            OpenShopMenu(client);
            return 0;
        }
        if (client >= 1 && g_hShopMenu[client] == menu)   // 只清自己（旧菜单 End 不覆盖新菜单句柄）
            g_hShopMenu[client] = null;
        if (action == MenuAction_End)   // 只删一次（Cancel 后必跟 End）
            delete menu;
    }
    return 0;
}

public Action Cmd_Shop(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;
    // v1.7.77: 关闭方式定稿——数字 9 关闭键（原生 ExitButton，与其他服务器
    // 一致）+ 20s 超时自动关。!buy 二次输入关不掉面板（L4D2 vgui 实测），
    // 废弃"二次输入关闭"（原 CancelClientMenu 方案），重复输入只重开菜单
    if (!g_cvEnable.BoolValue || !g_cvShopEnable.BoolValue)
    {
        PrintToChat(client, "\x04[商店]\x01 商店未开启");
        return Plugin_Handled;
    }
    if (GetClientTeam(client) != 2)
    {
        PrintToChat(client, "\x04[商店]\x01 只有幸存者可以使用商店");
        return Plugin_Handled;
    }
    OpenShopMenu(client);
    return Plugin_Handled;
}

// ============================================================================
// v1.7.67: 透视特感（!shop 特殊商品）——全局蓝色高亮（用户定稿 2026-08-02）
// 直接给特感实体加发光（与商店物品同机制 m_iGlowType 3 + 颜色）——轮廓完美
// 贴合动作。克隆方案已废弃（prop 不播特感动画 → 冻结人偶轮廓，用户否决）。
// 全队可见（co-op 团队增益）；任一购买者生效 → 全部特感蓝色；最后一位结束
// → 清光。价格 6000 / 3 分钟（用户定稿）。
// ============================================================================

void WallhackStart(int client, int price)
{
    // v1.7.69: 续费逻辑——已有剩余时长 + 180s，封顶 WALLHACK_CAP（900s）
    bool renew = g_bWallhack[client];
    float now = GetGameTime();
    float remaining = (renew && g_fWallhackEnd[client] > now) ? g_fWallhackEnd[client] - now : 0.0;
    float total = remaining + WALLHACK_DURATION;
    if (total > WALLHACK_CAP)
        total = WALLHACK_CAP;

    g_bWallhack[client] = true;
    g_fWallhackEnd[client] = now + total;

    // 重启到期计时器（续费时旧计时器作废重排）
    if (g_hWallhackTimer[client] != null)
    {
        KillTimer(g_hWallhackTimer[client]);
        g_hWallhackTimer[client] = null;
    }
    g_hWallhackTimer[client] = CreateTimer(total, Timer_WallhackExpire,
        GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    // v1.7.68: 结束前 30 秒提醒（一次性；剩余不足 30s 不排）
    if (g_hWallhackWarnTimer[client] != null)
    {
        KillTimer(g_hWallhackWarnTimer[client]);
        g_hWallhackWarnTimer[client] = null;
    }
    if (total > 30.0)
        g_hWallhackWarnTimer[client] = CreateTimer(total - 30.0, Timer_WallhackWarn,
            GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);

    if (g_hWallhackSyncTimer == null)
        g_hWallhackSyncTimer = CreateTimer(0.5, Timer_WallhackSync, INVALID_HANDLE, TIMER_REPEAT);

    LogMessage("[wallhack] %s client=%N wallet=%d total=%.0fs", renew ? "renew" : "start",
        client, g_iWallet[client], total);
    int secs = RoundToNearest(total);
    if (renew)
    {
        PrintToChat(client, "\x04[商店]\x01 已续费 \x05透视特感\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01），剩余生效时长：\x03%d\x01 秒",
            price, g_iWallet[client], secs);
    }
    else
    {
        PrintToChat(client, "\x04[商店]\x01 已购买 \x05透视特感\x01（-\x03%d\x01 可用积分，剩余 \x03%d\x01）：特感蓝色高亮生效，剩余生效时长：\x03%d\x01 秒（全队可见；死亡/切图/重开/闲置后失效）",
            price, g_iWallet[client], secs);
    }
    // v1.7.68: 全服播报购买/续费（y 键聊天可见）
    PrintToChatAll("\x04[商店]\x01 \x05%N\x01 购买了特感透视，剩余生效时长：\x03%d\x01 秒",
        client, secs);
    WallhackApplyGlow();   // 立即上光（不等首 tick）
}

// 给当前所有特感/Witch 上蓝色发光（幂等——新刷新的特感由心跳计时器自动补光）
void WallhackApplyGlow()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != 3)
            continue;
        SetEntProp(i, Prop_Send, "m_iGlowType", 3);
        SetEntProp(i, Prop_Send, "m_nGlowRange", 999999);
        SetEntProp(i, Prop_Send, "m_nGlowRangeMin", 0);
        SetEntProp(i, Prop_Send, "m_glowColorOverride", 0 | (0 << 8) | (255 << 16) | (255 << 24));  // 蓝
    }
    for (int i = 0; i < g_hWitchList.Length; i++)
    {
        int w = g_hWitchList.Get(i);
        if (!IsValidEntity(w) || !IsWitchEntity(w))
        {
            g_hWitchList.Erase(i--);
            continue;
        }
        SetEntProp(w, Prop_Send, "m_iGlowType", 3);
        SetEntProp(w, Prop_Send, "m_nGlowRange", 999999);
        SetEntProp(w, Prop_Send, "m_nGlowRangeMin", 0);
        SetEntProp(w, Prop_Send, "m_glowColorOverride", 0 | (0 << 8) | (255 << 16) | (255 << 24));  // 蓝
    }
}

void WallhackClearGlow()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != 3)
            continue;
        SetEntProp(i, Prop_Send, "m_iGlowType", 0);
    }
    for (int i = 0; i < g_hWitchList.Length; i++)
    {
        int w = g_hWitchList.Get(i);
        if (IsValidEntity(w) && IsWitchEntity(w))
            SetEntProp(w, Prop_Send, "m_iGlowType", 0);
    }
}

void WallhackEnd(int client, bool silent = false)
{
    g_bWallhack[client] = false;
    g_fWallhackEnd[client] = 0.0;   // v1.7.69: 累计清零
    if (g_hWallhackTimer[client] != null)
    {
        KillTimer(g_hWallhackTimer[client]);
        g_hWallhackTimer[client] = null;
    }
    if (g_hWallhackWarnTimer[client] != null)
    {
        KillTimer(g_hWallhackWarnTimer[client]);
        g_hWallhackWarnTimer[client] = null;
    }
    LogMessage("[wallhack] end client=%N silent=%d", client, silent ? 1 : 0);
    // 若已无任何购买者 → 立即清光（不等心跳下 tick）
    bool any = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bWallhack[i])
        {
            any = true;
            break;
        }
    }
    if (!any)
        WallhackClearGlow();
    if (!silent && IsClientInGame(client))
        PrintToChat(client, "\x04[商店]\x01 透视特感效果已结束");
}

void WallhackEndAll()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_bWallhack[i])
            WallhackEnd(i, true);
    }
}

// 0.5s 心跳：有购买者 → 补光新刷新的特感/Witch；无购买者 → 清光停表
Action Timer_WallhackSync(Handle timer)
{
    bool any = false;
    for (int b = 1; b <= MaxClients; b++)
    {
        if (g_bWallhack[b])
        {
            any = true;
            break;
        }
    }
    if (!any)
    {
        WallhackClearGlow();   // 最后一位失效时清光
        g_hWallhackSyncTimer = null;
        return Plugin_Stop;
    }
    WallhackApplyGlow();
    return Plugin_Continue;
}

Action Timer_WallhackExpire(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client >= 1 && client <= MaxClients)
    {
        g_hWallhackTimer[client] = null;   // 先置空，避免 WallhackEnd 自杀计时器
        WallhackEnd(client);
    }
    return Plugin_Continue;
}

// v1.7.68: 结束前 30 秒全服提醒（y 键聊天可见）
Action Timer_WallhackWarn(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client >= 1 && client <= MaxClients && g_bWallhack[client])
    {
        g_hWallhackWarnTimer[client] = null;   // 一次性——先置空防 WallhackEnd 杀已关句柄
        PrintToChatAll("\x04[商店]\x01 特感透视剩余 \x0330\x01 秒");
    }
    return Plugin_Continue;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client))
        return Plugin_Continue;
    if (event.GetInt("team") != 2 && g_bWallhack[client])   // 闲置/旁观/换队 → 透视失效
        WallhackEnd(client);
    return Plugin_Continue;
}

public Action Cmd_LaserTest(int client, int args)
{
    if (client < 1 || !IsClientInGame(client))
        return Plugin_Handled;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon > 0 && IsValidEntity(weapon))
    {
        SetEntProp(weapon, Prop_Send, "m_bHasLaserSight", 1);
        int back = GetEntProp(weapon, Prop_Send, "m_bHasLaserSight");
        char cls[64];
        GetEntityClassname(weapon, cls, sizeof(cls));
        LogMessage("[laser-test] weapon=%d cls=%s readback=%d", weapon, cls, back);
        PrintToChat(client, "\x04[laser-test]\x01 weapon=%d %s readback=%d", weapon, cls, back);
    }
    else
    {
        PrintToChat(client, "\x04[laser-test]\x01 无武器");
    }
    return Plugin_Handled;
}

// ============================================================================
// v1.7.28: 复活系统（移植 l4d2_auto_respawn，限次数 + 复活币）
// 每图初始 g_cvRespawnBase 次（=base+1 条命）；次数用完消耗复活币；
// 都没有 → 躺尸（电击器回归价值）。复活延迟 g_cvRespawnDelay（15s）。
// ============================================================================

void ScheduleRespawn(int client, bool hasCount)
{
    KillRespawnTimer(client);
    int userid = GetClientUserId(client);
    float delay = g_cvRespawnDelay.FloatValue;
    // v1.7.31b fix: NO_MAPCHANGE — 换图时引擎清普通 timer 会留下悬挂句柄
    // 和 DataPack 泄漏；标记后跨图继续，回调里 IsClientInGame/IsPlayerAlive 兜底
    g_hRespawnTimer[client] = CreateTimer(delay, Timer_Respawn, userid, TIMER_FLAG_NO_MAPCHANGE);

    if (hasCount)
        PrintToChat(client, "\x04[复活]\x01 你已死亡（本图剩余复活 \x03%d\x01 次），将在 \x03%.0f 秒\x01 后自动复活",
            g_iRevivesLeft[client], delay);
    else
        PrintToChat(client, "\x04[复活]\x01 你已死亡（复活币复活），将在 \x03%.0f 秒\x01 后自动复活", delay);

    int thresholds[] = {10, 5, 3, 2, 1};
    for (int i = 0; i < sizeof(thresholds); i++)
    {
        if (delay > float(thresholds[i]))
        {
            DataPack dp = new DataPack();
            dp.WriteCell(userid);
            dp.WriteCell(thresholds[i]);
            CreateTimer(delay - float(thresholds[i]), Timer_RespawnCountdown, dp, TIMER_FLAG_NO_MAPCHANGE);
        }
    }
}

Action Timer_RespawnCountdown(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    int seconds = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || IsPlayerAlive(client))
        return Plugin_Continue;

    PrintHintText(client, "复活倒计时: %d 秒", seconds);
    if (seconds <= 10)
        PrintToChat(client, "\x04[复活]\x01 你将在 \x03%d 秒\x01 后复活", seconds);

    return Plugin_Continue;
}

Action Timer_Respawn(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client >= 1 && client <= MaxClients)
        g_hRespawnTimer[client] = null;
    if (client < 1 || !IsClientInGame(client) || GetClientTeam(client) != 2 || IsPlayerAlive(client))
        return Plugin_Continue;

    L4D_RespawnPlayer(client);
    CreateTimer(0.5, Timer_RespawnTeleport, userid);

    return Plugin_Continue;
}

Action Timer_RespawnTeleport(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Continue;

    // 传送到最近存活队友
    float origin[3];
    bool found = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i != client && IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i))
        {
            GetClientAbsOrigin(i, origin);
            found = true;
            break;
        }
    }

    if (found)
    {
        TeleportEntity(client, origin, NULL_VECTOR, NULL_VECTOR);
        PrintToChat(client, "\x04[复活]\x01 你已复活在队友身边!");
    }
    else
    {
        PrintToChat(client, "\x04[复活]\x01 你已复活!");
    }

    PrintHintText(client, "你已复活!");
    return Plugin_Continue;
}

void KillRespawnTimer(int client)
{
    if (client >= 1 && client <= MaxClients && g_hRespawnTimer[client] != null)
    {
        KillTimer(g_hRespawnTimer[client]);
        g_hRespawnTimer[client] = null;
    }
}

// ============================================================================
// v1.7.80: 火炮支援1（!shop 特殊商品「artillery」）——BFV 式目标指示轰炸
//
// 交互（BFV 召唤火炮复刻，用户拍板）：
//   购买 → 扣款 → 切到服务器马格南（副武器已是马格南则不动）→ 准星瞄准处
//   显示爆炸半径圆圈+光柱+光点（全队可见；天花板 <600 或瞄天空 → 变红无效）
//   → 马格南开火 = 确认轰炸（weapon_fire 事件判定，射击点被火炮覆盖）→
//   马格南立刻移除并恢复原副武器（激光升级位一并恢复）→ 右键 / 15s 超时 /
//   死亡 / 断线 → 取消退款。
// 轰炸：N 个着火的瓦斯罐(weapon_propanetank)/煤气罐(weapon_oxygentank) 从高空
//   坠落（70/30 混合；汽油桶排除——gascan 点火以燃烧为主爆炸不可靠），错峰
//   生成（si_hud_art_stagger）→ 落地时刻定时器强制引爆（attacker=购买者，
//   期望击杀分归购买者，不强求）→ 原版爆炸伤害（全伤害，含队友，受友伤规则）。
// 室内自适应：天花板 ≥900 → 吊顶下 150u 生成 6 罐/350 半径；600-900 → 3 罐/250；
//   <600 或瞄天空 → 无效（红圈，确认被拒，留在瞄准模式）。
// 天花板阈值 600/900/4096 与 70/30 罐型比例写死（行为规则，同价格写死哲学）。
// 全局状态/常量声明在 ConVar 区（ShopBuy/OnMapStart 提前引用）。
// ============================================================================

// 进入瞄准指示：切服务器马格南 + 启动心跳 + 创建标记
void ArtStartDesignate(int client, int slot, int price)
{
    g_iArtSlot[client] = slot;
    g_iArtPrice[client] = price;
    g_iArtMagnum[client] = 0;
    g_sArtPrevWeapon[client][0] = '\0';
    g_sArtPrevMelee[client][0] = '\0';
    g_iArtPrevUpgrade[client] = 0;
    g_iArtPrevClip[client] = -1;
    g_fArtAimEnd[client] = GetGameTime() + g_cvArtTargetTime.FloatValue;

    // 副武器处理：已是马格南 → 不动（用户拍板）；否则保存原武器 → 切服务器
    // 马格南（引擎播放武器拔出动画；原武器自动掉落 → 立即移除，恢复时按
    // classname 重给 + 补激光位，避免地面遗留双武器）
    // v1.7.81 FIX: 近战(weapon_melee)没有 m_upgradeBitVec 属性，GetEntProp 直接
    // 抛异常中断（日志实锤 17:07:24 "Property not found (entity 639/weapon_melee)"）
    // → 马格南未给 + g_bArtAiming 卡死。改为 HasEntProp 保护读属性。
    // v1.7.82: 升级位全量保存（不只激光位）+ 弹匣 m_iClip1 保存（恢复时补回）。
    int weapon = GetPlayerWeaponSlot(client, 1);
    if (weapon > 0 && IsValidEntity(weapon))
    {
        char cls[32];
        GetEntityClassname(weapon, cls, sizeof(cls));
        if (!StrEqual(cls, "weapon_pistol_magnum"))
        {
            g_sArtPrevMelee[client][0] = '\0';
            if (StrEqual(cls, "weapon_melee"))
                Art_SaveMeleeName(client, weapon);   // v1.7.89: 多属性名兜底（见实现区）
            if (HasEntProp(weapon, Prop_Send, "m_upgradeBitVec"))
                g_iArtPrevUpgrade[client] = GetEntProp(weapon, Prop_Send, "m_upgradeBitVec");
            if (HasEntProp(weapon, Prop_Send, "m_iClip1"))
                g_iArtPrevClip[client] = GetEntProp(weapon, Prop_Send, "m_iClip1");
            strcopy(g_sArtPrevWeapon[client], sizeof(g_sArtPrevWeapon[]), cls);
            int ref = EntIndexToEntRef(weapon);
            int newWep = GivePlayerItem(client, "weapon_pistol_magnum");
            int dropped = EntRefToEntIndex(ref);
            if (dropped > 0 && IsValidEntity(dropped))
                AcceptEntityInput(dropped, "Kill");
            if (newWep > 0)
                g_iArtMagnum[client] = EntIndexToEntRef(newWep);
            LogMessage("[artillery] start client=%N slot1=%s prevMelee='%s' upgrade=%d clip=%d magnum=%d",
                client, cls, g_sArtPrevMelee[client], g_iArtPrevUpgrade[client],
                g_iArtPrevClip[client], newWep);
        }
        else
        {
            // 已是马格南 → 不切（用户拍板）；0 弹提示（否则无法开火确认，只能等超时退款）
            if (HasEntProp(weapon, Prop_Send, "m_iClip1")
                && GetEntProp(weapon, Prop_Send, "m_iClip1") <= 0)
                PrintToChat(client, "\x04[商店]\x01 你的马格南弹匣为空，\x05换弹后开火\x01确认轰炸（超时自动退款）");
            LogMessage("[artillery] start client=%N already magnum", client);
        }
    }
    else
    {
        int newWep = GivePlayerItem(client, "weapon_pistol_magnum");
        if (newWep > 0)
            g_iArtMagnum[client] = EntIndexToEntRef(newWep);
        LogMessage("[artillery] start client=%N empty slot1, magnum=%d", client, newWep);
    }

    // 标记光点（env_sprite，全队可见；颜色随合法性心跳更新）
    int sprite = CreateEntityByName("env_sprite");
    if (sprite > 0)
    {
        DispatchKeyValue(sprite, "model", "sprites/glow01.spr");
        DispatchKeyValue(sprite, "scale", "0.35");
        DispatchKeyValue(sprite, "spawnflags", "1");          // Start On
        DispatchKeyValue(sprite, "rendercolor", "0 255 0");
        DispatchSpawn(sprite);
        float pos[3];
        GetClientAbsOrigin(client, pos);
        pos[2] += 100.0;
        TeleportEntity(sprite, pos, NULL_VECTOR, NULL_VECTOR);
        g_iArtMarker[client] = EntIndexToEntRef(sprite);
    }

    // v1.7.81: 瞄准状态最后置位——上面任何一步抛错（如属性缺失）都不会留下
    // "g_bArtAiming=true 但 timer 未建"的永久卡死（无法取消/无法重买）
    g_bArtAiming[client] = true;
    g_hArtAimTimer[client] = CreateTimer(ART_TICK_INT, Timer_ArtAim,
        GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    PrintToChat(client, "\x04[商店]\x01 已购买 \x05火炮支援1\x01（-\x03%d\x01 可用积分）。\x05瞄准轰炸区域后开火（马格南）确认\x01，\x05右键取消\x01，\x03%.0f 秒\x01内有效",
        price, g_cvArtTargetTime.FloatValue);
}

// 退出瞄准指示：清理标记/马格南/心跳，恢复原副武器，可退款
void ArtEndDesignate(int client, bool refund, bool restoreWeapon = true)
{
    if (!g_bArtAiming[client]) return;
    g_bArtAiming[client] = false;

    if (g_hArtAimTimer[client] != null)
    {
        KillTimer(g_hArtAimTimer[client]);
        g_hArtAimTimer[client] = null;
    }

    int marker = EntRefToEntIndex(g_iArtMarker[client]);
    if (marker > 0 && IsValidEntity(marker))
        AcceptEntityInput(marker, "Kill");
    g_iArtMarker[client] = 0;

    int magnum = EntRefToEntIndex(g_iArtMagnum[client]);
    if (magnum > 0 && IsValidEntity(magnum))
    {
        if (IsClientInGame(client))
            RemovePlayerItem(client, magnum);
        AcceptEntityInput(magnum, "Kill");
    }
    g_iArtMagnum[client] = 0;

    // 恢复原副武器（重给 classname + 补升级位/弹匣；断线/死亡跳过）
    // v1.7.82 FIX: 近战恢复弃用 Use 输入（L4D2 武器实体不响应 Use——拾取靠 touch，
    // 日志实锤 17:15 测试取消后副武器消失）
    // v1.7.83 FIX: GivePlayerItem("weapon_melee") 无 script 名 → 引擎返回 -1
    // （日志实锤 17:22 newWep=-1 slot1=-1 近战仍丢）→ 头顶掉落触 touch
    // v1.7.85 FIX: 头顶掉落不可靠（weapon spawn 后 movetype NONE 悬空不落，玩家
    // 碰不到，17:27 仍丢）→ 定稿：兜底手枪保证槽位不空（GivePlayerItem 100%
    // 成功）+ 原近战种类放玩家面前 50u 可捡（L4D2 捡近战自动替换手枪）+
    // 0.4s 核查贴近提示。
    if (restoreWeapon && g_sArtPrevWeapon[client][0] != '\0'
        && IsClientInGame(client) && GetClientTeam(client) == 2)
    {
        int newWep = 0;
        if (StrEqual(g_sArtPrevWeapon[client], "weapon_melee"))
        {
            newWep = GivePlayerItem(client, "weapon_pistol");
            if (g_sArtPrevMelee[client][0] != '\0')
            {
                int meleeEnt = CreateEntityByName("weapon_melee");
                if (meleeEnt > 0)
                {
                    DispatchKeyValue(meleeEnt, "melee_script_name", g_sArtPrevMelee[client]);
                    DispatchSpawn(meleeEnt);
                    float pos[3], ang[3], fwd[3];
                    GetClientAbsOrigin(client, pos);
                    GetClientEyeAngles(client, ang);
                    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
                    pos[0] += fwd[0] * 50.0;
                    pos[1] += fwd[1] * 50.0;
                    pos[2] += 5.0;
                    TeleportEntity(meleeEnt, pos, NULL_VECTOR, NULL_VECTOR);
                    DataPack pack;
                    CreateDataTimer(0.4, Timer_ArtRestoreCheck, pack,
                        TIMER_FLAG_NO_MAPCHANGE);
                    WritePackCell(pack, GetClientUserId(client));
                    WritePackCell(pack, EntIndexToEntRef(meleeEnt));
                }
            }
            LogMessage("[artillery] end restore client=%N prevWeapon='weapon_melee' "
                ... "pistol=%d slot1=%d",
                client, newWep, GetPlayerWeaponSlot(client, 1));
        }
        else
        {
            newWep = GivePlayerItem(client, g_sArtPrevWeapon[client]);
            if (g_iArtPrevUpgrade[client] != 0 && newWep > 0 && IsValidEntity(newWep)
                && HasEntProp(newWep, Prop_Send, "m_upgradeBitVec"))
                SetEntProp(newWep, Prop_Send, "m_upgradeBitVec", g_iArtPrevUpgrade[client]);
            if (g_iArtPrevClip[client] >= 0 && newWep > 0 && IsValidEntity(newWep)
                && HasEntProp(newWep, Prop_Send, "m_iClip1"))
                SetEntProp(newWep, Prop_Send, "m_iClip1", g_iArtPrevClip[client]);
            LogMessage("[artillery] end restore client=%N prevWeapon='%s' slot1=%d upgrade=%d clip=%d",
                client, g_sArtPrevWeapon[client],
                GetPlayerWeaponSlot(client, 1), g_iArtPrevUpgrade[client], g_iArtPrevClip[client]);
        }
    }
    g_sArtPrevWeapon[client][0] = '\0';
    g_sArtPrevMelee[client][0] = '\0';
    g_iArtPrevUpgrade[client] = 0;
    g_iArtPrevClip[client] = -1;

    if (refund)
    {
        g_iWallet[client] += g_iArtPrice[client];
        g_iShopBought[client][g_iArtSlot[client]]--;
        LogMessage("[artillery] designate cancelled client=%N refund=%d", client, g_iArtPrice[client]);
    }
}

// v1.7.83: 近战恢复核查——头顶掉落的近战 0.4s 后若玩家仍未拾取（被弹开等），
// 放回玩家脚下（L4D2 touch 拾取=走到武器旁自动捡）
public Action Timer_ArtRestoreCheck(Handle timer, DataPack pack)
{
    ResetPack(pack);
    int userid = ReadPackCell(pack);
    int ref = ReadPackCell(pack);
    delete pack;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Stop;
    int slot1 = GetPlayerWeaponSlot(client, 1);
    if (slot1 > 0 && IsValidEntity(slot1))
        return Plugin_Stop;                       // 已拾取装备

    int ent = EntRefToEntIndex(ref);
    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Stop;
    float pos[3];
    GetClientAbsOrigin(client, pos);
    pos[2] += 30.0;
    TeleportEntity(ent, pos, NULL_VECTOR, NULL_VECTOR);
    LogMessage("[artillery] restore check: melee not picked, dropped at feet client=%N", client);
    return Plugin_Stop;
}

// 瞄准心跳：更新标记（圆圈+光柱+光点，全队可见）+ 右键取消 + 超时/死亡
public Action Timer_ArtAim(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0) return Plugin_Stop;          // 断线（OnClientDisconnect 已清理）
    if (!g_bArtAiming[client]) return Plugin_Stop;

    if (!IsClientInGame(client) || !IsPlayerAlive(client))
    {
        ArtEndDesignate(client, true);            // 死亡 → 取消退款
        return Plugin_Stop;
    }

    if (GetGameTime() >= g_fArtAimEnd[client])
    {
        PrintToChat(client, "\x04[商店]\x01 火炮支援1瞄准超时，积分已退回");
        ArtEndDesignate(client, true);
        return Plugin_Stop;
    }

    if (GetClientButtons(client) & IN_ATTACK2)    // 右键 → 取消退款
    {
        PrintToChat(client, "\x04[商店]\x01 已取消火炮支援1，积分已退回");
        ArtEndDesignate(client, true);
        return Plugin_Stop;
    }

    // 标记更新：瞄准点 + 圆圈（爆炸范围）+ 光柱；合法绿 / 无效红
    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
        valid = false;

    int color[4] = { 0, 255, 0, 255 };            // 合法绿
    int radius = 150;
    if (valid)
    {
        int count; float r, h;
        Art_PickParams(ceiling, openAbove, count, r, h);
        radius = RoundToNearest(r);
    }
    else
    {
        color[0] = 255; color[1] = 0; color[2] = 0;   // 无效红
    }

    int marker = EntRefToEntIndex(g_iArtMarker[client]);
    if (marker > 0 && IsValidEntity(marker))
    {
        char col[32];
        Format(col, sizeof(col), "%d %d %d", color[0], color[1], color[2]);
        DispatchKeyValue(marker, "rendercolor", col);
        float pos[3];
        pos = target;
        pos[2] += 15.0;
        TeleportEntity(marker, pos, NULL_VECTOR, NULL_VECTOR);
    }

    // v1.7.85 FIX: beam 索引 0 时跳过 TE 发送（reload 后 OnMapStart 不重跑会归 0，
    // 空模型索引发送可能 segfault——17:28:36 实锤）
    if (g_iBeamLaser > 0 && g_iBeamHalo > 0)
    {
        float ground[3];
        ground = target;
        ground[2] += 5.0;
        TE_SetupBeamRingPoint(ground, float(radius) - 5.0, float(radius),
            g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15, 3.0, 0.0, color, 0, 0);
        TE_SendToAll();

        float top[3];
        top = ground;
        top[2] += 500.0;
        TE_SetupBeamPoints(ground, top, g_iBeamLaser, g_iBeamHalo, 0, 10, 0.15,
            2.0, 2.0, 0, 0.0, color, 0);
        TE_SendToAll();
    }
    return Plugin_Continue;
}

// 马格南开火 = 确认轰炸（weapon_fire 事件；只用设计器马格南判定）
public Action Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || !g_bArtAiming[client])
        return Plugin_Continue;

    int active = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (active <= 0)
        return Plugin_Continue;
    if (g_iArtMagnum[client] != 0 && EntRefToEntIndex(g_iArtMagnum[client]) != active)
        return Plugin_Continue;                   // 开的不是设计器马格南（如主武器）
    char cls[32];
    GetEntityClassname(active, cls, sizeof(cls));
    if (!StrEqual(cls, "weapon_pistol_magnum"))
        return Plugin_Continue;

    float target[3];
    bool valid;
    Art_AimPoint(client, target, valid);
    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    if (ceiling > 0.0 && ceiling < ART_CEIL_LOW && !openAbove)
        valid = false;
    LogMessage("[artillery] confirm client=%N valid=%d ceiling=%.0f openAbove=%d target=(%.0f %.0f %.0f)",
        client, valid, ceiling, openAbove, target[0], target[1], target[2]);
    if (!valid)
    {
        PrintToChat(client, "\x04[商店]\x01 目标无效：需要能落到地面的开阔区域（天花板过低或瞄天空），请重新瞄准开火");
        return Plugin_Continue;                   // 留在瞄准模式，可再次开火
    }

    ArtEndDesignate(client, false);
    Art_ConfirmStrike(client, target);
    return Plugin_Continue;
}

// 准星瞄准点（只碰世界固体，不碰玩家/特感）；瞄天花板底面 → 落点下移 120u
// v1.7.82: 水面支持——水面是 CONTENTS_WATER 不是 brush，MASK_SOLID_BRUSHONLY
// 不命中 → 瞄水面必报无效；补一次 CONTENTS_WATER trace（水面 = 开阔落点，合法）。
void Art_AimPoint(int client, float out[3], bool &valid)
{
    valid = false;
    float eye[3], ang[3], fwd[3], end[3];
    GetClientEyePosition(client, eye);
    GetClientEyeAngles(client, ang);
    GetAngleVectors(ang, fwd, NULL_VECTOR, NULL_VECTOR);
    end = eye;
    end[0] += fwd[0] * ART_AIM_MAX_DIST;
    end[1] += fwd[1] * ART_AIM_MAX_DIST;
    end[2] += fwd[2] * ART_AIM_MAX_DIST;

    char hitType[16];
    strcopy(hitType, sizeof(hitType), "brush");
    Handle tr = TR_TraceRayFilterEx(eye, end, MASK_SOLID_BRUSHONLY,
        RayType_EndPoint, ShopTraceFilter, client);
    if (TR_DidHit(tr))
    {
        TR_GetEndPosition(out, tr);
        float normal[3];
        TR_GetPlaneNormal(tr, normal);
        if (normal[2] < -0.7)                     // 瞄到天花板底面 → 落到室内地面
            out[2] -= 120.0;
        valid = true;
    }
    else
    {
        // 水面兜底（瞄天空/无遮挡时此 trace 也无命中 → 保持无效）
        Handle trw = TR_TraceRayFilterEx(eye, end, CONTENTS_WATER,
            RayType_EndPoint, ShopTraceFilter, client);
        if (TR_DidHit(trw))
        {
            TR_GetEndPosition(out, trw);
            valid = true;
            strcopy(hitType, sizeof(hitType), "water");
        }
        delete trw;
    }
    delete tr;
    LogMessage("[artillery] aimpoint client=%N hit=%s valid=%d pos=(%.0f %.0f %.0f)",
        client, hitType, valid, out[0], out[1], out[2]);
}

// 落点上方找天花板：返回距离；0 = 4096u 内无遮挡（室外）
// v1.7.82: 薄遮挡穿透——公园树冠/路灯/电线/雨棚是 <50u 的薄 brush（c5m2 实测
// 开阔室外被树冠误判 ceiling<600 报"目标无效"），穿透后继续向上找，只认
// ≥50u 的实心结构（楼板/岩石/桥面）为天花板；最多穿透 3 层。
// v1.7.83: 侧面命中穿透——树干/柱/墙是"竖直柱面"（法线近乎水平），向上 trace
// 穿树干时侧面命中被判"实心天花板"（17:22 日志 dist=339 实锤）；法线 z>-0.7
// → 不是天花板，穿透继续。薄遮挡阈值 50→100u（树冠/雨棚常见 50-100u）。
#define ART_CEIL_THIN  100.0  // 薄遮挡厚度阈值（u）
// v1.7.84: openAbove 输出——最终判定实心天花板的上方是否开阔（再向上 4096u
// 无遮挡）。平台/桥/单层屋顶上方是天空 → openAbove=true → <600 也放行
// （罐子从遮挡下 150u 短落爆炸，用户在大平台/桥上也有轰炸效果）；
// 多层建筑/地下室 → openAbove=false → <600 拒绝（保持 v1.7.80 用户拍板）。
float Art_FindCeiling(const float pos[3], bool &openAbove)
{
    openAbove = false;
    float from[3], to[3];
    from = pos;
    from[2] += 60.0;
    to = from;
    to[2] += ART_CEIL_CLEAR;

    // data=-1 → ShopTraceFilter(entity != -1) 恒真 → 忽略所有实体，只算世界几何
    float dist = 0.0;
    int hops = 0;
    int hits = 0;
    float lastNormal[3] = { 0.0, 0.0, 0.0 };
    float lastHit[3];
    while (hops < 4)
    {
        Handle tr = TR_TraceRayFilterEx(from, to, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        if (!TR_DidHit(tr))
        {
            dist = 0.0;                       // 到顶无遮挡 → 室外
            delete tr;
            break;
        }
        hits++;
        float frac = TR_GetFraction(tr);
        float seg = frac * (to[2] - from[2]);
        TR_GetEndPosition(lastHit, tr);
        TR_GetPlaneNormal(tr, lastNormal);
        delete tr;

        // 侧面命中（树干/柱/墙，法线近乎水平）→ 不是天花板 → 穿透继续
        if (lastNormal[2] > -0.7)
        {
            dist += seg;
            from = lastHit;
            from[2] += 2.0;
            hops++;
            continue;
        }

        // 从命中点继续向上 probe：100u 内无再命中 → 薄遮挡（树冠等），穿透继续
        float probe[3];
        probe = lastHit;
        probe[2] += ART_CEIL_THIN;
        Handle tr2 = TR_TraceRayFilterEx(lastHit, probe, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        bool solidAbove = TR_DidHit(tr2);
        delete tr2;

        if (!solidAbove)
        {
            dist += seg;
            from = probe;                     // 穿透：从命中点上方继续
            hops++;
            continue;
        }
        dist += seg;                          // 实心天花板：累计到命中点
        break;
    }

    // 实心遮挡上方是否开阔：从命中点上方 120u 再向上探测（无再命中 = 开阔）
    if (dist <= 0.0)
    {
        openAbove = true;                     // 室外
    }
    else
    {
        float above[3], to2[3];
        above = lastHit;
        above[2] += 120.0;
        to2 = above;
        to2[2] += ART_CEIL_CLEAR;
        Handle tr = TR_TraceRayFilterEx(above, to2, MASK_SOLID,
            RayType_EndPoint, ShopTraceFilter, -1);
        openAbove = !TR_DidHit(tr);
        delete tr;
    }
    LogMessage("[artillery] ceiling pos=(%.0f %.0f %.0f) dist=%.0f openAbove=%d hops=%d hits=%d normal=(%.2f %.2f %.2f)",
        pos[0], pos[1], pos[2], dist, openAbove, hops, hits,
        lastNormal[0], lastNormal[1], lastNormal[2]);
    return dist;
}

// 三级参数：室外 / 室内大(≥900) / 室内小(600-900) / 遮挡下短落(<600 且上方开阔)
// v1.7.84: 短落——平台/桥/树冠下，罐子从遮挡下 150u（下限 100u）掉落照样爆炸，
// 大平台/桥上使用不再"目标无效"；高度与爆炸伤害无关（落地触发）。
void Art_PickParams(float ceiling, bool openAbove, int &count, float &radius, float &height)
{
    if (ceiling <= 0.0)
    {
        count  = g_cvArtCountOut.IntValue;
        radius = g_cvArtRadiusOut.FloatValue;
        height = GetRandomFloat(g_cvArtHeightMin.FloatValue, g_cvArtHeightMax.FloatValue);
    }
    else if (ceiling >= ART_CEIL_MID)
    {
        count  = g_cvArtCountMid.IntValue;
        radius = g_cvArtRadiusMid.FloatValue;
        height = ceiling - 150.0;                 // 吊顶下生成，保证落地高度
    }
    else if (openAbove)
    {
        // v1.7.88: 开阔（平台/桥上方有天，如实测点位 ceiling=339）——之前锁小档
        // 用户反馈"太小了" → 按室外规模炸（12罐/500），落点高度仍压到吊顶-150 防撞头顶结构
        count  = g_cvArtCountOut.IntValue;
        radius = g_cvArtRadiusOut.FloatValue;
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
        if (height > 500.0) height = 500.0;
    }
    else if (ceiling >= ART_CEIL_LOW)
    {
        count  = g_cvArtCountSmall.IntValue;      // 封闭矮房（600-900）：小规模
        radius = g_cvArtRadiusSmall.FloatValue;
        height = ceiling - 150.0;
        if (height < 100.0) height = 100.0;
    }
    else
    {
        count  = g_cvArtCountSmall.IntValue;      // 拒绝级：确认前被拦截，不会真正使用
        radius = g_cvArtRadiusSmall.FloatValue;
        height = ceiling - 150.0;
    }
    if (count < 1) count = 1;
    if (count > ART_MAX_CANS) count = ART_MAX_CANS;
}

// 确认轰炸：锁定落点 → 全服警报 → 错峰生成罐子
void Art_ConfirmStrike(int client, float target[3])
{
    if (g_hArtCans == null)
        g_hArtCans = new ArrayList();

    bool openAbove;
    float ceiling = Art_FindCeiling(target, openAbove);
    int count; float radius, height;
    Art_PickParams(ceiling, openAbove, count, radius, height);

    // 轰炸总时长 = 首罐延迟 + 末罐生成 + 落地 + 落地后燃烧 + 引爆（播报"剩余 x 秒"）
    // v1.7.86: 点燃的罐子对伤害免疫且燃烧结束不自爆（实测"假火"）→ 火灭后引擎引爆
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    float burn = g_cvArtBurn.FloatValue;              // 落地后继续燃烧秒数
    float duration = g_cvArtDelay.FloatValue + float(count - 1) * g_cvArtStagger.FloatValue
        + fallT + burn + 0.15;
    g_fArtNextBuyTime = GetGameTime() + duration + g_cvArtCooldown.FloatValue;

    // v1.7.80（用户拍板）：开始/结束全服聊天播报 + 轰炸中/冷却中禁止全体购买
    PrintToChatAll("\x04[商店]\x01 \x05火炮支援来袭，注意躲避！\x01剩余：\x03%d\x01 秒", RoundToCeil(duration));
    PrintToChatAll("\x04[商店]\x01 \x05%N\x01 召唤了区域火炮：着火的瓦斯罐/煤气罐即将从天而降！", client);
    CreateTimer(duration, Timer_ArtNotifyEnd, INVALID_HANDLE, TIMER_FLAG_NO_MAPCHANGE);

    for (int i = 0; i < count; i++)
    {
        DataPack dp = new DataPack();
        dp.WriteFloat(target[0]);
        dp.WriteFloat(target[1]);
        dp.WriteFloat(target[2]);
        dp.WriteFloat(radius);
        dp.WriteFloat(height);
        dp.WriteCell(GetClientUserId(client));
        CreateTimer(g_cvArtDelay.FloatValue + float(i) * g_cvArtStagger.FloatValue,
            Timer_ArtSpawnCan, dp, TIMER_FLAG_NO_MAPCHANGE);
    }

    LogMessage("[artillery] strike client=%N target=(%.0f,%.0f,%.0f) ceiling=%.0f count=%d r=%.0f h=%.0f",
        client, target[0], target[1], target[2], ceiling, count, radius, height);
}

// 生成单个着火罐子（圆内均匀散布）→ 安排落地强制引爆
public Action Timer_ArtSpawnCan(Handle timer, DataPack dp)
{
    dp.Reset();
    float target[3];
    target[0] = dp.ReadFloat();
    target[1] = dp.ReadFloat();
    target[2] = dp.ReadFloat();
    float radius = dp.ReadFloat();
    float height = dp.ReadFloat();
    int userid = dp.ReadCell();
    delete dp;

    float ang = GetRandomFloat(0.0, 6.2831853);
    float r = radius * SquareRoot(GetRandomFloat(0.0, 1.0));
    float pos[3];
    pos[0] = target[0] + Cosine(ang) * r;
    pos[1] = target[1] + Sine(ang) * r;
    pos[2] = target[2] + height;

    // v1.7.93 FIX（死亡爆炸最终方案）: 直接生成 prop_physics + 罐模型 = 地图罐子
    // 等价物。引擎爆炸能力由模型 propdata（physgun_interactions onbreak:explode_fire）
    // 承载，只有 prop_physics 破碎/死亡时触发；weapon_* 类名实体不走 propdata 破碎
    // 路径：v1.7.90/91 实锤生成态 weapon_propanetank 死亡静默消失（post-blast
    // hp=-99942），v1.7.92 give+drop 转换依赖购买者槽位/触地拾取竞态（slot4 掉落 +
    // 脚边闪现）。社区定论（[L4D1 & L4D2] Weapon Prop Give Fix, t-331053 /
    // disawar1 Physics fix, t-178076）：能炸的罐子 = prop_physics + 罐模型，
    // weapon_* drop 后不可 break/ignite/explode。直接生成最终形态 → 无 give+drop
    // 副作用；死亡/点燃过热 → 引擎爆炸（音效/火球/伤害/友伤缩放全原版）。
    char model[PLATFORM_MAX_PATH];
    if (GetRandomInt(1, 100) <= ART_CAN_PROPANE_PCT)
        strcopy(model, sizeof(model), "models/props_junk/propanecanister001a.mdl");
    else
        strcopy(model, sizeof(model), "models/props_equipment/oxygentank01.mdl");

    int ent = CreateEntityByName("prop_physics");
    if (ent == -1)
    {
        LogError("[artillery] spawn prop_physics failed");
        return Plugin_Continue;
    }
    DispatchKeyValue(ent, "model", model);
    DispatchKeyValueVector(ent, "origin", pos);     // 直接生成在落点上空（不经世界原点）
    DispatchSpawn(ent);
    SetEntProp(ent, Prop_Data, "m_takedamage", 2);

    Art_LaunchCan(ent, pos, height, userid, true);
    return Plugin_Continue;
}

// 罐子发射共用尾部：传送落点 + 点火 + 跟踪 + 安排引爆
void Art_LaunchCan(int ent, const float pos[3], float height, int userid, bool converted)
{
    // 火会持续伤害罐子（v1.7.91 实锤 100→57）→ 抬高血量防燃烧中途过热自爆
    // （500hp ≈ 31s 燃烧才自爆，手动引爆时序内安全）
    if (converted && HasEntProp(ent, Prop_Data, "m_iHealth"))
        SetEntProp(ent, Prop_Data, "m_iHealth", 500);

    float vel[3] = { 0.0, 0.0, -80.0 };             // 轻微初速，防止悬停
    TeleportEntity(ent, pos, NULL_VECTOR, vel);

    // 坠落全程 + 落地后 burn 秒带火尾；火灭 0.15s 后引爆定时器（节奏错峰）
    float fallT = SquareRoot((2.0 * height) / ART_GRAVITY);
    float burn = g_cvArtBurn.FloatValue;
    if (burn < 0.5) burn = 0.5;
    IgniteEntity(ent, fallT + burn);

    int ref = EntIndexToEntRef(ent);
    if (ref != 0 && g_hArtCans != null)
        g_hArtCans.Push(ref);

    DataPack dp3 = new DataPack();
    dp3.WriteCell(ref);
    dp3.WriteCell(userid);
    CreateTimer(fallT + burn + 0.15, Timer_ArtExplode, dp3,
        TIMER_FLAG_NO_MAPCHANGE);
}

// 轰炸结束播报（含硬冷却提示）
public Action Timer_ArtNotifyEnd(Handle timer)
{
    PrintToChatAll("\x04[商店]\x01 \x05火炮支援结束\x01，\x03%.0f\x01 秒后可重新购买", g_cvArtCooldown.FloatValue);
    return Plugin_Continue;
}

// 火灭后引爆：击杀罐子 → 引擎死亡爆炸（原版音效/伤害/友伤缩放/击杀归属全自动）
public Action Timer_ArtExplode(Handle timer, DataPack dp)
{
    dp.Reset();
    int ent = EntRefToEntIndex(dp.ReadCell());
    int buyer = GetClientOfUserId(dp.ReadCell());
    delete dp;

    if (ent <= 0 || !IsValidEntity(ent))
        return Plugin_Continue;                     // 已被玩家提前打爆 → 无事

    // v1.7.91 FIX（静默消失根因）: 去掉 DMG_ALWAYSGIB——强制碎尸会跳过引擎死亡
    // 爆炸（v1.7.90 实测：罐子死了但没炸，直接消失）。纯 DMG_BLAST 走正常死亡
    // 流程 → 引擎死亡爆炸（音效/火球/伤害/友伤缩放全原版）。
    SDKHooks_TakeDamage(ent, ent, buyer > 0 ? buyer : 0, 99999.0,
        DMG_BLAST, -1, NULL_VECTOR, NULL_VECTOR, false);

    if (IsValidEntity(ent))
    {
        // 诊断：hp<=0 = 已死但爆炸未触发（引擎问题）；hp>0 = 仍打不死
        int hp = HasEntProp(ent, Prop_Data, "m_iHealth")
            ? GetEntProp(ent, Prop_Data, "m_iHealth") : -1;
        LogMessage("[artillery] can %d post-blast hp=%d (alive after 99999 dmg)", ent, hp);
    }
    return Plugin_Continue;
}

// v1.7.89 FIX: 近战种类名读取——m_MeleeWeaponName(Prop_Send) 实测读空（18:08 日志
// prevMelee='' 导致恢复兜底小手枪）→ 多属性名/多 prop 域逐一尝试，取第一个非空
void Art_SaveMeleeName(int client, int weapon)
{
    char name[64];
    static const char props[][] = { "m_MeleeWeaponName", "m_szMeleeWeaponName" };
    for (int i = 0; i < 2 && g_sArtPrevMelee[client][0] == '\0'; i++)
    {
        if (HasEntProp(weapon, Prop_Send, props[i]))
            GetEntPropString(weapon, Prop_Send, props[i], name, sizeof(name));
        if (name[0] == '\0' && HasEntProp(weapon, Prop_Data, props[i]))
            GetEntPropString(weapon, Prop_Data, props[i], name, sizeof(name));
        if (name[0] != '\0')
        {
            strcopy(g_sArtPrevMelee[client], sizeof(g_sArtPrevMelee[]), name);
            break;
        }
        name[0] = '\0';
    }
}

// v1.7.90: prop_physics + 手搓爆炸（Art_DoExplosion/Art_CanTakeDamage/IsArtExplodable）
// 已整体移除——回归原版 weapon_* 罐子 + 补可破坏状态（见 Timer_ArtSpawnCan 注释）。

// 换图 / 卸载 / reload 兜底清理：所有瞄准状态 + 残留罐子
void Art_CleanupAll()
{
    g_fArtNextBuyTime = 0.0;                       // 换图清冷却（通知定时器 NO_MAPCHANGE 已随图自动清）

    for (int i = 1; i <= MaxClients; i++)
    {
        // v1.7.82: restoreWeapon=false——换图/卸载时机不恢复武器（重生自动重置，
        // 避免换图瞬间 GivePlayerItem 竞态）
        if (g_bArtAiming[i])
            ArtEndDesignate(i, false, false);
    }

    if (g_hArtCans != null)
    {
        for (int i = 0; i < g_hArtCans.Length; i++)
        {
            int ent = EntRefToEntIndex(g_hArtCans.Get(i));
            if (ent > 0 && IsValidEntity(ent))
                AcceptEntityInput(ent, "Kill");
        }
        g_hArtCans.Clear();
    }
}
