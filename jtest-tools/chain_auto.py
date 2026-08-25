#!/usr/bin/env python3
"""
chain_auto.py — 三方图解密链自动还原器(通用)

用法:
  python3 chain_auto.py <campaign.vpk>              # 包内全部 .bsp
  python3 chain_auto.py <campaign.vpk> re1m1        # 指定地图

原理:
  1. 解析 VPK 树抽取 BSP(单档/dir 档/LZMA 兼容)
  2. 解析实体块(保留重复输出键——一个按钮常挂多条 OnPressed)
  3. 定位出口门(script_changelevel 等; 无则 refugio/exit 名字启发)
  4. 反向链推导: 从出口沿 I/O 边回溯"解锁者"集合
     (enabler 输入白名单: Unlock/Enable/UnblockNav/Trigger/Increment/Open...)
  5. 集合内依赖最长路分层 → 有序步骤 → ptg_objectives.cfg 草稿
     (同层并列的天然分组; relay/logic 只做中转不进步骤)
"""
import struct, sys, os, re, lzma

ENABLERS = {'unlock','enable','unblocknav','trigger','increment','add',
            'open','forcespawn','setvalue','kill','startglowing','disablemotion'}
EXIT_CLASSES = {'script_changelevel','trigger_changelevel','info_changelevel'}
INTERACTIVE = {
    'func_button':'button','func_rot_button':'button','momentary_rot_button':'button',
    'prop_door_rotating':'door','func_door':'door_f','func_door_rotating':'door_dr',
    'func_breakable':'breakable','func_breakable_surf':'breakable',
    'math_counter':'counter','weapon_gascan':'pickup',
    'trigger_once':'trigger','trigger_multiple':'trigger',
}
LOGIC = {'logic_relay','logic_branch','logic_auto'}
DEFAULT_OUT = {'button':'OnPressed','door':'OnOpen','door_f':'OnOpen',
               'door_dr':'OnOpen','breakable':'OnBreak','counter':'OnHitMax',
               'pickup':'OnPlayerPickup','trigger':'OnStartTouch'}

# ── VPK ──────────────────────────────────────────────────────
def vpk_tree(path):
    with open(path,'rb') as f:
        sig, ver, treesz = struct.unpack('<III', f.read(12))
        assert sig == 0x55AA1234, hex(sig)
        base = 28+treesz if ver == 2 else 12+treesz
        def cs():
            b=bytearray()
            while True:
                c=f.read(1)
                if c in (b'\x00',b''): break
                b+=c
            return b.decode('utf8','replace')
        ent={}; ext=cs()
        while ext:
            p=cs()
            while p:
                n=cs()
                while n:
                    crc,pre,aidx,eoff,elen = struct.unpack('<IHHII', f.read(16))
                    f.read(2)
                    pl=f.read(pre) if pre else b''
                    ent[f"{p}/{n}.{ext}" if ext else f"{p}/{n}"]=(aidx,eoff,elen,pl)
                    n=cs()
                p=cs()
            ext=cs()
        return ent, base

def vpk_read(path, base, e):
    aidx,eoff,elen,pl = e
    if aidx == 0x7FFF or aidx == 0:
        with open(path,'rb') as f:
            f.seek(base+eoff); data=f.read(elen)
        if pl: data=(pl+data)[:elen]
        return data
    ap=os.path.splitext(path)[0]+f"_{aidx:03d}.vpk"
    with open(ap,'rb') as f:
        f.seek(eoff); data=f.read(elen)
    if pl: data=(pl+data)[:elen]
    return data

def unlzma(d):
    if d[:4]==b'LZMA':
        actual=struct.unpack('<I',d[8:12])[0]
        return lzma.LZMADecompressor(format=lzma.FORMAT_ALONE).decompress(d[17:])[:actual]
    return d

# ── 实体解析(保留重复键) ─────────────────────────────────────
def bsp_entities(bsp):
    i = bsp.find(b'{\n"world_maxs"')
    if i == -1: i = bsp.find(b'"classname"')
    if i == -1: return []
    txt = bsp[i:i+8_000_000].decode('latin-1')
    ents=[]
    for m in re.finditer(r'^\{(.*?)^\}', txt, re.S|re.M):
        props=[(k,v) for k,v in re.findall(r'"([^"\n]+)"\s+"([^"\n]*)"', m.group(1))]
        ents.append(props)
        if len(ents)>4000: break
    return ents

def gv(props,k,default=''):
    for kk,vv in props:
        if kk==k: return vv
    return default

def outputs(props):
    r=[]
    for k,v in props:
        if not k.startswith('On'): continue
        # BSP 实体 I/O 字段分隔符是 0x1B(ESC), 兼容逗号写法
        parts=[p.strip() for p in re.split(r'[\x1b,]', v)]
        tgt=parts[0] if parts else ''
        inp=parts[1].lower() if len(parts)>1 else ''
        if tgt in ('','<null>','!self','!activator','!caller'): continue
        r.append((k,tgt,inp))
    return r

# ── 链推导 ───────────────────────────────────────────────────
def analyze(ents):
    by_name={}
    for idx,e in enumerate(ents):
        tn=gv(e,'targetname')
        if tn: by_name.setdefault(tn,[]).append(idx)

    gates=set()
    for e in ents:
        if gv(e,'classname') in EXIT_CLASSES:
            t=gv(e,'targetname')
            if t: gates.add(t)
    # 启发式始终并入(切图实体常无输入连线, 反向链要挂在安全门上)
    for e in ents:
        tn=gv(e,'targetname').lower(); cn=gv(e,'classname')
        if 'door' in cn and any(s in tn for s in ('refugio','exit','salida')):
            t=gv(e,'targetname')
            if t: gates.add(t)
    if not gates:
        return [], [], "no exit entity found"

    feeds={}
    for idx,e in enumerate(ents):
        for _,tgt,inp in outputs(e):
            feeds.setdefault(tgt,[]).append((idx,inp))

    needed=set(); frontier=list(gates)   # 按目标名回溯(与 feeds 键一致)
    while frontier:
        nm=frontier.pop()
        for src,inp in feeds.get(nm,[]):
            c=gv(ents[src],'classname')
            if inp not in ENABLERS: continue
            if c not in INTERACTIVE and c not in LOGIC: continue
            if src in needed: continue
            needed.add(src)
            tn=gv(ents[src],'targetname')
            if tn: frontier.append(tn)   # 继续回溯该实体的解锁者

    # 只留交互实体为步骤; relay 已把上游带进集合
    steps=[i for i in needed if gv(ents[i],'classname') in INTERACTIVE]

    sids=set(steps)
    prereq={i:set() for i in steps}
    for i in steps:
        tn=gv(ents[i],'targetname')
        if not tn: continue
        for src,inp in feeds.get(tn,[]):
            if src in sids and src!=i and inp in ENABLERS:
                prereq[i].add(src)

    depth={}
    def dd(i, stack=frozenset()):
        if i in depth: return depth[i]
        d=0
        for p in prereq.get(i,()):
            if p in stack: continue
            d=max(d, dd(p, stack|{i})+1)
        depth[i]=d
        return d
    for i in steps: dd(i)
    steps.sort(key=lambda i:(depth.get(i,0), gv(ents[i],'targetname')))

    # ── 兜底: 出口关联缺失时(VScript 门控/触摸式切图), 切换为
    #    "交互组件模式"——收集一切参与解锁链的交互物整体分层 ──
    if len(steps) < 2:
        nodes=set(); edges={}
        for idx,e in enumerate(ents):
            c=gv(e,'classname')
            if c not in INTERACTIVE and c not in LOGIC: continue
            tn=gv(e,'targetname')
            if not tn: continue
            for src,inp in feeds.get(tn,[]):
                sc=gv(ents[src],'classname')
                if inp not in ENABLERS: continue
                if sc not in INTERACTIVE and sc not in LOGIC: continue
                if src==idx: continue
                nodes.add(idx); nodes.add(src)
                edges.setdefault(src,set()).add(idx)
        # 去掉没有出边也没有入边的孤点
        has_edge=set()
        for s,ds in edges.items():
            has_edge.add(s); has_edge |= ds
        nodes &= has_edge
        isteps=[i for i in nodes if gv(ents[i],'classname') in INTERACTIVE]
        dep2={}
        def dd2(i, stack=frozenset()):
            if i in dep2: return dep2[i]
            d=0
            for p in edges.get(i,()):
                if p in stack or p not in dep2 and p!=i:
                    pass
                if p in stack: continue
                d=max(d,(dd2(p,stack|{i})+1) if p in nodes else 0)
            dep2[i]=d
            return d
        for i in isteps: dd2(i)
        isteps.sort(key=lambda i:(dep2.get(i,0), gv(ents[i],'targetname')))
        if len(isteps)>len(steps):
            steps=isteps
    return steps, gates, None

# ── 主流程 ───────────────────────────────────────────────────
def gen_config(vpkpath, only=None):
    entries, base = vpk_tree(vpkpath)
    bsps = sorted(k for k in entries if k.endswith('.bsp') and (not only or only in os.path.basename(k)))
    print(f'// vpk={os.path.basename(vpkpath)} maps={len(bsps)}')
    print('"objectives"\n{')
    for k in bsps:
        mapname=os.path.splitext(os.path.basename(k))[0]
        ents=bsp_entities(unlzma(vpk_read(vpkpath, base, entries[k])))
        if not ents:
            print(f'\t// {mapname}: no entities parsed'); continue
        steps,gates,err=analyze(ents)
        if err:
            print(f'\t// {mapname}: {err} (ents={len(ents)})'); continue
        print(f'\t"{mapname}"\n\t{{')
        n=0
        prev_depth=None
        for i in steps:
            e=ents[i]; cn=gv(e,'classname'); tn=gv(e,'targetname')
            t=INTERACTIVE[cn]
            n+=1
            attrs=[f'"type" "{t}"']
            if cn != {'button':'func_button','door':'prop_door_rotating','door_f':'func_door',
                      'door_dr':'func_door_rotating','breakable':'func_breakable',
                      'counter':'math_counter','pickup':'weapon_gascan',
                      'trigger':'trigger_once'}[t]:
                attrs.append(f'"class" "{cn}"')
            if tn: attrs.append(f'"name" "{tn}"')
            org=gv(e,'origin')
            if org:
                p=org.split(' ')
                if len(p)==3: attrs.append(f'"pos" "{p[0]} {p[1]} {p[2]}"')
            hint=tn.replace('"','')
            print(f'\t\t"{n}" {{ {" ".join(attrs)}\n\t\t       "hint" "[TODO:{cn}] {hint}" }}')
        print('\t}')
    print('}')

if __name__=='__main__':
    gen_config(sys.argv[1], sys.argv[2] if len(sys.argv)>2 else None)
