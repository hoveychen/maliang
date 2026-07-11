import { useCallback, useEffect, useState } from 'react';
import type { BackupManifest, RestoreResponse } from './types.ts';

// token：?token= 进来先落 localStorage（后续导航/刷新不用带参），请求走 x-admin-token 头。
const KEY = 'maliang_admin_token';
const urlToken = new URLSearchParams(location.search).get('token');
if (urlToken) localStorage.setItem(KEY, urlToken);

export function getToken(): string {
  return urlToken ?? localStorage.getItem(KEY) ?? '';
}

export function setToken(t: string): void {
  localStorage.setItem(KEY, t);
}

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export async function api<T>(path: string): Promise<T> {
  const token = getToken();
  const res = await fetch(path, { headers: token ? { 'x-admin-token': token } : {} });
  if (!res.ok) throw new ApiError(res.status, `${res.status} ${res.statusText}`);
  return res.json() as Promise<T>;
}

/**
 * 管理写操作（补动画、开演等触发类端点）：POST 带 admin token，返回 JSON。
 * 失败时优先拿服务端 body 里的 error 当消息——「世界里没有在线的小朋友」比「400 Bad Request」有用得多。
 */
export async function apiPost<T>(path: string, body?: unknown): Promise<T> {
  const token = getToken();
  const headers: Record<string, string> = {};
  if (token) headers['x-admin-token'] = token;
  if (body !== undefined) headers['content-type'] = 'application/json';
  const res = await fetch(path, { method: 'POST', headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (!res.ok) {
    const detail = await res.json().then((j: { error?: string }) => j?.error).catch(() => undefined);
    throw new ApiError(res.status, detail ?? `${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<T>;
}

export function assetUrl(hash: string): string {
  return `/assets/${hash}`;
}

/** 拉一个 API 资源：loading/error/data + reload。path 变化自动重拉。 */
export function useApi<T>(path: string): { data: T | null; error: ApiError | null; loading: boolean; reload: () => void } {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [loading, setLoading] = useState(true);
  const [nonce, setNonce] = useState(0);
  const reload = useCallback(() => setNonce((n) => n + 1), []);
  useEffect(() => {
    let alive = true;
    setLoading(true);
    setError(null);
    api<T>(path)
      .then((d) => { if (alive) { setData(d); setLoading(false); } })
      .catch((e: ApiError) => { if (alive) { setError(e); setLoading(false); } });
    return () => { alive = false; };
  }, [path, nonce]);
  return { data, error, loading, reload };
}

export function fmtTs(ts: number | null | undefined): string {
  if (!ts) return '—';
  return new Date(ts).toLocaleString('zh-CN', { hour12: false });
}

/**
 * 下载全量备份包：带 token 拉 /admin/backup，把响应存成本地文件。
 * manifest 在响应头里（服务端不用解包就告诉了我们包里有什么），顺手返回给调用方展示。
 */
export async function downloadBackup(): Promise<BackupManifest> {
  const token = getToken();
  const res = await fetch('/admin/backup', { headers: token ? { 'x-admin-token': token } : {} });
  if (!res.ok) {
    const detail = await res.json().then((j: { error?: string }) => j?.error).catch(() => undefined);
    throw new ApiError(res.status, detail ?? `${res.status} ${res.statusText}`);
  }
  const manifest = JSON.parse(res.headers.get('x-backup-manifest') ?? '{}') as BackupManifest;
  const name =
    /filename="([^"]+)"/.exec(res.headers.get('content-disposition') ?? '')?.[1] ?? 'maliang-backup.tar.gz';
  const url = URL.createObjectURL(await res.blob());
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
  return manifest;
}

/**
 * 上传备份包做全量恢复。**破坏性**：服务端当前数据会被整个换掉。
 * 调用方必须先让老板明确确认过——服务端不会替你把关这一步。
 */
export async function uploadRestore(file: File): Promise<RestoreResponse> {
  const token = getToken();
  const headers: Record<string, string> = { 'content-type': 'application/gzip' };
  if (token) headers['x-admin-token'] = token;
  const res = await fetch('/admin/restore', { method: 'POST', headers, body: file });
  if (!res.ok) {
    const detail = await res.json().then((j: { error?: string }) => j?.error).catch(() => undefined);
    throw new ApiError(res.status, detail ?? `${res.status} ${res.statusText}`);
  }
  return res.json() as Promise<RestoreResponse>;
}
