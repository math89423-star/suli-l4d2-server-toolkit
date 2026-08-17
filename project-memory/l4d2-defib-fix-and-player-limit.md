---
name: l4d2-defib-fix-and-player-limit
description: 2026-08-03 人数上限全面放开（24幸存者/32特感/200小僵尸）+ Defib_Fix 电击器修复部署（SM1.12 gamedata/dhooks 适配全链路）
metadata: 
  node_type: memory
  type: project
  originSessionId: 3a3fab95-82f0-45a7-ab2c-513813d56d47
  modified: 2026-08-03T15:18:51.133Z
---

# 2026-08-03 人数上限放开 + Defib_Fix 部署

> **v2.0.2（23:14）**：新增 native `L4D2_KillSurvivorDeathModel(client)`——复活后清尸（si_hud v1.9.6 调用，修 L4D_RespawnPlayer 残留尸体被电击器误电活人 bug）。详见 [[l4d2-respawn-gear]]。

## 热更新项（全部 RCON 即时生效 + 配置文件持久化）

| cvar | 旧值 | 新值 | 持久化位置 |
|------|------|------|-----------|
| `l4d_multislots_max_survivors` | 10 | 24 | l4dmultislots.cfg（运行时 max 就是 24，cfg 注释 18 是旧版残留） |
| `ss_si_limit` | 20 | 32 | sourcemod.cfg `sm_cvar ss_si_limit 32` + specialspawner.cfg `"32"`（原 sourcemod.cfg 里 48 超上限被 clamp，specialspawner.cfg 里 28，已统一） |
| `sm_max_common_cap` | 120 | 200 | l4d2_max_common.cfg 追加 `sm_max_common_cap "200"`（**必须写 cfg 否则重启回退 120**；base 30 + 6×人数公式不变，200 只是天花板） |
| `z_common_limit` | 90 | 200 | sourcemod.cfg（max_common 插件动态覆盖它） |
| `l4d_multislots_alive_bot_time` | 0 | 30 | l4dmultislots.cfg（0=必须生成存活 bot，人满时新人卡"无法生成生还者Bot"；>0 时 bot 失败→死尸状态入队） |

**"生还者已达上限"根因**：sv_maxplayers 24 是总槽位，幸存者上限之前只有 10（l4d_multislots_max_survivors 10），满 10 后新玩家被拒。

## Defib_Fix 部署（修电击器错乱/电到活人）——核心踩坑

**症状**：5+ 幸存者（l4dmultislots）下电击器目标错乱，提示"这时候无法生成一个生还者Bot"（这其实是 l4dmultislots 翻译文案 `Impossible to generate a bot at the moment.`）→ 与 defib 无关；defib 错乱是另一个 bug，社区标准解 = Defib_Fix（[alliedmods 帖](https://forums.alliedmods.net/showthread.php?p=2647018)，MultiSlots 作者原话 "This is 5+ survivor bug, use Defib_Fix"）。

**部署链条（2026-08-03，引擎 2.2.4.3 build 2026-06-30，SM 1.12.0.7220，DHooks 1.12.0.7230）**：

1. 原版 `plugins_no_gamedata/Defib_Fix.smx`（LuxLuma v2.0.1）已编译但从未部署——缺 gamedata
2. **gamedata（`gamedata/defib_fix.txt`）**：
   - 引擎 `server_srv.so`（dedicated 实际加载，`server.so` 是另一份同代码差 0x1A0 偏移的库）被 strip，`@_ZN` 符号全在 `.symtab` 但**不在 `.dynsym`** → dlsym 找不到
   - **但 SM 1.12 的符号解析能工作**（SymbolsAreHidden=true 时走自研 .symtab 解析）——前提是条目放对位置
   - **关键**：`DHookCreateFromConf`（dhooks 扩展）只查 Signatures 的 GetMemSig 且**解析失败**（原因未最终定位）；而 **SM 原生 `GameConfGetAddress`（Addresses 节 → signature 引用 → GetMemSig）解析成功**
   - 所以 gamedata 必须同时有 Addresses 节（signature 引用）+ Signatures 节（`@_ZN` 符号）
   - 符号名从引擎二进制提取：`nm /tmp/server_srv.so | grep CItemDefibrillator`（本地符号 t 小写，地址 0x5319d0 等）
3. **源码适配**（scripting/Defib_Fix.sp，已本地修改）：
   - 4 个 `DHookCreateFromConf` 全部替换为 `DHookCreateDetour(GameConfGetAddress(hGamedata, "key"), CallConv, ReturnType, ThisPointer_Ignore)`
   - OnActionComplete/OnStartAction/GetPlayerByCharacter：CallConv_THISCALL, ReturnType_Void/Int
   - **CSurvivorDeathModel::Create：CallConv_CDECL**（反汇编从 stack 读参数，pThis 才 = CTerrorPlayer*）
   - 删除 OnEntityCreated（不再按实体 hook，改全局 detour）
   - 编译输出到 scripting/ 当前目录（不是 compiled/！spcomp 默认输出 cwd）
4. **验证**：`defib_fix_version` cvar 存在 = OnPluginStart 完整执行（4 detour 全成功）

**注意**：`sm plugins list` 76 个插件时 RCON 输出截断只显示 72 个，用 `sm plugins load` 的 "already loaded" + cvar 判断状态。

## 静态检测修正（2026-08-03 二次检测发现，已修复）

原 DHookCreateDetour 版有 3 个运行期 bug（玩家死亡时暴露）：

1. **ReturnType_Void → 必须 ReturnType_Int/CBaseEntity**：Void 时 hReturn 不 push（回调收 0 → "Invalid Handle 0"）；且回调有 DHookSetReturn 必炸。OnActionComplete/OnStartAction 保持 Int。
2. **DHookCreateDetour 后必须 DHookAddParam 定义参数**：setup 无参数 → argNum=0 → hParams 不 push → DHookGetParam 报 Invalid Handle 0。OnActionComplete 加 [Int, CBaseEntity(死亡模型), Int]（GetParam(2)=死亡模型实体索引）；GetPlayerByCharacter 加 [Int]；Create 加 [CBaseEntity]。
3. **Create 和 GetPlayerByCharacter 的 ReturnType_Int → ReturnType_CBaseEntity**：Int 时 DHookGetReturn 返回**指针值**（g_iDeathModelOwner[指针] 数组越界 277859440）；CBaseEntity 时自动 EntityToBCompatRef 转实体索引。SetReturn(client 索引) 也会转回实体指针。
4. **ThisPointer_Ignore 时 pThis 不 push**：回调不能用 `(int pThis)`（错位拿到 hReturn 句柄）——DeathModelCreatePre/Post 改 `(Handle hReturn, Handle hParams)`，Pre 用 DHookGetParam(hParams,1) 拿 client。
5. **DHookGetParam 索引 = 显式参数（不含 this）**：THISCALL detour 下 param 1 = 第一个显式参数（this 在 ecx 单独处理）——原代码 param 2（死亡模型）/param 1（character）**无需改**。

**验证**：22:40 部署后 22:41-22:46 零错误（期间 12 人战斗、幸存者死亡触发 Create）；对照：Int 版 2 分钟内必报数组越界。

**检测方法（复用）**：objdump 反汇编函数验证参数位置（死亡模型=[ebp+0xc] 显式#2，经 OnRevivedByDefibrillator 调用确认）；拉 SM 仓库 `extensions/dhooks/dynhooks_sourcepawn.cpp`（HandleDetour 回调构造）+ `DynamicHooks/conventions/x86GccThiscall.cpp`（this 插入）确认 push 顺序与索引规则。

**已知未解**：SM 1.12.0.7220 的 Linux 字节模式搜索（FindPattern）实测失效（连 CreateInterface 模式都搜不到）；dhooks DHookCreateFromConf 查 gamedata **Functions 节**（不是 Signatures），无 Functions 节就报 "Function signature not found"——若日后要恢复原版写法需补 Functions 节。未来引擎更新后若 defib_fix 失效，重走此流程。

## 关联
- [[l4d2-server-quick-reference]] — cvar 热更新/RCON
- [[l4d2-common-limit-scaling]] — 小僵尸公式
- [[l4d2-source-code-location-pitfall]] — 源码同步
