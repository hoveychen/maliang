#!/usr/bin/env python3
"""Flow Registry 内核（game-pilot 可复用流程中心 P1）：加载/校验 flows/registry.json、按名解析、
按 `depends` 拓扑排序（含环检测）、按 `args_schema` 校验入参。

MCP（P2）/ serve_web（P3）/ CLI（pilot_cli）三个入口都经这里解析出「要跑哪些 flow、什么顺序」，
再交给 pilot_cli.py 逐个 run(h,**args)——单一执行路径（设计 §4 A2）。

清单每条 flow 的字段（设计 §4）：
    name         唯一标识，按名调用
    desc         一句话描述
    kind         setup（前置夹具）| regression（被测流程）
    tags         检索标签
    script       命令式 flow：相对 test/e2e/ 的 .py 路径，暴露 run(h,**args)（带逻辑用）
    steps        声明式 flow：数据步骤数组 [{op:do/say/wait/inject,…}]（录制序列化而来，与 script 二选一）
    args_schema  {argName: "类型/说明"}；run_flow 按此校验+传入（值是描述串，非严格 JSON Schema）
    depends      前置 flow 名列表；runner 先按拓扑序跑完 depends 再跑本体
"""
import json
from pathlib import Path

# registry.py 在 test/e2e/flows/ 下；script 路径相对 test/e2e/（如 "flows/enter_world.py"）。
E2E_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = Path(__file__).resolve().parent / "registry.json"

VALID_KINDS = ("setup", "regression")

# 声明式 flow 的合法步骤 op → 该 op 必需的字段。**只认定义词汇**（curated 动作 + 必要控制），
# 盲坐标/手势/god op（tap/drag/scene/phone/teleport/pick…）**结构上进不来**——这就是「不泄漏非定义
# 词汇的动作」由格式硬保证、不靠人自觉的地方（对齐四铁律「写进数据模型」）。executor 见 pilot_cli.run_steps。
DECLARATIVE_OPS = {
    "do":     ("action",),   # h.do(action, **args)——真输入执行一个 action_id
    "say":    ("text",),     # h.say(text)
    "wait":   ("conds",),    # h.wait_server(conds, timeout)
    "inject": (),            # h.inject()——换 ScriptedAsr（说话前置控制，非玩家动作）
}


def _validate_steps(name, steps):
    """声明式 flow 的 steps 校验（纯函数）：非空列表、每步 op ∈ DECLARATIVE_OPS、必需字段齐、类型对。
    非法 op（含任何 legacy 盲坐标动作）在此 fail-fast——声明式 flow 结构上装不下非定义词汇。"""
    _require(isinstance(steps, list) and steps, f"flow {name} 的 steps 须为非空数组")
    for j, s in enumerate(steps):
        _require(isinstance(s, dict), f"flow {name} steps[{j}] 不是对象")
        op = s.get("op")
        _require(op in DECLARATIVE_OPS,
                 f"flow {name} steps[{j}] 的 op 非法: {op!r}（只认 {sorted(DECLARATIVE_OPS)}"
                 f"——盲坐标/legacy 动作不可入声明式 flow）")
        for req in DECLARATIVE_OPS[op]:
            _require(req in s, f"flow {name} steps[{j}]({op}) 缺字段 {req}")
        if op == "do":
            _require(isinstance(s["action"], str) and s["action"],
                     f"flow {name} steps[{j}] do.action 须为非空字符串")
        elif op == "say":
            _require(isinstance(s["text"], str), f"flow {name} steps[{j}] say.text 须为字符串")
        elif op == "wait":
            _require(isinstance(s["conds"], list) and s["conds"],
                     f"flow {name} steps[{j}] wait.conds 须为非空数组")

# 可用性条件（P6）：每条是 (谓词(state)->bool, 不满足时的人话原因)。对齐 harness 的 action 模型——
# action 带 enabled + reason_disabled，flow 带 available + reasons。全部**从 state 快照算**，不靠 LLM 判断。
# flow 用 requires 声明「跑本体前需要哪些条件」；setup flow 用 provides 声明「跑完会建立哪些条件」。
CONDITIONS = {
    "in_world":        (lambda s: bool(s.get("world_id")),
                        "不在世界(world_id 为空)——需先进世界"),
    "online":          (lambda s: bool(s.get("ws_open")),
                        "未连服务器(ws_open=false)——离线/世界未起"),
    "villagers_ready": (lambda s: bool(s.get("ws_open")) and int(s.get("npc_count") or 0) >= 8,
                        "世界未就绪(ws_open + npc>=8 未满足)——冷缓存慢填/离线"),
    "vc_ready":        (lambda s: bool(s.get("vc_ready")),
                        "语音未就绪(vc_ready=false)——桌面需先 inject 换 ScriptedAsr"),
}


class RegistryError(Exception):
    """清单加载/校验/解析出错（缺字段、未知依赖、环、未知 flow、非法入参等）。"""


def _require(cond, msg):
    if not cond:
        raise RegistryError(msg)


def load_registry(path=None):
    """读并校验清单，返回 {name: flowdef}（flowdef 字段已补默认值，另加 script_path 绝对路径）。

    校验：name 唯一非空；kind ∈ setup|regression；script 存在；depends 均指向已知 flow；
    args_schema/tags/depends 类型正确。任一不满足抛 RegistryError（fail-fast，别让坏清单跑到一半）。
    """
    p = Path(path) if path else DEFAULT_REGISTRY
    _require(p.exists(), f"registry 清单不存在: {p}")
    try:
        raw = json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        raise RegistryError(f"registry 清单不是合法 JSON: {p}: {e}")
    _require(isinstance(raw, dict) and isinstance(raw.get("flows"), list),
             f"registry 清单顶层须为 {{\"flows\": [...]}}: {p}")

    flows = {}
    for i, f in enumerate(raw["flows"]):
        _require(isinstance(f, dict), f"flows[{i}] 不是对象")
        name = f.get("name")
        _require(isinstance(name, str) and name, f"flows[{i}] 缺 name（非空字符串）")
        _require(name not in flows, f"flow 名重复: {name}")
        kind = f.get("kind", "regression")
        _require(kind in VALID_KINDS, f"flow {name} 的 kind 非法: {kind}（须 {VALID_KINDS}）")
        # flow 二选一：script（命令式 .py，带逻辑，暴露 run(h)）或 steps（声明式数据，录制序列化而来）。
        script = f.get("script")
        steps = f.get("steps")
        _require((script is None) != (steps is None),
                 f"flow {name} 须恰好有 script 或 steps 之一"
                 f"（script=命令式 .py 带 run(h)；steps=声明式数据步骤）")
        script_path = None
        if script is not None:
            _require(isinstance(script, str) and script, f"flow {name} 的 script 须为非空字符串")
            script_path = str((E2E_ROOT / script).resolve())
            _require(Path(script_path).exists(), f"flow {name} 的 script 不存在: {script_path}")
        else:
            _validate_steps(name, steps)
        args_schema = f.get("args_schema", {})
        _require(isinstance(args_schema, dict), f"flow {name} 的 args_schema 须为对象")
        depends = f.get("depends", [])
        _require(isinstance(depends, list) and all(isinstance(d, str) for d in depends),
                 f"flow {name} 的 depends 须为字符串数组")
        tags = f.get("tags", [])
        _require(isinstance(tags, list), f"flow {name} 的 tags 须为数组")
        # P6：requires（本体前需要的条件）/ provides（setup 跑完建立的条件）——键须是已知 CONDITIONS。
        requires = f.get("requires", [])
        _require(isinstance(requires, list) and all(isinstance(c, str) for c in requires),
                 f"flow {name} 的 requires 须为字符串数组")
        for c in requires:
            _require(c in CONDITIONS, f"flow {name} 的 requires 含未知条件: {c}（已知: {sorted(CONDITIONS)}）")
        provides = f.get("provides", [])
        _require(isinstance(provides, list) and all(isinstance(c, str) for c in provides),
                 f"flow {name} 的 provides 须为字符串数组")
        for c in provides:
            _require(c in CONDITIONS, f"flow {name} 的 provides 含未知条件: {c}（已知: {sorted(CONDITIONS)}）")
        flows[name] = {
            "name": name,
            "desc": f.get("desc", ""),
            "kind": kind,
            "tags": tags,
            "script": script,
            "script_path": script_path,
            "steps": steps,
            "args_schema": args_schema,
            "depends": depends,
            "requires": requires,
            "provides": provides,
        }

    # depends 引用完整性：每个依赖都得是已知 flow（放到全部加载完再查，允许前向引用）。
    for name, f in flows.items():
        for d in f["depends"]:
            _require(d in flows, f"flow {name} 依赖未知 flow: {d}")

    return flows


def get(flows, name):
    """按名取 flowdef；未知则抛 RegistryError（列出可选名，便于纠错）。"""
    if name not in flows:
        raise RegistryError(f"未知 flow: {name}（可选: {sorted(flows)}）")
    return flows[name]


def resolve_order(flows, name):
    """解析 `name` 的执行顺序：depends 先、本体后，返回去重后的拓扑序 flow 名列表。

    用 DFS + 在栈标记检测环（A→B→A 抛 RegistryError，别让运行卡死）。同一依赖被多条链共享时只跑一次。
    """
    get(flows, name)  # 触发未知 flow 检查
    order = []
    seen = set()
    on_stack = set()

    def visit(n, trail):
        _require(n not in on_stack,
                 f"depends 存在环: {' -> '.join(trail + [n])}")
        if n in seen:
            return
        on_stack.add(n)
        for d in flows[n]["depends"]:
            visit(d, trail + [n])
        on_stack.discard(n)
        seen.add(n)
        order.append(n)

    visit(name, [])
    return order


def evaluate_now(flowdef, state):
    """运行时严格判：flow 的每条 requires 是否在**当前 state** 真满足。返回 {ok, reasons:[未满足的人话]}。

    runner 在 deps 跑完、本体开跑前调它——deps 已把 provides 真建立进 state，故这里只认真实状态、不做乐观。
    这就是把「声明的 requires」变成**硬 gate**（未满足抛错）的判据来源，不是散在各 flow 里手写 raise。
    """
    reasons = []
    for c in flowdef.get("requires", []):
        pred, why = CONDITIONS[c]
        if not pred(state or {}):
            reasons.append(why)
    return {"ok": not reasons, "reasons": reasons}


def availability(flows, name, state):
    """列表/展示用判：从**当前 state** 看这条 flow「现在能不能跑」，**乐观计入其 setup 依赖会 provides 的条件**。

    例：naming_e2e 在菜单态 in_world/villagers_ready 都为假，但它 depends=[enter_world]，enter_world provides
    villagers_ready → 显示为「可跑」（跑起来 enter_world 会先把世界带起）。返回 {ok, reasons:[未满足且无依赖提供]}。
    state 为空（游戏没连上）→ ok=None（未知），reasons 空——list 侧据此显示「未知/游戏未连」。
    """
    flow = get(flows, name)
    if not state:
        return {"ok": None, "reasons": []}
    # 依赖闭包里 setup flow 的 provides 并集（本体自己不算——它要求的正是别人给的）。
    provided = set()
    for dep in resolve_order(flows, name):
        if dep == name:
            continue
        if flows[dep]["kind"] == "setup":
            provided.update(flows[dep].get("provides", []))
    reasons = []
    for c in flow.get("requires", []):
        pred, why = CONDITIONS[c]
        if not pred(state) and c not in provided:
            reasons.append(why)
    return {"ok": not reasons, "reasons": reasons}


def validate_args(flowdef, args):
    """按 flow 的 args_schema 校验入参：拒绝未声明的键（args_schema 的值是描述串，故只做键面校验）。

    返回一份浅拷贝的 args（可安全 **展开传给 run）。args 为 None 视作空。
    """
    args = dict(args or {})
    schema = flowdef.get("args_schema", {})
    unknown = [k for k in args if k not in schema]
    _require(not unknown,
             f"flow {flowdef['name']} 收到未声明的参数: {unknown}（args_schema 声明: {sorted(schema)}）")
    return args
