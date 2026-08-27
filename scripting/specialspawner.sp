#pragma tabsize 1
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

// v2.5.0 剿灭得分: si_hud 钱包入账口（AskPluginLoad2 里 MarkNativeAsOptional——
// si_hud 未加载时本插件仍可加载, 调用前必须 GetFeatureStatus 守卫）
native int SH_AddWallet(int client, int amount);

#define DEBUG		0
#define BENCHMARK	0
#if BENCHMARK
	#include <profiler>
	Profiler g_profiler;
#endif

#define SI_SMOKER		0
#define SI_BOOMER		1
#define SI_HUNTER		2
#define SI_SPITTER		3
#define SI_JOCKEY		4
#define SI_CHARGER		5
#define SI_MAX_SIZE		6

#define SPAWN_NO_PREFERENCE						-1
#define SPAWN_ANYWHERE							0
#define SPAWN_BEHIND_SURVIVORS					1
#define SPAWN_NEAR_IT_VICTIM					2
#define SPAWN_SPECIALS_IN_FRONT_OF_SURVIVORS	3
#define SPAWN_SPECIALS_ANYWHERE					4
#define SPAWN_FAR_AWAY_FROM_SURVIVORS			5
#define SPAWN_ABOVE_SURVIVORS					6
#define SPAWN_IN_FRONT_OF_SURVIVORS				7
#define SPAWN_VERSUS_FINALE_DISTANCE			8
#define SPAWN_LARGE_VOLUME						9
#define SPAWN_NEAR_POSITION						10

// v1.4.0 贴脸守卫 v3：分散刷 + LOS 过滤。
// 引擎 L4D_GetRandomPZSpawnPosition 生成点只围绕"参照生还者"转。固定一个领跑者
// （v1.3.8）→ 多人长队伍时领跑者 200-900 环带全是队友 → 重掷全灭整波饿死 + 堆怪；
// 只随机参照者（v1.3.9）→ 分散了，但保底 250 点常刷在队伍侧后方 → 看不见人 →
// 25s 自杀处决。v1.4.0：每只随机参照者（分散刷，每只独立）→ 候选点散布全队周边，
// 且必须 LOS 可见至少一个生还者；优先 ≥ss_spawnrange_guard(400)，耗尽改取
// ≥ss_spawnrange_guard_min(250) 且可见的最佳点，再兜底 250 不可见（窄室内防饿死），
// 仍无 → 本只跳过等下波（绝不放行 <250）。
// v1.4.1：处决可观测——KillInactiveSI 记 LogMessage；fallback 拆 visible/invisible
// 计数（invis-fb 是残余处决源，比例偏高时再收紧，比如调低 guard_min 或禁止不可见兜底）。
// v1.5.0 倒地补偿：刷怪瞬间按 站立/总人数 比例收缩本波数量与有效上限。
// 例: 10人5倒 → ratio 0.5 → 上限 15→8、波次 10→5，站立 5 人面对 ≤8 特感而非 15。
// 实时计算（无 cvar 写入）→ 复活后下一波自动恢复，不存在陈旧值。
// 强度 ss_incap_compensation [0-1]：1 = 全比例，0 = 关闭，0.5 = 半补偿。
// si_comp 播报镜像同公式（v2.3.8），改公式必须两处同步。
// v1.6.0 方向随机化：引擎每次 L4D_GetRandomPZSpawnPosition 调用会读脚本值
// "PreferredSpecialDirection"（插件在 L4D_OnGetScriptValueInt 拦截返回 g_iDirection）。
// 旧逻辑普通波次固定 SPAWN_LARGE_VOLUME(9) → 候选点全在队伍正前方锥形区 +
// 引擎 flow 校验偏前 → 实测"只会正前方"；且前方墙后点 LOS 全灭 → 全走不可见
// 兜底 → 2026-08-04 单日 210 次处决。v1.6.0：普通波次改 SPAWN_NO_PREFERENCE(-1)
// → 引擎每次调用随机方向（前/后/上/任意），ss_random_direction 可切回旧行为。
// v1.7.0 三段定向（单面受敌修复）：队伍拉长时按权重把本波特感分配到
// 前/中/后三段，每只独立方向+独立参照者——前段 IN_FRONT(7) 拦截、中段
// NO_PREFERENCE(-1) 侧翼、后段 BEHIND(1) 身后断后。段边界按 flow gap 自然切
// （蛇形/断裂队伍每段都能吃到特感）。防贴脸不变式：守卫查的是"落点离所有
// 生还者的地理 3D 距离"（v1.3.8 全队扫描），与参照者/方向无关，段划分只改变
// 特感出现的方位、不改变离人距离的下限。
#define SPAWN_GUARD_MAX_TRIES					10

// v1.7.0 波次最大规模（ss_spawn_size 上限 32，留余量给段分配数组）
#define MAX_WAVE								48

// v2.0.0 波间三态状态机（压力/收尾/冷静）
// IDLE 是唯一允许存在"待命波次 timer"的相位；其余相位各持有且仅持有一个生命周期 timer。
// 不变量: 非 IDLE 相位恰持一个生命周期 timer; IDLE 持有待命波 timer 或等待。
enum WavePhase {
	PHASE_IDLE = 0,			// 闲置: 开场等待 / 换图 / 冷静期结束后等下一波 timer
	PHASE_PRESSURE,			// 压力期: 本波批次释放 + retry 补波（可刷怪）
	PHASE_CLEARING,			// 收尾期: 2s 轮询清场（不刷怪, 等总特感 ≤ 阈值或 120s 硬上限）
	PHASE_REST				// 冷静期: 12-18s 倒计时休息（零特感压力缓冲节点）
}

// v2.0.2: 相位名映射（防御日志用）
static const char sPhaseNames[][] = { "IDLE", "PRESSURE", "CLEARING", "REST" };

Handle
	g_hSpawnTimer,
	g_hRetryTimer,
	g_hUpdateTimer,
	g_hSuicideTimer,
	g_hBatchTimer,				// v1.7.0 分批释放续刷 timer
	g_hClearTimer,				// v2.0.0 收尾期 2s 轮询 timer
	g_hRestTimer;				// v2.0.0 冷静期倒计时 timer
	float g_fRestEndTime;		// v2.5.4: 冷静期到期时刻（engine time，冻结恢复用）
	float g_fRestFrozenRemaining;	// v2.5.4: 暂停冻结的冷静期剩余秒数（0 = 无冻结）

// v2.2.0 波次生命周期 forward（外部插件监听）
GlobalForward
	g_fwdOnWaveRest,			// 进入冷静期（清缴结束，下波倒计时开始）
	g_fwdOnWaveStart;			// 波次开始（压力期，特感刷新）

ArrayList
	g_hBatchQueue;				// v1.7.0 本波类型队列（跨批持有，批间存活）

ConVar
	g_cSILimit,
	g_cSpawnSize,
	g_cSpawnLimits[SI_MAX_SIZE],
	g_cSpawnWeights[SI_MAX_SIZE],
	g_cScaleWeights,
	g_cSpawnTimeMode,
	g_cSpawnTimeMin,
	g_cSpawnTimeMax,
	g_cBaseLimit,
	g_cExtraLimit,
	g_cBaseSize,
	g_cExtraSize,
	g_cTankStatusAction,
	g_cTankStatusLimits,
	g_cTankStatusWeights,
	g_cSuicideTime,
	g_cRushDistance,
	g_cSpawnRangeMin,
	g_cSpawnRangeMax,
	g_cSpawnRangeGuard,
	g_cSpawnRangeGuardMin,
	g_cSpawnDistMax,
	g_cSpreadFloor,				// v6.5.0 分散降级保底间隔
	g_cInvisMaxDist,			// v6.5.0 不可见兜底距离上限
	// v2.6.0 幽灵修复: 不可见兜底分档 —— v6.0.0 起语义废弃（不再决定 fallback 等级），
	// 仅保留注册防旧 cfg 报错（报告 §16 建议逐步废掉），不再持有 handle。
	// v6.0.0 调研落地: Hard Gate + Soft Score 参数
	g_cCandidateSamples,		// 采样候选数
	g_cNavPathMax,				// NavPath 最大长度
	g_cNavTravelPrefMin,		// NavTravel 首选下限
	g_cNavTravelPrefMax,		// NavTravel 首选上限
	g_cFlowDeltaPref,			// flow 差首选上限
	g_cTargetInject,			// 出生目标注入开关
	g_cTargetInjectTime,		// 注入持续秒数
	g_cRecoverTime,				// 看门狗 retarget 阈值
	g_cRelocateTime,			// 看门狗 relocate 阈值
	// v6.0.2 坠落/不可见修复③: 波次泄气推进 cvar（防场上无 SI 时干等 60s 真空）
	g_cStallAdvance,
	g_cFirstSpawnTime,
	g_cSpawnRange,
	g_cDiscardRange,
	g_cSafeSpawnRange,
	g_cIncapCompensation,
	g_cRandomDirection,
	g_cDirFront,
	g_cDirMid,
	g_cDirBack,
	g_cDirSplitSpread,
	g_cDirSplitGap,
	g_cBatchSize,				// v2.0.0 批次引擎
	g_cBatchMax,
	g_cBatchWindow,
	g_cRestMin,					// v2.0.0 波间三态
	g_cRestMax,
	g_cRestForce,
	g_cRestPerfMin,				// v6.3.0 完美剿灭奖励区间
	g_cRestPerfMax,
	g_cPerfectHealthBonus,		// v6.6.0 完美剿灭实血奖励（+5实血，虚实合计≤100，满额虚转实）
	g_cCompRestBonus,			// v6.7.0 补偿剿灭下一波冷静期额外秒数
	g_cCompNextTankChance,		// v6.7.0 补偿剿灭下一波Tank概率覆盖（共享给 tank_mutator）
	// v2.5.0 剿灭得分（三档互斥, 波次清缴完成时全体生还者每人得分）
	g_cClearScoreBase,
	g_cClearScorePerfect,
	g_cClearScoreComp,
	g_cClearCompRatio,
	g_cClearTankMult,
	// v2.5.1 剿灭得分时间倍率（用户设计: 刷新播报起 1.5×, 每秒 -0.015, 下限 1.0）
	g_cClearTimeMultStart,
	g_cClearTimeMultDecay,
	// v6.2.0 损失率补偿：系统处决占比 → 冷静期压缩 + 剿灭得分补偿
	g_cLossCompEnable,
	g_cLossRestScale,
	g_cLossRestMin,
	g_cLossScoreScale;

float
	g_fSpawnTimeMin,
	g_fSpawnTimeMax,
	g_fExtraLimit,
	g_fExtraSize,
	g_fSuicideTime,
	g_fRushDistance,
	g_fFirstSpawnTime,
	g_fSpawnTimes[MAXPLAYERS + 1],
	g_fActionTimes[MAXPLAYERS + 1],
	g_fIncapCompensation,
	g_fDirFront,
	g_fDirMid,
	g_fDirBack,
	g_fDirSplitSpread,
	g_fDirSplitGap,
	g_fBatchInterval,			// v2.0.0 本波批间隔（= 窗口/批数, 钳 [5,10]，跨 timer 存活）
	g_fPhaseEnterTime,			// v2.0.0 压力期开始时刻（收尾期 120s 硬上限锚点）
	g_fWaveStartTime,			// v2.5.1 波次开始时刻（剿灭得分时间倍率起算; retry 波不重置）
	g_bRandomDirection,
	// v6.1.2 LOS + 距离过滤恢复: v6.1.0 过度信任引擎(无 LOS/距离检查) → 幽灵处决率高;
	// 恢复"可见优先 + 不可见最近兜底 + 距离 ≥ guard_min(250) 硬门"轻过滤, 不做 v6.0.0 复杂打分.
	// v6.1.0 信任引擎方案: 参数缓存
	g_fNavPathMax,				// NavPath 快速重试保护①: 候选点到目标的最大路径长度
	g_fOrigSafetyRange,			// v6.1.1: 覆盖前保存的 z_spawn_safety_range 原值(OnMapEnd 恢复用)
	g_fTargetInjectTime,
	g_fRecoverTime,
	g_fRelocateTime,
	// v6.0.2: 波次泄气推进 + 场上无 SI 计时
	g_fStallAdvance,
	g_fWaveNoSITime,
	// v6.2.0 损失率补偿参数缓存
	g_fLossRestScale,
	g_fLossRestMin,
	g_fLossScoreScale;

static const char
	g_sZombieClass[SI_MAX_SIZE][] = {
		"smoker",
		"boomer",
		"hunter",
		"spitter",
		"jockey",
		"charger"
	};

int
	g_iSILimit,
	g_iSpawnSize,
	g_iDirection,
	g_iCandidateSamples,		// v6.0.0 采样候选数缓存
	g_iSpawnLimits[SI_MAX_SIZE],
	g_iSpawnWeights[SI_MAX_SIZE],
	g_iSpawnTimeMode,
	g_iTankStatusAction,
	g_iSILimitCache = -1,
	g_iSpawnLimitsCache[SI_MAX_SIZE] = {	
		-1,
		-1,
		-1,
		-1,
		-1,
		-1
	},
	g_iSpawnWeightsCache[SI_MAX_SIZE] = {
		-1,
		-1,
		-1,
		-1,
		-1,
		-1
	},
	g_iTankStatusLimits[SI_MAX_SIZE] = {	
		-1,
		-1,
		-1,
		-1,
		-1,
		-1
	},
	g_iTankStatusWeights[SI_MAX_SIZE] = {	
		-1,
		-1,
		-1,
		-1,
		-1,
		-1
	},
	g_iSpawnSizeCache = -1,
	g_iSpawnCounts[SI_MAX_SIZE],
	g_iBaseLimit,
	g_iBaseSize,
	g_iCurrentClass = -1,
	// v1.7.0 三段定向：每只特感的段类型（0=前/1=中/2=后）
	g_iSegs[MAX_WAVE],
	// v1.7.0 分批状态（跨 timer 存活）
	g_iSliceCursor,
	g_iSliceEnd,
	g_iSliceCaller,			// v6.4.0: 逐帧切片发起方(0=首发/1=续批)
	g_iBatchNext,
	g_iBatchTotal,
	g_iBatchBatchSize,
	g_iBatchSuccess,
	g_iBatchGuardBlocked,
	g_iBatchGuardVis,
	g_iBatchGuardInvis,
	g_iBatchGuardInvisNear,		// v2.6.0 幽灵修复: B 档（[guard_min, invis_min) 极端兜底）计数
	g_iBatchGuardInvisCount,	// v2.6.0 幽灵修复: invis 兜底放行总数（距离均值用）
	g_iBatchGuardTrap,			// v6.0.3: 被伤害触发器(陷阱)硬拒的候选数（环境死亡观测）
	g_iBatchSegA,				// 中段参照子集起点（前段结束处）
	g_iBatchSegB,				// 后段参照子集起点（最后自然段起点）
	// v6.0.0 调研落地: 阻塞槽位欠账（失败不扣波次预算）——本波被 Hard Gate 拦下的槽位数,
	// 首发完成后 1s 内 catch-up 重采样补上（不消耗 reserve、不计入击杀阈值）
	g_iBatchDebt,
	// v6.1.4 分散刷：本波已刷点位（防挤一处，透视可见聚堆）
	g_iBatchSpawnPosCount,
	// v2.0.0 收尾期清剿阈值: 场上存活 ≤ 该值进入冷静期（= max(2, 本波刷新量×40%)）
	g_iClearThreshold,
	// v2.5.0 剿灭得分: 波次开始时生还队人数快照（含 bot）+ 波内倒地/死亡去重人数
	g_iWaveBase,
	g_iWaveDownDeaths,
	// v5.33: 70/30 Wave Budget — 首发 70% + 补位 30%
	g_iWaveBudget,			// 本波总预算（= spawnSize）
	g_iWaveInitial,			// 首发数量（= ceil(budget * 0.7)）
	g_iWaveReserve,			// 剩余补位数量（初始 = budget - initial，击杀一只减一）
	g_iWaveKills,			// 波内 SI 击杀计数
	g_iWaveReserveSpawned,	// 已补刷数量（日志用）
	g_iWaveSICount,			// v5.33: 波次内 SI 序号（每波从 1 开始）
	// v5.33: SI 生命周期追踪（日志用）
	g_iSIWaveID[MAXPLAYERS + 1],		// client → 波次内序号（每波重置）
	g_iSIWaveNum[MAXPLAYERS + 1],	// client → 所属波次
	g_iSIClass[MAXPLAYERS + 1],		// client → class
	// v6.0.0 调研落地: 幽灵看门狗 SI 进展追踪
	g_iSITarget[MAXPLAYERS + 1],	// client → 本只 SI 的 intended target survivor
	// v6.0.1 坠落修复①: 目标分散——本波每名生还者已被选为 target 的次数(round-robin 最少优先)
	g_iTargetCounts[MAXPLAYERS + 1];

float
	g_fSISpawnTime[MAXPLAYERS + 1],	// client → 生成时间
	g_fSILastNavDist[MAXPLAYERS + 1],	// v6.0.0 看门狗: 上次到目标的 NavTravelDistance(-1=未测量)
	g_fBatchSpawnPos[48][3];	// v6.1.4 分散刷：本波已刷点位

bool
	g_bLateLoad,
	g_bInSpawnTime,
	g_bScaleWeights,
	g_bLeftSafeArea,
	g_bFinaleStarted,
	g_bTargetInject,			// v6.0.0 出生目标注入开关缓存
	// v1.7.0 分批状态
	g_bBatchSegs,				// 本波是否启用三段定向
	g_bBatchRetry,				// 本波是否 retry 波（整波零成功时 1s 后重试）
	g_bBatchFind,				// 本波是否 rusher（跑图）
	// v6.0.0 调研落地: 本波已做过一次 catch-up（每波至多一次）
	g_bBatchCatchup,
	// v2.2.0 清缴挂起标志（外部插件控制，Tank 波等场景强制等待条件满足）
	g_bClearingHeld,
	// v2.4.0 刷新暂停标志（外部插件控制，火力支援 AGM 等场景临时暂停刷新）
	g_bSpawningPaused,
	// v2.5.0 剿灭得分: 波内统计
	g_bWaveActive,					// 本波进行中（PRESSURE/CLEARING，波外倒地不计入）
	g_bWaveStarted,					// 本波真的刷出特感（零波不发分）
	g_bWaveHadTank,					// 本波是 Tank 波（tank_wave_mutator 调 SS_MarkWaveTank 置位）
	g_bWaveDowned[MAXPLAYERS + 1],	// 波内倒地/死亡去重标记
	g_bSIInjected[MAXPLAYERS + 1],	// v6.0.0 本只 SI 是否处于目标注入状态(生效期间)
	g_bSIRecovered[MAXPLAYERS + 1],	// v6.0.0 本只 SI 是否已做过 retarget(recover 修理)
	g_bSIRelocated[MAXPLAYERS + 1],	// v6.0.0 本只 SI 是否已做过 unstick/relocate 修理
	g_bLossCompEnable;			// v6.2.0 损失率补偿开关缓存

// v5.33: 全局波次计数（日志用）——独立声明，避免被上面 bool 声明块吞成 bool（历史 bug）
int g_iWaveNumber;
int g_iWaveSystemKills;		// v6.2.0 本波系统处决数（非玩家击杀）
float g_fWaveLossRate;			// v6.2.0 本波损失率缓存（0-1，用于冷静期+得分）

// v2.0.0 波间三态: 当前相位（初始 = IDLE）
WavePhase
	g_Phase;

// v2.4.0 刷新暂停计时器句柄
Handle g_hPauseTimer;
// v2.4.3 暂停期间主动清理 timer（每秒杀掉新刷的特感，因 director_no_specials 是 cheat 无法用）
Handle g_hPauseCleanupTimer;
// v5.33: reserve 等待超时兜底 timer
Handle g_hReserveTimer;
// v6.0.0 调研落地: 出生目标注入 RESET timer（每只 SI 一个，防重叠）+ 阻塞槽位欠账 catch-up timer
Handle g_hSIInjectTimer[MAXPLAYERS + 1];
Handle g_hCatchupTimer;

// v1.7.0 参照者/flow 数组（全局持有——分批跨 timer 续刷需要存活）
int
	g_iBatchSurvivors[MAXPLAYERS + 1],
	g_iBatchSurvivorCount;
float
	g_fBatchFlows[MAXPLAYERS + 1],
	g_fBatchGuardInvisDistSum;	// v2.6.0 幽灵修复: invis 兜底放行点距离累计（日志均值）

public Plugin myinfo = {
	name = "Special Spawner",
	author = "Tordecybombo, breezy",
	description = "Provides customisable special infected spawing beyond vanilla coop limits",
	version = "6.7.0",		// v6.7.0 补偿剿灭惩罚: 下波冷静期+6s，Tank基础概率3%
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	g_bLateLoad = late;
	// v2.2.0 暴露 native: 外部插件可挂起清缴（Tank 波要求 Tank 死亡才结束清缴）
	CreateNative("SS_HoldClearing", Native_HoldClearing);
	// v2.4.0 暴露 native: 外部插件可暂停刷新（火力支援 AGM 等清场技能）
	CreateNative("SS_PauseSpawning", Native_PauseSpawning);
	// v2.5.0 暴露 native: tank_wave_mutator 标记本波为 Tank 波（突变 Tank 波剿灭得分 ×3）
	CreateNative("SS_MarkWaveTank", Native_MarkWaveTank);
	// v2.5.0 剿灭得分: si_hud 钱包 native 标记可选（si_hud 未加载时本插件照常工作）
	MarkNativeAsOptional("SH_AddWallet");
	RegPluginLibrary("specialspawner");
	return APLRes_Success;
}

// v2.2.0 native: SS_HoldClearing(bool hold)
// hold=true: 收尾期不进 REST（无视特感数/120s硬上限），直到调用方置 false
// 用途: Tank 波期间强制清缴条件 = Tank 死亡（由 tank_wave_mutator 控制）
int Native_HoldClearing(Handle plugin, int numParams) {
	g_bClearingHeld = GetNativeCell(1) != 0;
	LogMessage("[SS] Clearing hold %s (external)", g_bClearingHeld ? "SET" : "RELEASED");
	return 0;
}

// v2.5.0 native: SS_MarkWaveTank()
// tank_wave_mutator 在突变 Tank 波成功生成 Tank 后调用，标记"本波是 Tank 波"，
// 波次清缴结算时剿灭得分 ×ss_clear_tank_mult。仅对当前波次生效（波次开始自动清零）。
int Native_MarkWaveTank(Handle plugin, int numParams) {
	g_bWaveHadTank = true;
	LogMessage("[SS] Wave marked as TANK wave (external)");
	return 0;
}

// v2.5.4: 暂停期间冻结冷静期倒计时（用户实测洞察：爆炸恰好撞上波次剿灭 →
// 冷静期本来就不刷特感，暂停 20s 被冷静期覆盖 = 无额外价值；冻结后暂停是
// "从当前状态额外 +N 秒安静"，暂停结束冷静期续走）。
void SS_FreezeWaveTimers() {
	if (g_fRestFrozenRemaining > 0.0) return; // 已冻结，避免二次覆盖
	g_fRestFrozenRemaining = 0.0;
	if (g_Phase == PHASE_REST && g_hRestTimer != null && IsValidHandle(g_hRestTimer)) {
		float remaining = g_fRestEndTime - GetEngineTime();
		if (remaining < 0.1)
			remaining = 0.1;
		delete g_hRestTimer;
		g_hRestTimer = null;
		g_fRestFrozenRemaining = remaining;
		LogMessage("[SS] REST frozen by external pause (%.1fs remaining)", remaining);
	}
}

void SS_UnfreezeWaveTimers() {
	if (g_fRestFrozenRemaining > 0.0 && g_hRestTimer == null) {
		g_hRestTimer = CreateTimer(g_fRestFrozenRemaining, tmrRestEnd);
		g_fRestEndTime = GetEngineTime() + g_fRestFrozenRemaining;
		LogMessage("[SS] REST resumed after external pause (%.1fs)", g_fRestFrozenRemaining);
	}
	g_fRestFrozenRemaining = 0.0;
}

// v2.4.0 native: SS_PauseSpawning(float seconds)
// 暂停特感刷新 N 秒（外部插件调用，如火力支援 AGM 爆炸清场）
// seconds: 暂停秒数（调用时重置计时器，最后一次调用生效）
// 用途: 火力支援 AGM 导弹爆炸后暂停刷新 20 秒，给玩家喘息时间
// v2.4.3: director_no_specials 是 cheat 无法用，改用主动清理（每秒杀新刷特感）
// v2.5.3: **director_no_specials 实测非 cheat**（SM 1.12 RCON 可直设，2026-08-16
// 实锤）——v2.4.3 判断错误。暂停时直接设 1 真停导演特感（+ 每秒清理兜底），
// 恢复时还原原值。此前"假暂停"根因：只拦了本插件波次，导演特感照刷，
// 且清理对 ghost 特感无效（14:23/14:29 两次暂停 cleanup killed=0）。
int Native_PauseSpawning(Handle plugin, int numParams) {
	float seconds = GetNativeCell(1);
	if (seconds <= 0.0) {
		g_bSpawningPaused = false;
		delete g_hPauseTimer;
		delete g_hPauseCleanupTimer;
		SS_RestoreDirectorSpecials();
		SS_UnfreezeWaveTimers();   // v2.5.4: 解冻冷静期
		LogMessage("[SS] Spawning pause CLEARED (external)");
		return 0;
	}

	g_bSpawningPaused = true;
	delete g_hPauseTimer;
	delete g_hPauseCleanupTimer;
	g_hPauseTimer = CreateTimer(seconds, Timer_UnpauseSpawning, _, TIMER_FLAG_NO_MAPCHANGE);
	g_hPauseCleanupTimer = CreateTimer(1.0, Timer_PauseCleanup, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	SS_PauseDirectorSpecials();
	SS_FreezeWaveTimers();       // v2.5.4: 冻结冷静期（暂停 = 额外安静）
	LogMessage("[SS] Spawning PAUSED for %.1f seconds (external, director_no_specials + active cleanup)", seconds);
	return 0;
}

// v2.5.3: 暂停导演特感刷新——director_no_specials=1（记录原值，恢复时还原）。
// 只影响导演的原生特感生成；specialspawner 波次由 g_bSpawningPaused 拦截；
// Tank 波/玩家特感不受影响。
int g_iDirectorSpecialsPrev = -1;   // -1 = 未记录

void SS_PauseDirectorSpecials() {
	ConVar cv = FindConVar("director_no_specials");
	if (cv == null)
		return;
	if (g_iDirectorSpecialsPrev == -1) g_iDirectorSpecialsPrev = cv.IntValue;
	cv.IntValue = 1;
	LogMessage("[SS] director_no_specials %d -> 1 (pause)", g_iDirectorSpecialsPrev);
}

void SS_RestoreDirectorSpecials() {
	ConVar cv = FindConVar("director_no_specials");
	if (cv == null)
		return;
	if (g_iDirectorSpecialsPrev >= 0) {
		cv.IntValue = g_iDirectorSpecialsPrev;
		LogMessage("[SS] director_no_specials -> %d (restore)", g_iDirectorSpecialsPrev);
	} else {
		cv.IntValue = 0;
		LogMessage("[SS] director_no_specials -> 0 (restore, no prior value)");
	}
	g_iDirectorSpecialsPrev = -1;
}

// v2.4.0 计时器回调：暂停时间到，恢复刷新
// v2.4.3: 停止主动清理 timer
// v2.5.3: 同时还原 director_no_specials
Action Timer_UnpauseSpawning(Handle timer) {
	g_hPauseTimer = null;
	g_bSpawningPaused = false;
	delete g_hPauseCleanupTimer;
	SS_RestoreDirectorSpecials();
	SS_UnfreezeWaveTimers();   // v2.5.4: 解冻冷静期（续走剩余倒计时）
	LogMessage("[SS] Spawning pause EXPIRED, resuming normal spawn");
	return Plugin_Stop;
}

// v2.4.3 计时器回调：暂停期间主动清理新刷的特感（director_no_specials 是 cheat 无法用）
// 每秒遍历所有 bot 特感，杀掉导演刷新的（保留玩家控制的特感 + Tank）
// Tank 排除：Tank 只应被实际伤害击杀，凭空清理会让玩家觉得诡异（还丢击杀分）
Action Timer_PauseCleanup(Handle timer) {
	if (!g_bSpawningPaused) {
		g_hPauseCleanupTimer = null;
		return Plugin_Stop;
	}

	int killed = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		if (GetClientTeam(i) != 3)
			continue;
		if (!IsFakeClient(i))
			continue;  // 保留玩家控制的特感

		// 排除 Tank（class 8）——只清理普通特感
		int zClass = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (zClass == 8)
			continue;

		// 杀掉 bot 特感（导演刷新的）
		ForcePlayerSuicide(i);
		killed++;
	}

	if (killed > 0)
		LogMessage("[SS] Pause cleanup: killed %d director-spawned SI", killed);

	return Plugin_Continue;
}

public void OnPluginStart() {
	g_cSILimit	= 					CreateConVar("ss_si_limit",				"12",						"同时存在的最大特感数量", _, true, 1.0, true, 48.0);
	g_cSpawnSize = 					CreateConVar("ss_spawn_size",			"10",					"一次产生多少只特感（基准=4人时数量；用户设计=人数×2.5 最少10）", _, true, 1.0, true, 32.0);
	g_cSpawnLimits[SI_SMOKER] = 	CreateConVar("ss_smoker_limit",			"2",						"同时存在的最大smoker数量", _, true, 0.0, true, 32.0);
	g_cSpawnLimits[SI_BOOMER] = 	CreateConVar("ss_boomer_limit",			"2",						"同时存在的最大boomer数量", _, true, 0.0, true, 32.0);
	g_cSpawnLimits[SI_HUNTER] = 	CreateConVar("ss_hunter_limit",			"4",						"同时存在的最大hunter数量", _, true, 0.0, true, 32.0);
	g_cSpawnLimits[SI_SPITTER] = 	CreateConVar("ss_spitter_limit",		"2",						"同时存在的最大spitter数量", _, true, 0.0, true, 32.0);
	g_cSpawnLimits[SI_JOCKEY] = 	CreateConVar("ss_jockey_limit",			"4",						"同时存在的最大jockey数量", _, true, 0.0, true, 32.0);
	g_cSpawnLimits[SI_CHARGER] = 	CreateConVar("ss_charger_limit",		"4",						"同时存在的最大charger数量", _, true, 0.0, true, 32.0);

	g_cSpawnWeights[SI_SMOKER] =	CreateConVar("ss_smoker_weight",		"100",						"smoker产生比重", _, true, 0.0);
	g_cSpawnWeights[SI_BOOMER] =	CreateConVar("ss_boomer_weight",		"200",						"boomer产生比重", _, true, 0.0);
	g_cSpawnWeights[SI_HUNTER] =	CreateConVar("ss_hunter_weight",		"100",						"hunter产生比重", _, true, 0.0);
	g_cSpawnWeights[SI_SPITTER] =	CreateConVar("ss_spitter_weight",		"200",						"spitter产生比重", _, true, 0.0);
	g_cSpawnWeights[SI_JOCKEY] =	CreateConVar("ss_jockey_weight",		"100",						"jockey产生比重", _, true, 0.0);
	g_cSpawnWeights[SI_CHARGER] =	CreateConVar("ss_charger_weight",		"100",						"charger产生比重", _, true, 0.0);
	g_cScaleWeights =				CreateConVar("ss_scale_weights",		"1",						"缩放相应特感的产生比重 [0 = 关闭 | 1 = 开启](开启后,总比重越大的越容易先刷出来, 动态控制特感刷出顺序)", _, true, 0.0, true, 1.0);
	g_cSpawnTimeMin =				CreateConVar("ss_time_min",				"10.0",						"特感的最小产生时间", _, true, 0.1);
	g_cSpawnTimeMax =				CreateConVar("ss_time_max",				"15.0",						"特感的最大产生时间", _, true, 1.0);
	g_cSpawnTimeMode =				CreateConVar("ss_time_mode",			"1",						"特感的刷新时间模式[0 = 随机 | 1 = 递增(杀的越快刷的越快) | 2 = 递减(杀的越慢刷的越快)]", _, true, 0.0, true, 2.0);

	g_cBaseLimit =					CreateConVar("ss_base_limit",			"4",						"生还者团队不超过4人时有多少个特感", _, true, 0.0, true, 32.0);
	g_cExtraLimit =					CreateConVar("ss_extra_limit",			"1",						"生还者团队每增加一人可增加多少个特感", _, true, 0.0, true, 32.0);
	g_cBaseSize =					CreateConVar("ss_base_size",			"4",						"生还者团队不超过4人时一次产生多少只特感", _, true, 0.0, true, 32.0);
	g_cExtraSize =					CreateConVar("ss_extra_size",			"2",						"生还者团队每增加多少玩家人一次多产生一只特感", _, true, 1.0, true, 32.0);
	g_cTankStatusAction =			CreateConVar("ss_tankstatus_action",	"1",						"坦克产生后是否对当前刷特参数进行修改, 坦克死完后恢复?[0 = 忽略(保持原有的刷特状态) | 1 = 自定义]", _, true, 0.0, true, 1.0);
	g_cTankStatusLimits =			CreateConVar("ss_tankstatus_limits",	"2;1;4;1;4;4",				"坦克产生后每种特感数量的自定义参数");
	g_cTankStatusWeights =			CreateConVar("ss_tankstatus_weights",	"100;400;100;200;100;100",	"坦克产生后每种特感比重的自定义参数");
	g_cSuicideTime =				CreateConVar("ss_suicide_time",			"25.0",						"特感自动处死时间", _, true, 1.0);
	g_cRushDistance =				CreateConVar("ss_rush_distance",		"1500.0",					"路程超过多少算跑图(最前面的玩家路程减去最后面的玩家路程, 忽略倒地玩家)", _, true, 0.0);

	g_cSpawnRangeMin =				CreateConVar("ss_spawnrange_min",		"100.0",					"特感最小生成距离", _, true, 0.0);
	g_cSpawnRangeMax =				CreateConVar("ss_spawnrange_max",		"1500.0",					"特感最大生成距离", _, true, 0.0);
	// v6.1.0: ss_spawnrange_guard/guard_min 仅保留注册作观测阈值（FinishWave 日志
	// 统计落点距离分档），不再作为筛选条件——距离交给引擎 z_spawn_safety_range 语义。
	g_cSpawnRangeGuard =			CreateConVar("ss_spawnrange_guard",		"350.0",					"[v6.1.0仅观测] 落点距离观测阈值(引擎距离语义由 z_spawn_safety_range 负责)", _, true, 0.0, true, 1500.0);
	// v1.3.9 保底阈值注释已废弃；保留注册防旧 cfg 报错。
	g_cSpawnRangeGuardMin =			CreateConVar("ss_spawnrange_guard_min",	"250.0",					"[v6.1.0仅观测] 落点最近距离观测阈值下限", _, true, 0.0, true, 1500.0);
	g_cSpawnDistMax =				CreateConVar("ss_spawn_dist_max",		"1200.0",					"v6.4.2: 生成距离上限——开阔地防刷出过远被闲置处决", _, true, 400.0, true, 3000.0);
	// v6.5.0 点位人性化三件套（2026-08-26 实测日志驱动）:
	//   实测 failClose=24 全灭: 08-23 达 803 次/日 —— 玩家抱团时引擎采样器只能在
	//   同一口袋出点, 波内两两间隔 250u 几何不可能 → 候选全灭 → 欠账饿死(播报有怪没威胁)。
	//   A) 分散降级(ss_spawn_spread_floor): 被分散规则拒掉的候选进降级池(离已刷点最远者胜),
	//      主池全灭且 spread 主导时按保底间隔放行;
	//   B) 不可见兜底距离上限(ss_spawn_invis_max_dist): 更远的不可见点出生即注定
	//      25s 自杀处决(实测处决样本中位 dist=828 全部 visible=0), 宁可欠账重试;
	//   C) 可见性评估提前到分散检查之前: 被拒的可见点也能进降级池。
	g_cSpreadFloor =				CreateConVar("ss_spawn_spread_floor",	"120.0",					"v6.5.0 分散降级保底间隔: 抱团场景候选被分散规则全拒时, 降级采用'离已刷点最远'候选的最低间隔 [u]", _, true, 0.0, true, 250.0);
	g_cInvisMaxDist =				CreateConVar("ss_spawn_invis_max_dist",	"900.0",					"v6.5.0 不可见兜底距离上限: 超过该距离的不可见候选不采用(出生即注定闲置处决), 宁可欠账重试 [u]", _, true, 400.0, true, 3000.0);
	// v2.6.0 幽灵修复双阈值（防贴脸偏好层）——v6.0.0 起语义废弃（报告 §16）：
	// 不再决定 fallback 等级，仅保留注册防旧 cfg 报错；丢弃 handle 不持有。
	CreateConVar("ss_spawnrange_guard_invis_min",	"350.0",	"[已废弃] 原不可见兜底A档下限，v6.0.0 起不再使用，仅保留注册", _, true, 0.0, true, 1500.0);
	CreateConVar("ss_spawnrange_guard_invis_max",	"550.0",	"[已废弃] 原不可见兜底距离上限，v6.0.0 起不再使用，仅保留注册", _, true, 0.0, true, 1500.0);

	// ===================== v6.1.0 信任引擎方案 =====================
	// v6.0.0 的 Hard Gate + Soft Score(vs 官方候选打分) 已废弃: 实测"二次过滤+打分排序"
	// 打破 Director PZ 候选分布 → 选出奇怪点位被处决。改为社区 InfectedBots 哲学的
	// "信任引擎取点": 以 target 为参照直接 L4D_GetRandomPZSpawnPosition, 只留两条
	// 快速重试保护(trigger_hurt 陷阱 / NavPath 不通), 其余质量判定全交引擎。
	g_cCandidateSamples =		CreateConVar("ss_spawn_candidate_samples",	"16.0",		"引擎取点+保护重试轮数: 每只特感在 target 周围调 L4D_GetRandomPZSpawnPosition 的尝试次数(越高越不易欠账, 也越耗CPU) [8|16|24]", _, true, 2.0, true, 48.0);
	g_cNavPathMax =				CreateConVar("ss_spawn_nav_path_max",		"5000.0",	"快速重试保护②: 候选点到目标生还者的 infected NavPath 最大长度限制(超过=不可达, 重试)", _, true, 500.0, true, 20000.0);
	g_cNavTravelPrefMin =		CreateConVar("ss_spawn_nav_travel_preferred_min", "0.0",	"[已废弃] v6.0.0 Soft Score 项, v6.1.0 起不再使用, 仅保留注册防旧cfg报错", _, true, 0.0, true, 10000.0);
	g_cNavTravelPrefMax =		CreateConVar("ss_spawn_nav_travel_preferred_max", "3000.0",	"[已废弃] v6.0.0 Soft Score 项, v6.1.0 起不再使用, 仅保留注册防旧cfg报错", _, true, 0.0, true, 10000.0);
	g_cFlowDeltaPref =			CreateConVar("ss_spawn_flow_delta_preferred", "1500.0",	"[已废弃] v6.0.0 Soft Score 项, v6.1.0 起不再使用, 仅保留注册防旧cfg报错", _, true, 0.0, true, 20000.0);
	g_cTargetInject =			CreateConVar("ss_spawn_target_inject",		"1",		"出生目标注入: SI 出生后 L4D2_CommandABot(ATTACK 指定目标, 可绕过 BOT_CANT_SEE), 数秒后 RESET 交还 AI [1=开|0=关]", _, true, 0.0, true, 1.0);
	g_cTargetInjectTime =		CreateConVar("ss_spawn_target_inject_time",	"1.5",		"目标注入持续秒数: 到期 L4D2_CommandABot(RESET) 交还原版/AI_HardSI", _, true, 0.2, true, 10.0);
	g_cRecoverTime =			CreateConVar("ss_spawn_recover_time",		"7.0",		"幽灵看门狗: 无行动进展 T 秒后重新分配目标 + 重新注入(可绕过感知)", _, true, 2.0, true, 60.0);
	g_cRelocateTime =			CreateConVar("ss_spawn_relocate_time",		"14.0",		"幽灵看门狗: 仍无进展 T 秒后 L4D_WarpToValidPositionIfStuck 换位 + 重新注入", _, true, 3.0, true, 120.0);
	g_cStallAdvance = 			CreateConVar("ss_wave_stall_advance",		"6.0",		"PRESSURE 期场上一只 SI 都没有且击杀未达标持续该秒数 → 强制 FinishWave 推进下一波(0=关闭)", _, true, 0.0, true, 60.0);

	g_cFirstSpawnTime = 			CreateConVar("ss_first_time",			"0.0",						"玩家离开安全区域后第一波特感的刷新时间", _, true, 0.0);
	// v1.5.0: 倒地补偿强度 [0-1]。1 = 全比例（波次与上限 ×站立/总人数），0 = 关闭，
	// 0-1 = 线性插值。实时计算，复活后下一波自动恢复。
	g_cIncapCompensation =			CreateConVar("ss_incap_compensation",	"1.0",						"倒地补偿强度: 刷怪时按站立/总人数比例收缩本波数量与有效上限 [0=关闭|1=全比例]", _, true, 0.0, true, 1.0);
	// v1.6.0: 普通波次刷怪方向 [1=引擎随机(-1, 各方向随机) | 0=固定大体积(旧行为, 实测全正前方)]
	g_cRandomDirection =			CreateConVar("ss_random_direction",		"1",						"普通波次刷怪方向: 1=引擎随机(各方向) | 0=固定大体积(旧: 只会正前方)", _, true, 0.0, true, 1.0);
	// v1.7.0 三段定向刷新（单面受敌修复）：队伍拉长时把本波特感按权重分配到
	// 前/中/后三段，每只独立方向+独立参照者。前段=正前方拦截(领队压力减半以上)、
	// 中段=侧翼包抄(中部玩家有目标)、后段=身后断后(尾部玩家被迫参战)。
	// 段边界按 flow gap 自然切（蛇形/断裂队伍每段都吃特感），权重只决定数量分配。
	g_cDirFront =					CreateConVar("ss_dir_front",			"40",						"三段定向: 前段(正前方拦截)权重 [%]", _, true, 0.0, true, 100.0);
	g_cDirMid =						CreateConVar("ss_dir_mid",				"30",						"三段定向: 中段(侧翼随机)权重 [%]", _, true, 0.0, true, 100.0);
	g_cDirBack =					CreateConVar("ss_dir_back",				"30",						"三段定向: 后段(身后断后)权重 [%]", _, true, 0.0, true, 100.0);
	g_cDirSplitSpread =				CreateConVar("ss_dir_split_spread",		"400.0",					"三段定向: 队伍前后 flow 总差(单位)低于该值视为紧凑队伍, 不分段保持原逻辑(防贴脸)", _, true, 0.0);
	g_cDirSplitGap =				CreateConVar("ss_dir_split_gap",			"400.0",					"三段定向: 相邻生还者 flow 差超过该值视为队伍断裂, 段边界在此断开(蛇形/断裂队伍适配)", _, true, 0.0);
	// v2.0.0 批次引擎（替换 ss_wave_split/_interval）: 战术小队 4 只/批,
	// 批数 = ceil(波次/批大小) 钳 [1, 批数上限]，批间隔 = 窗口/批数 钳 [5,10]
	// ——任意人数都在窗口内出完, 批内三段再平衡多点位输出
	g_cBatchSize =					CreateConVar("ss_batch_size",			"4",						"波内每批特感数量(战术小队规模)", _, true, 1.0, true, 32.0);
	g_cBatchMax =					CreateConVar("ss_batch_max",			"5",						"波内最大批数", _, true, 1.0, true, 8.0);
	g_cBatchWindow =				CreateConVar("ss_batch_window",			"20.0",						"波内批次总释放窗口(秒), 批间隔=窗口/批数 钳制[5,10]", _, true, 5.0, true, 60.0);
	// v2.0.0 波间三态（压力/收尾/冷静）: 收尾期场上存活 ≤ 波次×40% 或
	// ss_rest_force 硬上限 → 冷静期零特感压力（缓冲节点）→ 下一波
	g_cRestMin =					CreateConVar("ss_rest_min",				"20.0",						"冷静期最小时长(秒, 零特感缓冲窗口)", _, true, 1.0, true, 60.0);
	g_cRestMax =					CreateConVar("ss_rest_max",				"30.0",						"冷静期最大时长(秒)", _, true, 1.0, true, 60.0);
	g_cRestForce =					CreateConVar("ss_rest_force",			"120.0",					"收尾期强制冷静硬上限(秒, 自波次开始计, 防留特/僵局)", _, true, 10.0, true, 600.0);
	// v6.3.0 完美剿灭奖励: 波内无人倒地/死亡 → 冷静期改抽 20-30s
	g_cRestPerfMin =				CreateConVar("ss_rest_perfect_min",		"20.0",						"完美剿灭奖励: 冷静期下限(波内无人倒地/死亡)", _, true, 1.0, true, 60.0);
	g_cRestPerfMax =				CreateConVar("ss_rest_perfect_max",		"30.0",						"完美剿灭奖励: 冷静期上限", _, true, 1.0, true, 60.0);
	// v6.6.0 完美剿灭实血奖励: 达成完美剿灭时全体存活且站立的生还者 +5实血，实+虚≤100，满额时虚转实
	g_cPerfectHealthBonus =			CreateConVar("ss_perfect_health_bonus",	"5",						"完美剿灭实血奖励: 完美时每人+实血数(0=关闭)", _, true, 0.0, true, 100.0);
	// v6.7.0 补偿剿灭惩罚: 损伤过多→下一波冷静期+6s，Tank基础概率3%
	g_cCompRestBonus =				CreateConVar("ss_comp_rest_bonus",		"6.0",						"补偿剿灭下一波冷静期额外秒数", _, true, 0.0, true, 60.0);
	g_cCompNextTankChance =			CreateConVar("ss_comp_next_tank_chance","-1.0",						"补偿剿灭下一波Tank概率覆盖(-1=用默认)", _, true, -1.0, true, 1.0);
	// v2.5.0 剿灭得分（用户设计 2026-08-17）: 波次清缴完成时全体生还者每人得分, 三档互斥:
	// 完美（波内无人倒地/死亡）> 补偿（倒地/死亡 ≥ 队伍人数×ss_clear_comp_ratio）> 基础（其余）。
	// Tank 波（tank_wave_mutator 突变, SS_MarkWaveTank）三档同乘 ss_clear_tank_mult。
	// 播报合并进"波次清剿完毕"消息: 本波次剿灭完成，<档位>全体+X分，下一波来袭X秒。
	g_cClearScoreBase =			CreateConVar("ss_clear_score_base",		"200",						"剿灭得分-基础档: 正常清缴波次全体每人得分(0=关闭剿灭得分)", _, true, 0.0);
	g_cClearScorePerfect =		CreateConVar("ss_clear_score_perfect",	"350",						"剿灭得分-完美档: 波内无人倒地/死亡时全体每人得分", _, true, 0.0);
	g_cClearScoreComp =			CreateConVar("ss_clear_score_comp",		"275",						"剿灭得分-补偿档: 波内倒地/死亡≥队伍比例时全体每人得分", _, true, 0.0);
	g_cClearCompRatio =			CreateConVar("ss_clear_comp_ratio",		"0.30",						"剿灭补偿触发: 波内倒地/死亡去重人数 ≥ 队伍人数×本比例", _, true, 0.0, true, 1.0);
	g_cClearTankMult =			CreateConVar("ss_clear_tank_mult",		"3.0",						"Tank 波剿灭得分倍率(三档同乘)", _, true, 1.0, true, 10.0);
	// v2.5.1 时间倍率（用户设计 2026-08-17）: 剿灭得分从特感刷新播报(波次开始)起算,
	// 倍率 = 起始 - 每秒衰减×经过秒数, 下限 1.0 —— 1.5 - 0.015/s ≈ 第 30s 恢复 1×。
	// 清剿越快奖励越高（替代已废弃的高光时刻加分方案）。
	g_cClearTimeMultStart =		CreateConVar("ss_clear_time_mult_start",	"1.5",						"剿灭得分时间倍率-起始值(波次刷新播报时刻)", _, true, 1.0, true, 5.0);
	g_cClearTimeMultDecay =		CreateConVar("ss_clear_time_mult_decay",	"0.015",					"剿灭得分时间倍率-每秒衰减量(下限1.0; 1.5-0.015/s≈30s回1×)", _, true, 0.0, true, 1.0);
	// v6.2.0 损失率补偿（系统处决占比 → 冷静期压缩 + 剿灭得分扣减）
	g_cLossCompEnable =			CreateConVar("ss_loss_comp_enable",		"1",						"损失率补偿开关: 1=启用(系统处决缩短冷静期+扣减得分) | 0=关闭", _, true, 0.0, true, 1.0);
	g_cLossRestScale =			CreateConVar("ss_loss_rest_scale",		"1.0",						"冷静期补偿系数: 修正后冷静期 = 原冷静期 * (1 - 损失率*系数), 1.0=30%损失压30%时间", _, true, 0.0, true, 2.0);
	g_cLossRestMin =				CreateConVar("ss_loss_rest_min",		"10.0",						"损失率补偿后冷静期最低秒数(保底, 防过短)", _, true, 1.0, true, 60.0);
	g_cLossScoreScale =			CreateConVar("ss_loss_score_scale",		"1.0",						"剿灭得分扣减系数: 扣减后得分 = 原得分 * (1 - 损失率*系数), 1.0=30%损失扣30%分(200→140)", _, true, 0.0, true, 2.0);

	g_cSpawnRange =					FindConVar("z_spawn_range");
	g_cDiscardRange =				FindConVar("z_discard_range");
	g_cSafeSpawnRange =				FindConVar("z_safe_spawn_range");

	g_cSpawnSize.AddChangeHook(CvarChanged_Limits);
	for (int i; i < SI_MAX_SIZE; i++) {
		g_cSpawnLimits[i].AddChangeHook(CvarChanged_Limits);
		g_cSpawnWeights[i].AddChangeHook(CvarChanged_General);
	}

	g_cSILimit.AddChangeHook(CvarChanged_Times);
	g_cSpawnTimeMin.AddChangeHook(CvarChanged_Times);
	g_cSpawnTimeMax.AddChangeHook(CvarChanged_Times);
	g_cSpawnTimeMode.AddChangeHook(CvarChanged_Times);

	g_cScaleWeights.AddChangeHook(CvarChanged_General);
	g_cBaseLimit.AddChangeHook(CvarChanged_General);
	g_cExtraLimit.AddChangeHook(CvarChanged_General);
	g_cBaseSize.AddChangeHook(CvarChanged_General);
	g_cExtraSize.AddChangeHook(CvarChanged_General);
	g_cSuicideTime.AddChangeHook(CvarChanged_General);
	g_cRushDistance.AddChangeHook(CvarChanged_General);
	g_cFirstSpawnTime.AddChangeHook(CvarChanged_General);
	g_cIncapCompensation.AddChangeHook(CvarChanged_General);
	g_cRandomDirection.AddChangeHook(CvarChanged_General);

	// v6.0.0 调研落地: Hard Gate + Soft Score 参数热更
	g_cCandidateSamples.AddChangeHook(CvarChanged_General);
	g_cNavPathMax.AddChangeHook(CvarChanged_General);
	g_cNavTravelPrefMin.AddChangeHook(CvarChanged_General);
	g_cNavTravelPrefMax.AddChangeHook(CvarChanged_General);
	g_cFlowDeltaPref.AddChangeHook(CvarChanged_General);
	g_cTargetInject.AddChangeHook(CvarChanged_General);
	g_cTargetInjectTime.AddChangeHook(CvarChanged_General);
	g_cRecoverTime.AddChangeHook(CvarChanged_General);
	g_cRelocateTime.AddChangeHook(CvarChanged_General);
	g_cStallAdvance.AddChangeHook(CvarChanged_General);
	g_cLossCompEnable.AddChangeHook(CvarChanged_General);
	g_cLossRestScale.AddChangeHook(CvarChanged_General);
	g_cLossRestMin.AddChangeHook(CvarChanged_General);
	g_cLossScoreScale.AddChangeHook(CvarChanged_General);

	g_cTankStatusAction.AddChangeHook(CvarChanged_TankStatus);
	g_cTankStatusLimits.AddChangeHook(CvarChanged_TankCustom);
	g_cTankStatusWeights.AddChangeHook(CvarChanged_TankCustom);

	AutoExecConfig(true, "specialspawner");//生成指定文件名的CFG.

	HookEvent("round_end",				Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("finale_vehicle_leaving", Event_RoundEnd,		EventHookMode_PostNoCopy);
	HookEvent("round_start",			Event_RoundStart,	EventHookMode_PostNoCopy);
	HookEvent("player_hurt",			Event_PlayerHurt);
	HookEvent("player_team",			Event_PlayerTeam);
	HookEvent("player_spawn",			Event_PlayerSpawn);
	HookEvent("player_death",			Event_PlayerDeath,	EventHookMode_Pre);
	// v2.5.0 剿灭得分: 波内倒地统计（去重）
	HookEvent("player_incapacitated",	Event_PlayerIncapacitated);

	RegAdminCmd("sm_weight",		cmdSetWeight,	ADMFLAG_RCON, "设置特感生成比重");
	RegAdminCmd("sm_limit",			cmdSetLimit,	ADMFLAG_RCON, "设置特感生成数量");
	RegAdminCmd("sm_timer",			cmdSetTimer,	ADMFLAG_RCON, "设置特感生成时间");

	RegAdminCmd("sm_resetspawn",	cmdResetSpawn,	ADMFLAG_RCON, "处死所有特感并重新开始生成计时");
	RegAdminCmd("sm_forcetimer",	cmdForceTimer,	ADMFLAG_RCON, "开始生成计时");
	RegAdminCmd("sm_type",			cmdType,		ADMFLAG_ROOT, "随机轮换模式");

	// v2.2.0 创建波次生命周期 forward（外部插件监听）
	g_fwdOnWaveRest = new GlobalForward("SS_OnWaveRest", ET_Ignore, Param_Float);
	g_fwdOnWaveStart = new GlobalForward("SS_OnWaveStart", ET_Ignore, Param_Cell);

	HookEntityOutput("trigger_finale", "FinaleStart", OnFinaleStart);

	if (g_bLateLoad && L4D_HasAnySurvivorLeftSafeArea())
		L4D_OnFirstSurvivorLeftSafeArea_Post(0);
}

public void OnPluginEnd() {
	// v6.1.1: 恢复 z_spawn_safety_range 原值（插件卸载/reload 不留脏值）
	{
		ConVar cvSafety = FindConVar("z_spawn_safety_range");
		if (cvSafety != null)
			cvSafety.SetFloat(g_fOrigSafetyRange);
	}

	TweakSettings(true);
	// v2.5.3: reload/卸载时还原导演特感刷新（防暂停中 reload 残留 director_no_specials=1）
	SS_RestoreDirectorSpecials();
	// v2.0.0: 三态生命周期清理（含跨批状态；TIMER_FLAG_NO_MAPCHANGE 会随换图取消，此处兜底）
	ResetLifecycle();
	g_bInSpawnTime = false;
}

void TweakSettings(bool restore) {
	if (!restore) {
		FindConVar("z_max_player_zombies").SetBounds(ConVarBound_Upper, true, float(MaxClients));
		FindConVar("z_max_player_zombies").SetFloat(float(MaxClients));
		FindConVar("z_minion_limit").SetInt(MaxClients);
		FindConVar("survival_max_specials").SetInt(MaxClients);

		FindConVar("z_smoker_limit").SetInt(0);
		FindConVar("z_boomer_limit").SetInt(0);
		FindConVar("z_hunter_limit").SetInt(0);
		FindConVar("z_spitter_limit").SetInt(0);
		FindConVar("z_jockey_limit").SetInt(0);
		FindConVar("z_charger_limit").SetInt(0);

		FindConVar("survival_max_smokers").SetInt(0);
		FindConVar("survival_max_boomers").SetInt(0);
		FindConVar("survival_max_hunters").SetInt(0);
		FindConVar("survival_max_spitters").SetInt(0);
		FindConVar("survival_max_jockeys").SetInt(0);
		FindConVar("survival_max_chargers").SetInt(0);

		g_cSpawnRange.SetInt(g_cSpawnRangeMax.IntValue);
		g_cDiscardRange.SetInt(g_cSpawnRange.IntValue + 500);
		g_cSafeSpawnRange.SetInt(g_cSpawnRangeMin.IntValue);
	}
	else {
		//FindConVar("z_max_player_zombies").RestoreDefault();
		FindConVar("z_minion_limit").RestoreDefault();
		FindConVar("survival_max_specials").RestoreDefault();

		FindConVar("z_smoker_limit").RestoreDefault();
		FindConVar("z_boomer_limit").RestoreDefault();
		FindConVar("z_hunter_limit").RestoreDefault();
		FindConVar("z_spitter_limit").RestoreDefault();
		FindConVar("z_jockey_limit").RestoreDefault();
		FindConVar("z_charger_limit").RestoreDefault();

		FindConVar("survival_max_smokers").RestoreDefault();
		FindConVar("survival_max_boomers").RestoreDefault();
		FindConVar("survival_max_hunters").RestoreDefault();
		FindConVar("survival_max_spitters").RestoreDefault();
		FindConVar("survival_max_jockeys").RestoreDefault();
		FindConVar("survival_max_chargers").RestoreDefault();

		g_cSpawnRange.RestoreDefault();
		g_cDiscardRange.RestoreDefault();
		g_cSafeSpawnRange.RestoreDefault();
	}
}

void OnFinaleStart(const char[] output, int caller, int activator, float delay) {
	g_bFinaleStarted = L4D_IsMissionFinalMap();
}

public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal) {
	if (!g_bInSpawnTime)
		return Plugin_Continue;	

	if (!strcmp(key, "PreferredSpecialDirection", false)) {
		retVal = g_iDirection;
		return Plugin_Handled;
	}

	if (!strcmp(key, "MaxSpecials", false) || !strcmp(key, "cm_MaxSpecials", false)) {
		retVal = g_iSILimit;
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client) {
	if (g_bLeftSafeArea)
		return;

	g_bLeftSafeArea = true;

	if (g_iCurrentClass >= SI_MAX_SIZE) {
		PrintToChatAll("\x03当前轮换\x01: \n");
		PrintToChatAll("\x01[\x05%s\x01]\x04模式\x01", g_sZombieClass[g_iCurrentClass - SI_MAX_SIZE]);
	}
	else if (g_iCurrentClass > -1)
		PrintToChatAll("\x01[\x05%s\x01]\x04模式\x01", g_sZombieClass[g_iCurrentClass]);

	StartCustomSpawnTimer(g_fFirstSpawnTime);
	delete g_hSuicideTimer;
	g_hSuicideTimer = CreateTimer(2.5, tmrForceSuicide, _, TIMER_REPEAT);
}

// v6.0.0 幽灵看门狗（调研 §24/§25 重构）:
// 幽灵 ≠ "看不见"，幽灵 = "无 target intent + 无 Nav 进展 + 无攻击/控人 + 没被伤害"
// 持续 N 秒。不再用 m_hasVisibleThreats 单一判据一杆子 25s 处决。
// 阶段（每次无行动 idle 计时）:
//   idle >= recover(7s)   → 重新 PickTarget + L4D2_CommandABot ATTACK 重新注入
//   idle >= relocate(14s) → L4D_WarpToValidPositionIfStuck 换位 + 重新注入
//   idle >= suicide(25s)  → KillInactiveSI（最终垃圾回收）
Action tmrForceSuicide(Handle timer) {
	static int i;
	static int class;
	static int victim;
	static float time;

	time = GetEngineTime();
	int aliveCount = 0;		// v6.0.2: 场上存活 bot SI 计数（波次泄气判定用）
	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i))
			continue;

		class = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (class < 1 || class > SI_MAX_SIZE)
			continue;
		aliveCount++;

		bool healthy = false;

		// 看见幸存者 → 续命（保留原判据，但它只是"healthy"之一）
		if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats")) {
			healthy = true;
		} else {
			victim = GetSurVictim(i, class);
			if (victim > 0) {
				healthy = true;			// 控任何人（站立/倒地）均有效，不处决（用户拍板：控倒地也算）
			}
		}

		// Nav 进展：NavTravelDistance 到目标明显下降 = 有行动（调研 §24/§25）
		if (!healthy && g_iSITarget[i] > 0
			&& IsClientInGame(g_iSITarget[i]) && GetClientTeam(g_iSITarget[i]) == 2 && IsPlayerAlive(g_iSITarget[i])) {
			float np[3], tp[3];
			GetClientAbsOrigin(i, np);
			GetClientAbsOrigin(g_iSITarget[i], tp);
			float d = L4D2_NavAreaTravelDistance(np, tp, false);
			if (d >= 0.0) {
				if (g_fSILastNavDist[i] >= 0.0 && (g_fSILastNavDist[i] - d) > 100.0)
					healthy = true;			// 朝目标缩短真实路线
				g_fSILastNavDist[i] = d;
			}
		}

		if (healthy) {
			// 任意行动续命（被打由 Event_PlayerHurt 刷 actionTime）
			g_fActionTimes[i] = time;
			g_bSIRecovered[i] = false;
			g_bSIRelocated[i] = false;
			continue;
		}

		// -------- 无行动：分阶段修理，而不是一杆子 25s 处决 --------
		float idle = time - g_fActionTimes[i];
		if (idle >= g_fSuicideTime) {
			float posTmp2[3]; GetClientAbsOrigin(i, posTmp2);
			LogMessage("[SS] 处决 %N (class=%d) 原因=自杀计时 idle=%.1fs dist=%.0f pos=(%.0f,%.0f,%.0f) visible=%d nav=%.0f", i, class, idle, DistanceToNearestSurvivor(posTmp2), posTmp2[0], posTmp2[1], posTmp2[2], GetEntProp(i, Prop_Send, "m_hasVisibleThreats"), g_fSILastNavDist[i]);
			KillInactiveSI(i);
			continue;
		}

		// 阶段 1: recover — retarget + 重新注入（可绕过 BOT_CANT_SEE）
		if (g_bTargetInject && !g_bSIRecovered[i] && idle >= g_fRecoverTime) {
			g_bSIRecovered[i] = true;
			int nt = SISpawn_PickTarget(class, 0, g_iBatchSurvivorCount - 1);
			if (nt > 0) {
				g_iSITarget[i] = nt;
				g_fSILastNavDist[i] = -1.0;
				SISpawn_ApplyTargetInject(i, nt);
				LogMessage("[SS] ghost-recover: %N retarget -> %N (idle %.1fs >= %.1f)",
					i, nt, idle, g_fRecoverTime);
			}
			continue;
		}

		// 阶段 2: relocate — 用我们自己的 Hard Gate 找安全点换位（绝不用引擎
		// L4D_WarpToValidPositionIfStuck: 只保证 nav 合法, 会把人扔到悬崖/高处 → 坠落）
		if (!g_bSIRelocated[i] && idle >= g_fRelocateTime) {
			g_bSIRelocated[i] = true;
			SISpawn_RelocateSI(i);
			if (g_bTargetInject && g_iSITarget[i] > 0) {
				g_fSILastNavDist[i] = -1.0;
				SISpawn_ApplyTargetInject(i, g_iSITarget[i]);
			}
			continue;
		}
	}

	// v6.0.2 波次泄气推进: PRESSURE 期首发已出、场上 0 SI、击杀未达标 → 别干等 60s 真空,
	// 场上无 SI 持续 ss_wave_stall_advance(6s) 秒就强制 FinishWave → CLEARING → REST → 下一波
	if (!g_bWaveHadTank && g_Phase == PHASE_PRESSURE && aliveCount == 0 && g_fStallAdvance > 0.0
		&& g_iBatchNext >= g_iBatchTotal && g_iWaveKills < g_iWaveInitial && !g_bSpawningPaused) {
		if (g_fWaveNoSITime <= 0.0) {
			g_fWaveNoSITime = time;
		} else if (time - g_fWaveNoSITime >= g_fStallAdvance) {
			g_fWaveNoSITime = 0.0;
			LogMessage("[SS] Wave #%d stalled: 0 SI alive, kills=%d < initial=%d — force advancing (%.1fs no SI)",
				g_iWaveNumber, g_iWaveKills, g_iWaveInitial, g_fStallAdvance);
			FinishWave();
		}
	} else {
		g_fWaveNoSITime = 0.0;
	}

	return Plugin_Continue;
}

void KillInactiveSI(int client) {
	// v1.4.1: 处决观测（进 L 日志，DEBUG 不依赖）——自杀计时处决必须可数，
	// 否则无法判断 LOS 过滤是否真的消除了"刷新即处决"。
	float o[3];
	GetClientAbsOrigin(client, o);
	LogMessage("[SS] 处决 %N (class=%d) 距生还者最近 %.0f", client,
		GetEntProp(client, Prop_Send, "m_zombieClass"), DistanceToNearestSurvivor(o));

	// v6.0.0: 处决前清掉出生目标注入 RESET timer（防复用槽被旧 RESET 干扰）
	SISpawn_CancelInject(client);
	ForcePlayerSuicide(client);

	// v5.33: 处决不触发 retry 整波重开——70/30 预算由 reserve 补位接管，
	//        处决的幽灵特感本就无压力贡献，不补；防处决→重开波的波次重复播报。
	//        （原 v2.0.0"处决补波仅压力期/收尾期"逻辑废弃）
}

int GetSurVictim(int client, int class) {
	switch (class) {
		case 1:
			return GetEntPropEnt(client, Prop_Send, "m_tongueVictim");

		case 3:
			return GetEntPropEnt(client, Prop_Send, "m_pounceVictim");

		case 5:
			return GetEntPropEnt(client, Prop_Send, "m_jockeyVictim");

		case 6: {
			class = GetEntPropEnt(client, Prop_Send, "m_pummelVictim");
			if (class > 0)
				return class;

			class = GetEntPropEnt(client, Prop_Send, "m_carryVictim");
			if (class > 0)
				return class;
		}
	}

	return -1;
}

Action cmdSetLimit(int client, int args) {
	if (args == 1) {
		char arg[16];
		GetCmdArg(1, arg, sizeof arg);	
		if (strcmp(arg, "reset", false) == 0) {
			ResetLimits();
			ReplyToCommand(client, "[SS] Spawn Limits reset to default values");
		}
	}
	else if (args == 2) {
		int limit = GetCmdArgInt(2);	
		if (limit < 0)
			ReplyToCommand(client, "[SS] Limit value must be >= 0");
		else {
			char arg[16];
			GetCmdArg(1, arg, sizeof arg);
			if (strcmp(arg, "all", false) == 0) {
				for (int i; i < SI_MAX_SIZE; i++)
					g_cSpawnLimits[i].IntValue = limit;

				PrintToChatAll("\x01[SS] All SI limits have been set to \x05%d", limit);
			} 
			else if (strcmp(arg, "max", false) == 0) {
				g_cSILimit.IntValue = limit;
				PrintToChatAll("\x01[SS] -> \x04Max \x01SI limit set to \x05%i", limit);				   
			} 
			else if (strcmp(arg, "group", false) == 0 || strcmp(arg, "wave", false) == 0) {
				g_cSpawnSize.IntValue = limit;
				PrintToChatAll("\x01[SS] -> SI will spawn in \x04groups\x01 of \x05%i", limit);
			} 
			else  {
				for (int i; i < SI_MAX_SIZE; i++) {
					if (strcmp(g_sZombieClass[i], arg, false) == 0) {
						g_cSpawnLimits[i].IntValue = limit;
						PrintToChatAll("\x01[SS] \x04%s \x01limit set to \x05%i", arg, limit);
					}
				}
			}
		}	 
	} 
	else {
		ReplyToCommand(client, "\x04!limit/sm_limit \x05<class> <limit>");
		ReplyToCommand(client, "\x05<class> \x01[ all | max | group/wave | smoker | boomer | hunter | spitter | jockey | charger ]");
		ReplyToCommand(client, "\x05<limit> \x01[ >= 0 ]");
	}

	return Plugin_Handled;
}

Action cmdSetWeight(int client, int args) {
	if (args == 1) {
		char arg[16];
		GetCmdArg(1, arg, sizeof arg);	
		if (strcmp(arg, "reset", false) == 0) {
			ResetWeights();
			ReplyToCommand(client, "[SS] Spawn weights reset to default values");
		} 
	} 
	else if (args == 2) {
		if (GetCmdArgInt(2) < 0) {
			ReplyToCommand(client, "weight value >= 0");
			return Plugin_Handled;
		} 
		else  {
			char arg[16];
			GetCmdArg(1, arg, sizeof arg);
			int iWeight = GetCmdArgInt(2);
			if (strcmp(arg, "all", false) == 0) {
				for (int i; i < SI_MAX_SIZE; i++)
					g_cSpawnWeights[i].IntValue = iWeight;			

				ReplyToCommand(client, "\x01[SS] -> \x04All spawn weights \x01set to \x05%d", iWeight);	
			} 
			else  {
				for (int i; i < SI_MAX_SIZE; i++) {
					if (strcmp(arg, g_sZombieClass[i], false) == 0) {
						g_cSpawnWeights[i].IntValue = iWeight;
						ReplyToCommand(client, "\x01[SS] \x04%s \x01weight set to \x05%d", g_sZombieClass[i], iWeight);				
					}
				}	
			}
		}
	} 
	else 
	{
		ReplyToCommand(client, "\x04!weight/sm_weight \x05<class> <value>");
		ReplyToCommand(client, "\x05<class> \x01[ reset | all | smoker | boomer | hunter | spitter | jockey | charger ]");	
		ReplyToCommand(client, "\x05value \x01[ >= 0 ]");	
	}

	return Plugin_Handled;
}

Action cmdSetTimer(int client, int args) {
	if (args == 1) {
		float time = GetCmdArgFloat(1);
		if (time < 0.1)
			time = 0.1;

		g_cSpawnTimeMin.FloatValue = time;
		g_cSpawnTimeMax.FloatValue = time;
		ReplyToCommand(client, "\x01[SS] Spawn timer set to constant \x05%.1f \x01seconds", time);
	} 
	else if (args == 2) {
		float min = GetCmdArgFloat(1);
		float max = GetCmdArgFloat(2);
		if (min > 0.1 && max > 1.0 && max > min) {
			g_cSpawnTimeMin.FloatValue = min;
			g_cSpawnTimeMax.FloatValue = max;
			ReplyToCommand(client, "\x01[SS] Spawn timer will be between \x05%.1f \x01and \x05%.1f \x01seconds", min, max);
		} 
		else 
			ReplyToCommand(client, "[SS] Max(>= 1.0) spawn time must greater than min(>= 0.1) spawn time");
	} 
	else 
		ReplyToCommand(client, "[SS] timer <constant> || timer <min> <max>");

	return Plugin_Handled;
}

Action cmdResetSpawn(int client, int args) {
	// v2.0.0: 重置三态生命周期（防批次中途命令覆盖队列状态）
	ResetLifecycle();

	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_zombieClass") != 8)
			ForcePlayerSuicide(i);
	}

	StartCustomSpawnTimer(g_fSpawnTimes[0]);
	ReplyToCommand(client, "[SS] Slayed all special infected. Spawn timer restarted. Next potential spawn in %.1f seconds.", g_fSpawnTimeMin);
	return Plugin_Handled;
}

Action cmdForceTimer(int client, int args) {
	// v2.0.0: 重置三态生命周期（防批次中途命令覆盖队列状态）
	ResetLifecycle();

	if (args < 1) {
		StartSpawnTimer();
		ReplyToCommand(client, "[SS] Spawn timer started manually.");
		return Plugin_Handled;
	}

	float time = GetCmdArgFloat(1);
	StartCustomSpawnTimer(time < 0.1 ? 0.1 : time);
	ReplyToCommand(client, "[SS] Spawn timer started manually. Next potential spawn in %.1f seconds.", time);
	return Plugin_Handled;
}

Action cmdType(int client, int args) {
	if (args != 1) {
		ReplyToCommand(client, "\x04!type/sm_type \x05<class>.");
		ReplyToCommand(client, "\x05<type> \x01[ off | random | smoker | boomer | hunter | spitter | jockey | charger ]");
		return Plugin_Handled;
	}

	char arg[16];
	GetCmdArg(1, arg, sizeof arg);
	if (strcmp(arg, "off", false) == 0) {
		g_iCurrentClass = -1;
		ReplyToCommand(client, "已关闭单一特感模式");
		ResetLimits();
	}
	else if (strcmp(arg, "random", false) == 0) {
		PrintToChatAll("\x03当前轮换\x01: \n");
		PrintToChatAll("\x01[\x05%s\x01]\x04模式\x01", g_sZombieClass[SetRandomType()]);
	}
	else {
		int class = GetZombieClass(arg);
		if (class == -1) {
			ReplyToCommand(client, "\x04!type/sm_type \x05<class>.");
			ReplyToCommand(client, "\x05<type> \x01[ off | random | smoker | boomer | hunter | spitter | jockey | charger ]");
		}
		else if (class == g_iCurrentClass)
			ReplyToCommand(client, "目标特感类型与当前特感类型相同");
		else {
			SetSiType(class);
			PrintToChatAll("\x01[\x05%s\x01]\x04模式\x01", g_sZombieClass[class]);
		}
	}

	return Plugin_Handled;
}

int GetZombieClass(const char[] sClass) {
	for (int i; i < SI_MAX_SIZE; i++) {
		if (strcmp(sClass, g_sZombieClass[i], false) == 0)
			return i;
	}
	return -1;
}

int SetRandomType() {
	static int class;
	static int zombieClass[SI_MAX_SIZE] = {0, 1, 2, 3, 4, 5};

	class %= SI_MAX_SIZE;
	if (!class)
		SortIntegers(zombieClass, sizeof zombieClass, Sort_Random);

	SetSiType(zombieClass[class]);
	g_iCurrentClass += SI_MAX_SIZE;
	return zombieClass[class++];
}

void SetSiType(int class) {
	SaveConfiguration();
	for (int i; i < SI_MAX_SIZE; i++)		
		g_cSpawnLimits[i].IntValue = i != class ? 0 : g_iSILimit;

	g_iCurrentClass = class;
}

public void OnConfigsExecuted() {
	GetCvars_Limits();
	GetCvars_Times();
	GetCvars_General();
	GetCvars_TankStatus();
	GetCvars_TankCustom();
	TweakSettings(false);
}

void CvarChanged_Limits(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars_Limits();
}

void GetCvars_Limits() {
	g_iSpawnSize = g_cSpawnSize.IntValue;
	for (int i; i < SI_MAX_SIZE; i++)
		g_iSpawnLimits[i] = g_cSpawnLimits[i].IntValue;
}

void CvarChanged_Times(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars_Times();
}

void GetCvars_Times() {
	g_iSILimit =		g_cSILimit.IntValue;
	g_fSpawnTimeMin =	g_cSpawnTimeMin.FloatValue;
	g_fSpawnTimeMax =	g_cSpawnTimeMax.FloatValue;
	g_iSpawnTimeMode =	g_cSpawnTimeMode.IntValue;

	if (g_fSpawnTimeMin > g_fSpawnTimeMax)
		g_fSpawnTimeMin = g_fSpawnTimeMax;
		
	CalculateSpawnTimes();
}

void CalculateSpawnTimes() {
	if (g_iSILimit <= 1 || g_iSpawnTimeMode <= 0)
		g_fSpawnTimes[0] = g_fSpawnTimeMax;
	else {
		float unit = (g_fSpawnTimeMax - g_fSpawnTimeMin) / (g_iSILimit - 1);
		switch (g_iSpawnTimeMode) {
			case 1:  {
				g_fSpawnTimes[0] = g_fSpawnTimeMin;
				for (int i = 1; i <= MaxClients; i++)
					g_fSpawnTimes[i] = i < g_iSILimit ? (g_fSpawnTimes[i - 1] + unit) : g_fSpawnTimeMax;
			}

			case 2:  {	
				g_fSpawnTimes[0] = g_fSpawnTimeMax;
				for (int i = 1; i <= MaxClients; i++)
					g_fSpawnTimes[i] = i < g_iSILimit ? (g_fSpawnTimes[i - 1] - unit) : g_fSpawnTimeMax;
			}
		}	
	} 
}

void CvarChanged_General(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars_General();
}

void GetCvars_General() {
	g_bScaleWeights =	g_cScaleWeights.BoolValue;

	for (int i; i < SI_MAX_SIZE; i++)
		g_iSpawnWeights[i] = g_cSpawnWeights[i].IntValue;

	g_iBaseLimit =		g_cBaseLimit.IntValue;
	g_fExtraLimit =		g_cExtraLimit.FloatValue;
	g_iBaseSize =		g_cBaseSize.IntValue;
	g_fExtraSize =		g_cExtraSize.FloatValue;
	g_fSuicideTime =	g_cSuicideTime.FloatValue;
	g_fRushDistance =	g_cRushDistance.FloatValue;
	g_fFirstSpawnTime =	g_cFirstSpawnTime.FloatValue;
	g_fIncapCompensation = g_cIncapCompensation.FloatValue;
	g_bRandomDirection = g_cRandomDirection.BoolValue;
	g_fDirFront = g_cDirFront.FloatValue;
	g_fDirMid = g_cDirMid.FloatValue;
	g_fDirBack = g_cDirBack.FloatValue;
	g_fDirSplitSpread = g_cDirSplitSpread.FloatValue;
	g_fDirSplitGap = g_cDirSplitGap.FloatValue;

	// v6.1.0 信任引擎方案: 参数缓存
	g_iCandidateSamples = g_cCandidateSamples.IntValue;
	if (g_iCandidateSamples < 2)
		g_iCandidateSamples = 2;
	g_fNavPathMax = g_cNavPathMax.FloatValue;
	g_bTargetInject = g_cTargetInject.BoolValue;
	g_fTargetInjectTime = g_cTargetInjectTime.FloatValue;
	g_fRecoverTime = g_cRecoverTime.FloatValue;
	g_fRelocateTime = g_cRelocateTime.FloatValue;
	g_fStallAdvance = g_cStallAdvance.FloatValue;
	// v6.2.0 损失率补偿参数缓存
	g_bLossCompEnable = g_cLossCompEnable.BoolValue;
	g_fLossRestScale = g_cLossRestScale.FloatValue;
	g_fLossRestMin = g_cLossRestMin.FloatValue;
	g_fLossScoreScale = g_cLossScoreScale.FloatValue;
}

void CvarChanged_TankStatus(ConVar convar, const char[] oldValue, const char[] newValue) {
	int last = g_iTankStatusAction;

	GetCvars_TankStatus();
	if (last != g_iTankStatusAction)
		TankStatusActoin(FindTank(-1));
}

void GetCvars_TankStatus() {
	g_iTankStatusAction = g_cTankStatusAction.IntValue;
}

void CvarChanged_TankCustom(ConVar convar, const char[] oldValue, const char[] newValue) {
	GetCvars_TankCustom();
}

void GetCvars_TankCustom() {
	char temp[64];
	g_cTankStatusLimits.GetString(temp, sizeof temp);

	char buffers[SI_MAX_SIZE][8];
	ExplodeString(temp, ";", buffers, sizeof buffers, sizeof buffers[]);

	int i;
	int val;
	for (; i < SI_MAX_SIZE; i++) {
		if (buffers[i][0] == '\0') {
			g_iTankStatusLimits[i] = -1;
			continue;
		}

		if ((val = StringToInt(buffers[i])) < -1 || val > g_iSILimit) {
			g_iTankStatusLimits[i] = -1;
			buffers[i][0] = '\0';
			continue;
		}

		g_iTankStatusLimits[i] = val;
		buffers[i][0] = '\0';
	}

	g_cTankStatusWeights.GetString(temp, sizeof temp);
	ExplodeString(temp, ";", buffers, sizeof buffers, sizeof buffers[]);

	for (i = 0; i < SI_MAX_SIZE; i++) {
		if (buffers[i][0] == '\0' || (val = StringToInt(buffers[i])) < 0) {
			g_iTankStatusWeights[i] = -1;
			continue;
		}

		g_iTankStatusWeights[i] = val;
	}
}

public void OnClientDisconnect(int client) {
	if (!client || !IsClientInGame(client) || GetClientTeam(client) != 3 || GetEntProp(client, Prop_Send, "m_zombieClass") != 8)
		return;

	CreateTimer(0.1, tmrTankDisconnect, _, TIMER_FLAG_NO_MAPCHANGE);
}

// v1.3.9: 热重载兜底——sm plugins reload 时 L4D_OnFirstSurvivorLeftSafeArea_Post
// 不会重发，刷怪定时器链会断（特感停刷到换图）。引擎状态不受插件重载影响，
// 用 L4D_HasAnySurvivorLeftSafeArea 检测 → 已离开安全区则重建链。
public void OnMapStart() {
	// v6.1.1: 覆盖 z_spawn_safety_range = 350 (InfectedBots 默认值)
	// v6.1.2 中度优化: 350→500 (+150) 配合 ss_spawnrange_min/guard_min 上调，给 2.5s 反应
	// 保存原值，OnMapEnd/OnPluginEnd 恢复，避免永久污染全局 cvar。
	{
		ConVar cvSafety = FindConVar("z_spawn_safety_range");
		if (cvSafety != null) {
			if (g_fOrigSafetyRange == 0.0) g_fOrigSafetyRange = cvSafety.FloatValue;
			cvSafety.SetFloat(500.0);
		}
	}

	if (L4D_HasAnySurvivorLeftSafeArea()) {
		g_bLeftSafeArea = true;
		// v2.0.0 热重载兜底: 状态机与全部 timer 随卸载清零 → 从收尾期恢复
		// （现有特感清剿 → 冷静 → 下一波, 冷静期契约在 reload 后仍成立）
		if (!g_hSpawnTimer && !g_hClearTimer && !g_hRestTimer && !g_hBatchTimer) {
			g_fPhaseEnterTime = GetEngineTime();
			EnterClearing();
		}
		if (!g_hSuicideTimer)
			g_hSuicideTimer = CreateTimer(2.5, tmrForceSuicide, _, TIMER_REPEAT);
	}
}

public void OnMapEnd() {
	// v6.1.1: 恢复 z_spawn_safety_range 原值
	{
		ConVar cvSafety = FindConVar("z_spawn_safety_range");
		if (cvSafety != null)
			cvSafety.SetFloat(g_fOrigSafetyRange);
	}

	g_bLeftSafeArea = false;
	g_bFinaleStarted = false;

	EndSpawnTimer();
	delete g_hSuicideTimer;
	// v2.0.0: 三态生命周期清理（含跨批状态；TIMER_FLAG_NO_MAPCHANGE 随换图取消，此处兜底）
	ResetLifecycle();
	g_bInSpawnTime = false;
	TankStatusActoin(false);

	if (g_iCurrentClass >= SI_MAX_SIZE)
		SetRandomType();
	else if (g_iCurrentClass > -1)
		SetSiType(g_iCurrentClass);
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
	OnMapEnd();
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
	EndSpawnTimer();
	// v2.0.0: 回合重开中途相位兜底复位
	ResetLifecycle();
}

void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bLeftSafeArea)
		return;

	g_fActionTimes[GetClientOfUserId(event.GetInt("userid"))] = GetEngineTime();
	g_fActionTimes[GetClientOfUserId(event.GetInt("attacker"))] = GetEngineTime();
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;

	if (event.GetInt("team") == 2 || event.GetInt("oldteam") == 2) {
		delete g_hUpdateTimer;
		g_hUpdateTimer = CreateTimer(2.0, tmrUpdate);
	}
}

Action tmrUpdate(Handle timer) {
	g_hUpdateTimer = null;
	SetSpawnCount();
	return Plugin_Continue;
}

void SetSpawnCount() {
	int count;
	int limit;
	int spawnSize;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2)
			count++;
	}

	count -= 4;
	if (count < 1) {
		limit = g_iBaseLimit;
		spawnSize = g_iBaseSize;
	}
	else {
		limit = g_iBaseLimit + RoundToNearest(g_fExtraLimit * count);
		spawnSize = g_iBaseSize + RoundToNearest(count / g_fExtraSize);
	}

	// v5.33: 计算值不应低于用户手动配置的 ss_spawn_size（防止人数少时覆盖用户设定）
	int userSpawnSize = g_cSpawnSize.IntValue;
	if (spawnSize < userSpawnSize)
		spawnSize = userSpawnSize;

	if (limit == g_iSILimit && spawnSize == g_iSpawnSize)
		return;

	g_cSILimit.IntValue = limit;
	g_cSpawnSize.IntValue = spawnSize;
	PrintToChatAll("\x01[\x05%d特\x01/\x05次\x01] \x05%d特 \x01[\x03%.1f\x01~\x03%.1f\x01]\x04秒", spawnSize <= limit ? spawnSize : limit, limit, g_fSpawnTimeMin, g_fSpawnTimeMax);
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client) || GetClientTeam(client) != 3)
		return;

	// v2.5.4: 暂停期间特感出生 = 暂停被突破（诊断"假暂停"：director 或其他源仍在刷）
	if (g_bSpawningPaused) {
		int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
		LogMessage("[SS] PAUSE VIOLATION: SI spawned during pause client=%N class=%d fake=%d",
			client, zClass, IsFakeClient(client));
	}

	if (GetEntProp(client, Prop_Send, "m_zombieClass") != 8)
		g_fActionTimes[client] = GetEngineTime();
	else
		CreateTimer(0.1, tmrTankSpawn, event.GetInt("userid"), TIMER_FLAG_NO_MAPCHANGE);
}

void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (!client || !IsClientInGame(client))
		return;

	// v2.5.0 剿灭得分: 波内死亡统计（去重; 倒地后死亡由标记拦住, 不重复计数）
	if (GetClientTeam(client) == 2) {
		if (g_bWaveActive && !g_bWaveDowned[client]) {
			g_bWaveDowned[client] = true;
			g_iWaveDownDeaths++;
		}
		return;
	}

	if (GetClientTeam(client) != 3)
		return;

	// v6.0.0: SI 死亡 → 清掉出生目标注入 RESET timer（防 client 槽复用被旧 RESET 干扰）
	SISpawn_CancelInject(client);

	// v5.33: SI 生命周期追踪 — 详细死亡日志
	int siID = g_iSIWaveID[client];
	int siClass = (client > 0 && client <= MaxClients) ? GetEntProp(client, Prop_Send, "m_zombieClass") : -1;
	float lifespan = (g_fSISpawnTime[client] > 0.0) ? (GetGameTime() - g_fSISpawnTime[client]) : 0.0;

	// 死亡来源
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int inflictor = event.GetInt("inflictor_entidx");
	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	bool headshot = event.GetInt("headshot") != 0;
	bool dominated = event.GetInt("dmg_type") & DMG_BURN;  // 燃烧

	// 幸存者 vs 特感 vs 环境
	char killerName[64] = "world";
	if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker)) {
		GetClientName(attacker, killerName, sizeof(killerName));
	}

	if (siID > 0) {
		int waveNum = g_iSIWaveNum[client];
		LogMessage("[SS] SI#%d-%d DIED: class=%s(%.0fs alive) killer='%s' weapon='%s' headshot=%d",
			waveNum, siID, (siClass >= 0 && siClass < SI_MAX_SIZE) ? g_sZombieClass[siClass] : "?",
			lifespan, killerName, weapon, headshot);
		// v6.1.5 系统处决疑似：短寿命 + 世界/自杀 击杀 → 额外标记，便于统计“刷不出或被处决”原因
		if (lifespan < 10.0 && (attacker <= 0 || attacker == client || StrContains(weapon, "world") != -1 || StrContains(weapon, "trigger") != -1)) {
			float dpos[3]; GetEntPropVector(client, Prop_Send, "m_vecOrigin", dpos);
			LogMessage("[SS] 系统处决疑似 SI#%d-%d class=%s %.1fs killer='%s' weapon='%s' pos=(%.0f,%.0f,%.0f) dist=%.0f", waveNum, siID, (siClass >= 0 && siClass < SI_MAX_SIZE) ? g_sZombieClass[siClass] : "?", lifespan, killerName, weapon, dpos[0], dpos[1], dpos[2], DistanceToNearestSurvivor(dpos));
		}
		// v5.33: 聊天播报击杀（v6.1.1 起移除——防刷屏；保留 LogMessage 生命周期追踪）
		if (attacker > 0 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == 2) {
			// PrintToChatAll("\x04[击杀]\x01 %s#\x05%d-%d\x01 被 \x03%s\x01 击杀（%.1fs）",
			// 	(siClass >= 0 && siClass < SI_MAX_SIZE) ? g_sZombieClass[siClass] : "?",
			// 	waveNum, siID, killerName, lifespan);
		} else {
			// 非玩家击杀（世界/自杀/坠落）
			char reason[32];
			if (StrContains(weapon, "world") != -1 || StrContains(weapon, "fall") != -1)
				strcopy(reason, sizeof(reason), "坠落");
			else if (StrContains(weapon, "trigger") != -1)
				strcopy(reason, sizeof(reason), "陷阱");
			else if (attacker == client || attacker <= 0)
				strcopy(reason, sizeof(reason), "自杀");
			else
				strcopy(reason, sizeof(reason), weapon);
			// PrintToChatAll("\x04[击杀]\x01 %s#\x05%d-%d\x01 %s（%.1fs）",
			// 	(siClass >= 0 && siClass < SI_MAX_SIZE) ? g_sZombieClass[siClass] : "?",
			// 	waveNum, siID, reason, lifespan);
		}
	} else {
		// 非本插件生成的 SI（引擎 director 生成的残留）
		LogMessage("[SS] SI DIED (untracked): class=%d killer='%s' weapon='%s' headshot=%d",
			siClass, killerName, weapon, headshot);
	}

	// v6.2.0 损失率统计：非玩家击杀的本波 SI 记为系统处决（与玩家击杀互斥）
	if (g_bWaveActive && siID > 0 && g_iSIWaveNum[client] == g_iWaveNumber) {
		bool isSurvivorKill = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == 2);
		if (!isSurvivorKill) {
			g_iWaveSystemKills++;
			if (g_iWaveBudget > 0) {
				float _loss = float(g_iWaveSystemKills) / float(g_iWaveBudget);
				if (_loss > 1.0) _loss = 1.0;
				g_fWaveLossRate = _loss;
			}
			LogMessage("[SS] Wave #%d system loss: SI#%d-%d class=%s sysKills=%d/%d loss=%.0f%%", g_iWaveNumber, g_iSIWaveNum[client], siID, (siClass >= 0 && siClass < SI_MAX_SIZE) ? g_sZombieClass[siClass] : "?", g_iWaveSystemKills, g_iWaveBudget, g_fWaveLossRate * 100.0);
		}
	}

	// v5.33: 70/30 Wave Budget — 击杀累计计数 + 补位
	// 核心语义（用户修正）：波次完成 = 本波[玩家]累计击杀达预算70%（g_iWaveInitial），
	// 不是"场上剩余30%"也不是"reserve耗尽"。reserve 只负责补位保持压力。
	// v5.33-fix2: 只有幸存者玩家击杀才计入（系统处决/自杀/特感互杀不算，
	//             否则 KillInactiveSI 处决不活跃特感会虚增 70% 进度）。
	if (g_bWaveActive && attacker >= 1 && attacker <= MaxClients
		&& IsClientInGame(attacker) && GetClientTeam(attacker) == 2) {
		g_iWaveKills++;
		// 击杀一只补一只（reserve 有剩 && 首发已完成），保持场上压力
		if (g_iWaveReserve > 0 && g_iBatchNext >= g_iBatchTotal) {
			if (SpawnReplacement())
				g_iWaveReserve--;
		}
		// v5.33: 累计击杀达到首发数（=预算70%）→ 波次完成，进 CLEARING
		if (g_iWaveKills >= g_iWaveInitial) {
			// 取消 wait 超时兜底
			if (g_hReserveTimer != null) {
				KillTimer(g_hReserveTimer);
				g_hReserveTimer = null;
			}
			LogMessage("[SS] Wave #%d 70%% cleared (kills=%d >= initial=%d), entering CLEARING",
				g_iWaveNumber, g_iWaveKills, g_iWaveInitial);
			FinishWave();
		}
	}

	static int class;
	class = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (class == 8 && !FindTank(client))
		TankStatusActoin(false);

	if (class != 4 && IsFakeClient(client))
		RequestFrame(NextFrame_KickBot, event.GetInt("userid"));
}

// v2.5.0 剿灭得分: 波内倒地统计（去重; 仅在波次进行中 PRESSURE/CLEARING 计入,
// REST/IDLE 期间残留特感造成的倒地归属下一波）
void Event_PlayerIncapacitated(Event event, const char[] name, bool dontBroadcast) {
	if (!g_bWaveActive)
		return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || GetClientTeam(client) != 2)
		return;
	if (!g_bWaveDowned[client]) {
		g_bWaveDowned[client] = true;
		g_iWaveDownDeaths++;
	}
}

Action tmrTankSpawn(Handle timer, int client) {
	if (!(client = GetClientOfUserId(client)) || !IsClientInGame(client) || GetClientTeam(client) != 3 || !IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_zombieClass") != 8 || FindTank(client))
		return Plugin_Stop;

	int totalLimit;
	int totalWeight;
	for (int i; i < SI_MAX_SIZE; i++) {
		totalLimit += g_iSpawnLimits[i];
		totalWeight += g_iSpawnWeights[i];
	}

	if (totalLimit && totalWeight)
		TankStatusActoin(true);

	return Plugin_Continue;
}

void SaveConfiguration() {
	for (int i; i < SI_MAX_SIZE; i++) {
		g_iSpawnLimitsCache[i] = g_iSpawnLimits[i];
		g_iSpawnWeightsCache[i] = g_iSpawnWeights[i];
	}
}

void NextFrame_KickBot(any client) {
	if ((client = GetClientOfUserId(client)) && IsClientInGame(client) && !IsClientInKickQueue(client) && IsFakeClient(client))
		KickClient(client);
}

bool FindTank(int client) {
	for (int i = 1; i <= MaxClients; i++) {
		if (i != client && IsClientInGame(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_zombieClass") == 8)
			return true;
	}
	return false;
}

Action tmrTankDisconnect(Handle timer) {
	if (FindTank(-1))
		return Plugin_Stop;

	TankStatusActoin(false);
	return Plugin_Continue;
}

void TankStatusActoin(bool isTankAlive) {
	static bool loaded;
	if (!isTankAlive) {
		if (loaded) {
			loaded = false;
			LoadCacheSpawnLimits();
			LoadCacheSpawnWeights();
		}
	}
	else {
		if (!loaded && g_iTankStatusAction) {
			loaded = true;
			for (int i; i < SI_MAX_SIZE; i++) {
				g_iSpawnLimitsCache[i] = g_iSpawnLimits[i];
				g_iSpawnWeightsCache[i] = g_iSpawnWeights[i];
			}
			LoadCacheTankCustom();
		}
	}
}

void LoadCacheSpawnLimits() {
	if (g_iSILimitCache != -1) {
		g_cSILimit.IntValue = g_iSILimitCache;
		g_iSILimitCache = -1;
	}

	if (g_iSpawnSizeCache != -1) {
		g_cSpawnSize.IntValue = g_iSpawnSizeCache;
		g_iSpawnSizeCache = -1;
	}

	for (int i; i < SI_MAX_SIZE; i++) {		
		if (g_iSpawnLimitsCache[i] != -1) {
			g_cSpawnLimits[i].IntValue = g_iSpawnLimitsCache[i];
			g_iSpawnLimitsCache[i] = -1;
		}
	}
}

void LoadCacheSpawnWeights() {
	for (int i; i < SI_MAX_SIZE; i++) {		
		if (g_iSpawnWeightsCache[i] != -1) {
			g_cSpawnWeights[i].IntValue = g_iSpawnWeightsCache[i];
			g_iSpawnWeightsCache[i] = -1;
		}
	}
}

void LoadCacheTankCustom() {
	for (int i; i < SI_MAX_SIZE; i++) {
		if (g_iTankStatusLimits[i] != -1)
			g_cSpawnLimits[i].IntValue = g_iTankStatusLimits[i];
			
		if (g_iTankStatusWeights[i] != -1)
			g_cSpawnWeights[i].IntValue = g_iTankStatusWeights[i];
	}
}

void ResetLimits() {
	for (int i; i < SI_MAX_SIZE; i++)
		g_cSpawnLimits[i].RestoreDefault();
}

void ResetWeights() {
	for (int i; i < SI_MAX_SIZE; i++)
		g_cSpawnWeights[i].RestoreDefault();
}

void StartCustomSpawnTimer(float time) {
	EndSpawnTimer();
	g_hSpawnTimer = CreateTimer(time, tmrSpawnSpecial);
}

void StartSpawnTimer() {
	EndSpawnTimer();
	g_hSpawnTimer = CreateTimer(g_iSpawnTimeMode > 0 ? g_fSpawnTimes[GetTotalSI()] : Math_GetRandomFloat(g_fSpawnTimeMin, g_fSpawnTimeMax), tmrSpawnSpecial);
}

void EndSpawnTimer() {
	delete g_hSpawnTimer;
	delete g_hRetryTimer;
}

Action tmrSpawnSpecial(Handle timer) {
	g_hSpawnTimer = null;
	delete g_hRetryTimer;

	// v2.4.0 刷新暂停防御: 外部插件暂停期间延迟刷新（如 AGM 爆炸清场）
	if (g_bSpawningPaused) {
		LogMessage("[SS] 防御: 刷新暂停期间延迟波次，5 秒后重试");
		g_hSpawnTimer = CreateTimer(5.0, tmrSpawnSpecial);
		return Plugin_Continue;
	}

	// v2.0.1 冷静期契约防御: REST 期间绝不允许排波。历史 bug（tmrClearCheck
	// REPEAT timer 回调自删双重释放）导致 SM 句柄表污染，出现 REST 期间幽灵
	// 波 timer 提前触发（波 B 在冷静期第 12s 刷出、无播报，玩家实测"第二波
	// 来袭不播报"）。防御: 忽略 + 记录，冷静期窗口由 tmrRestEnd 正常接管。
	if (g_Phase == PHASE_REST) {
		LogMessage("[SS] 防御: REST 期间忽略幽灵波 timer");
		return Plugin_Continue;
	}

	// v2.0.0 波间三态: 压力期开始（收尾期 120s 强制冷静硬上限锚点）
	g_fPhaseEnterTime = GetEngineTime();
	g_Phase = PHASE_PRESSURE;
	// v2.5.1 剿灭得分时间倍率起算点（特感刷新播报时刻; retry 波不重置）
	g_fWaveStartTime = GetEngineTime();

	// v2.5.0 剿灭得分: 波次开始快照——基数=当前生还队人数（含 bot, 用户拍板）,
	// 清零波内倒地/死亡/Tank 标志（retry 波不重进此处, 统计延续本波）
	g_iWaveBase = 0;
	g_iWaveDownDeaths = 0;
	g_bWaveHadTank = false;
	g_bWaveActive = true;
	g_iWaveNumber++;   // v5.33: 波次计数（日志用）
	for (int i = 1; i <= MaxClients; i++) {
		g_bWaveDowned[i] = false;
		if (IsClientInGame(i) && GetClientTeam(i) == 2)
			g_iWaveBase++;
	}

	int totalSI = GetTotalSI();
	// v2.1.0 FIX: 新波次开始应传 false（非 retry），才能触发 OnWaveStarted 通知
	bool started = ExecuteSpawnQueue(totalSI, false);
	// v2.5.0 剿灭得分: 零波（上限满/全倒/无站立生还者）不发剿灭分
	g_bWaveStarted = started;

	// v2.2.0 触发 WaveStart forward（started=是否真的刷出特感，供外部插件同步波次）
	Call_StartForward(g_fwdOnWaveStart);
	Call_PushCell(started);
	Call_Finish();

	// v2.0.0: 零波（上限满/全倒/无站立生还者）直接进收尾期轮询, 链条不断
	if (!started)
		EnterClearing();
	return Plugin_Continue;
}

bool ExecuteSpawnQueue(int totalSI, bool retry) {
	if (totalSI >= g_iSILimit)
		return false;

	#if BENCHMARK
	g_profiler = new Profiler();
	g_profiler.Start();
	#endif

	int allowedSI = g_iSILimit - totalSI;
	int spawnSize = g_iSpawnSize > allowedSI ? allowedSI : g_iSpawnSize;

	// v1.5.0 倒地补偿：刷怪瞬间按 站立/总人数 比例收缩本波数量与有效上限。
	// 例: 10人5倒 → ratio 0.5 → 上限 15→8（存活≥8 本波跳过）、波次 10→5，
	// 站立 5 人面对 ≤8 特感而非 15（近乎 3 倍）。全倒（total 全倒地）→ 比例 0，
	// 上限压到 1，波次跳过——等队友起身/复活后下一波自动恢复，无 cvar 陈旧问题。
	// 注意: IsPlayerAlive 对倒地返回 true，所以 total 含倒地者，须用
	// m_isIncapacitated 区分站立人数。
	float compensationStrength = g_fIncapCompensation;

	if (compensationStrength > 0.0) {
		int total;
		int standing;
		for (int s = 1; s <= MaxClients; s++) {
			if (IsClientInGame(s) && GetClientTeam(s) == 2 && IsPlayerAlive(s)) {
				total++;
				if (!GetEntProp(s, Prop_Send, "m_isIncapacitated"))
					standing++;
			}
		}

		if (total > 0 && standing < total) {
			float ratio = float(standing) / float(total);
			float scale = 1.0 - compensationStrength * (1.0 - ratio);

			int effLimit = RoundToNearest(float(g_iSILimit) * scale);
			if (effLimit < 1)
				effLimit = 1;

			if (totalSI >= effLimit) {
				LogMessage("[SS] incap comp: %d/%d 倒地, 上限 %d→%d, 存活 %d → 本波跳过 (comp %.1f)",
					total - standing, total, g_iSILimit, effLimit, totalSI, compensationStrength);
				return false;
			}

			int oldSize = spawnSize;
			allowedSI = effLimit - totalSI;
			spawnSize = RoundToNearest(float(spawnSize) * scale);
			if (spawnSize < 1)
				spawnSize = 1;
			if (spawnSize > allowedSI)
				spawnSize = allowedSI;

			if (spawnSize != oldSize)
				LogMessage("[SS] incap comp: %d/%d 倒地, 波次 %d→%d, 上限 %d→%d (comp %.1f)",
					total - standing, total, oldSize, spawnSize, g_iSILimit, effLimit, compensationStrength);
		}
	}

	GetSITypeCount();

	int i;
	int index;
	ArrayList aQueue = new ArrayList();
	for (; i < spawnSize; i++) {
		index = GenerateIndex();
		if (index == -1)
			break;

		aQueue.Push(index);
		g_iSpawnCounts[index]++;
	}

	spawnSize = aQueue.Length;
	if (!spawnSize) {
		delete aQueue;
		return false;
	}

	float flow;
	ArrayList aList = new ArrayList(2);
	for (i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i) && !GetEntProp(i, Prop_Send, "m_isIncapacitated")) {
			flow = L4D2Direct_GetFlowDistance(i);
			if (flow && flow != -9999.0)
				aList.Set(aList.Push(flow), i, 1);
		}
	}

	int count = aList.Length;
	if (!count) {
		delete aList;
		delete aQueue;
		return false;
	}

	aList.Sort(Sort_Descending, Sort_Float);

	bool find;
	flow = aList.Get(0, 0);
	float lastFlow = aList.Get(count - 1, 0);
	if (flow - lastFlow > g_fRushDistance) {
		#if DEBUG
		PrintToServer("[SS] Rusher -> %N", aList.Get(0, 1));
		#endif

		find = true;
	}

	// v1.3.9: 提前提取存活生还者数组（随机参照用，参照者=引擎生成点的中心）。
	// v1.7.0: 改为全局持有——分批续刷跨 timer 需要参照者/flow 存活。
	int aLen = aList.Length;
	g_iBatchSurvivorCount = aLen;
	for (i = 0; i < aLen; i++) {
		g_iBatchSurvivors[i] = aList.Get(i, 1);
		g_fBatchFlows[i] = aList.Get(i, 0);
	}

	delete aList;
	g_bInSpawnTime = true;
	//g_cSpawnRange.IntValue = retry ? 1000 : 1500;

	// v1.7.0 三段定向刷新（单面受敌修复）：队伍拉长时把本波特感按权重分配到
	// 前/中/后三段（前拦截/中侧翼/后断后），每只独立方向 + 独立参照者：
	//   前段 = SPAWN_IN_FRONT_OF_SURVIVORS(7)，参照前段成员（正面对手减半以上）
	//   中段 = SPAWN_NO_PREFERENCE(-1)，参照中部成员（侧翼包抄，中部玩家有目标）
	//   后段 = SPAWN_BEHIND_SURVIVORS(1)，参照尾部成员（身后断后，尾部玩家参战）
	// 段边界按 flow gap 自然切（相邻 gap > ss_dir_split_gap 断开）——蛇形环绕/
	// 断裂队伍每段都能吃到特感，而非机械三等分。防贴脸不受影响：守卫检查落点
	// 离"所有"生还者的地理 3D 距离（v1.3.8），与参照者/方向无关，段划分只改变
	// 特感出现的方位、不改变离人距离的下限。
	// 紧凑队伍（flow 总差 < ss_dir_split_spread）不分段，走 v1.6.0 原逻辑。
	// 终章（NEAR_IT_VICTIM）不分段，防守场景保持不变。
	int segA = 0;
	int segB = 0;
	bool useSegs = false;

	// v2.0.0 批次引擎: 批数 = ceil(波次/ss_batch_size) 钳 [1, ss_batch_max]
	// （战术小队 4 只/批）; 批间隔 = ss_batch_window/批数 钳 [5,10]（整波释放
	// 窗口 ≈ 35s, 任意人数都在窗口内出完）。
	int batches = RoundToCeil(float(spawnSize) / float(g_cBatchSize.IntValue));
	if (batches < 1)
		batches = 1;
	if (batches > g_cBatchMax.IntValue)
		batches = g_cBatchMax.IntValue;
	if (batches > spawnSize)
		batches = spawnSize;

	g_iBatchBatchSize = spawnSize / batches + ((spawnSize % batches) ? 1 : 0);

	float bi = g_cBatchWindow.FloatValue / float(batches);
	if (bi < 5.0)
		bi = 5.0;
	else if (bi > 10.0)
		bi = 10.0;
	g_fBatchInterval = bi;

	// v2.4.0 收尾期清剿阈值: 场上存活 ≤ max(2, floor(本波刷新量×0.3)) 进冷静期
	// （非Tank波必须剿灭70%才进冷静期；4人8特 → ≤2 = "不足3只"）
	g_iClearThreshold = spawnSize * 3 / 10;
	if (g_iClearThreshold < 2)
		g_iClearThreshold = 2;
	if (!g_bFinaleStarted && aLen >= 3 && (flow - lastFlow) >= g_fDirSplitSpread) {
		useSegs = true;
		// 自然段划分：segA = 第一处断裂（前段参照子集 [0,segA)），
		// segB = 最后自然段起点（后段参照子集 [segB,aLen)），中间段们 =
		// [segA,segB)（侧翼）。无断裂（单段拉长）退化为均匀三分。
		segA = aLen;
		int segLastStart = 0;
		int k = 0;
		for (i = 1; i < aLen; i++) {
			if (g_fBatchFlows[i - 1] - g_fBatchFlows[i] > g_fDirSplitGap) {
				if (segA == aLen)
					segA = i;			// 第一处断裂 = 前段结束
				segLastStart = i;
				k++;
			}
		}
		if (k >= 1) {
			segB = segLastStart;
		} else {
			// 单段拉长：均匀三分
			segA = aLen / 3;
			segB = aLen * 2 / 3;
		}
		if (segA < 1)
			segA = 1;
		if (segB <= segA)
			segB = segA + 1;
		if (segB > aLen)
			segB = aLen;

		// v2.0.0 批内段重平衡: 整波先分配再洗牌 → 分批释放时前批单段扎堆。
		// 每批独立 40/30/30 + 批内洗牌 → 每批都前中后均衡（4 只批 = 头2/中1/尾1,
		// 多点位输出）。段边界（segA/segB 参照子集）语义不变, 权重仍 40/30/30。
		float totalW = g_fDirFront + g_fDirMid + g_fDirBack;
		if (totalW <= 0.0)
			totalW = 100.0;
		for (int b = 0; b < batches; b++) {
			int start = b * g_iBatchBatchSize;
			int end = start + g_iBatchBatchSize;
			if (end > spawnSize)
				end = spawnSize;
			int batchN = end - start;
			int frontN = RoundToNearest(float(batchN) * g_fDirFront / totalW);
			if (frontN > batchN)
				frontN = batchN;
			if (frontN < 0)
				frontN = 0;
			int backN = RoundToNearest(float(batchN) * g_fDirBack / totalW);
			if (backN > batchN - frontN)
				backN = batchN - frontN;
			if (backN < 0)
				backN = 0;
			int midN = batchN - frontN - backN;
			for (i = start; i < end; i++)
				g_iSegs[i] = (i - start < frontN) ? 0 : (i - start < frontN + midN) ? 1 : 2;
			for (i = end - 1; i > start; i--) {
				int j = GetRandomInt(start, i);
				int tmp = g_iSegs[i];
				g_iSegs[i] = g_iSegs[j];
				g_iSegs[j] = tmp;
			}
		}
	}

	// v1.7.0 波次分批释放: 批次状态全局持有，续刷走 tmrBatchContinue，收尾统一
	// FinishWave（guard 统计跨批累计 + retry 判定 + 队列释放）。
	g_iBatchSuccess = 0;
	g_iBatchGuardBlocked = 0;
	g_iBatchGuardVis = 0;
	g_iBatchGuardInvis = 0;
	g_iBatchGuardInvisNear = 0;	// v2.6.0 幽灵修复: B 档计数/距离统计清零（v6.0.0 起=B 档语义废弃, 用于 隐藏且<guard 计数）
	g_iBatchGuardInvisCount = 0;
	g_iBatchGuardTrap = 0;		// v6.0.3: 陷阱硬拒计数清零
	g_fBatchGuardInvisDistSum = 0.0;
	// v6.0.0 调研落地: 阻塞槽位欠账重置（失败不消耗波次预算）
	g_iBatchDebt = 0;
	g_iBatchSpawnPosCount = 0;	// v6.1.4 分散刷：已刷点位清零
	g_bBatchCatchup = false;
	if (g_hCatchupTimer != null) {
		KillTimer(g_hCatchupTimer);
		g_hCatchupTimer = null;
	}
	// v6.0.1 target 分散计数 清零
	for (int _t = 1; _t <= MaxClients; _t++)
		g_iTargetCounts[_t] = 0;
	// v6.0.2: 波次泄气计时清零
	g_fWaveNoSITime = 0.0;

	// v5.33: 70/30 Wave Budget — 首发 70%，补位 30%（v6.1.3: 用户拍板取消补位，一次全刷，人数*2.5）
	// v6.2.0 损失率：本波系统处决清零（冷静期+得分补偿用）
	g_iWaveBudget = spawnSize;
	g_iWaveInitial = spawnSize; // 100% 首发，无保留
	g_iWaveReserve = 0;
	g_iWaveKills = 0;
	g_iWaveSystemKills = 0;
	g_fWaveLossRate = 0.0;
	g_iWaveReserveSpawned = 0;
	g_iWaveSICount = 0;   // v5.33: 波次内 SI 序号重置
	// 新波次开始时清理上一波的 reserve wait timer
	if (g_hReserveTimer != null) {
		KillTimer(g_hReserveTimer);
		g_hReserveTimer = null;
	}
	if (g_iWaveInitial < 1) g_iWaveInitial = 1;

	// 一次全刷（无 reserve 补位）
	g_iBatchTotal = g_iWaveInitial;
	g_iBatchNext = 0;
	g_iBatchSegA = segA;
	g_iBatchSegB = segB;
	g_bBatchSegs = useSegs;
	g_bBatchRetry = retry;
	g_bBatchFind = find;

	g_hBatchQueue = aQueue;

	// v5.33: 波次开始播报（必须在 SpawnSliced 之前，否则玩家先看到刷新再看到计划）。
	// v6.1.1: 播报已移除（用户要求减少刷屏）。
	// if (!retry) {
	// 	PrintToChatAll("\x04[SI]\x01 特感来袭！");
	// }

	// v5.33: 首发改为逐帧分散生成(v6.4.0), 完成后走 SliceDone 首发分支
	g_iSliceCaller = 0;
	SpawnSliced(0, g_iWaveInitial);

	return true;
}

// v6.4.0: 逐帧切片完成回调——按发起方分流收尾
void SliceDone() {
	if (g_iSliceCaller == 0)
		SliceDone_Initial();
	else
		SliceDone_Batch();
}

void SliceDone_Initial() {
	// v6.0.0 调研落地: 首发被 Hard Gate 拦下的槽位（欠账）1s 后 catch-up 重采样补上
	if (g_iBatchDebt > 0)
		SISpawn_ScheduleCatchup();

	LogMessage("[SS] Wave Budget: total=%d initial=%d(70%%) reserve=%d(30%%) debt=%d",
		g_iWaveBudget, g_iWaveInitial, g_iWaveReserve, g_iBatchDebt);

	#if BENCHMARK
	g_profiler.Stop();
	PrintToServer("[SS] ProfilerTime: %f", g_profiler.Time);
	#endif

	// v5.33: 首发完成但 reserve>0 → 不立即收尾，等击杀补位或超时兜底
	if (g_iBatchNext >= g_iBatchTotal) {
		if (g_iWaveReserve > 0) {
			g_bInSpawnTime = false;
			LogMessage("[SS] Initial batch done, reserve=%d remaining — waiting for replacements", g_iWaveReserve);
			if (g_hReserveTimer == null)
				g_hReserveTimer = CreateTimer(60.0, tmrReserveTimeout, _, TIMER_FLAG_NO_MAPCHANGE);
		} else {
			FinishWave();
		}
	} else {
		g_hBatchTimer = CreateTimer(g_fBatchInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// v5.33: reserve 等待超时兜底——60s 内没补完也强制收尾，防波次永久卡在 PRESSURE
Action tmrReserveTimeout(Handle timer) {
	g_hReserveTimer = null;
	if (g_Phase == PHASE_PRESSURE && g_iWaveReserve > 0) {
		LogMessage("[SS] Reserve wait timeout (60s), forcing wave end with reserve=%d remaining", g_iWaveReserve);
		FinishWave();
	}
	return Plugin_Continue;
}

// ============================================================================
// v6.1.0 信任引擎取点（2026-08-18，对标社区 InfectedBots 3.0.8 刷点哲学）:
// v6.0.0 的 "Hard Gate(8项) + Soft Score(8项打分排序)" 已废弃——实测二次过滤+
// 打分排序打破 Director PZ 候选分布, 选出"奇怪位置被处决"（这也是用户困惑的根因）。
// InfectedBots 社区十几年实践的做法: 一次 L4D_GetRandomPZSpawnPosition 拿引擎给
// 的点, 找到就刷、找不到重试, 点位质量全权信任 Valve。
// 本插件在此之上保留两层原创保护（不改变候选分布, 只做快速重试）:
//   A) trigger_hurt 陷阱内 → 重试（v6.0.3 环境死亡实测）
//   B) 候选点→target NavPath 不通 → 重试
// 压力均衡（首中尾都面临特感）由 SISpawn_PickTarget（目标分配）保证: 每只 SI 以
// 自己分配到的 target 为参照锚取点 → 被盯谁, 点就刷在谁附近, 整队分段承压。
// 幽灵（出生后不知打谁 + 感知被卡）由出生目标注入（CommandABot → RESET）解决。
// ============================================================================

#define L4D_TEAM_SURVIVOR		2
#define L4D_TEAM_INFECTED		3


// v6.0.3: 出生点是否在伤害触发器(trigger_hurt 等"陷阱")包围盒内 → 一出生就被机关秒杀
// （实测 2026-08-18 波6: charger/spitter 出生 2.2s/2.7s "陷阱"秒死）。硬拒。
bool SISpawn_InHurtTrigger(const float pos[3]) {
	float mins[3], maxs[3], origin[3];
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "trigger_hurt")) != -1) {
		if (!IsValidEntity(ent))
			continue;
		GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
		GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
		mins[0] += origin[0]; mins[1] += origin[1]; mins[2] += origin[2];
		maxs[0] += origin[0]; maxs[1] += origin[1]; maxs[2] += origin[2];
		// 防止未初始化(全 0)的触发器把整个地图当命中 → 跳过
		if (mins[0] == 0.0 && mins[1] == 0.0 && mins[2] == 0.0
			&& maxs[0] == 0.0 && maxs[1] == 0.0 && maxs[2] == 0.0)
			continue;
		// 包围盒外扩 45u（SI 出生半径 + 一步可能踏入）
		if (pos[0] >= mins[0] - 45.0 && pos[0] <= maxs[0] + 45.0
			&& pos[1] >= mins[1] - 45.0 && pos[1] <= maxs[1] + 45.0
			&& pos[2] >= mins[2] - 45.0 && pos[2] <= maxs[2] + 45.0)
			return true;
	}
	return false;
}


// 候选点主入口（v6.5.0）: 信任引擎取点 + LOS/距离轻过滤。
// 参照锚 = 本只 SI 分配到的 intendedTarget（压力均衡由 SISpawn_PickTarget 保底）。
// 调 L4D_GetRandomPZSpawnPosition(target, class, attempts) 拿引擎给的点，
// 保留快速重试保护（trigger_hurt 陷阱 / NavPath 不通），新增距离硬门 +
// 可见性优先（可见立即采用，不可见追踪最近兜底，防饿死）。
// v6.1.3: 补位(30% reserve)用 250 硬门保证必补，首发用 400 保证反应时间
// v6.5.0: 三件套（实测日志驱动）——
//   A 分散降级: spread 拒掉的候选进降级池(离已刷点最远者胜), 主池全灭且
//     spread 主导时按 ss_spawn_spread_floor 放行（治抱团口袋 failClose 全灭饿死）
//   B 不可见兜底距离上限 ss_spawn_invis_max_dist（治出生即注定闲置处决的垃圾点）
//   C 可见性评估提前于分散检查（被拒可见点也能进降级池）
// 返回 false = 无合法点（欠账 catch-up，失败不耗波次预算）。
bool SISpawn_FindPosition(int zombieClass, int dir, int intendedTarget, float outPos[3], bool isReplacement=false) {

	if (intendedTarget <= 0 || intendedTarget > MaxClients
		|| !IsClientInGame(intendedTarget) || GetClientTeam(intendedTarget) != 2
		|| !IsPlayerAlive(intendedTarget))
		return false;

	float tp[3];
	GetClientAbsOrigin(intendedTarget, tp);
	Address targetNav = L4D_GetNearestNavArea(tp, 500.0, true, false, false, L4D_TEAM_INFECTED);

	int attempts = g_iCandidateSamples;		// 引擎取点尝试/保护重试轮数
	if (attempts < 2)
		attempts = 2;

	float p[3];
	float bestInvisPos[3];
	float bestInvisDist = 999999.0;
	bool hasInvisFallback = false;
	bool hasVisFallback = false;
	float bestVisDist = -1.0;
	float bestVisPos[3];
	int failEngine=0, failTrap=0, failNav=0, failDist=0, failClose=0, failFar=0;

	// v6.5.0(A) 分散降级池: 被分散规则拒掉的候选中"离已刷点最远"者
	// （可见优先于不可见；主池全灭且 spread 拒绝主导时按 ss_spawn_spread_floor 放行）
	float relaxVisSep = -1.0;
	float relaxVisPos[3];
	float relaxInvisSep = -1.0;
	float relaxInvisPos[3];

	for (int t = 0; t < attempts; t++) {
		g_iDirection = dir;		// 引擎 GetRandomPZSpawnPosition 读 PreferredSpecialDirection
		if (!L4D_GetRandomPZSpawnPosition(intendedTarget, zombieClass, 10, p)) {
			failEngine++;
			continue;			// 引擎取点失败 → 下一轮
		}

		// 快速重试保护①: 伤害触发器(陷阱)内 → 出生即死，重试
		if (SISpawn_InHurtTrigger(p)) {
			g_iBatchGuardTrap++;
			failTrap++;
			continue;
		}

		// 快速重试保护②: 候选点到 target 的 NavPath 不通 → 重试
		Address nav = L4D_GetNearestNavArea(p, 300.0, false, false, false, L4D_TEAM_INFECTED);
		if (nav == Address_Null) {
			failNav++;
			continue;
		}
		if (targetNav != Address_Null
			&& !L4D2_NavAreaBuildPath(nav, targetNav, g_fNavPathMax, L4D_TEAM_INFECTED, false)) {
			failNav++;
			continue;
		}

		// 距离硬门：离最近生还者必须 >= guard_min，防贴脸不变式
		// v6.1.3: 补位用250保证必补，首发用400保证2.5s反应
		float dist = DistanceToNearestSurvivor(p);
		float minDist = isReplacement ? 250.0 : g_cSpawnRangeGuardMin.FloatValue;
		if (dist < minDist) {
			failDist++;
			continue;
		}

		// v6.4.2 距离上限: 大开阔地候选普遍偏远(无遮挡全可见), 刷出后
		// 25s 闲置处决赶不到 → 硬门拒掉超远点(cvar 可调)
		if (dist > g_cSpawnDistMax.FloatValue) {
			failDist++;
			continue;
		}

		// v6.5.0(C) 可见性评估提前: 先判可见再决定去向——被分散规则拒掉的
		// 可见点不再直接丢弃, 转入降级池参与兜底（原顺序里它们连参赛资格都没有）
		bool vis = IsPosVisibleToAnySurvivor(p);

		// v6.1.4 分散刷：与本波已刷点位保持 250u 以上（防挤一处，透视聚堆）
		// v6.5.0(A) 拒掉的同时进降级池: 追踪"离已刷点最远"的落选候选。
		// 玩家抱团口袋里引擎只能反复给同一片点 → 主池全灭时按保底间隔放行,
		// 根治 failClose=24 全灭饿死（实测 08-23 单日 803 次）
		float sep = SISpawn_MinSepToPlaced(p);
		if (sep < 250.0) {
			failClose++;
			if (vis) {
				if (sep > relaxVisSep) { relaxVisSep = sep; relaxVisPos = p; }
			} else if (sep > relaxInvisSep) {
				relaxInvisSep = sep;
				relaxInvisPos = p;
			}
			continue;
		}

		// v6.4.2 可见候选择优: 追踪"最近可见点"(旧逻辑第一个可见即返回,
		// 开阔地会选中过远点), 全扫完取最近
		if (vis) {
			if (bestVisDist < 0.0 || dist < bestVisDist) {
				bestVisDist = dist;
				bestVisPos = p;
				hasVisFallback = true;
			}
			continue;
		}

		// v6.5.0(B) 不可见兜底距离上限: 太远的不可见点出生即注定闲置处决
		// （实测处决样本全部 visible=0、距离中位 828u），宁可欠账重试也不产垃圾
		if (dist > g_cInvisMaxDist.FloatValue) {
			failFar++;
			continue;
		}

		// 不可见候选：追踪距离最近的作为兜底（近 = 走几步就能看见）
		if (dist < bestInvisDist) {
			bestInvisDist = dist;
			bestInvisPos = p;
			hasInvisFallback = true;
		}
	}

	// v6.4.2: 有最近可见点 → 优先采用(可见>不可见优先级不变)
	if (hasVisFallback) {
		outPos = bestVisPos;
		return true;
	}

	// 全部尝试后无可见点 → 用最近的不可见点兜底（防饿死，目標注入 + 看门狗兜）
	if (hasInvisFallback) {
		outPos = bestInvisPos;
		return true;
	}

	// v6.5.0(A) 分散降级: 主池全灭且 spread 拒绝主导 → 采用降级池最优者。
	// 可见 > 不可见；间隔 ≥ ss_spawn_spread_floor 防真·叠罗汉。
	// 只动放行决策、不改变引擎候选分布（吸取 v6.0.0 打分排序翻车教训）。
	if (failClose > 0 && relaxVisSep >= g_cSpreadFloor.FloatValue) {
		outPos = relaxVisPos;
		LogMessage("[SS] FindPosition spread-relaxed class=%d target=%N sep=%.0f vis=1 failClose=%d", zombieClass, intendedTarget, relaxVisSep, failClose);
		return true;
	}
	if (failClose > 0 && relaxInvisSep >= g_cSpreadFloor.FloatValue) {
		outPos = relaxInvisPos;
		LogMessage("[SS] FindPosition spread-relaxed class=%d target=%N sep=%.0f vis=0 failClose=%d", zombieClass, intendedTarget, relaxInvisSep, failClose);
		return true;
	}

	// v6.4.1 引擎饥饿兜底(小优化): failEngine 全灭 = 地图地形性采样饥饿
	// (如 bdp 地堡狭窄通道, 9 人挤一处时引擎 PZ 采样器暂时饿死)。
	// 绕过引擎采样器, 直接以目标为圆心环形采地面点:
	//   距离 300-800u + 地面存在 + 与目标同层(±150u) + 离队 ≥guard_min
	// 通过后交回主流程走原有守卫(trap/nav/分散), 找不到才真正失败。
	if (failEngine >= attempts && failTrap == 0 && failNav == 0) {
		int ref = -1;
		float rPos[3];
		for (int i = 1; i <= MaxClients; i++) {
			if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
				ref = i;
				break;
			}
		}
		if (ref > 0) {
			GetClientAbsOrigin(ref, rPos);
			for (int t = 0; t < 10; t++) {
				float ang = GetURandomFloat() * 6.2831853;
				float d = GetRandomFloat(300.0, 800.0);
				float p[3];
				p[0] = rPos[0] + Cosine(ang) * d;
				p[1] = rPos[1] + Sine(ang) * d;
				p[2] = rPos[2] + 80.0;
				float gnd[3];
				gnd = p; gnd[2] -= 600.0;
				TR_TraceRayFilter(p, gnd, MASK_SOLID, RayType_EndPoint, TRFilter_SkipPlayers);
				if (!TR_DidHit()) continue;
				TR_GetEndPosition(gnd);
				if (FloatAbs(gnd[2] - rPos[2]) > 150.0) continue;
				gnd[2] += 5.0;
				float dist = DistanceToNearestSurvivor(gnd);
				float minDist = isReplacement ? 250.0 : g_cSpawnRangeGuardMin.FloatValue;
				if (dist < minDist) continue;
				if (SISpawn_MinSepToPlaced(gnd) < 250.0) continue;
				outPos = gnd;
				LogMessage("[SS] FindPosition engine-starve fallback OK class=%d dist=%.0f", zombieClass, dist);
				return true;
			}
			LogMessage("[SS] FindPosition engine-starve fallback exhausted (10 samples)");
		}
	}

	LogMessage("[SS] FindPosition FAILED class=%d target=%N attempts=%d failEngine=%d failTrap=%d failNav=%d failDist=%d failClose=%d failFar=%d hasInvis=%d", zombieClass, intendedTarget, attempts, failEngine, failTrap, failNav, failDist, failClose, failFar, hasInvisFallback);
	return false;
}

// 目标选择（调研 §20）: 不用所有 SI 都打最高 flow（前排会被集火）。
// 按 class profile 在"本只 SI 的战场段"内选人——独行类选孤立/边缘,
// 集群类选扎堆；spawn validator 是统一一套算法，变的只是 target selection。
int SISpawn_NeighborCount(int client, float radius) {
	int cnt = 0;
	float o[3];
	GetClientAbsOrigin(client, o);
	for (int s = 1; s <= MaxClients; s++) {
		if (s == client || !IsClientInGame(s) || GetClientTeam(s) != 2 || !IsPlayerAlive(s))
			continue;
		float so[3];
		GetClientAbsOrigin(s, so);
		if (GetVectorDistance(o, so) <= radius)
			cnt++;
	}
	return cnt;
}

int SISpawn_PickTarget(int zombieClass, int refMin, int refMax) {
	if (g_iBatchSurvivorCount <= 0)
		return -1;
	if (refMin < 0) refMin = 0;
	if (refMax >= g_iBatchSurvivorCount) refMax = g_iBatchSurvivorCount - 1;
	if (refMax < refMin) refMin = refMax;
	if (refMax < 0)
		return g_iBatchSurvivors[0];

	// 主序: round-robin —— 本波被盯次数最少的生还者优先（防止所有 SI 全锤 1-2 个人
	// → 出生点位全挤同一个口袋 → 聚集+坠落，见 2026-08-18 c2m1 首波 7 只同一坐标克隆）。
	// 次序(class profile): 独行类(smoker/hunter/jockey)选孤立/边缘, 集群类选扎堆——仅打平局。
	bool wantIsolated = (zombieClass == 1 || zombieClass == 3 || zombieClass == 5);	// smoker/hunter/jockey
	int best = 0;
	int bestCount = 999999999;		// 最低被盯次数
	int bestNB = -1;				// 队友数(tie-break)
	for (int k = refMin; k <= refMax; k++) {
		int s = g_iBatchSurvivors[k];
		if (!IsClientInGame(s) || GetClientTeam(s) != 2 || !IsPlayerAlive(s))
			continue;
		int count = g_iTargetCounts[s];
		int nb = SISpawn_NeighborCount(s, 380.0);
		bool betterCount = count < bestCount;
		bool sameCount = count == bestCount;
		bool betterNB = (wantIsolated ? nb < bestNB : nb > bestNB);
		if (best <= 0 || betterCount || (sameCount && betterNB)) {
			best = s;
			bestCount = count;
			bestNB = nb;
		}
	}
	if (best <= 0)
		best = g_iBatchSurvivors[refMin];
	return best;
}

// ---------- 出生目标注入（调研 §11/§A2/A3，本轮最重要的幽灵修复） ----------
// SI 出生 → L4D2_CommandABot(ATTACK 指定目标, 可绕过 BOT_CANT_SEE) → 短暂后 RESET
// 交还原版/AI_HardSI。CommandABot 是"出生引导器"，不是永久 SI AI。
void SISpawn_CancelInject(int client) {
	if (client < 1 || client > MaxClients)
		return;
	if (g_hSIInjectTimer[client] != null) {
		KillTimer(g_hSIInjectTimer[client]);
		g_hSIInjectTimer[client] = null;
	}
	g_bSIInjected[client] = false;
}

void SISpawn_ApplyTargetInject(int zombie, int target) {
	if (!g_bTargetInject || target <= 0)
		return;
	if (zombie < 1 || zombie > MaxClients || !IsClientInGame(zombie)
		|| !IsFakeClient(zombie) || GetClientTeam(zombie) != 3 || !IsPlayerAlive(zombie))
		return;
	SISpawn_CancelInject(zombie);
	g_bSIInjected[zombie] = true;
	L4D2_CommandABot(zombie, target, BOT_CMD_ATTACK);
	int waveID = g_iSIWaveID[zombie];
	DataPack dp = new DataPack();
	dp.WriteCell(zombie);
	dp.WriteCell(waveID);
	g_hSIInjectTimer[zombie] = CreateTimer(g_fTargetInjectTime, tmrCancelBotCommand, dp, TIMER_FLAG_NO_MAPCHANGE);
}

Action tmrCancelBotCommand(Handle timer, DataPack dp) {
	dp.Reset();
	int zombie = dp.ReadCell();
	int waveID = dp.ReadCell();
	delete dp;
	if (zombie < 1 || zombie > MaxClients || !IsClientInGame(zombie))
		return Plugin_Stop;
	// waveID 不符 = client 已被复用/新一波, 不再碰这个槽
	if (g_iSIWaveID[zombie] != waveID) {
		g_bSIInjected[zombie] = false;
		return Plugin_Stop;
	}
	g_hSIInjectTimer[zombie] = null;
	if (IsFakeClient(zombie) && GetClientTeam(zombie) == 3 && IsPlayerAlive(zombie))
		L4D2_CommandABot(zombie, 0, BOT_CMD_RESET);	// 交还原版/AI_HardSI
	g_bSIInjected[zombie] = false;
	return Plugin_Stop;
}

// ---------- 统一放置单只 SI（1926 行原 SpawnSliced 逐只逻辑 → 抽到这里） ----------
int SISpawn_PlaceOne(int zombieClass0, int dir, int refMin, int refMax, bool isReplacement) {
	int index = zombieClass0 + 1;	// 1..6
	g_iDirection = dir;
	int target = SISpawn_PickTarget(index, refMin, refMax);
	if (target <= 0)
		return 0;
	if (g_iTargetCounts[target] < 9999)	// 防溢出
		g_iTargetCounts[target]++;
	float vPos[3];
	if (!SISpawn_FindPosition(index, dir, target, vPos, isReplacement))
		return 0;

	vPos[2] += 5.0;
	int zombie = L4D2_SpawnSpecial(index, vPos, NULL_VECTOR);
	if (zombie <= 0)
		return 0;
	SetEntProp(zombie, Prop_Send, "m_bDucked", 1);
	SetEntityFlags(zombie, GetEntityFlags(zombie) | FL_DUCKING);

	g_iWaveSICount++;
	g_iSIWaveID[zombie] = g_iWaveSICount;
	g_fSISpawnTime[zombie] = GetGameTime();
	g_iSIWaveNum[zombie] = g_iWaveNumber;
	g_iSIClass[zombie] = zombieClass0;
	g_iSITarget[zombie] = target;
	g_bSIRecovered[zombie] = false;
	g_bSIRelocated[zombie] = false;
	g_fSILastNavDist[zombie] = -1.0;
	// v6.1.4 分散刷：记录本波已刷点位
	if (g_iBatchSpawnPosCount < 48) {
		g_fBatchSpawnPos[g_iBatchSpawnPosCount][0] = vPos[0];
		g_fBatchSpawnPos[g_iBatchSpawnPosCount][1] = vPos[1];
		g_fBatchSpawnPos[g_iBatchSpawnPosCount][2] = vPos[2];
		g_iBatchSpawnPosCount++;
	}

	SISpawn_ApplyTargetInject(zombie, target);

	// 观测计数（FinishWave 的 spawn guard 摘要用）：可见/隐藏分账
	bool placedVisible = IsPosVisibleToAnySurvivor(vPos);
	float euclid = DistanceToNearestSurvivor(vPos);
	if (placedVisible) {
		g_iBatchGuardVis++;
	} else {
		g_iBatchGuardInvis++;
		g_iBatchGuardInvisCount++;
		g_fBatchGuardInvisDistSum += euclid;
		if (euclid < g_cSpawnRangeGuard.FloatValue)
			g_iBatchGuardInvisNear++;
	}

	LogMessage("[SS] SI#%d-%d spawned: class=%s wave=%d target=%N pos=(%.0f,%.0f,%.0f) vis=%d%s",
		g_iWaveNumber, g_iSIWaveID[zombie], g_sZombieClass[zombieClass0],
		g_iWaveNumber, target, vPos[0], vPos[1], vPos[2],
		placedVisible, isReplacement ? " (replacement)" : "");
	// v6.1.1 起移除"已刷新"聊天播报（防刷屏；保留 LogMessage 生成日志）
	// if (!isReplacement)
	// 	PrintToChatAll("\x04[SI]\x01 %s#\x05%d-%d\x01 已刷新",
	// 		g_sZombieClass[zombieClass0], g_iWaveNumber, g_iSIWaveID[zombie]);
	return zombie;
}

// ---------- v6.0.1 坠落修复②: 安全换位（替换引擎 L4D_WarpToValidPositionIfStuck） ----------
// 用我们自己的 Hard Gate 找安全点（ground+hull+nav path 全保障）Teleport 过去；
// 找不到就不动位置只重注入。绝不把 SI 扔到引擎所谓的 "valid position"（可能在高台/悬崖）。
void SISpawn_RelocateSI(int client) {
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;
	int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (zClass < 1 || zClass > SI_MAX_SIZE)
		return;
	int target = g_iSITarget[client];
	if (target <= 0 || !IsClientInGame(target) || GetClientTeam(target) != 2 || !IsPlayerAlive(target)
		|| g_iBatchSurvivorCount <= 0) {
		LogMessage("[SS] ghost-relocate: %N no target/batch context, keep position", client);
		return;
	}
	int dir = g_bRandomDirection ? SPAWN_NO_PREFERENCE : SPAWN_LARGE_VOLUME;
	float p[3];
	if (SISpawn_FindPosition(zClass, dir, target, p)) {
		p[2] += 5.0;
		TeleportEntity(client, p, NULL_VECTOR, NULL_VECTOR);
		LogMessage("[SS] ghost-relocate: %N -> safe (%.0f,%.0f,%.0f)", client, p[0], p[1], p[2]);
	} else {
		LogMessage("[SS] ghost-relocate: %N NO safe spot found, keep position (re-inject only)", client);
	}
}

// ---------- 阻塞槽位欠账 catch-up（调研 §12/§14: 失败不耗预算, 稍后重采样） ----------
void SISpawn_ScheduleCatchup() {
	if (g_iBatchDebt <= 0 || g_bBatchCatchup)
		return;
	g_bBatchCatchup = true;
	if (g_hCatchupTimer == null)
		g_hCatchupTimer = CreateTimer(1.0, tmrCatchup, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action tmrCatchup(Handle timer) {
	g_hCatchupTimer = null;
	if (g_Phase != PHASE_PRESSURE) {
		g_bBatchCatchup = false;
		g_iBatchDebt = 0;
		return Plugin_Continue;
	}
	if (!g_bBatchCatchup)
		return Plugin_Continue;
	g_bBatchCatchup = false;
	if (g_iBatchDebt <= 0)
		return Plugin_Continue;

	int debt = g_iBatchDebt;
	g_iBatchDebt = 0;
	int dir = g_bBatchFind ? SPAWN_IN_FRONT_OF_SURVIVORS
		: (g_bRandomDirection ? SPAWN_NO_PREFERENCE : SPAWN_LARGE_VOLUME);
	int spawned = 0;
	g_bInSpawnTime = true;		// 让 L4D_OnGetScriptValueInt 的 PreferredSpecialDirection 目标生效
	for (int k = 0; k < debt; k++) {
		int zClass0 = GenerateIndex();
		if (zClass0 < 0)
			break;
		if (SISpawn_PlaceOne(zClass0, dir, 0, g_iBatchSurvivorCount - 1, false))
			spawned++;
	}
	g_bInSpawnTime = false;
	LogMessage("[SS] Catchup: debt=%d re-spawned=%d (blocked slots kept debt, retried once, no reserve spent)", debt, spawned);
	return Plugin_Continue;
}

// v1.7.0: 刷取队列 [from, to) 区间。每只特感按段类型决定方向与参照者子集，
// v6.0.0: 逐只交给 SISpawn_PlaceOne（Hard Gate + Soft Score + 目标注入）。
// 无任何"任意最近点"无条件 fallback；Hard Gate 不过就记欠账，由 catch-up 补。
// v6.4.0: 逐帧分散生成——旧版同帧循环整批连续 L4D2_SpawnSpecial(每只带
// 24 次采样搜索), 单帧引擎开销集中造成明显卡顿(用户实测)。改为每帧
// 处理一只(RequestFrame 链), 波次节奏不变、单帧成本摊平。
void SpawnSliced(int from, int to) {
	g_iSliceCursor = from;
	g_iSliceEnd = to;
	if (from >= to) {
		g_iBatchNext = to;
		SliceDone();
		return;
	}
	RequestFrame(TMR_SliceFrame, 0);
}

void TMR_SliceFrame(any data) {
	if (g_hBatchQueue == null || g_Phase != PHASE_PRESSURE) return;
	if (g_iSliceCursor >= g_iSliceEnd) {
		g_iBatchNext = g_iSliceEnd;
		SliceDone();
		return;
	}
	int i = g_iSliceCursor;
	{
		if (g_hBatchQueue == null) return;
		int zClass0 = g_hBatchQueue.Get(i);		// 0..5

		// 段类型 → 方向 + 参照者子集 [refMin, refMax]（闭区间）
		int dir;
		int refMin;
		int refMax;
		if (g_bFinaleStarted) {
			dir = SPAWN_NEAR_IT_VICTIM;
			refMin = 0;
			refMax = g_iBatchSurvivorCount - 1;
		} else if (!g_bBatchSegs) {
			// 紧凑队伍/未分段：v6.1.2 每只 SI 轮换方向，强制分散来向（防全聚一面）
			if (g_bBatchRetry) {
				dir = g_bBatchFind ? SPAWN_IN_FRONT_OF_SURVIVORS
					: (g_bRandomDirection ? SPAWN_NO_PREFERENCE : SPAWN_LARGE_VOLUME);
			} else if (g_bRandomDirection) {
				static const int dirCycle[4] = {
					SPAWN_NO_PREFERENCE,
					SPAWN_IN_FRONT_OF_SURVIVORS,
					SPAWN_BEHIND_SURVIVORS,
					SPAWN_ABOVE_SURVIVORS
				};
				dir = dirCycle[GetRandomInt(0, 3)];
			} else {
				dir = SPAWN_LARGE_VOLUME;
			}
			refMin = 0;
			refMax = g_iBatchSurvivorCount - 1;
		} else {
			int seg = g_iSegs[i];
			if (seg == 0) {
				dir = SPAWN_IN_FRONT_OF_SURVIVORS;
				refMin = 0;
				refMax = g_iBatchSegA - 1;
			} else if (seg == 1) {
				dir = SPAWN_NO_PREFERENCE;
				refMin = g_iBatchSegA;
				refMax = g_iBatchSegB - 1;
			} else {
				dir = SPAWN_BEHIND_SURVIVORS;
				refMin = g_iBatchSegB;
				refMax = g_iBatchSurvivorCount - 1;
			}
		}

		if (SISpawn_PlaceOne(zClass0, dir, refMin, refMax, false))
			g_iBatchSuccess++;
		else {
			g_iBatchGuardBlocked++;	// 观测: 被 Hard Gate 拦下的槽位数（饿死率）
			g_iBatchDebt++;			// v6.0.0: 失败不消耗波次预算，欠账稍后 catch-up 重采样
			LogMessage("[SS] Spawn FAILED class=%s targetRange=[%d,%d] dir=%d debt=%d", g_sZombieClass[zClass0], refMin, refMax, dir, g_iBatchDebt);
		}
	}
	g_iSliceCursor++;
	if (g_iSliceCursor < g_iSliceEnd)
		RequestFrame(TMR_SliceFrame, 0);
	else {
		g_iBatchNext = g_iSliceEnd;
		SliceDone();
	}
}

// ============================================================================
// v5.33: 70/30 Wave Budget — 补位刷怪
// 玩家击杀一只 SI → 从 reserve pool 补刷一只，保持波次压力。
// v6.0.0: 补位也走统一 Hard Gate + 目标注入引擎；失败不扣 reserve（下次击杀再试）。
// 返回 true=成功（调用方扣 reserve），false=失败（不消耗，下次击杀再试）。
// ============================================================================
bool SpawnReplacement() {
	if (g_iWaveReserve < 0) return false;
	if (GetTotalSI() >= g_iSILimit) return false;  // 场上已满，不补

	// 随机选一个 SI class（按权重）— P2: 去 jockey 跳过，首发/补位一致
	int totalWeight = 0;
	for (int i = 0; i < SI_MAX_SIZE; i++) {
		totalWeight += g_iSpawnWeights[i];
	}
	if (totalWeight <= 0) return false;

	int roll = GetRandomInt(0, totalWeight - 1);
	int class = 0;
	int accum = 0;
	for (int i = 0; i < SI_MAX_SIZE; i++) {
		accum += g_iSpawnWeights[i];
		if (roll < accum) {
			class = i;
			break;
		}
	}

	// 找一个存活幸存者存活性守卫（PlaceOne 内部仍会重新 PickTarget）
	int ref = -1;
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && GetClientTeam(i) == 2 && IsPlayerAlive(i)) {
			ref = i;
			break;
		}
	}
	if (ref <= 0) return false;
	if (g_iBatchSurvivorCount <= 0) return false;

	int dir = g_bRandomDirection ? SPAWN_NO_PREFERENCE : SPAWN_LARGE_VOLUME;
	g_bInSpawnTime = true;
	bool ok = SISpawn_PlaceOne(class, dir, 0, g_iBatchSurvivorCount - 1, true);
	g_bInSpawnTime = false;
	if (ok) {
		g_iWaveReserveSpawned++;
		// v6.1.1 起移除"补位"聊天播报（防刷屏；保留 LogMessage 补位日志）
		// PrintToChatAll("\x04[补位]\x01 %s 补刷成功（剩余 \x03%d\x01）",
		// 	g_sZombieClass[class], g_iWaveReserve - 1);
		LogMessage("[SS] Wave Budget: replacement OK class=%d reserve=%d", class, g_iWaveReserve - 1);
		return true;
	}
	// 生成失败：不减 budget（下次击杀还会再试）
	LogMessage("[SS] Wave Budget: replacement spawn FAILED class=%d, reserve=%d (will retry on next kill)",
		class, g_iWaveReserve);
	return false;
}

// v1.7.0: 分批续刷。下一片刷完若仍有剩余继续定时，否则收尾。
// v2.0.2: 相位守卫——续刷仅限压力期。历史: v2.0.0 tmrClearCheck 双重释放污染
// 句柄表后幽灵 timer 在冷静期提前触发（波 B 冷静期第 12s 刷出、无播报）。已给
// tmrSpawnSpecial 加 REST 守卫（v2.0.1），批次续刷是最后的无守卫刷怪入口：
// 正常流程收尾期只在全部批次出完后进入（不可能持有批次 timer），非 PRESSURE
// 触发 = 异常，忽略 + 记录。队列已释放的幽灵批次同样忽略（防空句柄访问）。
Action tmrBatchContinue(Handle timer) {
	g_hBatchTimer = null;

	// v2.4.0 刷新暂停防御: 外部插件暂停期间延迟批次释放
	if (g_bSpawningPaused) {
		LogMessage("[SS] 防御: 刷新暂停期间延迟批次释放，5 秒后重试");
		g_hBatchTimer = CreateTimer(5.0, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Continue;
	}

	if (g_Phase != PHASE_PRESSURE) {
		LogMessage("[SS] 防御: %s 期间忽略幽灵批次 timer", sPhaseNames[g_Phase]);
		return Plugin_Continue;
	}
	if (g_hBatchQueue == null) {
		LogMessage("[SS] 防御: 幽灵批次 timer 队列已释放");
		return Plugin_Continue;
	}

	int end = g_iBatchNext + g_iBatchBatchSize;
	if (end > g_iBatchTotal)
		end = g_iBatchTotal;

	// v6.4.0: 逐帧分散生成, 完成后走 SliceDone 批次分支
	g_iSliceCaller = 1;
	SpawnSliced(g_iBatchNext, end);
	return Plugin_Continue;
}

void SliceDone_Batch() {
	if (g_iBatchNext >= g_iBatchTotal) {
		// v5.33: reserve > 0 时不立即收尾——等补位完成或 CLEARING 硬上限兜底
		if (g_iWaveReserve > 0) {
			g_bInSpawnTime = false;
			LogMessage("[SS] Initial batch done, reserve=%d remaining — waiting for replacements", g_iWaveReserve);
		} else {
			FinishWave();
		}
	} else {
		g_hBatchTimer = CreateTimer(g_fBatchInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
	}
}

// v1.7.0: 整波收尾——guard 统计日志（跨批累计）、刷怪窗口关闭、retry 判定、
// 队列释放。
void FinishWave() {
	// v1.3.9/v1.4.1: 守卫统计（跳过 / 保底放行，波内有任何拦截才记一条，防日志刷屏）
	// v2.6.0: invis-fb 行追加 near=B 档计数 + avgDist 平均距离（观测幽灵修复效果）
	if (g_iBatchGuardBlocked || g_iBatchGuardVis || g_iBatchGuardInvis || g_iBatchGuardTrap) {
		LogMessage("[SS] spawn guard: %d/%d skipped, %d trap-reject, %d vis-fb(>=%.0f), %d invis-fb(near=%d avgDist=%.0f), prefer >=%.0f, dir=%d",
			g_iBatchGuardBlocked, g_iBatchTotal, g_iBatchGuardTrap,
			g_iBatchGuardVis, g_cSpawnRangeGuardMin.FloatValue,
			g_iBatchGuardInvis, g_iBatchGuardInvisNear,
			g_iBatchGuardInvisCount > 0 ? g_fBatchGuardInvisDistSum / g_iBatchGuardInvisCount : 0.0,
			g_cSpawnRangeGuard.FloatValue, g_iDirection);
	}

	g_bInSpawnTime = false;

	// v5.33: Wave Budget 结算日志
	if (g_iWaveBudget > 0) {
		LogMessage("[SS] Wave Budget summary: budget=%d initial=%d reserve=%d kills=%d replacements=%d",
			g_iWaveBudget, g_iWaveInitial, g_iWaveReserve, g_iWaveKills, g_iWaveReserveSpawned);
		// v5.33: 列出本波所有 SI 的最终状态
		int waveSI = 0, waveKilled = 0, waveAlive = 0;
		for (int i = 1; i <= MaxClients; i++) {
			if (g_iSIWaveNum[i] == g_iWaveNumber) {
				waveSI++;
				if (IsClientInGame(i) && IsPlayerAlive(i))
					waveAlive++;
				else
					waveKilled++;
			}
		}
		LogMessage("[SS] Wave #%d lifecycle: total_spawned=%d alive=%d killed=%d", g_iWaveNumber, waveSI, waveAlive, waveKilled);
		// v6.2.0 损失率预览（最终损失率在 EnterRest 结算，处决可能发生在 CLEARING 轮询期间）
		if (g_iWaveBudget > 0 && g_iWaveSystemKills > 0) {
			LogMessage("[SS] Wave #%d loss preview: sysKills=%d budget=%d loss=%.0f%% playerKills=%d", g_iWaveNumber, g_iWaveSystemKills, g_iWaveBudget, float(g_iWaveSystemKills)/float(g_iWaveBudget)*100.0, g_iWaveKills);
		}
		// v5.33 波次结算聊天摘要：v6.1.1 起移除（防刷屏；保留 LogMessage；剿灭提示仍保留）
		// PrintToChatAll("\x04[SI]\x01 第 \x05%d\x01 波结算：实际刷新 \x03%d\x01，玩家击杀 \x05%d\x01，补位 \x05%d\x01，存活 \x03%d\x01",
		// 	g_iWaveNumber, waveSI, g_iWaveKills, g_iWaveReserveSpawned, waveAlive);
	}

	if (g_bBatchRetry) {
		if (!g_iBatchSuccess) {
			#if DEBUG
			PrintToServer("[SS] Retry spawn SI! spawned:%d failed:%d", g_iBatchSuccess, g_iBatchTotal - g_iBatchSuccess);
			#endif
			g_hRetryTimer = CreateTimer(1.0, tmrRetrySpawn, false);
		}
	}
	#if DEBUG
	else {
		if (!g_iBatchSuccess)
			PrintToServer("[SS] Spawn SI failed! spawned:%d failed:%d", g_iBatchSuccess, g_iBatchTotal - g_iBatchSuccess);
	}
	#endif

	// v2.0.0 波间三态: 收尾转换——retry 波仍在压力期（其 FinishWave 才收尾）
	if (!g_hRetryTimer)
		EnterClearing();

	if (g_hBatchQueue) {
		delete g_hBatchQueue;
		g_hBatchQueue = null;
	}
}

// ============ v2.0.0 波间三态（压力/收尾/冷静） ============

// 进入收尾期: 2s 轮询清场。清场（总特感 ≤ 清剿阈值）→ 冷静期; 自压力期开始超
// ss_rest_force 秒强制冷静（防留特/僵局拖死节奏——留特者被 25s 处决自然清场,
// 保持可见威胁的极端留特由硬上限兜底）。终章同样走三态（终章压力由引擎潮水/
// Tank 事件兜底, 本插件只是额外功能层）。
void EnterClearing() {
	g_Phase = PHASE_CLEARING;
	if (g_iClearThreshold < 2)
		g_iClearThreshold = 2;		// reload 兜底: 全局清零后保底 2
	KillClearTimer();				// v2.0.1: 防御 delete（句柄可能已被 SM 释放, 裸 delete 抛错中断状态机）
	g_hClearTimer = CreateTimer(2.0, tmrClearCheck, _, TIMER_REPEAT);
	LogMessage("[SS] phase: PRESSURE -> CLEARING (阈值 %d)", g_iClearThreshold);
}

// v2.0.1: 防御性清除收尾轮询 timer——句柄可能已被 SM 在 Plugin_Stop 收尾时释放
// （历史: 回调自删 REPEAT timer 双重释放 + 相位转移路径不置 null → 悬空句柄 →
// 裸 delete 抛 "Handle is invalid" → EnterClearing 中断, 状态机卡死, 波次失控）。
void KillClearTimer() {
	if (g_hClearTimer != null) {
		if (IsValidHandle(g_hClearTimer))
			delete g_hClearTimer;
		g_hClearTimer = null;
	}
}

Action tmrClearCheck(Handle timer) {
	// 防御: 相位被处决补波等转移后不再轮询（只置空不 delete——v2.0.1:
	// Plugin_Stop 会让 SM 自动释放本 timer, 回调内手动 delete 自己的
	// REPEAT 句柄 = 双重释放, 实测污染 SM 句柄表触发后续连锁错误）
	if (g_Phase != PHASE_CLEARING) {
		g_hClearTimer = null;
		return Plugin_Stop;
	}

	// v2.2.0 清缴挂起检查：外部插件（Tank 波等）要求强制等待，跳过常规判定
	if (g_bClearingHeld) {
		return Plugin_Continue;	// 继续轮询，直到外部释放挂起
	}

	if (GetTotalSI() <= g_iClearThreshold || GetEngineTime() - g_fPhaseEnterTime >= g_cRestForce.FloatValue) {
		g_hClearTimer = null;
		EnterRest();
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

// 进入冷静期: 25-35s 零特感压力倒计时（缓冲节点）, 播报总倒计时（冷静期 +
// 下一波间隔, 确定性可算 → 数字精确）。PrintToChatAll——不用 PrintHintText
// （L4D2 CJK hint 首条渲染乱码 bug）。
// 2026-08-16 压力系统废弃: 冷静期固定走 cfg 的 ss_rest_min/max（25-35s）。
// 旧 v2.1.0 tier 覆盖有个遗留坑: g_iCurrentPressureTier 默认 T2 → 走
// GetRestRangeByTier(2) 的 12-15s, cfg 设计值 25-35s 从未生效（记忆库
// l4d2-rest-tier-override-bug）。清理后回归设计值。
// v5.24: PostRest 下限归零后播报 = 冷静期本身（25-35s），与"冷静期=下一波
// 间隔"的用户预期一致（旧 20-25s 波间隔钉值是 12-18s 冷静期时代的配套）。
// v5.25: 冷静期抽取移到 SS_OnWaveRest 通知之后 —— tank_wave_mutator 在
// forward 里判定"下一波是否 Tank"并可能把 ss_rest_min/max ×1.5（用户设计：
// Tank 波前冷静期 37.5-52.5s）。先通知后抽取才能让倍率作用于本波。
void EnterRest() {
	// v6.7.0 补偿剿灭下一波惩罚判定（出现损伤过多→下一波冷静期+6s，Tank概率3%）
	bool bCompClear = false;
	if (g_bWaveStarted && g_iWaveDownDeaths > 0) {
		float ratioComp = g_iWaveBase > 0 ? float(g_iWaveDownDeaths) / float(g_iWaveBase) : 0.0;
		if (ratioComp >= g_cClearCompRatio.FloatValue) bCompClear = true;
	}
	if (bCompClear) {
		if (g_cCompNextTankChance != null) g_cCompNextTankChance.SetFloat(0.03);
	} else {
		if (g_cCompNextTankChance != null && g_cCompNextTankChance.FloatValue >= 0.0) g_cCompNextTankChance.SetFloat(-1.0);
	}

	// 1) 先通知（tank_wave_mutator 判定下一波 + 可能调整 ss_rest cvar ×1.5）。
	//    参数传 0.0 占位：当前消费者（tank_mutator/si_comp）不使用该值，
	//    播报在 rest 抽取后重新计算，保证数字精确。
	Call_StartForward(g_fwdOnWaveRest);
	Call_PushFloat(0.0);
	Call_Finish();

	// 2) 抽取冷静期（读调整后的 cvar：非 Tank 25-35s / Tank 波 ×1.5）
	// v6.3.0 完美剿灭奖励: 波内无人倒地/死亡 → 改抽 ss_rest_perfect_* (20-30s)
	// 覆盖优先级最高(Tank 缩放也让位于完美奖励); 之后仍走损失率压缩
	float restMin = g_cRestMin.FloatValue;
	float restMax = g_cRestMax.FloatValue;
	bool bPerfectClear = (g_bWaveStarted && g_iWaveDownDeaths == 0);
	if (bPerfectClear)
	{
		restMin = g_cRestPerfMin.FloatValue;
		restMax = g_cRestPerfMax.FloatValue;
	}
	float rest = Math_GetRandomFloat(restMin, restMax);
	if (rest < 1.0)
		rest = 1.0;
	// v6.2.0 损失率补偿：系统处决占比 → 缩短冷静期找回节奏
	// 公式 rest' = rest * (1 - loss*scale), 钳制 ≥ ss_loss_rest_min (保底 10s)
	// loss = 系统处决数 / 本波预算（例 10应刷/3处决=30% → 20s*0.7=14s）
	float restOrig = rest;
	if (g_bLossCompEnable && g_fLossRestScale > 0.0 && g_bWaveStarted && g_iWaveBudget > 0) {
		float lossRate = float(g_iWaveSystemKills) / float(g_iWaveBudget);
		if (lossRate < 0.0) lossRate = 0.0;
		if (lossRate > 1.0) lossRate = 1.0;
		g_fWaveLossRate = lossRate;
		if (lossRate > 0.001) {
			float restComp = rest * (1.0 - lossRate * g_fLossRestScale);
			if (restComp < g_fLossRestMin)
				restComp = g_fLossRestMin;
			if (restComp < 1.0)
				restComp = 1.0;
			if (restComp < rest) {
				LogMessage("[SS] Loss comp REST: budget=%d sysKill=%d loss=%.0f%% rest %.1f->%.1f (scale=%.2f min=%.1f)", g_iWaveBudget, g_iWaveSystemKills, lossRate*100.0, rest, restComp, g_fLossRestScale, g_fLossRestMin);
				rest = restComp;
			}
		}
	} else {
		// 非补偿波：清零损失率（零波/关闭时不带入下一波）
		if (!g_bWaveStarted || g_iWaveBudget <= 0)
			g_fWaveLossRate = 0.0;
		else if (!g_bLossCompEnable)
			g_fWaveLossRate = 0.0;
	}
	// v6.7.0 补偿剿灭惩罚: 下一波冷静期额外+6s
	if (bCompClear && g_cCompRestBonus != null) {
		float bonus = g_cCompRestBonus.FloatValue;
		if (bonus > 0.0) {
			rest += bonus;
			LogMessage("[SS] Comp bonus REST: +%.1fs (comp tier)", bonus);
		}
	}
	g_Phase = PHASE_REST;
	if (g_hRestTimer != null && IsValidHandle(g_hRestTimer))
		delete g_hRestTimer;
	g_hRestTimer = CreateTimer(rest, tmrRestEnd);
	g_fRestEndTime = GetEngineTime() + rest;   // v2.5.4: 记录到期时刻（暂停冻结用）
	if (rest != restOrig)
		LogMessage("[SS] phase: CLEARING -> REST (%.1fs orig %.1fs, loss %.0f%%)%s", rest, restOrig, g_fWaveLossRate*100.0, bPerfectClear ? " [PERFECT]" : "");
	else
		LogMessage("[SS] phase: CLEARING -> REST (%.1fs)%s", rest, bPerfectClear ? " [PERFECT]" : "");

	// v2.2.0 触发 REST forward（传入总倒计时秒数，供外部插件预警）
	float totalCountdown = rest + GetPostRestInterval();
	// v5.24 诊断：打印播报构成（定位播报异常时使用；稳定后可移除）
	LogMessage("[SS] REST countdown: rest=%.1f postRest=%.1f total=%.1f (spawnTimeMax=%.1f avgRest=%.1f)",
		rest, GetPostRestInterval(), totalCountdown, g_fSpawnTimeMax,
		(g_cRestMin.FloatValue + g_cRestMax.FloatValue) * 0.5);

	// v2.5.0 剿灭得分结算（发钱 + 播报合并进清剿完成消息；原"波次清剿完毕"播报由
	// SettleWaveClearScore 内部按零波/关闭时兜底输出）
	SettleWaveClearScore(totalCountdown);
}

// v6.6.0 完美剿灭实血奖励: 虚实合计≤100，满额虚转实
stock int SS_GetTempHealth(int client) {
	float buffer = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
	float time = GetEntPropFloat(client, Prop_Send, "m_healthBufferTime");
	ConVar cv = FindConVar("pain_pills_decay_rate");
	float decay = cv != null ? cv.FloatValue : 0.27;
	float cur = buffer - (GetGameTime() - time) * decay;
	if (cur < 0.0) cur = 0.0;
	return RoundToCeil(cur);
}
stock void SS_SetSurvivorHealth(int client, int perm, int temp) {
	if (perm < 0) perm = 0; if (perm > 100) perm = 100;
	if (temp < 0) temp = 0; if (temp > 100) temp = 100;
	SetEntProp(client, Prop_Send, "m_iHealth", perm);
	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", float(temp));
	SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
}
void RewardPerfectHealth(int &healthGiven, int &pointGiven) {
	healthGiven = 0; pointGiven = 0;
	int bonus = g_cPerfectHealthBonus != null ? g_cPerfectHealthBonus.IntValue : 5;
	if (bonus <= 0) return;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
		if (!IsPlayerAlive(i)) continue;
		if (GetEntProp(i, Prop_Send, "m_isIncapacitated")) continue;
		if (GetEntProp(i, Prop_Send, "m_isHangingFromLedge")) continue;
		int perm = GetEntProp(i, Prop_Send, "m_iHealth");
		if (perm >= 100) {
			if (GetFeatureStatus(FeatureType_Native, "SH_AddWallet") == FeatureStatus_Available) {
				SH_AddWallet(i, 50);
			}
			pointGiven++;
			LogMessage("[SS] Perfect bonus: %N perm 100 -> +50 points (instead of health)", i);
			continue;
		}
		int temp = SS_GetTempHealth(i);
		int totalBefore = perm + temp;
		int newPerm, newTemp;
		if (totalBefore >= 100) {
			newPerm = perm + bonus;
			if (newPerm > 100) newPerm = 100;
			newTemp = totalBefore - newPerm;
			if (newTemp < 0) newTemp = 0;
			if (newTemp > 100) newTemp = 100;
		} else {
			newPerm = perm + bonus;
			newTemp = temp;
			if (newPerm + newTemp > 100) newPerm = 100 - newTemp;
			if (newPerm > 100) newPerm = 100;
			if (newPerm < 0) newPerm = 0;
		}
		if (newPerm == perm && newTemp == temp) continue;
		SS_SetSurvivorHealth(i, newPerm, newTemp);
		healthGiven++;
		LogMessage("[SS] Perfect health +%d: %N %d+%d=%d -> %d+%d=%d", bonus, i, perm, temp, totalBefore, newPerm, newTemp, newPerm+newTemp);
	}
}

// v2.5.0 剿灭得分结算（用户设计 2026-08-17 拍板）:
// 三档互斥 —— 完美（波内无人倒地/死亡）= ss_clear_score_perfect(350) /
// 补偿（倒地/死亡去重人数 ≥ 队伍人数×ss_clear_comp_ratio）= ss_clear_score_comp(275) /
// 基础（其余）= ss_clear_score_base(200)。Tank 波三档同乘 ss_clear_tank_mult(3)。
// 发放对象 = 当前生还队全体（含 bot，与过关奖励同口径），每人各得对应分数。
// 播报: [特感] 本波次剿灭完成，<档位>全体 +X 分，下一波来袭 X 秒
// 零波（未刷出特感）或全部关闭: 不发分, 保持原"波次清剿完毕"播报。
void SettleWaveClearScore(float totalCountdown) {
	g_bWaveActive = false;

	int total = RoundToNearest(totalCountdown);
	int score = 0;
	float timeMult = 1.0;		// v2.5.1 时间倍率（默认 1.0, 快速清剿时 >1）
	char tier[64];
	char tankTag[32];
	tankTag[0] = '\0';

	if (g_bWaveStarted) {
		if (g_iWaveDownDeaths == 0) {
			score = g_cClearScorePerfect.IntValue;
			strcopy(tier, sizeof(tier), "完美剿灭");
		} else {
			float ratio = g_iWaveBase > 0 ? float(g_iWaveDownDeaths) / float(g_iWaveBase) : 0.0;
			if (ratio >= g_cClearCompRatio.FloatValue) {
				score = g_cClearScoreComp.IntValue;
				strcopy(tier, sizeof(tier), "剿灭补偿");
			} else {
				score = g_cClearScoreBase.IntValue;
				strcopy(tier, sizeof(tier), "剿灭得分");
			}
		}

		// Tank 波（tank_wave_mutator 突变, SS_MarkWaveTank）三档同乘倍率
		if (g_bWaveHadTank && g_cClearTankMult.FloatValue > 1.0) {
			score = RoundToNearest(float(score) * g_cClearTankMult.FloatValue);
			strcopy(tankTag, sizeof(tankTag), "☠Tank波 ");
		}

		// v2.5.1 时间倍率（用户设计）: 从特感刷新播报(波次开始)起算 1.5×,
		// 每秒 -0.015, 下限 1.0（≈30s 回 1×）——清剿越快奖励越高。
		// v2.5.2: 倍率只计入得分, 播报不再标注括号内容（用户拍板, 保持播报简洁）。
		timeMult = g_cClearTimeMultStart.FloatValue
			- g_cClearTimeMultDecay.FloatValue * (GetEngineTime() - g_fWaveStartTime);
		if (timeMult < 1.0)
			timeMult = 1.0;
		if (timeMult > 1.0)
			score = RoundToNearest(float(score) * timeMult);

		// v6.2.0 损失率得分扣减：系统处决占比 → 扣减剿灭得分（少威胁少奖励）
		// 公式 score' = score * (1 - loss*scale), 例 200*(1-0.3)=140；钳 ≥0
		if (g_bLossCompEnable && g_fLossScoreScale > 0.0 && g_fWaveLossRate > 0.001) {
			int scoreOrig = score;
			float lossFactor = 1.0 - g_fWaveLossRate * g_fLossScoreScale;
			if (lossFactor < 0.0) lossFactor = 0.0;
			score = RoundToNearest(float(score) * lossFactor);
			LogMessage("[SS] Loss deduct SCORE: loss=%.0f%% scale=%.2f %d->%d (timeMult=%.2f)", g_fWaveLossRate*100.0, g_fLossScoreScale, scoreOrig, score, timeMult);
		}
	}

	int healthBonus = 0, pointBonus = 0;
	// v6.6.0 完美剿灭实血奖励: 完美时全体存活站立者 +5实血，满实血转50分（实+虚≤100，满额虚转实）
	if (g_bWaveStarted && g_iWaveDownDeaths == 0) {
		RewardPerfectHealth(healthBonus, pointBonus);
	}
	if (score > 0) {
		// 入账: 全体生还者（含 bot; si_hud 未加载时静默跳过——optional native 守卫）
		if (GetFeatureStatus(FeatureType_Native, "SH_AddWallet") == FeatureStatus_Available) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && GetClientTeam(i) == 2)
					SH_AddWallet(i, score);
			}
		}
		// v2.5.3 FIX: LogMessage 格式串参数不匹配（v2.5.0-2.5.2: downDeaths=%d/%d 缺
		// 第二个值 + tank=%s 传 int）→ 每次结算抛 "String formatted incorrectly"
		// 异常 → 函数中断 → 剿灭播报永远不显示（分已入账）。8 格式符 ↔ 8 参数。
		LogMessage("[SS] Clear score: tier=%s score=%d downDeaths=%d/%d base=%d tank=%d next=%ds (timeMult=%.2f loss=%.0f%% sys=%d/%d) health=%d points=%d",
			tier, score, g_iWaveDownDeaths, g_iWaveBase, g_iWaveBase,
			g_bWaveHadTank ? 1 : 0, total, timeMult, g_fWaveLossRate*100.0, g_iWaveSystemKills, g_iWaveBudget, healthBonus, pointBonus);
		if (StrEqual(tier, "完美剿灭")) {
			// 统一播报 +5生命，满血者静默转50分不单独播报
			PrintToChatAll("\x04[特感]\x01 本波次剿灭完成，\x03%s%s\x01全体\x05+%d\x01分 \x05+5生命\x01，下一波来袭 \x05%d\x01 秒",
				tankTag, tier, score, total);
		} else {
			PrintToChatAll("\x04[特感]\x01 本波次剿灭完成，\x03%s%s\x01全体 \x05+%d\x01 分，下一波来袭 \x05%d\x01 秒",
				tankTag, tier, score, total);
		}
	} else {
		// 零波或关闭: 保持原播报
		PrintToChatAll("\x04[特感]\x01 波次清剿完毕，\x05%d\x01 秒后下一波", total);
	}
}

// 冷静期后的下一波间隔 = 波间隔钉值 − 平均冷静时长（冷静期吃掉波间隔前段,
// 总波周期仍 ≈ 钉值 40-55, 不会"休息完再等满 40-55"）。si_comp 每波把
// ss_time_min/max 钉为随机(40,55), g_fSpawnTimeMax 即当前钉值。
// v5.24 FIX: 下限 clamp 10.0→0.0 —— 2026-08-16 压力系统清理后冷静期回归
// 设计值 25-35s（旧 tier 时代 12-18s 的配套波间隔 20-25s 已错位：冷静期 +
// PostRest 播报出 43s，与"冷静期最大 35s"的预期矛盾）。现在冷静期本身
// 25-35s 已是完整缓冲，结束后立即进入下一波计时（PostRest 仅当波间隔钉值
// > 冷静期均值时才补剩余差额，< 时归零），播报回到 25-35s。
float GetPostRestInterval() {
	float avgRest = (g_cRestMin.FloatValue + g_cRestMax.FloatValue) * 0.5;
	float interval = g_fSpawnTimeMax - avgRest;
	if (interval < 0.0)
		interval = 0.0;
	if (interval > 45.0)
		interval = 45.0;
	return interval;
}

// 冷静期结束: 排下一波 timer（相位回 IDLE, 持有待命波 timer）
void StartPostRestTimer() {
	EndSpawnTimer();
	g_hSpawnTimer = CreateTimer(GetPostRestInterval(), tmrSpawnSpecial);
	LogMessage("[SS] phase: REST -> IDLE (下一波 %.1fs)", GetPostRestInterval());
}

Action tmrRestEnd(Handle timer) {
	g_hRestTimer = null;
	g_Phase = PHASE_IDLE;
	StartPostRestTimer();
	return Plugin_Continue;
}

// 中止并重置波次生命周期（admin 命令 / 换图 / 卸载复用; 不碰自杀 timer）
void ResetLifecycle() {
	g_Phase = PHASE_IDLE;
	g_bClearingHeld = false;	// v2.2.0 释放清缴挂起（防换图/reload 残留）
	KillClearTimer();
	if (g_hRestTimer != null && IsValidHandle(g_hRestTimer))
		delete g_hRestTimer;
	g_hRestTimer = null;
	delete g_hBatchTimer;
	// v6.0.0: 清掉 catch-up timer + 全部剩余目标注入 RESET timer
	if (g_hCatchupTimer != null) {
		KillTimer(g_hCatchupTimer);
		g_hCatchupTimer = null;
	}
	// v5.37 FIX: 换图后 g_hReserveTimer 残留 —— reserve 兜底 timer 用 TIMER_FLAG_NO_MAPCHANGE，
	// 换图被引擎自动杀但变量未置 null → 下一波 ExecuteSpawnQueue:2018 KillTimer 对失效句柄抛异常
	// → 函数中止、SpawnSliced 不执行 → 整波 0 特感（2026-08-20 li_c1m3 实机：21:06 起 total_spawned=0）。
	// OnMapEnd/ResetLifecycle 时刻该 timer 仍有效，安全 KillTimer。
	if (g_hReserveTimer != null) {
		KillTimer(g_hReserveTimer);
		g_hReserveTimer = null;
	}
	g_bBatchCatchup = false;
	g_iBatchDebt = 0;
	for (int c = 1; c <= MaxClients; c++)
		SISpawn_CancelInject(c);
	if (g_hBatchQueue) {
		delete g_hBatchQueue;
		g_hBatchQueue = null;
	}
}

// v1.3.9: 落点离最近存活生还者的距离（含倒地，IsPlayerAlive 对倒地返回 true）。
// 3D 距离——垂直贴脸（头顶实体/高台正上方）同样拦截。
// v6.5.0: 候选点与本波已刷点位的最近间隔（分散刷/降级池共用）
float SISpawn_MinSepToPlaced(const float pos[3]) {
	float best = 999999.0;
	for (int k = 0; k < g_iBatchSpawnPosCount; k++) {
		float d = GetVectorDistance(pos, g_fBatchSpawnPos[k]);
		if (d < best)
			best = d;
	}
	return best;
}

float DistanceToNearestSurvivor(const float pos[3]) {
	float best = 999999.0;
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsClientInGame(s) || GetClientTeam(s) != 2 || !IsPlayerAlive(s))
			continue;
		float o[3];
		GetClientAbsOrigin(s, o);
		float d = GetVectorDistance(pos, o);
		if (d < best)
			best = d;
	}
	return best;
}

// v1.4.0: 刷点是否至少能看见一个存活生还者（LOS 通畅）。
// 看不见人的刷点 → m_hasVisibleThreats 恒 false → 25s 自杀计时处决（玩家实测
// "刷新基本都被处决"）。MASK_VISIBLE + RayType_EndPoint，filter 跳过所有玩家
// 实体（终点就是生还者 eye，不排除会被误判成遮挡）。
bool IsPosVisibleToAnySurvivor(const float pos[3]) {
	for (int s = 1; s <= MaxClients; s++) {
		if (!IsClientInGame(s) || GetClientTeam(s) != 2 || !IsPlayerAlive(s))
			continue;
		float eye[3];
		GetClientEyePosition(s, eye);
		TR_TraceRayFilter(pos, eye, MASK_VISIBLE, RayType_EndPoint, TRFilter_SkipPlayers);
		if (!TR_DidHit())
			return true;
	}
	return false;
}

bool TRFilter_SkipPlayers(int entity, int contentsMask, any data) {
	return entity < 1 || entity > MaxClients;
}

Action tmrRetrySpawn(Handle timer, bool retry) {
	g_hRetryTimer = null;

	// v2.4.0 刷新暂停防御: 外部插件暂停期间延迟重试
	if (g_bSpawningPaused) {
		LogMessage("[SS] 防御: 刷新暂停期间延迟重试波，5 秒后重试");
		g_hRetryTimer = CreateTimer(5.0, tmrRetrySpawn, retry);
		return Plugin_Continue;
	}

	// v5.33: 只允许压力期补波——CLEARING 阶段波已进入收尾，不再重开整波
	//（防"第X波"重复播报）。原 v2.0.0 允许 CLEARING 补波，配合处决制retry
	// 造成波次重复，已废弃。
	if (g_Phase != PHASE_PRESSURE)
		return Plugin_Continue;

	// v2.0.0 retry 波属压力期: 重置 120s 硬上限锚点; 从收尾期转移须撤轮询 timer
	g_fPhaseEnterTime = GetEngineTime();
	g_Phase = PHASE_PRESSURE;
	if (!ExecuteSpawnQueue(GetTotalSI(), retry))
		EnterClearing();
	return Plugin_Continue;
}

int GetTotalSI() {
	int count = 0;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsClientInKickQueue(i) || GetClientTeam(i) != 3)
			continue;
	
		if (IsPlayerAlive(i)) {
			int zc = GetEntProp(i, Prop_Send, "m_zombieClass");
			if (1 <= zc && zc <= 6)
				count++;
		}
		else if (IsFakeClient(i))
			KickClient(i);
	}
	return count;
}

void GetSITypeCount() {
	int i;
	for (; i < SI_MAX_SIZE; i++)
		g_iSpawnCounts[i] = 0;

	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsClientInKickQueue(i)|| GetClientTeam(i) != 3 || !IsPlayerAlive(i))
			continue;

		switch (GetEntProp(i, Prop_Send, "m_zombieClass")) {
			case 1:
				g_iSpawnCounts[SI_SMOKER]++;

			case 2:
				g_iSpawnCounts[SI_BOOMER]++;

			case 3:
				g_iSpawnCounts[SI_HUNTER]++;

			case 4:
				g_iSpawnCounts[SI_SPITTER]++;

			case 5:
				g_iSpawnCounts[SI_JOCKEY]++;
		
			case 6:
				g_iSpawnCounts[SI_CHARGER]++;
		}
	}
}

int GenerateIndex() {	
	static int i;
	static int totalWeight;
	static int standardizedWeight;
	static int tempWeights[SI_MAX_SIZE];
	static float unit;
	static float random;
	static float intervalEnds[SI_MAX_SIZE];

	totalWeight = 0;
	standardizedWeight = 0;

	for (i = 0; i < SI_MAX_SIZE; i++) {
		tempWeights[i] = g_iSpawnCounts[i] < g_iSpawnLimits[i] ? (g_bScaleWeights ? ((g_iSpawnLimits[i] - g_iSpawnCounts[i]) * g_iSpawnWeights[i]) : g_iSpawnWeights[i]) : 0;
		totalWeight += tempWeights[i];
	}

	unit = 1.0 / totalWeight;
	for (i = 0; i < SI_MAX_SIZE; i++) {
		if (tempWeights[i] >= 0) {
			standardizedWeight += tempWeights[i];
			intervalEnds[i] = standardizedWeight * unit;
		}
	}

	random = Math_GetRandomFloat(0.0, 1.0);
	for (i = 0; i < SI_MAX_SIZE; i++) {
		if (tempWeights[i] > 0 && intervalEnds[i] >= random)
			return i;
	}

	return -1;
}

// https://github.com/bcserv/smlib/blob/transitional_syntax/scripting/include/smlib/math.inc
float Math_GetRandomFloat(float min, float max) {
	return (GetURandomFloat() * (max  - min)) + min;
}
