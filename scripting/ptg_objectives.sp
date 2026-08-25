// ============================================================
//  [L4D2] PTG Objectives — 解密链式导航引擎 v0.9
//
//  与 PTG(flow 梯度导航)互补: PTG 指"最终门", 本插件按剧本顺序
//  引导解密步骤(找道具A→开机关B→触发C→最终门)。
//
//  数据来源 = configs/ptg_objectives.cfg 每图一段有序步骤。
//  解密逻辑藏在实体 I/O 里(nav mesh 不可见)——所以必须有一层
//  剧本描述; root 命令 chain_scan 扫描全图交互嫌疑物作为编写底稿。
//
//  步骤完成检测(HookEntityOutput 按 classname 全局钩):
//    button    func_button        OnPressed
//    door      prop_door_rotating OnOpen
//    door_f    func_door          OnOpen
//    breakable func_breakable     OnBreak
//    pickup    prop_physics       OnPlayerPickup
//    trigger   trigger_once       OnStartTouch
//    counter   math_counter       OnHitMax
//    reach     无 hook, 幸存者进入目标半径轮询判定
//  配置可覆写 class/output/targetname; "count N"= 并列组需 N 次
//  (如散布 3 个油桶任收满 3 个)。
//
//  命令:
//    sm_obj                     玩家开关个人引导线(有 chain 的图)
//    chain_scan                 ROOT 扫描交互嫌疑物 → data/ptg_chain_<map>.txt
//    chain_reload               ROOT 重载配置
//    chain_step <n>             ROOT 跳步测试
// ============================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_entinput>
#include <left4dhooks>

#define PLUGIN_VERSION  "0.9 2026-08-25"
#define TEAM_SURVIVOR   2
#define CFG_PATH        "configs/ptg_objectives.cfg"
#define MAX_STEPS       32
#define MAX_TARGETS     64
#define REDRAW_INTERVAL 0.5
#define BFS_MAX_EXPAND  20000

public Plugin myinfo =
{
	name        = "[L4D2] PTG Objectives (puzzle chain guide)",
	author      = "server",
	description = "Sequence-aware objective navigation for puzzle maps",
	version     = PLUGIN_VERSION,
	url         = ""
}

// ────────────────────────── 步骤数据模型 ──────────────────────────

enum struct Step {
	char eClass[48];      // 实体类名(hook + 匹配)
	char eOutput[40];     // 完成输出名
	char eName[48];       // targetname 过滤(空=不过滤)
	char eHint[96];       // HUD 提示文案
	int  needCount;       // 并列组需完成次数(默认 1)
	int  doneCount;       // 已完成计数
	int  targetPosIdx;    // 主目标在 g_fTargetPos 的下标(-1=reach 无实体)
	float reachRadius;    // reach 型判定半径
	bool  resolved;       // 本回合已解析实体
	float cfgPos[3];      // 配置直填坐标("pos", reach 型/兜底)
	bool  hasCfgPos;
}

char  g_sMap[PLATFORM_MAX_PATH];
bool  g_bChainLoaded;
int   g_iStepCount;
Step  g_Steps[MAX_STEPS];
int   g_iCurStep;

// 目标世界坐标(解析时缓存)
ArrayList g_fTargetX, g_fTargetY, g_fTargetZ;

// ────────────────────────── 导航表(移植 PTG 模式) ──────────────────────────
ArrayList g_hAreaList;
StringMap g_hAreaIndex;
ArrayList g_hNeighborIdx;   // index → ArrayList(4 向邻居 index)
ArrayList g_hCenterX, g_hCenterY, g_hCenterZ;
bool   g_bNavReady;

// ────────────────────────── 渲染状态 ──────────────────────────
int    g_iLaserSprite;
bool   g_bGuideOn[MAXPLAYERS + 1];
Handle g_hDrawTimer[MAXPLAYERS + 1];
ConVar g_hCvarAutoOn;
ConVar g_hCvarColorR, g_hCvarColorG, g_hCvarColorB;

public void OnPluginStart()
{
	RegConsoleCmd("sm_obj", CmdToggleGuide, "开关个人解密引导线");
	RegAdminCmd("chain_scan", CmdChainScan, ADMFLAG_ROOT, "扫描全图交互嫌疑物");
	RegAdminCmd("chain_reload", CmdChainReload, ADMFLAG_ROOT, "重载 objectives 配置");
	RegAdminCmd("chain_step", CmdChainStep, ADMFLAG_ROOT, "跳步: chain_step <n>");
	RegAdminCmd("obj_skip", CmdObjSkip, ADMFLAG_ROOT, "暴力跳过(输入模拟): obj_skip=无限跳到完成; obj_skip <n>=限n步");
	RegAdminCmd("obj_aim", CmdObjAim, ADMFLAG_ROOT, "查看准星指向的实体信息(配置剧本用)");

	g_hCvarAutoOn  = CreateConVar("ptg_obj_auto_on", "1", "有 chain 配置的图中玩家默认自动开启引导线");
	g_hCvarColorR  = CreateConVar("ptg_obj_color_r", "0", "引导线 R");
	g_hCvarColorG  = CreateConVar("ptg_obj_color_g", "210", "引导线 G");
	g_hCvarColorB  = CreateConVar("ptg_obj_color_b", "255", "引导线 B");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
}

public void OnMapStart()
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	g_iLaserSprite = PrecacheModel("sprites/white.vmt", true);
	if (g_iLaserSprite == 0)
		g_iLaserSprite = PrecacheModel("sprites/laserbeam.vmt", true);

	FreeRoundState();
	g_bChainLoaded = false;
	g_bNavReady = false;

	CreateTimer(3.0, Timer_PostStart_Init, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_PostStart_Init(Handle timer)
{
	LoadChainConfig();
	if (g_bChainLoaded)
	{
		BuildNavTables();
		ResolveCurrentStep();
		ApplyAutoOn();
	}
	return Plugin_Stop;
}

public void Event_RoundStart(Event e, const char[] n, bool d)
{
	// 回合重开: 步骤进度归零, 实体引用失效待重解析。
	// v0.9.1: 同时立即挂起绘制(g_bChainLoaded=false)——数组已清空而
	// 重初始化在 3s 定时器后, 窗口期 DrawForClient 访问空 ArrayList
	// 会抛 Invalid index 异常导致玩家完全看不到线。
	g_bChainLoaded = false;
	for (int i = 0; i < g_iStepCount; i++)
	{
		g_Steps[i].doneCount = 0;
		g_Steps[i].resolved = false;
	}
	g_iCurStep = 0;
	CreateTimer(3.0, Timer_PostStart_Init, _, TIMER_FLAG_NO_MAPCHANGE);
}

void FreeRoundState()
{
	g_iStepCount = 0;
	g_iCurStep = 0;
	delete g_fTargetX; delete g_fTargetY; delete g_fTargetZ;
	delete g_hAreaList; delete g_hAreaIndex; delete g_hNeighborIdx;
	delete g_hCenterX; delete g_hCenterY; delete g_hCenterZ;
}

// ────────────────────────── 配置加载 ──────────────────────────

void LoadChainConfig()
{
	// v0.9.1 幂等保护: 回合重启路径(Event_RoundStart→Timer_PostStart_Init)
	// 不经 FreeRoundState, 二次加载会把步骤追加到旧数据上(实测 20+12=32)
	g_iStepCount = 0;
	g_iCurStep = 0;
	delete g_fTargetX; delete g_fTargetY; delete g_fTargetZ;

	g_bChainLoaded = false;
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), CFG_PATH);
	if (!FileExists(path))
		return;

	KeyValues kv = new KeyValues("objectives");
	if (!kv.ImportFromFile(path))
	{
		LogMessage("[PTGOBJ] config import fail: %s", path);
		delete kv;
		return;
	}

	g_fTargetX = new ArrayList();
	g_fTargetY = new ArrayList();
	g_fTargetZ = new ArrayList();

	if (!kv.JumpToKey(g_sMap))   // 精确地图名匹配
	{
		delete kv;
		return;
	}
	if (!kv.GotoFirstSubKey(false))
	{
		delete kv;
		return;
	}

	char sec[12];
	do
	{
		if (g_iStepCount >= MAX_STEPS) break;
		kv.GetSectionName(sec, sizeof(sec));
		Step s;
		s.doneCount = 0;
		s.resolved = false;
		s.targetPosIdx = -1;
		s.reachRadius = 120.0;
		s.needCount = kv.GetNum("count", 1);

		char type[16];
		kv.GetString("type", type, sizeof(type), "button");
		TypeDefaults(type, s.eClass, sizeof(s.eClass), s.eOutput, sizeof(s.eOutput));
		kv.GetString("class", s.eClass, sizeof(s.eClass), s.eClass);      // 覆写
		kv.GetString("output", s.eOutput, sizeof(s.eOutput), s.eOutput);  // 覆写
		kv.GetString("name", s.eName, sizeof(s.eName), "");
		kv.GetString("hint", s.eHint, sizeof(s.eHint), "");

		if (StrEqual(type, "reach"))
		{
			s.eClass[0] = 0;
			s.reachRadius = kv.GetFloat("radius", 120.0);
		}

		char posbuf[64];
		kv.GetString("pos", posbuf, sizeof(posbuf), "");
		if (posbuf[0] != 0)
		{
			char parts[3][16];
			if (ExplodeString(posbuf, " ", parts, 3, 16) == 3)
			{
				s.cfgPos[0] = StringToFloat(parts[0]);
				s.cfgPos[1] = StringToFloat(parts[1]);
				s.cfgPos[2] = StringToFloat(parts[2]);
				s.hasCfgPos = true;
			}
		}

		g_Steps[g_iStepCount++] = s;
	}
	while (kv.GotoNextKey());

	delete kv;
	if (g_iStepCount > 0)
	{
		g_bChainLoaded = true;
		LogMessage("[PTGOBJ] chain loaded: map=%s steps=%d", g_sMap, g_iStepCount);
	}
}

void TypeDefaults(const char[] type, char[] cls, int clsLen, char[] out, int outLen)
{
	if (StrEqual(type, "button"))      { strcopy(cls, clsLen, "func_button");         strcopy(out, outLen, "OnPressed"); }
	else if (StrEqual(type, "door"))   { strcopy(cls, clsLen, "prop_door_rotating");  strcopy(out, outLen, "OnOpen"); }
	else if (StrEqual(type, "door_f")) { strcopy(cls, clsLen, "func_door");           strcopy(out, outLen, "OnOpen"); }
	else if (StrEqual(type, "breakable")) { strcopy(cls, clsLen, "func_breakable");   strcopy(out, outLen, "OnBreak"); }
	else if (StrEqual(type, "pickup")) { strcopy(cls, clsLen, "prop_physics");        strcopy(out, outLen, "OnPlayerPickup"); }
	else if (StrEqual(type, "trigger")){ strcopy(cls, clsLen, "trigger_once");        strcopy(out, outLen, "OnStartTouch"); }
	else if (StrEqual(type, "counter")){ strcopy(cls, clsLen, "math_counter");        strcopy(out, outLen, "OnHitMax"); }
	else                               { strcopy(cls, clsLen, "func_button");         strcopy(out, outLen, "OnPressed"); }
}

Action CmdChainReload(int client, int args)
{
	FreeRoundState();
	g_bChainLoaded = false;
	LoadChainConfig();
	if (g_bChainLoaded)
	{
		BuildNavTables();
		ResolveCurrentStep();
		ApplyAutoOn();
	}
	ReplyToCommand(client, "[PTGOBJ] reload: steps=%d cur=%d", g_iStepCount, g_iCurStep + 1);
	return Plugin_Handled;
}

Action CmdChainStep(int client, int args)
{
	if (args < 1) return Plugin_Handled;
	char b[8]; GetCmdArg(1, b, sizeof(b));
	int n = StringToInt(b);
	if (n < 1 || n > g_iStepCount) return Plugin_Handled;
	g_iCurStep = n - 1;
	for (int i = 0; i < n; i++) g_Steps[i].doneCount = g_Steps[i].needCount;
	g_Steps[n-1].doneCount = 0;
	ResolveCurrentStep();
	AnnounceStep(true);
	return Plugin_Handled;
}

// ────────────────────────── 步骤实体解析 ──────────────────────────

char g_sHookedClass[48], g_sHookedOutput[40];

void DetachStepHook()
{
	if (g_sHookedClass[0] != 0)
	{
		UnhookEntityOutput(g_sHookedClass, g_sHookedOutput, EO_OnStepOutput);
		g_sHookedClass[0] = 0;
	}
}

void AttachStepHook()
{
	DetachStepHook();
	Step s;
	s = g_Steps[g_iCurStep];
	if (!g_bChainLoaded || g_iCurStep >= g_iStepCount || s.eClass[0] == 0) return;
	HookEntityOutput(s.eClass, s.eOutput, EO_OnStepOutput);
	strcopy(g_sHookedClass, sizeof(g_sHookedClass), s.eClass);
	strcopy(g_sHookedOutput, sizeof(g_sHookedOutput), s.eOutput);
	LogMessage("[PTGOBJ] hook %s :: %s (step %d)", s.eClass, s.eOutput, g_iCurStep + 1);
}

void ResolveCurrentStep()
{
	if (!g_bChainLoaded || g_iCurStep >= g_iStepCount) return;
	Step s;
	s = g_Steps[g_iCurStep];
	if (s.resolved && s.targetPosIdx >= 0) return;

	// 清旧 hook 残留计数
	s.doneCount = 0;

	int posIdx = g_fTargetX.Length;   // 新增主目标位置槽
	float px = 0.0, py = 0.0, pz = 0.0;
	bool havePos = false;

	// 完成匹配走"类名+targetname 字符串对比"(EO 回调), 这里只解析位置。
	// 注意: math_counter/logic_relay 等非网络实体的 FindEntityByClassname
	// 返回伪索引, EntIndexToEntRef 会拒绝 → 不存实体引用。
	if (s.eClass[0] != 0)
	{
		char names[8][48];
		int nameCnt = ExplodeString(s.eName, ",", names, 8, 48);
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, s.eClass)) != -1)
		{
			if (s.eName[0] != 0)
			{
				char tn[48];
				GetEntPropString(ent, Prop_Data, "m_iName", tn, sizeof(tn));
				bool hit = false;
				for (int ni = 0; ni < nameCnt; ni++)
					if (StrEqual(tn, names[ni])) { hit = true; break; }
				if (!hit) continue;
			}
			if (ent <= 0 || ent > MaxClients + 4096) continue;   // 伪索引不能取位置
			float c[3];
			EntityCenter(ent, c);
			px = c[0]; py = c[1]; pz = c[2];
			havePos = true;
			break;   // 只要一个可用位置
		}
	}

	if (!havePos && s.hasCfgPos)
	{
		// 无实体匹配但配置直填了坐标(reach 型常用) → 用配置坐标
		s.targetPosIdx = posIdx;
		g_fTargetX.Push(s.cfgPos[0]); g_fTargetY.Push(s.cfgPos[1]); g_fTargetZ.Push(s.cfgPos[2]);
	}
	else if (!havePos)
	{
		// 完全无法定位 → 不画线只发文字提示
		s.targetPosIdx = -1;
		LogMessage("[PTGOBJ] step %d: no entity matched (%s %s)", g_iCurStep + 1, s.eClass, s.eName);
	}
	else
	{
		s.targetPosIdx = posIdx;
		g_fTargetX.Push(px); g_fTargetY.Push(py); g_fTargetZ.Push(pz);
	}
	s.resolved = true;
	g_Steps[g_iCurStep] = s;
	AttachStepHook();
}

void EntityCenter(int ent, float c[3])
{
	c[0] = 0.0; c[1] = 0.0; c[2] = 0.0;
	if (ent <= 0 || !IsValidEntity(ent)) return;
	if (HasEntProp(ent, Prop_Send, "m_vecOrigin"))
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", c);
	else if (HasEntProp(ent, Prop_Data, "m_vecOrigin"))
		GetEntPropVector(ent, Prop_Data, "m_vecOrigin", c);
	// brush 实体 origin 恒 0 → 用包围盒中心
	if (c[0] == 0.0 && c[1] == 0.0 && c[2] == 0.0
		&& HasEntProp(ent, Prop_Send, "m_vecMins"))
	{
		float mi[3], ma[3];
		GetEntPropVector(ent, Prop_Send, "m_vecMins", mi);
		GetEntPropVector(ent, Prop_Send, "m_vecMaxs", ma);
		for (int k = 0; k < 3; k++) c[k] = (mi[k] + ma[k]) * 0.5;
	}
}

// ────────────────────────── 完成检测 ──────────────────────────

public void EO_OnStepOutput(const char[] output, int caller, int activator, float delay)
{
	if (!g_bChainLoaded || g_iCurStep >= g_iStepCount) return;
	Step s;
	s = g_Steps[g_iCurStep];
	if (s.eClass[0] == 0) return;

	// 类名 + targetname 字符串匹配(不依赖实体引用, 兼容非网络实体)
	char cn[48];
	GetEntityClassname(caller, cn, sizeof(cn));
	if (!StrEqual(cn, s.eClass)) return;
	if (s.eName[0] != 0)
	{
		char tn[48];
		GetEntPropString(caller, Prop_Data, "m_iName", tn, sizeof(tn));
		char names[8][48];
		int nameCnt = ExplodeString(s.eName, ",", names, 8, 48);
		bool hit = false;
		for (int ni = 0; ni < nameCnt; ni++)
			if (StrEqual(tn, names[ni])) { hit = true; break; }
		if (!hit) return;
	}
	RegisterProgress();
}

void RegisterProgress()
{
	Step s;
	s = g_Steps[g_iCurStep];
	s.doneCount++;
	g_Steps[g_iCurStep] = s;
	LogMessage("[PTGOBJ] progress step=%d %d/%d", g_iCurStep + 1, s.doneCount, s.needCount);
	if (s.doneCount >= s.needCount)
		AdvanceStep();
	else
		PrintHintToAll("\x05[%d/%d]\x01 %s", s.doneCount, s.needCount, s.eHint);
}

void AdvanceStep()
{
	if (g_iCurStep + 1 >= g_iStepCount)
	{
		DetachStepHook();
		PrintHintToAll("\x04所有机关已激活 — 最终门已开启!");
		g_iCurStep = g_iStepCount;   // 完成态
		return;
	}
	g_iCurStep++;
	ResolveCurrentStep();
	AnnounceStep(false);
}

void AnnounceStep(bool jump)
{
	if (g_iCurStep >= g_iStepCount) return;
	Step s;
	s = g_Steps[g_iCurStep];
	PrintHintToAll("%s第%d步: %s", jump ? "\x04[跳步]\x01" : "\x04新目标\x01", g_iCurStep + 1, s.eHint);
}

// reach 型轮询(0.5s 复用绘制定时器内检查)
void CheckReachProgress()
{
	if (!g_bChainLoaded || g_iCurStep >= g_iStepCount) return;
	Step s;
	s = g_Steps[g_iCurStep];
	if (s.eClass[0] != 0 || s.targetPosIdx < 0 || !s.resolved) return;
	float tx = g_fTargetX.Get(s.targetPosIdx);
	float ty = g_fTargetY.Get(s.targetPosIdx);
	float tz = g_fTargetZ.Get(s.targetPosIdx);
	float r2 = s.reachRadius * s.reachRadius;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i)) continue;
		float o[3];
		GetClientAbsOrigin(i, o);
		float dx = o[0]-tx, dy = o[1]-ty, dz = o[2]-tz;
		if (dx*dx + dy*dy + dz*dz <= r2)
		{
			RegisterProgress();
			return;
		}
	}
}

// ────────────────────────── 导航表(BFS 早停版) ──────────────────────────

void BuildNavTables()
{
	g_bNavReady = false;
	ArrayList all = new ArrayList();
	L4D_GetAllNavAreas(all);
	int n = all.Length;
	if (n == 0) { delete all; return; }

	g_hAreaList = new ArrayList();
	g_hAreaIndex = new StringMap();
	g_hNeighborIdx = new ArrayList();
	g_hCenterX = new ArrayList(); g_hCenterY = new ArrayList(); g_hCenterZ = new ArrayList();

	char key[16];
	float c[3];
	for (int i = 0; i < n; i++)
	{
		int aInt = all.Get(i);
		g_hAreaList.Push(aInt);
		IntToString(aInt, key, sizeof(key));
		g_hAreaIndex.SetValue(key, i);
		L4D_GetNavAreaCenter(view_as<Address>(aInt), c);
		g_hCenterX.Push(c[0]); g_hCenterY.Push(c[1]); g_hCenterZ.Push(c[2]);
	}

	ArrayList adj = new ArrayList();
	for (int i = 0; i < n; i++)
	{
		ArrayList nb = new ArrayList();
		for (int dir = 0; dir < 4; dir++)
		{
			adj.Clear();
			L4D_NavArea_GetAdjacentAreas(view_as<Address>(g_hAreaList.Get(i)), dir, adj);
			for (int j = 0; j < adj.Length; j++)
			{
				IntToString(adj.Get(j), key, sizeof(key));
				int idx;
				if (g_hAreaIndex.GetValue(key, idx))
					nb.Push(idx);
			}
		}
		g_hNeighborIdx.Push(nb);
	}
	delete adj;
	delete all;
	g_bNavReady = true;
	LogMessage("[PTGOBJ] nav table: areas=%d", n);
}

int AreaToIndex(Address a)
{
	char key[16];
	IntToString(view_as<int>(a), key, sizeof(key));
	int idx = -1;
	g_hAreaIndex.GetValue(key, idx);
	return idx;
}

// BFS 起点→目标 index, 早停; 返回路径(areaInt 序列)或 null
ArrayList BfsPath(int startIdx, int goalIdx)
{
	if (startIdx < 0 || goalIdx < 0) return null;
	int n = g_hAreaList.Length;
	int[] visited = new int[n];
	int[] parent = new int[n];
	for (int i = 0; i < n; i++) { visited[i] = 0; parent[i] = -1; }
	visited[startIdx] = 1;

	ArrayList queue = new ArrayList();
	queue.Push(startIdx);
	int head = 0, found = -1;
	while (head < queue.Length)
	{
		int cur = queue.Get(head); head++;
		if (cur == goalIdx) { found = cur; break; }
		ArrayList nb = g_hNeighborIdx.Get(cur);
		for (int j = 0; j < nb.Length; j++)
		{
			int nx = nb.Get(j);
			if (visited[nx]) continue;
			if (FloatAbs(g_hCenterZ.Get(cur) - g_hCenterZ.Get(nx)) > 150.0) continue;
			visited[nx] = 1;
			parent[nx] = cur;
			queue.Push(nx);
		}
		if (queue.Length > BFS_MAX_EXPAND) break;
	}
	ArrayList path = null;
	if (found != -1)
	{
		path = new ArrayList();
		int node = found, guard = 0;
		while (node != -1 && guard <= n)
		{
			guard++;
			path.Push(g_hAreaList.Get(node));
			node = parent[node];
		}
		// 反转成 起点→目标
		int lo = 0, hi = path.Length - 1;
		while (lo < hi)
		{
			int t = path.Get(lo); path.Set(lo, path.Get(hi)); path.Set(hi, t);
			lo++; hi--;
		}
	}
	delete queue;
	return path;
}

Address NearestSurvivorArea(const float pos[3])
{
	Address a = L4D_GetNearestNavArea(pos, 800.0, false, false, false, TEAM_SURVIVOR);
	if (a == Address_Null) return Address_Null;
	float c[3];
	L4D_GetNavAreaCenter(a, c);
	if (FloatAbs(c[2] - pos[2]) > 150.0) return Address_Null;
	return a;
}

// ────────────────────────── 绘制 ──────────────────────────

Action CmdToggleGuide(int client, int args)
{
	if (client < 1 || !IsClientInGame(client)) return Plugin_Handled;
	if (!g_bChainLoaded)
	{
		PrintToChat(client, "[OBJ] \x01本图无解密剧本, 请用 \x05!ptg\x01 常规导航");
		return Plugin_Handled;
	}
	g_bGuideOn[client] = !g_bGuideOn[client];
	PrintToChat(client, g_bGuideOn[client] ? "[OBJ] \x05引导线 ON" : "[OBJ] \x04引导线 OFF");
	if (g_bGuideOn[client] && g_hDrawTimer[client] == null)
		g_hDrawTimer[client] = CreateTimer(REDRAW_INTERVAL, Timer_Draw, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

void ApplyAutoOn()
{
	if (!g_hCvarAutoOn.BoolValue) return;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			g_bGuideOn[i] = true;
			if (g_hDrawTimer[i] == null)
				g_hDrawTimer[i] = CreateTimer(REDRAW_INTERVAL, Timer_Draw, GetClientUserId(i), TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public void OnClientDisconnect(int client)
{
	g_bGuideOn[client] = false;
	g_hDrawTimer[client] = null;
}

Action Timer_Draw(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client <= 0 || !g_bGuideOn[client])
	{
		if (client > 0) g_hDrawTimer[client] = null;
		return Plugin_Stop;
	}
	g_hDrawTimer[client] = null;

	DrawForClient(client);

	// 完成态或掉线自然停止; 否则续排
	if (g_bGuideOn[client] && IsClientInGame(client))
		g_hDrawTimer[client] = CreateTimer(REDRAW_INTERVAL, Timer_Draw, userid, TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Stop;
}

void DrawForClient(int client)
{
	if (!g_bChainLoaded || g_bNavReady == false) return;
	if (g_iCurStep >= g_iStepCount)
	{
		// 完成态: 只画最终门方向? PTG 接管即可, 这里静默
		return;
	}
	CheckReachProgress();

	Step s;
	s = g_Steps[g_iCurStep];

	// 周期性提示(每 20s)
	static int lastHintTick[MAXPLAYERS + 1];
	if (GetGameTickCount() - lastHintTick[client] > 400)
	{
		lastHintTick[client] = GetGameTickCount();
		PrintHintText(client, "第%d步: %s", g_iCurStep + 1, s.eHint);
	}

	if (s.targetPosIdx < 0 || s.targetPosIdx >= g_fTargetX.Length) return;

	float org[3], tgt[3];
	GetClientAbsOrigin(client, org);
	tgt[0] = g_fTargetX.Get(s.targetPosIdx);
	tgt[1] = g_fTargetY.Get(s.targetPosIdx);
	tgt[2] = g_fTargetZ.Get(s.targetPosIdx);

	Address pa = NearestSurvivorArea(org);
	Address pb = NearestSurvivorArea(tgt);
	if (pa == Address_Null || pb == Address_Null)
	{
		// 吸附失败: 直线连过去(聊胜于无)
		float top[3]; top = tgt; top[2] += 160.0;
		BeamSeg(client, tgt, top);
		return;
	}
	int si = AreaToIndex(pa), gi = AreaToIndex(pb);
	if (si < 0 || gi < 0) return;

	ArrayList path = BfsPath(si, gi);
	if (path == null)
	{
		float top[3]; top = tgt; top[2] += 160.0;
		BeamSeg(client, tgt, top);
		return;
	}

	// 衔接段: 玩家 → 首个 area center
	int len = path.Length;
	int maxBeams = 24;
	int step = len > maxBeams ? (len + maxBeams - 1) / maxBeams : 1;
	float prev[3];
	prev = org; prev[2] += 10.0;
	float c[3];
	L4D_GetNavAreaCenter(view_as<Address>(path.Get(0)), c);
	c[2] += 10.0;
	if (FloatAbs(c[2] - prev[2]) <= 150.0) BeamSeg(client, prev, c);

	for (int i = 0; i < len - 1; i += (i < 6 ? 1 : step))
	{
		float a[3], b2[3];
		L4D_GetNavAreaCenter(view_as<Address>(path.Get(i)), a);
		L4D_GetNavAreaCenter(view_as<Address>(path.Get(i + 1)), b2);
		a[2] += 10.0; b2[2] += 10.0;
		if (LosClear(a, b2))
			BeamSeg(client, a, b2);
		else
			BeamSeg(client, a, b2);   // v0.9 不做中点修正, 保持轻量(青色段穿墙可接受)
	}
	// 终点脉冲 beacon
	float end[3], top2[3];
	end[0]=tgt[0]; end[1]=tgt[1]; end[2]=tgt[2] + 10.0 + 30.0 * FloatAbs(Sine(GetGameTime() * 3.0));
	top2 = tgt; top2[2] += 170.0;
	BeamSeg(client, end, top2);

	delete path;
}

bool LosClear(const float p1[3], const float p2[3])
{
	TR_TraceRayFilter(p1, p2, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
	return !TR_DidHit();
}

public bool TraceFilterWorldOnly(int entity, int contentsMask, any data)
{
	return false;
}

void BeamSeg(int client, const float p1[3], const float p2[3])
{
	int color[4];
	color[0] = g_hCvarColorR.IntValue;
	color[1] = g_hCvarColorG.IntValue;
	color[2] = g_hCvarColorB.IntValue;
	color[3] = 230;
	TE_SetupBeamPoints(p1, p2, g_iLaserSprite, 0, 0, 0, REDRAW_INTERVAL + 0.25, 1.0, 3.0, 0, 0.0, color, 0);
	if (IsClientInGame(client)) TE_SendToClient(client);
}

void PrintHintToAll(const char[] fmt, any ...)
{
	char buf[192];
	VFormat(buf, sizeof(buf), fmt, 2);
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i))
			PrintHintText(i, "%s", buf);
}

public void OnClientPutInServer(int client)
{
	// 中途加入自动开启(与 ApplyAutoOn 同策略)
	if (g_bChainLoaded && g_hCvarAutoOn.BoolValue && !IsFakeClient(client))
	{
		g_bGuideOn[client] = true;
		if (g_hDrawTimer[client] == null)
			g_hDrawTimer[client] = CreateTimer(REDRAW_INTERVAL, Timer_Draw, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
	}
}

// ────────────────────────── 暴力跳过(输入模拟) ──────────────────────────
// 原理: 不需要知道谜题答案——直接重放该类实体的"完成语义"输入
// (Press/Unlock+Open/Break/SetValue), 地图自身逻辑照常发生,
// 我们的 hook 收到 OnXxx 后走正规推进流程。

Action CmdObjSkip(int client, int args)
{
	if (!g_bChainLoaded || g_iCurStep >= g_iStepCount)
	{
		ReplyToCommand(client, "[PTGOBJ] 无进行中的步骤可跳过");
		return Plugin_Handled;
	}
	char b[8];
	int times = MAX_STEPS + 1;   // 默认无限: 跳到链完成或首个无响应为止
	if (args >= 1)
	{
		GetCmdArg(1, b, sizeof(b));
		times = StringToInt(b);
		if (times < 1) times = 1;
		if (times > MAX_STEPS) times = MAX_STEPS;
	}
	int done = 0;
	for (int t = 0; t < times; t++)
	{
		if (g_iCurStep >= g_iStepCount) break;
		if (!SkipCurrentStep())
		{
			// 输入被吞(按钮已消耗等): 明确告知, 避免空转
			ReplyToCommand(client, "[PTGOBJ] 步骤 %d 无响应(实体可能已消耗)— 可用 chain_step %d 强推",
				g_iCurStep + 1, g_iCurStep + 2 <= g_iStepCount ? g_iCurStep + 2 : g_iCurStep + 1);
			break;
		}
		done++;
	}
	ReplyToCommand(client, "[PTGOBJ] skipped %d step(s), now at %d/%d", done, g_iCurStep + 1 <= g_iStepCount ? g_iCurStep + 1 : g_iStepCount, g_iStepCount);
	return Plugin_Handled;
}

// 跳过当前一步; 返回是否真正推进了(g_iCurStep 前移)
bool SkipCurrentStep()
{
	int before = g_iCurStep;
	Step s;
	s = g_Steps[g_iCurStep];

	// reach / 无实体步骤: 手动推进度
	if (s.eClass[0] == 0)
	{
		RegisterProgress();
		return true;
	}

	char names[8][48];
	int nameCnt = ExplodeString(s.eName, ",", names, 8, 48);
	// acted 变量已由 g_iCurStep 前移判据取代
	bool matchedAny = false;
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, s.eClass)) != -1)
	{
		if (s.eName[0] != 0)
		{
			char tn[48];
			GetEntPropString(ent, Prop_Data, "m_iName", tn, sizeof(tn));
			bool hit = false;
			for (int ni = 0; ni < nameCnt; ni++)
				if (StrEqual(tn, names[ni])) { hit = true; break; }
			if (!hit) continue;
		}
		matchedAny = true;
		if (!IsValidEntity(ent)) continue;
		if (ApplySkipInput(ent))
		{
			LogMessage("[PTGOBJ] skip input fired on ent=%d (%s)", ent, s.eClass);
		}
	}

	if (!matchedAny)
	{
		// 实体不存在(已被消耗/解析失败): 直接推进度兜底
		RegisterProgress();
		return true;
	}
	// 有 hook 回调时 RegisterProgress 由 EO 触发(同步);
	// 以 g_iCurStep 是否前移作为"真推进"判据
	return (g_iCurStep != before);
}

// 对单个实体施加"完成语义"输入; 返回是否施加
bool ApplySkipInput(int ent)
{
	char cn[48];
	GetEntityClassname(ent, cn, sizeof(cn));

	if (StrEqual(cn, "func_button") || StrEqual(cn, "func_rot_button") || StrEqual(cn, "momentary_rot_button"))
	{
		AcceptEntityInput(ent, "Unlock");
		AcceptEntityInput(ent, "Press");
		return true;
	}
	if (StrEqual(cn, "prop_door_rotating"))
	{
		AcceptEntityInput(ent, "Unlock");
		AcceptEntityInput(ent, "Open");
		return true;
	}
	if (StrEqual(cn, "func_door") || StrEqual(cn, "func_door_rotating"))
	{
		AcceptEntityInput(ent, "Unlock");
		AcceptEntityInput(ent, "Open");
		return true;
	}
	if (StrEqual(cn, "func_breakable") || StrEqual(cn, "func_breakable_surf"))
	{
		AcceptEntityInput(ent, "Break");
		return true;
	}
	if (StrEqual(cn, "math_counter"))
	{
		// SetValue 到超大值 → 必然触发 OnHitMax
		SetVariantString("99999");
		AcceptEntityInput(ent, "SetValue");
		return true;
	}
	// trigger/pickup 等: 无法输入模拟
	return false;
}

// ────────────────────────── 扫描器 ──────────────────────────

static const char SCAN_CLASSES[][28] = {
	"func_button", "func_rot_button", "momentary_rot_button",
	"prop_door_rotating", "func_door", "func_door_rotating",
	"func_breakable", "func_breakable_surf",
	"math_counter", "logic_relay", "logic_branch",
	"trigger_once", "trigger_multiple",
	"weapon_gascan", "weapon_gascan_scavenge", "weapon_colasingle",
	"prop_minigun", "prop_physics"
};

// ────────────────────────── 准星查勘 ──────────────────────────
// 管理员对准目标实体执行, 输出类名/目标名/坐标/模型——配置剧本的定位神器

Action CmdObjAim(int client, int args)
{
	if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
		return Plugin_Handled;
	float eye[3], ang[3], dir[3];
	GetClientEyePosition(client, eye);
	GetClientEyeAngles(client, ang);
	GetAngleVectors(ang, dir, NULL_VECTOR, NULL_VECTOR);
	float end[3];
	for (int k = 0; k < 3; k++) end[k] = eye[k] + dir[k] * 3000.0;

	TR_TraceRayFilter(eye, end, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
	if (!TR_DidHit())
	{
		PrintToChat(client, "[OBJ] 准星未命中实体");
		return Plugin_Handled;
	}
	int ent = TR_GetEntityIndex();
	if (ent <= 0 || ent > MaxClients + 4096)
	{
		PrintToChat(client, "[OBJ] 命中世界几何(非实体)");
		return Plugin_Handled;
	}
	char cn[48], tn[48], mdl[96];
	GetEntityClassname(ent, cn, sizeof(cn));
	GetEntPropString(ent, Prop_Data, "m_iName", tn, sizeof(tn));
	mdl[0] = 0;
	if (HasEntProp(ent, Prop_Data, "m_ModelName"))
		GetEntPropString(ent, Prop_Data, "m_ModelName", mdl, sizeof(mdl));
	float c[3];
	EntityCenter(ent, c);
	PrintToChat(client, "[OBJ] ent=%d class=\x05%s\x01 name=\x05%s\x01", ent, cn, tn);
	PrintToChat(client, "[OBJ] pos=(\x05%.0f %.0f %.0f\x01) model=%.70s", c[0], c[1], c[2], mdl);
	LogMessage("[PTGOBJ] aim: ent=%d class=%s name=%s pos=(%.0f %.0f %.0f) model=%s", ent, cn, tn, c[0], c[1], c[2], mdl);
	return Plugin_Handled;
}

Action CmdChainScan(int client, int args)
{
	GetCurrentMap(g_sMap, sizeof(g_sMap));
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/ptg_chain_%s.txt", g_sMap);
	File f = OpenFile(path, "w");

	ReplyToCommand(client, "[PTGOBJ] scanning %s ...", g_sMap);
	int total = 0;
	for (int ci = 0; ci < sizeof(SCAN_CLASSES); ci++)
	{
		int ent = -1, cnt = 0;
		while ((ent = FindEntityByClassname(ent, SCAN_CLASSES[ci])) != -1)
		{
			cnt++; total++;
			char tn[48], mdl[96], pos[64];
			GetEntPropString(ent, Prop_Data, "m_iName", tn, sizeof(tn));
			float c[3];
			EntityCenter(ent, c);
			Format(pos, sizeof(pos), "%.0f %.0f %.0f", c[0], c[1], c[2]);
			mdl[0] = 0;
			if (HasEntProp(ent, Prop_Data, "m_ModelName"))
				GetEntPropString(ent, Prop_Data, "m_ModelName", mdl, sizeof(mdl));
			if (client > 0)
				ReplyToCommand(client, "[%s] name=\"%s\" pos=(%s) model=%.48s ent=%d",
					SCAN_CLASSES[ci], tn, pos, mdl, ent);
			if (f != null)
				f.WriteLine("[%s] name=\"%s\" pos=(%s) model=%s ent=%d",
					SCAN_CLASSES[ci], tn, pos, mdl, ent);
		}
		if (cnt > 0 && client > 0)
			ReplyToCommand(client, "── %s: %d ──", SCAN_CLASSES[ci], cnt);
	}
	if (f != null)
	{
		f.WriteLine("// total=%d", total);
		delete f;
	}
	ReplyToCommand(client, "[PTGOBJ] done total=%d → %s", total, path);
	return Plugin_Handled;
}
