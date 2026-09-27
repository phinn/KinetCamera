<template>
  <div class="page">
    <div class="topbar">
      <div style="flex:1">
        <h1>选择年级</h1>
        <div class="sub">{{ user?.name }} · 已登录</div>
      </div>
      <button class="back" title="大屏端入口" @click="goScreen">🖥</button>
      <button class="back" title="退出登录" @click="logout">⎋</button>
    </div>

    <div class="card">
      <div v-for="(g, i) in grades" :key="g.id">
        <div class="list-item" @click="$router.push('/grade/' + g.id)">
          <div class="avatar" :style="{ background: colorOf(i) }">🎓</div>
          <div class="info">
            <div class="name">{{ g.name }}</div>
            <div class="meta">{{ g.classCount }} 个班</div>
          </div>
          <span class="arrow">›</span>
        </div>
        <div class="divider" v-if="i < grades.length - 1"></div>
      </div>
      <div v-if="!grades.length" class="empty">暂无年级数据</div>
    </div>
  </div>
</template>

<script>
import { api } from '../api';

export default {
  data: () => ({ grades: [], user: null }),
  async mounted() {
    this.user = JSON.parse(localStorage.getItem('user') || 'null');
    this.grades = (await api('/api/grades')).grades;
  },
  methods: {
    colorOf(i) {
      const colors = ['#4f7cff', '#6c5ce7', '#00b894', '#e17055', '#0984e3', '#e84393'];
      return colors[i % colors.length];
    },
    goScreen() { this.$router.push('/screen'); },
    async logout() {
      try { await api('/api/logout', { method: 'POST' }); } catch {}
      localStorage.removeItem('user');
      this.$router.push('/login');
    },
  },
};
</script>
