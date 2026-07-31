// PTG Module: ptg_detour — local detour around newly blocked nav areas (v4.6)
//
// When a nav area on the current guide path becomes blocked (nav_blocked event
// or periodic integrity poll), instead of a full pipeline rebuild — which on
// large maps costs seconds of background CPU and briefly blanks the path — run
// a windowed A* around the break and splice the detour into g_GuideCells.
//
// Window: [blockedIdx ± DETOUR_WINDOW] cells. Anchors are the window's first
// and last nav areas; a BFS constrained to the window's AABB (+400u padding)
// collects the local node table; a local A* (independent arrays — never touches
// pipeline search state) runs start→goal; the resulting path is converted with
// AStar_CellFromNode (shared with the pipeline) and spliced in place.
//
// Failure chain: widen window 2× (max DETOUR_WINDOW*4) → full NavChanged(true)
// rebuild. Concurrency: the whole chain holds g_bGuideCellsBusy (drawers
// snapshot); triggers during the chain are queued and run on completion;
// NavChanged(true) during the chain sets g_bDetourQueuedDirty and runs after.
//
// State variables and window constants live in ptg_types.inc — ptg_validate.inc
// (REPAIR completion) reads the queued flags and is inlined before this file.

// Entry point. Called with the blocked nav area (must be on the path).
public void Guide_TryLocalDetour(Address blockedArea)
{
    if (blockedArea == Address_Null) return;

    // Gate: only when the path is live and nothing else is mutating it.
    // Triggers while busy are deferred; the completion branches of the
    // pipeline / REPAIR / detour chains run them.
    if (!guide_ready || guide_prep || g_bGuideCellsBusy || g_bDetourActive)
    {
        g_bDetourQueued = true;
        g_aDetourQueuedArea = blockedArea;
        return;
    }

    // Locate the blocked cell index on the path
    int len = g_GuideCells.Length;
    g_iDetourBlockedIdx = -1;
    Cell cell;
    for (int i = 0; i < len; i++)
    {
        g_GuideCells.GetArray(i, cell, sizeof(Cell));
        if (cell.navArea == blockedArea)
        {
            g_iDetourBlockedIdx = i;
            break;
        }
    }
    if (g_iDetourBlockedIdx < 0) return; // not on path (anymore) — nothing to do

    g_iDetourD = DETOUR_WINDOW;
    g_bDetourQueued = false;
    g_bDetourQueuedDirty = false;
    if (!Detour_InitWindow())
    {
        LogMessage("[PTG] Detour: window init failed at cell %d — falling back to full rebuild", g_iDetourBlockedIdx);
        NavChanged(true);
        return;
    }

    g_bDetourActive = true;
    g_bGuideCellsBusy = true; // we will rewrite g_GuideCells — drawers snapshot
    g_iDetourStage = 1;
    LogMessage("[PTG] Detour: cell %d blocked — window [%d..%d], local A* start %d → goal %d",
        g_iDetourBlockedIdx, g_iDetourWinStart, g_iDetourWinEnd, g_iDetourStartIdx, g_iDetourGoalIdx);
    RequestFrame(Detour_Frame, 0);
}

// Initialize window, anchors and AABB. Returns false on unrecoverable failure.
bool Detour_InitWindow()
{
    int len = g_GuideCells.Length;
    int s = g_iDetourBlockedIdx - g_iDetourD;
    int e = g_iDetourBlockedIdx + g_iDetourD;
    if (s < 0) s = 0;
    if (e >= len) e = len - 1;
    if (e - s < 2) return false; // window collapsed onto itself

    Cell cStart, cEnd;
    g_GuideCells.GetArray(s, cStart, sizeof(Cell));
    g_GuideCells.GetArray(e, cEnd, sizeof(Cell));
    if (cStart.navArea == Address_Null || cEnd.navArea == Address_Null) return false;

    // Anchor node indices (A* node index survives the post-build cleanup —
    // only search state is freed at SMOOTH finish)
    char key[16];
    IntToString(view_as<int>(cStart.navArea), key, sizeof(key));
    if (!g_hAStarAreaToIndex.GetValue(key, g_iDetourStartIdx)) return false;
    IntToString(view_as<int>(cEnd.navArea), key, sizeof(key));
    if (!g_hAStarAreaToIndex.GetValue(key, g_iDetourGoalIdx)) return false;

    g_iDetourWinStart = s;
    g_iDetourWinEnd = e;

    // AABB around window cell centers + padding
    g_fDetourMin[0] = g_fDetourMin[1] = g_fDetourMin[2] = 99999999.0;
    g_fDetourMax[0] = g_fDetourMax[1] = g_fDetourMax[2] = -99999999.0;
    for (int i = s; i <= e; i++)
    {
        Cell c;
        g_GuideCells.GetArray(i, c, sizeof(Cell));
        for (int a = 0; a < 3; a++)
        {
            if (c.center[a] < g_fDetourMin[a]) g_fDetourMin[a] = c.center[a];
            if (c.center[a] > g_fDetourMax[a]) g_fDetourMax[a] = c.center[a];
        }
    }
    for (int a = 0; a < 3; a++)
    {
        g_fDetourMin[a] -= DETOUR_BOX_PADDING;
        g_fDetourMax[a] += DETOUR_BOX_PADDING;
    }
    return true;
}

// Distributed detour frame chain
void Detour_Frame()
{
    switch (g_iDetourStage)
    {
        case 1: // collect nodes in the AABB via BFS from the start anchor
        {
            if (Detour_CollectFrame())
            {
                // goal must be inside the collected set, else no path can exist
                char key[16];
                IntToString(g_iDetourGoalIdx, key, sizeof(key));
                if (!g_hDetourNodeMap.ContainsKey(key))
                {
                    LogMessage("[PTG] Detour: goal not in collected set (%d nodes) — widening", g_hDetourNodes.Length);
                    Detour_Fail();
                    return;
                }
                g_iDetourStage = 2;
                Detour_AStar_Init();
            }
            RequestFrame(Detour_Frame, 0);
        }
        case 2: // local A*
        {
            int result = Detour_AStar_Frame(DETOUR_NODES_PER_FRAME);
            if (result == 1)
            {
                g_iDetourStage = 3;
                g_iDetourConvIdx = 0;
            }
            else if (result == -1)
            {
                LogMessage("[PTG] Detour: local A* exhausted (%d nodes) — widening", g_hDetourNodes.Length);
                Detour_Fail();
                return;
            }
            RequestFrame(Detour_Frame, 0);
        }
        case 3: // convert local path → guide cells
        {
            if (Detour_ConvertFrame(DETOUR_CONVERT_PER_FRAME))
                g_iDetourStage = 4;
            RequestFrame(Detour_Frame, 0);
        }
        case 4: // splice into g_GuideCells (single frame: O(n) rebuild + few traces)
        {
            if (Detour_Splice())
            {
                LogMessage("[PTG] Detour complete: %d detour cells spliced (total %d cells)",
                    g_hDetourCells.Length, g_GuideCells.Length);
                Detour_Done();
            }
            else
            {
                LogMessage("[PTG] Detour: splice boundary check failed — widening");
                Detour_Fail();
            }
        }
    }
}

// Window BFS. Returns true when done (queue drained or node limit hit).
bool Detour_CollectFrame()
{
    if (g_hDetourNodes == null)
    {
        delete g_hDetourNodes; delete g_hDetourNodeMap;
        delete g_hDetourG; delete g_hDetourCameFrom;
        delete g_hDetourEdge; delete g_hDetourClosed; delete g_hDetourOpen;
        g_hDetourNodes = new ArrayList();
        g_hDetourNodeMap = new StringMap();
        g_hDetourG = new ArrayList(1);
        g_hDetourCameFrom = new ArrayList(1);
        g_hDetourEdge = new ArrayList(1);
        g_hDetourClosed = new ArrayList(1);
        g_hDetourOpen = new ArrayList(sizeof(HeapEntry));

        // seed with start anchor
        char key[16];
        IntToString(g_iDetourStartIdx, key, sizeof(key));
        g_hDetourNodeMap.SetValue(key, 0);
        g_hDetourNodes.Push(g_iDetourStartIdx);
        g_hDetourG.Push(0.0);
        g_hDetourCameFrom.Push(-1);
        g_hDetourEdge.Push(CONNECTED_NOT);
        g_hDetourClosed.Push(0);
        g_iDetourCollectHead = 0;
    }

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    int processed = 0;
    int limit = DETOUR_NODE_LIMIT;

    while (g_iDetourCollectHead < g_hDetourNodes.Length && g_hDetourNodes.Length < limit)
    {
        if (processed > 0 && frame_budget_exceeded()) return false;

        int localIdx = g_iDetourCollectHead;
        g_iDetourCollectHead++;
        int nodeIdx = g_hDetourNodes.Get(localIdx);
        int areaInt = g_hAStarNodes.Get(nodeIdx);
        Address area = view_as<Address>(areaInt);

        GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length && g_hDetourNodes.Length < limit; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int otherInt = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

            // Already in the table?
            IntToString(otherIdx, keyB, sizeof(keyB));
            if (g_hDetourNodeMap.ContainsKey(keyB)) continue;

            // Skip blocked areas — the whole point of the detour. Anchors are
            // already in the table, so they're exempt from this check.
            if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)) continue;

            // AABB constraint: only nodes inside the window box
            float center[3];
            g_hAStarCenters.GetArray(otherIdx, center, 3);
            if (center[0] < g_fDetourMin[0] || center[0] > g_fDetourMax[0]
             || center[1] < g_fDetourMin[1] || center[1] > g_fDetourMax[1]
             || center[2] < g_fDetourMin[2] || center[2] > g_fDetourMax[2]) continue;

            int newLocal = g_hDetourNodes.Length;
            g_hDetourNodeMap.SetValue(keyB, newLocal);
            g_hDetourNodes.Push(otherIdx);
            g_hDetourG.Push(99999999.0);
            g_hDetourCameFrom.Push(-1);
            g_hDetourEdge.Push(CONNECTED_NOT);
            g_hDetourClosed.Push(0);
        }
        processed++;
    }

    if (g_hDetourNodes.Length >= limit)
    {
        // v4.6: truncated box — the reachable set is partial; a widening retry
        // will re-collect with a bigger window before we give up
        LogMessage("[PTG] Detour: node collection hit %d limit — box may be partial", limit);
    }
    return (g_iDetourCollectHead >= g_hDetourNodes.Length || g_hDetourNodes.Length >= limit);
}

// Local A* heuristic — Z-weighted Euclidean toward the goal anchor.
// Deliberately simple and self-contained: does not touch g_iAStarGoalIndex
// or pipeline heuristics (HPA boost etc.), which belong to the pipeline.
float Detour_Heuristic(int localIdx)
{
    int nodeIdx = g_hDetourNodes.Get(localIdx);
    float center[3];
    g_hAStarCenters.GetArray(nodeIdx, center, 3);
    float gc[3];
    g_hAStarCenters.GetArray(g_iDetourGoalIdx, gc, 3);
    float dx = center[0] - gc[0];
    float dy = center[1] - gc[1];
    float dz = center[2] - gc[2];
    float zFactor = (g_hCvarZCostFactor != null) ? g_hCvarZCostFactor.FloatValue : 4.0;
    return (SquareRoot(dx * dx + dy * dy) + FloatAbs(dz) * zFactor) * 1.15;
}

void Detour_AStar_Init()
{
    g_hDetourG.Clear();
    g_hDetourCameFrom.Clear();
    g_hDetourEdge.Clear();
    g_hDetourClosed.Clear();
    g_hDetourOpen.Clear();
    for (int i = 0; i < g_hDetourNodes.Length; i++)
    {
        g_hDetourG.Push(99999999.0);
        g_hDetourCameFrom.Push(-1);
        g_hDetourEdge.Push(CONNECTED_NOT);
        g_hDetourClosed.Push(0);
    }
    g_hDetourG.Set(0, 0.0); // local 0 = start anchor
    float f = Detour_Heuristic(0);
    Heap_Push(g_hDetourOpen, 0, f, 0.0);
}

// Local A* over the collected table. Returns 1=goal reached, 0=still searching,
// -1=open set exhausted (goal unreachable within window).
int Detour_AStar_Frame(int maxNodes)
{
    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));

    // goal local index
    char key[16];
    IntToString(g_iDetourGoalIdx, key, sizeof(key));
    int goalLocal = -1;
    if (!g_hDetourNodeMap.GetValue(key, goalLocal)) return -1;

    int processed = 0;
    HeapEntry entry;

    while (processed < maxNodes && g_hDetourOpen.Length > 0)
    {
        if (processed > 0 && frame_budget_exceeded()) return 0;

        if (!Heap_Pop(g_hDetourOpen, entry))
            return -1;

        int currentLocal = entry.nodeIndex;
        if (g_hDetourClosed.Get(currentLocal) == 1) continue;

        float currentG = g_hDetourG.Get(currentLocal);
        if (FloatAbs(entry.gScore - currentG) > 0.1) continue;

        if (currentLocal == goalLocal)
        {
            g_hDetourClosed.Set(currentLocal, 1);
            return 1;
        }

        g_hDetourClosed.Set(currentLocal, 1);

        int nodeIdx = g_hDetourNodes.Get(currentLocal);
        Address area = view_as<Address>(g_hAStarNodes.Get(nodeIdx));
        GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        for (int i = 0; i < ConAdj.Length; i++)
        {
            NavConnection nc;
            ConAdj.GetArray(i, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int otherInt = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

            IntToString(otherIdx, keyB, sizeof(keyB));
            int otherLocal = -1;
            if (!g_hDetourNodeMap.GetValue(keyB, otherLocal)) continue; // outside box
            if (g_hDetourClosed.Get(otherLocal) == 1) continue;
            if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true)
                && otherLocal != goalLocal) continue;

            float tentativeG = currentG + AStar_EdgeCost(nodeIdx, otherIdx, nc.connectiontype);
            if (tentativeG < g_hDetourG.Get(otherLocal))
            {
                g_hDetourG.Set(otherLocal, tentativeG);
                g_hDetourCameFrom.Set(otherLocal, currentLocal);
                g_hDetourEdge.Set(otherLocal, view_as<int>(nc.connectiontype));
                float fScore = tentativeG + Detour_Heuristic(otherLocal);
                Heap_Push(g_hDetourOpen, otherLocal, fScore, tentativeG);
            }
        }
        processed++;
    }

    if (g_hDetourOpen.Length == 0) return -1;
    return 0;
}

// Convert the local path (walk cameFrom chain) → guide cells.
// Returns true when done.
bool Detour_ConvertFrame(int maxCells)
{
    if (g_hDetourPath == null)
    {
        // Walk backwards from goal
        char key[16];
        IntToString(g_iDetourGoalIdx, key, sizeof(key));
        int goalLocal = -1;
        g_hDetourNodeMap.GetValue(key, goalLocal);

        ArrayList reversePath = new ArrayList();
        int cur = goalLocal;
        int steps = 0;
        while (cur >= 0 && steps < g_hDetourNodes.Length)
        {
            reversePath.Push(cur);
            cur = g_hDetourCameFrom.Get(cur);
            steps++;
        }
        if (steps >= g_hDetourNodes.Length || reversePath.Length < 2)
        {
            delete reversePath;
            return false; // cycle or degenerate — treated as failure by caller
        }

        delete g_hDetourPath;
        g_hDetourPath = new ArrayList();
        for (int i = reversePath.Length - 1; i >= 0; i--)
            g_hDetourPath.Push(reversePath.Get(i));
        delete reversePath;

        delete g_hDetourCells;
        g_hDetourCells = new ArrayList(sizeof(Cell));
        g_iDetourConvIdx = 0;
    }

    int pathLen = g_hDetourPath.Length;
    Cell cStart, cEnd;
    g_GuideCells.GetArray(g_iDetourWinStart, cStart, sizeof(Cell));
    g_GuideCells.GetArray(g_iDetourWinEnd, cEnd, sizeof(Cell));
    float startFlow = cStart.flow;
    float goalFlow = cEnd.flow;

    int processed = 0;
    while (g_iDetourConvIdx < pathLen && processed < maxCells)
    {
        if (processed > 0 && frame_budget_exceeded()) return false;

        int localIdx = g_hDetourPath.Get(g_iDetourConvIdx);
        int nodeIdx = g_hDetourNodes.Get(localIdx);

        Cell cell;
        AStar_CellFromNode(nodeIdx, cell);

        // flow interpolated across the window
        cell.flow = startFlow + (goalFlow - startFlow) * (float(g_iDetourConvIdx) / float(pathLen - 1));
        g_hDetourCells.PushArray(cell, sizeof(Cell));

        g_iDetourConvIdx++;
        processed++;
    }
    return g_iDetourConvIdx >= pathLen;
}

// Splice the detour into g_GuideCells + g_bBeamWalkable. Returns false when a
// boundary LOS check fails (caller widens the window and retries).
bool Detour_Splice()
{
    int len = g_GuideCells.Length;
    if (g_hDetourCells == null || g_hDetourCells.Length < 2) return false;

    Cell first, last;
    g_hDetourCells.GetArray(0, first, sizeof(Cell));
    g_hDetourCells.GetArray(g_hDetourCells.Length - 1, last, sizeof(Cell));

    // Boundary LOS — detour must connect cleanly to the path outside the window
    if (g_iDetourWinStart > 0)
    {
        Cell before;
        g_GuideCells.GetArray(g_iDetourWinStart - 1, before, sizeof(Cell));
        if (!twopos_traversable(before.center, first.center))
        {
            float lifted[3];
            lifted = first.center; lifted[2] += 8.0;
            if (twopos_traversable(before.center, lifted)) first.center = lifted;
            else return false;
        }
    }
    if (g_iDetourWinEnd < len - 1)
    {
        Cell after;
        g_GuideCells.GetArray(g_iDetourWinEnd + 1, after, sizeof(Cell));
        if (!twopos_traversable(last.center, after.center))
        {
            float lifted[3];
            lifted = last.center; lifted[2] += 8.0;
            if (twopos_traversable(lifted, after.center)) last.center = lifted;
            else return false;
        }
    }
    g_hDetourCells.SetArray(0, first, sizeof(Cell));
    g_hDetourCells.SetArray(g_hDetourCells.Length - 1, last, sizeof(Cell));

    // Rebuild g_GuideCells with the detour spliced in (O(n) single pass)
    ArrayList newCells = new ArrayList(sizeof(Cell));
    Cell c;
    for (int i = 0; i < g_iDetourWinStart; i++)
    {
        g_GuideCells.GetArray(i, c, sizeof(Cell));
        newCells.PushArray(c, sizeof(Cell));
    }
    for (int i = 0; i < g_hDetourCells.Length; i++)
    {
        g_hDetourCells.GetArray(i, c, sizeof(Cell));
        newCells.PushArray(c, sizeof(Cell));
    }
    for (int i = g_iDetourWinEnd + 1; i < len; i++)
    {
        g_GuideCells.GetArray(i, c, sizeof(Cell));
        newCells.PushArray(c, sizeof(Cell));
    }
    delete g_GuideCells;
    g_GuideCells = newCells;

    // Rebuild beam walkable flags: edges touching the detour segment are
    // re-validated (unified TryHull filter — v4.6 batch4); outside edges keep
    // their old flags with an index shift.
    int detourLen = g_hDetourCells.Length;
    int windowLen = g_iDetourWinEnd - g_iDetourWinStart + 1;
    int idxShift = detourLen - windowLen;
    ArrayList newBeams = new ArrayList(1);
    float midMins[3] = {-14.0, -14.0, 0.0};
    float midMaxs[3] = { 14.0,  14.0, 44.0};
    for (int i = 0; i < newCells.Length - 1; i++)
    {
        bool touchesDetour = (i >= g_iDetourWinStart - 1 && i < g_iDetourWinStart + detourLen - 1);
        if (touchesDetour)
        {
            Cell c1, c2;
            newCells.GetArray(i, c1, sizeof(Cell));
            newCells.GetArray(i + 1, c2, sizeof(Cell));
            float s1[3], e1[3];
            s1 = c1.center; s1[2] += 28.0;
            e1 = c2.center; e1[2] += 28.0;
            newBeams.Push(TryHull(s1, e1, midMins, midMaxs) ? 1 : 0);
        }
        else
        {
            int oldIdx = (i >= g_iDetourWinStart + detourLen - 1) ? i - idxShift : i;
            newBeams.Push((g_bBeamWalkable != null && oldIdx >= 0 && oldIdx < g_bBeamWalkable.Length)
                ? g_bBeamWalkable.Get(oldIdx) : 1);
        }
    }
    delete g_bBeamWalkable;
    g_bBeamWalkable = newBeams;

    return true;
}

// Failure: clean local state, widen the window (2×, capped), retry or fall
// back to a full NavChanged(true) rebuild.
void Detour_Fail()
{
    Detour_ClearLocalState();
    g_iDetourD *= 2;
    if (g_iDetourD > DETOUR_WINDOW * 4)
    {
        LogMessage("[PTG] Detour failed after widening — full rebuild");
        g_bDetourActive = false;
        g_bGuideCellsBusy = false;
        NavChanged(true);
        return;
    }
    if (Detour_InitWindow())
    {
        g_iDetourStage = 1;
        LogMessage("[PTG] Detour: widening window to ±%d (cell %d)", g_iDetourD, g_iDetourBlockedIdx);
        RequestFrame(Detour_Frame, 0);
        return;
    }
    g_bDetourActive = false;
    g_bGuideCellsBusy = false;
    NavChanged(true);
}

void Detour_ClearLocalState()
{
    delete g_hDetourNodes; g_hDetourNodes = null;
    delete g_hDetourNodeMap; g_hDetourNodeMap = null;
    delete g_hDetourG; g_hDetourG = null;
    delete g_hDetourCameFrom; g_hDetourCameFrom = null;
    delete g_hDetourEdge; g_hDetourEdge = null;
    delete g_hDetourClosed; g_hDetourClosed = null;
    delete g_hDetourOpen; g_hDetourOpen = null;
    delete g_hDetourPath; g_hDetourPath = null;
    delete g_hDetourCells; g_hDetourCells = null;
}

// Success: release the busy gate, run deferred work, flush pending requests.
void Detour_Done()
{
    Detour_ClearLocalState();
    g_bDetourActive = false;
    g_bGuideCellsBusy = false;
    g_iDetourStage = 0;

    if (g_bDetourQueuedDirty)
    {
        // a full invalidation arrived while we were detouring — honor it
        g_bDetourQueuedDirty = false;
        NavChanged(true);
        return;
    }
    if (g_bDetourQueued)
    {
        Address queued = g_aDetourQueuedArea;
        g_bDetourQueued = false;
        g_aDetourQueuedArea = Address_Null;
        Guide_TryLocalDetour(queued);
        return;
    }
    Timer_CheckRequests(null);
}
