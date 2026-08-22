---
name: l4d2-rcon-filename-pitfall
description: /tmp/rcon.py 文件名与 rcon.source pip 包冲突导致 import 失败
metadata:
  node_type: memory
  type: pitfall
  tags:
    - l4d2
    - python
    - rcon
    - import
---

# /tmp/rcon.py 文件名冲突坑

## 症状

```
from rcon.source import Client as R
ModuleNotFoundError: No module named 'rcon.source'; 'rcon' is not a package
```

但 `python3 -c "import rcon.source"` 单独执行正常。

## 根因

Python 的模块搜索顺序：**脚本所在目录优先于 site-packages**。

`/tmp/rcon.py` 执行时，Python 把 `/tmp/rcon.py` 当成了 `rcon` 模块 → 覆盖了 site-packages 里的 `rcon` 包 → `rcon.source` 找不到。

## 解决

**脚本文件名不能和 pip 包名相同**：

```bash
# 错误：与 rcon 包冲突
/tmp/rcon.py          ← Python 把它当 rcon 模块

# 正确：改名避开
/home/administrator/suli-l4d2-server-toolkit/bin/rcons.py         ← 不冲突，正常 import rcon.source
```

## 触发条件

- 脚本在 `/tmp/` 等非 site-packages 目录
- `import rcon.source` 在脚本内执行
- 脚本文件名恰好是 `rcon.py`

## 关联
- [[l4d2-howto-plugins]] — RCON 客户端路径已更新为 rcons.py
- [[l4d2-rcon-hotreload-workflow]] — 完整热加载方案
