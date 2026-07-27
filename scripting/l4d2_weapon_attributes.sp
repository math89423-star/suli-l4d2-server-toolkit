/**
 * l4d2_weapon_attributes.sp
 * Weapon attribute modification plugin using Left4DHooks natives.
 * Supports ALL weapon attributes exposed by left4dhooks.
 * Replaces older plugin that lacked clipsize/minmovespread/mincrouchspread support.
 */

#include <sourcemod>
#include <left4dhooks>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"

// Attribute type
enum AttrType
{
	Attr_Int,
	Attr_Float
}

// Attribute mapping entry
enum struct AttrEntry
{
	char name[32];
	int enumIndex;
	AttrType type;
}

// All supported attributes
AttrEntry g_AttrList[] = {
	// === Int Attributes ===
	{"damage",              L4D2IWA_Damage,              Attr_Int},
	{"bullets",             L4D2IWA_Bullets,             Attr_Int},
	{"clipsize",            L4D2IWA_ClipSize,            Attr_Int},
	{"bucket",              L4D2IWA_Bucket,              Attr_Int},
	{"tier",                L4D2IWA_Tier,                Attr_Int},

	// === Float Attributes ===
	{"maxplayerspeed",      L4D2FWA_MaxPlayerSpeed,      Attr_Float},
	{"spreadpershot",       L4D2FWA_SpreadPerShot,       Attr_Float},
	{"maxspread",           L4D2FWA_MaxSpread,           Attr_Float},
	{"spreaddecay",         L4D2FWA_SpreadDecay,         Attr_Float},
	{"minduckingspread",    L4D2FWA_MinDuckingSpread,    Attr_Float},
	{"mincrouchspread",     L4D2FWA_MinDuckingSpread,    Attr_Float},  // alias
	{"minstandingspread",   L4D2FWA_MinStandingSpread,   Attr_Float},
	{"minstandspread",      L4D2FWA_MinStandingSpread,   Attr_Float},  // alias (backward compat)
	{"mininairspread",      L4D2FWA_MinInAirSpread,      Attr_Float},
	{"maxmovementspread",   L4D2FWA_MaxMovementSpread,   Attr_Float},
	{"minmovespread",       L4D2FWA_MaxMovementSpread,   Attr_Float},  // alias (backward compat)
	{"penlayers",           L4D2FWA_PenetrationNumLayers, Attr_Float},
	{"pennumlayers",        L4D2FWA_PenetrationNumLayers, Attr_Float},  // alias
	{"penpower",            L4D2FWA_PenetrationPower,    Attr_Float},
	{"penmaxdist",          L4D2FWA_PenetrationMaxDist,  Attr_Float},
	{"charpenmaxdist",      L4D2FWA_CharPenetrationMaxDist, Attr_Float},
	{"range",               L4D2FWA_Range,               Attr_Float},
	{"rangemod",            L4D2FWA_RangeModifier,       Attr_Float},
	{"rangemodifier",       L4D2FWA_RangeModifier,       Attr_Float},  // alias
	{"cycletime",           L4D2FWA_CycleTime,           Attr_Float},
	{"scatterpitch",        L4D2FWA_PelletScatterPitch,  Attr_Float},
	{"pelletscatterpitch",  L4D2FWA_PelletScatterPitch,  Attr_Float},  // alias
	{"scatteryaw",          L4D2FWA_PelletScatterYaw,    Attr_Float},
	{"pelletscatteryaw",    L4D2FWA_PelletScatterYaw,    Attr_Float},  // alias
	{"verticalpunch",       L4D2FWA_VerticalPunch,       Attr_Float},
	{"horizontalpunch",     L4D2FWA_HorizontalPunch,     Attr_Float},
	{"gainrange",           L4D2FWA_GainRange,           Attr_Float},
	{"reloadduration",      L4D2FWA_ReloadDuration,      Attr_Float}
};

int g_AttrCount;

public Plugin myinfo =
{
	name = "L4D2 Weapon Attributes",
	author = "Claude (replacement for older plugin)",
	description = "Modify weapon attributes via sm_weapon command using Left4DHooks",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_AttrCount = sizeof(g_AttrList);

	RegAdminCmd("sm_weapon", Command_Weapon, ADMFLAG_CONFIG, "sm_weapon <weapon> <attribute> <value> - Modify weapon attributes");

	AutoExecConfig(true, "l4d2_weapon_attributes");
}

public void OnConfigsExecuted()
{
	// Config has been executed - attributes are applied via sm_weapon commands
}

public Action Command_Weapon(int client, int args)
{
	if (args < 3)
	{
		ReplyToCommand(client, "[SM] Usage: sm_weapon <weapon> <attribute> <value>");
		ReplyToCommand(client, "[SM] Supported attributes:");
		ListAttributes(client);
		return Plugin_Handled;
	}

	char weapon[64], attr[32], valStr[32];
	GetCmdArg(1, weapon, sizeof(weapon));
	GetCmdArg(2, attr, sizeof(attr));
	GetCmdArg(3, valStr, sizeof(valStr));

	// Build full weapon classname if not prefixed
	char classname[64];
	if (strncmp(weapon, "weapon_", 7) == 0)
	{
		strcopy(classname, sizeof(classname), weapon);
	}
	else
	{
		Format(classname, sizeof(classname), "weapon_%s", weapon);
	}

	// Validate weapon
	if (!L4D2_IsValidWeapon(classname))
	{
		ReplyToCommand(client, "[SM] Invalid weapon: %s", weapon);
		return Plugin_Handled;
	}

	// Find attribute
	int idx = FindAttrIndex(attr);
	if (idx == -1)
	{
		ReplyToCommand(client, "[SM] Unknown attribute: %s", attr);
		ReplyToCommand(client, "[SM] Supported attributes:");
		ListAttributes(client);
		return Plugin_Handled;
	}

	// Apply attribute
	if (g_AttrList[idx].type == Attr_Int)
	{
		int val = StringToInt(valStr);
		L4D2_SetIntWeaponAttribute(classname, view_as<L4D2IntWeaponAttributes>(g_AttrList[idx].enumIndex), val);
		ReplyToCommand(client, "[SM] Set %s %s = %d (Int)", weapon, attr, val);
	}
	else
	{
		float val = StringToFloat(valStr);
		L4D2_SetFloatWeaponAttribute(classname, view_as<L4D2FloatWeaponAttributes>(g_AttrList[idx].enumIndex), val);
		ReplyToCommand(client, "[SM] Set %s %s = %.4f (Float)", weapon, attr, val);
	}

	return Plugin_Handled;
}

int FindAttrIndex(const char[] name)
{
	for (int i = 0; i < g_AttrCount; i++)
	{
		if (strcmp(name, g_AttrList[i].name, false) == 0)
			return i;
	}
	return -1;
}

void ListAttributes(int client)
{
	char line[512];
	int len;

	// List unique attributes (skip aliases)
	line = "";
	for (int i = 0; i < g_AttrCount; i++)
	{
		// Skip aliases
		if (i > 0 && g_AttrList[i].enumIndex == g_AttrList[i-1].enumIndex)
			continue;

		char tag[5];
		if (g_AttrList[i].type == Attr_Int)
			strcopy(tag, sizeof(tag), "[I]");
		else
			strcopy(tag, sizeof(tag), "[F]");

		char entry[64];
		Format(entry, sizeof(entry), "%s%s ", tag, g_AttrList[i].name);
		len += strlen(entry);

		if (len > 400)
		{
			ReplyToCommand(client, line);
			line = "";
			len = 0;
		}
		StrCat(line, sizeof(line), entry);
	}
	if (line[0] != '\0')
		ReplyToCommand(client, line);
}
