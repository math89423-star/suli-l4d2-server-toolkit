// PTG Module: ptg_astar — A* engine, heap, spatial hash, non-mesh detection, portals, HPA*, bridges, smoothing
// Extracted from l4d_path_to_goal.inc (backup)

// ── Binary heap ──
stock void Heap_BubbleUp(ArrayList heap, int i)
{
    if (i <= 0) return;
    HeapEntry current, parent;
    while (i > 0)
    {
        int pi = (i - 1) / 2;
        heap.GetArray(i, current, sizeof(HeapEntry));
        heap.GetArray(pi, parent, sizeof(HeapEntry));
        if (current.fScore >= parent.fScore) break;
        // swap
        heap.SetArray(i, parent, sizeof(HeapEntry));
        heap.SetArray(pi, current, sizeof(HeapEntry));
        i = pi;
    }
}

// Bubble down from index i
stock void Heap_BubbleDown(ArrayList heap, int i)
{
    int size = heap.Length;
    if (size <= 1) return;
    HeapEntry current, child, temp;
    while (true)
    {
        int left = 2 * i + 1;
        int right = 2 * i + 2;
        int smallest = i;

        heap.GetArray(i, current, sizeof(HeapEntry));

        if (left < size)
        {
            heap.GetArray(left, child, sizeof(HeapEntry));
            if (child.fScore < current.fScore) smallest = left;
        }
        if (right < size)
        {
            heap.GetArray(right, child, sizeof(HeapEntry));
            heap.GetArray(smallest, temp, sizeof(HeapEntry));
            if (child.fScore < temp.fScore) smallest = right;
        }
        if (smallest == i) break;

        // swap
        heap.GetArray(smallest, child, sizeof(HeapEntry));
        heap.SetArray(i, child, sizeof(HeapEntry));
        heap.SetArray(smallest, current, sizeof(HeapEntry));
        i = smallest;
    }
}

stock void Heap_Push(ArrayList heap, int nodeIndex, float fScore, float gScore)
{
    HeapEntry entry;
    entry.nodeIndex = nodeIndex;
    entry.fScore = fScore;
    entry.gScore = gScore;
    heap.PushArray(entry, sizeof(HeapEntry));
    Heap_BubbleUp(heap, heap.Length - 1);
}

// Pop the entry with lowest fScore. Returns false if heap is empty.
stock bool Heap_Pop(ArrayList heap, HeapEntry outEntry)
{
    if (heap.Length == 0) return false;

    // Get root
    heap.GetArray(0, outEntry, sizeof(HeapEntry));

    // Move last to root
    int last = heap.Length - 1;
    if (last > 0)
    {
        HeapEntry lastEntry;
        heap.GetArray(last, lastEntry, sizeof(HeapEntry));
        heap.SetArray(0, lastEntry, sizeof(HeapEntry));
    }
    heap.Resize(last);

    if (heap.Length > 0)
        Heap_BubbleDown(heap, 0);

    return true;
}

// ============================================================================
// Spatial Hash — fast O(k) nearby-nav-area queries
// ============================================================================


// ── Spatial hash ──
stock void SpatialHash_Insert(float center[3], int navAreaInt)
{
    int cx = RoundToFloor(center[0] / SPATIAL_CELL_SIZE);
    int cy = RoundToFloor(center[1] / SPATIAL_CELL_SIZE);
    int cz = RoundToFloor(center[2] / SPATIAL_CELL_SIZE);

    char key[32];
    Format(key, sizeof(key), "%d_%d_%d", cx, cy, cz);

    ArrayList cellList;
    if (!g_hSpatialHash.GetValue(key, cellList))
    {
        cellList = new ArrayList(2); // entry: {navArea(int), float[3] center}
        g_hSpatialHash.SetValue(key, cellList);
    }

    // Cap cell size to prevent perf issues on dense nav meshes
    if (cellList.Length >= 64) return;

    cellList.Push(navAreaInt);
    cellList.PushArray(center, 3);
}

// Query: fill result with navArea addresses (as int) within range of pos
// checkRange: how many spatial cells to check in each axis (1 = 3x3x3, 2 = 5x5x5)
stock void SpatialHash_Query(float pos[3], ArrayList result, float maxDist = 512.0, int checkRange = 1)
{
    result.Clear();
    int cx = RoundToFloor(pos[0] / SPATIAL_CELL_SIZE);
    int cy = RoundToFloor(pos[1] / SPATIAL_CELL_SIZE);
    int cz = RoundToFloor(pos[2] / SPATIAL_CELL_SIZE);

    float maxDistSq = maxDist * maxDist;

    for (int dx = -checkRange; dx <= checkRange; dx++)
    {
        for (int dy = -checkRange; dy <= checkRange; dy++)
        {
            for (int dz = -checkRange; dz <= checkRange; dz++)
            {
                char key[32];
                Format(key, sizeof(key), "%d_%d_%d", cx + dx, cy + dy, cz + dz);

                ArrayList cellList;
                if (!g_hSpatialHash.GetValue(key, cellList)) continue;

                int count = cellList.Length;
                for (int i = 0; i < count; i += 2) // stride 2: {int, float[3]}
                {
                    int areaInt = cellList.Get(i);
                    float areaCenter[3];
                    cellList.GetArray(i + 1, areaCenter, 3);

                    float distSq = GetVectorDistance(pos, areaCenter, true);
                    if (distSq <= maxDistSq)
                        result.Push(areaInt);
                }
            }
        }
    }
}

// ============================================================================
// Physics-based Jump Validation — replaces hardcoded thresholds with actual
// trajectory traces using the PlayerCaps capability model.
// ============================================================================

// Validate a jump arc between two points by tracing a parabolic trajectory.
// Uses 10-sample hull trace to verify the path is clear for a crouching player.

// ── Non-mesh connection detection ──
stock void DetectNonMeshConnections_Init()
{
    delete g_hNonMeshEdges;
    g_hNonMeshEdges = new ArrayList(sizeof(NonMeshEdge));
    g_iNonMeshI = 0;
    if (g_hNonMeshNearby == null)
        g_hNonMeshNearby = new ArrayList();
}

// Returns true when detection is complete
stock bool DetectNonMeshConnections_Frame()
{
    if (g_hAStarNodes == null || g_hAStarCenters == null)
    {
        LogMessage("[PTG] DetectNonMesh: nodes not built yet");
        return true;
    }

    float t = GetEngineTime();
    int nodeCount = g_hAStarNodes.Length;
    int processed = 0;

    while (g_iNonMeshI < nodeCount)
    {
        if (processed >= 150 && ((GetEngineTime() - t) * 1000.0) > g_hCvarBudget.FloatValue)
            return false; // continue next frame

        int areaInt = g_hAStarNodes.Get(g_iNonMeshI);
        float center[3];
        g_hAStarCenters.GetArray(g_iNonMeshI, center, 3);

        // Query nearby areas via spatial hash
        SpatialHash_Query(center, g_hNonMeshNearby, 320.0, 1);

        // Track area attributes (for crouch/jump/breakable detection)
        Address areaAddr = view_as<Address>(areaInt);
        int attrs = (elevator_available) ? L4D_GetNavArea_AttributeFlags(areaAddr) : 0;
        bool crouchArea = (attrs & NAV_BASE_CROUCH) != 0;
        bool noJumpArea = (attrs & NAV_BASE_NO_JUMP) != 0;
        bool breakableArea = (attrs & NAV_BASE_BREAKABLEWALL) != 0;

        for (int j = 0; j < g_hNonMeshNearby.Length; j++)
        {
            int otherInt = g_hNonMeshNearby.Get(j);
            if (otherInt == areaInt) continue;

            // Skip if already connected via nav mesh
            if (navArea_connected(areaAddr, view_as<Address>(otherInt))) continue;

            // Find other area's node index
            char key[16];
            IntToString(otherInt, key, sizeof(key));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(key, otherIdx)) continue;

            float otherCenter[3];
            g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);

            float dz = otherCenter[2] - center[2];
            float dzAbs = FloatAbs(dz);
            float xyDist = GetVectorDistance(center, otherCenter, false);

            Address otherAddr = view_as<Address>(otherInt);
            int otherAttrs = (elevator_available) ? L4D_GetNavArea_AttributeFlags(otherAddr) : 0;
            bool otherCrouch = (otherAttrs & NAV_BASE_CROUCH) != 0;
            bool otherNoJump = (otherAttrs & NAV_BASE_NO_JUMP) != 0;
            bool otherBreakable = (otherAttrs & NAV_BASE_BREAKABLEWALL) != 0;

            NonMeshEdge edge;
            edge.fromArea = areaInt;
            edge.toArea = otherInt;
            bool detected = false;

            // --- JUMP_UP: jump from lower to higher (PlayerCaps validated) ---
            if (!detected && !noJumpArea && !otherNoJump
                && dz >= g_Caps.max_step_up && dz <= g_Caps.max_jump_height
                && xyDist < 80.0)
            {
                if (ValidateJumpArc(center, otherCenter, g_Caps))
                {
                    edge.edgeType = CONNECTED_JUMP_UP;
                    detected = true;
                }
            }

            // --- JUMP_DOWN: safe drop from higher to lower (PlayerCaps validated) ---
            // v4.1: Added vertical trace validation to prevent window-jump paths.
            // ValidateDropArc checks the parabolic clearance but doesn't verify
            // whether there's solid ground below the departure point. On C1M1,
            // this created JUMP_DOWN edges from hotel interior areas (near windows)
            // to outdoor street-level areas — the arc was clear (through the window
            // gap) but the drop would require jumping through a window.
            // The vertical trace catches this: if the ray from center downward
            // hits nothing, the area has no floor below → window/ledge gap.
            if (!detected && !noJumpArea && !otherNoJump
                && dz <= -g_Caps.max_step_up && dz >= -g_Caps.max_safe_drop
                && xyDist < 150.0)
            {
                if (ValidateDropArc(center, otherCenter, g_Caps))
                {
                    // Trace vertically from departure point to landing Z.
                    // If trace hits world geometry, there is solid floor/ground
                    // below the departure area — valid drop (ledge, balcony, etc.).
                    // If trace passes through empty space, the departure area has
                    // no floor beneath it (window gap, narrow walkway edge) —
                    // mark as CONDITIONAL (cost 25.0, only used when no alternative).
                    float vStart[3], vEnd[3];
                    vStart = center; vStart[2] -= 4.0;
                    vEnd[0] = center[0];
                    vEnd[1] = center[1];
                    vEnd[2] = otherCenter[2] + 8.0;

                    TR_TraceRayFilter(vStart, vEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                    if (TR_DidHit())
                    {
                        edge.edgeType = CONNECTED_JUMP_DOWN;
                    }
                    else
                    {
                        edge.edgeType = CONNECTED_CONDITIONAL;
                    }
                    detected = true;
                }
            }

            // --- STEP_DOWN: small step down ---
            if (!detected && dz >= -72.0 && dz <= -32.0 && xyDist < 80.0)
            {
                float sdStart[3], sdEnd[3];
                sdStart = center; sdStart[2] -= 2.0;
                sdEnd = center; sdEnd[2] = otherCenter[2] + 8.0;

                float slimMins[3] = {-8.0, -8.0, 1.0};
                float slimMaxs[3] = { 8.0,  8.0, 36.0};
                if (TryHull(sdStart, sdEnd, slimMins, slimMaxs))
                {
                    edge.edgeType = CONNECTED_STEP_DOWN;
                    detected = true;
                }
            }

            // --- VAULT: mantle over waist-high obstacle (PlayerCaps validated) ---
            if (!detected && dzAbs >= 40.0 && dzAbs <= g_Caps.max_vault_height && xyDist < 72.0)
            {
                float vaultZ = (center[2] > otherCenter[2] ? center[2] : otherCenter[2]) + 10.0;
                float vs[3], ve[3];
                vs = center; vs[2] = vaultZ;
                ve = otherCenter; ve[2] = vaultZ;

                float lowMins[3] = {-10.0, -10.0, 0.0};
                float lowMaxs[3] = { 10.0,  10.0, 32.0};
                if (TryHull(vs, ve, lowMins, lowMaxs))
                {
                    edge.edgeType = CONNECTED_VAULT;
                    detected = true;
                }
            }

            // --- GAP_JUMP: horizontal running jump across a gap (PlayerCaps validated) ---
            if (!detected && dzAbs < g_Caps.max_step_up * 2.0
                && xyDist >= 80.0 && xyDist <= g_Caps.max_gap_jump
                && !noJumpArea && !otherNoJump)
            {
                // Verify it's a real gap (no ground at midpoint)
                float mid[3];
                mid[0] = (center[0] + otherCenter[0]) / 2.0;
                mid[1] = (center[1] + otherCenter[1]) / 2.0;
                mid[2] = (center[2] + otherCenter[2]) / 2.0;

                float midDown[3];
                midDown = mid; midDown[2] -= 200.0;
                TR_TraceRayFilter(mid, midDown, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                bool noGround = !TR_DidHit();

                if (noGround && ValidateJumpArc(center, otherCenter, g_Caps))
                {
                    edge.edgeType = CONNECTED_GAP_JUMP;
                    detected = true;
                }
            }

            // --- CROUCH: passage that requires crouching ---
            if (!detected && dzAbs < 40.0 && xyDist < 256.0 && (crouchArea || otherCrouch))
            {
                float cs[3], ce[3];
                cs = center; cs[2] += 16.0;
                ce = otherCenter; ce[2] += 16.0;

                float lowMins[3] = {-10.0, -10.0, 0.0};
                float lowMaxs[3] = { 10.0,  10.0, 36.0};
                if (TryHull(cs, ce, lowMins, lowMaxs))
                {
                    edge.edgeType = CONNECTED_CROUCH;
                    detected = true;
                }
            }

            // --- BREAKABLE: wall that can be destroyed ---
            if (!detected && (breakableArea || otherBreakable))
            {
                edge.edgeType = CONNECTED_BREAKABLE;
                detected = true;
            }

            if (detected)
            {
                g_hNonMeshEdges.PushArray(edge, sizeof(NonMeshEdge));
            }
        }

        g_iNonMeshI++;
        processed++;
    }

    return true; // all done
}

// Get non-mesh connections FROM a given nav area. Fills conList with NavConnection.
stock int GetNonMeshConnections(int areaInt, ArrayList conList)
{
    conList.Clear();
    if (!g_hCvarNonMesh.BoolValue) return 0;
    if (g_hNonMeshEdges == null) return 0;

    int count = g_hNonMeshEdges.Length;
    NavConnection nc;
    for (int i = 0; i < count; i++)
    {
        NonMeshEdge edge;
        g_hNonMeshEdges.GetArray(i, edge, sizeof(NonMeshEdge));
        if (edge.fromArea == areaInt)
        {
            nc.navArea = view_as<Address>(edge.toArea);
            nc.connectiontype = edge.edgeType;
            conList.PushArray(nc, sizeof(NavConnection));
        }
        else if (edge.edgeType != CONNECTED_JUMP_UP
              && edge.edgeType != CONNECTED_JUMP_DOWN
              && edge.edgeType != CONNECTED_STEP_DOWN
              && edge.fromArea != areaInt
              && edge.toArea == areaInt)
        {
            // Bidirectional non-mesh edge: add reverse direction
            nc.navArea = view_as<Address>(edge.fromArea);
            nc.connectiontype = edge.edgeType;
            conList.PushArray(nc, sizeof(NavConnection));
        }
    }
    return conList.Length;
}

// ============================================================================
// A* Pathfinding Engine
// ============================================================================

// v4.0 Heuristic — Euclidean dominant, flow as tie-breaker.
//
// Previous versions (v3.0) used flow as the dominant heuristic term (80% weight).
// This worked well on official maps but broke on third-party maps where:
//   - Flow is non-monotonic (U-shaped paths, spiral staircases)
//   - Flow overestimates due to nav mesh gaps/overlaps
//   - The goal area is in a disconnected nav mesh component
//
// v4.0 formula: h = euclidean * 1.15 + flow_tiebreaker * flow_weight
// where flow_weight defaults to 0.25 (configurable via l4d_path_to_goal_flow_weight).
// Flow is now a tie-breaker — it helps A* prefer the escape direction without
// overcommitting to flow-optimal-but-geometrically-wrong paths.
//
// The 1.15× Euclidean is still admissible: the shortest path between two points
// in an irregular nav mesh is at most ~1.08× Euclidean in the worst case
// (8-direction grid), and 1.15 gives a safety margin while staying tight enough
// to avoid excessive node expansion.

// ── A* engine core ──
stock float AStar_Heuristic(int nodeIndex)
{
    float center[3], goalCenter[3];
    g_hAStarCenters.GetArray(nodeIndex, center, 3);
    g_hAStarCenters.GetArray(g_iAStarGoalIndex, goalCenter, 3);

    // v4.1: Z-weighted distance — decomposes Euclidean into XY and Z components.
    // Matches AStar_EdgeCost structure (flatDist + |dz| * zFactor) so the
    // heuristic accurately reflects the edge cost model. This makes A* deprioritize
    // exploring nodes on different Z-levels from the goal.
    // Without this, Euclidean treats Z=XY — a node at (0,0,100) has the same
    // heuristic distance to (0,0,0) as one at (100,0,0), even though climbing
    // 100u costs 4× more than walking 100u in the edge cost model.
    float dx = center[0] - goalCenter[0];
    float dy = center[1] - goalCenter[1];
    float dz = FloatAbs(center[2] - goalCenter[2]);
    float dxy = SquareRoot(dx * dx + dy * dy);
    float zFactor = (g_hCvarZCostFactor != null) ? g_hCvarZCostFactor.FloatValue : 4.0;
    float baseDist = dxy + dz * zFactor;
    float h = baseDist * 1.15; // tight admissible bound

    // Flow tie-breaker: only when flow data is valid and weight is positive
    float flowWeight = (g_hCvarFlowWeight != null) ? g_hCvarFlowWeight.FloatValue : 0.25;

    if (g_fMaxFlow > 0.0 && flowWeight > 0.001)
    {
        int areaInt = g_hAStarNodes.Get(nodeIndex);
        float areaFlow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(areaInt));
        float goalFlow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(g_hAStarNodes.Get(g_iAStarGoalIndex)));

        if (areaFlow > 0.0 && goalFlow > 0.0)
        {
            float flowRemaining = goalFlow - areaFlow;
            if (flowRemaining < 0.0) flowRemaining = 0.0;

            // Flow tie-breaker: clamp to avoid overriding spatial distance.
            // The tie-breaker should be at most half of baseDist so it
            // only discriminates between cells at similar Z-weighted distances.
            float tiebreaker = flowRemaining;
            if (tiebreaker > baseDist * 0.5)
                tiebreaker = baseDist * 0.5;

            // Weighted blend: Z-weighted base + flow tie-breaker
            h += tiebreaker * flowWeight;
        }
    }

    // v4.0: HPA* cluster heuristic boost for large maps
    if (g_iHPAClusterCount > 0 && g_hCvarHpaEnable != null && g_hCvarHpaEnable.BoolValue)
        h += HPA_ClusterHeuristic(nodeIndex, g_iAStarGoalIndex);

    return h;
}

// Edge cost: Euclidean distance weighted by connection type + vertical penalty.
// Without the Z penalty, A* treats climbing stairs the same as walking on flat
// ground (both have similar 3D distance ~90u), leading to paths that zigzag
// up/down through multi-floor buildings instead of following level ground.
// v4.0: Z_COST_FACTOR is now configurable via l4d_path_to_goal_z_cost_factor (default 4.0).
stock float AStar_EdgeCost(int fromIndex, int toIndex, ConnectionType conType)
{
    float c1[3], c2[3];
    g_hAStarCenters.GetArray(fromIndex, c1, 3);
    g_hAStarCenters.GetArray(toIndex, c2, 3);
    float dx = c2[0] - c1[0];
    float dy = c2[1] - c1[1];
    float dz = c2[2] - c1[2];
    float flatDist = SquareRoot(dx * dx + dy * dy);
    float absDz = FloatAbs(dz);
    // Horizontal cost (flat) + vertical cost (penalized) — keeps A* preferring
    // level paths and only climbing when geometrically necessary.
    float zFactor = (g_hCvarZCostFactor != null) ? g_hCvarZCostFactor.FloatValue : 4.0;
    float effectiveDist = flatDist + absDz * zFactor;
    return effectiveDist * GetConnectionCost(conType);
}

// Initialize A* state. Call once before starting search.
stock void AStar_Init()
{
    delete g_hAStarOpen;
    g_hAStarOpen = new ArrayList(sizeof(HeapEntry));

    int nodeCount = g_hAStarNodes.Length;

    delete g_hAStarGScore;
    g_hAStarGScore = new ArrayList(1);
    delete g_hAStarCameFrom;
    g_hAStarCameFrom = new ArrayList(1);
    delete g_hAStarEdgeType;
    g_hAStarEdgeType = new ArrayList(1);
    delete g_hAStarClosed;
    g_hAStarClosed = new ArrayList(1);

    float inf = 99999999.0; // large finite sentinel — SourcePawn view_as<float>(0x7F800000) yields 0
    for (int i = 0; i < nodeCount; i++)
    {
        g_hAStarGScore.Push(inf);
        g_hAStarCameFrom.Push(-1);
        g_hAStarEdgeType.Push(CONNECTED_NOT);
        g_hAStarClosed.Push(0);
    }

    g_bAStarPathFound = false;
    g_iAStarBestIdx = -1;
    g_fAStarBestG = -1.0;
}

// Set the start node. Call after AStar_Init.
stock void AStar_SetStart(int startIndex)
{
    g_hAStarGScore.Set(startIndex, 0.0);
    g_hAStarClosed.Set(startIndex, 0);
    float fScore = AStar_Heuristic(startIndex);
    Heap_Push(g_hAStarOpen, startIndex, fScore, 0.0);
}

// Process up to maxNodes nodes of A*. Returns:
//   1 = path found (reconstruct from cameFrom)
//   0 = still searching (continue next frame)
//  -1 = no path exists (open set empty)
stock int AStar_SearchFrame(int maxNodes)
{
    // Guard: bail if A* was not properly initialized (crashed Init, broken nav, third-party map)
    if (g_hAStarOpen == null || g_hAStarNodes == null)
        return -1;

    // Open set empty — all reachable nodes explored. If we have a best node
    // (always true after at least one frame of search), use it as effective goal.
    // This handles maps with disconnected nav mesh components.
    if (g_hAStarOpen.Length == 0)
    {
        if (g_iAStarBestIdx >= 0 && g_iAStarBestIdx != g_iAStarGoalIndex)
        {
            LogMessage("[PTG] A* exhausted open set. Using best reachable node %d (g=%.0f) as effective goal.",
                g_iAStarBestIdx, g_fAStarBestG);
            g_iAStarGoalIndex = g_iAStarBestIdx;
            g_bAStarPathFound = true;
            return 1;
        }
        return -1;
    }

    int processed = 0;
    HeapEntry entry;

    // Reusable arrays for connections
    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    while (processed < maxNodes && g_hAStarOpen.Length > 0)
    {
        // Pop best node, skip stale entries
        if (!Heap_Pop(g_hAStarOpen, entry))
            return -1;

        int currentIdx = entry.nodeIndex;

        // Skip if already closed
        if (g_hAStarClosed.Get(currentIdx) == 1)
            continue;

        // Skip stale entries (gScore changed since push)
        float currentG = g_hAStarGScore.Get(currentIdx);
        if (FloatAbs(entry.gScore - currentG) > 0.1)
            continue;

        // Goal reached?
        if (currentIdx == g_iAStarGoalIndex)
        {
            g_bAStarPathFound = true;
            g_hAStarClosed.Set(currentIdx, 1);
            return 1;
        }

        // Mark as closed
        g_hAStarClosed.Set(currentIdx, 1);

        // Track best reachable node (in case goal is in a disconnected nav mesh component)
        // Use gScore as the quality metric — higher gScore = farther from start along
        // the search direction (flow heuristic guides expansion toward the escape).
        if (currentG > g_fAStarBestG)
        {
            g_fAStarBestG = currentG;
            g_iAStarBestIdx = currentIdx;
        }

        // Get current area
        int areaInt = g_hAStarNodes.Get(currentIdx);
        Address areaAddr = view_as<Address>(areaInt);

        // --- Expand neighbors ---
        // CON_KEEP_ALL: explore connections in all directions. The flow-based
        // heuristic (fix #3) naturally prioritizes forward-going nodes, so we
        // don't need CON_KEEP_FORWARD to restrict the search — the heuristic
        // does the same job without risking pathfinding failures on nav meshes
        // where flow isn't perfectly monotonic.
        GetNavConnections(areaAddr, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        // Non-mesh connections
        GetNonMeshConnections(areaInt, AdjNN);
        // Merge AdjNN into ConAdj
        NavConnection nc;
        for (int i = 0; i < AdjNN.Length; i++)
        {
            AdjNN.GetArray(i, nc, sizeof(NavConnection));
            ConAdj.PushArray(nc, sizeof(NavConnection));
        }

        for (int i = 0; i < ConAdj.Length; i++)
        {
            ConAdj.GetArray(i, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int neighborInt = view_as<int>(nc.navArea);

            // Find neighbor's nodeIndex
            char key[16];
            IntToString(neighborInt, key, sizeof(key));
            int neighborIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(key, neighborIdx)) continue;

            // Skip if closed
            if (g_hAStarClosed.Get(neighborIdx) == 1) continue;

            // Check if blocked (unless breakable or conditional)
            if (nc.connectiontype != CONNECTED_BREAKABLE && nc.connectiontype != CONNECTED_CONDITIONAL)
            {
                if (blocked_available && L4D_NavArea_IsBlocked(nc.navArea, TEAM_SURVIVOR, true))
                    continue;
            }

            // v4.0 Theta*: check parent-LOS for any-angle shortcuts during search.
            // If parent(current) has LOS to neighbor AND the direct path is shorter,
            // bypass current entirely — produces smoother paths with fewer waypoints.
            bool thetaUsed = false;
            int cameFrom = currentIdx;
            float tentativeG;
            if (g_hCvarThetaStar != null && g_hCvarThetaStar.BoolValue)
            {
                int parentIdx = g_hAStarCameFrom.Get(currentIdx);
                if (parentIdx >= 0 && parentIdx < g_hAStarNodes.Length)
                {
                    float pCenter[3], nCenter[3];
                    g_hAStarCenters.GetArray(parentIdx, pCenter, 3);
                    g_hAStarCenters.GetArray(neighborIdx, nCenter, 3);
                    float losDist = GetVectorDistance(pCenter, nCenter, false);
                    float losMax = (g_hCvarThetaLosMax != null) ? g_hCvarThetaLosMax.FloatValue : 1500.0;
                    if (losDist <= losMax && twopos_traversable(pCenter, nCenter))
                    {
                        float parentGScore = g_hAStarGScore.Get(parentIdx);
                        float directG = parentGScore + AStar_EdgeCost(parentIdx, neighborIdx, CONNECTED_ADJACENT);
                        float viaCurrentG = currentG + AStar_EdgeCost(currentIdx, neighborIdx, nc.connectiontype);
                        if (directG < viaCurrentG)
                        {
                            tentativeG = directG;
                            cameFrom = parentIdx;
                            thetaUsed = true;
                        }
                    }
                }
            }
            if (!thetaUsed)
            {
                tentativeG = currentG + AStar_EdgeCost(currentIdx, neighborIdx, nc.connectiontype);
                cameFrom = currentIdx;
            }

            float neighborG = g_hAStarGScore.Get(neighborIdx);
            if (tentativeG < neighborG)
            {
                g_hAStarGScore.Set(neighborIdx, tentativeG);
                g_hAStarCameFrom.Set(neighborIdx, cameFrom);
                g_hAStarEdgeType.Set(neighborIdx, view_as<int>(nc.connectiontype));

                float fScore = tentativeG + AStar_Heuristic(neighborIdx);
                Heap_Push(g_hAStarOpen, neighborIdx, fScore, tentativeG);

                // Goal reached — will be popped and detected next frame
            }
        }

        processed++;
    }

    if (g_hAStarOpen.Length == 0)
    {
        // Goal unreachable — nav mesh is in disconnected components.
        // Use the best reachable node (farthest along the search direction)
        // as the effective goal. The path will guide players as far as
        // possible toward the escape direction.
        if (g_iAStarBestIdx >= 0 && g_iAStarBestIdx != g_iAStarGoalIndex)
        {
            LogMessage("[PTG] A* goal unreachable (disconnected nav mesh). Using best reachable node %d (g=%.0f) as effective goal.",
                g_iAStarBestIdx, g_fAStarBestG);
            g_iAStarGoalIndex = g_iAStarBestIdx;
            g_bAStarPathFound = true;
            return 1;
        }
        return -1;
    }

    return 0;
}

// 2D triangle signed area. Used by funnel algorithm for left/right checks.
// Returns: >0 if p is left of directed line a→b, <0 if right, 0 if collinear.
stock float TriArea2D(const float a[3], const float b[3], const float p[3])
{
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

// Reconstruct path from cameFrom chain, output portal-centered waypoints.
// v4.0: portal-based waypoints + funnel string pulling (replaces LOS smoothing)
stock void AStar_ReconstructPath(ArrayList outCells)
{
    outCells.Clear();
    if (!g_bAStarPathFound) return;

    // Walk backwards from goal to start
    ArrayList reversePath = new ArrayList(2);
    int maxSteps = g_hAStarNodes.Length + 1;
    int currentIdx = g_iAStarGoalIndex;
    int steps = 0;
    while (currentIdx >= 0 && steps < maxSteps)
    {
        if (currentIdx >= g_hAStarNodes.Length) break;
        int edgeType = g_hAStarEdgeType.Get(currentIdx);
        reversePath.Push(currentIdx);
        reversePath.Push(edgeType);
        currentIdx = g_hAStarCameFrom.Get(currentIdx);
        steps++;
    }
    if (steps >= maxSteps)
    {
        LogMessage("[PTG] A* reconstruct aborted: path too long (cycle detected)");
        delete reversePath;
        return;
    }

    // Build forward-order nodeIndex list (start → goal)
    ArrayList nodePath = new ArrayList();
    for (int i = reversePath.Length - 2; i >= 0; i -= 2)
        nodePath.Push(reversePath.Get(i));
    delete reversePath;

    int pathLen = nodePath.Length;
    if (pathLen < 2)
    {
        delete nodePath;
        return;
    }

    // Direct conversion: each nav area center → guide cell.
    // SSFA funnel disabled — geometric portal endpoints (midpoint of centers +
    // perpendicular segment) land on high ledges and outside air walls.
    // Accurate portal geometry requires L4D_NavArea_GetCorner, which does not
    // exist in left4dhooks v1.168.

    int firstIdx = nodePath.Get(0);
    int lastIdx = nodePath.Get(pathLen - 1);
    int firstAI = g_hAStarNodes.Get(firstIdx);
    int lastAI = g_hAStarNodes.Get(lastIdx);
    Address firstArea = view_as<Address>(firstAI);
    Address lastArea = view_as<Address>(lastAI);
    float startFlow = L4D2Direct_GetTerrorNavAreaFlow(firstArea);
    float goalFlow = L4D2Direct_GetTerrorNavAreaFlow(lastArea);
    if (startFlow <= 0.0) startFlow = 0.0;
    if (goalFlow <= 0.0) goalFlow = g_fMaxFlow;

    for (int ni = 0; ni < pathLen; ni++)
    {
        int idx = nodePath.Get(ni);
        int areaInt = g_hAStarNodes.Get(idx);

        Cell cell;
        cell.navArea = view_as<Address>(areaInt);
        g_hAStarCenters.GetArray(idx, cell.center, 3);

        // Ground snap: nav area center Z is the area's average height, not
        // the actual walkable floor. Trace down to find the real surface.
        // v4.4: widened trace range (100 up / 300 down) for steep slopes
        // and multi-story buildings. Add +2 fudge after hit to stay above
        // the surface so beams don't embed in slight floor undulations.
        float traceStart[3], traceEnd[3], traceHit[3];
        traceStart[0] = cell.center[0];
        traceStart[1] = cell.center[1];
        traceStart[2] = cell.center[2] + 100.0;
        traceEnd[0] = cell.center[0];
        traceEnd[1] = cell.center[1];
        traceEnd[2] = cell.center[2] - 300.0;
        TR_TraceRayFilter(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
        if (TR_DidHit())
        {
            TR_GetEndPosition(traceHit);
            cell.center[2] = traceHit[2] + 2.0; // +2 above floor surface
        }

        cell.flow = startFlow + (goalFlow - startFlow) * (float(ni) / float(pathLen - 1));
        outCells.PushArray(cell, sizeof(Cell));
    }

    delete nodePath;

    // --- Validation pass: hull trace every edge ---
    if (outCells.Length >= 2)
    {
        for (int i = 1; i < outCells.Length; i++)
        {
            Cell c1, c2;
            outCells.GetArray(i - 1, c1, sizeof(Cell));
            outCells.GetArray(i, c2, sizeof(Cell));

            if (!twopos_traversable(c1.center, c2.center))
            {
                float lifted[3];
                lifted[0] = c2.center[0];
                lifted[1] = c2.center[1];
                lifted[2] = c2.center[2] + 24.0;
                if (twopos_traversable(c1.center, lifted))
                {
                    c2.center[0] = lifted[0];
                    c2.center[1] = lifted[1];
                    c2.center[2] = lifted[2];
                    outCells.SetArray(i, c2, sizeof(Cell));
                }
            }
        }
    }
}

stock int AStar_IdentifyStart()
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length == 0) return -1;

    int bestIdx = -1;
    float bestFlow = g_fMaxFlow + 1.0;
    bool foundPlayerStart = false;

    for (int i = 0; i < g_hAStarNodes.Length; i++)
    {
        int areaInt = g_hAStarNodes.Get(i);
        Address area = view_as<Address>(areaInt);

        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        // Only filter by flow when valid flow data is available.
        // g_fMaxFlow=0 means no flow data on this map → skip filtering
        // so A* can identify start/goal via spatial heuristics alone.
        if (g_fMaxFlow > 0.0 && (flow < 0.0 || flow > g_fMaxFlow)) continue;

        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(area);
        bool isPlayerStart = (spawnAttrs & NAV_SPAWN_PLAYER_START) != 0;

        if (isPlayerStart && flow < bestFlow)
        {
            bestFlow = flow;
            bestIdx = i;
            foundPlayerStart = true;
        }
        else if (!foundPlayerStart && flow < bestFlow)
        {
            bestFlow = flow;
            bestIdx = i;
        }
    }

    return bestIdx;
}

// Identify the GOAL nav area for the escape path.
//
// v4.1 Priority (revised):
//   1. RESCUE_VEHICLE — unambiguous, always correct if present
//   2. Max-flow area VERIFIED reachable from start via BFS flood-fill
//      (fixes multi-story maps where farthest-Euclidean picks the wrong floor)
//   3. Farthest Euclidean among reachable areas at similar Z-level (±200u from start)
//      (safety net for maps where flow is unreliable)
//   4. Farthest Euclidean overall (fallback for disconnected nav meshes)
//
// The old v4.0 Strategy 2 (farthest Euclidean) was broken on multi-story maps:
// on C1M1 (hotel), the farthest Euclidean point from the street-level spawn is
// an upper-floor nav area, causing A* to path up stairs then jump out a window.
// Max-flow areas ARE the intended escape direction — we now verify reachability
// with a BFS instead of blindly trusting Euclidean distance.
stock int AStar_IdentifyGoal(int startIndex)
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length == 0) return -1;

    float startCenter[3];
    if (startIndex >= 0)
        g_hAStarCenters.GetArray(startIndex, startCenter, 3);

    int nodeCount = g_hAStarNodes.Length;

    // Strategy 1: RESCUE_VEHICLE area (unambiguous, always correct if present)
    for (int i = 0; i < nodeCount; i++)
    {
        int areaInt = g_hAStarNodes.Get(i);
        Address area = view_as<Address>(areaInt);
        int spawnAttrs = L4D_GetNavArea_SpawnAttributes(area);
        if ((spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE) && g_hCvarFinale.IntValue < FINALE_NEVER)
        {
            LogMessage("[PTG] A* goal: RESCUE_VEHICLE at index %d", i);
            return i;
        }
    }

    // Strategy 2: Max-flow area verified reachable from start via BFS.
    // This is the correct goal on ~95% of maps. Flow distances are monotonic
    // toward the escape — the max-flow area IS the evacuation destination.
    // We verify reachability so disconnected components (locked doors,
    // finale-only areas) don't produce unreachable goals.
    //
    // v4.4: Also track the farthest-spatial reachable node. When the reachable
    // set is very small (< BFS_FRAGMENTED_THRESHOLD nodes — fragmented nav mesh
    // on custom maze maps), use the farthest-spatial node instead of max-flow.
    // This ensures A* produces a multi-cell path spanning the full reachable
    // area instead of collapsing to a single area near the start.
    if (startIndex >= 0 && g_fMaxFlow > 0.0)
    {
        #define BFS_FRAGMENTED_THRESHOLD 100

        StringMap reachable = new StringMap();
        ArrayList bfsQueue = new ArrayList();
        bfsQueue.Push(startIndex);

        char rkey[16];
        IntToString(startIndex, rkey, sizeof(rkey));
        reachable.SetValue(rkey, 1);

        int bestFlowIdx = startIndex;
        float bestFlow = L4D2Direct_GetTerrorNavAreaFlow(
            view_as<Address>(g_hAStarNodes.Get(startIndex)));
        int bestDistIdx = startIndex;
        float bestDistSq = 0.0;

        float startC[3];
        g_hAStarCenters.GetArray(startIndex, startC, 3);

        int bfsLimit = 5000; // cap to prevent excessive iteration on giant maps

        if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));

        while (bfsQueue.Length > 0 && reachable.Size < bfsLimit)
        {
            int current = bfsQueue.Get(0);
            bfsQueue.Erase(0);

            int areaInt = g_hAStarNodes.Get(current);

            // Track max-flow reachable node
            float flow = L4D2Direct_GetTerrorNavAreaFlow(view_as<Address>(areaInt));
            if (flow > bestFlow)
            {
                bestFlow = flow;
                bestFlowIdx = current;
            }

            // Track farthest-spatial reachable node
            float center[3];
            g_hAStarCenters.GetArray(current, center, 3);
            float distSq = GetVectorDistance(startC, center, true);
            if (distSq > bestDistSq)
            {
                bestDistSq = distSq;
                bestDistIdx = current;
            }

            Address area = view_as<Address>(areaInt);
            GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

            for (int n = 0; n < ConAdj.Length && reachable.Size < bfsLimit; n++)
            {
                NavConnection nc;
                ConAdj.GetArray(n, nc, sizeof(NavConnection));
                if (nc.navArea == Address_Null) continue;

                int otherInt = view_as<int>(nc.navArea);
                char keyB[16];
                IntToString(otherInt, keyB, sizeof(keyB));
                int otherIdx = -1;
                if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

                IntToString(otherIdx, rkey, sizeof(rkey));
                if (reachable.ContainsKey(rkey)) continue;

                reachable.SetValue(rkey, 1);
                bfsQueue.Push(otherIdx);
            }
        }

        int bfsNodeCount = reachable.Size;
        delete bfsQueue;
        delete reachable;

        // Pick goal: farthest-spatial for fragmented meshes, max-flow for normal maps
        int chosenIdx;
        if (bfsNodeCount > 0 && bfsNodeCount < BFS_FRAGMENTED_THRESHOLD && bestDistIdx != bestFlowIdx)
        {
            chosenIdx = bestDistIdx;
            float gc[3];
            g_hAStarCenters.GetArray(chosenIdx, gc, 3);
            LogMessage("[PTG] A* goal: farthest reachable (fragmented nav, %d nodes) index %d (dist=%.0f, z=%.0f)",
                bfsNodeCount, chosenIdx, SquareRoot(bestDistSq), gc[2]);
        }
        else if (bestFlowIdx >= 0)
        {
            chosenIdx = bestFlowIdx;
            float gc[3];
            g_hAStarCenters.GetArray(chosenIdx, gc, 3);
            LogMessage("[PTG] A* goal: max-flow reachable index %d (flow=%.1f, z=%.0f, bfs_nodes=%d)",
                chosenIdx, bestFlow, gc[2], bfsNodeCount);
        }
        else
        {
            chosenIdx = -1;
        }

        if (chosenIdx >= 0)
            return chosenIdx;
    }

    // Strategy 3: Farthest Euclidean among areas at similar Z-level (±200u).
    // On multi-story maps, filtering by Z ensures the goal stays on the same
    // floor as the start. 200u ≈ one building floor.
    // This is a safety net for maps where flow data is missing or corrupted.
    if (startIndex >= 0)
    {
        float startZ = startCenter[2];
        float zTolerance = 200.0;

        int farIdx = -1;
        float maxDist = -1.0;
        for (int i = 0; i < nodeCount; i++)
        {
            float center[3];
            g_hAStarCenters.GetArray(i, center, 3);

            // Filter by Z-level — skip areas on different floors
            if (FloatAbs(center[2] - startZ) > zTolerance) continue;

            float dist = GetVectorDistance(startCenter, center, true); // sq dist
            if (dist > maxDist)
            {
                maxDist = dist;
                farIdx = i;
            }
        }
        if (farIdx >= 0)
        {
            float fc[3];
            g_hAStarCenters.GetArray(farIdx, fc, 3);
            LogMessage("[PTG] A* goal: farthest Euclidean (Z-filtered ±%.0f) index %d (dist=%.0f, z=%.0f)",
                zTolerance, farIdx, SquareRoot(maxDist), fc[2]);
            return farIdx;
        }
    }

    // Strategy 4: Farthest Euclidean overall (last resort for disconnected nav meshes)
    if (startIndex >= 0)
    {
        int farIdx = -1;
        float maxDist = -1.0;
        for (int i = 0; i < nodeCount; i++)
        {
            float center[3];
            g_hAStarCenters.GetArray(i, center, 3);
            float dist = GetVectorDistance(startCenter, center, true); // sq dist
            if (dist > maxDist)
            {
                maxDist = dist;
                farIdx = i;
            }
        }
        if (farIdx >= 0)
        {
            LogMessage("[PTG] A* goal: farthest Euclidean (no filter) index %d (dist=%.0f) [last resort]",
                farIdx, SquareRoot(maxDist));
            return farIdx;
        }
    }

    return -1;
}

// ============================================================================
// Portal Computation — finds shared boundary edges between adjacent nav areas.
// Portal centers replace area centers as path waypoints, so beams pass through
// actual doorways and corridor junctions instead of diagonally through walls.
// ============================================================================


// ── Portal computation ──
stock void AStar_ComputePortals()
{
    delete g_hPortalCache;
    g_hPortalCache = new StringMap();

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    int nodeCount = g_hAStarNodes.Length;
    char key[32];
    float cornersA[4][3], cornersB[4][3];

    for (int i = 0; i < nodeCount; i++)
    {
        int areaIntA = g_hAStarNodes.Get(i);
        Address areaA = view_as<Address>(areaIntA);
        if (areaA == Address_Null) continue;

        // Get corners of area A — required for accurate portal detection

        GetNavConnections(areaA, ConAdj, TEAM_SURVIVOR, true, false, false, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null || nc.navArea == areaA) continue;

            int areaIntB = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(areaIntB, keyB, sizeof(keyB));
            int j = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, j)) continue;

            int minI = (i < j) ? i : j;
            int maxI = (i < j) ? j : i;
            Format(key, sizeof(key), "%d_%d", minI, maxI);

            if (g_hPortalCache.ContainsKey(key)) continue;

            // Portal from centers — L4D_NavArea_GetCorner does NOT exist in left4dhooks
            float cA[3], cB[3];
            g_hAStarCenters.GetArray(i, cA, 3);
            g_hAStarCenters.GetArray(j, cB, 3);

            PortalInfo portal;
            portal.center[0] = (cA[0] + cB[0]) / 2.0;
            portal.center[1] = (cA[1] + cB[1]) / 2.0;

            float dx = cB[0] - cA[0];
            float dy = cB[1] - cA[1];
            float dLen = SquareRoot(dx*dx + dy*dy);
            if (dLen < 1.0) dLen = 1.0;

            float px = -dy / dLen;
            float py =  dx / dLen;
            float halfWidth = 48.0;
            if (halfWidth > dLen * 0.4) halfWidth = dLen * 0.4;

            float zGround = (cA[2] > cB[2]) ? cA[2] : cB[2];
            portal.center[2] = zGround;
            portal.ep1[2] = zGround;
            portal.ep2[2] = zGround;

            portal.ep1[0] = portal.center[0] + px * halfWidth;
            portal.ep1[1] = portal.center[1] + py * halfWidth;
            portal.ep2[0] = portal.center[0] - px * halfWidth;
            portal.ep2[1] = portal.center[1] - py * halfWidth;

            g_hPortalCache.SetArray(key, portal, sizeof(PortalInfo));
        }
    }

    StringMapSnapshot snap = g_hPortalCache.Snapshot();
    LogMessage("[PTG] Portal cache built: %d portals for %d nav areas", snap.Length, nodeCount);
    delete snap;
}

// v4.0: Batched portal computation — processes count nav areas per call,
// starting from startIdx. Returns true if more areas remain.
// Called from STAGE_PREP phase 1 to avoid SIGALRM on large maps.
stock bool AStar_ComputePortalsBatch(int startIdx, int count)
{
    int nodeCount = g_hAStarNodes.Length;

    // First call: initialize the portal cache
    if (startIdx == 0)
    {
        delete g_hPortalCache;
        g_hPortalCache = new StringMap();
        LogMessage("[PTG] Portal batch starting: %d nav areas, %d per frame", nodeCount, count);
    }

    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    if (AdjNN == null) AdjNN = new ArrayList();

    char key[32];
    float cornersA[4][3], cornersB[4][3];
    int endIdx = startIdx + count;
    if (endIdx > nodeCount) endIdx = nodeCount;

    for (int i = startIdx; i < endIdx; i++)
    {
        int areaIntA = g_hAStarNodes.Get(i);
        Address areaA = view_as<Address>(areaIntA);
        if (areaA == Address_Null) continue;


        GetNavConnections(areaA, ConAdj, TEAM_SURVIVOR, true, false, false, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null || nc.navArea == areaA) continue;

            int areaIntB = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(areaIntB, keyB, sizeof(keyB));
            int j = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, j)) continue;

            int minI = (i < j) ? i : j;
            int maxI = (i < j) ? j : i;
            Format(key, sizeof(key), "%d_%d", minI, maxI);

            if (g_hPortalCache.ContainsKey(key)) continue;

            // Portal from centers — L4D_NavArea_GetCorner does NOT exist in left4dhooks
            // Compute portal geometrically: midpoint of centers + perpendicular segment
            float cA[3], cB[3];
            g_hAStarCenters.GetArray(i, cA, 3);
            g_hAStarCenters.GetArray(j, cB, 3);

            // Portal center = midpoint of nav area centers (at the shared boundary)
            PortalInfo portal;
            portal.center[0] = (cA[0] + cB[0]) / 2.0;
            portal.center[1] = (cA[1] + cB[1]) / 2.0;

            // Portal direction = perpendicular to AB connection (XY plane)
            float dx = cB[0] - cA[0];
            float dy = cB[1] - cA[1];
            float dLen = SquareRoot(dx*dx + dy*dy);
            if (dLen < 1.0) dLen = 1.0;

            float px = -dy / dLen;  // perpendicular X (rotate AB by 90°)
            float py =  dx / dLen;  // perpendicular Y

            // Portal half-width: 48u (~3ft doorway), capped to 40% of area distance
            float halfWidth = 48.0;
            if (halfWidth > dLen * 0.4) halfWidth = dLen * 0.4;

            // Z: use higher of the two areas (safe walkable height at +16 above ground)
            float zGround = (cA[2] > cB[2]) ? cA[2] : cB[2];
            portal.center[2] = zGround;
            portal.ep1[2] = zGround;
            portal.ep2[2] = zGround;

            portal.ep1[0] = portal.center[0] + px * halfWidth;
            portal.ep1[1] = portal.center[1] + py * halfWidth;
            portal.ep2[0] = portal.center[0] - px * halfWidth;
            portal.ep2[1] = portal.center[1] - py * halfWidth;

            g_hPortalCache.SetArray(key, portal, sizeof(PortalInfo));
        }
    }

    if (endIdx >= nodeCount)
    {
        StringMapSnapshot snap = g_hPortalCache.Snapshot();
        LogMessage("[PTG] Portal cache built: %d portals for %d nav areas (batched)", snap.Length, nodeCount);
        delete snap;
        return false; // done
    }
    return true; // more areas remain
}

// Build the node index from all nav areas. Call once per map load.

// ── AStar_BuildNodeIndex ──
stock void AStar_BuildNodeIndex()
{
    delete g_hAStarNodes;
    delete g_hAStarCenters;
    delete g_hAStarAreaToIndex;
    delete g_hSpatialHash;

    ArrayList areaList = new ArrayList();
    L4D_GetAllNavAreas(areaList);

    int count = areaList.Length;
    g_hAStarNodes = new ArrayList(1);
    g_hAStarCenters = new ArrayList(3);
    g_hAStarAreaToIndex = new StringMap();
    g_hSpatialHash = new StringMap();

    float center[3];
    char key[16];

    for (int i = 0; i < count; i++)
    {
        Address area = areaList.Get(i);
        if (area == Address_Null) continue;

        L4D_GetNavAreaCenter(area, center);
        center[2] += 16.0;
        if (pos_underwater(center))
        {
            center[2] += 16.0;
            if (pos_underwater(center)) center[2] += 16.0;
        }

        int areaInt = view_as<int>(area);
        g_hAStarNodes.Push(areaInt);
        g_hAStarCenters.PushArray(center, 3);

        IntToString(areaInt, key, sizeof(key));
        g_hAStarAreaToIndex.SetValue(key, i);

        // Spatial hash
        SpatialHash_Insert(center, areaInt);
    }

    delete areaList;

    // v4.0: Portal computation, HPA* clusters, and bridge detection are
    // now batched across frames via OnFramePrep sub-phases (g_iBuildPhase 1-3).
    // AStar_ComputePortalsBatch handles portals; HPA_BuildClusters and
    // DetectNavMeshBridges are called in phases 2-3 respectively.

    #if DEBUG
    LogMessage("[PTG] A* node index built: %d nav areas in spatial hash", count);
    #endif
}

// ============================================================================
// v4.0 HPA* — Hierarchical Pathfinding Acceleration
//
// Clusters nav areas by spatial hash at a coarser resolution (default 1024u).
// Computes cluster-level connectivity. The cluster-level distance is used as a
// secondary heuristic boost for maps with 5000+ nav areas where the A* open
// set can grow very large before converging.
// ============================================================================

StringMap g_hHPAClusters;       // "cx_cy_cz" → ArrayList of nodeIndices
ArrayList g_hHPAClusterCenters; // float[3] center for each cluster
ArrayList g_hHPAClusterNodes;   // ArrayList of nodeIndices per cluster
StringMap g_hHPAClusterAdj;     // "ci_cj" → 1 if clusters i and j are adjacent


// ── HPA* ──
stock void HPA_BuildClusters()
{
    // Clean inner ArrayLists to prevent handle leak
    if (g_hHPAClusterNodes != null)
    {
        for (int i = 0; i < g_hHPAClusterNodes.Length; i++)
        {
            int handle = g_hHPAClusterNodes.Get(i);
            ArrayList innerList = view_as<ArrayList>(handle);
            delete innerList;
        }
    }
    delete g_hHPAClusters;
    delete g_hHPAClusterCenters;
    delete g_hHPAClusterNodes;
    delete g_hHPAClusterAdj;

    g_hHPAClusters = new StringMap();
    g_hHPAClusterCenters = new ArrayList(3);
    g_hHPAClusterNodes = new ArrayList();
    g_hHPAClusterAdj = new StringMap();

    float cellSize = g_hCvarHpaCellSize != null ? g_hCvarHpaCellSize.FloatValue : 1024.0;
    int nodeCount = g_hAStarNodes.Length;
    StringMap clusterMap = new StringMap(); // key → clusterIndex

    // Pass 1: assign nodes to clusters
    for (int i = 0; i < nodeCount; i++)
    {
        float center[3];
        g_hAStarCenters.GetArray(i, center, 3);

        int cx = RoundToFloor(center[0] / cellSize);
        int cy = RoundToFloor(center[1] / cellSize);
        int cz = RoundToFloor(center[2] / cellSize);

        char key[32];
        Format(key, sizeof(key), "%d_%d_%d", cx, cy, cz);

        int clusterIdx = -1;
        if (!clusterMap.GetValue(key, clusterIdx))
        {
            clusterIdx = g_hHPAClusterCenters.Length / 3;
            g_hHPAClusterCenters.PushArray(center, 3);
            // Store nodeList handle as int inside g_hHPAClusterNodes
            ArrayList nodeList = new ArrayList();
            g_hHPAClusterNodes.Push(view_as<int>(nodeList));
            nodeList.Push(i);

            clusterMap.SetValue(key, clusterIdx);

            // Update cluster center as average
            float avg[3]; avg = center;
            g_hHPAClusterCenters.SetArray(clusterIdx, avg, 3);
        }
        else
        {
            int handle = g_hHPAClusterNodes.Get(clusterIdx);
            ArrayList nodeList = view_as<ArrayList>(handle);
            nodeList.Push(i);

            // Update running average for center
            float curCenter[3];
            g_hHPAClusterCenters.GetArray(clusterIdx, curCenter, 3);
            int n = nodeList.Length;
            curCenter[0] = (curCenter[0] * (n - 1) + center[0]) / n;
            curCenter[1] = (curCenter[1] * (n - 1) + center[1]) / n;
            curCenter[2] = (curCenter[2] * (n - 1) + center[2]) / n;
            g_hHPAClusterCenters.SetArray(clusterIdx, curCenter, 3);
        }
    }

    g_iHPAClusterCount = g_hHPAClusterCenters.Length / 3;

    // Pass 2: compute cluster adjacency by checking nav area connections
    if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
    for (int ci = 0; ci < g_iHPAClusterCount; ci++)
    {
        int nhandle = g_hHPAClusterNodes.Get(ci);
        ArrayList nodes = view_as<ArrayList>(nhandle);

        for (int ni = 0; ni < nodes.Length; ni++)
        {
            int nodeIdx = nodes.Get(ni);
            int areaInt = g_hAStarNodes.Get(nodeIdx);
            Address area = view_as<Address>(areaInt);

            GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

            for (int c = 0; c < ConAdj.Length; c++)
            {
                NavConnection nc;
                ConAdj.GetArray(c, nc, sizeof(NavConnection));
                if (nc.navArea == Address_Null) continue;

                int otherInt = view_as<int>(nc.navArea);
                char keyB[16];
                IntToString(otherInt, keyB, sizeof(keyB));
                int otherIdx = -1;
                if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

                // Find which cluster otherIdx belongs to
                float otherCenter[3];
                g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);
                int ocx = RoundToFloor(otherCenter[0] / cellSize);
                int ocy = RoundToFloor(otherCenter[1] / cellSize);
                int ocz = RoundToFloor(otherCenter[2] / cellSize);

                char okey[32];
                Format(okey, sizeof(okey), "%d_%d_%d", ocx, ocy, ocz);

                int cj = -1;
                if (clusterMap.GetValue(okey, cj) && cj != ci)
                {
                    char adjKey[16];
                    int minC = (ci < cj) ? ci : cj;
                    int maxC = (ci < cj) ? cj : ci;
                    Format(adjKey, sizeof(adjKey), "%d_%d", minC, maxC);
                    g_hHPAClusterAdj.SetValue(adjKey, 1);
                }
            }
        }
    }

    delete clusterMap;

    #if DEBUG
    LogMessage("[PTG] HPA*: %d clusters (cell=%.0f) for %d nav areas",
        g_iHPAClusterCount, cellSize, nodeCount);
    #endif
}

// HPA* heuristic boost: Euclidean distance between cluster centers.
// Used as a cheap upper-bound check: if two nodes are in clusters far apart,
// their direct connection is unlikely and A* should explore alternatives first.
stock float HPA_ClusterHeuristic(int fromIdx, int toIdx)
{
    if (g_iHPAClusterCount < 2) return 0.0;

    float fromCenter[3], toCenter[3];
    g_hAStarCenters.GetArray(fromIdx, fromCenter, 3);
    g_hAStarCenters.GetArray(toIdx, toCenter, 3);

    float cellSize = g_hCvarHpaCellSize != null ? g_hCvarHpaCellSize.FloatValue : 1024.0;
    int fcx = RoundToFloor(fromCenter[0] / cellSize);
    int fcy = RoundToFloor(fromCenter[1] / cellSize);
    int fcz = RoundToFloor(fromCenter[2] / cellSize);

    int tcx = RoundToFloor(toCenter[0] / cellSize);
    int tcy = RoundToFloor(toCenter[1] / cellSize);
    int tcz = RoundToFloor(toCenter[2] / cellSize);

    // Same cluster: no boost needed
    if (fcx == tcx && fcy == tcy && fcz == tcz) return 0.0;

    // Different clusters: add cluster-center distance as a mild boost
    // This helps A* prefer paths that make progress between clusters
    float fc[3], tc[3];
    fc[0] = (fcx + 0.5) * cellSize;
    fc[1] = (fcy + 0.5) * cellSize;
    fc[2] = (fcz + 0.5) * cellSize;
    tc[0] = (tcx + 0.5) * cellSize;
    tc[1] = (tcy + 0.5) * cellSize;
    tc[2] = (tcz + 0.5) * cellSize;

    return GetVectorDistance(fc, tc, false) * 0.05; // 5% boost — very mild
}

// ============================================================================
// v4.0 Nav Mesh Bridge Detection — cross-component connectivity
//
// On maps with disconnected nav mesh components (common in third-party maps),
// finds nearby but unconnected nav areas that a human player could traverse
// between (by jumping, dropping, or walking through an unmarked passage).
// These bridges are added as non-mesh edges so A* can find paths across
// component boundaries.
// ============================================================================


// ── DetectNavMeshBridges ──
stock void DetectNavMeshBridges()
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length < 2) return;

    int nodeCount = g_hAStarNodes.Length;
    int bridgesFound = 0;

    // Use a simple flood-fill from start to identify the primary component
    // Then for any area NOT in the primary component, look for nearby areas
    // in the primary component that a player could physically reach.

    // v4.0: Nav mesh bridge detection uses a StringMap-based reachability set
    // to avoid stack overflow on maps with 10K+ nav areas.
    // Key = nodeIndex as string, Value = 1 if reachable.
    int startIdx = AStar_IdentifyStart();
    if (startIdx < 0) return;

    // Use StringMap for O(1) lookup without stack allocation
    StringMap reachableMap = new StringMap();
    ArrayList bfsQueue = new ArrayList();
    bfsQueue.Push(startIdx);

    char rkey[16];
    IntToString(startIdx, rkey, sizeof(rkey));
    reachableMap.SetValue(rkey, 1);
    int reachableCount = 1;

    // Cap BFS at 5000 nodes to prevent excessive iteration
    int bfsLimit = 5000;
    while (bfsQueue.Length > 0 && reachableCount < bfsLimit)
    {
        int current = bfsQueue.Get(0);
        bfsQueue.Erase(0);

        int areaInt = g_hAStarNodes.Get(current);
        Address area = view_as<Address>(areaInt);

        if (ConAdj == null) ConAdj = new ArrayList(sizeof(NavConnection));
        GetNavConnections(area, ConAdj, TEAM_SURVIVOR, true, true, true, CON_KEEP_ALL);

        for (int n = 0; n < ConAdj.Length && reachableCount < bfsLimit; n++)
        {
            NavConnection nc;
            ConAdj.GetArray(n, nc, sizeof(NavConnection));
            if (nc.navArea == Address_Null) continue;

            int otherInt = view_as<int>(nc.navArea);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;

            IntToString(otherIdx, rkey, sizeof(rkey));
            if (reachableMap.ContainsKey(rkey)) continue;

            reachableMap.SetValue(rkey, 1);
            bfsQueue.Push(otherIdx);
            reachableCount++;
        }
    }

    delete bfsQueue;

    #if DEBUG
    LogMessage("[PTG] Bridge detection: %d/%d nodes reachable from start (%.1f%%)",
        reachableCount, nodeCount, (float(reachableCount) / nodeCount) * 100.0);
    #endif

    // If most nodes are reachable, bridges aren't needed
    if (reachableCount > nodeCount * 0.9 || reachableCount >= bfsLimit)
    {
        delete reachableMap;
        return;
    }

    // For each UNREACHABLE node, look for nearby REACHABLE nodes within
    // spatial proximity that could be traversed (jump/drop/walk gap).
    float bridgeMaxDist = 256.0; // max distance to search for bridge
    int unreachableScanned = 0;
    int unreachableLimit = 2000; // cap to avoid excessive processing

    for (int i = 0; i < nodeCount && unreachableScanned < unreachableLimit; i++)
    {
        IntToString(i, rkey, sizeof(rkey));
        if (reachableMap.ContainsKey(rkey)) continue;
        unreachableScanned++;

        float center[3];
        g_hAStarCenters.GetArray(i, center, 3);

        // Query spatial hash for nearby reachable nodes
        if (g_hNonMeshNearby == null) g_hNonMeshNearby = new ArrayList();
        SpatialHash_Query(center, g_hNonMeshNearby, bridgeMaxDist, 2);

        float bestDist = bridgeMaxDist * bridgeMaxDist + 1.0;
        int bestReachable = -1;
        ConnectionType bestType = CONNECTED_NOT;

        for (int j = 0; j < g_hNonMeshNearby.Length; j++)
        {
            int otherInt = g_hNonMeshNearby.Get(j);
            char keyB[16];
            IntToString(otherInt, keyB, sizeof(keyB));
            int otherIdx = -1;
            if (!g_hAStarAreaToIndex.GetValue(keyB, otherIdx)) continue;
            IntToString(otherIdx, rkey, sizeof(rkey));
            if (!reachableMap.ContainsKey(rkey)) continue;

            float otherCenter[3];
            g_hAStarCenters.GetArray(otherIdx, otherCenter, 3);

            float dz = otherCenter[2] - center[2];
            float dzAbs = FloatAbs(dz);
            float xyDist = GetVectorDistance(center, otherCenter, false);

            // Check if a player could traverse between these positions
            ConnectionType bridgeType = CONNECTED_NOT;

            // Drop down: unreachable is LOWER than reachable
            if (dz >= -g_Caps.max_safe_drop && dz <= -g_Caps.max_step_up && xyDist < 120.0)
            {
                if (ValidateDropArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_JUMP_DOWN;
            }
            // Jump up: unreachable is HIGHER than reachable
            else if (dz >= g_Caps.max_step_up && dz <= g_Caps.max_jump_height && xyDist < 80.0)
            {
                if (ValidateJumpArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_JUMP_UP;
            }
            // Horizontal gap jump
            else if (dzAbs < g_Caps.max_step_up * 2.0 && xyDist >= 80.0 && xyDist <= g_Caps.max_gap_jump)
            {
                float mid[3];
                mid[0] = (center[0] + otherCenter[0]) / 2.0;
                mid[1] = (center[1] + otherCenter[1]) / 2.0;
                mid[2] = (center[2] + otherCenter[2]) / 2.0;

                float midDown[3];
                midDown = mid; midDown[2] -= 200.0;
                TR_TraceRayFilter(mid, midDown, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                if (!TR_DidHit() && ValidateJumpArc(center, otherCenter, g_Caps))
                    bridgeType = CONNECTED_GAP_JUMP;
            }
            // Same level but close (nav mesh gap in floor)
            else if (dzAbs < 32.0 && xyDist < 64.0)
            {
                bridgeType = CONNECTED_ADJACENT;
            }

            if (bridgeType != CONNECTED_NOT)
            {
                float distSq = GetVectorDistance(center, otherCenter, true);
                if (distSq < bestDist)
                {
                    bestDist = distSq;
                    bestReachable = otherIdx;
                    bestType = bridgeType;
                }
            }
        }

        // Add bridge as non-mesh edge
        if (bestReachable >= 0 && bestType != CONNECTED_NOT)
        {
            int areaInt = g_hAStarNodes.Get(i);
            int otherAreaInt = g_hAStarNodes.Get(bestReachable);

            NonMeshEdge bridge;
            bridge.fromArea = areaInt;       // unreachable → reachable
            bridge.toArea = otherAreaInt;
            bridge.edgeType = bestType;

            if (g_hNonMeshEdges == null)
                g_hNonMeshEdges = new ArrayList(sizeof(NonMeshEdge));
            g_hNonMeshEdges.PushArray(bridge, sizeof(NonMeshEdge));

            // Also add reverse for bidirectional types
            if (bestType != CONNECTED_JUMP_UP && bestType != CONNECTED_JUMP_DOWN)
            {
                bridge.fromArea = otherAreaInt;
                bridge.toArea = areaInt;
                g_hNonMeshEdges.PushArray(bridge, sizeof(NonMeshEdge));
            }

            bridgesFound++;
        }
    }

    if (bridgesFound > 0)
    {
        LogMessage("[PTG] NavMeshBridge: %d cross-component bridges found (%d/%d nodes unreachable)",
            bridgesFound, nodeCount - reachableCount, nodeCount);
    }
    delete reachableMap;
}

// ============================================================================
// v4.0 3D Funnel Enhancement — Z-layer awareness
//
// Post-processes funnel waypoints to handle multi-floor transitions.
// When consecutive funnel waypoints have a large Z gap (> funnel_z_step),
// this function inserts intermediate guiding waypoints that trace a valid
// 3D path (vertical transitions, stair landings, elevator stops).
//
// Called from AStar_ReconstructPath after the 2D funnel completes.
// ============================================================================


// ── Funnel3D_InsertZTransitions ──
stock void Funnel3D_InsertZTransitions(ArrayList cells)
{
    if (cells == null || cells.Length < 2) return;
    if (g_hCvarFunnel3D == null || !g_hCvarFunnel3D.BoolValue) return;

    float zStep = g_hCvarFunnelZStep != null ? g_hCvarFunnelZStep.FloatValue : 80.0;

    // Build new cell list with Z transitions inserted
    ArrayList result = new ArrayList(sizeof(Cell));
    Cell prev; cells.GetArray(0, prev, sizeof(Cell));
    result.PushArray(prev, sizeof(Cell));

    for (int i = 1; i < cells.Length; i++)
    {
        Cell curr;
        cells.GetArray(i, curr, sizeof(Cell));

        float dz = curr.center[2] - prev.center[2];
        float dzAbs = FloatAbs(dz);

        if (dzAbs > zStep)
        {
            // Large Z gap — insert intermediate transition waypoints
            int steps = RoundToCeil(dzAbs / zStep);
            if (steps > 8) steps = 8; // cap to prevent excessive waypoints

            for (int s = 1; s < steps; s++)
            {
                float t = float(s) / float(steps);
                Cell mid;
                mid.navArea = Address_Null;
                mid.flow = prev.flow + (curr.flow - prev.flow) * t;
                mid.center[0] = prev.center[0] + (curr.center[0] - prev.center[0]) * t;
                mid.center[1] = prev.center[1] + (curr.center[1] - prev.center[1]) * t;
                mid.center[2] = prev.center[2] + (curr.center[2] - prev.center[2]) * t;

                // Try to snap intermediate Z to ground via trace
                float groundCheck[3];
                groundCheck = mid.center;
                groundCheck[2] -= 500.0;
                TR_TraceRayFilter(mid.center, groundCheck, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                if (TR_DidHit())
                {
                    float groundPos[3];
                    TR_GetEndPosition(groundPos);
                    mid.center[2] = groundPos[2] + 16.0;
                }

                result.PushArray(mid, sizeof(Cell));
            }
        }

        result.PushArray(curr, sizeof(Cell));
        prev = curr;
    }

    // Replace original cells with enhanced version
    cells.Clear();
    for (int i = 0; i < result.Length; i++)
    {
        Cell c;
        result.GetArray(i, c, sizeof(Cell));
        cells.PushArray(c, sizeof(Cell));
    }
    delete result;
}

///////////// SDK

