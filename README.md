# L4D2 Server - 插件包 & Web 管理面板

L4D2 (Left 4 Dead 2) 服务器插件包和 Web 管理面板的长期维护仓库。

## 目录结构

```
l4d2-server/
├── sourcemod/            # SourceMod 完整插件生态
│   ├── plugins/          # 已编译插件 (.smx)，70+ 个 active
│   ├── scripting/        # 插件源码 (.sp)
│   ├── configs/          # 插件配置文件
│   ├── extensions/       # C++ 扩展 (.so/.dll)
│   ├── gamedata/         # Gamedata 签名文件
│   ├── translations/     # 多语言翻译
│   ├── data/             # 插件运行时数据
│   └── PLUGINS.md        # 插件清单与说明
├── admin-panel/          # Flask Web 管理面板
│   ├── app.py            # 主应用
│   ├── switch_map.py     # 换图逻辑
│   ├── scan_maps.py      # 地图扫描
│   ├── templates/        # Jinja2 模板
│   ├── static/           # 静态资源
│   ├── deploy/           # 部署配置 (nginx, systemd)
│   └── Dockerfile        # Docker 镜像
├── scripts/              # 工具脚本
└── .gitignore
```

## 快速开始

### 1. 部署插件

```bash
# 克隆仓库
git clone <repo-url> /opt/gameservers/l4d2/data/addons/sourcemod

# 下载 SourceMod 核心二进制 (bin/)
# 从 https://www.sourcemod.net/downloads.php 下载对应版本

# 下载 GeoIP 数据库 (可选)
MAXMIND_KEY=yourkey ./scripts/download-geoip.sh

# 配置管理员
cp sourcemod/configs/admins_simple.ini.example sourcemod/configs/admins_simple.ini
# 编辑 admins_simple.ini，填入你的 Steam ID
```

### 2. 部署 Web 管理面板

```bash
cd admin-panel
cp config.json.example config.json
# 编辑 config.json，填入 RCON 密码等配置
pip install -r requirements.txt
python app.py
```
或使用 Docker：
```bash
cd admin-panel
docker build -t l4d2-admin-panel .
docker run -d -p 5000:5000 -v /opt/gameservers/l4d2:/opt/gameservers/l4d2 l4d2-admin-panel
```

## 需要手动安装的组件

| 组件 | 路径 | 获取方式 |
|------|------|---------|
| SourceMod 核心 | `sourcemod/bin/` | [sourcemod.net](https://www.sourcemod.net/downloads.php) |
| GeoIP 数据库 | `sourcemod/configs/geoip/` | `./scripts/download-geoip.sh` |
| Metamod:Source | `../metamod/` | [metamodsource.net](https://www.metamodsource.net/) |

## 重要说明

- **不要直接提交含敏感信息的配置文件** — `admins.cfg`、`admins_simple.ini`、`databases.cfg`、`config.json` 等已在 `.gitignore` 中排除，使用 `.example` 模板
- 插件清单详见 `sourcemod/PLUGINS.md`
- 武器属性配置在 `sourcemod/configs/l4d2_weapon_data.cfg`
