#if defined _l4d2_score_core_included
    #endinput
#endif
#define _l4d2_score_core_included

/**
 * score_core(原 l4d2_si_hud) 公共 API（v1.9.0+）——积分钱包
 *
 *score_core(原 si_hud) 拥有并持久化 g_iWallet（可用积分）：
 * 计分入账（击杀/伤害/连杀/救援）、存档恢复（data/si_hud_scores.txt）、
 * 战役清零、重连恢复全在 score_core 内。消费方（如 l4d2_shop）通过本 API
 * 读取/增减，不触碰内部状态。
 *
 * v1.12.0: 复活币 natives（SH_GetReviveCoins/SH_AddReviveCoins/
 * SH_GetCoinMax/SH_ReviveClient）已移除——复活体系改为免费次数 +
 * 积分自动复活（score_core_revive_cost），复活套装 forward 保留。
 *
 * ⚠ 绑定规则（SM 1.12 运行时懒绑定——项目既有模式，见 left4dhooks 消费方）：
 *   - 消费方直接 `native` 声明这些函数即可；score_core 未加载时插件照常加载，
 *     但对缺失 native 的调用会记错误日志并返回 0。
 *   - 因此调用必须经可用性守卫：FindPluginByFile("l4d2_score_core.smx") 存在
 *     且版本 >= 1.9.0（SH_Ready 模式，见 l4d2_shop.sp），未就绪时不发起
 *     调用。score_core 通过 RegPluginLibrary("score_core_api") 声明库存在，
 *     可作辅助信号。
 */

/**
 * 读取玩家可用积分（钱包）。
 */
native int SH_GetWallet(int client);

/**
 * 增减玩家可用积分（负数 = 消费，正数 = 退款），结果钳制 >= 0。
 * 返回操作后的新余额（消费方聊天播报直接用返回值，无需二次读取）。
 */
native int SH_AddWallet(int client, int amount);

/**
 * 复活完成全局 forward（v1.9.2+，score_core 发布，消费方定义同名 public 函数即可
 * 自动接收）：自动复活（免费命或积分复活，v1.12.0 起两种都触发）确认存活后
 * （Timer_RespawnTeleport，复活 0.5s 后）触发。l4d2_shop v1.5.1 监听它发放
 * "复活套装"（sm_shop_respawn_gear）+ 满血（sm_shop_respawn_health）。
 * 闲置/接管不触发（引擎自管）。
 */
forward void SH_OnClientRespawned(int client);

/**
 * ── v1.13.7 只读榜单数据 API（l4d2_scoreboard_ui 常驻 EMS 排行榜消费）──
 * 数据口径与 !rank/EMS 得分榜同源；三级排序 积分>特感>击杀 由消费方实现。
 */

/** 本关累计积分（排行榜口径，OnMapEnd 清零；≠钱包可用积分）。 */
native int SH_GetRoundScore(int client);

/** 特感击杀数。 */
native int SH_GetSIKills(int client);

/** 小僵尸击杀数（总击杀 = SIKills + CommonKills）。 */
native int SH_GetCommonKills(int client);

/** 友伤伤害累计。 */
native int SH_GetFFDamage(int client);

/** 被黑（黑枪/被 SI 控制次数）计数。 */
native int SH_GetBlacked(int client);
