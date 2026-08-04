// [TEST] Flow gradient descent path — 实验插件（验证用，非正式）
// 验证核心假设：
//   1. 引擎 flow 场（L4D2Direct_GetTerrorNavAreaFlow）梯度下降能否从任意点走到出口/救援车
//   2. 4 向平面邻接是否是人类可走的连接集
//   3. 无 nav / 断裂 nav 图的行为（安静降级 or 断链 beacon）
//
// 命令：
//   sm_flowtest         — 从执行者位置梯度下降，画线 + 输出路径数据
//   sm_flowtest x y z   — 从指定坐标梯度下降
//   sm_flowtest_map     — 全图统计：flow 覆盖、连通组件、救援车标记（验证大图断裂程度）

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION "0.1"

#define TEAM_SURVIVOR 2
#define VMT_LASER "sprites/laserbeam.vmt"
#define MAX_STEPS 2000
#define FLOW_INVALID -1.0

int g_iLaser;
bool g_bIsL4D2;

public Plugin myinfo =
{
    name = "[TEST] Flow Gradient Descent Path",
    author = "server",
    description = "验证 flow 梯度下降寻路方案（实验）",
    version = PLUGIN_VERSION,
    url = ""
};

public void OnPluginStart()
{
    g_bIsL4D2 = (GetEngineVersion() == Engine_Left4Dead2);
    RegAdminCmd("sm_flowtest", Cmd_FlowTest, ADMFLAG_ROOT, "sm_flowtest [x y z] — 从玩家位置/坐标梯度下降到出口");
    RegAdminCmd("sm_flowtest_map", Cmd_FlowMap, ADMFLAG_ROOT, "全图 flow/连通组件统计");
    RegAdminCmd("sm_flowtest_all", Cmd_FlowAll, ADMFLAG_ROOT, "全图逐 area 梯度下降可达性统计");
    RegAdminCmd("sm_flowtest_full", Cmd_FlowFull, ADMFLAG_ROOT, "4向组件 + 可跳LOS边合并 → 全连接视角连通性");
    RegAdminCmd("sm_flowtest_ents", Cmd_FlowEnts, ADMFLAG_ROOT, "遍历地图实体：可炸墙/门/按钮/触发器分类统计 + 位置");
}

char g_sMapName[128];

public void OnMapStart()
{
    GetCurrentMap(g_sMapName, sizeof(g_sMapName));
    g_iLaser = PrecacheModel(VMT_LASER, true);
    if (g_iLaser == 0) g_iLaser = PrecacheModel("sprites/white.vmt", true);
}

// ────────────────────────── sm_flowtest ──────────────────────────

Action Cmd_FlowTest(int client, int args)
{
    if (!g_bIsL4D2)
    {
        ReplyToCommand(client, "[FLOW] L4D2 only");
        return Plugin_Handled;
    }
    float pos[3];
    if (args >= 3)
    {
        char buf[32];
        GetCmdArg(1, buf, sizeof(buf)); pos[0] = StringToFloat(buf);
        GetCmdArg(2, buf, sizeof(buf)); pos[1] = StringToFloat(buf);
        GetCmdArg(3, buf, sizeof(buf)); pos[2] = StringToFloat(buf);
        LogMessage("[FLOW] 手动坐标: args=%d pos=(%.1f %.1f %.1f)", args, pos[0], pos[1], pos[2]);
    }
    else if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client))
    {
        GetClientAbsOrigin(client, pos);
    }
    else
    {
        // 无活玩家（RCON 测试）: 从 PLAYER_START 出生点 area 出发
        Address ps = FindPlayerStartArea();
        if (ps == Address_Null)
        {
            ReplyToCommand(client, "[FLOW] 无活玩家且找不到出生点 area — 请提供坐标 sm_flowtest x y z");
            return Plugin_Handled;
        }
        L4D_GetNavAreaCenter(ps, pos);
        LogMessage("[FLOW] RCON 测试: 从 PLAYER_START area=%d pos=(%.0f %.0f %.0f) 出发", view_as<int>(ps), pos[0], pos[1], pos[2]);
    }

    RunGradientDescent(client, pos);
    return Plugin_Handled;
}

void RunGradientDescent(int client, float pos[3])
{
    float t0 = GetEngineTime();

    Address start = L4D_GetNearestNavArea(pos, 500.0, true, true, false, TEAM_SURVIVOR);
    if (start == Address_Null)
    {
        // 诊断：参数变体 + 地图状态
        char map[64];
        GetCurrentMap(map, sizeof(map));
        Address v1 = L4D_GetNearestNavArea(pos, 2000.0, true, false, false, TEAM_SURVIVOR);
        Address v2 = L4D_GetNearestNavArea(pos, 500.0, true, false, false, TEAM_SURVIVOR);
        Address v3 = L4D_GetNearestNavArea(pos, 500.0, false, false, false, TEAM_SURVIVOR);
        ArrayList all2 = new ArrayList();
        L4D_GetAllNavAreas(all2);
        ReplyToCommand(client, "[FLOW] 起点无 nav area  map=%s  areas=%d  变体: 2000u/anyZ/LOSoff=%s  500u/anyZ=%s  500u/strictZ=%s",
            map, all2.Length,
            v1 != Address_Null ? "YES" : "no",
            v2 != Address_Null ? "YES" : "no",
            v3 != Address_Null ? "YES" : "no");
        LogMessage("[FLOW] 起点无 nav area  map=%s  areas=%d  v1(2000u anyZ LOSoff)=%d v2(500u anyZ)=%d v3(500u strictZ)=%d",
            map, all2.Length, view_as<int>(v1), view_as<int>(v2), view_as<int>(v3));
        delete all2;
        return;
    }

    // 全图扫描：flow 有效范围 + 救援车目标
    float fMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);

    Address goalVehicle = Address_Null;
    int flowValid = 0;
    for (int i = 0; i < all.Length; i++)
    {
        Address a = view_as<Address>(all.Get(i));
        float f = L4D2Direct_GetTerrorNavAreaFlow(a);
        if (f >= 0.0) flowValid++;
        if (L4D_GetNavArea_SpawnAttributes(a) & NAV_SPAWN_RESCUE_VEHICLE)
            goalVehicle = a;
    }
    ReplyToCommand(client, "[FLOW] map: %s  total_areas=%d  flow_valid=%d (%.0f%%)  map_max_flow=%.0f  rescue_vehicle=%s",
        g_sMapName, all.Length, flowValid,
        all.Length > 0 ? 100.0 * flowValid / all.Length : 0.0,
        fMaxFlow,
        goalVehicle != Address_Null ? "YES" : "no (非 finale 图预期)");
    delete all;

    // ── 梯度下降：沿 4 向邻接中 flow 严格递增的方向走（引擎 flow = 从起点弧长，递增=朝出口）──
    float fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (fMapMaxFlow <= 0.0) fMapMaxFlow = 999999.0; // 引擎 max 不可用则按未知处理

    ArrayList path = new ArrayList();   // area int
    Address cur = start;
    float curFlow = L4D2Direct_GetTerrorNavAreaFlow(cur);
    int guard = 0;
    ArrayList adj = new ArrayList();

    while (curFlow >= 0.0 && guard < MAX_STEPS)
    {
        guard++;
        path.Push(view_as<int>(cur));

        Address best = Address_Null;
        float bestFlow = curFlow;
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

        if (best == Address_Null) break;   // 局部极大：出口 or 断链
        cur = best;
        curFlow = bestFlow;
    }
    delete adj;

    float t1 = GetEngineTime();

    // ── 结果分析 ──
    float endCenter[3];
    L4D_GetNavAreaCenter(cur, endCenter);
    int endAttrs = L4D_GetNavArea_SpawnAttributes(cur);

    char verdict[128];
    if (curFlow < 0.0)
        strcopy(verdict, sizeof(verdict), "flow 无效(负值) — 引擎 flow 场未覆盖");
    else if (endAttrs & NAV_SPAWN_RESCUE_VEHICLE)
        strcopy(verdict, sizeof(verdict), "到达 RESCUE_VEHICLE (成功终点)");
    else if (fMapMaxFlow < 999999.0 && curFlow >= fMapMaxFlow * 0.95)
        strcopy(verdict, sizeof(verdict), "到达出口 (flow 接近地图最大值)");
    else
    {
        Format(verdict, sizeof(verdict),
            "flow 极大 %.0f 未达 max %.0f — 死路分支/断裂组件/机关阻挡 (需 beacon 降级)", curFlow, fMapMaxFlow);
    }

    ReplyToCommand(client, "[FLOW] start_area=%d  steps=%d  end_area=%d  end_flow=%.0f  end=(%.0f %.0f %.0f)  attrs=%d",
        view_as<int>(start), path.Length, view_as<int>(cur), curFlow,
        endCenter[0], endCenter[1], endCenter[2], endAttrs);
    ReplyToCommand(client, "[FLOW] 判定: %s", verdict);
    LogMessage("[FLOW] map=%s start=%d steps=%d end=%d flow=%.0f end=(%.0f %.0f %.0f) attrs=%d verdict=%s time=%.1fms",
        g_sMapName, view_as<int>(start), path.Length, view_as<int>(cur), curFlow,
        endCenter[0], endCenter[1], endCenter[2], endAttrs, verdict, (t1 - t0) * 1000.0);

    // ── 路径质量统计: 每段 LOS trace（只查世界几何, 实体全部放行）──
    int losTotal = 0;
    int losFail = 0;
    for (int i = 0; i < path.Length - 1; i++)
    {
        float p1[3], p2[3];
        L4D_GetNavAreaCenter(view_as<Address>(path.Get(i)), p1);
        L4D_GetNavAreaCenter(view_as<Address>(path.Get(i + 1)), p2);
        p1[2] += 30.0;
        p2[2] += 30.0;
        losTotal++;
        if (!LosClear(p1, p2)) losFail++;
    }
    float losPct = 100.0 * float(losFail) / float(losTotal);
    ReplyToCommand(client, "[FLOW] LOS: %d/%d 段 blocked (%.1f%%)", losFail, losTotal, losPct);
    LogMessage("[FLOW] LOS: %d/%d blocked (%.1f%%)", losFail, losTotal, losPct);

    // ── 画线：绿色 trail（blocked 段红色）+ 终点 beacon ──
    if (g_iLaser != 0 && path.Length >= 2)
    {
        int color[4] = {0, 255, 100, 200};
        int colorBad[4] = {255, 60, 0, 220};
        bool reachedEnd = (endAttrs & NAV_SPAWN_RESCUE_VEHICLE)
            || (fMapMaxFlow < 999999.0 && curFlow >= fMapMaxFlow * 0.95);
        for (int i = 0; i < path.Length - 1; i++)
        {
            float p1[3], p2[3];
            L4D_GetNavAreaCenter(view_as<Address>(path.Get(i)), p1);
            L4D_GetNavAreaCenter(view_as<Address>(path.Get(i + 1)), p2);
            p1[2] += 30.0;
            p2[2] += 30.0;
            bool bad = !LosClear(p1, p2);
            TE_SetupBeamPoints(p1, p2, g_iLaser, 0, 0, 0, 10.0, 0.5, 2.0, 0, 0.0, bad ? colorBad : color, 0);
            if (client > 0 && IsClientInGame(client)) TE_SendToClient(client);
            else TE_SendToAll();
        }
        // 终点 beacon 竖线
        float top[3];
        top = endCenter;
        top[2] += 200.0;
        TE_SetupBeamPoints(endCenter, top, g_iLaser, 0, 0, 0, 10.0, 1.0, 4.0, 0, 0.0, reachedEnd ? color : colorBad, 0);
        if (client > 0 && IsClientInGame(client)) TE_SendToClient(client);
        else TE_SendToAll();
    }

    delete path;
}

// ────────────────────────── sm_flowtest_full ──────────────────────────
// 验证"全连接视角"连通性：4 向组件 + 可跳墙 LOS 边（矮墙=可跳）合并。
// 回答: 迷宫图 nav 的 25+ 个 4 向孤岛，在"可跳/可爬"视角下是否连通？
// 附带: 玩家出生点（PLAYER_START）最近 nav area 的距离（逐级放大搜索）。

Action Cmd_FlowFull(int client, int args)
{
    float t0 = GetEngineTime();
    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);

    // ── 1. 4 向组件（含组件代表 area）──
    StringMap comp = new StringMap();       // area → cid
    ArrayList compRepr = new ArrayList();   // 组件代表 area
    ArrayList compSize = new ArrayList();

    char key[16];
    for (int i = 0; i < all.Length; i++)
    {
        IntToString(all.Get(i), key, sizeof(key));
        if (comp.ContainsKey(key)) continue;

        int cid = compSize.Length;
        compSize.Push(0);
        compRepr.Push(all.Get(i));

        ArrayList queue = new ArrayList();
        queue.Push(all.Get(i));
        comp.SetValue(key, cid);
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
                    if (!comp.ContainsKey(key))
                    {
                        comp.SetValue(key, cid);
                        queue.Push(aInt);
                    }
                }
            }
            delete adj;
        }
        delete queue;
    }
    int compCount = compSize.Length;

    // ── 2. 组件间通道边检测（全量跨组件 area 对，空间预筛）──
    // v3: 代表 area 抽样会漏掉"通道在非代表 area 之间"的情况。
    //     全量：128u 网格分桶，同桶/邻桶内跨组件 area 对 → 距离<400u + 高度差<90u
    //     + 地面视线(+30u，实体放行=门也算通) → 可通边 → 并查集合并。
    ArrayList ufParent = new ArrayList();
    for (int i = 0; i < compCount; i++) ufParent.Push(i);
    int jumpEdges = 0;
    int losTests = 0;

    // 建立 128u 网格桶：key "gx_gy" → ArrayList(area int)
    StringMap grid = new StringMap();
    float center[3];
    for (int i = 0; i < all.Length; i++)
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

    // 遍历每桶，与自身 + 8 邻桶的 area 配对（i<j，跨组件才测）
    StringMapSnapshot snap = grid.Snapshot();
    for (int bi = 0; bi < snap.Length; bi++)
    {
        char gkey[64];
        snap.GetKey(bi, gkey, sizeof(gkey));
        ArrayList bucketA;
        if (!grid.GetValue(gkey, bucketA)) continue;

        // 自身桶 + 邻桶（x±1, y±1）
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
                        char ka[16], kb[16];
                        IntToString(aInt, ka, sizeof(ka));
                        IntToString(bInt, kb, sizeof(kb));
                        int cida, cidb;
                        if (!comp.GetValue(ka, cida) || !comp.GetValue(kb, cidb)) continue;
                        if (cida == cidb) continue;   // 同组件内部跳过

                        float pa[3], pb[3];
                        L4D_GetNavAreaCenter(view_as<Address>(aInt), pa);
                        L4D_GetNavAreaCenter(view_as<Address>(bInt), pb);
                        if (GetVectorDistance(pa, pb, false) > 400.0) continue;
                        if (FloatAbs(pa[2] - pb[2]) > 90.0) continue;

                        losTests++;
                        float ta[3], tb[3];
                        ta = pa; ta[2] += 30.0;
                        tb = pb; tb[2] += 30.0;
                        TR_TraceRayFilter(ta, tb, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
                        if (TR_DidHit()) continue;

                        jumpEdges++;
                        int ri = UfFind(ufParent, cida);
                        int rj = UfFind(ufParent, cidb);
                        if (ri != rj) ufParent.Set(rj, ri);
                    }
                }
            }
        }
    }
    delete snap;

    // ── 3. 合并统计 ──
    int mergedCount = 0;
    ArrayList mergedSize = new ArrayList();  // 按根 id 累计
    for (int i = 0; i < compCount; i++) mergedSize.Push(0);
    for (int i = 0; i < compCount; i++)
    {
        int r = UfFind(ufParent, i);
        mergedSize.Set(r, mergedSize.Get(r) + compSize.Get(i));
    }
    for (int i = 0; i < compCount; i++)
        if (mergedSize.Get(i) > 0) mergedCount++;

    // 最大合并组件
    int biggest = 0;
    for (int i = 0; i < compCount; i++)
        if (mergedSize.Get(i) > biggest) biggest = mergedSize.Get(i);

    // ── 4. 出生点最近 area 距离（逐级放大）──
    float spawn[3];
    Address ps = FindPlayerStartArea();
    float spawnDist = -1.0;
    if (ps != Address_Null)
    {
        L4D_GetNavAreaCenter(ps, spawn);
        for (int range = 500; range <= 4000 && spawnDist < 0.0; range *= 2)
        {
            Address near = L4D_GetNearestNavArea(spawn, float(range), true, false, false, TEAM_SURVIVOR);
            if (near != Address_Null)
                spawnDist = float(range);
        }
    }

    float t1 = GetEngineTime();
    ReplyToCommand(client, "[FULL] map=%s areas=%d comp4=%d passEdges=%d losTests=%d mergedComp=%d biggest=%d (%.1fms)",
        g_sMapName, all.Length, compCount, jumpEdges, losTests, mergedCount, biggest, (t1 - t0) * 1000.0);
    LogMessage("[FULL] map=%s areas=%d comp4=%d passEdges=%d losTests=%d mergedComp=%d biggest=%d time=%.1fms",
        g_sMapName, all.Length, compCount, jumpEdges, losTests, mergedCount, biggest, (t1 - t0) * 1000.0);
    if (ps != Address_Null)
    {
        ReplyToCommand(client, "[FULL] 出生点=(%.0f %.0f %.0f) 最近area距离≈%.0f", spawn[0], spawn[1], spawn[2], spawnDist);
        LogMessage("[FULL] spawn=(%.0f %.0f %.0f) nearestDist=%.0f", spawn[0], spawn[1], spawn[2], spawnDist);
    }

    // 清理网格桶
    StringMapSnapshot snap2 = grid.Snapshot();
    for (int i = 0; i < snap2.Length; i++)
    {
        char gkey[64];
        snap2.GetKey(i, gkey, sizeof(gkey));
        ArrayList bucket;
        if (grid.GetValue(gkey, bucket)) delete bucket;
    }
    delete snap2;
    delete grid;
    delete ufParent;
    delete mergedSize;
    delete compSize;
    delete compRepr;
    delete comp;
    delete all;
    return Plugin_Handled;
}

int UfFind(ArrayList parent, int x)
{
    int p = parent.Get(x);
    if (p != x)
    {
        int root = UfFind(parent, p);
        parent.Set(x, root);
    }
    return parent.Get(x);
}

// ────────────────────────── sm_flowtest_ents ──────────────────────────
// 遍历地图实体：可炸墙(func_breakable)/门(prop_door_rotating, func_door)/
// 按钮(func_button, func_useable)/触发器(trigger_*) 分类统计 + 抽样位置。
// 验证假设：孤岛间的真实连接（炸墙/门）是否存在实体表里 → 可做"实体桥"。

Action Cmd_FlowEnts(int client, int args)
{
    // classname → 计数
    StringMap counts = new StringMap();
    // 关键实体位置抽样（前 10 个）
    ArrayList samplePos = new ArrayList();
    ArrayList sampleCls = new ArrayList();

    // 遍历：先收集"有趣的" classname 列表
    char classes[][][] = {
        { "func_breakable", "可炸墙" },
        { "prop_door_rotating", "旋转门" },
        { "func_door", "滑门" },
        { "func_door_rotating", "旋转门(旧)" },
        { "func_button", "按钮" },
        { "func_useable", "可用物" },
        { "trigger_multiple", "触发器" },
        { "trigger_once", "一次性触发器" },
        { "trigger_changelevel", "切图触发器" },
        { "script_changelevel", "脚本切图" },
        { "trigger_finale", "终局触发器" },
        { "func_breakable_doors", "可破门" },
        { "prop_dynamic", "动态物" },
        { "script_trigger_once", "脚本触发器" }
    };

    for (int ci = 0; ci < sizeof(classes); ci++)
    {
        int count = 0;
        int ent = -1;
        float pos[3];
        while ((ent = FindEntityByClassname(ent, classes[ci][0])) != -1)
        {
            count++;
            if (samplePos.Length < 10)
            {
                GetEntPropVector(ent, Prop_Send, "m_vecOrigin", pos);
                samplePos.PushArray(pos);
                char buf[64];
                Format(buf, sizeof(buf), "%s(#%d)", classes[ci][1], ent);
                sampleCls.PushString(buf);
            }
        }
        counts.SetValue(classes[ci][0], count);
    }

    // 输出
    ReplyToCommand(client, "[ENTS] map=%s", g_sMapName);
    LogMessage("[ENTS] map=%s", g_sMapName);
    for (int ci = 0; ci < sizeof(classes); ci++)
    {
        int count = 0;
        counts.GetValue(classes[ci][0], count);
        ReplyToCommand(client, "[ENTS]   %-24s %s: %d", classes[ci][0], classes[ci][1], count);
        LogMessage("[ENTS]   %s: %d", classes[ci][0], count);
    }
    for (int i = 0; i < samplePos.Length; i++)
    {
        float p[3];
        samplePos.GetArray(i, p);
        char buf[64];
        sampleCls.GetString(i, buf, sizeof(buf));
        ReplyToCommand(client, "[ENTS]   %s @ (%.0f %.0f %.0f)", buf, p[0], p[1], p[2]);
        LogMessage("[ENTS]   %s @ (%.0f %.0f %.0f)", buf, p[0], p[1], p[2]);
    }

    delete sampleCls;
    delete samplePos;
    delete counts;
    return Plugin_Handled;
}

// 找一个 PLAYER_START 标记的 area（出生点）
Address FindPlayerStartArea()
{
    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);
    Address found = Address_Null;
    for (int i = 0; i < all.Length; i++)
    {
        Address a = view_as<Address>(all.Get(i));
        if (L4D_GetNavArea_SpawnAttributes(a) & NAV_SPAWN_PLAYER_START)
        {
            found = a;
            break;
        }
    }
    delete all;
    return found;
}

// 世界几何 LOS 检查（实体全部放行——可推/可碎/会动的不算墙）
bool LosClear(const float p1[3], const float p2[3])
{
    TR_TraceRayFilter(p1, p2, MASK_SOLID, RayType_EndPoint, TraceFilterWorldOnly);
    return !TR_DidHit();
}

public bool TraceFilterWorldOnly(int entity, int contentsMask, any data)
{
    return false;   // 忽略所有实体
}

// ────────────────────────── sm_flowtest_all ──────────────────────────
// 全图每个 area 跑一次梯度下降，统计: 多少 % 能走到 flow<=1（出口根区）
// 直接量化"4向梯度下降方案"在整张图上的成功率 + 断链分布

Action Cmd_FlowAll(int client, int args)
{
    if (!g_bIsL4D2)
    {
        ReplyToCommand(client, "[FLOW] L4D2 only");
        return Plugin_Handled;
    }

    float t0 = GetEngineTime();
    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);

    float fMapMaxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (fMapMaxFlow <= 0.0) fMapMaxFlow = 999999.0;

    int total = all.Length;
    int reached = 0;
    int broke = 0;
    int noFlow = 0;
    int bridgeOK = 0;   // 无flow area 经 BFS 桥接到有 flow 区
    int bridgeFail = 0;
    int bridgeDepthSum = 0;

    ArrayList adj = new ArrayList();
    for (int i = 0; i < total; i++)
    {
        Address cur = view_as<Address>(all.Get(i));
        float curFlow = L4D2Direct_GetTerrorNavAreaFlow(cur);
        if (curFlow < 0.0)
        {
            noFlow++;
            // ── 轻量桥: 4向 BFS 找最近有 flow 的 area（深度上限 60）──
            int depth = BfsToFlowArea(cur, adj);
            if (depth > 0)
            {
                bridgeOK++;
                bridgeDepthSum += depth;
            }
            else
            {
                bridgeFail++;
                if (bridgeFail <= 6)   // 输出前 6 个失败点坐标
                {
                    float c[3];
                    L4D_GetNavAreaCenter(cur, c);
                    LogMessage("[FLOW-ALL] bridgeFail area=%d pos=(%.0f %.0f %.0f)", view_as<int>(cur), c[0], c[1], c[2]);
                }
            }
            continue;
        }
        int endAttrs = L4D_GetNavArea_SpawnAttributes(cur);
        if ((endAttrs & NAV_SPAWN_RESCUE_VEHICLE) || (fMapMaxFlow < 999999.0 && curFlow >= fMapMaxFlow * 0.95))
        {
            reached++;
            continue;
        }

        // 梯度上升（单步内联，无路径收集）
        int guard = 0;
        bool success = false;
        while (curFlow >= 0.0 && guard < MAX_STEPS)
        {
            guard++;
            Address best = Address_Null;
            float bestFlow = curFlow;
            for (int dir = 0; dir < 4; dir++)
            {
                adj.Clear();
                L4D_NavArea_GetAdjacentAreas(cur, dir, adj);
                for (int j = 0; j < adj.Length; j++)
                {
                    float f = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(adj.Get(j)));
                    if (f >= 0.0 && f > bestFlow)
                    {
                        bestFlow = f;
                        best = view_as<Address>(adj.Get(j));
                    }
                }
            }
            if (best == Address_Null) break;
            endAttrs = L4D_GetNavArea_SpawnAttributes(best);
            if ((endAttrs & NAV_SPAWN_RESCUE_VEHICLE) || (fMapMaxFlow < 999999.0 && bestFlow >= fMapMaxFlow * 0.95))
            {
                success = true;
                break;
            }
            cur = best;
            curFlow = bestFlow;
        }
        if (success) reached++;
        else broke++;
    }
    delete adj;
    delete all;

    float t1 = GetEngineTime();
    float reachPct = 100.0 * reached / total;
    int totalOK = reached + bridgeOK;
    float totalPct = 100.0 * float(totalOK) / total;
    float avgBridge = bridgeOK > 0 ? float(bridgeDepthSum) / float(bridgeOK) : 0.0;
    ReplyToCommand(client, "[FLOW-ALL] map=%s  areas=%d  4向梯度可达=%d (%.1f%%)  无flow桥接=%d (%.1f%%)  桥失败=%d  最终覆盖=%d (%.1f%%)  桥深=%.0f  耗时=%.0fms",
        g_sMapName, total, reached, reachPct, bridgeOK, 100.0 * float(bridgeOK) / total,
        bridgeFail, totalOK, totalPct, avgBridge, (t1 - t0) * 1000.0);
    LogMessage("[FLOW-ALL] map=%s areas=%d reached=%d (%.1f%%) bridgeOK=%d bridgeFail=%d total=%d (%.1f%%) avgBridge=%.0f time=%.0fms",
        g_sMapName, total, reached, reachPct, bridgeOK, bridgeFail, totalOK, totalPct, avgBridge, (t1 - t0) * 1000.0);
    return Plugin_Handled;
}

// 4向 BFS：从 startArea 找最近的有 flow area（flow>=0），返回步数；找不到返回 0
// 复用调用方的 adj 缓冲区。visited 用 StringMap。
int BfsToFlowArea(Address startArea, ArrayList adjBuf)
{
    ArrayList queue = new ArrayList();
    StringMap visited = new StringMap();
    ArrayList depthMap = new ArrayList();  // 每个入队 area 的深度

    queue.Push(view_as<int>(startArea));
    depthMap.Push(0);
    char key[16];
    IntToString(view_as<int>(startArea), key, sizeof(key));
    visited.SetValue(key, 1);

    int head = 0;
    int found = -1;
    while (head < queue.Length && head < 2000)
    {
        int areaInt = queue.Get(head);
        int depth = depthMap.Get(head);
        head++;
        if (depth >= 60) break;

        adjBuf.Clear();
        for (int dir = 0; dir < 4; dir++)
        {
            L4D_NavArea_GetAdjacentAreas(view_as<Address>(areaInt), dir, adjBuf);
            for (int j = 0; j < adjBuf.Length; j++)
            {
                int aInt = adjBuf.Get(j);
                IntToString(aInt, key, sizeof(key));
                if (visited.ContainsKey(key)) continue;
                visited.SetValue(key, 1);

                if (L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(aInt)) >= 0.0)
                {
                    found = depth + 1;
                    break;
                }
                queue.Push(aInt);
                depthMap.Push(depth + 1);
            }
            if (found > 0) break;
        }
        if (found > 0) break;
    }

    delete queue;
    delete visited;
    delete depthMap;
    return found;
}

// ────────────────────────── sm_flowtest_map ──────────────────────────
// 全图统计：flow 覆盖 / 连通组件（4向邻接）/ 救援车位置
// 回答: 断裂 nav 三方图到底断成几块？每块多大？flow 场覆盖多少？

Action Cmd_FlowMap(int client, int args)
{
    if (!g_bIsL4D2)
    {
        ReplyToCommand(client, "[FLOW] L4D2 only");
        return Plugin_Handled;
    }

    float t0 = GetEngineTime();
    ArrayList all = new ArrayList();
    L4D_GetAllNavAreas(all);

    // area -> 组件 id
    StringMap comp = new StringMap();
    ArrayList compSize = new ArrayList();   // 每个组件的 area 数
    ArrayList compFlow0 = new ArrayList();  // 组件是否含 flow==0 根区
    ArrayList compRescue = new ArrayList(); // 组件是否含 RESCUE_VEHICLE
    ArrayList compFlowValid = new ArrayList(); // 组件内 flow>=0 的 area 数
    ArrayList compRepr = new ArrayList();   // 组件代表 area

    char key[16];
    for (int i = 0; i < all.Length; i++)
    {
        IntToString(all.Get(i), key, sizeof(key));
        if (comp.ContainsKey(key)) continue;

        // BFS 新组件
        int cid = compSize.Length;
        compSize.Push(0);
        compFlow0.Push(0);
        compRescue.Push(0);
        compFlowValid.Push(0);
        compRepr.Push(all.Get(i));

        ArrayList queue = new ArrayList();
        queue.Push(all.Get(i));
        comp.SetValue(key, cid);
        int head = 0;
        while (head < queue.Length)
        {
            int areaInt = queue.Get(head);
            head++;
            compSize.Set(cid, compSize.Get(cid) + 1);

            Address a = view_as<Address>(areaInt);
            float f = L4D2Direct_GetTerrorNavAreaFlow(a);
            if (f >= 0.0) compFlowValid.Set(cid, compFlowValid.Get(cid) + 1);
            if (f >= 0.0 && f <= 1.0) compFlow0.Set(cid, 1);
            if (L4D_GetNavArea_SpawnAttributes(a) & NAV_SPAWN_RESCUE_VEHICLE)
                compRescue.Set(cid, 1);

            ArrayList adj = new ArrayList();
            for (int dir = 0; dir < 4; dir++)
            {
                adj.Clear();
                L4D_NavArea_GetAdjacentAreas(a, dir, adj);
                for (int j = 0; j < adj.Length; j++)
                {
                    int aInt = adj.Get(j);
                    IntToString(aInt, key, sizeof(key));
                    if (!comp.ContainsKey(key))
                    {
                        comp.SetValue(key, cid);
                        queue.Push(aInt);
                    }
                }
            }
            delete adj;
        }
        delete queue;
    }

    // 输出组件统计（大组件优先）
    int compCount = compSize.Length;
    ArrayList order = new ArrayList();
    for (int i = 0; i < compCount; i++) order.Push(i);
    // 按大小降序（简单选择排序，compCount 通常 < 20）
    for (int i = 0; i < compCount; i++)
        for (int j = i + 1; j < compCount; j++)
            if (compSize.Get(order.Get(j)) > compSize.Get(order.Get(i)))
            {
                int tmp = order.Get(i);
                order.Set(i, order.Get(j));
                order.Set(j, tmp);
            }

    float t1 = GetEngineTime();
    ReplyToCommand(client, "[FLOW] map=%s areas=%d components=%d (%.1fms)", g_sMapName, all.Length, compCount, (t1 - t0) * 1000.0);
    LogMessage("[FLOW-MAP] map=%s areas=%d components=%d time=%.1fms", g_sMapName, all.Length, compCount, (t1 - t0) * 1000.0);

    int printed = 0;
    for (int i = 0; i < compCount && printed < 8; i++)
    {
        int cid = order.Get(i);
        int size = compSize.Get(cid);
        float pct = 100.0 * size / all.Length;
        float rep[3];
        L4D_GetNavAreaCenter(view_as<Address>(compRepr.Get(cid)), rep);
        ReplyToCommand(client, "[FLOW]   comp#%d: %d areas (%.1f%%)  flowOK=%d  flow0=%s  rescue=%s  repr=(%.0f %.0f %.0f)",
            cid, size, pct,
            compFlowValid.Get(cid),
            compFlow0.Get(cid) ? "YES" : "no",
            compRescue.Get(cid) ? "YES" : "no",
            rep[0], rep[1], rep[2]);
        LogMessage("[FLOW-MAP]   comp#%d: %d areas (%.1f%%) flowOK=%d flow0=%d rescue=%d repr=(%.0f %.0f %.0f)",
            cid, size, pct, compFlowValid.Get(cid), compFlow0.Get(cid), compRescue.Get(cid),
            rep[0], rep[1], rep[2]);
        printed++;
    }
    if (compCount > printed)
        ReplyToCommand(client, "[FLOW]   ... 其余 %d 个组件", compCount - printed);

    delete order;
    delete compSize;
    delete compFlow0;
    delete compRescue;
    delete compFlowValid;
    delete compRepr;
    delete comp;
    delete all;
    return Plugin_Handled;
}
