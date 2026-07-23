#!/usr/bin/env python3
"""内容包分发 P5：把 build/packs/*.pck 入库到服务端（POST /admin/packs/:name）。

服务端运行时读不到 assets/packs/*.json（Docker 只 COPY server/），故 renderRef→pack 的映射
必须在入库时随 .pck 一起登记 keys——本脚本从 build/packs/registry.json（由 gen-content-pack-presets.py
产出）读出每个包的 keys 传入。voice/bgm 无键包 keys=[]（靠 GET /packs 按名解析）。

用法：
  scripts/register-content-packs.py <server-base> [--token <admin-token>] [--only name1,name2]
  例：scripts/register-content-packs.py http://127.0.0.1:8080
      scripts/register-content-packs.py https://... --token $MALIANG_ADMIN_TOKEN
token 缺省从 server/.env 的 MALIANG_ADMIN_TOKEN 读（prod-admin-endpoint recipe）。
"""
import base64
import json
import os
import sys
import urllib.request
import urllib.error

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read_env_token():
    envp = os.path.join(REPO, 'server', '.env')
    if not os.path.exists(envp):
        return None
    for line in open(envp):
        line = line.strip()
        if line.startswith('MALIANG_ADMIN_TOKEN='):
            return line.split('=', 1)[1].strip().strip('"').strip("'")
    return None


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(2)
    base = args[0].rstrip('/')
    token = None
    only = None
    i = 1
    while i < len(args):
        if args[i] == '--token':
            token = args[i + 1]; i += 2
        elif args[i] == '--only':
            only = set(args[i + 1].split(',')); i += 2
        else:
            print('未知参数 %s' % args[i]); sys.exit(2)
    token = token or read_env_token()
    if not token:
        print('缺 admin token（--token 或 server/.env 的 MALIANG_ADMIN_TOKEN）'); sys.exit(2)

    reg_path = os.path.join(REPO, 'build', 'packs', 'registry.json')
    if not os.path.exists(reg_path):
        print('缺 %s——先跑 scripts/build-content-packs.sh' % reg_path); sys.exit(1)
    registry = json.load(open(reg_path))

    names = sorted(registry)
    if only:
        names = [n for n in names if n in only]
    ok = 0
    for name in names:
        pck_path = os.path.join(REPO, registry[name]['export_path'])
        if not os.path.exists(pck_path):
            print('  SKIP %-24s 缺 %s（先构建）' % (name, pck_path)); continue
        data = open(pck_path, 'rb').read()
        body = json.dumps({
            'pckBase64': base64.b64encode(data).decode('ascii'),
            'keys': registry[name]['keys'],
        }).encode('utf-8')
        req = urllib.request.Request(
            '%s/admin/packs/%s' % (base, name), data=body, method='POST',
            headers={'content-type': 'application/json', 'x-admin-token': token})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                res = json.load(r)
            print('  ok   %-24s hash=%s bytes=%d keys=%d'
                  % (name, res['hash'][:12], res['bytes'], len(res['keys'])))
            ok += 1
        except urllib.error.HTTPError as e:
            print('  FAIL %-24s HTTP %d %s' % (name, e.code, e.read().decode('utf-8', 'replace')[:120]))
        except Exception as e:
            print('  FAIL %-24s %s' % (name, e))
    print('入库 %d/%d 个包' % (ok, len(names)))
    sys.exit(0 if ok == len(names) else 1)


if __name__ == '__main__':
    main()
