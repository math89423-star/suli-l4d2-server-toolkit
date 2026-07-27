# [L4D2] Battlefield Kill Feedback

战地风格击杀反馈插件 — 击杀特感时播放战地1原版音效 + 屏幕显示骷髅头图标。

纯服务端 SourceMod 插件，客户端无需任何额外安装。

## 音效

战地1原版击杀音效，从 Frosty Editor 提取（via [ModWorkshop / ttqdqqd](https://modworkshop.net/mod/46718)），已转换为 MP3：

| 音效文件 | 时长 | 场景 |
|----------|------|------|
| `si_kill.mp3` | 2.5s | 普通击杀特感（战地1 Kill Sound） |
| `si_headshot_kill.mp3` | 3.4s | 爆头击杀特感（战地1 Headshot Kill — 更清脆的"叮"） |
| `tank_kill.mp3` | 3.4s | 击杀 Tank（战地1 Critical Headshot Kill — 更响亮） |
| `witch_kill.mp3` | 1.2s | 击杀 Witch（战地1 Critical Headhit） |
| `melee_kill.mp3` | 2.5s | 近战击杀特感（同 Kill Sound） |
| `common_headshot.mp3` | 1.0s | 普感爆头击杀（默认关闭，战地1 Headhit） |

## 效果展示

```
玩家击杀 Smoker →
  🔊 播放 si_kill.mp3（战地1 "叮" 声）
  📺 屏幕显示: ☠ SMOKER 烟鬼 击杀

玩家爆头击杀 Hunter →
  🔊 播放 si_headshot_kill.mp3（更清脆的 headshot kill 声）
  📺 屏幕显示: ☠ HUNTER 猎人 击杀 [爆头]

玩家爆头+近战击杀 Charger →
  🔊 播放 si_headshot_kill.mp3
  📺 屏幕显示: ☠ CHARGER 牛 击杀 [爆头][近战]

玩家连杀 3 只特感 →
  📺 屏幕显示: ☠ JOCKEY 猴子 击杀  x3
```

## 服务端路径

```
addons/sourcemod/
├── plugins/
│   └── l4d2_bf_killfeedback.smx        # 编译后插件
├── scripting/
│   ├── l4d2_bf_killfeedback.sp         # 源码
│   ├── l4d2_bf_killfeedback_README.md  # 本文档
│   └── compiled/
│       └── l4d2_bf_killfeedback.smx    # 编译输出

data/sound/battlefield/
├── si_kill.mp3
├── si_headshot_kill.mp3
├── tank_kill.mp3
├── witch_kill.mp3
├── melee_kill.mp3
└── common_headshot.mp3
```

## 安装

```bash
# 1. 编译（修改源码后）
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting
bash compile.sh l4d2_bf_killfeedback.sp

# 2. 安装到 plugins 目录
cp compiled/l4d2_bf_killfeedback.smx ../plugins/

# 3. 热加载（不重启服务器）
docker exec l4d2-server sm plugins load l4d2_bf_killfeedback
# 或者换图后自动加载
```

音效文件已在 `/opt/gameservers/l4d2/data/sound/battlefield/` 就位，客户端首次连接时会自动下载。

## ConVar 配置

配置自动生成为 `cfg/sourcemod/l4d2_bf_killfeedback.cfg`。

### 主开关

| ConVar | 默认值 | 说明 |
|--------|--------|------|
| `bf_kill_enabled` | `1` | 总开关，0=关闭所有击杀反馈 |
| `bf_kill_volume` | `0.8` | 音量 (0.0 ~ 1.0) |
| `bf_kill_hud_enabled` | `1` | 骷髅头 HUD 显示开关 |
| `bf_kill_cooldown` | `0.1` | 两次音效最小间隔(秒)，防止连喷/连发时重叠 |
| `bf_kill_streak_threshold` | `3` | 连杀计数显示阈值，0=关闭 |

### 音效路径

| ConVar | 默认值 | 触发场景 |
|--------|--------|----------|
| `bf_kill_sound_si` | `battlefield/si_kill.mp3` | 击杀任意特感（兜底音效） |
| `bf_kill_sound_headshot` | `battlefield/si_headshot_kill.mp3` | 爆头击杀特感 |
| `bf_kill_sound_tank` | `battlefield/tank_kill.mp3` | 击杀 Tank |
| `bf_kill_sound_witch` | `battlefield/witch_kill.mp3` | 击杀 Witch |
| `bf_kill_sound_melee` | `battlefield/melee_kill.mp3` | 近战击杀特感 |
| `bf_kill_sound_common_hs` | (空) | 普感爆头击杀，留空=禁用 |

### 音效覆盖规则

```
Tank 击杀  → bf_kill_sound_tank    → bf_kill_sound_si（兜底）
Witch 击杀 → bf_kill_sound_witch   → bf_kill_sound_si（兜底）
爆头击杀   → bf_kill_sound_headshot → bf_kill_sound_si（兜底）
近战击杀   → bf_kill_sound_melee    → bf_kill_sound_si（兜底）
普通击杀   → bf_kill_sound_si
普感爆头   → bf_kill_sound_common_hs（留空=不播放）
```

## 与现有插件的关系

| 现有插件 | 状态 | 关系 |
|----------|------|------|
| `l4d2_headshot_sound.smx` | 已禁用 | **功能重叠** — 本插件已覆盖爆头音效，保持禁用 |
| `l4d2_si_hp_hud.smx` | 源码有/未激活 | **不冲突** — 各自用不同的 PrintHintText，后调用的覆盖前者 |
| `l4d2_emshud_info.smx` | 已禁用 | **不冲突** — EMS HUD 使用 VScript HUD 槽位，本插件用 HintText |
| `l4d2_common_kill_reward.smx` | 启用中 | **不冲突** — 各自监听不同事件 |

## 事件处理流程

```
player_death 事件
  ├─ victim = SI (team 3, player client)
  │   ├─ IsTank?   → tank_kill.mp3
  │   ├─ Headshot? → si_headshot_kill.mp3
  │   ├─ Melee?    → melee_kill.mp3
  │   └─ Default   → si_kill.mp3
  │   └─ HUD: ☠ [SI_NAME] 击杀 [爆头][近战] xN
  │
  ├─ entityid = Witch
  │   └─ witch_kill.mp3 + ☠ WITCH 击杀
  │
  └─ Attacker = survivor (team 2)

infected_death 事件
  ├─ headshot && common_hs sound configured? → common_headshot.mp3
  └─ else → 不播放（避免普感击杀刷屏）
```

## 已知限制 / 后续优化方向

### 当前限制

1. **骷髅头是文本而非图片** — L4D2 的 `PrintHintText` 使用游戏内建字体，`☠` (U+2620) 可能在某些客户端渲染为方框。替代方案见下方。

2. **Witch 检测依赖 entityid** — `player_death` 事件中 Witch 的 `entityid` 在某些 mod 地图中可能不准确。

3. **音效从 ModWorkshop Volume+ 版提取** — 音量偏大，可通过 `bf_kill_volume` 调整。如需原版音量，需重新提取 Volume- 版本。

4. **连杀计数在回合结束重置** — 正常行为，符合 Battlefield 逻辑。

### 后续优化项

- [ ] **真实骷髅头图标** — 集成 Hit Marker Overhaul VScript 框架，用 VTF 材质显示战地风格骷髅头图案
- [ ] **屏幕震动** — Tank 击杀时给附近玩家一个轻微屏幕震动
- [ ] **击杀粒子特效** — 击杀位置播放短暂粒子（参考 `l4d2_headshot_sound.sp` 的粒子效果）
- [ ] **音效随机化** — 同类型击杀从多个音效中随机选择（如 BF1/BFV/BF2042 随机切换）
- [ ] **Chat 播报** — 可选聊天栏公屏播报（如 "玩家X 爆头击杀了 Hunter!"）
- [ ] **伤害数字** — 类似 `l4d2_damage_show.smx` 的伤害数字漂浮显示
- [ ] **爆头命中音效** — 非致命爆头也有命中音效（参考 `l4d2_headshot_sound.sp` 的 hurt sound）
- [ ] **Tank 弱点反馈** — 打中 Tank 不同部位不同音效
- [ ] **客户端偏好** — 玩家用 `!bfkill` 自行开关音效/HUD

### 如需更强的视觉效果

1. **Steam 创意工坊订阅 Hit Marker Overhaul**（工坊 ID `3626250386`）
   - 纯 VScript，客户端侧，无需服务端安装
   - 支持 COD 风格命中/击杀/爆头标记
   - 可作为本插件骷髅头图标的客户端替代

2. **替换为更好的音效**
   - 从战地1游戏文件中用 Frosty Editor 直接提取更高音质版本
   - 从 Nexus Mods 下载 BFV/BF2042 击杀音效包
   - 放置到 `sound/battlefield/` 并修改对应 ConVar 即可

## 编译

```bash
cd /opt/gameservers/l4d2/data/addons/sourcemod/scripting
bash compile.sh l4d2_bf_killfeedback.sp
# 输出: compiled/l4d2_bf_killfeedback.smx
```

依赖的 include 文件（均为服务器已有）：
- `sourcemod.inc`
- `sdkhooks.inc`
- `sdktools.inc`

无需额外 gamedata 或 extension。

## 调试

```bash
# 查看插件状态
docker exec l4d2-server sm plugins list | grep bf_kill

# 查看 ConVar 值
docker exec l4d2-server sm_cvar bf_kill_enabled
docker exec l4d2-server sm_cvar bf_kill_volume

# 重新加载配置
docker exec l4d2-server sm plugins reload l4d2_bf_killfeedback

# 临时关闭
docker exec l4d2-server sm_cvar bf_kill_enabled 0
```

## 更新日志

| 版本 | 日期 | 变更 |
|------|------|------|
| 1.0.0 | 2026-07-27 | 初始版本 — SI 击杀音效 + 骷髅头 HUD + 连杀计数 |

## 鸣谢

- 战地1音效：ttqdqqd (ModWorkshop) / DICE
- 参考代码：`l4d2_headshot_sound.sp` (suli), `l4d2_si_hp_hud.sp` (Claude)
- 服务器：suli-l4d2-server-toolkit
