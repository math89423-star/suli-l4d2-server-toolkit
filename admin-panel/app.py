#!/usr/bin/env python3
import hashlib, json, os, re, secrets, shutil, subprocess, sys, tempfile, zipfile
from datetime import timedelta
from functools import wraps
from flask import Flask, jsonify, request, session, send_from_directory
from rcon.source import Client as RCONClient

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")
MAPS_FILE = os.path.join(BASE_DIR, "maps.json")

def load_config():
    with open(CONFIG_FILE) as f: return json.load(f)

def save_config(co):
    with open(CONFIG_FILE,"w") as f: json.dump(co,f,indent=4,ensure_ascii=False)

cfg = load_config()

if cfg.get("secret_key","").startswith("replace_"):
    cfg["secret_key"] = secrets.token_hex(32)
    save_config(cfg)

if "replace_me" in cfg.get("admin_password_hash",""):
    pw = os.environ.get("L4D2_ADMIN_PASSWORD","admin123")
    s = secrets.token_hex(16)
    h = hashlib.sha256(f"{pw}:{s}".encode()).hexdigest()
    cfg["admin_password_hash"] = f"sha256:{s}:{h}"
    save_config(cfg)
    print(f"[init] Admin password: {pw}", file=sys.stderr)

app = Flask(__name__)
app.secret_key = cfg["secret_key"]
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(days=30)
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["MAX_CONTENT_LENGTH"] = 2 * 1024 * 1024 * 1024  # 2 GB max upload

def check_password(pw):
    p = cfg["admin_password_hash"].split(":")
    if len(p)!=3 or p[0]!="sha256": return False
    return hashlib.sha256(f"{pw}:{p[1]}".encode()).hexdigest() == p[2]

def login_required(f):
    @wraps(f)
    def d(*a,**k):
        if not session.get("authed"): return jsonify({"error":"unauthorized"}),401
        return f(*a,**k)
    return d

def rcon(cmd):
    with RCONClient(cfg["rcon_host"],cfg["rcon_port"],passwd=cfg["rcon_password"]) as c:
        return c.run(cmd).strip()

def load_labels():
    with open(MAPS_FILE) as f: return json.load(f).get("map_labels",{})

@app.route("/api/login",methods=["POST"])
def api_login():
    d = request.get_json(silent=True) or {}
    if check_password(d.get("password","")):
        session.permanent = True
        session["authed"] = True
        return jsonify({"ok":True})
    return jsonify({"error":"wrong password"}),403

@app.route("/api/logout",methods=["POST"])
def api_logout():
    session.clear()
    return jsonify({"ok":True})

@app.route("/api/check")
def api_check():
    """Lightweight session check — no RCON calls."""
    if session.get("authed"):
        return jsonify({"authed":True})
    return jsonify({"authed":False}),401

@app.route("/api/status")
@login_required
def api_status():
    try: raw = rcon("status")
    except Exception as e: return jsonify({"error":str(e),"online":False}),500
    hn,mp,pl,mx = "","","0","24"
    for line in raw.split("\n"):
        line=line.strip()
        if line.startswith("hostname:"): hn=line.split(":",1)[1].strip()
        elif line.startswith("map"):
            ps=line.split()
            if len(ps)>=2: mp=ps[2].strip()
        elif line.startswith("players"):
            m=re.match(r"players\s*:\s*(\d+)\s*humans.*\((\d+)\s*max\)",line)
            if m: pl,mx=m.group(1),m.group(2)
    tr=""
    try:
        raw2=rcon("sm_cvar sv_maxcmdrate")
        m=re.search(r'"sv_maxcmdrate"\s*[:=]\s*"([^"]+)"',raw2)
        if m:
            tr=m.group(1)
    except: pass
    lb=load_labels()
    # Check if restart is needed (any VPK newer than last restart)
    restart_needed = False
    addons_dir = cfg.get("addons_dir", "/opt/gameservers/l4d2/data/addons")
    last_restart = cfg.get("last_restart", 0)
    if os.path.isdir(addons_dir):
        try:
            for fn in os.listdir(addons_dir):
                if fn.lower().endswith(".vpk"):
                    vpk_mtime = os.path.getmtime(os.path.join(addons_dir, fn))
                    if vpk_mtime > last_restart:
                        restart_needed = True
                        break
        except:
            pass
    return jsonify({"online":True,"hostname":hn,"map":mp,
        "map_label":lb.get(mp,mp),"players":int(pl),
        "maxplayers":int(mx),"tickrate":tr,
        "restart_needed": restart_needed})

@app.route("/api/maps")
@login_required
def api_maps():
    with open(MAPS_FILE) as f: return jsonify(json.load(f))

def _read_mapcycle(path):
    """Return [{name,label}] list from a mapcycle file."""
    if not os.path.exists(path): return []
    with open(path) as f:
        ms=[l.strip() for l in f if l.strip() and not l.startswith("//")]
    lb=load_labels()
    return [{"name":m,"label":lb.get(m,m)} for m in ms]

def _active_pool_state_path():
    return os.path.join(os.path.dirname(cfg["mapcycle_path"]), ".active_pool")

def _detect_active_pool():
    """Read which pool is active from the state file."""
    sp = _active_pool_state_path()
    if os.path.exists(sp):
        with open(sp) as f:
            pool = f.read().strip()
            if pool in ("official", "custom"):
                return pool
    return "unknown"

def _pool_path(pool):
    """Resolve a pool name to its file path."""
    if pool in ("official","custom"):
        return cfg.get(f"mapcycle_{pool}_path",cfg["mapcycle_path"])
    return cfg["mapcycle_path"]

@app.route("/api/mapcycle",methods=["GET"])
@login_required
def api_get_mapcycle():
    pool=request.args.get("type","").strip()
    if pool:
        p=_pool_path(pool)
        if not os.path.exists(p): return jsonify({"error":"not found"}),404
        return jsonify({"maps":_read_mapcycle(p),"pool":pool})
    # No type → return everything
    return jsonify({
        "active_pool":_detect_active_pool(),
        "official":_read_mapcycle(cfg["mapcycle_official_path"]),
        "custom":_read_mapcycle(cfg["mapcycle_custom_path"]),
    })

@app.route("/api/mapcycle",methods=["PUT"])
@login_required
def api_put_mapcycle():
    d=request.get_json(silent=True) or {}
    ms=d.get("maps",[])
    if not ms: return jsonify({"error":"empty"}),400
    pool=request.args.get("type","").strip()
    p=_pool_path(pool) if pool else cfg["mapcycle_path"]
    with open(p,"w") as f:
        for m in ms: f.write(m+"\n")
    return jsonify({"ok":True,"count":len(ms),"pool":pool or "active"})

@app.route("/api/mapcycle/activate",methods=["POST"])
@login_required
def api_activate_mapcycle():
    d=request.get_json(silent=True) or {}
    pool=d.get("type","").strip()
    if pool not in ("official","custom"):
        return jsonify({"error":"invalid type, must be official or custom"}),400
    src=cfg.get(f"mapcycle_{pool}_path","")
    if not src or not os.path.exists(src):
        return jsonify({"error":f"mapcycle_{pool}.txt not found"}),404
    shutil.copy2(src,cfg["mapcycle_path"])
    with open(_active_pool_state_path(), "w") as f:
        f.write(pool)
    return jsonify({"ok":True,"active_pool":pool})

import time as _time
_LAST_SWITCH = 0.0
_SWITCH_TARGET = ""          # map we're waiting to load
_SWITCH_LOADED_AT = 0.0      # when server confirmed target loaded
_POST_LOAD_BUFFER = cfg.get("post_switch_buffer", 15)  # seconds after load before release
_SWITCH_TIMEOUT = 120        # max seconds for map load; after this, assume stale and clear

def _get_current_map():
    """Get current map name from server status. Returns '' on failure."""
    try:
        raw = rcon("status")
        for line in raw.split("\n"):
            line = line.strip()
            if line.startswith("map"):
                ps = line.split()
                if len(ps) >= 2:
                    return ps[2].strip()
    except:
        pass
    return ""

@app.route("/api/cooldown")
@login_required
def api_cooldown():
    """Return switch lock state: loading / post-load buffer / ready."""
    global _SWITCH_TARGET, _SWITCH_LOADED_AT, _LAST_SWITCH
    if not _SWITCH_TARGET:
        return jsonify({"loading": False, "remaining": 0, "current": _get_current_map()})

    elapsed = _time.time() - _LAST_SWITCH
    current = _get_current_map()
    loaded = (current == _SWITCH_TARGET)

    # Auto-clear if switch timed out: map never loaded (or already moved past target)
    if not loaded and elapsed > _SWITCH_TIMEOUT:
        _SWITCH_TARGET = ""
        _SWITCH_LOADED_AT = 0.0
        return jsonify({"loading": False, "remaining": 0, "current": current})

    if loaded and _SWITCH_LOADED_AT == 0:
        _SWITCH_LOADED_AT = _time.time()

    if not loaded:
        # Still loading — remaining shows elapsed time for UI
        return jsonify({"loading": True, "target": _SWITCH_TARGET,
            "current": current, "elapsed": round(elapsed, 1),
            "remaining": round(elapsed, 1)})

    # Loaded — compute post-load buffer remaining
    buffer_remain = max(0, _POST_LOAD_BUFFER - (_time.time() - _SWITCH_LOADED_AT))
    if buffer_remain <= 0:
        _SWITCH_TARGET = ""       # fully done, release lock
        _SWITCH_LOADED_AT = 0.0
        return jsonify({"loading": False, "remaining": 0, "current": current})

    return jsonify({"loading": False, "target": _SWITCH_TARGET,
        "current": current, "elapsed": round(elapsed, 1),
        "remaining": round(buffer_remain, 1), "buffer": _POST_LOAD_BUFFER})

@app.route("/api/switch",methods=["POST"])
@login_required
def api_switch():
    global _LAST_SWITCH, _SWITCH_TARGET, _SWITCH_LOADED_AT
    d=request.get_json(silent=True) or {}
    t=d.get("map","").strip()
    if not t: return jsonify({"error":"no map"}),400

    # Check if a switch is already in progress
    if _SWITCH_TARGET:
        current = _get_current_map()
        if current != _SWITCH_TARGET:
            # Target not yet reached — check if this is a stale state
            elapsed = _time.time() - _LAST_SWITCH
            if elapsed > _SWITCH_TIMEOUT:
                # Stale state from a previous switch whose polling was abandoned
                _SWITCH_TARGET = ""
                _SWITCH_LOADED_AT = 0.0
            else:
                elapsed = round(_time.time() - _LAST_SWITCH, 1)
                return jsonify({"error": f"正在加载 {_SWITCH_TARGET}，已等待 {elapsed} 秒，请等待加载完成"}), 429
        else:
            # Loaded but buffer active
            buffer_remain = max(0, _POST_LOAD_BUFFER - (_time.time() - _SWITCH_LOADED_AT))
            if buffer_remain > 0:
                return jsonify({"error": f"地图刚加载完成，请等待 {round(buffer_remain,1)} 秒让玩家进入"}), 429
            # Buffer expired, clear and allow
            _SWITCH_TARGET = ""
            _SWITCH_LOADED_AT = 0.0

    # Detect if we're currently on a tumtara map (need special plugin handling)
    current_map = ""
    try:
        current_map = _get_current_map()
    except:
        pass
    coming_from_tumtara = current_map in cfg.get("tumtara_maps", [])
    going_to_tumtara = t in cfg.get("tumtara_maps", [])

    if going_to_tumtara:
        # Unload multi-SI plugins before switching (tumtara has no nav mesh)
        for plg in cfg.get("tumtara_unload_plugins", []):
            try: rcon(f"sm plugins unload {plg}")
            except: pass
    try:
        _LAST_SWITCH = _time.time()
        _SWITCH_TARGET = t
        _SWITCH_LOADED_AT = 0.0
        rs=rcon(f"sm_map {t}")
        # Reload multi-SI plugins when leaving tumtara
        if coming_from_tumtara and not going_to_tumtara:
            for plg in cfg.get("tumtara_unload_plugins", []):
                try: rcon(f"sm plugins load {plg}")
                except: pass
        return jsonify({"ok":True,"map":t,"result":rs,"buffer":_POST_LOAD_BUFFER})
    except Exception as e:
        _SWITCH_TARGET = ""  # clear on error
        return jsonify({"error":str(e)}),500

# ── Map extraction helper ──────────────────────────────────

def _extract_map_names(vpk_path):
    """Extract BSP map names from a VPK using strings. Returns sorted list."""
    maps = set()
    vpk_path = os.path.realpath(vpk_path)
    # Handle ZIP-wrapped VPK (e.g. deadcity2)
    if zipfile.is_zipfile(vpk_path):
        with zipfile.ZipFile(vpk_path, 'r') as zf:
            names = zf.namelist()
            vpk_inside = [n for n in names if n.lower().endswith('.vpk')]
            other = [n for n in names if not n.lower().endswith('.vpk')]
            if vpk_inside and not other:
                td = tempfile.mkdtemp(prefix="l4d2_vpk_")
                try:
                    zf.extract(vpk_inside[0], td)
                    return _extract_map_names(os.path.join(td, vpk_inside[0]))
                finally:
                    shutil.rmtree(td, ignore_errors=True)
            for name in names:
                if name.lower().endswith('.bsp'):
                    m = os.path.basename(name)[:-4].replace(' ', '_').lower()
                    if re.match(r'^[a-z][a-z0-9_]*[a-z0-9]$', m) and len(m) >= 4:
                        maps.add(m)
    try:
        result = subprocess.run(['strings', vpk_path], capture_output=True, text=True, timeout=30)
        for line in result.stdout.split('\n'):
            line = line.strip()
            if not line.lower().endswith('.bsp'):
                continue
            name = os.path.basename(line)
            if name.lower().endswith('.bsp'):
                name = name[:-4]
            name = name.replace(' ', '_').lower()
            if re.match(r'^[a-z][a-z0-9_]*[a-z0-9]$', name) and len(name) >= 4:
                maps.add(name)
    except:
        pass
    return sorted(maps)

def _natural_key(name):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r'(\d+)', name)]

# ── Map upload / workshop / restart ─────────────────────────

@app.route("/api/maps/upload", methods=["POST"])
@login_required
def api_maps_upload():
    if "file" not in request.files:
        return jsonify({"error": "no file"}), 400
    f = request.files["file"]
    if not f.filename or not f.filename.lower().endswith(".zip"):
        return jsonify({"error": "only .zip allowed"}), 400

    # Save ZIP to authoritative source (also serves as download server)
    maps_zip_dir = cfg.get("maps_zip_dir", "/home/ubuntu/l4d2-maps")
    os.makedirs(maps_zip_dir, exist_ok=True)
    zip_dst = os.path.join(maps_zip_dir, f.filename)
    try:
        f.save(zip_dst)
    except Exception as e:
        return jsonify({"error": f"save zip failed: {e}"}), 500

    # Unzip VPK to temp
    tmpdir = tempfile.mkdtemp(prefix="l4d2_upload_")
    try:
        subprocess.run(["unzip", "-o", zip_dst, "*.vpk", "-d", tmpdir],
                       capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": "unzip timeout"}), 500
    except Exception as e:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": f"unzip failed: {e}"}), 500

    # Find VPK files
    vpks = []
    for fn in sorted(os.listdir(tmpdir)):
        if fn.lower().endswith(".vpk"):
            vpks.append(os.path.join(tmpdir, fn))

    if not vpks:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": "no .vpk found in zip"}), 400

    # Copy VPK: addons/ (engine) + thirdparty-maps/ (backup)
    addons = cfg.get("addons_dir", "/opt/gameservers/l4d2/data/addons")
    vpk_dir = cfg.get("maps_vpk_dir", "/home/ubuntu/l4d2-thirdparty-maps")
    os.makedirs(vpk_dir, exist_ok=True)
    copied = []
    for vpk in vpks:
        for dest_dir in (addons, vpk_dir):
            dst = os.path.join(dest_dir, os.path.basename(vpk))
            shutil.copy2(vpk, dst)
            os.chmod(dst, 0o644)
        copied.append(os.path.basename(vpk))

    # Run scan_maps.py to regenerate maps.json
    scan = cfg.get("scan_script", os.path.join(BASE_DIR, "scan_maps.py"))
    scan_ok = False
    try:
        r = subprocess.run([sys.executable, scan], capture_output=True, text=True, timeout=60)
        scan_ok = (r.returncode == 0)
    except:
        pass

    shutil.rmtree(tmpdir, ignore_errors=True)
    return jsonify({
        "ok": True,
        "vpks": copied,
        "need_restart": True,
        "scan_ok": scan_ok,
    })


@app.route("/api/maps/workshop", methods=["POST"])
@login_required
def api_maps_workshop():
    d = request.get_json(silent=True) or {}
    url = d.get("url", "").strip()
    if not url:
        return jsonify({"error": "no url or id"}), 400

    # Extract workshop ID
    wid = None
    if url.isdigit():
        wid = url
    else:
        for pat in [r'[?&]id=(\d+)', r'/filedetails/(\d+)', r'/sharedfiles/(\d+)']:
            m = re.search(pat, url)
            if m:
                wid = m.group(1)
                break
    if not wid:
        return jsonify({"error": "cannot extract workshop id"}), 400

    # Download via steamcmd
    steamcmd = cfg.get("steamcmd_path", "/usr/games/steamcmd")
    tmpdir = tempfile.mkdtemp(prefix="l4d2_ws_")
    try:
        subprocess.run(
            [steamcmd, "+login", "anonymous", "+workshop_download_item", "550", wid, "+quit"],
            capture_output=True, text=True, timeout=300, cwd=tmpdir
        )
    except subprocess.TimeoutExpired:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": "steamcmd timeout (5min)"}), 500
    except Exception as e:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": f"steamcmd failed: {e}"}), 500

    # Find downloaded VPK
    vpks = []
    for root, dirs, files in os.walk(tmpdir):
        for fn in files:
            if fn.lower().endswith(".vpk"):
                vpks.append(os.path.join(root, fn))
    if not vpks:
        # Also check steamapps directory
        for root, dirs, files in os.walk(os.path.expanduser("~/.local/share/Steam")):
            for fn in files:
                if fn.lower().endswith(".vpk"):
                    vpks.append(os.path.join(root, fn))

    if not vpks:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": "download succeeded but no vpk found"}), 500

    # Extract map names
    maps = []
    for vpk in vpks:
        maps.extend(_extract_map_names(vpk))
    maps = sorted(set(maps), key=_natural_key)
    if not maps:
        shutil.rmtree(tmpdir, ignore_errors=True)
        return jsonify({"error": "no maps found in vpk"}), 500

    first_map = maps[0]
    # Generate campaign id from first map
    cid = re.sub(r'[^a-z0-9_]', '', first_map.rsplit('_', 1)[0]) if '_' in first_map else first_map
    if len(cid) < 2:
        cid = "ws_" + wid

    # Add to maps.json
    with open(MAPS_FILE) as f:
        mj = json.load(f)
    # Check duplicate
    for cat in mj["categories"]:
        for camp in cat["campaigns"]:
            if camp["maps"][0] == first_map:
                shutil.rmtree(tmpdir, ignore_errors=True)
                return jsonify({"error": f"map already exists: {camp['name']}"}), 409

    new_camp = {
        "id": cid, "name": f"Workshop {wid}", "alias": cid,
        "maps": maps, "size": "工坊"
    }
    for cat in mj["categories"]:
        if cat["id"] == "custom":
            cat["campaigns"].append(new_camp)
            break
    mj["aliases"][cid] = first_map
    existing_labels = mj.get("map_labels", {})
    for i, m in enumerate(maps):
        if m not in existing_labels:
            existing_labels[m] = f"Workshop {wid}-{i + 1}"
    mj["map_labels"] = existing_labels
    with open(MAPS_FILE, "w") as f:
        json.dump(mj, f, indent=2, ensure_ascii=False)

    # Add first map to custom mapcycle
    mcp = cfg.get("mapcycle_custom_path", "")
    if mcp:
        existing = []
        if os.path.exists(mcp):
            with open(mcp) as f:
                existing = [l.strip() for l in f if l.strip()]
        if first_map not in existing:
            with open(mcp, "a") as f:
                f.write(first_map + "\n")

    shutil.rmtree(tmpdir, ignore_errors=True)
    return jsonify({
        "ok": True, "workshop_id": wid,
        "campaign": new_camp, "maps": maps,
    })


@app.route("/api/server/restart", methods=["POST"])
@login_required
def api_server_restart():
    d = request.get_json(silent=True) or {}
    force = d.get("force", False)

    # Check players if not forced
    if not force:
        try:
            raw = rcon("status")
            for line in raw.split("\n"):
                line = line.strip()
                if line.startswith("players"):
                    m = re.match(r"players\s*:\s*(\d+)\s*humans", line)
                    if m and int(m.group(1)) > 0:
                        return jsonify({"confirm_required": True, "players": int(m.group(1))})
                    break
        except:
            pass

    try:
        result = subprocess.run(
            ["docker", "restart", "l4d2-server"],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            return jsonify({"error": result.stderr.strip()}), 500
        # Record restart time so frontend knows restart is no longer needed
        cfg["last_restart"] = _time.time()
        save_config(cfg)
        return jsonify({"ok": True, "message": "服务器正在重启..."})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/")
def index():
    return send_from_directory(os.path.join(BASE_DIR,"templates"),"index.html")

@app.route("/style.css")
def style():
    return send_from_directory(os.path.join(BASE_DIR,"static"),"style.css")

@app.route("/static/<path:filename>")
def static_files(filename):
    return send_from_directory(os.path.join(BASE_DIR,"static"),filename)

@app.route("/webfonts/<path:filename>")
def webfonts(filename):
    return send_from_directory(os.path.join(BASE_DIR,"static","webfonts"),filename)

@app.route("/health")
def health():
    return jsonify({"ok":True})

if __name__=="__main__":
    h=cfg.get("host","127.0.0.1")
    p=cfg.get("port",5000)
    print(f"[l4d2-admin] {h}:{p}",file=sys.stderr)
    app.run(host=h,port=p,debug=False,threaded=True)
