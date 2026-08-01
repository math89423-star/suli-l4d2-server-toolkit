/**
 * [TEST] HUD channel probe — kill card replacement candidates.
 *
 * The PrintHintText channel is a dead end for the kill card: the engine
 * shows a hint ~10s (not ~4s — that was CS:GO knowledge) and the "" purge
 * that shortens it garbles the NEXT CJK hint. This plugin probes every
 * other channel so we can pick where the card lives next.
 *
 * Usage (admin):
 *   sm_hudtest <mode> [target]     — target optional (defaults to self; RCON must pass one)
 *   mode 0: PrintHintText (current card, control)
 *   mode 1: ShowHudText channel 0
 *   mode 2: ShowHudText channel 1
 *   mode 3: ShowHudText channel 2
 *   mode 4: ShowHudText channel 3
 *   mode 5: raw HudMsg x=-1 y=720 hold 2.0  (mid-low at 1080p)
 *   mode 6: raw HudMsg x=-1 y=600 hold 2.0
 *   mode 7: raw HudMsg x=-1 y=-1 hold 2.0  (screen center)
 *   mode 8: KeyHintText count=1 (RELIABLE — the un-reliable send may have dropped)
 *   mode 9: KeyHintText burst — resend every 1s for 5s (kills the "flash and
 *           vanish" / drop ambiguity; if this shows, the channel itself works)
 *   mode 10: PrintCenterText TWO lines (\n) — does L4D2 center text wrap?
 *   mode 11: PrintCenterText single long line (control for 10)
 *   mode 12: diag — print usermsg ids (HintText/KeyHintText/HudMsg) to chat
 *
 * Check for each mode: WHERE is it on screen, is the CJK text clean, and
 * how long does it stay (the exact thing the stopwatch is for).
 * NOTE (v1.2): modes 1-7 (HudMsg family) are CONFIRMED DEAD on L4D2 —
 * client-side font/splitscreen bugs (AM thread p=2792713) — kept only as
 * references.
 */

#pragma semicolon 1
#pragma newdecls required

#define CARD "[M16] ☠ HUNTER 猎人(head shot)"

Handle g_hBurst[MAXPLAYERS + 1];             // mode 9 burst timer per client

public Plugin myinfo =
{
    name        = "[TEST] HUD Channels",
    author      = "suli",
    description = "HUD channel probe for the kill card replacement",
    version     = "1.1.0",
    url         = ""
};

public void OnPluginStart()
{
    RegAdminCmd("sm_hudtest", Cmd_HudTest, ADMFLAG_ROOT,
        "sm_hudtest <mode 0-8> [target] — probe HUD channels (position/CJK/duration)");
}

public Action Cmd_HudTest(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "usage: sm_hudtest <mode 0-8> [target]");
        return Plugin_Handled;
    }

    char arg[16];
    GetCmdArg(1, arg, sizeof(arg));
    int mode = StringToInt(arg);

    int target = client;
    if (args >= 2)
    {
        char targetArg[64];
        GetCmdArg(2, targetArg, sizeof(targetArg));
        target = FindTarget(client, targetArg, true, false);
        if (target < 1)
        {
            ReplyToCommand(client, "target not found");
            return Plugin_Handled;
        }
    }

    if (target < 1 || !IsClientInGame(target))
    {
        ReplyToCommand(client, "no in-game target");
        return Plugin_Handled;
    }

    switch (mode)
    {
        case 0: PrintHintText(target, CARD);                       // control: current hint card
        case 1: ShowHudText(target, 0, CARD);
        case 2: ShowHudText(target, 1, CARD);
        case 3: ShowHudText(target, 2, CARD);
        case 4: ShowHudText(target, 3, CARD);
        case 5: HudMsgAt(target, -1.0, 720.0, 2.0);                // mid-low @1080p (dead on L4D2)
        case 6: HudMsgAt(target, -1.0, 600.0, 2.0);                // dead on L4D2
        case 7: HudMsgAt(target, -1.0, -1.0, 2.0);                 // screen center (dead on L4D2)
        case 8: SendKeyHint(target, CARD);                         // KeyHintText, RELIABLE
        case 9:
        {
            if (g_hBurst[target] != null)
            {
                KillTimer(g_hBurst[target]);
                g_hBurst[target] = null;
            }
            DataPack pack = new DataPack();
            pack.WriteCell(GetClientUserId(target));
            pack.WriteCell(0);                                     // burst count
            g_hBurst[target] = CreateTimer(1.0, Timer_KeyHintBurst, pack,
                TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
            PrintToChat(target, "\x04[HUD TEST]\x01 mode 9 running — KeyHintText every 1s for 5s (burst)");
            return Plugin_Handled;
        }
        case 10: PrintCenterText(target, "☠☠☠ 爆头击杀 +150\n[M16] ☠ HUNTER 猎人(head shot)");
        case 11: PrintCenterText(target, "☠☠☠ 爆头击杀 +150  [M16] ☠ HUNTER 猎人(head shot)");
        case 13: PrintCenterText(target, "☠☠☠ \x07FFD700爆头击杀\x01 +150\n[M16] \x07FFD700☠\x01 HUNTER 猎人");
        case 14: PrintCenterText(target, "\x04☠☠☠\x01 爆头击杀 +150\n[M16] ☠ HUNTER 猎人");
        case 12:
        {
            int h = GetUserMessageId("HintText");
            int k = GetUserMessageId("KeyHintText");
            int m = GetUserMessageId("HudMsg");
            PrintToChat(target, "[HUD TEST] HintText=%d KeyHintText=%d HudMsg=%d (-1 = not registered)", h, k, m);
            return Plugin_Handled;
        }
        default:
        {
            ReplyToCommand(target, "mode must be 0-8");
            return Plugin_Handled;
        }
    }

    PrintToChat(target, "\x04[HUD TEST]\x01 mode %d sent — check position, CJK, and time it (s)", mode);
    return Plugin_Handled;
}

// Raw HudMsg with explicit position and hold time. Old-Source field order
// (no fx id in this build): channel, x, y, r,g,b,a, effect,
// fadein, fadeout, hold, fxamount, fxspeed, text.
void HudMsgAt(int client, float x, float y, float hold)
{
    UserMsg um = GetUserMessageId("HudMsg");
    if (um == INVALID_MESSAGE_ID)
    {
        PrintToChat(client, "[HUD TEST] no HudMsg usermsg on this build");
        return;
    }

    int clients[1];
    clients[0] = client;
    Handle bf = StartMessageEx(um, clients, 1);
    if (bf == null)
        return;

    BfWrite w = UserMessageToBfWrite(bf);
    w.WriteByte(0);                        // channel
    w.WriteFloat(x);                       // x (-1 = horizontal center)
    w.WriteFloat(y);                       // y (-1 = vertical center)
    w.WriteByte(255); w.WriteByte(255); w.WriteByte(255); w.WriteByte(255); // r g b a
    w.WriteByte(0);                        // effect
    w.WriteFloat(0.0);                     // fade in
    w.WriteFloat(0.5);                     // fade out
    w.WriteFloat(hold);                    // hold time — the engine removes it after this
    w.WriteFloat(0.0);                     // fx amount
    w.WriteFloat(0.0);                     // fx speed
    w.WriteString(CARD);                   // text
    EndMessage();
}

void SendKeyHint(int client, const char[] text)
{
    UserMsg um = GetUserMessageId("KeyHintText");
    if (um == INVALID_MESSAGE_ID)
        return;

    int clients[1];
    clients[0] = client;
    Handle bf = StartMessageEx(um, clients, 1, USERMSG_RELIABLE);
    if (bf == null)
        return;

    BfWrite w = UserMessageToBfWrite(bf);
    w.WriteByte(1);                        // count
    w.WriteString(text);                   // hint line
    EndMessage();
}

Action Timer_KeyHintBurst(Handle timer, DataPack pack)
{
    pack.Reset();
    int userId = pack.ReadCell();
    int count = pack.ReadCell();
    count++;
    pack.WriteCell(count);

    int client = GetClientOfUserId(userId);
    if (client < 1 || !IsClientInGame(client) || count > 5)
    {
        if (client > 0)
            g_hBurst[client] = null;
        return Plugin_Stop;
    }

    SendKeyHint(client, CARD);
    return Plugin_Continue;
}
