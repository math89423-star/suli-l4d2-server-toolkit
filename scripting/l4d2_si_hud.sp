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
 * Changelog v1.9.0:
 *   - 商店解耦（user 拍板）: !shop/!buy 商店整体移出为独立插件 l4d2_shop.sp
 *     （商品表/菜单/购买/透视特感/火炮支援 I/II + si_hud_shop_enable/
 *     si_hud_art_* cvar）。本插件保留计分入账、钱包/复活币所有权与持久化、
 *     复活系统、排行榜、HUD。新增 SH_ 公共 API（RegPluginLibrary
 *     "l4d2_si_hud_api"：SH_GetWallet/SH_AddWallet/SH_GetReviveCoins/
 *     SH_AddReviveCoins/SH_GetCoinMax；契约见 include/l4d2_si_hud.inc；
 *     SM 1.12 懒绑定：l4d2_shop 直接 native 声明 + FindPluginByFile 守卫）。
 *     respawn_coin_* 保留本插件。
 *   - 删除死代码: gamedata SetHasLaserSight SDKCall（L4D2 无此符号，从未调用）
 *     + sm_laser_test 调试命令 + gamedata/l4d2_si_hud.txt 文件。
 *
 * Changelog v1.8.2:
 *   - FIX 换图可用积分被清 0 (user 实测): GetMapPrefix 从第一个 '_' 截断 →
 *     "c1m1_hotel"→"c1m1"、"c1m2_streets"→"c1m2"，地图号混进战役前缀 →
 *     每次换图都被判成"新战役"：OnMapStart 清可用积分/复活币 + ScoreLoad_Player
 *     存档战役校验拒绝恢复（v1.7.28 跨图保留、v1.7.43 重连恢复均被此毒化，
 *     官图从未真正生效）。重写 GetMapPrefix：截 "m<数字>" 标记
 *     （"c1m2_streets"→"c1"、"zc1_m1"→"zc1"）或尾部 "分隔符+数字" 段
 *     （"l4d_yama_1"→"l4d_yama"）；无标记独立图 → 整图名。缓冲 16→64。
 *   - FIX 换图重连窗口过窄 (大三方图加载 >20s 必丢): 断线记录所在图，
 *     重连时地图已变 = changelevel 自动重连 → 窗口放宽 180s；
 *     同图重连（疑似主动退服）保持 20s 防带旧钱。
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

#define PLUGIN_VERSION "1.9.0"

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
ConVar g_cvRespawnEnable;      // v1.7.28
ConVar g_cvRespawnBase;        // v1.7.28
ConVar g_cvRespawnDelay;       // v1.7.28
ConVar g_cvRespawnCoinMax;     // v1.7.29: 复活币持有上限
ConVar g_cvRespawnCoinStart;   // v1.7.31: 新玩家初始复活币
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
char      g_sPrevCampaign[64];                        // 上一张图的战役前缀（前缀变化 = 新战役 → 清钱包/复活币）
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

// v1.7.34: 持久化——钱包/复活币按 SteamID 存 KeyValues（data/si_hud_scores.txt），
// reload/重启不丢；保存时机: 断线 / OnPluginEnd(reload) / 60s 周期 / 新战役清零后
char      g_sSavePath[PLATFORM_MAX_PATH];

// v1.7.40: 前向声明（OnPluginStart/持久化区在 GetMapPrefix 定义之前使用）
void GetMapPrefix(const char[] map, char[] out, int maxlen);

// v1.7.43: 换图重连识别——L4D2 changelevel 时客户端断线自动重连，
// 会被 OnClientPostAdminCheck 当成"新加入"清空钱包。断线时记录
// (SteamID, 时间, 所在图)，重连时同 ID 匹配 = 换图重连 → 恢复存档。
// v1.8.2: 换图重连窗口放宽到 180s（大三方图加载慢，20s 必丢）；同图重连保持 20s。
char      g_sDiscAuth[MAXPLAYERS + 1][32];
float     g_fDiscTime[MAXPLAYERS + 1];
char      g_sDiscMap[MAXPLAYERS + 1][64];             // v1.8.2: 断线时的地图（换图判定用）


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

// ============================================================================
// v1.9.0: SH_ public API（l4d2_shop.sp 消费）——商店解耦
// 钱包/复活币单源所有权在本插件（计分入账 + 持久化 + 复活消费）；
// 消费方只经 natives 读写，不改内部状态。
// ============================================================================

public int Native_SH_GetWallet(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
        return 0;
    return g_iWallet[client];
}

public int Native_SH_AddWallet(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int amount = GetNativeCell(2);
    if (client >= 1 && client <= MaxClients)
    {
        int newVal = g_iWallet[client] + amount;
        if (newVal < 0) newVal = 0;   // 结果钳制 >= 0
        g_iWallet[client] = newVal;
    }
    return (client >= 1 && client <= MaxClients) ? g_iWallet[client] : 0;
}

public int Native_SH_GetReviveCoins(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients)
        return 0;
    return g_iReviveCoins[client];
}

public int Native_SH_AddReviveCoins(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int amount = GetNativeCell(2);
    if (client >= 1 && client <= MaxClients)
    {
        int newVal = g_iReviveCoins[client] + amount;
        if (newVal < 0) newVal = 0;   // 结果钳制 >= 0
        g_iReviveCoins[client] = newVal;
    }
    return (client >= 1 && client <= MaxClients) ? g_iReviveCoins[client] : 0;
}

public int Native_SH_GetCoinMax(Handle plugin, int numParams)
{
    return g_cvRespawnCoinMax.IntValue;
}

// ============================================================================
// OnPluginStart
// ============================================================================

public void OnPluginStart()
{
    CreateConVar("si_hud_version", PLUGIN_VERSION,
        "SI HUD version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

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

    // v1.9.0: SH_ public API（l4d2_shop.sp 消费）——商店解耦
    RegPluginLibrary("l4d2_si_hud_api");
    CreateNative("SH_GetWallet",      Native_SH_GetWallet);
    CreateNative("SH_AddWallet",      Native_SH_AddWallet);
    CreateNative("SH_GetReviveCoins", Native_SH_GetReviveCoins);
    CreateNative("SH_AddReviveCoins", Native_SH_AddReviveCoins);
    CreateNative("SH_GetCoinMax",     Native_SH_GetCoinMax);

    // ── Events ──────────────────────────────────────────

    HookEvent("player_hurt",    Event_PlayerHurt);
    HookEvent("player_spawn",   Event_PlayerSpawn);
    HookEvent("player_death",   Event_PlayerDeath);
    HookEvent("infected_death", Event_InfectedDeath);
    HookEvent("infected_hurt",  Event_InfectedHurt);    // v1.7.16: common damage points
    HookEvent("revive_success", Event_ReviveSuccess);   // v1.7.51: 救援算分
    HookEvent("round_end",      Event_RoundEnd);
    HookEvent("round_start",    Event_RoundStart);      // v1.7.30: 团灭重开判定
    HookEvent("map_transition", Event_MapTransition);   // v1.7.9


    RegAdminCmd("sm_streak_test", Cmd_StreakTest, ADMFLAG_ROOT,
        "sm_streak_test — debug: play the L2 streak sound + the SI kill sound directly");

    // v1.7.6: chat scoreboard (Y key) — !rank / !score / !top
    RegConsoleCmd("sm_rank", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");
    RegConsoleCmd("sm_score", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");
    RegConsoleCmd("sm_top", Cmd_Scoreboard, "Show the scoreboard (top + your rank).");

    // v1.7.6: periodic per-player broadcast (45s default; 0=off via cvar
    // check inside the callback; interval change needs plugin reload)
    CreateTimer(45.0, Timer_ScoreboardBroadcast, INVALID_HANDLE, TIMER_REPEAT);

    // v1.7.32d FIX: plugin reload 不触发 OnClientPutInServer —— 已在线的玩家
    // 复活次数/复活币/钱包全是 0（reload 清零副作用）。补全初始化：
    // 复活次数回 base，钱包/复活币从持久化文件恢复（v1.7.34）。
    ScoreSave_Init();
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
    char savedCampaign[64];
    char curMap[64];
    GetCurrentMap(curMap, sizeof(curMap));
    char curPrefix[64];
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

    // HP display is now on-hit only (player_hurt → RefreshHPForClient → 0.5s hide).
    // Persistent timer is no longer started — SI HP only shows when you damage them.

    // v1.7.28: 战役判定——地图前缀变化 = 切换新战役 → 清可用积分 + 复活币
    // （用户：可用积分不随 map 切换清理，只重新开始战役/切换新战役才清理）
    char map[64];
    GetCurrentMap(map, sizeof(map));
    char prefix[64];
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
    // v1.8.2 FIX (user 实测): 旧实现从第一个 '_' 截断 → "c1m1_hotel"→"c1m1"、
    // "c1m2_streets"→"c1m2"，地图号混进战役前缀 → 每次换图都被判成"新战役"，
    // OnMapStart 清可用积分/复活币 + 存档校验拒绝恢复（v1.7.28 跨图保留从未生效）。
    // 战役前缀 = 去掉地图号标记的部分：
    //   官图风格 "c1m2_streets" → "c1"（截 "m<数字>" 标记）
    //   三方图风格 "zc1_m1" → "zc1"、"l4d_yama_1" → "l4d_yama"（截尾部 "分隔符+数字" 段）
    //   无标记（独立图 "l4d_sh01_oldsh" 等）→ 整图名作为自己的战役
    int len = strlen(map);
    int cut = len;

    // 1) "m<数字>" 地图号标记（官图 + 部分三方图）：标记之前即战役
    for (int i = 0; i < len - 1; i++)
    {
        if (map[i] == 'm' && map[i + 1] >= '0' && map[i + 1] <= '9')
        {
            cut = i;
            break;
        }
    }

    // 2) 无 m<数字> 标记：尾部 "分隔符+数字" 段（"l4d_yama_1" 的 "_1"）是地图号
    if (cut == len)
    {
        for (int i = len - 1; i > 0; i--)
        {
            if ((map[i] == '_' || map[i] == '-') && map[i + 1] >= '0' && map[i + 1] <= '9')
            {
                cut = i;
                break;
            }
        }
    }

    // 去尾部残留分隔符（"nanningcity_bridge_m6" 截出 "nanningcity_bridge_"）
    while (cut > 0 && (map[cut - 1] == '_' || map[cut - 1] == '-'))
        cut--;

    if (cut <= 0)
        cut = len;

    if (cut >= maxlen)
        cut = maxlen - 1;
    strcopy(out, maxlen, map);
    out[cut] = '\0';
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
    g_bMapEndBroadcasted = false;          // v1.7.9: fresh map, fresh flag
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
    g_iTotalScore[client] = 0;
    g_iSIKills[client] = 0;
    g_iDeaths[client] = 0;
    g_iFFDamage[client] = 0;
    g_iBlacked[client] = 0;
}

public void OnClientPostAdminCheck(int client)
{
    // v1.7.43: 换图重连判定——同 SteamID 断线记录匹配 = changelevel 自动重连
    // → 恢复存档（同战役换图不丢钱）；否则 = 真实新加入 → 全默认 0
    // v1.8.2: 断线后地图已变 = 换图重连（大三方图加载慢，窗口放宽 180s）；
    // 同图重连 = 疑似主动退服，保持 20s 严格窗口（防中途进服带旧钱）
    char auth[32];
    bool reconnect = false;
    if (GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth), false))
    {
        float now = GetGameTime();
        char curMap[64];
        GetCurrentMap(curMap, sizeof(curMap));
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_fDiscTime[i] > 0.0 && StrEqual(g_sDiscAuth[i], auth))
            {
                bool mapChanged = (strlen(g_sDiscMap[i]) > 0 && !StrEqual(g_sDiscMap[i], curMap));
                float window = mapChanged ? 180.0 : 20.0;
                if (now - g_fDiscTime[i] < window)
                {
                    reconnect = true;
                    g_fDiscTime[i] = 0.0;   // 消费记录
                    break;
                }
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
    ScoreSave_Player(client);            // v1.7.34: 断线保存（必须在清零前）
    // v1.7.43: 记录断线 SteamID + 时间（换图重连识别用）
    // v1.8.2: 顺带记录断线时的地图（重连时判断地图是否已变 → 放宽窗口）
    if (GetClientAuthId(client, AuthId_Steam2, g_sDiscAuth[client], sizeof(g_sDiscAuth[]), false))
    {
        g_fDiscTime[client] = GetGameTime();
        GetCurrentMap(g_sDiscMap[client], sizeof(g_sDiscMap[]));
    }
    else
    {
        g_fDiscTime[client] = 0.0;
        g_sDiscMap[client][0] = '\0';
    }
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

