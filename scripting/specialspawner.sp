#pragma tabsize 1
#pragma semicolon 1
#pragma newdecls required
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

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

Handle
	g_hSpawnTimer,
	g_hRetryTimer,
	g_hUpdateTimer,
	g_hSuicideTimer,
	g_hBatchTimer;				// v1.7.0 分批释放续刷 timer

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
	g_cWaveSplit,
	g_cWaveSplitInterval;

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
	g_fWaveSplitInterval,
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
	g_iWaveSplit,
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
	g_iBatchSegB;				// 后段参照子集起点（最后自然段起点）

bool
	g_bLateLoad,
	g_bInSpawnTime,
	g_bScaleWeights,
	g_bLeftSafeArea,
	g_bFinaleStarted,
	// v1.7.0 分批状态
	g_bBatchSegs,				// 本波是否启用三段定向
	g_bBatchRetry,				// 本波是否 retry 波（整波零成功时 1s 后重试）
	g_bBatchFind;				// 本波是否 rusher（跑图）

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
	version = "1.7.0",
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max) {
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart() {
	g_cSILimit	= 					CreateConVar("ss_si_limit",				"12",						"同时存在的最大特感数量", _, true, 1.0, true, 32.0);
	g_cSpawnSize = 					CreateConVar("ss_spawn_size",			"4",						"一次产生多少只特感", _, true, 1.0, true, 32.0);
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
	// v1.7.0 波次分批释放：总数量不变，分 N 批间隔刷出，缓解窄地形一波全堆正面的瞬间压力
	g_cWaveSplit =					CreateConVar("ss_wave_split",			"2",						"波次分批释放批数 [1=不分批]", _, true, 1.0, true, 4.0);
	g_cWaveSplitInterval =			CreateConVar("ss_wave_split_interval",	"2.5",						"波次分批释放间隔(秒)", _, true, 0.5, true, 10.0);

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

	RegAdminCmd("sm_weight",		cmdSetWeight,	ADMFLAG_RCON, "设置特感生成比重");
	RegAdminCmd("sm_limit",			cmdSetLimit,	ADMFLAG_RCON, "设置特感生成数量");
	RegAdminCmd("sm_timer",			cmdSetTimer,	ADMFLAG_RCON, "设置特感生成时间");

	RegAdminCmd("sm_resetspawn",	cmdResetSpawn,	ADMFLAG_RCON, "处死所有特感并重新开始生成计时");
	RegAdminCmd("sm_forcetimer",	cmdForceTimer,	ADMFLAG_RCON, "开始生成计时");
	RegAdminCmd("sm_type",			cmdType,		ADMFLAG_ROOT, "随机轮换模式");

	HookEntityOutput("trigger_finale", "FinaleStart", OnFinaleStart);

	if (g_bLateLoad && L4D_HasAnySurvivorLeftSafeArea())
		L4D_OnFirstSurvivorLeftSafeArea_Post(0);
}

public void OnPluginEnd() {
	TweakSettings(true);
	// v1.7.0: 清理跨批状态（TIMER_FLAG_NO_MAPCHANGE 会随换图取消，此处兜底）
	delete g_hBatchTimer;
	if (g_hBatchQueue) {
		delete g_hBatchQueue;
		g_hBatchQueue = null;
	}
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
		else if (time - g_fActionTimes[i] > g_fSuicideTime)
			KillInactiveSI(i);
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

	if (!g_hRetryTimer)
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
	for (int i = 1; i <= MaxClients; i++) {
		if (IsClientInGame(i) && IsFakeClient(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i) && GetEntProp(i, Prop_Send, "m_zombieClass") != 8)
			ForcePlayerSuicide(i);
	}

	StartCustomSpawnTimer(g_fSpawnTimes[0]);
	ReplyToCommand(client, "[SS] Slayed all special infected. Spawn timer restarted. Next potential spawn in %.1f seconds.", g_fSpawnTimeMin);
	return Plugin_Handled;
}

Action cmdForceTimer(int client, int args) {
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
	g_iWaveSplit = g_cWaveSplit.IntValue;
	g_fWaveSplitInterval = g_cWaveSplitInterval.FloatValue;
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
		if (!g_hSpawnTimer)
			StartCustomSpawnTimer(g_fFirstSpawnTime);
		if (!g_hSuicideTimer)
			g_hSuicideTimer = CreateTimer(2.5, tmrForceSuicide, _, TIMER_REPEAT);
	}
}

public void OnMapEnd() {
	g_bLeftSafeArea = false;
	g_bFinaleStarted = false;

	EndSpawnTimer();
	delete g_hSuicideTimer;
	// v1.7.0: 清理跨批状态（TIMER_FLAG_NO_MAPCHANGE 会随换图取消，此处兜底）
	delete g_hBatchTimer;
	if (g_hBatchQueue) {
		delete g_hBatchQueue;
		g_hBatchQueue = null;
	}
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
	if (!client || !IsClientInGame(client) || GetClientTeam(client) != 3)
		return;

	static int class;
	class = GetEntProp(client, Prop_Send, "m_zombieClass");
	if (class == 8 && !FindTank(client))
		TankStatusActoin(false);

	if (class != 4 && IsFakeClient(client))
		RequestFrame(NextFrame_KickBot, event.GetInt("userid"));
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

	int totalSI = GetTotalSI();
	ExecuteSpawnQueue(totalSI, true);

	g_hSpawnTimer = CreateTimer(g_iSpawnTimeMode > 0 ? g_fSpawnTimes[totalSI] : Math_GetRandomFloat(g_fSpawnTimeMin, g_fSpawnTimeMax), tmrSpawnSpecial);
	return Plugin_Continue;
}

void ExecuteSpawnQueue(int totalSI, bool retry) {
	if (totalSI >= g_iSILimit)
		return;

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
	if (g_fIncapCompensation > 0.0) {
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
			float scale = 1.0 - g_fIncapCompensation * (1.0 - ratio);

			int effLimit = RoundToNearest(float(g_iSILimit) * scale);
			if (effLimit < 1)
				effLimit = 1;

			if (totalSI >= effLimit) {
				LogMessage("[SS] incap comp: %d/%d 倒地, 上限 %d→%d, 存活 %d → 本波跳过",
					total - standing, total, g_iSILimit, effLimit, totalSI);
				return;
			}

			int oldSize = spawnSize;
			allowedSI = effLimit - totalSI;
			spawnSize = RoundToNearest(float(spawnSize) * scale);
			if (spawnSize < 1)
				spawnSize = 1;
			if (spawnSize > allowedSI)
				spawnSize = allowedSI;

			if (spawnSize != oldSize)
				LogMessage("[SS] incap comp: %d/%d 倒地, 波次 %d→%d, 上限 %d→%d",
					total - standing, total, oldSize, spawnSize, g_iSILimit, effLimit);
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
		return;
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
		return;
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

		// 按权重精确分配各段特感数 + Fisher-Yates 洗牌（比例精确、波内顺序随机）
		float totalW = g_fDirFront + g_fDirMid + g_fDirBack;
		if (totalW <= 0.0)
			totalW = 100.0;
		int frontN = RoundToNearest(float(spawnSize) * g_fDirFront / totalW);
		if (frontN > spawnSize)
			frontN = spawnSize;
		if (frontN < 0)
			frontN = 0;
		int backN = RoundToNearest(float(spawnSize) * g_fDirBack / totalW);
		if (backN > spawnSize - frontN)
			backN = spawnSize - frontN;
		if (backN < 0)
			backN = 0;
		int midN = spawnSize - frontN - backN;
		for (i = 0; i < spawnSize; i++)
			g_iSegs[i] = (i < frontN) ? 0 : (i < frontN + midN) ? 1 : 2;
		for (i = spawnSize - 1; i > 0; i--) {
			int j = GetRandomInt(0, i);
			int tmp = g_iSegs[i];
			g_iSegs[i] = g_iSegs[j];
			g_iSegs[j] = tmp;
		}
	}

	// v1.7.0 波次分批释放：总数量不变，分 N 批间隔刷出（缓解窄地形一波全堆
	// 正面）。批次状态全局持有，续刷走 tmrBatchContinue，收尾统一 FinishWave
	// （guard 统计跨批累计 + retry 判定 + 队列释放）。
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
	int batches = g_iWaveSplit;
	if (batches > spawnSize)
		batches = spawnSize;
	if (batches < 1)
		batches = 1;
	g_iBatchBatchSize = spawnSize / batches + ((spawnSize % batches) ? 1 : 0);

	g_hBatchQueue = aQueue;
	SpawnSliced(0, (g_iBatchBatchSize < spawnSize) ? g_iBatchBatchSize : spawnSize);

	#if BENCHMARK
	g_profiler.Stop();
	PrintToServer("[SS] ProfilerTime: %f", g_profiler.Time);
	#endif

	if (g_iBatchNext >= g_iBatchTotal)
		FinishWave();
	else
		g_hBatchTimer = CreateTimer(g_fWaveSplitInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
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
Action tmrBatchContinue(Handle timer) {
	g_hBatchTimer = null;

	int end = g_iBatchNext + g_iBatchBatchSize;
	if (end > g_iBatchTotal)
		end = g_iBatchTotal;
	SpawnSliced(g_iBatchNext, end);

	if (g_iBatchNext >= g_iBatchTotal)
		FinishWave();
	else
		g_hBatchTimer = CreateTimer(g_fWaveSplitInterval, tmrBatchContinue, _, TIMER_FLAG_NO_MAPCHANGE);
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
	ExecuteSpawnQueue(GetTotalSI(), retry);
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
