<template>
  <div class="page">
    <div class="topbar">
      <button class="back" @click="$router.back()">‹</button>
      <div style="flex:1">
        <h1>{{ gradeName }} · 班级</h1>
      </div>
    </div>

    <div class="card">
      <div v-for="(c, i) in classes" :key="c.id">
        <div class="list-item" @click="$router.push('/class/' + c.id)">
          <div class="avatar" :style="{ background: colorOf(i) }">🏫</div>
          <div class="info">
            <div class="name">{{ c.name }}</div>
            <div class="meta">{{ c.studentCount }} 名学生 · {{ c.teacherCount }} 名老师</div>
          </div>
          <span class="arrow">›</span>
        </div>
        <div class="divider" v-if="i < classes.length - 1"></div>
      </div>
      <div v-if="!classes.length" class="empty">暂无班级</div>
    </div>
  </div>
</template>

<script>
import { api } from '../api';

export default {
  data: () => ({ classes: [], gradeName: '' }),
  async mounted() {
    const gradeId = this.$route.params.gradeId;
    // 从年级列表缓存取名字,或直接用 class 推断
    this.classes = (await api('/api/classes/' + gradeId)).classes;
    this.gradeName = this.classes[0]?.name ? (this.classes[0].name.match(/^(.+)·?\d+班$/)?.[1] || '') : '';
    // 名称形如「一年级1班」,取前缀
    if (!this.gradeName && this.classes[0]) {
      this.gradeName = this.classes[0].name.replace(/\d+班$/, '');
    }
  },
  methods: {
    colorOf(i) {
      const colors = ['#00b894', '#0984e3', '#e17055', '#8e44ad', '#16a085', '#d35400'];
      return colors[i % colors.length];
    },
  },
};
</script>
