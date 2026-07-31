// PTG Module: ptg_utils — Physics hull traces, geometry, nav mesh helpers, jump/drop validation
// Extracted from l4d_path_to_goal.inc (backup)

// ── Physics trace utilities ──
public bool TraceFilter_WorldOnly(int entity, int contentsMask, any data)
{
    return (entity == 0); // only collide with world BSP geometry
}

// Single hull test helper — returns true if walkable
// v4.6: filter unified with path construction/validation. The old
// TraceFilter_WorldOnly only saw world BSP, so REPAIR/validate passed beams
// through closed doors, unbroken breakables and physics-blocked corridors
// that the path itself (TraceFilterStatic) treats as impassable — two
// standards, contradictory results. TraceFilterStatic with accuracy on =
// TraceFilterWalkable (entities + door state + health); accuracy off =
// legacy behavior (world + prop_static + func_brush).
bool TryHull(float start[3], float end[3], const float mins[3], const float maxs[3])
{
    TR_TraceHullFilter(start, end, mins, maxs, MASK_PLAYERSOLID, TraceFilterStatic);
    return !TR_DidHit();
}

// Offset a point perpendicular to the travel direction
void OffsetPerpendicular(float start[3], float end[3], float offset, float result[3])
{
    float dir[3], perp[3];
    dir[0] = end[0] - start[0];
    dir[1] = end[1] - start[1];
    dir[2] = 0.0;
    float len = SquareRoot(dir[0] * dir[0] + dir[1] * dir[1]);
    if (len < 1.0) { result = start; return; }
    perp[0] = -dir[1] / len * offset;
    perp[1] =  dir[0] / len * offset;
    perp[2] = 0.0;
    result[0] = start[0] + perp[0];
    result[1] = start[1] + perp[1];
    result[2] = start[2];
}

// ── Geometry, ground checks, traversability ──
bool cell_traversable(int i, float pos[3], bool world_only = true, float max_distance = -1.0)
{
    static Cell cell;
    g_GuideCells.GetArray(i,cell,sizeof(Cell));
    return twopos_traversable(pos,cell.center,world_only,max_distance);
}

//static int MASK_PTG = MASK_PLAYERSOLID | MASK_VISIBLE | CONTENTS_DETAIL;
static int MASK_PTG = MASK_PLAYERSOLID;

#define DX_HULL 8.0
#define DZ_HULL 30.0

// Test if you can travel between two vector positions without an obstruction. world_only to hit only world and static props. ladder to accept traversability if ladder was hit
bool twopos_traversable(float pos1[3], float pos2[3], bool world_only = true, float max_distance = -1.0, bool hull = true)
//bool twopos_traversable(float pos1[3], float pos2[3], bool world_only = true, float max_distance = -1.0, bool hull = true, bool ladder = true)
{
    //g_bHitLadder = false;
    if (max_distance>0.0 && GetVectorDistance(pos1,pos2)>max_distance) return false;
    if (hull)
    {
        if (world_only) TR_TraceHullFilter(pos1,pos2,{-DX_HULL,-DX_HULL,1.0},{DX_HULL,DX_HULL,DZ_HULL},MASK_PTG,TraceFilterStatic);
        else            TR_TraceHullFilter(pos1,pos2,{-DX_HULL,-DX_HULL,1.0},{DX_HULL,DX_HULL,DZ_HULL},MASK_PTG,TraceFilterNoClients);
    }
    else
    {
       if (world_only) TR_TraceRayFilter(pos1,pos2,MASK_PTG,RayType_EndPoint,TraceFilterStatic);
       else TR_TraceRayFilter(pos1,pos2,MASK_PTG,RayType_EndPoint,TraceFilterNoClients);
    }
    //if (ladder && g_bHitLadder) return true;
    if (!TR_DidHit(INVALID_HANDLE)) return true;
    #if DEBUG
    g_iHitEntity = TR_GetEntityIndex(INVALID_HANDLE);
    g_iHitSurfaceProps = TR_GetSurfaceProps(INVALID_HANDLE);
    g_iHitSurfaceFlags = TR_GetSurfaceFlags(INVALID_HANDLE);
    TR_GetSurfaceName(INVALID_HANDLE,g_sHitSurfaceName,sizeof(g_sHitSurfaceName));
    #endif
    return false;
}

bool TraceFilterStatic(int entity, int contentsMask)
{
    // v4.5: When accuracy mode is on, delegate to expanded walkable filter
    if (g_bAccuracyEnabled)
        return TraceFilterWalkable(entity, contentsMask);

    if (entity == 0) return true;
    if (entity > 0 && entity <= MaxClients) return false;
    static char class[16];
    GetEntityClassname(entity,class,sizeof(class));
    switch (class[0])
    {
        case 'p':
        {
            if (strncmp(class,"prop_static",11,false)==0) return true;
        }
        case 'f':
        {
            if (strncmp(class,"func_brush",10,false)==0) return true;
            if (strncmp(class,"func_simpleladder",17,false)==0) return false;
        }
    }
    return false;
}

// v4.5 Expanded trace filter — blocks against world geometry PLUS common
// impassable entities that the legacy Static filter misses: doors, breakables,
// physics props, and solid triggers.
//
// TraceFilterStatic only checks world (entity 0), prop_static, and func_brush.
// On custom maps especially, paths would route through closed doors, barricades,
// and physics-blocked corridors because those entities were invisible to the
// hull trace.  This filter catches them while respecting open-door state.
//
// Regression risk analysis:
//   - Doors that are OPEN are NOT blocked (m_eDoorState check)
//   - Breakables with 0 health (already destroyed) are NOT blocked
//   - Non-solid entities are skipped first (entity_solid check)
//   - Strictly MORE blocking than Static → paths that were going through walls
//     will now either: (a) find a real route around, (b) get repaired in REPAIR
//     stage, or (c) be correctly shortened to the last walkable point.
//     In all cases, this is better than showing a path through an impassable wall.
bool TraceFilterWalkable(int entity, int contentsMask)
{
    if (entity == 0) return true;                    // world geometry — always solid
    if (entity > 0 && entity <= MaxClients) return false; // skip players

    // Non-solid entities can never block a player (debris, triggers, items, etc.)
    if (!entity_solid(entity)) return false;

    static char class[64];
    GetEntityClassname(entity, class, sizeof(class));

    // ── prop_* entities ──
    if (class[0] == 'p')
    {
        if (strncmp(class, "prop_static", 11) == 0) return true;

        // prop_door_rotating: only block when closed or closing.
        // m_eDoorState: 0=closed, 1=opening, 2=open, 3=closing
        if (strncmp(class, "prop_door", 9) == 0)
        {
            int doorState = GetEntProp(entity, Prop_Send, "m_eDoorState");
            return (doorState == 0 || doorState == 3); // closed or closing
        }

        // prop_physics / prop_physics_multiplayer — blocks if solid
        if (strncmp(class, "prop_physics", 12) == 0) return true;

        // prop_dynamic_override — sometimes used as a barrier
        if (strncmp(class, "prop_dynamic_override", 21) == 0) return true;

        return false;
    }

    // ── func_* brush entities ──
    if (class[0] == 'f')
    {
        if (strncmp(class, "func_brush", 10) == 0) return true;

        // func_door / func_door_rotating — only block when closed
        if (strncmp(class, "func_door", 9) == 0)
        {
            // m_eDoorState for func_door: same enum as prop_door
            int doorState = GetEntProp(entity, Prop_Send, "m_eDoorState");
            return (doorState == 0 || doorState == 3); // closed or closing
        }

        // func_breakable / func_breakable_surf — only block if not yet broken
        if (strncmp(class, "func_breakable", 14) == 0)
        {
            int health = GetEntProp(entity, Prop_Data, "m_iHealth");
            return (health > 0); // broken if health <= 0
        }

        // func_simpleladder — always pass-through
        if (strncmp(class, "func_simpleladder", 17) == 0) return false;

        // func_wall / func_wall_toggle — invisible walls (map boundaries)
        if (strncmp(class, "func_wall", 9) == 0) return true;

        // func_physbox — physics brush, blocks until destroyed/moved
        if (strncmp(class, "func_physbox", 12) == 0) return true;

        return false;
    }

    // ── trigger_* volumes ──
    // Most triggers are non-solid (filtered above). Solid triggers are rare
    // but exist as invisible barriers (trigger_push fences, etc.)
    if (strncmp(class, "trigger_", 8) == 0)
        return false; // triggers that pass entity_solid() are intentional barriers

    // Default: block unknown solid entities (safe — unknown → assume obstacle)
    return true;
}

bool TraceFilterNoClients(int entity, int contentsMask)
{
    if (entity > 0 && entity <= MaxClients) return false;
    return true;
}

stock bool pos_underwater(const float pos[3])
{
	static float top[3], bottom[3];
    bottom = pos;
    top = pos; top[2] += 64.0;
	TR_TraceRay(top,bottom,MASK_WATER,RayType_EndPoint);
	if (TR_DidHit(INVALID_HANDLE)) return true;
    return false;
}

// Get midpoint between pos1 and pos2.
stock void get_midpoint(float pos1[3], float pos2[3], float pos_mid[3])
{
    static float vDiff[3];
    MakeVectorFromPoints(pos1,pos2,vDiff);
    ScaleVector(vDiff,0.5);
    AddVectors(pos1,vDiff,pos_mid);
}

// Try to project pos onto line between pos_start and pos_end. Update pos_mid if success.
stock bool project_forward(float pos_start[3], float pos_end[3], float pos[3], float pos_mid[3])
{
    static float vDiff[3], vDiff2[3];
    MakeVectorFromPoints(pos_start,pos_end,vDiff);
    float mag_sq = GetVectorDotProduct(vDiff,vDiff);
    if (mag_sq<=0.0) return false;
    MakeVectorFromPoints(pos_start,pos,vDiff2);
    float dot = GetVectorDotProduct(vDiff,vDiff2);
    if (dot<=0.0) return false; // not pointing in the right direction
    float scale = dot/mag_sq;
    if (scale>=0.999 || scale<=0.001) return false; // projection is crappy
    ScaleVector(vDiff,scale);
    AddVectors(pos_start,vDiff,pos_mid);
    return true;
}

#define DZ_TOO_HIGH 50.0 // how high survivors can jump
#define DZ_TOO_LOW 200.0 // fall damage

// See if going from pos1 to pos2 is too steep (potentially dangerous, or obstacle too tall.)
// This is mostly useless.
stock bool vecdiff_too_steep(float pos1[3], float pos2[3])
{
    static float diff[3];
    SubtractVectors(pos2,pos1,diff); // how to move to go from from pos1 to pos2
    if (FloatAbs(diff[2])<=DZ_TOO_HIGH) return false;
    float length = GetVectorLength(diff);
    if (length<=DZ_TOO_HIGH) return false;
    float ratio = diff[2] / length;
    return FloatAbs(ratio)>=0.75;
}

stock bool cell_step_too_steep(Cell cell_before,Cell cell_after)
{
    if (cell_before.navArea != Address_Null && cell_after.navArea != Address_Null)
        return nav_too_steep(cell_before.navArea,cell_after.navArea);
    return vecdiff_too_steep(cell_before.center,cell_after.center);
    //float dz = FloatAbs(cell_before.center[2]-cell_after.center[2]);
    //return dz >= DZ_TOO_HIGH;
}

// See if from -> to is too steep
stock bool nav_too_steep(Address from, Address to)
{
    if (from==Address_Null || to==Address_Null) return false;
    static float pos1[3], pos2[3];
    L4D_GetNavAreaCenter(from,pos1);
    L4D_GetNavAreaCenter(to,pos2);
    float dz = pos2[2]-pos1[2];
    bool up = dz >= 0.0;
    dz = FloatAbs(dz);
    if (dz<DZ_TOO_HIGH) return false;
    static float size1[3], size2[3];
    L4D_GetNavAreaSize(from,size1);
    L4D_GetNavAreaSize(to,size2);
    dz -= FloatAbs(size1[2]/2.0);
    dz -= FloatAbs(size2[2]/2.0);
    if (up) return dz>=DZ_TOO_HIGH;
    else return dz>=DZ_TOO_LOW;
}

// Check if ground is valid at both positions and inbetween.
stock bool triple_valid_ground(float pos1[3], float pos2[3])
{
    if (!valid_ground(pos1)) return false;
    if (!valid_ground(pos2)) return false;
    return midpoint_valid_ground(pos1,pos2);
}

// Check if midpoint between two vector positions is reasonably close to the ground.
stock bool midpoint_valid_ground(float pos1[3], float pos2[3])
{
    static float diff[3], pos_mid[3];
    SubtractVectors(pos2,pos1,diff); // how to move to go from from pos1 to pos2
    if (GetVectorLength(diff,true)<=4096.0) return true;
    ScaleVector(diff,0.5);
    AddVectors(pos1,diff,pos_mid);
    return valid_ground(pos_mid);
}

#define GROUND_WIDTH 16.0
#define GROUND_TRACE_DOWN_NEAR 100.0   // v4.5: first attempt — near ground
#define GROUND_TRACE_DOWN_FAR  500.0   // v4.5: second attempt — steep drops

stock bool valid_ground(float pos[3])
{
    static float pos_down[3];

    // First try: moderate range (100u), tight hull — catches most cases fast
    pos_down = pos; pos_down[2] -= GROUND_TRACE_DOWN_NEAR;
    TR_TraceHullFilter(pos,pos_down,{-GROUND_WIDTH,-GROUND_WIDTH,2.0},{GROUND_WIDTH,GROUND_WIDTH,5.0},MASK_PTG|MASK_WATER,TraceFilterStatic);
    if (TR_DidHit(INVALID_HANDLE)) return true;

    // Second try: full range (500u), wider hull — catches steep slopes,
    // multi-story drops, and nav areas whose center Z is far above the floor
    pos_down = pos; pos_down[2] -= GROUND_TRACE_DOWN_FAR;
    TR_TraceHullFilter(pos,pos_down,{-24.0,-24.0,2.0},{24.0,24.0,5.0},MASK_PTG|MASK_WATER,TraceFilterStatic);
    if (TR_DidHit(INVALID_HANDLE)) return true;

    // Third try: upward trace (64u) — catches cases where pos is slightly
    // below a low ceiling or embedded in a thin floor surface
    pos_down = pos; pos_down[2] += 64.0;
    TR_TraceHullFilter(pos,pos_down,{-GROUND_WIDTH,-GROUND_WIDTH,2.0},{GROUND_WIDTH,GROUND_WIDTH,5.0},MASK_PTG|MASK_WATER,TraceFilterStatic);
    return TR_DidHit(INVALID_HANDLE);
}

// Determine if entity is solid to players and zombies from m_CollisionGroup, m_nSolidType and m_usSolidFlags
stock bool entity_solid(int entity)
{
    if (GetEntProp(entity, Prop_Send, "m_nSolidType") == 0) return false;
    if (GetEntProp(entity, Prop_Send, "m_usSolidFlags") & 0x0004) return false; // FSOLID_NOT_SOLID 
    switch (GetEntProp(entity, Prop_Send, "m_CollisionGroup"))
    {
        case 1: return false; // COLLISION_GROUP_DEBRIS
        case 2: return false; // COLLISION_GROUP_DEBRIS_TRIGGER
    }
    return true;
}

///////////// Connections

// Fill conList with NavConnection (navArea+connection_type) to navArea. returns length of array
stock int GetNavConnections(Address navArea, ArrayList conList, int team = TEAM_SURVIVOR,
                            bool adjacent = true, bool elevator = true, bool ladder = true, int filter = CON_KEEP_FORWARD)
{
    if (navArea == Address_Null) return 0;
    conList.Clear();
    ArrayList tempList = new ArrayList();
    static NavConnection nav_connection;
    Address adjArea;
    int i;
    if (adjacent)
    {
        for (int dir = 0; dir < 4; dir++)
        {
            tempList.Clear();
            L4D_NavArea_GetAdjacentAreas(navArea, dir, tempList);
            for (i = 0; i < tempList.Length; i++)
            {
                adjArea = tempList.Get(i);
                if (adjArea == Address_Null || adjArea == navArea) continue;
                if (navmesh_adjacent_too_far(navArea,adjArea))
                {
                    #if DEBUG>1
                        LogMessage("navmesh_adjacent_too_far %d -> %d", navArea, adjArea);
                    #endif
                    continue;
                }
                switch (filter)
                {
                    case CON_KEEP_FORWARD:
                    {
                        if (!adjacent_connected(navArea,adjArea)) continue;
                    }
                    case CON_KEEP_BACKWARD:
                    {
                        if (!adjacent_connected(adjArea,navArea)) continue;
                    }
                    default: // CON_KEEP_ALL
                    {
                        if (!adjacent_connected(navArea,adjArea) && !adjacent_connected(adjArea,navArea)) continue;
                    }
                }
                nav_connection.navArea = adjArea;
                nav_connection.connectiontype = CONNECTED_ADJACENT;

                // Detect one-way drop-down connections in the nav mesh itself.
                // Source Engine nav mesh uses directed edges: a one-way edge from
                // higher→lower means "you can drop down" — correct for zombie AI
                // but wrong for a human player guide. Reclassify these as JUMP_DOWN.
                // v4.1: Verify solid ground below departure point. One-way edges
                // through windows (indoor→outdoor) have no floor below the indoor
                // departure area and are reclassified as CONDITIONAL instead.
                if (!adjacent_connected(adjArea, navArea))
                {
                    float cFrom[3], cTo[3];
                    L4D_GetNavAreaCenter(navArea, cFrom);
                    L4D_GetNavAreaCenter(adjArea, cTo);
                    if (cFrom[2] - cTo[2] > 48.0)
                    {
                        float vStart[3], vEnd[3];
                        vStart = cFrom; vStart[2] -= 4.0;
                        vEnd = cFrom;
                        vEnd[2] = cTo[2] + 8.0;

                        TR_TraceRayFilter(vStart, vEnd, MASK_PLAYERSOLID, RayType_EndPoint, TraceFilterStatic);
                        if (TR_DidHit())
                        {
                            nav_connection.connectiontype = CONNECTED_JUMP_DOWN;
                        }
                        else
                        {
                            nav_connection.connectiontype = CONNECTED_CONDITIONAL;
                        }
                    }
                }

                conList.PushArray(nav_connection);
            }
        }
    }
    if (elevator && team!=TEAM_INFECTED) // typically only survivors can use elevators
    {
        adjArea = navArea_elevator_navArea(navArea);
        if (adjArea != Address_Null)
        {
            nav_connection.navArea = adjArea;
            nav_connection.connectiontype = CONNECTED_ELEVATOR;
            conList.PushArray(nav_connection);
        }
    }
    if (ladder)
    {
        int count = navArea_ladder_navAreas(navArea,tempList,team);
        for (i = 0; i < count; i++)
        {
            adjArea = tempList.Get(i);
            nav_connection.navArea = adjArea;
            nav_connection.connectiontype = CONNECTED_LADDER;
            conList.PushArray(nav_connection);
        }                
    }
    delete tempList;
    return conList.Length;
}

// Check if connection from -> to can be made.
// check_ladder manually searches for nearby func_simpleladder
//stock bool cell_connected(Cell from, Cell to)
stock bool cell_connected(Cell from, Cell to, bool check_ladder = true)
{
    if (from.navArea != Address_Null && to.navArea != Address_Null)
    { 
        if (navArea_connected(from.navArea,to.navArea)) return true;
    }
    if (check_ladder) // manual ladder search, expensive
    {
        static Cell cell;
        if (try_ladder(from.flow,from.center,cell) && cell_connected(cell,to,false)) return true;
    }
    return false;
}

// Check if connection from -> to can be made.
stock bool navArea_connected(Address from, Address to, int team = TEAM_SURVIVOR)
{
    if (from == Address_Null || to == Address_Null) return false;
    if (from == to) return true;
    if (elevator_from_to(from,to)>0) return true;
    if (ladder_from_to(from,to,team)>0) return true;
    if (navmesh_adjacent_too_far(from,to))
    {
        #if DEBUG>1
            LogMessage("navmesh_adjacent_too_far %d -> %d", from, to);
        #endif
        return false;
    }
    return adjacent_connected(from,to);
}

// Check if from -> to is connected adjacently
stock bool adjacent_connected(Address from, Address to)
{
    for (int dir = 0; dir < 4; dir++)
    {
        if (L4D_NavArea_IsConnected(from,to,dir)) return true;
    }
    return false;
}

ArrayList ladders1, ladders2;

// Return func_simpleladder connecting from -> to. returns -1 on failure.
stock int ladder_from_to(Address from, Address to, int team = TEAM_SURVIVOR)
{
    if (from == Address_Null || to == Address_Null) return -1;
    if (ladders1 == null) ladders1 = new ArrayList();
    ladders1.Clear();
    int count1 = NavArea_GetLadders(from,ladders1);
    if (count1<=0) return -1;

    if (ladders2 == null) ladders2 = new ArrayList();
    ladders2.Clear();
    int count2 = NavArea_GetLadders(to,ladders2);
    if (count2<=0) return -1;

    for (int i1 = 0; i1 < ladders1.Length; i1++)
    {
        int ladder = ladders1.Get(i1);
        if (ladder<=0 || !IsValidEntity(ladder)) continue;
        for (int i2 = 0; i2 < ladders2.Length; i2++)
        {
            if (ladders2.Get(i2)==ladder)
            {
                int team_ladder = GetEntProp(ladder, Prop_Send, "m_iTeamNum");
                if (team_ladder==0 || team_ladder==team) return ladder;
            }
        }
    }
    return -1;
}

// Find other navAreas connected to navArea via ladder.
stock int navArea_ladder_navAreas(Address from, ArrayList navList, int team = TEAM_SURVIVOR)
{
    if (from==Address_Null || !elevator_available) return 0;
    if (ladders1 == null) ladders1 = new ArrayList();
    ladders1.Clear();
    int count = NavArea_GetLadders(from,ladders1);
    if (count<=0) return 0;
    navList.Clear();
    static float start[3];
    L4D_GetNavAreaCenter(from,start);
    for (int i = 0; i < ladders1.Length; i++)
    {
        int ladder = ladders1.Get(i);
        if (ladder<=0 || !IsValidEntity(ladder)) continue;
        int team_ladder = GetEntProp(ladder, Prop_Send, "m_iTeamNum");
        if (team_ladder!=0 && team_ladder!=team) continue;
        static float pos1[3],pos2[3];
        GetEntPropVector(ladder, Prop_Send, "m_vecMaxs", pos1);
        GetEntPropVector(ladder, Prop_Send, "m_vecMins", pos2);
        SortTwoVectorsClosest(start,pos1,pos2);
        if (navmesh_xy_too_far(from,pos1)) continue;
        Address to = L4D_GetNearestNavArea(pos2,500.0,true,false,false,TEAM_SURVIVOR);
        #if DEBUG>1
        LogMessage("navArea_ladder_navAreas %d -> %d", from, to);
        #endif
        if (to==Address_Null || to==from) continue;
        navList.Push(to);
    }
    return navList.Length;
}

// Fill ladderList with func_simpleladder connected to navArea.
stock int NavArea_GetLadders(Address navArea, ArrayList ladderList)
{
    if (!elevator_available || navArea == Address_Null) return 0;
    return L4D_NavArea_GetLadder(navArea,ladderList);
}

// Return func_elevator connecting from -> to. returns -1 on failure.
stock int elevator_from_to(Address from, Address to)
{
    if (!elevator_available || from == Address_Null || to == Address_Null) return -1;
    int elevator = L4D_NavArea_GetElevator(from);
    if (elevator<=0 || !IsValidEntity(elevator)) return -1;
    if (elevator == L4D_NavArea_GetElevator(to)) return elevator;
    return -1;
}

// Get other navArea connecting navArea via elevator
stock Address navArea_elevator_navArea(Address from)
{
    if (from==Address_Null || !elevator_available) return Address_Null;
    int elevator = L4D_NavArea_GetElevator(from);
    if (elevator<=0 || !IsValidEntity(elevator)) return Address_Null;
    static float start[3],pos[3],pos1[3],pos2[3];
    L4D_GetNavAreaCenter(from,start);
    GetEntPropVector(elevator, Prop_Send, "m_vecOrigin", pos);
    pos1 = pos; pos2 = pos;
    pos1[2] = GetEntPropFloat(elevator, Prop_Send, "m_movementStartZ");
    pos2[2] = GetEntPropFloat(elevator, Prop_Send, "m_destinationFloorPosition");
    SortTwoVectorsClosest(start,pos1,pos2);
    Address to = L4D_GetNearestNavArea(pos2,500.0,true,false,false,TEAM_SURVIVOR);
    if (to==Address_Null || to==from) return Address_Null;
    return to;
}

// Check if nav area is relevant to survivor escape path.
stock bool navArea_escape(Address navArea)
{
    if (navArea == Address_Null) return false;
    int spawnAttrs = L4D_GetNavArea_SpawnAttributes(navArea);
    if (spawnAttrs & NAV_SPAWN_ESCAPE_ROUTE) return true;
    if (spawnAttrs & NAV_SPAWN_CHECKPOINT) return true;
    if (spawnAttrs & NAV_SPAWN_PLAYER_START) return true;
    if (spawnAttrs & NAV_SPAWN_RESCUE_VEHICLE) return true;
    return false;
}

// Acknowledge navmesh change. Ptg must be recalculated after NAV_COOLDOWN. If recompute, recalculate without cooldown.
// Check if a nav area is on the current guide path.
// Used by dynamic re-planning to decide if a nav_blocked event affects us.
stock bool IsAreaOnPath(Address navArea)
{
    if (g_GuideCells == null || navArea == Address_Null) return false;
    int len = g_GuideCells.Length;
    Cell cell;
    for (int i = 0; i < len; i++)
    {
        g_GuideCells.GetArray(i, cell, sizeof(Cell));
        if (cell.navArea == navArea) return true;
    }
    return false;
}

// Periodic path integrity check — polls g_GuideCells for newly blocked areas.
// Handles cases where nav_blocked events don't fire (prop physics, dynamic obstacles).
// Returns true if path is still valid, false if re-planning was triggered.
stock bool PathIntegrityCheck()
{
    if (!guide_ready || g_GuideCells == null || !blocked_available) return true;

    int len = g_GuideCells.Length;
    if (len < 2) return true;

    // Check ~25% of cells each call (strided sampling, 5s interval)
    // Over ~20s, every cell gets checked at least once
    static int checkOffset = 0;
    int stride = 4;
    if (stride < 1) stride = 1;

    Cell cell;
    int checked = 0;
    int blocked = 0;

    for (int i = checkOffset; i < len; i += stride)
    {
        g_GuideCells.GetArray(i, cell, sizeof(Cell));
        if (cell.navArea != Address_Null && L4D_NavArea_IsBlocked(cell.navArea, TEAM_SURVIVOR, true))
            blocked++;
        checked++;
        if (checked >= 8) break; // limit per-frame work
    }

    checkOffset = (checkOffset + 1) % stride;

    if (blocked > 0)
    {
        LogMessage("[PTG] Path integrity check: %d/%d sampled cells blocked — local detour", blocked, checked);
        // v4.6: windowed detour around the first blocked cell found (falls
        // back to full NavChanged(true) rebuild inside when impossible)
        Guide_TryLocalDetour(cell.navArea);
        return false;
    }

    return true;
}

stock void NavChanged(bool recompute = false)
{
    // v4.2: Soft path invalidation.
    // recompute=false: full nav mesh change (round_start_post_nav, nav_generate).
    //   Must clean up — the old nav data is invalid.
    // recompute=true: path integrity found blocked cells or flow was recomputed.
    //   Keep the current path active for toggled clients (it may be slightly stale
    //   but drawing something is better than nothing). Flag as dirty so auto-check
    //   timer triggers a background rebuild.
    if (!recompute)
    {
        Guide_Cleanup();
        g_bPathDirty = false;
    }
    else
    {
        // Don't nuke the path — just mark it stale and let auto-check handle rebuild.
        // If already dirty, don't spam (PathIntegrityCheck fires every 6s and
        // would keep calling NavChanged(true) until rebuild completes).
        if (!g_bPathDirty)
        {
            g_bPathDirty = true;
            LogMessage("[PTG] Path marked dirty — rebuild scheduled (old path stays active for toggled clients)");
        }
    }

    t_nav = GetGameTime();
    if (recompute) t_nav = t_nav - NAV_COOLDOWN + 0.1;
    if (!enable || !gamemode_guidable || !map_started || !nav_started || timer_nav != null) return;
    if (finale && finale_rescue && finale_stitched && g_hCvarFinaleAuto.BoolValue) Guide_All_Clients();
    else timer_nav = CreateTimer( (recompute) ? 0.1 : NAV_COOLDOWN , Timer_CheckRequests, _, TIMER_FLAG_NO_MAPCHANGE );
}

// return true if given flow value is better than old value. increasing=true if better is bigger.
stock bool flow_better(const float flow_new, const float flow_old, const bool increasing = true)
{
    if (increasing) return (flow_new)>=flow_old;
    else return (flow_new)<=flow_old;
}

stock bool IsValidClient(int client, bool replaycheck = true)
{
	if (client<1 || client>MaxClients) return false;
	if (!IsClientInGame(client)) return false;
	if (replaycheck)
	{
		if (IsClientSourceTV(client) || IsClientReplay(client)) return false;
	}
	return true;
}

// ============================================================================
// Binary Heap (Min-Heap) for A* Priority Queue
// Ordered by fScore. Lazy deletion: stale entries are skipped on pop.
// ============================================================================

// Bubble up from index i

// ── Jump arc and drop arc validation ──
stock bool ValidateJumpArc(const float from[3], const float to[3], PlayerCaps caps)
{
    float dx = to[0] - from[0];
    float dy = to[1] - from[1];
    float dz = to[2] - from[2];
    float distXY = SquareRoot(dx * dx + dy * dy);
    if (distXY < 1.0) return true;

    // Parabola bulge: how much the arc rises above the straight line at midpoint
    float midZ = (from[2] + to[2]) / 2.0;
    float apexZ = ((from[2] > to[2]) ? from[2] : to[2]) + caps.max_jump_height * 0.6;
    float h = apexZ - midZ;
    if (h < caps.max_step_up) h = caps.max_jump_height * 0.3;

    float lowMins[3] = {-10.0, -10.0, 0.0};
    float lowMaxs[3] = { 10.0,  10.0, 32.0};

    float prev[3], curr[3];
    prev = from;
    prev[2] += 28.0; // standing height

    int samples = 10;
    for (int i = 1; i <= samples; i++)
    {
        float s = float(i) / float(samples);
        curr[0] = from[0] + dx * s;
        curr[1] = from[1] + dy * s;
        curr[2] = from[2] + dz * s + 4.0 * h * s * (1.0 - s) + 28.0;

        if (!TryHull(prev, curr, lowMins, lowMaxs))
            return false;
        prev = curr;
    }
    return true;
}

// Validate a drop-down connection by tracing vertically from the higher point.
// Verifies the drop is within safe height and landing area is clear.
stock bool ValidateDropArc(const float from[3], const float to[3], PlayerCaps caps)
{
    float dz = to[2] - from[2];
    if (dz > 0.0 || FloatAbs(dz) > caps.max_safe_drop) return false;
    if (FloatAbs(dz) < caps.max_step_up) return true; // small step, no validation needed

    float dropStart[3], dropEnd[3];
    dropStart = from;
    dropStart[2] -= 4.0; // start slightly below feet
    dropEnd[0] = from[0];
    dropEnd[1] = from[1];
    dropEnd[2] = to[2] + 8.0; // land slightly above target

    float slimMins[3] = {-8.0, -8.0, 1.0};
    float slimMaxs[3] = { 8.0,  8.0, 36.0};

    return TryHull(dropStart, dropEnd, slimMins, slimMaxs);
}

// ============================================================================
// Non-Mesh Connection Detection
// ============================================================================

// Detect all non-mesh connections between nav areas. Called once per map load.
// Uses spatial hash + nav area attributes (CROUCH, JUMP, BREAKABLEWALL, etc.)
// Distributed across frames via OnFramePrep for large maps.
int g_iNonMeshI;               // current scan index for frame distribution
ArrayList g_hNonMeshNearby;    // reusable nearby query result

