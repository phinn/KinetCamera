<template>
  <div class="page">
    <div class="topbar">
      <button class="back" @click="$router.back()">‹</button>
      <div style="flex:1">
        <h1>{{ cls?.name || '班级' }}</h1>
        <div class="sub">点击成员发起呼叫</div>
      </div>
    </div>

    <div class="section-title">👩‍🏫 任课老师({{ teachers.length }})</div>
    <div class="card">
      <div v-for="(t, i) in teachers" :key="t.id">
        <div class="list-item" @click="$router.push('/call/teacher/' + t.id)">
          <div class="avatar" :style="{ background: tcolor(i) }">{{ t.name[0] }}</div>
          <div class="info">
            <div class="name">{{ t.name }}</div>
            <div class="meta">老师</div>
          </div>
          <span class="arrow">›</span>
        </div>
        <div class="divider" v-if="i < teachers.length - 1"></div>
      </div>
    </div>

    <div class="section-title">🎒 学生({{ students.length }})</div>
    <div class="card">
      <div v-for="(s, i) in students" :key="s.id">
        <div class="list-item" @click="$router.push('/call/student/' + s.id)">
          <div class="avatar" :style="{ background: scolor(i) }">{{ s.name[0] }}</div>
          <div class="info">
            <div class="name">{{ s.name }}</div>
            <div class="meta">{{ s.seat }} 号</div>
          </div>
          <span class="arrow">›</span>
        </div>
        <div class="divider" v-if="i < students.length - 1"></div>
      </div>
    </div>
  </div>
</template>

<script>
import { api } from '../api';

export default {
  data: () => ({ cls: null, students: [], teachers: [] }),
  async mounted() {
    const data = await api('/api/classes/' + this.$route.params.classId + '/members');
    this.cls = data.class;
    this.students = data.students;
    this.teachers = data.teachers;
  },
  methods: {
    tcolor(i) {
      const colors = ['#e17055', '#e84393', '#f39c12', '#8e44ad'];
      return colors[i % colors.length];
    },
    scolor(i) {
      const colors = ['#4f7cff', '#00b894', '#0984e3', '#6c5ce7', '#16a085', '#e67e22', '#2980b9', '#27ae60'];
      return colors[i % colors.length];
    },
  },
};
</script>

<style scoped>
.section-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--sub);
  margin: 18px 6px 8px;
}
</style>
