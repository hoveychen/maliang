import { useCallback, useEffect, useState } from 'react';

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

/** 管理写操作（补动画等触发类端点）：POST 带 admin token，返回 JSON。 */
export async function apiPost<T>(path: string): Promise<T> {
  const token = getToken();
  const res = await fetch(path, { method: 'POST', headers: token ? { 'x-admin-token': token } : {} });
  if (!res.ok) throw new ApiError(res.status, `${res.status} ${res.statusText}`);
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
