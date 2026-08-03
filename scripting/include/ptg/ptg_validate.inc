// PTG Module: ptg_validate — Hull trace validation, auto-repair, beacons
// Extracted from l4d_path_to_goal.inc (backup)

// Async hull trace state — shared between Guide_ValidateWalkable and its frame callback.
// Processing in batches of BATCH_SIZE per frame avoids main-thread stalls on
// maps with thousands of nav cells (fallback path can collect 5000+ cells).
#define VALIDATE_BATCH 30
int g_vi;          // current beam index
int g_vBlocked;    // blocked count
int g_vStair;      // passed via stair-lift
int g_vLow;        // passed via vent/crawl hull
int g_vSide;       // passed via side offset
int g_vSubdiv;     // passed via subdivision
int g_vVault;      // passed via vault/climb

int g_iValidateMapGen = -1; // map generation when validation started; abort if stale

void Guide_ValidateWalkable()
{
    delete g_bBeamWalkable;
    if (g_GuideCells == null || g_GuideCells.Length < 2) return;
    if (g_hCvarTraceHull == null || !g_hCvarTraceHull.BoolValue) return;

    g_bBeamWalkable = new ArrayList(1);
    g_vi = 0;
    g_vBlocked = g_vStair = g_vLow = g_vSide = g_vSubdiv = g_vVault = 0;
    g_iValidateMapGen = g_iMapGeneration;

    RequestFrame(Guide_ValidateWalkable_Frame, 0);
}

void Guide_ValidateWalkable_Frame(any unused)
{
    // Abort if map changed since validation started
    if (g_iValidateMapGen != g_iMapGeneration) return;
    if (g_GuideCells == null || g_vi >= g_GuideCells.Length - 1)
    {
        int total = (g_GuideCells != null) ? (g_GuideCells.Length - 1) : 0;
        if (total > 0)
        {
            LogMessage("[PTG] Hull validation: %d/%d walkable — vault:%d stair:%d low:%d side:%d subdiv:%d — blocked:%d",
                total - g_vBlocked, total, g_vVault, g_vStair, g_vLow, g_vSide, g_vSubdiv, g_vBlocked);

            // v4.6 FIX: blocked-edge feedback loop. Hull validation runs on
            // SNAPPED cell coordinates while A* searches in nav-center space —
            // search-space geometry checks (Theta*, geom penalty) cannot see
            // these walls, so only real validation can. Record every blocked
            // beam's nav-area pair and rebuild with those edges penalized.
            if (g_vBlocked > 0 && g_iGeomIter < GEOM_ITER_MAX)
            {
                if (g_hBlockedEdges == null) g_hBlockedEdges = new StringMap();
                for (int b = 0; b < g_bBeamWalkable.Length; b++)
                {
                    if (g_bBeamWalkable.Get(b) == 1) continue;
                    Cell bc1, bc2;
                    g_GuideCells.GetArray(b, bc1, sizeof(Cell));
                    g_GuideCells.GetArray(b + 1, bc2, sizeof(Cell));
                    if (bc1.navArea == Address_Null || bc2.navArea == Address_Null) continue;
                    char ekey[48];
                    Format(ekey, sizeof(ekey), "%d|%d", view_as<int>(bc1.navArea), view_as<int>(bc2.navArea));
                    g_hBlockedEdges.SetValue(ekey, 1);
                    Format(ekey, sizeof(ekey), "%d|%d", view_as<int>(bc2.navArea), view_as<int>(bc1.navArea));
                    g_hBlockedEdges.SetValue(ekey, 1);
                }

                // v4.8: few blocked beams → REPAIR in place, no rebuild. The
                // geometry-iteration rebuild existed so A* could re-plan around
                // the blocked edges, but on large maps it cost a full pipeline
                // re-run (~2-4s of budgeted frames) and the SAME walls blocked
                // the re-validated path again (they are physical). REPAIR's
                // Z-step/offset/subdivide/local-A*/beacon cascade fixes isolated
                // clippers in a few frames. Above the threshold the blocked
                // edges are penalized and a SOFT rebuild re-plans (A* node
                // index + portal cache are reused — v4.8).
                int totalBeams = g_GuideCells.Length - 1;
                if (totalBeams > 0 && g_vBlocked <= GEOM_ITER_REPAIR_ONLY_MAX
                    && g_vBlocked * 4 <= totalBeams)
                {
                    g_iGeomIter++; // consume the iteration budget
                    LogMessage("[PTG] Geometry: %d/%d blocked beams below repair threshold — REPAIR in place",
                        g_vBlocked, totalBeams);
                    if (g_hCvarRepairEnable != null && g_hCvarRepairEnable.BoolValue)
                        Guide_RepairBlocked();
                    else if (g_bGuideCellsBusy)
                    {
                        g_bGuideCellsBusy = false;
                        g_iPathGen++;
                        Guide_RedrawAllToggled();
                    }
                    return;
                }
                g_iGeomIter++;
                LogMessage("[PTG] Geometry iteration %d/%d: %d blocked beams recorded — soft rebuilding path",
                    g_iGeomIter, GEOM_ITER_MAX, g_vBlocked);
                // v4.8: soft rebuild — blocked edges penalize the re-run A*,
                // node index + portal cache are reused (cost ~1/4 of full).
                Guide_Prep(true);
                return;
            }

            // v4.0: Chain into STAGE_REPAIR after validation completes
            if (g_vBlocked > 0 && g_hCvarRepairEnable != null && g_hCvarRepairEnable.BoolValue)
            {
                Guide_RepairBlocked();
            }
            else if (g_bGuideCellsBusy)
            {
                // v4.7: validation clean (or repair off) — release the busy
                // gate coarse-first set and redraw the refined line. (With
                // blocked>0 + repair on, REPAIR's completion clears it.)
                g_bGuideCellsBusy = false;
                g_iPathGen++;
                Guide_RedrawAllToggled();
            }
        }
        return;
    }

    int count = g_GuideCells.Length;

    // Hull definitions
    float midMins[3] = {-14.0, -14.0, 0.0};
    float midMaxs[3] = { 14.0,  14.0, 44.0};
    float lowMins[3] = {-10.0, -10.0, 0.0};
    float lowMaxs[3] = { 10.0,  10.0, 32.0};

    for (int batch = 0; batch < VALIDATE_BATCH && g_vi < count - 1; batch++, g_vi++)
    {
        int i = g_vi;
        Cell cell1, cell2;
        g_GuideCells.GetArray(i, cell1, sizeof(Cell));
        g_GuideCells.GetArray(i + 1, cell2, sizeof(Cell));

        bool walkable = false;

        float baseStart[3], baseEnd[3];
        baseStart = cell1.center;
        baseEnd   = cell2.center;

        float dz = FloatAbs(cell2.center[2] - cell1.center[2]);
        float dist = GetVectorDistance(cell1.center, cell2.center, false);
        float distXY = GetVectorDistance(cell1.center, cell2.center, true);

        // v4.6.1: hard cap on un-verified vertical drops. dz>140 exceeds the
        // engine's DZ_TOO_LOW fall-damage threshold — the player cannot step
        // down that far, and a straight beam through the void reads as
        // "punching through the roof/floor" (c2m4 2026-08-01: barn→cellar
        // drops with dz≈190 drew beams through the slab; the floating
        // Funnel3D waypoints are fixed separately). Only real ladders and
        // elevators (nav LADDER / elevator connections) may exceed it.
        if (dz > 140.0 && !navArea_has_climb(cell1.navArea) && !navArea_has_climb(cell2.navArea))
        {
            g_bBeamWalkable.Push(0);
            g_vBlocked++;
            continue;
        }

        // Strategy 0: Ladder / elevator shaft — pure vertical passage
        // v4.7: ONLY near-vertical XY<40 stays legal (ladders, elevator
        // shafts). The v4.6 widen (dz>100 && XY<120 unconditional pass,
        // including drops) made every floor-to-roof nav connection "legal"
        // without checking the space between — beams punched through floor
        // slabs and A* routed paths up onto roofs and back down (loops +
        // vertical lines). Wider cross-level beams (including drops) fall
        // through to the standard hull strategies below and get beaconed
        // where no real passage (stairwell) exists.
        if (dz > 100.0 && distXY < 40.0)
        {
            g_bBeamWalkable.Push(1);
            continue;
        }

        // Strategy 0.5: Vault / climb — moderate-height obstacle to jump over
        // Two cells close horizontally but with a box/crate/ledge between them.
        // The player can vault: step up onto the higher cell, walk across, drop down.
        // v4.7 FIX: the old test only traced a horizontal line at the higher
        // cell's level — a cross-FLOOR connection (dz 30..100 between floors)
        // passed whenever the upper floor was open, and the drawn line then
        // punched through the floor slab. Verify the actual parabolic jump
        // trajectory (low → 60u apex → high, same as Strategy 8) so only real
        // vaults pass; the drawer renders the arc via jumpFlag.
        if (dz >= 30.0 && dz <= 100.0 && distXY < 120.0)
        {
            float sj[3], ej[3], mj[3];
            sj = baseStart; sj[2] += 28.0;
            ej = baseEnd;   ej[2] += 28.0;
            mj[0] = (sj[0] + ej[0]) / 2.0;
            mj[1] = (sj[1] + ej[1]) / 2.0;
            mj[2] = (sj[2] + ej[2]) / 2.0 + 60.0;
            if (TryHull(sj, mj, lowMins, lowMaxs) && TryHull(mj, ej, lowMins, lowMaxs))
            {
                // v4.7: the beam into cell2 is a JUMP — a straight drawn line
                // clips through the ledge/obstacle side. Mark the cell so the
                // drawer renders a parabolic arc instead.
                cell2.jumpFlag = true;
                g_GuideCells.SetArray(i + 1, cell2, sizeof(Cell));
                g_vVault++;
                g_bBeamWalkable.Push(1);
                continue;
            }
        }

        // Strategy 1: Mid hull (44h), normal lift (28u)
        float s1[3], e1[3];
        s1 = baseStart; s1[2] += 28.0;
        e1 = baseEnd;   e1[2] += 28.0;
        walkable = TryHull(s1, e1, midMins, midMaxs);

        // Strategy 2: Mid hull, steep lift (48u) — stairs
        if (!walkable && dz > 30.0 && dist < 150.0)
        {
            float s2[3], e2[3];
            s2 = baseStart; s2[2] += 48.0;
            e2 = baseEnd;   e2[2] += 48.0;
            walkable = TryHull(s2, e2, midMins, midMaxs);
            if (walkable) g_vStair++;
        }

        // Strategy 3: Low hull (32h), normal lift — vent/crawl
        if (!walkable)
        {
            float s3[3], e3[3];
            s3 = baseStart; s3[2] += 28.0;
            e3 = baseEnd;   e3[2] += 28.0;
            walkable = TryHull(s3, e3, lowMins, lowMaxs);
            if (walkable) g_vLow++;
        }

        // Strategy 4: Low hull, steep lift — crawl + stair
        if (!walkable && dz > 30.0 && dist < 150.0)
        {
            float s4[3], e4[3];
            s4 = baseStart; s4[2] += 48.0;
            e4 = baseEnd;   e4[2] += 48.0;
            walkable = TryHull(s4, e4, lowMins, lowMaxs);
            if (walkable) { g_vLow++; g_vStair++; }
        }

        // Strategy 5+6: Offset left/right (±18u)
        if (!walkable)
        {
            for (int side = 0; side < 2 && !walkable; side++)
            {
                float so[3], eo[3];
                float offset = (side == 0) ? 18.0 : -18.0;
                OffsetPerpendicular(s1, e1, offset, so);
                OffsetPerpendicular(e1, s1, -offset, eo);
                so[2] = s1[2]; eo[2] = e1[2];
                walkable = TryHull(so, eo, midMins, midMaxs);
            }
            if (walkable) g_vSide++;
        }

        // Strategy 7: Subdivide (3 segments)
        if (!walkable && dist > 200.0)
        {
            float segStart[3], segEnd[3];
            bool allClear = true;
            for (int seg = 0; seg < 3 && allClear; seg++)
            {
                float t0 = float(seg) / 3.0;
                float t1 = float(seg + 1) / 3.0;
                for (int j = 0; j < 3; j++)
                {
                    segStart[j] = baseStart[j] + (baseEnd[j] - baseStart[j]) * t0;
                    segEnd[j]   = baseStart[j] + (baseEnd[j] - baseStart[j]) * t1;
                }
                segStart[2] += 28.0;
                segEnd[2]   += 28.0;
                if (!TryHull(segStart, segEnd, midMins, midMaxs))
                    allClear = false;
            }
            walkable = allClear;
            if (walkable) g_vSubdiv++;
        }

        // Strategy 8: Jump arc (parabolic, 60u apex)
        if (!walkable && dist < 250.0)
        {
            float sj[3], ej[3], mj[3];
            sj = baseStart; sj[2] += 28.0;
            ej = baseEnd;   ej[2] += 28.0;
            mj[0] = (sj[0] + ej[0]) / 2.0;
            mj[1] = (sj[1] + ej[1]) / 2.0;
            mj[2] = (sj[2] + ej[2]) / 2.0 + 60.0;
            walkable = TryHull(sj, mj, lowMins, lowMaxs)
                    && TryHull(mj, ej, lowMins, lowMaxs);
            // v4.7: jump-validated beam — drawer must render an arc, not a
            // straight line through the obstacle the jump cleared.
            if (walkable)
            {
                cell2.jumpFlag = true;
                g_GuideCells.SetArray(i + 1, cell2, sizeof(Cell));
            }
        }

        g_bBeamWalkable.Push(walkable ? 1 : 0);
        if (!walkable) g_vBlocked++;
    }

    RequestFrame(Guide_ValidateWalkable_Frame, 0);
}

// v4.6.1: does the nav area connect to a ladder or elevator? Exempts real
// climbing structures from the vertical-drop hard cap (dz > 140).
stock bool navArea_has_climb(Address navArea)
{
    if (navArea == Address_Null || !elevator_available) return false;
    if (L4D_NavArea_GetElevator(navArea) > 0) return true;
    if (ladders1 == null) ladders1 = new ArrayList();
    ladders1.Clear();
    return NavArea_GetLadders(navArea, ladders1) > 0;
}

bool frame_budget_exceeded()
{
    if (g_hCvarBudget.FloatValue <= 0.0) return false;
    float dt_ms = (GetEngineTime()-g_tFrameStart)*1000.0;
    bool exceeded = dt_ms >= g_hCvarBudget.FloatValue;
    return exceeded;
}

// v4.6.1: detour-chain budget — independent of the pipeline 0.5ms budget.
// The detour is a small windowed search that must complete in seconds, not
// 40-100s. Always bounded (never "infinite"): an unbounded detour frame
// would blow the engine CPU budget and trip SIGALRM like HPA clustering did.
bool detour_frame_budget_exceeded()
{
    float dt_ms = (GetEngineTime()-g_tFrameStart)*1000.0;
    return dt_ms >= DETOUR_BUDGET_MS;
}

// ======================================================================
// v4.0 STAGE_REPAIR — Auto-repair blocked beams after hull validation
//
// For each beam marked as blocked (g_bBeamWalkable[i] == 0), attempts a
// cascade of repair strategies:
//   1. Z-step: lift cell center by ±48, ±96, ±144
//   2. Horizontal offset: shift ±32u perpendicular to beam direction
//   3. Segment subdivide: split beam into 3 parts, validate each
//   4. Local A* reroute: mini-search between the two cell areas
//   5. Beacon marker: if all repair fails, mark as beacon point
//
// Distributed across frames (REPAIR_BATCH per frame) to avoid stalls.
// ======================================================================

#define REPAIR_BATCH 4
int g_ri;               // current repair beam index
int g_rFixed;           // count of repaired beams
int g_rBeaconed;        // count of beacon-marked beams
int g_rAttempts;        // repair attempts for current beam
ArrayList g_hBeaconCells; // beacon positions for unreachable transitions

int g_iRepairMapGen = -1; // map generation when repair started; abort if stale

// GroundSnapPosition now lives in ptg_utils.inc (defined before both
// ptg_astar.inc and ptg_validate.inc — SourcePawn single-pass compiler).

// ======================================================================
// v4.6 FIX: REPAIR Strategy 4+ — multi-hop local A* reroute.
// The old Strategy 4 tried a SINGLE adjacent nav area as a bypass waypoint
// (cell1 → alt → cell2) and failed on most blocked beams. This collects a
// reachable window around cell1 via BFS, runs a local A* to cell2 (with the
// same geometric visibility penalty as the main search), converts the node
// path to ground-snapped cells, hull-validates every new segment, and splices
// the reroute into g_GuideCells. Falls back to the old single-hop probe when
// the window is too small.
// ======================================================================
#define REROUTE_BFS_DEPTH 14
#define REROUTE_MAX_NODES 2000
#define REROUTE_MAX_POP 3000

ArrayList g_hRrNodes;        // local idx → area int
ArrayList g_hRrCenters;      // local idx → float[3]
StringMap g_hRrAreaToIdx;    // "areaInt" → local idx
ArrayList g_hRrQueue;        // BFS queue of int[2] {areaInt, depth}
ArrayList g_hRrOpen, g_hRrClosed, g_hRrG, g_hRrCameFrom;

// Collect a BFS window around startArea (depth ≤ REROUTE_BFS_DEPTH, skipping
// blocked areas). Returns true if goalArea is inside the window.
stock bool Reroute_Collect(Address startArea, Address goalArea)
{
    if (startArea == Address_Null || goalArea == Address_Null) return false;

    delete g_hRrNodes;
    g_hRrNodes = new ArrayList(1);
    delete g_hRrCenters;
    g_hRrCenters = new ArrayList(3);
    delete g_hRrAreaToIdx;
    g_hRrAreaToIdx = new StringMap();
    delete g_hRrQueue;
    g_hRrQueue = new ArrayList(2);

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));

    bool foundGoal = false;
    int goalInt = view_as<int>(goalArea);

    // Seed with start
    char key[16];
    IntToString(view_as<int>(startArea), key, sizeof(key));
    g_hRrAreaToIdx.SetValue(key, 0);
    float sc[3];
    L4D_GetNavAreaCenter(startArea, sc);
    sc[2] += 16.0;
    g_hRrNodes.Push(view_as<int>(startArea));
    g_hRrCenters.PushArray(sc, 3);

    int queueIdx = 0;
    int pair[2];
    pair[0] = view_as<int>(startArea);
    pair[1] = 0;
    g_hRrQueue.PushArray(pair, 2);

    while (queueIdx < g_hRrQueue.Length && g_hRrNodes.Length < REROUTE_MAX_NODES)
    {
        int cur[2];
        g_hRrQueue.GetArray(queueIdx, cur, 2);
        queueIdx++;
        if (cur[1] >= REROUTE_BFS_DEPTH) continue;

        ConAdj.Clear();
        int connCount = GetNavConnections(view_as<Address>(cur[0]), ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);
        NavConnection nc;
        for (int n = 0; n < connCount; n++)
        {
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;
            int aInt = view_as<int>(nc.navArea);
            if (aInt == cur[0]) continue;
            if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)) continue;

            IntToString(aInt, key, sizeof(key));
            if (g_hRrAreaToIdx.ContainsKey(key)) continue;

            int localIdx = g_hRrNodes.Length;
            g_hRrAreaToIdx.SetValue(key, localIdx);
            float c[3];
            L4D_GetNavAreaCenter(nc.navArea, c);
            c[2] += 16.0;
            g_hRrNodes.Push(aInt);
            g_hRrCenters.PushArray(c, 3);

            pair[0] = aInt;
            pair[1] = cur[1] + 1;
            g_hRrQueue.PushArray(pair, 2);

            if (aInt == goalInt) foundGoal = true;
        }
    }
    delete g_hRrQueue;
    g_hRrQueue = null;
    return foundGoal;
}

// Local A* over the collected window. Returns node index path in g_hRrPath
// (local indices, start → goal) or null.
ArrayList g_hRrPath;

stock float Reroute_Heuristic(int localIdx, int goalLocal)
{
    float c1[3], c2[3];
    g_hRrCenters.GetArray(localIdx, c1, 3);
    g_hRrCenters.GetArray(goalLocal, c2, 3);
    return GetVectorDistance(c1, c2, true) + FloatAbs(c2[2] - c1[2]) * 4.0;
}

stock bool Reroute_AStar(int startLocal, int goalLocal)
{
    if (g_hRrNodes == null || g_hRrNodes.Length < 2) return false;

    delete g_hRrOpen;
    g_hRrOpen = new ArrayList(sizeof(HeapEntry));
    delete g_hRrClosed;
    g_hRrClosed = new ArrayList(1);
    delete g_hRrG;
    g_hRrG = new ArrayList(1);
    delete g_hRrCameFrom;
    g_hRrCameFrom = new ArrayList(1);
    for (int i = 0; i < g_hRrNodes.Length; i++)
    {
        g_hRrClosed.Push(0);
        g_hRrG.Push(99999999.0);
        g_hRrCameFrom.Push(-1);
    }
    g_hRrG.Set(startLocal, 0.0);
    float startF = Reroute_Heuristic(startLocal, goalLocal);
    Heap_Push(g_hRrOpen, startLocal, startF, 0.0);

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    int pops = 0;
    bool found = false;
    HeapEntry entry;
    while (g_hRrOpen.Length > 0 && pops < REROUTE_MAX_POP)
    {
        if (!Heap_Pop(g_hRrOpen, entry)) break;
        pops++;
        int cur = entry.nodeIndex;
        if (g_hRrClosed.Get(cur) == 1) continue;
        float curG = g_hRrG.Get(cur);
        if (FloatAbs(entry.gScore - curG) > 0.1) continue;

        if (cur == goalLocal)
        {
            g_hRrClosed.Set(cur, 1);
            found = true;
            break;
        }
        g_hRrClosed.Set(cur, 1);

        // Expand
        int areaInt = g_hRrNodes.Get(cur);
        ConAdj.Clear();
        int connCount = GetNavConnections(view_as<Address>(areaInt), ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);
        NavConnection nc;
        for (int n = 0; n < connCount; n++)
        {
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;
            if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)) continue;

            char key[16];
            IntToString(view_as<int>(nc.navArea), key, sizeof(key));
            int nLocal = -1;
            if (!g_hRrAreaToIdx.GetValue(key, nLocal)) continue;
            if (g_hRrClosed.Get(nLocal) == 1) continue;

            // Edge cost with geometric visibility penalty (same as main search)
            float c1[3], c2[3];
            g_hRrCenters.GetArray(cur, c1, 3);
            g_hRrCenters.GetArray(nLocal, c2, 3);
            float dx = c2[0] - c1[0], dy = c2[1] - c1[1], dz = c2[2] - c1[2];
            float cost = SquareRoot(dx * dx + dy * dy) + FloatAbs(dz) * 4.0;
            if (g_hCvarGeomPenalty != null && g_hCvarGeomPenalty.BoolValue
                && !twopos_traversable(c1, c2))
                cost *= GEOM_HIDDEN_COST_MULT;

            float tentative = curG + cost;
            float oldG = g_hRrG.Get(nLocal);
            if (tentative < oldG)
            {
                g_hRrG.Set(nLocal, tentative);
                g_hRrCameFrom.Set(nLocal, cur);
                float h = Reroute_Heuristic(nLocal, goalLocal);
                Heap_Push(g_hRrOpen, nLocal, tentative + h, tentative);
            }
        }
    }
    if (!found) return false;

    // Reconstruct local path
    delete g_hRrPath;
    g_hRrPath = new ArrayList();
    int idx = goalLocal;
    int guard = 0;
    while (idx >= 0 && guard < REROUTE_MAX_NODES)
    {
        g_hRrPath.Push(idx);
        idx = g_hRrCameFrom.Get(idx);
        guard++;
    }
    // Reverse in place
    for (int i = 0, j = g_hRrPath.Length - 1; i < j; i++, j--)
    {
        int tmp = g_hRrPath.Get(i);
        g_hRrPath.Set(i, g_hRrPath.Get(j));
        g_hRrPath.Set(j, tmp);
    }
    return g_hRrPath.Length >= 2;
}

// Try a multi-hop reroute between cell1 and cell2. On success, splices the
// new waypoints into g_GuideCells at g_ri+1 and returns true.
stock bool Repair_TryLocalReroute(Cell cell1, Cell cell2)
{
    if (cell1.navArea == Address_Null || cell2.navArea == Address_Null) return false;

    if (!Reroute_Collect(cell1.navArea, cell2.navArea)) return false;
    if (g_hRrNodes == null || g_hRrNodes.Length < 2) return false;

    char key[16];
    int startLocal = 0; // start seeded at local 0
    IntToString(view_as<int>(cell2.navArea), key, sizeof(key));
    int goalLocal = -1;
    if (!g_hRrAreaToIdx.GetValue(key, goalLocal)) return false;

    if (!Reroute_AStar(startLocal, goalLocal)) return false;
    if (g_hRrPath == null || g_hRrPath.Length < 2) return false;

    // Convert node path → ground-snapped mid cells (skip the endpoints:
    // cell1 and cell2 keep their current coordinates)
    ArrayList midCells = new ArrayList(sizeof(Cell));
    float startFlow = cell1.flow, endFlow = cell2.flow;
    int totalNodes = g_hRrPath.Length;
    for (int p = 1; p < totalNodes - 1; p++)
    {
        int nLocal = g_hRrPath.Get(p);
        Cell mc;
        mc.navArea = view_as<Address>(g_hRrNodes.Get(nLocal));
        g_hRrCenters.GetArray(nLocal, mc.center, 3);
        GroundSnapPosition(mc.center);
        mc.flow = startFlow + (endFlow - startFlow) * (float(p) / float(totalNodes - 1));
        midCells.PushArray(mc, sizeof(Cell));
    }

    // Hull-validate every new segment (same standard as the main validate pass)
    float midMins[3] = {-14.0, -14.0, 0.0};
    float midMaxs[3] = { 14.0,  14.0, 44.0};
    bool ok = true;
    if (midCells.Length == 0)
    {
        // No mid cells — direct reroute must itself be traversable
        Cell firstC, lastC;
        g_hRrCenters.GetArray(g_hRrPath.Get(0), firstC.center, 3);
        GroundSnapPosition(firstC.center);
        g_hRrCenters.GetArray(g_hRrPath.Get(totalNodes - 1), lastC.center, 3);
        GroundSnapPosition(lastC.center);
        float s[3], e[3];
        s = cell1.center; s[2] += 28.0;
        e = cell2.center; e[2] += 28.0;
        ok = TryHull(s, e, midMins, midMaxs);
    }
    else
    {
        // cell1 → mid[0]
        float s[3], e[3];
        s = cell1.center; s[2] += 28.0;
        Cell mc;
        midCells.GetArray(0, mc, sizeof(Cell));
        e = mc.center; e[2] += 28.0;
        if (!TryHull(s, e, midMins, midMaxs)) ok = false;

        // mid[j] → mid[j+1]
        for (int j = 0; ok && j < midCells.Length - 1; j++)
        {
            Cell a, b;
            midCells.GetArray(j, a, sizeof(Cell));
            midCells.GetArray(j + 1, b, sizeof(Cell));
            s = a.center; s[2] += 28.0;
            e = b.center; e[2] += 28.0;
            if (!TryHull(s, e, midMins, midMaxs)) ok = false;
        }

        // mid[last] → cell2
        if (ok)
        {
            Cell lastC;
            midCells.GetArray(midCells.Length - 1, lastC, sizeof(Cell));
            s = lastC.center; s[2] += 28.0;
            e = cell2.center; e[2] += 28.0;
            if (!TryHull(s, e, midMins, midMaxs)) ok = false;
        }
    }

    if (!ok)
    {
        delete midCells;
        return false;
    }

    // Splice mid cells into g_GuideCells at g_ri+1, keep beam walkable in sync
    int insertIdx = g_ri + 1;
    for (int j = 0; j < midCells.Length; j++)
    {
        Cell mc;
        midCells.GetArray(j, mc, sizeof(Cell));
        g_GuideCells.ShiftUp(insertIdx);
        g_GuideCells.SetArray(insertIdx, mc, sizeof(Cell));
        g_bBeamWalkable.ShiftUp(insertIdx - 1);
        g_bBeamWalkable.Set(insertIdx - 1, 1);
        g_bBeamWalkable.Set(insertIdx, 1);
        insertIdx++;
    }
    delete midCells;
    return true;
}

void Guide_RepairBlocked()
{
    if (!g_hCvarRepairEnable.BoolValue) return;
    if (g_bBeamWalkable == null || g_GuideCells == null || g_GuideCells.Length < 2) return;

    delete g_hBeaconCells;
    g_hBeaconCells = new ArrayList(3);

    g_ri = 0;
    g_rFixed = 0;
    g_rBeaconed = 0;
    g_rAttempts = 0;
    g_iRepairMapGen = g_iMapGeneration;
    // v4.6: REPAIR mutates g_GuideCells in place (ShiftUp/SetArray between
    // frames). Drawers snapshot, one-shot requests defer, and the completion
    // branch below flushes them. Cleared in Guide_Cleanup for map-change safety.
    g_bGuideCellsBusy = true;

    RequestFrame(Guide_RepairBlocked_Frame, 0);
}

void Guide_RepairBlocked_Frame(any unused)
{
    // Abort if map changed since repair started
    if (g_iRepairMapGen != g_iMapGeneration) return; // busy flag cleared by Guide_Cleanup on map end
    if (g_GuideCells == null || g_bBeamWalkable == null || g_ri >= g_bBeamWalkable.Length)
    {
        if (g_rFixed > 0 || g_rBeaconed > 0)
        {
            LogMessage("[PTG] STAGE_REPAIR: fixed=%d beaconed=%d / %d total beams",
                g_rFixed, g_rBeaconed, (g_GuideCells != null && g_GuideCells.Length > 1) ? g_GuideCells.Length - 1 : 0);
        }
        // v4.6: REPAIR done — release the busy gate. A detour requested while
        // REPAIR was rewriting cells runs now (re-enters with busy=false);
        // otherwise flush any one-shot requests deferred during REPAIR.
        g_bGuideCellsBusy = false;
        g_iPathGen++; // v4.7: repaired line supersedes the coarse/validated one — dedup redraws
        if (g_bDetourQueued && !g_bDetourActive)
        {
            Address queued = g_aDetourQueuedArea;
            g_bDetourQueued = false;
            g_aDetourQueuedArea = Address_Null;
            Guide_TryLocalDetour(queued);
        }
        else
        {
            Timer_CheckRequests(null);
        }
        return;
    }

    int count = g_bBeamWalkable.Length;

    for (int batch = 0; batch < REPAIR_BATCH && g_ri < count; batch++, g_ri++)
    {
        if (g_bBeamWalkable.Get(g_ri) == 1) continue; // already walkable

        Cell cell1, cell2;
        g_GuideCells.GetArray(g_ri, cell1, sizeof(Cell));
        g_GuideCells.GetArray(g_ri + 1, cell2, sizeof(Cell));

        bool repaired = false;

        // Strategy 1: Z-stepping — lift the target cell center
        // Try progressively higher lifts to clear low obstacles
        if (!repaired)
        {
            float zOffsets[6] = {48.0, -48.0, 96.0, -96.0, 144.0, -144.0};
            for (int z = 0; z < 6 && !repaired; z++)
            {
                float test[3];
                test = cell2.center;
                test[2] += zOffsets[z];
                if (twopos_traversable(cell1.center, test))
                {
                    cell2.center = test;
                    // v4.6 FIX: the lifted coordinate only proves the beam
                    // clears the obstacle — snap back to the real ground and
                    // re-verify, or the written cell floats ±48..144u in air.
                    GroundSnapPosition(cell2.center);
                    if (twopos_traversable(cell1.center, cell2.center))
                    {
                        cell2.jumpFlag = false; // v4.7: repaired via straight line — no arc
                        g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                        g_bBeamWalkable.Set(g_ri, 1);
                        repaired = true;
                        g_rFixed++;
                    }
                }
                // Also try lifting cell1
                if (!repaired)
                {
                    test = cell1.center;
                    test[2] += zOffsets[z];
                    if (twopos_traversable(test, cell2.center))
                    {
                        cell1.center = test;
                        GroundSnapPosition(cell1.center);
                        if (twopos_traversable(cell1.center, cell2.center))
                        {
                            cell1.jumpFlag = false; // v4.7: straight line — no arc
                            g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                            g_bBeamWalkable.Set(g_ri, 1);
                            repaired = true;
                            g_rFixed++;
                        }
                    }
                }
            }
        }

        // Strategy 2: Horizontal offset perpendicular to beam
        if (!repaired)
        {
            float dir[3];
            dir[0] = cell2.center[0] - cell1.center[0];
            dir[1] = cell2.center[1] - cell1.center[1];
            float len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);
            if (len > 1.0)
            {
                float perp[3];
                perp[0] = -dir[1] / len;
                perp[1] =  dir[0] / len;
                perp[2] = 0.0;

                float offsets[4] = {32.0, -32.0, 64.0, -64.0};
                for (int o = 0; o < 4 && !repaired; o++)
                {
                    float s1[3], e1[3];
                    s1[0] = cell1.center[0] + perp[0] * offsets[o];
                    s1[1] = cell1.center[1] + perp[1] * offsets[o];
                    s1[2] = cell1.center[2] + 28.0;
                    e1[0] = cell2.center[0] + perp[0] * offsets[o];
                    e1[1] = cell2.center[1] + perp[1] * offsets[o];
                    e1[2] = cell2.center[2] + 28.0;

                    float midMins[3] = {-14.0, -14.0, 0.0};
                    float midMaxs[3] = { 14.0,  14.0, 44.0};
                    // v4.6: unified filter (was TraceFilter_WorldOnly) — REPAIR
                    // must agree with path construction about what blocks.
                    TR_TraceHullFilter(s1, e1, midMins, midMaxs, MASK_PLAYERSOLID, TraceFilterStatic);
                    if (!TR_DidHit())
                    {
                        cell1.center = s1;
                        cell1.center[2] -= 28.0;
                        cell2.center = e1;
                        cell2.center[2] -= 28.0;
                        // v4.6 FIX: the +28 hull lift proves clearance, but the
                        // written cells must rest on real surfaces — snap both
                        // endpoints down and re-verify before accepting.
                        GroundSnapPosition(cell1.center);
                        GroundSnapPosition(cell2.center);
                        if (twopos_traversable(cell1.center, cell2.center))
                        {
                            cell1.jumpFlag = false; // v4.7: straight line — no arc
                            cell2.jumpFlag = false;
                            g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                            g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                            g_bBeamWalkable.Set(g_ri, 1);
                            repaired = true;
                            g_rFixed++;
                        }
                    }
                }
            }
        }

        // Strategy 3: Segment subdivision — split long beam into 3 parts
        if (!repaired)
        {
            float dist = GetVectorDistance(cell1.center, cell2.center, false);
            if (dist > 120.0)
            {
                float segs[4][3];
                segs[0] = cell1.center;
                segs[3] = cell2.center;
                for (int s = 1; s < 3; s++)
                {
                    float t = float(s) / 3.0;
                    for (int j = 0; j < 3; j++)
                        segs[s][j] = cell1.center[j] + (cell2.center[j] - cell1.center[j]) * t;
                    segs[s][2] += 28.0;
                }
                segs[0][2] += 28.0;
                segs[3][2] += 28.0;

                float midMins[3] = {-14.0, -14.0, 0.0};
                float midMaxs[3] = { 14.0,  14.0, 44.0};
                bool allClear = true;
                for (int s = 0; s < 3 && allClear; s++)
                {
                    // v4.6: unified filter (was TraceFilter_WorldOnly)
                    TR_TraceHullFilter(segs[s], segs[s+1], midMins, midMaxs, MASK_PLAYERSOLID, TraceFilterStatic);
                    if (TR_DidHit()) allClear = false;
                }

                if (allClear)
                {
                    // Insert intermediate waypoints to avoid the blocked direct beam
                    Cell midCell;
                    midCell.navArea = Address_Null;
                    midCell.flow = (cell1.flow + cell2.flow) / 2.0;
                    midCell.center[0] = segs[1][0];
                    midCell.center[1] = segs[1][1];
                    midCell.center[2] = segs[1][2] - 28.0;
                    // v4.6 FIX: the midpoint is a linear Z interpolation between
                    // the two endpoints — on stairs/slopes it hovers above the
                    // surface. Snap to ground and re-verify both new beams.
                    GroundSnapPosition(midCell.center);
                    if (twopos_traversable(cell1.center, midCell.center)
                        && twopos_traversable(midCell.center, cell2.center))
                    {
                        // Insert new cell between g_ri and g_ri+1
                        g_GuideCells.ShiftUp(g_ri + 1);
                        g_GuideCells.SetArray(g_ri + 1, midCell, sizeof(Cell));
                        g_bBeamWalkable.ShiftUp(g_ri);
                        g_bBeamWalkable.Set(g_ri, 1);
                        g_bBeamWalkable.Set(g_ri + 1, 1);
                        repaired = true;
                        g_rFixed++;
                    }
                }
            }
        }

        // Strategy 4: Local A* reroute using nav area adjacency
        // v4.6 FIX: multi-hop window search first — the old single-hop probe
        // below only tried ONE adjacent area and failed on most blocked beams.
        if (!repaired && cell1.navArea != Address_Null && cell2.navArea != Address_Null)
        {
            if (Repair_TryLocalReroute(cell1, cell2))
            {
                repaired = true;
                g_rFixed++;
            }
        }
        // Strategy 4b: single-hop probe (legacy fallback when reroute window fails)
        if (!repaired && cell1.navArea != Address_Null && cell2.navArea != Address_Null)
        {
            if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
            ConAdj.Clear();

            int connCount = GetNavConnections(cell1.navArea, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);
            NavConnection nc;
            bool foundAlt = false;
            float bestDist = -1.0;
            float bestPos[3];
            Address bestArea = Address_Null;

            for (int n = 0; n < connCount; n++)
            {
                ConAdj.GetArray(n, nc, sizeof(NavConnection));
                if (nc.navArea == Address_Null || nc.navArea == cell1.navArea) continue;
                if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)) continue;

                float altCenter[3];
                L4D_GetNavAreaCenter(nc.navArea, altCenter);
                altCenter[2] += 16.0;

                if (twopos_traversable(cell1.center, altCenter) && twopos_traversable(altCenter, cell2.center))
                {
                    float d = GetVectorDistance(cell1.center, altCenter, true)
                            + GetVectorDistance(altCenter, cell2.center, true);
                    if (bestDist < 0.0 || d < bestDist)
                    {
                        bestDist = d;
                        bestPos = altCenter;
                        bestArea = nc.navArea;
                        foundAlt = true;
                    }
                }
            }

            if (foundAlt)
            {
                Cell altCell;
                altCell.navArea = bestArea;
                altCell.center = bestPos;
                altCell.flow = (cell1.flow + cell2.flow) / 2.0;
                // v4.6 FIX: nav-area centers sit at the area's average height
                // (floors/slopes/ledges) — snap the reroute waypoint to the
                // real ground and re-verify both new beams.
                GroundSnapPosition(altCell.center);
                if (twopos_traversable(cell1.center, altCell.center)
                    && twopos_traversable(altCell.center, cell2.center))
                {
                    g_GuideCells.ShiftUp(g_ri + 1);
                    g_GuideCells.SetArray(g_ri + 1, altCell, sizeof(Cell));
                    g_bBeamWalkable.ShiftUp(g_ri);
                    g_bBeamWalkable.Set(g_ri, 1);
                    g_bBeamWalkable.Set(g_ri + 1, 1);
                    repaired = true;
                    g_rFixed++;
                }
            }
        }

        // Strategy 5: Beacon — mark unreachable transition
        if (!repaired && g_hCvarBeaconEnable.BoolValue)
        {
            float beaconPos[3];
            beaconPos = cell1.center;
            g_hBeaconCells.PushArray(beaconPos, 3);
            g_rBeaconed++;

            // Mark as walkable so we don't keep trying to repair
            g_bBeamWalkable.Set(g_ri, 1);
        }
        else if (!repaired)
        {
            // No beacon enabled, just mark as-is
            g_bBeamWalkable.Set(g_ri, 0);
        }
    }

    RequestFrame(Guide_RepairBlocked_Frame, 0);
}

// Draw a single beacon pillar (vertical beam + top ring) at pos.
// v4.6: split out of Guide_DrawBeacons so AutoGuideDrawPath can reuse it for
// blocked segments (replaces the tiny 28u dots that were invisible in 3D).
void Guide_DrawBeaconPillar(float pos[3], int client, float duration, float width)
{
    int laser = g_iLaserWhite;
    if (laser == 0) laser = g_iLaser;
    if (laser == 0) return;
    if (duration < 1.0) duration = 5.0;

    // Bright red-orange beacon: "path continues here"
    int color_beacon[4] = {255, 100, 50, 255};

    float end[3];
    end = pos;
    end[2] += 32.0; // tall vertical marker

    // Vertical pillar beam — visible from a distance
    TE_SetupBeamPoints(pos, end, laser, 0, 0, 0,
        duration, width, width, 0, 0.0, color_beacon, 0);
    if (client > 0) TE_SendToClient(client);
    else TE_SendToAll();

    // Ring at top — makes it recognizable as a beacon
    float ringCenter[3];
    ringCenter = end;
    int color_ring[4] = {255, 200, 100, 200};
    float ringRad = 20.0;
    float ringSteps[6][3];
    for (int s = 0; s < 6; s++)
    {
        float angle = float(s) * 3.14159 * 2.0 / 6.0;
        ringSteps[s][0] = ringCenter[0] + Cosine(angle) * ringRad;
        ringSteps[s][1] = ringCenter[1] + Sine(angle) * ringRad;
        ringSteps[s][2] = ringCenter[2];
    }
    for (int s = 0; s < 6; s++)
    {
        int sn = (s + 1) % 6;
        TE_SetupBeamPoints(ringSteps[s], ringSteps[sn], laser, 0, 0, 0,
            duration * 0.5, 1.5, 1.0, 0, 0.0, color_ring, 0);
        if (client > 0) TE_SendToClient(client);
        else TE_SendToAll();
    }
}

// Draw beacon markers: partial-path dead-end beacon + REPAIR beacons.
void Guide_DrawBeacons(int client = -1)
{
    if (!g_hCvarBeaconEnable.BoolValue) return;

    float duration = g_hCvarAutoDuration.FloatValue;
    if (duration < 1.0) duration = 5.0;

    // v4.6: cap per-draw beacons — each beacon costs 7 temp entities
    int budget = (g_hCvarMax.IntValue > 8) ? g_hCvarMax.IntValue / 4 : 4;
    int drawn = 0;

    // v4.6: partial-path dead-end beacon (A* open set exhausted — the path
    // stops here because the nav mesh is disconnected)
    if (g_hPartialBeacon != null && g_hPartialBeacon.Length > 0)
    {
        float pos[3];
        g_hPartialBeacon.GetArray(0, pos, 3);
        Guide_DrawBeaconPillar(pos, client, duration, 4.0);
        drawn++;
    }

    // v4.6: finale radio operation point beacon (see evtFinaleStart)
    if (g_hRadioBeacon != null && g_hRadioBeacon.Length > 0)
    {
        float pos[3];
        g_hRadioBeacon.GetArray(0, pos, 3);
        Guide_DrawBeaconPillar(pos, client, duration, 4.0);
        drawn++;
    }

    if (g_hBeaconCells == null || g_hBeaconCells.Length == 0) return;

    // v4.6: snapshot before drawing — REPAIR may delete/rebuild
    // g_hBeaconCells between redraw ticks (see Guide_RepairBlocked).
    ArrayList snapshot = g_hBeaconCells.Clone();
    for (int i = 0; i < snapshot.Length && drawn < budget; i++)
    {
        float pos[3];
        snapshot.GetArray(i, pos, 3);
        Guide_DrawBeaconPillar(pos, client, duration, 4.0);
        drawn++;
    }
    delete snapshot;
}



