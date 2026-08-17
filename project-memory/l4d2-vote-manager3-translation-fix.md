---
name: l4d2-vote-manager3-translation-fix
description: l4d2_vote_manager3 翻译文件被裁剪导致 "Vote Called 2 Arguments" 缺失报错——已用官方完整版恢复并部署
metadata:
  node_type: memory
  type: fix
  modified: 2026-08-16T01:40:00.000Z
---

`l4d2_vote_manager3.smx`（"[L4D1/2] Vote Manager Remake" v1.2h by McFlurry, Harry）是 **ESC 原生投票权限/冷却管理系统**（非换图执行器）：按 flag 放行/拦截「换关 / 开新战役 / 换难度 / 踢人 / 全员语音」投票 + 冷却 60s + 免投/免踢，投票通过后播报出自它。

**报错**（每次投票通过必现）：
```
Language phrase "Vote Called 2 Arguments" not found (arg 4)   ← Blaming: l4d2_vote_manager3.smx
[0] VFormat ← [1] LogVoteManager (line 787) ← [2] NextFrame_CallVote (line 479)
```

**根因**：本地 `translations/l4d2_vote_manager3.phrases.txt` 被裁剪成只剩 6 个短语（No Vote / No Access / Vote Passed / Vote Failed / Passed / Vetoed），而插件实际调用的 `"Vote Called 2 Arguments"`（3 format 参数：`{1:s},{2:s},{3:s}`）被裁掉了。

**修复（2026-08-16 已部署）**：从官方仓库 `fbef0102/L4D1_2-Plugins`（master 分支 `l4d2_vote_manager3/translations/`）取回完整版 **21 个短语**（Vetoed/Passed/Cant Pass/Cant Veto/No Vote/Log Error/Conflict/Wait/No Vote Access/Vote Called/Vote Failed/Vote Called 2 Arguments/Vote Passed/Kick Vote/Kick Vote Call Failed/Kick Immunity/Invalid Kick Userid/Tank Immune Response/Spectator Response/Client Exploit Attempt/NotAllowed，含 en/chi/zho/ru 四语），并保留本地特有的 `No Access` 短语（官方只有 No Vote Access，兼容插件可能调用 No Access）。合并后覆盖部署：

- 新文件：`translations/l4d2_vote_manager3.phrases.txt`（8778 字节, 189 行）
- 备份：`translations/l4d2_vote_manager3.phrases.txt.bak-20260816`（原 6 短语裁剪版）
- 生效：翻译文件修改后需 `sm_reload_translations` 或插件 reload（服务器空闲时执行）

**相关**：播报源全清单见 [[l4d2-deployment-rules]]（campaign_transition 轮询 / mapchanger [TS] 已关 / basetriggers !nextmap / vote_manager3 投票通过提示）。