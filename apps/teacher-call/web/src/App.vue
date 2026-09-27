<template>
  <router-view />
</template>

<script>
import { api } from './api';

export default {
  async mounted() {
    // 恢复会话
    if (localStorage.getItem('user')) {
      try { await api('/api/me'); } catch { localStorage.removeItem('user'); }
    }
  },
};
</script>

<style>
:root {
  --bg: #f5f6fa;
  --card: #ffffff;
  --primary: #4f7cff;
  --primary-2: #6c5ce7;
  --text: #1e2233;
  --sub: #8a90a5;
  --radius: 18px;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { height: 100%; }
body {
  font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', 'Helvetica Neue', sans-serif;
  background: var(--bg);
  color: var(--text);
  -webkit-font-smoothing: antialiased;
}
a { color: inherit; text-decoration: none; }
button { font-family: inherit; }

.page {
  max-width: 520px;
  margin: 0 auto;
  min-height: 100vh;
  padding: 16px 16px 40px;
}
.topbar {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 14px 4px;
}
.topbar .back {
  width: 36px; height: 36px;
  border-radius: 12px;
  background: var(--card);
  display: flex; align-items: center; justify-content: center;
  font-size: 18px;
  box-shadow: 0 2px 8px rgba(30,34,51,.06);
  border: none; cursor: pointer;
}
.topbar h1 { font-size: 20px; font-weight: 700; flex: 1; }
.topbar .sub { font-size: 12px; color: var(--sub); margin-top: 2px; }

.card {
  background: var(--card);
  border-radius: var(--radius);
  box-shadow: 0 4px 16px rgba(30,34,51,.05);
}

.list-item {
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 16px;
  cursor: pointer;
  transition: background .15s;
  user-select: none;
}
.list-item:active { background: #f0f2f8; }
.list-item .avatar {
  width: 46px; height: 46px;
  border-radius: 14px;
  display: flex; align-items: center; justify-content: center;
  font-size: 20px;
  color: #fff;
  flex-shrink: 0;
  font-weight: 600;
}
.list-item .info { flex: 1; min-width: 0; }
.list-item .info .name { font-size: 16px; font-weight: 600; }
.list-item .info .meta { font-size: 12px; color: var(--sub); margin-top: 3px; }
.list-item .arrow { color: #c5c9d6; font-size: 16px; }

.divider { height: 1px; background: #f0f1f6; margin-left: 76px; }

.btn-primary {
  width: 100%;
  border: none;
  background: linear-gradient(135deg, var(--primary), var(--primary-2));
  color: #fff;
  font-size: 16px;
  font-weight: 600;
  padding: 15px;
  border-radius: 16px;
  cursor: pointer;
  transition: opacity .15s;
}
.btn-primary:active { opacity: .85; }
.btn-primary:disabled { opacity: .5; }

.empty {
  text-align: center;
  color: var(--sub);
  padding: 60px 0;
  font-size: 14px;
}

.fade-enter-active, .fade-leave-active { transition: opacity .2s; }
.fade-enter-from, .fade-leave-to { opacity: 0; }
</style>
