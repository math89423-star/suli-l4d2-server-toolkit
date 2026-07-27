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

            // v4.0: Chain into STAGE_REPAIR after validation completes
            if (g_vBlocked > 0 && g_hCvarRepairEnable != null && g_hCvarRepairEnable.BoolValue)
            {
                Guide_RepairBlocked();
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

        // Strategy 0: Ladder / elevator / vertical drop
        if (dz > 80.0 && distXY < 40.0)
        {
            g_bBeamWalkable.Push(1);
            continue;
        }

        // Strategy 0.5: Vault / climb — moderate-height obstacle to jump over
        // Two cells close horizontally but with a box/crate/ledge between them.
        // The player can vault: step up onto the higher cell, walk across, drop down.
        // Trace at the higher cell's level (+10u clearance) with low hull.
        if (dz >= 30.0 && dz <= 100.0 && distXY < 120.0)
        {
            float vaultZ = (cell1.center[2] > cell2.center[2] ? cell1.center[2] : cell2.center[2]) + 10.0;
            float sv[3], ev[3];
            sv = baseStart; sv[2] = vaultZ;
            ev = baseEnd;   ev[2] = vaultZ;
            // Only the higher-level horizontal trace needs to clear — player steps up naturally
            if (TryHull(sv, ev, lowMins, lowMaxs))
            {
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
        }

        g_bBeamWalkable.Push(walkable ? 1 : 0);
        if (!walkable) g_vBlocked++;
    }

    RequestFrame(Guide_ValidateWalkable_Frame, 0);
}

bool frame_budget_exceeded()
{
    if (g_hCvarBudget.FloatValue <= 0.0) return false;
    float dt_ms = (GetEngineTime()-g_tFrameStart)*1000.0;
    bool exceeded = dt_ms >= g_hCvarBudget.FloatValue;
    return exceeded;
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

    RequestFrame(Guide_RepairBlocked_Frame, 0);
}

void Guide_RepairBlocked_Frame(any unused)
{
    // Abort if map changed since repair started
    if (g_iRepairMapGen != g_iMapGeneration) return;
    if (g_GuideCells == null || g_bBeamWalkable == null || g_ri >= g_bBeamWalkable.Length)
    {
        if (g_rFixed > 0 || g_rBeaconed > 0)
        {
            LogMessage("[PTG] STAGE_REPAIR: fixed=%d beaconed=%d / %d total beams",
                g_rFixed, g_rBeaconed, (g_GuideCells != null && g_GuideCells.Length > 1) ? g_GuideCells.Length - 1 : 0);
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
                    g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                    g_bBeamWalkable.Set(g_ri, 1);
                    repaired = true;
                    g_rFixed++;
                }
                // Also try lifting cell1
                if (!repaired)
                {
                    test = cell1.center;
                    test[2] += zOffsets[z];
                    if (twopos_traversable(test, cell2.center))
                    {
                        cell1.center = test;
                        g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                        g_bBeamWalkable.Set(g_ri, 1);
                        repaired = true;
                        g_rFixed++;
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
                    TR_TraceHullFilter(s1, e1, midMins, midMaxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly);
                    if (!TR_DidHit())
                    {
                        cell1.center = s1;
                        cell1.center[2] -= 28.0;
                        cell2.center = e1;
                        cell2.center[2] -= 28.0;
                        g_GuideCells.SetArray(g_ri, cell1, sizeof(Cell));
                        g_GuideCells.SetArray(g_ri + 1, cell2, sizeof(Cell));
                        g_bBeamWalkable.Set(g_ri, 1);
                        repaired = true;
                        g_rFixed++;
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
                    TR_TraceHullFilter(segs[s], segs[s+1], midMins, midMaxs, MASK_PLAYERSOLID, TraceFilter_WorldOnly);
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

        // Strategy 4: Local A* reroute using nav area adjacency
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
                g_GuideCells.ShiftUp(g_ri + 1);
                g_GuideCells.SetArray(g_ri + 1, altCell, sizeof(Cell));
                g_bBeamWalkable.ShiftUp(g_ri);
                g_bBeamWalkable.Set(g_ri, 1);
                g_bBeamWalkable.Set(g_ri + 1, 1);
                repaired = true;
                g_rFixed++;
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

// Draw beacon markers at positions stored in g_hBeaconCells
void Guide_DrawBeacons(int client = -1)
{
    if (g_hBeaconCells == null || g_hBeaconCells.Length == 0) return;
    if (!g_hCvarBeaconEnable.BoolValue) return;

    int laser = g_iLaserWhite;
    if (laser == 0) laser = g_iLaser;
    if (laser == 0) return;

    float duration = g_hCvarAutoDuration.FloatValue;
    if (duration < 1.0) duration = 5.0;

    // Bright red-orange beacon: "path continues here"
    int color_beacon[4] = {255, 100, 50, 255};

    for (int i = 0; i < g_hBeaconCells.Length; i++)
    {
        float pos[3], end[3];
        g_hBeaconCells.GetArray(i, pos, 3);
        end = pos;
        end[2] += 32.0; // tall vertical marker

        // Vertical pillar beam — visible from a distance
        TE_SetupBeamPoints(pos, end, laser, 0, 0, 0,
            duration, 4.0, 4.0, 0, 0.0, color_beacon, 0);
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
}



