#!/usr/bin/env python3
# OpenRouter 生图原图拉取（纯 stdlib，跑在能出图的出口机器上，如首尔 own-api-ko——
# 港区 IP 对 Google/OpenAI 图像模型一律 403，见 memory: image-model-eval-and-ip-policy）。
# 与 gen_ui_assets.mjs 两段式配合：
#   本机:  node tools/gen_ui_assets.mjs <manifest> <out> --only ... --emit-jobs jobs.json
#   出口机: OPENROUTER_API_KEY=... python3 fetch_openrouter_images.py jobs.json rawdir [并发]
#   本机:  node tools/gen_ui_assets.mjs <manifest> <out> --only ... --raw-dir rawdir
# 用法: OPENROUTER_API_KEY=sk-... python3 fetch_openrouter_images.py jobs.json outdir [concurrency=6]
import base64
import concurrent.futures
import json
import os
import sys
import urllib.request

def main():
    spec = json.load(open(sys.argv[1]))
    out = sys.argv[2]
    workers = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    os.makedirs(out, exist_ok=True)
    key = os.environ["OPENROUTER_API_KEY"]
    model = spec["model"]

    def fetch(job):
        body = json.dumps({
            "model": model,
            "messages": [{"role": "user", "content": job["prompt"]}],
            "modalities": ["image", "text"],
        }).encode()
        last = ""
        for attempt in range(3):  # 生图偶发超时/空图，重试 3 次
            try:
                req = urllib.request.Request(
                    "https://openrouter.ai/api/v1/chat/completions", data=body,
                    headers={"authorization": "Bearer " + key, "content-type": "application/json"})
                r = json.load(urllib.request.urlopen(req, timeout=180))
                imgs = (((r.get("choices") or [{}])[0].get("message") or {}).get("images")) or []
                url = ""
                if imgs:
                    url = (imgs[0].get("image_url") or {}).get("url") or imgs[0].get("url") or ""
                if not url.startswith("data:"):
                    raise RuntimeError("no image: " + json.dumps(r)[:160])
                mime = url[5:url.index(";")]
                ext = "png" if "png" in mime else "jpg"
                data = base64.b64decode(url[url.index(",") + 1:])
                with open(os.path.join(out, job["file"] + "." + ext), "wb") as f:
                    f.write(data)
                return "ok   " + job["file"]
            except Exception as e:  # noqa: BLE001
                last = str(e)[:160]
        return "FAIL " + job["file"] + " " + last

    with concurrent.futures.ThreadPoolExecutor(workers) as ex:
        for res in ex.map(fetch, spec["jobs"]):
            print(res, flush=True)

if __name__ == "__main__":
    main()
