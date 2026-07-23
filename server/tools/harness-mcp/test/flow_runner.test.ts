import { test } from "node:test";
import assert from "node:assert/strict";
import { buildRunnerArgs, parseRunnerJson, compactFlows, RUNNER_PATH } from "../src/flow_runner.ts";

test("buildRunnerArgs list：--list --with-availability + host/port（连游戏标 available）", () => {
  const a = buildRunnerArgs("list", { host: "127.0.0.1", port: 8578 });
  assert.equal(a[0], RUNNER_PATH);
  assert.deepEqual(a.slice(1), ["--list", "--with-availability", "--host", "127.0.0.1", "--port", "8578"]);
});

test("buildRunnerArgs flow：带 --flow/--json/--host/--port，无参不加 --args", () => {
  const a = buildRunnerArgs("flow", { host: "127.0.0.1", port: 8578 }, { name: "enter_world" });
  assert.equal(a[0], RUNNER_PATH);
  assert.deepEqual(a.slice(1), ["--flow", "enter_world", "--json", "--host", "127.0.0.1", "--port", "8578"]);
});

test("buildRunnerArgs flow：有参把 args 序列化成 JSON 追加 --args", () => {
  const a = buildRunnerArgs("flow", { host: "h", port: 9 }, { name: "naming_e2e", args: { name: "小火箭" } });
  const i = a.indexOf("--args");
  assert.ok(i > 0, "应含 --args");
  assert.deepEqual(JSON.parse(a[i + 1]), { name: "小火箭" });
});

test("buildRunnerArgs flow：空 args 对象不追加 --args", () => {
  const a = buildRunnerArgs("flow", { host: "h", port: 9 }, { name: "enter_world", args: {} });
  assert.equal(a.includes("--args"), false);
});

test("buildRunnerArgs flow：缺 name 抛错", () => {
  assert.throws(() => buildRunnerArgs("flow", { host: "h", port: 9 }, { name: "" }), /需要 flow name/);
});

test("parseRunnerJson：取最后一行合法 JSON，跳过前面的日志行", () => {
  const out = "[runner] connected\nsome noise\n{\"ok\":true,\"flow\":\"enter_world\",\"coverage\":{}}\n";
  const v = parseRunnerJson(out);
  assert.equal(v.ok, true);
  assert.equal(v.flow, "enter_world");
});

test("parseRunnerJson：多行 JSON 时取最后一个对象", () => {
  const out = '{"ok":false,"stale":1}\n{"ok":true,"final":1}\n';
  assert.equal(parseRunnerJson(out).final, 1);
});

test("parseRunnerJson：无任何 JSON 行抛错", () => {
  assert.throws(() => parseRunnerJson("just logs\nno json here\n"), /未输出可解析 JSON/);
});

test("compactFlows：抽出 name/kind/desc 并把 available.ok 归一成 true/false/null", () => {
  const list = {
    ok: true,
    flows: [
      { name: "enter_world", kind: "setup", desc: "进世界", available: { ok: true, reasons: [] } },
      { name: "naming_e2e", kind: "regression", desc: "造物起名", available: { ok: false, reasons: ["世界未就绪"] } },
      { name: "no_avail", kind: "setup", available: { ok: null } },
    ],
  };
  assert.deepEqual(compactFlows(list), [
    { name: "enter_world", kind: "setup", available: true, desc: "进世界" },
    { name: "naming_e2e", kind: "regression", available: false, desc: "造物起名" },
    { name: "no_avail", kind: "setup", available: null, desc: undefined },
  ]);
});

test("compactFlows：缺 flows 字段 / null 入参 → 空数组（绝不让 observe 挂）", () => {
  assert.deepEqual(compactFlows(null), []);
  assert.deepEqual(compactFlows({}), []);
  assert.deepEqual(compactFlows({ flows: "oops" as unknown as [] }), []);
});
