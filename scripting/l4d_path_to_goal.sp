// ============================================================
//  [L4D2] Path To Goal — flow 梯度下降重写版 v5.0.0
//
//  弃用 11k 行自建 A* 管线（PTG v4.8.3），核心换成引擎 flow 场：
//    引擎 flow = 从地图起点沿 nav 的弧长，递增方向 = 出口方向。
//    从玩家所在 nav area 沿 4 向平面邻接（人类可走连接）做
//    flow 严格递增的梯度上升，直到到达 RESCUE_VEHICLE /
//    flow 接近地图最大值，或走到局部极大（死路/机关 → beacon 降级）。
//
//  已验证（c1m1_hotel，实验插件 l4d2_flow_path_test）：
//    69.4% area 可达、0 断链、LOS 1.7%、单次路径 0.9ms、无后台管线
//
//  命令（双击 0.5s 内两次触发 toggle，与旧版一致）：
//    path_to_goal / pathtogoal / wheretogo / imlost / guide / ptg
//
//  说明：
//    - 画线仅发给 toggle 的玩家本人（TE_SendToClient）
//    - 每段先画 nav-center 连线，LOS 失败用"共享边中点"修正
//      （两 area 包围盒在相邻方向的交集中心），再失败标红
//    - 死路/机关断链：路径画到断点 + 红色 beacon（玩家看到线
//      到电梯口/机关口，自然知道要走的路）
//    - 无 nav 地图（如 tumtara）：双击提示"此图无导航数据"，安静退出
// ============================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION     "5.0.0 2026-08-04"
#define CONFIG_FILENAME    "l4d_path_to_goal"

#define TEAM_SURVIVOR      2
#define MAX_STEPS          2000
#define REDRAW_INTERVAL    0.3
#define FALLBACK_MAXFLOW   999999.0

// 用 white.vmt 而非 laserbeam.vmt：TE beam 默认渲染模式下
// laserbeam 材质不可见（原版 v4.x 实锤：主线用 g_iLaserWhite）
#define VMT_LASER          "sprites/white.vmt"

int    g_iLaser;
bool   g_bGuideToggled[MAXPLAYERS + 1];
Handle g_hToggleTimer = null;
bool   g_bNavReady;          // 当前地图有 nav mesh（OnMapStart 查一次）
ArrayList g_hPathCache[MAXPLAYERS + 1];   // 路径缓存（移动 <128u 复用，零重算）
float  g_fPathCacheTime[MAXPLAYERS + 1];  // 上次重算时间（大图 BFS 成本高，≥0.5s 节流）
float  g_fPathCachePos[MAXPLAYERS + 1][3];
float  g_fPathCacheFlow[MAXPLAYERS + 1];
int    g_iPathCacheAttrs[MAXPLAYERS + 1];
Address g_AreaPathCacheEnd[MAXPLAYERS + 1];
float  g_fMapMaxFlow;        // 地图 flow 上限（每局懒初始化一次）
float  g_fFlowCoverage;      // 地图 flow 场覆盖率（0-1，OnMapStart 统计）
bool   g_bHasGoal;           // 找到出口实体（script_changelevel/trigger 等）
float  g_fGoalPos[3];        // 出口实体位置（目标）
Address g_GoalArea;          // 出口实体最近的 nav area（每次路径计算刷新）
Address g_FarGoalArea;       // fallback 目标：离出生点欧氏最远的同层 area
bool   g_bFarGoalReady;      // g_FarGoalArea 已计算
StringMap g_hVirtualEdges;   // 虚拟边缓存: "areaInt" → ArrayList(邻居 areaInts)
bool   g_bVirtualBuilt;      // 虚拟边已构建（OnMapStart 一次）
int    g_iEntityBridges;     // 实体桥数量（门/可炸墙配对成功数）
ArrayList g_hAreaList;       // index → areaInt（BFS index 化用）
StringMap g_hAreaIndex;      // areaInt → index
ArrayList g_hNeighborIdx;    // index → ArrayList(邻居 index)（4 向 + 虚拟边合并）
ArrayList g_hFlowValues;     // index → flow（预构建，BFS 零 native）
ArrayList g_hCenterX, g_hCenterY, g_hCenterZ;   // index → center 分量
bool   g_bNavTableReady;     // nav 表已构建
char   g_sNavMap[PLATFORM_MAX_PATH];  // 表所属地图（reload/换图懒重建）
float  g_fLastPathDiag;      // path 诊断日志限频

ConVar g_hCvarEnable;
ConVar g_hCvarDuration;
ConVar g_hCvarMax;

public Plugin myinfo =
{
	name = "[L4D2] Path To Goal (flow)",
	author = "server",
	description = "Flow gradient descent path indicator for Survivor team.",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	RegConsoleCmd("path_to_goal", CmdRequestGuide, "Point where to go to progress in the map.");
	RegConsoleCmd("pathtogoal",   CmdRequestGuide, "Point where to go to progress in the map.");
	RegConsoleCmd("wheretogo",    CmdRequestGuide, "Point where to go to progress in the map.");
	RegConsoleCmd("imlost",       CmdRequestGuide, "Point where to go to progress in the map.");
	RegConsoleCmd("guide",        CmdRequestGuide, "Point where to go to progress in the map.");
	RegConsoleCmd("ptg",          CmdRequestGuide, "Point where to go to progress in the map.");

	g_hCvarEnable   = CreateConVar("l4d_path_to_goal_enable",  "1",    "Enable the path-to-goal indicator.", FCVAR_NOTIFY);
	g_hCvarDuration = CreateConVar("l4d_path_to_goal_duration", "0.5", "Beam lifetime in seconds (must be > redraw interval 0.3s to avoid flicker).", FCVAR_NOTIFY);
	g_hCvarMax      = CreateConVar("l4d_path_to_goal_max", "32", "Max beam segments per frame (client TE buffer cap).", FCVAR_NOTIFY);

	AutoExecConfig(true, CONFIG_FILENAME);
}

public void OnMapStart()
{
	// 统一入口：reload 后 OnMapStart 不触发，改为懒检测（CmdRequestGuide /
	// FlowPathFrom 都会调用 EnsureInitForCurrentMap），这里直接强制重建
	EnsureInitForCurrentMap();
}

// 清理上一张图的所有状态（表/虚拟边/目标缓存跨图残留会全量失效：
// c5m3 用 silenthill 的表 → AreaToIndex 全 miss → BFS 退化 len=2）
void ResetMapState()
{
	g_bNavReady = false;
	g_fFlowCoverage = 0.0;
	g_iEntityBridges = 0;
	g_bVirtualBuilt = false;
	if (g_hVirtualEdges != null) { delete g_hVirtualEdges; g_hVirtualEdges = null; }
	g_bNavTableReady = false;
	if (g_hAreaList != null) { delete g_hAreaList; g_hAreaList = null; }
	if (g_hAreaIndex != null) { delete g_hAreaIndex; g_hAreaIndex = null; }
	if (g_hNeighborIdx != null) { delete g_hNeighborIdx; g_hNeighborIdx = null; }
	if (g_hFlowValues != null) { delete g_hFlowValues; g_hFlowValues = null; }
	if (g_hCenterX != null) { delete g_hCenterX; g_hCenterX = null; }
	if (g_hCenterY != null) { delete g_hCenterY; g_hCenterY = null; }
	if (g_hCenterZ != null) { delete g_hCenterZ; g_hCenterZ = null; }
	g_fMapMaxFlow = 0.0;
	g_bHasGoal = false;
	g_GoalArea = Address_Null;
	g_bFarGoalReady = false;
	g_FarGoalArea = Address_Null;
}

// 懒初始化：插件 reload（OnMapStart 不触发）或换图后首次调用时重建全部表。
// 幂等：同图重复调用无副作用（Build* 自带 g_b*Ready 守卫）。
void EnsureInitForCurrentMap()
{
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	if (g_sNavMap[0] != 0 && StrEqual(g_sNavMap, map) && g_bNavTableReady)
		return;
	strcopy(g_sNavMap, sizeof(g_sNavMap), map);
	ResetMapState();

	g_iLaser = PrecacheModel(VMT_LASER, true);
	if (g_iLaser == 0)
		g_iLaser = PrecacheModel("sprites/laserbeam.vmt", true);

	// nav mesh 随地图加载，一局内不变（机关/实体变化只改 flow 值不改 area 集合）
	// flow 覆盖率：三方图 nav 质量差时引擎 flow 场可能只覆盖极少区域
	//（死亡厕所迷宫 6%、tumtara 0%）→ 覆盖率过低直接禁用画线
	ArrayList all = new ArrayList();
	L4D_GetAllNavAreas(all);
	g_bNavReady = (all.Length > 0);
	int flowValid = 0;
	for (int i = 0; i < all.Length; i++)
	{
		if (L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(all.Get(i))) >= 0.0)
			flowValid++;
	}
	g_fFlowCoverage = all.Length > 0 ? float(flowValid) / float(all.Length) : 0.0;
	delete all;

	FindGoalEntity();
	BuildVirtualEdges();
	ComputeFarGoal();
	BuildNavTables();
}

// ────────────────────────── nav 索引表（BFS 零 native 化） ──────────────────────────
// BFS 卡顿根治：预构建 area→index、邻居 index 表、flow/center 表。
// BFS 运行时纯 ArrayList 操作（无 StringMap 哈希、无 native 调用）。
// 死亡厕所迷宫实测：fallback BFS + StringMap visited/parent 每 0.3s 全遍历
// → 服务器明显卡顿（SourcePawn VM 哈希开销巨大）。

void BuildNavTables()
{
	if (g_bNavTableReady)
		return;
	g_bNavTableReady = true;

	ArrayList all = new ArrayList();
	L4D_GetAllNavAreas(all);
	int n = all.Length;

	g_hAreaList = new ArrayList();
	g_hAreaIndex = new StringMap();
	g_hFlowValues = new ArrayList();
	g_hCenterX = new ArrayList();
	g_hCenterY = new ArrayList();
	g_hCenterZ = new ArrayList();

	char key[16];
	float c[3];
	for (int i = 0; i < n; i++)
	{
		int areaInt = all.Get(i);
		g_hAreaList.Push(areaInt);
		IntToString(areaInt, key, sizeof(key));
		g_hAreaIndex.SetValue(key, i);
		g_hFlowValues.Push(L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(areaInt)));
		L4D_GetNavAreaCenter(view_as<Address>(areaInt), c);
		g_hCenterX.Push(c[0]);
		g_hCenterY.Push(c[1]);
		g_hCenterZ.Push(c[2]);
	}

	// 邻居表：4 向 + 虚拟边合并
	g_hNeighborIdx = new ArrayList();
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
		ArrayList vnb;
		if (GetVirtualNeighbors(g_hAreaList.Get(i), vnb))
		{
			for (int j = 0; j < vnb.Length; j++)
			{
				IntToString(vnb.Get(j), key, sizeof(key));
				int idx;
				if (g_hAreaIndex.GetValue(key, idx))
					nb.Push(idx);
			}
		}
		g_hNeighborIdx.Push(nb);
	}
	delete adj;
	delete all;
}

int AreaToIndex(Address a)
{
	char key[16];
	IntToString(view_as<int>(a), key, sizeof(key));
	int idx = -1;
	if (g_hAreaIndex.GetValue(key, idx))
		return idx;
	return -1;
}

// ────────────────────────── fallback 目标：欧氏最远同层 area ──────────────────────────
// 无出口实体时，目标是"离出生点欧氏最远的同层 area"（迷宫/大图流程终点
// 通常在几何最远端）。教训：fallback 用 flow 最大点会把玩家引到
// flow 孤岛（死亡厕所迷宫唯一 flow 区在 z=384 楼上 → 线往天花板画）。

void ComputeFarGoal()
{
	g_bFarGoalReady = true;
	g_FarGoalArea = Address_Null;

	// 基准 = 所有 PLAYER_START area 的平均位置（地图固定基准，不随玩家漂移）
	ArrayList all = new ArrayList();
	L4D_GetAllNavAreas(all);
	float base[3], bsum[3];
	int bcount = 0;
	for (int i = 0; i < all.Length; i++)
	{
		Address a = view_as<Address>(all.Get(i));
		if (L4D_GetNavArea_SpawnAttributes(a) & NAV_SPAWN_PLAYER_START)
		{
			float c[3];
			L4D_GetNavAreaCenter(a, c);
			bsum[0] += c[0]; bsum[1] += c[1]; bsum[2] += c[2];
			bcount++;
		}
	}
	if (bcount == 0)
	{
		delete all;
		return;
	}
	for (int k = 0; k < 3; k++)
		base[k] = bsum[k] / bcount;

	// 同层（相对基准 ±150u）+ 欧氏最远
	float bestD = -1.0;
	for (int i = 0; i < all.Length; i++)
	{
		float c[3];
		L4D_GetNavAreaCenter(view_as<Address>(all.Get(i)), c);
		if (FloatAbs(c[2] - base[2]) > 150.0)
			continue;
		float d = GetVectorDistance(base, c, false);
		if (d > bestD)
		{
			bestD = d;
			g_FarGoalArea = view_as<Address>(all.Get(i));
		}
	}
	delete all;
	LogMessage("[PTG] farGoal dist=%.0f", bestD);
}

// ────────────────────────── 虚拟边构建（补 nav 缺失连接） ──────────────────────────
// 大量三方图的 nav 没记录"门洞/机关通道"连接（玩家实际能走，nav 显示孤岛，
// 死亡厕所迷宫验证：261 次测试找到 74 条地面 LOS 通道，28 岛→21 岛）。
// 策略：4 向连通组件间，距离 <400u + 高度差 <90u + 地面视线(+30u，实体放行
// =门也算通) 的 area 对 → 双向注册虚拟边。BFS 时 4 向 + 虚拟边一起搜。
// OnMapStart 一次性构建缓存；渲染时每段 LOS 验证（直的绿线，转弯标红）。

void BuildVirtualEdges()
{
	if (g_bVirtualBuilt)
		return;
	g_bVirtualBuilt = true;
	if (g_hVirtualEdges != null)
		delete g_hVirtualEdges;
	g_hVirtualEdges = new StringMap();

	float t0 = GetEngineTime();
	ArrayList all = new ArrayList();
	L4D_GetAllNavAreas(all);
	int n = all.Length;
	if (n == 0)
	{
		delete all;
		return;
	}

	// 1. 4 向连通组件（同组件内部 4 向已连，虚拟边只跨组件）
	StringMap compId = new StringMap();
	ArrayList compSize = new ArrayList();
	char key[16];
	for (int i = 0; i < n; i++)
	{
		IntToString(all.Get(i), key, sizeof(key));
		if (compId.ContainsKey(key)) continue;
		int cid = compSize.Length;
		compSize.Push(0);
		ArrayList queue = new ArrayList();
		queue.Push(all.Get(i));
		compId.SetValue(key, cid);
		int head = 0;
		while (head < queue.Length)
		{
			int areaInt = queue.Get(head);
			head++;
			compSize.Set(cid, compSize.Get(cid) + 1);
			ArrayList adj = new ArrayList();
			for (int dir = 0; dir < 4; dir++)
			{
				adj.Clear();
				L4D_NavArea_GetAdjacentAreas(view_as<Address>(areaInt), dir, adj);
				for (int j = 0; j < adj.Length; j++)
				{
					int aInt = adj.Get(j);
					IntToString(aInt, key, sizeof(key));
					if (!compId.ContainsKey(key))
					{
						compId.SetValue(key, cid);
						queue.Push(aInt);
					}
				}
			}
			delete adj;
		}
		delete queue;
	}

	// 2. 128u 网格桶预筛（只测近邻 area 对）
	StringMap grid = new StringMap();
	float center[3];
	for (int i = 0; i < n; i++)
	{
		L4D_GetNavAreaCenter(view_as<Address>(all.Get(i)), center);
		char gkey[32];
		Format(gkey, sizeof(gkey), "%d_%d",
			RoundToFloor(center[0] / 128.0), RoundToFloor(center[1] / 128.0));
		ArrayList bucket;
		if (!grid.GetValue(gkey, bucket))
		{
			bucket = new ArrayList();
			grid.SetValue(gkey, bucket);
		}
		bucket.Push(all.Get(i));
	}

	// 3. 跨组件近邻对 → 地面 LOS → 双向注册虚拟边
	int edges = 0;
	StringMapSnapshot snap = grid.Snapshot();
	for (int bi = 0; bi < snap.Length; bi++)
	{
		char gkey[64];
		snap.GetKey(bi, gkey, sizeof(gkey));
		ArrayList bucketA;
		if (!grid.GetValue(gkey, bucketA)) continue;

		char parts[2][16];
		ExplodeString(gkey, "_", parts, 2, 16);
		int gx = StringToInt(parts[0]);
		int gy = StringToInt(parts[1]);
		for (int dx = -1; dx <= 1; dx++)
		{
			for (int dy = -1; dy <= 1; dy++)
			{
				char nkey[32];
				Format(nkey, sizeof(nkey), "%d_%d", gx + dx, gy + dy);
				ArrayList bucketB;
				if (!grid.GetValue(nkey, bucketB)) continue;

				for (int i = 0; i < bucketA.Length; i++)
				{
					int aInt = bucketA.Get(i);
					for (int j = (bucketA == bucketB) ? i + 1 : 0; j < bucketB.Length; j++)
					{
						int bInt = bucketB.Get(j);
						if (aInt == bInt) continue;
						IntToString(aInt, key, sizeof(key));
						int cida;
						if (!compId.GetValue(key, cida)) continue;
						IntToString(bInt, key, sizeof(key));
						int cidb;
						if (!compId.GetValue(key, cidb)) continue;
						if (cida == cidb) continue;   // 同组件内部不补

						float pa[3], pb[3];
						L4D_GetNavAreaCenter(view_as<Address>(aInt), pa);
						L4D_GetNavAreaCenter(view_as<Address>(bInt), pb);
						if (GetVectorDistance(pa, pb, false) > 400.0) continue;
						if (FloatAbs(pa[2] - pb[2]) > 90.0) continue;

						float ta[3], tb[3];
						ta = pa; ta[2] += 30.0;
						tb = pb; tb[2] += 30.0;
						TR_TraceRayFilter(ta, tb, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
						if (TR_DidHit()) continue;

						RegisterVirtualEdge(aInt, bInt);
						RegisterVirtualEdge(bInt, aInt);
						edges++;
					}
				}
			}
		}
	}
	delete snap;

	// 清理网格桶
	snap = grid.Snapshot();
	for (int i = 0; i < snap.Length; i++)
	{
		char gkey[64];
		snap.GetKey(i, gkey, sizeof(gkey));
		ArrayList bucket;
		if (grid.GetValue(gkey, bucket)) delete bucket;
	}
	delete snap;
	delete grid;
	delete compSize;
	delete compId;
	delete all;

	// 实体桥：门/可炸墙 = nav 作者故意不连的通道（交互后才通）→ 补连接。
	// 位置用 brush bounds 中心（brush origin 恒 0 不可用）。
	g_iEntityBridges = BuildEntityBridges();

	LogMessage("[PTG] virtual edges=%d (los=%d entity=%d) areas=%d time=%.1fms", edges + g_iEntityBridges, edges, g_iEntityBridges, n, (GetEngineTime() - t0) * 1000.0);
}

// ────────────────────────── 实体桥（门/可炸墙） ──────────────────────────
// 死亡厕所迷宫验证：nav 孤岛间的真实通道是 func_breakable（炸墙）、
// prop_door_rotating/func_door（门）——nav 作者没画连接，但实体表里有。
// 做法：实体中心 ± 垂直门面方向 70u → 两侧各取最近同层 nav area → 配对注册。
// 返回注册的边数。

int BuildEntityBridges()
{
	int edges = 0;
	ArrayList used = new ArrayList();   // 已处理的实体（防 func_door_rotating 与 prop 重复）

	// 门类：prop_door_rotating / func_door / func_door_rotating
	char doorClasses[3][24] = { "prop_door_rotating", "func_door", "func_door_rotating" };
	for (int ci = 0; ci < 3; ci++)
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, doorClasses[ci])) != -1)
		{
			if (used.FindValue(ent) != -1) continue;
			used.Push(ent);
			if (BridgeEntitySides(ent, true))
				edges++;
		}
	}

	// 可炸墙：func_breakable（还有可打碎的 func_breakable 装饰——两侧配对无害，
	// 打碎即可通行，符合逻辑）
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "func_breakable")) != -1)
	{
		if (used.FindValue(ent) != -1) continue;
		used.Push(ent);
		if (BridgeEntitySides(ent, false))
			edges++;
	}

	delete used;
	return edges;
}

// 单个实体两侧配对；返回是否注册了边
bool BridgeEntitySides(int ent, bool useYaw)
{
	// 中心 = origin + (mins+maxs)/2（brush 的 origin 恒 0，mins/maxs 是世界坐标；
	// prop 的 mins/maxs 相对 origin —— 统一公式两者都对）
	float origin[3], mins[3], maxs[3], center[3];
	GetEntPropVector(ent, Prop_Send, "m_vecOrigin", origin);
	GetEntPropVector(ent, Prop_Send, "m_vecMins", mins);
	GetEntPropVector(ent, Prop_Send, "m_vecMaxs", maxs);
	for (int k = 0; k < 3; k++)
		center[k] = origin[k] + (mins[k] + maxs[k]) * 0.5;

	// 两侧方向：默认 ±X；有朝向（门）则用垂直门面的方向
	float sx = 1.0, sy = 0.0;
	if (useYaw)
	{
		float ang[3];
		GetEntPropVector(ent, Prop_Data, "m_angRotation", ang);
		float yaw = ang[1] * 0.0174533;   // deg → rad
		// L4D2: fwd = (Sine(yaw), -Cosine(yaw))；side 垂直 fwd
		float fx = Sine(yaw), fy = -Cosine(yaw);
		sx = -fy;
		sy = fx;
	}

	float p1[3], p2[3];
	p1 = center; p2 = center;
	p1[0] += sx * 70.0; p1[1] += sy * 70.0;
	p2[0] -= sx * 70.0; p2[1] -= sy * 70.0;

	Address a1 = GetSameFloorArea(p1);
	Address a2 = GetSameFloorArea(p2);
	if (a1 == Address_Null || a2 == Address_Null || a1 == a2)
		return false;

	RegisterVirtualEdge(view_as<int>(a1), view_as<int>(a2));
	RegisterVirtualEdge(view_as<int>(a2), view_as<int>(a1));
	return true;
}

// 取最近同层 nav area（Z 差 <=150u）
Address GetSameFloorArea(const float pos[3])
{
	Address a = L4D_GetNearestNavArea(pos, 300.0, false, false, false, TEAM_SURVIVOR);
	if (a == Address_Null)
		return Address_Null;
	float c[3];
	L4D_GetNavAreaCenter(a, c);
	if (FloatAbs(c[2] - pos[2]) > 150.0)
		return Address_Null;
	return a;
}

void RegisterVirtualEdge(int a, int b)
{
	char key[16];
	IntToString(a, key, sizeof(key));
	ArrayList list;
	if (!g_hVirtualEdges.GetValue(key, list))
	{
		list = new ArrayList();
		g_hVirtualEdges.SetValue(key, list);
	}
	list.Push(b);
}

// 查询 area 的虚拟邻居（无则返回空 list）
bool GetVirtualNeighbors(int areaInt, ArrayList &out)
{
	char key[16];
	IntToString(areaInt, key, sizeof(key));
	return g_hVirtualEdges.GetValue(key, out);
}

// ────────────────────────── 出口目标实体 ──────────────────────────
// flow 递增方向 = "离出生点弧长更远"，在绕行结构地图（如 c2m3 过山车轨道）
// 上弧长最大点是轨道中段而非出口 → 线指向天花板。
// 正确目标 = 地图出口实体位置（章节出口 trigger / finale 救援区）。
// 找不到出口实体（部分三方图）→ fallback 到 flow 最大（旧行为）。

void FindGoalEntity()
{
	g_bHasGoal = false;
	float pos[3];

	// L4D2 章节出口：script_changelevel（玩家走过安全门触发切图）
	int ent = -1;
	while ((ent = FindEntityByClassname(ent, "script_changelevel")) != -1)
	{
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			g_fGoalPos = pos;
			g_bHasGoal = true;
			LogMessage("[PTG] goal=script_changelevel pos=(%.0f %.0f %.0f)", pos[0], pos[1], pos[2]);
			return;
		}
	}

	// 老式章节出口 trigger
	ent = -1;
	while ((ent = FindEntityByClassname(ent, "trigger_changelevel")) != -1)
	{
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			g_fGoalPos = pos;
			g_bHasGoal = true;
			LogMessage("[PTG] goal=trigger_changelevel pos=(%.0f %.0f %.0f)", pos[0], pos[1], pos[2]);
			return;
		}
	}

	// finale 救援区（救援车位置已在梯度判定中用 RESCUE_VEHICLE 属性覆盖，
	// 此处兜底 trigger_finale）
	ent = -1;
	while ((ent = FindEntityByClassname(ent, "trigger_finale")) != -1)
	{
		GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
		if (pos[0] != 0.0 || pos[1] != 0.0 || pos[2] != 0.0)
		{
			g_fGoalPos = pos;
			g_bHasGoal = true;
			LogMessage("[PTG] goal=trigger_finale pos=(%.0f %.0f %.0f)", pos[0], pos[1], pos[2]);
			return;
		}
	}
}

public void OnPluginEnd()
{
	if (g_hToggleTimer != null)
	{
		KillTimer(g_hToggleTimer);
		g_hToggleTimer = null;
	}
}

public void OnMapEnd()
{
	if (g_hToggleTimer != null)
	{
		KillTimer(g_hToggleTimer);
		g_hToggleTimer = null;
	}
}

// ────────────────────────── 双击 toggle ──────────────────────────

Action CmdRequestGuide(int client, int args)
{
	if (!g_hCvarEnable.BoolValue || client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
		return Plugin_Handled;

	// reload 后 OnMapStart 不触发：这里兜底懒初始化（换图也会重建）
	EnsureInitForCurrentMap();

	if (!g_bNavReady)
	{
		ReplyToCommand(client, "[PTG] 此图无导航数据（nav mesh 缺失），无法指引");
		return Plugin_Handled;
	}
	if (g_fFlowCoverage < 0.2)
	{
		// 极低 flow 覆盖 = 谜题/陷阱/特殊机制图（死亡厕所迷宫 6%）。
		// 有实体桥（门/可炸墙 = 真实交互通道）→ 桥接模式放行，线引导到
		// 机关/炸墙点，玩家按逻辑推进（用户拍板：迷宫越复杂越需要导航线）。
		// 无实体桥 → 数据层面无解，禁用。
		if (g_iEntityBridges == 0)
		{
			ReplyToCommand(client, "[PTG] 此图为谜题/陷阱型地图（flow 场仅 %.0f%%），自动导航不可用", g_fFlowCoverage * 100.0);
			return Plugin_Handled;
		}
		PrintToChat(client, "[PTG] \x05谜题图（flow 场 %.0f%%）已启用实体桥模式：线引导至机关/炸墙点，按逻辑推进",
			g_fFlowCoverage * 100.0);
	}

	// 单击 toggle：输入一次开，再输入一次关
	g_bGuideToggled[client] = !g_bGuideToggled[client];
	LogMessage("[PTG] toggle client=%d on=%d laser=%d navReady=%d", client, g_bGuideToggled[client], g_iLaser, g_bNavReady);
	if (g_bGuideToggled[client])
		PrintToChat(client, "[PTG] \x05导航线 ON — 沿橙色线走向安全屋/出口");
	else
		PrintToChat(client, "[PTG] \x04导航线 OFF");
	Guide_UpdateRedrawTimer();
	return Plugin_Handled;
}

void Guide_UpdateRedrawTimer()
{
	bool anyOn = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bGuideToggled[i]) { anyOn = true; break; }
	}

	if (anyOn && g_hToggleTimer == null)
	{
		// 递归 one-shot：TIMER_REPEAT 空服不触发（SourceMod bug，v4.5 教训）
		g_hToggleTimer = CreateTimer(REDRAW_INTERVAL, Timer_ToggleRedraw, _, TIMER_FLAG_NO_MAPCHANGE);
	}
	else if (!anyOn && g_hToggleTimer != null)
	{
		KillTimer(g_hToggleTimer);
		g_hToggleTimer = null;
	}
}

Action Timer_ToggleRedraw(Handle timer)
{
	// 递归 one-shot — 先排下一次再干活
	g_hToggleTimer = CreateTimer(REDRAW_INTERVAL, Timer_ToggleRedraw, _, TIMER_FLAG_NO_MAPCHANGE);

	bool anyOn = false;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!g_bGuideToggled[i] || !IsClientInGame(i) || IsFakeClient(i))
			continue;
		anyOn = true;

		float origin[3];
		GetClientAbsOrigin(i, origin);

		// 移动 <128u 且缓存有效 → 用缓存路径画线（零路径计算）
		// 重算节流 ≥0.5s：全图 BFS 成本随图线性增长，快跑也不逐帧算
		//（大三方图 2 万 areas 单次 BFS 可达百 ms 级，0.3s 逐帧会卡）
		// 缓存有效性双保险：句柄非 null + 时间戳>0（悬垂句柄 ≠ null 但时间戳永不为负，
		// 防"某处 delete 未置 null"同类回归——DrawPathList 曾误删缓存引发 788 连环崩）
		if (g_fPathCacheTime[i] > 0.0 && g_hPathCache[i] != null
			&& (GetVectorDistance(origin, g_fPathCachePos[i], false) < 128.0
				|| GetEngineTime() - g_fPathCacheTime[i] < 0.5))
		{
			if (GetEngineTime() - g_fLastPathDiag > 5.0)
			{
				LogMessage("[PTG] diag cache-hit draw");
				g_fLastPathDiag = GetEngineTime();
			}
			DrawPathList(i, origin, g_hPathCache[i],
				g_fPathCacheFlow[i], g_iPathCacheAttrs[i], g_AreaPathCacheEnd[i]);
			continue;
		}

		// 重算路径并缓存
		g_fPathCacheTime[i] = GetEngineTime();
		float endFlow = -1.0;
		int endAttrs = 0;
		Address endArea = Address_Null;
		ArrayList path = FlowPathFrom(origin, endFlow, endAttrs, endArea);
		if (path != null)
		{
			delete g_hPathCache[i];
			g_hPathCache[i] = path.Clone();
			g_fPathCachePos[i] = origin;
			g_fPathCacheFlow[i] = endFlow;
			g_iPathCacheAttrs[i] = endAttrs;
			g_AreaPathCacheEnd[i] = endArea;
		}
		else if (GetEngineTime() - g_fLastPathDiag > 5.0)
		{
			LogMessage("[PTG] diag FlowPathFrom returned NULL");
			g_fLastPathDiag = GetEngineTime();
		}
		DrawPathList(i, origin, path, endFlow, endAttrs, endArea);
		delete path;
	}

	if (!anyOn)
	{
		g_hToggleTimer = null;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

// ────────────────────────── 画线 ──────────────────────────

void DrawPathList(int client, const float startPos[3], ArrayList path, float endFlow, int endAttrs, Address endArea)
{
	if (g_iLaser == 0)
		return;
	if (path == null || path.Length < 1)
		return;
	// 注意：path 由调用方管理，本函数不 delete（缓存路径复用）
	LogMessage("[PTG] draw client=%d laser=%d len=%d flow=%.0f attrs=%d pos=(%.0f %.0f %.0f)", client, g_iLaser, path.Length, endFlow, endAttrs, startPos[0], startPos[1], startPos[2]);

	int colorGood[4] = {255, 200, 75, 255};   // amber trail（全不透明，醒目）
	int colorBad[4]  = {255, 60, 0, 255};     // blocked 段 / 断链 beacon
	int len = path.Length;

	// 玩家当前位置 → 第一个 path area 的衔接段（无条件画：nav area 可能
	// 长几十米，玩家在 area 内走动时 line 起点必须贴玩家脚，否则线
	// 固定在 area 中心不动 — "线停留在原地"教训）
	float cur[3];
	cur = startPos;
	cur[2] += 10.0;   // 地面之上 10u（-13 会埋进地面不可见）
	float firstC[3];
	L4D_GetNavAreaCenter(view_as<Address>(path.Get(0)), firstC);
	firstC[2] += 10.0;
	// Z 差 >150u 不画衔接段（起点 area 跨层时防竖直线段上天花板）
	if (GetVectorDistance(cur, firstC, false) > 0.5 && FloatAbs(cur[2] - firstC[2]) <= 150.0)
		BeamSegment(client, cur, firstC, colorGood);

	// 逐段画线（抽样）：nav-center 连线，LOS 失败用共享边中点修正。
	// 一次画 300+ 段会塞爆客户端 TE/beam 缓冲，第一批之后全部创建失败
	// → "线停留在原地"（原版 maxBeams=32 教训）
	int maxBeams = g_hCvarMax.IntValue;
	if (maxBeams <= 0) maxBeams = 32;
	int step = 1;
	if (len > maxBeams)
	{
		step = (len + maxBeams - 1) / maxBeams;
		if (step < 1) step = 1;
	}

	// 近段全量画（脚下连续有线），远段抽样（客户端 TE 缓冲上限）
	// 一次画 300+ 段会塞爆客户端 beam 池 → "线停留在原地"（原版 maxBeams 教训）
	int nearSegs = 6;
	int trailDrawn = 0;
	for (int i = 0; i < len - 1 && trailDrawn < maxBeams; i += (i < nearSegs ? 1 : step))
	{
		trailDrawn++;
		float a[3], b[3];
		L4D_GetNavAreaCenter(view_as<Address>(path.Get(i)), a);
		L4D_GetNavAreaCenter(view_as<Address>(path.Get(i + 1)), b);
		a[2] += 10.0;
		b[2] += 10.0;

		if (LosClear(a, b))
		{
			BeamSegment(client, a, b, colorGood);
			continue;
		}

		// 中心连线穿墙 → 共享边中点中转（A→M→B）
		float mid[3];
		if (SharedEdgeMidpoint(view_as<Address>(path.Get(i)), view_as<Address>(path.Get(i + 1)), mid))
		{
			mid[2] = (a[2] + b[2]) * 0.5;
			if (LosClear(a, mid) && LosClear(mid, b))
			{
				BeamSegment(client, a, mid, colorGood);
				BeamSegment(client, mid, b, colorGood);
				continue;
			}
		}

		// 修正失败：标红（路径完整可见，玩家知道此段异常）
		BeamSegment(client, a, b, colorBad);
	}

	// 终点 beacon：到达出口竖绿线；断链（死路/机关）竖红线
	// 判定：救援车 / 到达出口实体 / fallback flow 最大
	bool reached = (endAttrs & NAV_SPAWN_RESCUE_VEHICLE) ? true : false;
	if (!reached && g_GoalArea != Address_Null)
		reached = (endArea == g_GoalArea) ? true : false;
	if (!reached && g_GoalArea == Address_Null
		&& g_fMapMaxFlow < FALLBACK_MAXFLOW && endFlow >= g_fMapMaxFlow * 0.95)
		reached = true;
	float endC[3];
	L4D_GetNavAreaCenter(endArea, endC);
	endC[2] += 10.0;
	float top[3];
	top = endC;
	top[2] += 200.0;
	BeamSegment(client, endC, top, reached ? colorGood : colorBad);
	// ⚠️ 不 delete path！调用方管理（缓存分支复用 g_hPathCache，重算分支 771 释放）。
	// 曾在此 delete → 缓存句柄悬垂 → 第二次画线起 Timer 每 0.3s 崩（error 3）→ 线消失。
}

void BeamSegment(int client, const float p1[3], const float p2[3], const int color[4])
{
	// beam 寿命必须与重画节奏匹配（~1s）：寿命过长旧位置的线残留叠加，
	// 看起来"线固定原处不跟随"（10s 寿命的教训）
	float life = g_hCvarDuration.FloatValue;
	if (life <= 0.0) life = 1.0;
	TE_SetupBeamPoints(p1, p2, g_iLaser, 0, 0, 0, life, 1.0, 3.0, 0, 0.0, color, 0);
	if (client > 0 && IsClientInGame(client))
		TE_SendToClient(client);
	else
		TE_SendToAll();
}

// ────────────────────────── 核心：flow 梯度上升 ──────────────────────────

ArrayList FlowPathFrom(const float pos[3], float &endFlow, int &endAttrs, Address &endArea)
{
	// 懒初始化兜底（reload/换图后首次画线）
	EnsureInitForCurrentMap();

	// 懒初始化地图 flow 上限
	if (g_fMapMaxFlow <= 0.0)
	{
		g_fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
		if (g_fMapMaxFlow <= 0.0)
			g_fMapMaxFlow = FALLBACK_MAXFLOW;
	}

	ArrayList path = new ArrayList();
	// 起点选择：同层优先逐级放大 + Z 差 150u 硬过滤 + 邻居检查。
	// 教训1：anyZ=true 会把起点捞到楼上 area（死亡厕所迷宫 z=16 玩家 → z=384
	//   楼上 area，500u 垂直距离内）→ 衔接段竖直画向天花板
	// 教训2：迷宫图出生点可能是"零邻居孤岛 area"（nav 存在但无连接）→
	//   BFS 可达集=1 → 无解。起点必须是有邻居的 area（孤岛 area 跳过）
	Address start = Address_Null;
	for (int range = 500; range <= 2000 && start == Address_Null; range *= 2)
	{
		Address cand = L4D_GetNearestNavArea(pos, float(range), false, false, false, TEAM_SURVIVOR);
		if (cand == Address_Null)
			continue;
		float c[3];
		L4D_GetNavAreaCenter(cand, c);
		if (FloatAbs(c[2] - pos[2]) > 150.0)
			continue;
		// 孤岛 area（无 4 向/虚拟邻居）跳过——无路可走
		if (g_bNavTableReady)
		{
			int idx = AreaToIndex(cand);
			if (idx < 0 || view_as<ArrayList>(g_hNeighborIdx.Get(idx)).Length == 0)
				continue;
		}
		start = cand;
	}
	if (start == Address_Null)
	{
		// 跨层兜底（电梯井/特殊位置）：anyZ=true 且 Z 差放宽
		start = L4D_GetNearestNavArea(pos, 500.0, true, false, false, TEAM_SURVIVOR);
	}
	if (start == Address_Null)
	{
		delete path;
		return null;
	}

	// 目标 area：出口实体优先；无实体 → 欧氏最远同层 area（流程终点方向）。
	// 教训：fallback 用 flow 最大点会把玩家引到 flow 孤岛（迷宫图唯一 flow
	// 区在楼上 → 线往天花板画）
	Address goalArea = Address_Null;
	float goalFlow = -1.0;
	if (g_bHasGoal)
	{
		goalArea = L4D_GetNearestNavArea(g_fGoalPos, 1000.0, true, false, false, TEAM_SURVIVOR);
		if (goalArea != Address_Null)
			goalFlow = L4D2Direct_GetTerrorNavAreaFlow(goalArea);
	}
	else if (g_bFarGoalReady)
	{
		goalArea = g_FarGoalArea;
	}
	g_GoalArea = goalArea;

	Address cur = start;
	float curFlow = L4D2Direct_GetTerrorNavAreaFlow(cur);
	int guard = 0;
	int bridges = 0;
	ArrayList adj = new ArrayList();

	// 混合主循环：梯度上升为主；梯度卡住（无更大 flow 邻居/无 flow）时
	// BFS 桥接（4 向 + 虚拟边）跳到"有 flow 的 area"或目标 area，继续梯度
	while (guard < MAX_STEPS)
	{
		guard++;
		path.Push(view_as<int>(cur));

		endAttrs = L4D_GetNavArea_SpawnAttributes(cur);
		if (endAttrs & NAV_SPAWN_RESCUE_VEHICLE)
			break;   // 到达救援车
		if (goalArea != Address_Null && cur == goalArea)
			break;   // 到达出口实体（安全门/切图 trigger 附近）
		if (curFlow >= 0.0)
		{
			if (goalFlow > 0.0 && curFlow >= goalFlow)
				break;   // flow 已到出口区域（在轨道段时立即断，玩家下车回走）
			if (goalArea == Address_Null && g_fMapMaxFlow < FALLBACK_MAXFLOW && curFlow >= g_fMapMaxFlow * 0.95)
				break;   // fallback：无出口实体时用 flow 最大判定
		}

		// 梯度步（只在有 flow 时）：4 向邻接中 flow 严格递增
		Address best = Address_Null;
		float bestFlow = curFlow;
		if (curFlow >= 0.0)
		{
			for (int dir = 0; dir < 4; dir++)
			{
				adj.Clear();
				L4D_NavArea_GetAdjacentAreas(cur, dir, adj);
				for (int j = 0; j < adj.Length; j++)
				{
					Address a = view_as<Address>(adj.Get(j));
					float f = L4D2Direct_GetTerrorNavAreaFlow(a);
					if (f >= 0.0 && f > bestFlow)
					{
						bestFlow = f;
						best = a;
					}
				}
			}
			if (best != Address_Null)
			{
				cur = best;
				curFlow = bestFlow;
				continue;
			}
		}

		// 梯度卡住（局部极大/无 flow）→ 一次 BFS 全图直达。
		// 根治：BFS 深限 = 全节点数、目标 = goal 直达（或可达集最优），
		// 且 BFS 后直接结束（不再碎步回来继续 gradient）——每次路径计算
		// 最多 1 次 BFS，成本与图大小线性，与 flow 场质量解耦。
		//（c5m3 教训：旧版"第一个 flow 邻居就停"→ 366 次碎步桥接 + guard
		//  2000 撞顶 → 每帧全图级计算 → 卡顿）
		ArrayList bridge = new ArrayList();
		float startZ = 0.0;
		{
			float szc[3];
			L4D_GetNavAreaCenter(cur, szc);
			startZ = szc[2];
		}
		Address next = BfsBridge(cur, curFlow, goalArea, startZ, bridge, false);
		if (next == Address_Null)
		{
			// 正常 BFS 无解 → 降级：画到"可达集最远点"（部分导航）。
			// 迷宫/孤岛图玩家至少被引导穿过整个可达组件，走到最深处自己推进
			delete bridge;
			bridge = new ArrayList();
			next = BfsBridge(cur, curFlow, goalArea, startZ, bridge, true);
		}
		if (next != Address_Null && bridge.Length > 0)
		{
			for (int bi = bridge.Length - 1; bi >= 0; bi--)
				path.Push(bridge.Get(bi));   // bridge 是 目标→起点 反序，反转 push
			cur = next;
			curFlow = L4D2Direct_GetTerrorNavAreaFlow(cur);
			bridges++;
		}
		delete bridge;
		break;   // BFS 已补完全程（goal 直达 / flow 最大 / 最远可达）——循环结束
	}

	endArea = cur;
	endFlow = curFlow;
	int startNb = -1;
	if (g_bNavTableReady)
	{
		int sIdx = AreaToIndex(start);
		if (sIdx >= 0)
			startNb = view_as<ArrayList>(g_hNeighborIdx.Get(sIdx)).Length;
	}
	// 异常态（len<=3 断链）每次打；正常态 10s 限频（避免每秒 3 条刷屏）
	if (path.Length <= 3 || GetEngineTime() - g_fLastPathDiag > 10.0)
	{
		LogMessage("[PTG] path len=%d bridges=%d guard=%d startNb=%d", path.Length, bridges, guard, startNb);
		g_fLastPathDiag = GetEngineTime();
	}
	delete adj;
	return path;
}

// ────────────────────────── BFS 桥接 ──────────────────────────
// 根治版：gradient 卡住时一次 BFS 全图扩展（深限 = 全节点数，无硬性
// 2000 上限——图多大走多大）。目标优先级：① goalArea（出口实体直达）
// ② flow 最大可达节点（同层优先，跨层需显著更优防爬楼）
// ③ fallback 模式：可达集欧氏最远点。返回目标 area；bridgeOut 收集
// "目标→起点"反序路径（调用方反转 push）。每次路径计算最多调用 1 次
//（主循环 BFS 后即 break）——成本与图大小线性，不再碎步。

Address BfsBridge(Address start, float startFlow, Address goalArea, float startZ, ArrayList bridgeOut, bool fallbackMode)
{
	// 预构建表未就绪时退化为旧逻辑（防御）
	if (!g_bNavTableReady)
		return Address_Null;

	int n = g_hAreaList.Length;
	int startIdx = AreaToIndex(start);
	if (startIdx < 0)
		return Address_Null;

	// visited/parent 用 int 数组（index 直接寻址，零哈希）
	ArrayList visited = new ArrayList();
	ArrayList parent = new ArrayList();
	for (int i = 0; i < n; i++)
	{
		visited.Push(0);
		parent.Push(-1);
	}
	visited.Set(startIdx, 1);

	int goalIdx = -1;
	if (goalArea != Address_Null)
		goalIdx = AreaToIndex(goalArea);

	float startX = g_hCenterX.Get(startIdx);
	float startY = g_hCenterY.Get(startIdx);

	// 目标候选：goal 命中；flow 最大可达（同层优先）；fallback 欧氏最远
	int foundGoal = -1;
	int bestFlowIdx = -1;
	float bestFlowV = -1.0;
	int farthestIdx = -1;
	float farthestD = -1.0;

	ArrayList queue = new ArrayList();
	queue.Push(startIdx);

	int head = 0;
	while (head < queue.Length)   // 全图扩展一次（深限 = 节点数，天然有界）
	{
		int curIdx = queue.Get(head);
		head++;

		// fallback 模式：记录离起点欧氏最远的可达 area
		if (fallbackMode)
		{
			float dx = g_hCenterX.Get(curIdx) - startX;
			float dy = g_hCenterY.Get(curIdx) - startY;
			float d = dx * dx + dy * dy;
			if (d > farthestD)
			{
				farthestD = d;
				farthestIdx = curIdx;
			}
		}

		ArrayList nb = g_hNeighborIdx.Get(curIdx);
		for (int j = 0; j < nb.Length; j++)
		{
			int nIdx = nb.Get(j);
			if (visited.Get(nIdx))
				continue;
			visited.Set(nIdx, 1);
			parent.Set(nIdx, curIdx);

			if (nIdx == goalIdx)
			{
				foundGoal = nIdx;
				break;
			}

			// flow 最大候选：同层（±150u）直接竞争；跨层需显著更优
			//（防被楼上 flow 孤岛带走——死亡厕所迷宫 z=384 教训）
			float f = g_hFlowValues.Get(nIdx);
			if (f >= 0.0)
			{
				if (FloatAbs(g_hCenterZ.Get(nIdx) - startZ) <= 150.0)
				{
					if (f > bestFlowV)
					{
						bestFlowV = f;
						bestFlowIdx = nIdx;
					}
				}
				else if (f > bestFlowV + 500.0)
				{
					bestFlowV = f;
					bestFlowIdx = nIdx;
				}
			}
			queue.Push(nIdx);
		}
		if (foundGoal != -1)
			break;
	}

	// 目标选择：goal → fallback 最远 → flow 最大
	int target = -1;
	if (foundGoal != -1)
		target = foundGoal;
	else if (fallbackMode && farthestIdx != -1 && farthestIdx != startIdx)
		target = farthestIdx;
	else if (bestFlowIdx != -1)
		target = bestFlowIdx;

	if (target != -1)
	{
		// 回溯：目标 → 起点，存入 bridgeOut（areaInt，调用方反转 push）
		int node = target;
		int guard = 0;
		while (node != startIdx && guard <= n)
		{
			guard++;
			bridgeOut.Push(g_hAreaList.Get(node));
			int p = parent.Get(node);
			if (p < 0) break;
			node = p;
		}
	}

	delete queue;
	delete visited;
	delete parent;
	if (target == -1)
		return Address_Null;
	return view_as<Address>(g_hAreaList.Get(target));
}

// ────────────────────────── 共享边中点 ──────────────────────────
// 两 4 向相邻 area 的共享边中点：用 center+size 包围盒推算
// （left4dhooks 无 corner API；不改内存偏移，PTG 时代 Prop_Data 教训）

bool SharedEdgeMidpoint(Address a, Address b, float mid[3])
{
	float ca[3], sa[3], cb[3], sb[3];
	L4D_GetNavAreaCenter(a, ca);
	L4D_GetNavAreaSize(a, sa);
	L4D_GetNavAreaCenter(b, cb);
	L4D_GetNavAreaSize(b, sb);

	// A、B 包围盒
	float minAx = ca[0] - sa[0] * 0.5, maxAx = ca[0] + sa[0] * 0.5;
	float minAy = ca[1] - sa[1] * 0.5, maxAy = ca[1] + sa[1] * 0.5;
	float minBx = cb[0] - sb[0] * 0.5, maxBx = cb[0] + sb[0] * 0.5;
	float minBy = cb[1] - sb[1] * 0.5, maxBy = cb[1] + sb[1] * 0.5;

	float dx = cb[0] - ca[0];
	float dy = cb[1] - ca[1];
	float lo, hi;

	if (FloatAbs(dx) >= FloatAbs(dy))
	{
		// 水平相邻：共享边竖直，x = A 朝向 B 的侧边，y = 两盒交集中心
		mid[0] = ca[0] + (dx > 0.0 ? sa[0] * 0.5 : -sa[0] * 0.5);
		lo = (minAy > minBy) ? minAy : minBy;
		hi = (maxAy < maxBy) ? maxAy : maxBy;
		if (lo > hi)
			return false;
		mid[1] = (lo + hi) * 0.5;
	}
	else
	{
		// 垂直相邻：共享边水平，y = A 朝向 B 的侧边，x = 两盒交集中心
		mid[1] = ca[1] + (dy > 0.0 ? sa[1] * 0.5 : -sa[1] * 0.5);
		lo = (minAx > minBx) ? minAx : minBx;
		hi = (maxAx < maxBx) ? maxAx : maxBx;
		if (lo > hi)
			return false;
		mid[0] = (lo + hi) * 0.5;
	}

	mid[2] = (ca[2] + cb[2]) * 0.5;
	return true;
}

// ────────────────────────── LOS（世界几何，实体放行） ──────────────────────────
// 可推开/可撞碎/会动的实体不算墙 — 画线是引导不是碰撞体积

bool LosClear(const float p1[3], const float p2[3])
{
	TR_TraceRayFilter(p1, p2, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
	return !TR_DidHit();
}

public bool TraceFilterWorldOnly(int entity, int contentsMask, any data)
{
	return false;   // 忽略所有实体
}
