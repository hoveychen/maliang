import { HashRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { getToken } from './api.ts';
import { OverviewPage } from './pages/Overview.tsx';
import { PlayersPage } from './pages/Players.tsx';
import { PlayerDetailPage } from './pages/PlayerDetail.tsx';
import { WorldsPage } from './pages/Worlds.tsx';
import { WorldDetailPage } from './pages/WorldDetail.tsx';
import { CharacterDetailPage } from './pages/CharacterDetail.tsx';
import { DataPage } from './pages/Data.tsx';
import { ActivityPage } from './pages/Activity.tsx';

const NAV = [
  { to: '/', zh: '总览', en: 'overview', end: true },
  { to: '/players', zh: '玩家', en: 'players', end: false },
  { to: '/worlds', zh: '世界', en: 'worlds', end: false },
  { to: '/activity', zh: '活动', en: 'activity', end: false },
  { to: '/data', zh: '数据', en: 'backup', end: false },
];

export function App() {
  return (
    <HashRouter>
      <div className="layout">
        <aside className="side">
          <div className="seal-block">
            <div className="stamp">馬良</div>
            <div>
              <div className="title">马良管理台</div>
              <div className="sub">世界状态 · 只读</div>
            </div>
          </div>
          <nav className="nav">
            {NAV.map((n) => (
              <NavLink to={n.to} end={n.end} key={n.to} className={({ isActive }) => (isActive ? 'active' : '')}>
                <span className="zh">{n.zh}</span>
                <span className="en">{n.en}</span>
              </NavLink>
            ))}
          </nav>
          <div className="side-foot">
            <span className={`dot ${getToken() ? 'ok' : 'bad'}`} />
            {getToken() ? 'token 已配置' : '未配 token（开发环境直连）'}
          </div>
        </aside>
        <main className="main">
          <Routes>
            <Route path="/" element={<OverviewPage />} />
            <Route path="/players" element={<PlayersPage />} />
            <Route path="/players/:id" element={<PlayerDetailPage />} />
            <Route path="/worlds" element={<WorldsPage />} />
            <Route path="/worlds/:id" element={<WorldDetailPage />} />
            <Route path="/worlds/:id/characters/:cid" element={<CharacterDetailPage />} />
            <Route path="/activity" element={<ActivityPage />} />
            <Route path="/data" element={<DataPage />} />
            <Route path="*" element={<Navigate to="/" replace />} />
          </Routes>
        </main>
      </div>
    </HashRouter>
  );
}
