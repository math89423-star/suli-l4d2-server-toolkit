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
	// v2.5.0 剿灭得分（三档互斥, 波次清缴完成时全体生还者每人得分）
	g_cClearScoreBase,
	g_cClearScorePerfect,
	g_cClearScoreComp,
	g_cClearCompRatio,
	g_cClearTankMult,
	// v2.5.1 剿灭得分时间倍率（用户设计: 刷新播报起 1.5×, 每秒 -0.015, 下限 1.0）
	g_cClearTimeMultStart,
	g_cClearTimeMultDecay;

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
	g_bRandomDirection;

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
	g_iBatchNext,
	g_iBatchTotal,
	g_iBatchBatchSize,
	g_iBatchSuccess,
	g_iBatchGuardBlocked,
	g_iBatchGuardVis,
	g_iBatchGuardInvis,
	g_iBatchSegA,				// 中段参照子集起点（前段结束处）
	g_iBatchSegB,				// 后段参照子集起点（最后自然段起点）
	// v2.0.0 收尾期清剿阈值: 场上存活 ≤ 该值进入冷静期（= max(2, 本波刷新量×40%)）
	g_iClearThreshold,
	// v2.5.0 剿灭得分: 波次开始时生还队人数快照（含 bot）+ 波内倒地/死亡去重人数
	g_iWaveBase,
	g_iWaveDownDeaths;

bool
	g_bLateLoad,
	g_bInSpawnTime,
	g_bScaleWeights,
	g_bLeftSafeArea,
	g_bFinaleStarted,
	// v1.7.0 分批状态
	g_bBatchSegs,				// 本波是否启用三段定向
	g_bBatchRetry,				// 本波是否 retry 波（整波零成功时 1s 后重试）
	g_bBatchFind,				// 本波是否 rusher（跑图）
	// v2.2.0 清缴挂起标志（外部插件控制，Tank 波等场景强制等待条件满足）
	g_bClearingHeld,
	// v2.4.0 刷新暂停标志（外部插件控制，火力支援 AGM 等场景临时暂停刷新）
	g_bSpawningPaused,
	// v2.5.0 剿灭得分: 波内统计
	g_bWaveActive,					// 本波进行中（PRESSURE/CLEARING，波外倒地不计入）
	g_bWaveStarted,					// 本波真的刷出特感（零波不发分）
	g_bWaveHadTank,					// 本波是 Tank 波（tank_wave_mutator 调 SS_MarkWaveTank 置位）
	g_bWaveDowned[MAXPLAYERS + 1];	// 波内倒地/死亡去重标记

// v2.0.0 波间三态: 当前相位（初始 = IDLE）
WavePhase
	g_Phase;

// v2.4.0 刷新暂停计时器句柄
Handle g_hPauseTimer;
// v2.4.3 暂停期间主动清理 timer（每秒杀掉新刷的特感，因 director_no_specials 是 cheat 无法用）
Handle g_hPauseCleanupTimer;

// v1.7.0 参照者/flow 数组（全局持有——分批跨 timer 续刷需要存活）
int
	g_iBatchSurvivors[MAXPLAYERS + 1],
	g_iBatchSurvivorCount;
float
	g_fBatchFlows[MAXPLAYERS + 1];

public Plugin myinfo = {
	name = "Special Spawner",
	author = "Tordecybombo, breezy",
	description = "Provides customisable special infected spawing beyond vanilla coop limits",
	version = "2.5.2",
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

// v2.4.0 native: SS_PauseSpawning(float seconds)
// 暂停特感刷新 N 秒（外部插件调用，如火力支援 AGM 爆炸清场）
// seconds: 暂停秒数（调用时重置计时器，最后一次调用生效）
// 用途: 火力支援 AGM 导弹爆炸后暂停刷新 20 秒，给玩家喘息时间
// v2.4.3: director_no_specials 是 cheat 无法用，改用主动清理（每秒杀新刷特感）
int Native_PauseSpawning(Handle plugin, int numParams) {
	float seconds = GetNativeCell(1);
	if (seconds <= 0.0) {
		g_bSpawningPaused = false;
		delete g_hPauseTimer;
		delete g_hPauseCleanupTimer;
		LogMessage("[SS] Spawning pause CLEARED (external)");
		return 0;
	}

	g_bSpawningPaused = true;
	delete g_hPauseTimer;
	delete g_hPauseCleanupTimer;
	g_hPauseTimer = CreateTimer(seconds, Timer_UnpauseSpawning, _, TIMER_FLAG_NO_MAPCHANGE);
	g_hPauseCleanupTimer = CreateTimer(1.0, Timer_PauseCleanup, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	LogMessage("[SS] Spawning PAUSED for %.1f seconds (external, active cleanup)", seconds);
	return 0;
}

// v2.4.0 计时器回调：暂停时间到，恢复刷新
// v2.4.3: 停止主动清理 timer
Action Timer_UnpauseSpawning(Handle timer) {
	g_hPauseTimer = null;
	g_bSpawningPaused = false;
	delete g_hPauseCleanupTimer;
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
	// v1.3.8: 防贴脸守卫——落点离【所有】存活生还者（含倒地）的最小距离。
	// 引擎 L4D_GetRandomPZSpawnPosition 只保证离"领跑者"≥ss_spawnrange_min，
	// 队友完全没查 → 4人抱团时贴脸刷。本守卫对所有生还者生效，重掷+跳过兜底。
	g_cSpawnRangeGuard =			CreateConVar("ss_spawnrange_guard",		"400.0",					"落点离所有生还者的最小距离(防贴脸, 0=关闭)", _, true, 0.0, true, 1500.0);
	// v1.3.9: 保底阈值——重掷耗尽仍无 ≥guard 的点时，若存在离所有人 ≥ 本值的点则放行
	// 最佳者（防整波饿死），必须 ≤ guard 才有意义，0=不保底（保持 v1.3.8 绝不放行）。
	g_cSpawnRangeGuardMin =			CreateConVar("ss_spawnrange_guard_min",	"250.0",					"全跳保底:重掷耗尽后放行最近点≥该值的落点(须≤guard, 0=不保底)", _, true, 0.0, true, 1500.0);

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
	g_cBatchWindow =				CreateConVar("ss_batch_window",			"35.0",						"波内批次总释放窗口(秒), 批间隔=窗口/批数 钳制[5,10]", _, true, 5.0, true, 60.0);
	// v2.0.0 波间三态（压力/收尾/冷静）: 收尾期场上存活 ≤ 波次×40% 或
	// ss_rest_force 硬上限 → 冷静期零特感压力（缓冲节点）→ 下一波
	g_cRestMin =					CreateConVar("ss_rest_min",				"25.0",						"冷静期最小时长(秒, 零特感缓冲窗口)", _, true, 1.0, true, 60.0);
	g_cRestMax =					CreateConVar("ss_rest_max",				"35.0",						"冷静期最大时长(秒)", _, true, 1.0, true, 60.0);
	g_cRestForce =					CreateConVar("ss_rest_force",			"120.0",					"收尾期强制冷静硬上限(秒, 自波次开始计, 防留特/僵局)", _, true, 10.0, true, 600.0);
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
	TweakSettings(true);
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

Action tmrForceSuicide(Handle timer) {
	static int i;
	static int class;
	static int victim;
	static float time;

	time = GetEngineTime();
	for (i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || !IsFakeClient(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i))
			continue;

		class = GetEntProp(i, Prop_Send, "m_zombieClass");
		if (class < 1 || class > SI_MAX_SIZE)
			continue;

		if (GetEntProp(i, Prop_Send, "m_hasVisibleThreats")) {
			g_fActionTimes[i] = time;
			continue;
		}

		victim = GetSurVictim(i, class);
		if (victim > 0) {
			if (GetEntProp(victim, Prop_Send, "m_isIncapacitated"))
				KillInactiveSI(i);
			else
				g_fActionTimes[i] = time;
		}
		else {
			// 压力系统已废弃（2026-08-16）: 自杀时间固定用 cfg 默认值
			if (time - g_fActionTimes[i] > g_fSuicideTime)
				KillInactiveSI(i);
		}
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
	ForcePlayerSuicide(client);

	// v2.0.0 波间三态: 处决补波仅压力期/收尾期（冷静期/闲置期不补——冷静期契约零特感）
	if (!g_hRetryTimer && g_Phase != PHASE_REST && g_Phase != PHASE_IDLE)
		CreateTimer(1.0, tmrRetrySpawn, true);
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
	g_iBatchTotal = spawnSize;
	g_iBatchNext = 0;
	g_iBatchSegA = segA;
	g_iBatchSegB = segB;
	g_bBatchSegs = useSegs;
	g_bBatchRetry = retry;
	g_bBatchFind = find;

	g_hBatchQueue = aQueue;
	SpawnSliced(0, (g_iBatchBatchSize < spawnSize) ? g_iBatchBatchSize : spawnSize);

	#if BENCHMARK
	g_profiler.Stop();
	PrintToServer("[SS] ProfilerTime: %f", g_profiler.Time);
	#endif

	if (g_iBatchNext >= g_iBatchTotal)
		FinishWave();
	else
		g_hBatchTimer = CreateTimer(g_fBatchInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);

	return true;
}

// v1.7.0: 刷取队列 [from, to) 区间。每只特感按段类型决定方向与参照者子集，
// 守卫逻辑与 v1.4.0 相同（落点须离所有生还者 ≥guard，分层兜底防饿死）。
void SpawnSliced(int from, int to) {
	float guard = g_cSpawnRangeGuard.FloatValue;
	float guardMin = g_cSpawnRangeGuardMin.FloatValue;

	for (int i = from; i < to; i++) {
		int index = g_hBatchQueue.Get(i) + 1;

		// 段类型 → 方向 + 参照者子集 [refMin, refMax]（闭区间）
		int dir;
		int refMin;
		int refMax;
		if (g_bFinaleStarted) {
			dir = SPAWN_NEAR_IT_VICTIM;
			refMin = 0;
			refMax = g_iBatchSurvivorCount - 1;
		} else if (!g_bBatchSegs) {
			// 紧凑队伍/未分段：v1.6.0 原逻辑
			dir = g_bBatchRetry ? (g_bBatchFind ? SPAWN_IN_FRONT_OF_SURVIVORS : (g_bRandomDirection ? SPAWN_NO_PREFERENCE : SPAWN_LARGE_VOLUME)) : SPAWN_NO_PREFERENCE;
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
		g_iDirection = dir;

		// v1.4.0 贴脸守卫 v3：候选点必须 LOS 可见至少一个生还者（看得见 → 有威胁
		// → 不处决，特感立刻投入进攻）。分层：≥guard(400) 且可见 > 10 次耗尽取
		// ≥guard_min(250) 且可见的最佳 > 再兜底 250 不可见（窄室内 AI 可自行转向
		// 找人，防饿死）> 跳过。
		bool find = false;
		bool hasBestPos = false;
		float bestDist = 0.0;
		float bestPos[3];
		bool hasBestVisible = false;
		float bestVisibleDist = 0.0;
		float bestVisiblePos[3];
		float vPos[3];
		for (int tries = 0; tries < SPAWN_GUARD_MAX_TRIES; tries++) {
			int ref = g_iBatchSurvivors[GetRandomInt(refMin, refMax)];
			if (!L4D_GetRandomPZSpawnPosition(ref, index, 10, vPos))
				continue;
			float d = DistanceToNearestSurvivor(vPos);
			bool visible = IsPosVisibleToAnySurvivor(vPos);
			if (!hasBestPos || d > bestDist) {
				hasBestPos = true;
				bestDist = d;
				bestPos = vPos;
			}
			if (visible && (!hasBestVisible || d > bestVisibleDist)) {
				hasBestVisible = true;
				bestVisibleDist = d;
				bestVisiblePos = vPos;
			}
			if (!visible)
				continue;
			if (guard <= 0.0 || d >= guard) {
				find = true;
				break;
			}
		}

		if (!find) {
			// 保底 1：可见 + ≥guard_min 的最佳点（防处决 + 防饿死）
			if (hasBestVisible && guard > 0.0 && guardMin > 0.0 && bestVisibleDist >= guardMin) {
				vPos = bestVisiblePos;
				find = true;
				g_iBatchGuardVis++;
			}
			// 保底 2：不可见但 ≥guard_min（极窄地形，AI 会自行转向找人）
			// ⚠️ 残余处决源：不可见点 → m_hasVisibleThreats false → 25s 自杀计时。
			// 无法完全消除（全跳 = 饿死），靠日志统计比例决定是否收紧。
			else if (hasBestPos && guard > 0.0 && guardMin > 0.0 && bestDist >= guardMin) {
				vPos = bestPos;
				find = true;
				g_iBatchGuardInvis++;
			}
			else {
				g_iBatchGuardBlocked++;
				continue;
			}
		}

		vPos[2] += 5.0;
		int zombie;
		if ((zombie = L4D2_SpawnSpecial(index, vPos, NULL_VECTOR)) > 0) {
			SetEntProp(zombie, Prop_Send, "m_bDucked", 1);
			SetEntityFlags(zombie, GetEntityFlags(zombie)|FL_DUCKING);
			g_iBatchSuccess++;
		}
		vPos[2] -= 5.0;
	}
	g_iBatchNext = to;
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
	SpawnSliced(g_iBatchNext, end);

	if (g_iBatchNext >= g_iBatchTotal)
		FinishWave();
	else
		g_hBatchTimer = CreateTimer(g_fBatchInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Continue;
}

// v1.7.0: 整波收尾——guard 统计日志（跨批累计）、刷怪窗口关闭、retry 判定、
// 队列释放。
void FinishWave() {
	// v1.3.9/v1.4.1: 守卫统计（跳过 / 保底放行，波内有任何拦截才记一条，防日志刷屏）
	if (g_iBatchGuardBlocked || g_iBatchGuardVis || g_iBatchGuardInvis) {
		LogMessage("[SS] spawn guard: %d/%d skipped, %d vis-fb(>=%.0f), %d invis-fb, prefer >=%.0f, dir=%d",
			g_iBatchGuardBlocked, g_iBatchTotal, g_iBatchGuardVis, g_cSpawnRangeGuardMin.FloatValue,
			g_iBatchGuardInvis, g_cSpawnRangeGuard.FloatValue, g_iDirection);
	}

	g_bInSpawnTime = false;

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
	// 1) 先通知（tank_wave_mutator 判定下一波 + 可能调整 ss_rest cvar ×1.5）。
	//    参数传 0.0 占位：当前消费者（tank_mutator/si_comp）不使用该值，
	//    播报在 rest 抽取后重新计算，保证数字精确。
	Call_StartForward(g_fwdOnWaveRest);
	Call_PushFloat(0.0);
	Call_Finish();

	// 2) 抽取冷静期（读调整后的 cvar：非 Tank 25-35s / Tank 波 ×1.5）
	float rest = Math_GetRandomFloat(g_cRestMin.FloatValue, g_cRestMax.FloatValue);
	if (rest < 1.0)
		rest = 1.0;
	g_Phase = PHASE_REST;
	if (g_hRestTimer != null && IsValidHandle(g_hRestTimer))
		delete g_hRestTimer;
	g_hRestTimer = CreateTimer(rest, tmrRestEnd);
	LogMessage("[SS] phase: CLEARING -> REST (%.1fs)", rest);

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
	}

	if (score > 0) {
		// 入账: 全体生还者（含 bot; si_hud 未加载时静默跳过——optional native 守卫）
		if (GetFeatureStatus(FeatureType_Native, "SH_AddWallet") == FeatureStatus_Available) {
			for (int i = 1; i <= MaxClients; i++) {
				if (IsClientInGame(i) && GetClientTeam(i) == 2)
					SH_AddWallet(i, score);
			}
		}
		LogMessage("[SS] Clear score: tier=%s score=%d downDeaths=%d/%d base=%d tank=%s next=%ds (timeMult=%.2f)",
			tier, score, g_iWaveDownDeaths, g_iWaveBase, g_bWaveHadTank ? 1 : 0, total, timeMult);
		PrintToChatAll("\x04[特感]\x01 本波次剿灭完成，\x03%s%s\x01全体 \x05+%d\x01 分，下一波来袭 \x05%d\x01 秒",
			tankTag, tier, score, total);
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
	if (g_hBatchQueue) {
		delete g_hBatchQueue;
		g_hBatchQueue = null;
	}
}

// v1.3.9: 落点离最近存活生还者的距离（含倒地，IsPlayerAlive 对倒地返回 true）。
// 3D 距离——垂直贴脸（头顶实体/高台正上方）同样拦截。
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

	// v2.0.0 波间三态: 仅压力期/收尾期补波（冷静期/闲置期不补——冷静期后由
	// rest 结束的 timer 负责下一波）
	if (g_Phase != PHASE_PRESSURE && g_Phase != PHASE_CLEARING)
		return Plugin_Continue;

	// v2.0.0 retry 波属压力期: 重置 120s 硬上限锚点; 从收尾期转移须撤轮询 timer
	if (g_Phase == PHASE_CLEARING) {
		KillClearTimer();		// v2.0.1: 防御 delete（悬空句柄裸 delete 抛错）
	}
	g_fPhaseEnterTime = GetEngineTime();
	g_Phase = PHASE_PRESSURE;
	if (!ExecuteSpawnQueue(GetTotalSI(), retry))
		EnterClearing();
	return Plugin_Continue;
}

int GetTotalSI() {
	int count;
	for (int i = 1; i <= MaxClients; i++) {
		if (!IsClientInGame(i) || IsClientInKickQueue(i) || GetClientTeam(i) != 3)
			continue;
	
		if (IsPlayerAlive(i)) {
			if (1 <= GetEntProp(i, Prop_Send, "m_zombieClass") <= 6)
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
