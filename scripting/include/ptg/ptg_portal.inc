// PTG Module: ptg_portal — shared-edge portal geometry + human-capability
// connection classification (v4.7)
//
// The guide's original defect: waypoints were nav-area CENTERS, so beams ran
// center-to-center chords — cutting through walls, floating over floors, and
// crossing multi-floor gaps. Additionally the engine's adjacency list includes
// jump links (cjump) that only BOTS can cross — L4D2 human players cannot jump,
// so those edges produced lines to unreachable ledges.
//
// left4dhooks (plugin build, v1.168+) exposes L4D_NavArea_GetCorner / GetZ at
// runtime — the exact portal geometry that ptg_astar.inc:873 claimed was
// missing. This module computes the real shared boundary between every pair of
// adjacent nav areas, classifies each pair by what a HUMAN can traverse, and
// feeds the result into:
//   - GetNavConnections (edge filter — the single entry point of the whole
//     A*/BFS/detour/stitch pipeline)
//   - waypoint generation (Portal_CellFromEdge — portal centers instead of
//     area centers)
//   - smoothing (string-pull + optional SSFA funnel)
//
// Include order: after ptg_utils.inc, before ptg_astar.inc. It only reads the
// caches here (no calls back into astar), so utils can consume the filter.
// SP VM discipline: every float[] lives at function scope; loops are
// frame-budgeted (see the SIGALRM history in ptg_astar Funnel3D comments).

// Corner cache row layout: 4 corners × 3 floats packed linearly.
#define PORTAL_STRIDE 12
#define PORTAL_Z_SENTINEL -9000.0  // L4D_NavArea_GetZ returns a large negative
                                   // outside the area polygon (finale.inc:603 precedent)

// ── Master gate ──
stock bool Portal_Active()
{
    if (!corner_available) return false;
    if (!g_bPortalReady) return false;
    if (g_hCvarPortals == null || !g_hCvarPortals.BoolValue) return false;
    if (g_hCvarLegacyMode != null && g_hCvarLegacyMode.BoolValue) return false;
    return true;
}

// ── Build lifecycle ──
stock void Portal_InitBuild()
{
    g_bPortalReady = false;
    g_bPortalBuildFailed = false;
    delete g_hPortalCache;
    g_hPortalCache = new StringMap();
    delete g_hPortalExcluded;
    g_hPortalExcluded = new StringMap();
    delete g_hCornerCache;
    g_hCornerCache = new ArrayList(PORTAL_STRIDE);
    g_iPortalDiagNeighbors = 0;
    g_iPortalDiagLookupMiss = 0;
    g_iPortalDiagClassified = 0;
}

stock void Portal_Clear()
{
    g_bPortalReady = false;
    g_bPortalBuildFailed = false;
    g_bCoarseDrawn = false;
    delete g_hPortalExcluded;
    g_hPortalExcluded = null;
    delete g_hCornerCache;
    g_hCornerCache = null;
    delete g_hPullResult;
    g_hPullResult = null;
    delete g_hSSFAPortals;
    g_hSSFAPortals = null;
    delete g_hSSFAPath;
    g_hSSFAPath = null;
}

// Called once the batch build completes: publish the classification to the
// rest of the pipeline (Portal_Active flips on) and log the totals.
stock void Portal_FinishBuild()
{
    g_bPortalReady = true;
    int walkable = 0, excluded = 0;
    if (g_hPortalCache != null) walkable = g_hPortalCache.Size;
    if (g_hPortalExcluded != null) excluded = g_hPortalExcluded.Size;
    LogMessage("[PTG] Portal classification: %d walkable / %d excluded pairs (%d nav areas) — portal waypoints + human-capability edge filter active",
        walkable, excluded, (g_hAStarNodes != null) ? g_hAStarNodes.Length : 0);
    // v4.7.1 diagnostic counters — remove once the build is verified
    LogMessage("[PTG] Portal diag: enumerated=%d lookupMiss=%d classified=%d (cache=%d excluded=%d)",
        g_iPortalDiagNeighbors, g_iPortalDiagLookupMiss, g_iPortalDiagClassified, walkable, excluded);
}

// Cache the 4 corners of one nav area (4 GetCorner native calls).
stock void Portal_CacheCorners(int idx)
{
    if (g_hCornerCache == null || g_hAStarNodes == null) return;
    Address area = view_as<Address>(g_hAStarNodes.Get(idx));
    if (area == Address_Null)
    {
        float zero[PORTAL_STRIDE];
        g_hCornerCache.PushArray(zero, PORTAL_STRIDE);
        return;
    }
    float row[PORTAL_STRIDE];
    for (int c = 0; c < 4; c++)
    {
        float corner[3];
        L4D_NavArea_GetCorner(area, view_as<NavCornerType>(c), corner);
        row[c * 3 + 0] = corner[0];
        row[c * 3 + 1] = corner[1];
        row[c * 3 + 2] = corner[2];
    }
    g_hCornerCache.PushArray(row, PORTAL_STRIDE);
}

// Shared boundary between two convex quads. Picks the longest collinear
// overlapping edge pair (16 combinations). Returns false when the areas only
// touch at a corner or are separated by a gap (jump link).
stock bool Portal_SharedEdge(int fromIdx, int toIdx, PortalInfo p)
{
    if (g_hCornerCache == null) return false;
    float rowA[PORTAL_STRIDE], rowB[PORTAL_STRIDE];
    g_hCornerCache.GetArray(fromIdx, rowA, PORTAL_STRIDE);
    g_hCornerCache.GetArray(toIdx, rowB, PORTAL_STRIDE);

    float bestOverlap = -1.0;
    float bestEp1x, bestEp1y, bestEp2x, bestEp2y;
    float minOverlap = (g_hCvarPortalMinOverlap != null) ? g_hCvarPortalMinOverlap.FloatValue : 12.0;

    for (int iA = 0; iA < 4; iA++)
    {
        int iA2 = (iA + 1) % 4;
        float a0x = rowA[iA * 3 + 0], a0y = rowA[iA * 3 + 1];
        float a1x = rowA[iA2 * 3 + 0], a1y = rowA[iA2 * 3 + 1];
        float ax = a1x - a0x, ay = a1y - a0y;
        float len2 = ax * ax + ay * ay;
        if (len2 < 0.01) continue; // degenerate (zero-length) edge
        float invLen = 1.0 / SquareRoot(len2);
        float ux = ax * invLen, uy = ay * invLen; // unit direction of A edge

        for (int iB = 0; iB < 4; iB++)
        {
            int iB2 = (iB + 1) % 4;
            float b0x = rowB[iB * 3 + 0], b0y = rowB[iB * 3 + 1];
            float b1x = rowB[iB2 * 3 + 0], b1y = rowB[iB2 * 3 + 1];

            // 1) parallel in XY: cross(unitA, B-dir) ~ 0
            float bdx = b1x - b0x, bdy = b1y - b0y;
            float bLen = SquareRoot(bdx * bdx + bdy * bdy);
            if (bLen < 0.01) continue;
            float crossU = ux * bdy - uy * bdx;
            if (FloatAbs(crossU) > 0.1 * bLen) continue;

            // 2) collinear: distance from B0 to the A line ~ 0
            float dx = b0x - a0x, dy = b0y - a0y;
            float crossD = ux * dy - uy * dx;
            if (FloatAbs(crossD) > 2.0) continue;

            // 3) overlap along the shared axis
            float tA0 = 0.0, tA1 = SquareRoot(len2);
            float tB0 = dx * ux + dy * uy;
            float tB1 = tB0 + bdx * ux + bdy * uy;
            if (tB0 > tB1) { float t = tB0; tB0 = tB1; tB1 = t; }

            float lo = (tA0 > tB0) ? tA0 : tB0;
            float hi = (tA1 < tB1) ? tA1 : tB1;
            float overlap = hi - lo;
            if (overlap < minOverlap) continue;
            if (overlap <= bestOverlap) continue;

            bestOverlap = overlap;
            bestEp1x = a0x + ux * lo; bestEp1y = a0y + uy * lo;
            bestEp2x = a0x + ux * hi; bestEp2y = a0y + uy * hi;
        }
    }

    if (bestOverlap < 0.0) return false;

    p.ep1[0] = bestEp1x; p.ep1[1] = bestEp1y;
    p.ep2[0] = bestEp2x; p.ep2[1] = bestEp2y;
    p.center[0] = (bestEp1x + bestEp2x) * 0.5;
    p.center[1] = (bestEp1y + bestEp2y) * 0.5;

    // Z from the nav mesh at the portal XY (with out-of-polygon sentinel).
    Address a = view_as<Address>(g_hAStarNodes.Get(fromIdx));
    Address b = view_as<Address>(g_hAStarNodes.Get(toIdx));
    float zA = L4D_NavArea_GetZ(a, p.center);
    float zB = L4D_NavArea_GetZ(b, p.center);
    if (zA < PORTAL_Z_SENTINEL || zB < PORTAL_Z_SENTINEL)
    {
        // Portal center outside one polygon (weird geometry) — fall back to
        // the stored area centers.
        float cA[3], cB[3];
        g_hAStarCenters.GetArray(fromIdx, cA, 3);
        g_hAStarCenters.GetArray(toIdx, cB, 3);
        zA = cA[2]; zB = cB[2];
    }
    p.dz = zA - zB;              // positive = fromIdx higher (drop direction)
    p.center[2] = (zA > zB) ? zA : zB;
    p.ep1[2] = p.center[2];
    p.ep2[2] = p.center[2];
    return true;
}

// Ground-snap the portal center, clamped to ±20u of the portal Z so it can
// never sink onto a different floor (the Funnel3D interval rule).
stock void Portal_Snap(PortalInfo p)
{
    float zBefore = p.center[2];
    float zLo = zBefore - 20.0, zHi = zBefore + 20.0;

    float traceStart[3], traceEnd[3], traceHit[3];
    traceStart = p.center;
    traceStart[2] += 200.0;
    traceEnd = p.center;
    traceEnd[2] -= 800.0;
    TR_TraceRayFilter(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterWalkableStrict);
    if (TR_DidHit())
    {
        TR_GetEndPosition(traceHit);
        float zSnap = traceHit[2] + 2.0;
        if (zSnap >= zLo && zSnap <= zHi)
            p.center[2] = zSnap;
    }
    else
    {
        traceStart[2] = p.center[2] - 16.0;
        traceEnd[2] = p.center[2] + 128.0;
        TR_TraceRayFilter(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterWalkableStrict);
        if (TR_DidHit())
        {
            TR_GetEndPosition(traceHit);
            float zSnap = traceHit[2] + 2.0;
            if (zSnap >= zLo && zSnap <= zHi)
                p.center[2] = zSnap;
        }
    }
    p.ep1[2] = p.center[2];
    p.ep2[2] = p.center[2];
}

// Classify one adjacent pair (fromIdx < toIdx guaranteed by the caller) and
// write the caches. Two-way shared boundary = walkable; jumps humans cannot
// make = excluded; drops within safe fall height = one-way JUMP_DOWN.
stock void Portal_ClassifyPair(int fromIdx, int toIdx)
{
    if (g_hPortalCache == null || g_hPortalExcluded == null) return;

    PortalInfo p;
    bool shared = Portal_SharedEdge(fromIdx, toIdx, p);
    float dz = p.dz; // + = fromIdx higher

    float cA[3], cB[3];
    g_hAStarCenters.GetArray(fromIdx, cA, 3);
    g_hAStarCenters.GetArray(toIdx, cB, 3);
    if (!shared)
        dz = cA[2] - cB[2]; // no shared boundary — fall back to center heights

    char key[32];
    Format(key, sizeof(key), "%d_%d", fromIdx, toIdx);

    float portalMaxDz = (g_hCvarPortalMaxDz != null) ? g_hCvarPortalMaxDz.FloatValue : 48.0;

    if (shared && FloatAbs(dz) <= portalMaxDz)
    {
        // Real shared boundary, modest height delta — plain walking edge.
        p.connectiontype = CONNECTED_ADJACENT;
        p.walkable = true;
        Portal_Snap(p);
        g_hPortalCache.SetArray(key, p, sizeof(PortalInfo));
        return;
    }
    if (shared && dz > portalMaxDz && dz <= g_Caps.max_safe_drop)
    {
        // Shared edge but the far side drops — walking off is fine (one-way).
        p.connectiontype = CONNECTED_JUMP_DOWN;
        p.walkable = true;
        Portal_Snap(p);
        g_hPortalCache.SetArray(key, p, sizeof(PortalInfo));
        return;
    }
    if (shared && dz < -portalMaxDz && -dz <= g_Caps.max_vault_height)
    {
        // Climb up a tall step — humans can vault (mantle) up to vault height
        // if the ballistic arc is clear.
        if (ValidateJumpArc(cA, cB, g_Caps))
        {
            p.connectiontype = CONNECTED_VAULT;
            p.walkable = true;
            Portal_Snap(p);
            g_hPortalCache.SetArray(key, p, sizeof(PortalInfo));
            return;
        }
        g_hPortalExcluded.SetValue(key, 1); // no shared walkable way up
        return;
    }
    if (!shared && dz > 18.0 && dz <= g_Caps.max_safe_drop)
    {
        // No shared boundary (jump link / gap) but the far side is lower —
        // a drop humans can make, validated with the drop arc.
        if (ValidateDropArc(cA, cB, g_Caps))
        {
            p.connectiontype = CONNECTED_JUMP_DOWN;
            p.walkable = true;
            Portal_Snap(p);
            g_hPortalCache.SetArray(key, p, sizeof(PortalInfo));
            return;
        }
    }
    // Everything else: cjump up, flat gap jumps, deadly drops, windows.
    // L4D2 humans cannot jump — these are bot-only links.
    g_hPortalExcluded.SetValue(key, 1);
}

// Process one batch of areas: cache their corners, then classify every
// adjacent pair (j, i) with j < i (each pair handled exactly once, when the
// max-index area is processed). The cursor g_iPortalBatchIdx is owned HERE —
// a budget break mid-batch must not skip the tail, so the cursor only moves
// by the areas actually processed. Returns true when ALL areas are done.
stock bool Portal_ComputeBatch(int count)
{
    if (g_hAStarNodes == null || g_hAStarNodes.Length < 2)
        return true; // nothing to classify — caller advances

    // v4.8: soft rebuild — classification from the previous build is still
    // valid (same nav mesh). Skip the whole batch phase: re-enumerating
    // 18K+ adjacent pairs on large maps was ~1.3s of budgeted frames per
    // dirty rebuild.
    if (g_bPortalReady)
        return true;

    if (!corner_available)
    {
        g_bPortalBuildFailed = true;
        return true;
    }
    if (g_hCvarPortals == null || !g_hCvarPortals.BoolValue
        || (g_hCvarLegacyMode != null && g_hCvarLegacyMode.BoolValue))
    {
        g_bPortalBuildFailed = true;
        return true;
    }

    if (g_iPortalBatchIdx == 0)
        Portal_InitBuild();

    int nodeCount = g_hAStarNodes.Length;
    int endIdx = g_iPortalBatchIdx + count;
    if (endIdx > nodeCount) endIdx = nodeCount;

    float t0 = GetEngineTime();
    float maxMs = (g_hCvarBudget != null && g_hCvarBudget.FloatValue > 0.0)
        ? g_hCvarBudget.FloatValue : 0.5;

    // Reusable adjacency scratch (function scope — SP VM discipline).
    ArrayList adjScratch = new ArrayList();
    int areaInt = 0;
    Address areaAddr;
    int neighborInt = 0;
    int neighborIdx = 0;
    char key[16];
    int processedInBatch = 0; // v4.7.1: local counter — (i-cursor) was always -1

    for (int i = g_iPortalBatchIdx; i < endIdx; i++)
    {
        if (processedInBatch > 0 && processedInBatch % 25 == 0)
        {
            if ((GetEngineTime() - t0) * 1000.0 >= maxMs)
            {
                g_iPortalBatchIdx = i; // resume here next frame
                delete adjScratch;
                return false; // more areas remain
            }
        }

        Portal_CacheCorners(i);

        areaInt = g_hAStarNodes.Get(i);
        areaAddr = view_as<Address>(areaInt);
        if (areaAddr == Address_Null) continue;

        for (int dir = 0; dir < 4; dir++)
        {
            adjScratch.Clear();
            L4D_NavArea_GetAdjacentAreas(areaAddr, dir, adjScratch);
            g_iPortalDiagNeighbors += adjScratch.Length;
            for (int n = 0; n < adjScratch.Length; n++)
            {
                neighborInt = adjScratch.Get(n);
                if (neighborInt == 0 || neighborInt == areaInt) continue;
                IntToString(neighborInt, key, sizeof(key));
                if (!g_hAStarAreaToIndex.GetValue(key, neighborIdx))
                {
                    g_iPortalDiagLookupMiss++;
                    continue;
                }
                if (neighborIdx >= i) continue; // classified when the max index is processed
                Portal_ClassifyPair(neighborIdx, i);
                g_iPortalDiagClassified++;
            }
        }
        g_iPortalBatchIdx = i + 1;
        processedInBatch++;
    }
    delete adjScratch;
    // v4.7.2: the loop only ran `count` areas (endIdx = cursor + count), so a
    // clean loop exit does NOT mean the build is done. Declaring completion
    // here skipped every area past the first batch — on a fast machine the
    // first 100 areas finished inside the budget, g_iPortalBatchIdx jumped to
    // nodeCount, and 1152/1252 areas were never classified (diag showed
    // enumerated=310 classified=13 for a 1252-area map).
    if (g_iPortalBatchIdx < nodeCount)
        return false; // more areas remain — caller resumes next frame
    return true;
}

// Lookup helper shared by the edge filter and waypoint generation.
// Returns true when the pair was classified; walkable/conType describe it.
// Unclassified pairs (dynamic nav changes) pass through unfiltered.
stock bool Portal_GetForPair(int fromIdx, int toIdx, PortalInfo out, bool &walkable, ConnectionType &conType)
{
    walkable = true;
    conType = CONNECTED_ADJACENT;
    if (fromIdx < 0 || toIdx < 0) return false;
    int lo = fromIdx, hi = toIdx;
    if (lo > hi) { int t = lo; lo = hi; hi = t; }

    char key[32];
    Format(key, sizeof(key), "%d_%d", lo, hi);

    if (g_hPortalExcluded != null && g_hPortalExcluded.ContainsKey(key))
    {
        walkable = false;
        return true;
    }
    if (g_hPortalCache != null && g_hPortalCache.GetArray(key, out, sizeof(PortalInfo)))
    {
        walkable = out.walkable;
        conType = out.connectiontype;
        return true;
    }
    return false;
}

// Waypoint at the portal center of the fromIdx→idx edge (ground-snapped,
// Z-interval clamped). Fallback: the area center (unclassified/dynamic pair).
// The Cell keeps navArea = g_hAStarNodes.Get(idx) — every consumer keys on it.
stock void Portal_CellFromEdge(int prevIdx, int idx, Cell out)
{
    out.navArea = view_as<Address>(g_hAStarNodes.Get(idx));
    g_hAStarCenters.GetArray(idx, out.center, 3);
    out.jumpFlag = false;

    if (Portal_Active() && prevIdx >= 0)
    {
        PortalInfo p;
        bool walkable; ConnectionType conType;
        if (Portal_GetForPair(prevIdx, idx, p, walkable, conType))
        {
            out.center = p.center;
            if (p.connectiontype == CONNECTED_VAULT)
                out.jumpFlag = true; // drawer renders a vault arc
        }
    }

    // Ground snap (+2 above surface), clamped to ±20u of the waypoint Z so a
    // tall-floor portal can never snap onto a different floor.
    float zBefore = out.center[2];
    float zLo = zBefore - 20.0, zHi = zBefore + 20.0;
    float traceStart[3], traceEnd[3], traceHit[3];
    traceStart = out.center;
    traceStart[2] += 200.0;
    traceEnd = out.center;
    traceEnd[2] -= 800.0;
    TR_TraceRayFilter(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterWalkableStrict);
    if (TR_DidHit())
    {
        TR_GetEndPosition(traceHit);
        float zSnap = traceHit[2] + 2.0;
        if (zSnap >= zLo && zSnap <= zHi)
            out.center[2] = zSnap;
    }
    else
    {
        traceStart[2] = out.center[2] - 16.0;
        traceEnd[2] = out.center[2] + 128.0;
        TR_TraceRayFilter(traceStart, traceEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterWalkableStrict);
        if (TR_DidHit())
        {
            TR_GetEndPosition(traceHit);
            float zSnap = traceHit[2] + 2.0;
            if (zSnap >= zLo && zSnap <= zHi)
                out.center[2] = zSnap;
        }
    }
}

// ── Multi-hop string-pulling ──
// Greedy shortcut reduction over the portal polyline: keep an anchor and
// extend as far as a walkable shortcut reaches; commit the previous cell when
// the extension fails. Same acceptance rules as STAGE_VALIDATE's erase
// (triple_valid_ground + twopos_traversable + |dz| <= 50) but multi-hop, so
// long straight corridors collapse to a single beam.
stock bool Portal_StringPull_Init(ArrayList cells)
{
    delete g_hPullResult;
    g_hPullResult = null;
    g_iPullJ = 0;
    g_iPullAnchor = 0;
    g_iPullLastSrc = 0;
    if (g_hCvarStringPull == null || !g_hCvarStringPull.BoolValue) return false;
    if (cells == null || cells.Length < 3) return false;
    g_hPullResult = new ArrayList(sizeof(Cell));
    Cell first;
    cells.GetArray(0, first, sizeof(Cell));
    g_hPullResult.PushArray(first, sizeof(Cell));
    g_iPullJ = 1;
    g_iPullAnchor = 0;      // index into g_hPullResult
    g_iPullLastSrc = 0;     // source index of the last committed cell
    return true;
}

// Returns true when done. On completion g_GuideCells is replaced by the
// reduced polyline (the pipeline owns the list during STAGE_SMOOTH).
stock bool Portal_StringPull_Frame(ArrayList cells)
{
    if (g_hPullResult == null) return true;
    int srcLen = cells.Length;
    int processed = 0;
    float budgetMs = (g_hCvarBudget != null && g_hCvarBudget.FloatValue > 0.0)
        ? g_hCvarBudget.FloatValue : 0.5;

    while (g_iPullJ < srcLen && processed < EDGES_PER_FRAME)
    {
        if (processed > 0 && (GetEngineTime() - g_tFrameStart) * 1000.0 >= budgetMs)
            return false;

        Cell anchor, cur;
        g_hPullResult.GetArray(g_iPullAnchor, anchor, sizeof(Cell));
        cells.GetArray(g_iPullJ, cur, sizeof(Cell));

        bool shortcut = (FloatAbs(anchor.center[2] - cur.center[2]) <= 50.0)
            && triple_valid_ground(anchor.center, cur.center)
            && twopos_traversable(anchor.center, cur.center);

        if (!shortcut && g_iPullJ - 1 != g_iPullLastSrc)
        {
            // commit the cell before the failed extension (it was reachable)
            Cell keep;
            cells.GetArray(g_iPullJ - 1, keep, sizeof(Cell));
            g_hPullResult.PushArray(keep, sizeof(Cell));
            g_iPullAnchor = g_hPullResult.Length - 1;
            g_iPullLastSrc = g_iPullJ - 1;
        }
        g_iPullJ++;
        processed++;
    }

    if (g_iPullJ >= srcLen)
    {
        // commit the final source cell unless it is already committed
        if (g_iPullLastSrc != srcLen - 1)
        {
            Cell last;
            cells.GetArray(srcLen - 1, last, sizeof(Cell));
            g_hPullResult.PushArray(last, sizeof(Cell));
        }
        if (g_hPullResult.Length >= 2)
        {
            LogMessage("[PTG] String-pull: %d → %d waypoints", srcLen, g_hPullResult.Length);
            delete g_GuideCells;
            g_GuideCells = g_hPullResult;
            g_hPullResult = null;
        }
        else
        {
            delete g_hPullResult;
            g_hPullResult = null;
        }
        return true;
    }
    return false;
}

// ── Optional SSFA funnel (cvar l4d_path_to_goal_funnel_ssfa, default 0) ──
// Classic simple-stupid-funnel string pulling over the portal segments.
// Only runs when the path is short (≤ 60 cells) — the win on huge paths is
// marginal and the SIGALRM history (2026-07-26) made long tight loops a
// liability. SP VM discipline (from that incident): scalar cross products,
// function-scope buffers, element-wise copies, bounded iteration.
#define SSFA_MAX_CELLS 60
#define SSFA_ITER_CAP 256

stock int IdxFromNavArea(Address area)
{
    char key[16];
    IntToString(view_as<int>(area), key, sizeof(key));
    int idx = -1;
    if (g_hAStarAreaToIndex != null)
        g_hAStarAreaToIndex.GetValue(key, idx);
    return idx;
}

stock bool Funnel_SSFA_Init(ArrayList cells)
{
    delete g_hSSFAPortals;
    g_hSSFAPortals = null;
    delete g_hSSFAPath;
    g_hSSFAPath = null;
    if (g_hCvarFunnelSSFA == null || !g_hCvarFunnelSSFA.BoolValue) return false;
    if (!Portal_Active()) return false;
    if (cells == null || cells.Length < 3 || cells.Length > SSFA_MAX_CELLS) return false;

    // Build the portal chain: one portal per consecutive cell pair.
    ArrayList chain = new ArrayList(sizeof(PortalInfo));
    for (int i = 1; i < cells.Length; i++)
    {
        Cell cPrev, cCur;
        cells.GetArray(i - 1, cPrev, sizeof(Cell));
        cells.GetArray(i, cCur, sizeof(Cell));
        PortalInfo p;
        bool walkable; ConnectionType conType;
        if (Portal_GetForPair(IdxFromNavArea(cPrev.navArea), IdxFromNavArea(cCur.navArea), p, walkable, conType))
            chain.PushArray(p, sizeof(PortalInfo));
        else
        {
            // missing portal — degenerate point portal at the cell center
            p.center = cCur.center;
            p.ep1 = cCur.center;
            p.ep2 = cCur.center;
            p.dz = 0.0;
            p.connectiontype = CONNECTED_ADJACENT;
            p.walkable = true;
            chain.PushArray(p, sizeof(PortalInfo));
        }
    }
    g_hSSFAPortals = chain;
    return true;
}

// Run the funnel once (single frame — pure arithmetic on ≤ 60 portals).
stock bool Funnel_SSFA_Frame()
{
    if (g_hSSFAPortals == null) return true;
    int portalCount = g_hSSFAPortals.Length;
    if (portalCount < 2)
    {
        delete g_hSSFAPortals;
        g_hSSFAPortals = null;
        return true;
    }

    // Output waypoints (float[3]).
    ArrayList outPts = new ArrayList(3);
    PortalInfo p0;
    g_hSSFAPortals.GetArray(0, p0, sizeof(PortalInfo));
    float apex[3];
    apex = p0.center;
    outPts.PushArray(apex, 3);

    float left[3], right[3];
    PortalInfo p1;
    g_hSSFAPortals.GetArray(1, p1, sizeof(PortalInfo));
    Portal_OrderEndpoints(apex, p1, left, right);

    int iter = 0;
    for (int i = 1; i < portalCount && iter < SSFA_ITER_CAP; i++, iter++)
    {
        PortalInfo pi;
        g_hSSFAPortals.GetArray(i, pi, sizeof(PortalInfo));
        float leftI[3], rightI[3];
        Portal_OrderEndpoints(apex, pi, leftI, rightI);

        bool apexOnRight = (GetVectorDistance(apex, right, true) < 0.01);
        bool apexOnLeft  = (GetVectorDistance(apex, left, true)  < 0.01);

        // right side: point rightI crosses past the current right constraint
        if (TriAreaScalar(apex, right, rightI) <= 0.0)
        {
            if (apexOnRight || TriAreaScalar(apex, left, rightI) >= 0.0)
            {
                // tighten the funnel
                right = rightI;
            }
            else
            {
                // path goes around the right constraint — restart the funnel
                // at the corner, re-ordering the current portal vs the new apex
                outPts.PushArray(right, 3);
                apex = right;
                Portal_OrderEndpoints(apex, pi, left, right);
                continue;
            }
        }
        // left side
        if (TriAreaScalar(apex, left, leftI) >= 0.0)
        {
            if (apexOnLeft || TriAreaScalar(apex, right, leftI) <= 0.0)
            {
                left = leftI;
            }
            else
            {
                outPts.PushArray(left, 3);
                apex = left;
                Portal_OrderEndpoints(apex, pi, left, right);
                continue;
            }
        }
    }

    // final point
    PortalInfo pLast;
    g_hSSFAPortals.GetArray(portalCount - 1, pLast, sizeof(PortalInfo));
    float lastC[3];
    lastC = pLast.center;
    if (GetVectorDistance(apex, lastC, false) > 1.0)
        outPts.PushArray(lastC, 3);

    g_hSSFAPath = outPts;
    delete g_hSSFAPortals;
    g_hSSFAPortals = null;
    return true;
}

// Convert the funnel output back into Cells and replace g_GuideCells.
// Each waypoint inherits navArea/flow/jumpFlag from the nearest source cell.
stock bool Funnel_SSFA_Apply(ArrayList cells)
{
    if (g_hSSFAPath == null) return true;
    if (g_hSSFAPath.Length < 2)
    {
        delete g_hSSFAPath;
        g_hSSFAPath = null;
        return true;
    }

    ArrayList result = new ArrayList(sizeof(Cell));
    for (int w = 0; w < g_hSSFAPath.Length; w++)
    {
        float wp[3];
        g_hSSFAPath.GetArray(w, wp, 3);
        // nearest source cell (short paths — O(n²) is fine)
        float bestD = -1.0;
        Cell bestCell;
        for (int s = 0; s < cells.Length; s++)
        {
            Cell c;
            cells.GetArray(s, c, sizeof(Cell));
            float d = GetVectorDistance(wp, c.center, true);
            if (bestD < 0.0 || d < bestD)
            {
                bestD = d;
                bestCell = c;
            }
        }
        bestCell.center = wp;
        result.PushArray(bestCell, sizeof(Cell));
    }

    LogMessage("[PTG] SSFA funnel: %d → %d waypoints", cells.Length, result.Length);
    delete g_GuideCells;
    g_GuideCells = result;
    delete g_hSSFAPath;
    g_hSSFAPath = null;
    return true;
}

// Order a portal's two endpoints as left/right relative to travel from apex.
stock void Portal_OrderEndpoints(const float apex[3], PortalInfo p, float left[3], float right[3])
{
    // cross(apex→center, ep−center): +z = left of travel direction
    float cx = p.center[0] - apex[0];
    float cy = p.center[1] - apex[1];
    float e1x = p.ep1[0] - p.center[0];
    float e1y = p.ep1[1] - p.center[1];
    float cross1 = cx * e1y - cy * e1x;
    if (cross1 >= 0.0)
    {
        left = p.ep1;
        right = p.ep2;
    }
    else
    {
        left = p.ep2;
        right = p.ep1;
    }
}

// 2D signed triangle area — scalar cross product form (inline, no arrays).
// >0: p is left of directed a→b; <0: right; ~0: collinear.
stock float TriAreaScalar(const float a[3], const float b[3], const float p[3])
{
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}
