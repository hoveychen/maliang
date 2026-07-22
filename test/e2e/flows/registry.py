#!/usr/bin/env python3
"""Flow Registry 内核（game-pilot 可复用流程中心 P1）：加载/校验 flows/registry.json、按名解析、
按 `depends` 拓扑排序（含环检测）、按 `args_schema` 校验入参。

MCP（P2）/ serve_web（P3）/ CLI（pilot_runner）三个入口都经这里解析出「要跑哪些 flow、什么顺序」，
再交给 pilot_runner 逐个 run(h,**args)——单一执行路径（设计 §4 A2）。

清单每条 flow 的字段（设计 §4）：
    name         唯一标识，按名调用
    desc         一句话描述
    kind         setup（前置夹具）| regression（被测流程）
    tags         检索标签
    script       相对 test/e2e/ 的脚本路径，暴露 run(h,**args)
    args_schema  {argName: "类型/说明"}；run_flow 按此校验+传入（值是描述串，非严格 JSON Schema）
    depends      前置 flow 名列表；runner 先按拓扑序跑完 depends 再跑本体
"""
import json
from pathlib import Path

# registry.py 在 test/e2e/flows/ 下；script 路径相对 test/e2e/（如 "flows/enter_world.py"）。
E2E_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_REGISTRY = Path(__file__).resolve().parent / "registry.json"

VALID_KINDS = ("setup", "regression")


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
        script = f.get("script")
        _require(isinstance(script, str) and script, f"flow {name} 缺 script")
        script_path = (E2E_ROOT / script).resolve()
        _require(script_path.exists(), f"flow {name} 的 script 不存在: {script_path}")
        args_schema = f.get("args_schema", {})
        _require(isinstance(args_schema, dict), f"flow {name} 的 args_schema 须为对象")
        depends = f.get("depends", [])
        _require(isinstance(depends, list) and all(isinstance(d, str) for d in depends),
                 f"flow {name} 的 depends 须为字符串数组")
        tags = f.get("tags", [])
        _require(isinstance(tags, list), f"flow {name} 的 tags 须为数组")
        flows[name] = {
            "name": name,
            "desc": f.get("desc", ""),
            "kind": kind,
            "tags": tags,
            "script": script,
            "script_path": str(script_path),
            "args_schema": args_schema,
            "depends": depends,
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
