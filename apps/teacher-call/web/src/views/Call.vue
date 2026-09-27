<template>
  <div class="page">
    <div class="topbar">
      <button class="back" @click="$router.back()">‹</button>
      <div style="flex:1">
        <h1>呼叫 {{ target?.name }}</h1>
        <div class="sub">{{ target?.kind === 'teacher' ? '老师' : '学生' }} · {{ target?.className }}</div>
      </div>
    </div>

    <div class="card target-card">
      <div class="avatar big" :style="{ background: target?.kind === 'teacher' ? '#e17055' : '#4f7cff' }">
        {{ target?.name?.[0] }}
      </div>
      <div class="t-name">{{ target?.name }}</div>
      <div class="t-meta">{{ target?.kind === 'teacher' ? '任课老师' : `${target?.seat} 号学生` }}</div>
    </div>

    <div class="section-title">选择快捷话术</div>
    <div class="quick">
      <button
        v-for="q in quickList"
        :key="q"
        :class="['chip', { active: text === q }]"
        @click="text = q"
      >{{ q }}</button>
    </div>

    <div class="section-title">或输入内容</div>
    <div class="card editor">
      <textarea
        v-model="text"
        rows="3"
        maxlength="500"
        placeholder="例如:请到老师办公室来一趟"
      ></textarea>
      <div class="count">{{ text.length }}/500</div>
    </div>

    <button class="btn-primary send" :disabled="!text.trim() || sending" @click="send">
      {{ sending ? '发送中…' : '📣 推送到大屏并播报' }}
    </button>

    <transition name="fade">
      <div class="toast" v-if="toast">{{ toast }}</div>
    </transition>
  </div>
</template>

<script>
import { api } from '../api';

const QUICK_DEFAULT = [
  '请到老师办公室来一趟',
  '请到教务处来',
  '请马上到操场集合',
  '家长在校门口等您',
  '请到广播室',
];

export default {
  data: () => ({
    target: null,
    text: '',
    sending: false,
    toast: '',
    quickList: [...QUICK_DEFAULT],
  }),
  async mounted() {
    const { kind, targetId } = this.$route.params;
    // 从 members 接口定位目标:遍历该学生/老师所在班级;简化:后端提供了全局 id,这里用 members 接口按 classId 找不到时 fallback
    // 为避免额外接口,调用 members 时通过 targetId 反查:先请求所有班级代价高,因此后端提供 /api/target/:id
    const data = await api('/api/target/' + targetId);
    this.target = data;
    // 历史常用语
    try {
      const saved = JSON.parse(localStorage.getItem('quickPhrases') || '[]');
      if (saved.length) this.quickList = [...new Set([...saved, ...QUICK_DEFAULT])].slice(0, 8);
    } catch {}
  },
  methods: {
    async send() {
      if (this.sending || !this.text.trim()) return; // 防重复点击
      this.sending = true;
      try {
        const { delivered } = await api('/api/call', {
          method: 'POST',
          body: {
            targetId: this.target.id,
            text: this.text.trim().slice(0, 500),
            screenCode: localStorage.getItem('screenCode') || undefined,
          },
        });
        // 保存常用语
        const saved = new Set(JSON.parse(localStorage.getItem('quickPhrases') || '[]'));
        saved.add(this.text.trim());
        localStorage.setItem('quickPhrases', JSON.stringify([...saved].slice(0, 5)));

        this.toast = delivered ? '✅ 已推送到大屏,正在播报' : '⚠️ 大屏未连接,消息已记录';
        // 成功后保持 sending=true(按钮禁用),直到跳转,防止延迟期内重复发送
        setTimeout(() => this.$router.back(), 1200);
      } catch (e) {
        this.toast = '❌ ' + e.message;
        setTimeout(() => (this.toast = ''), 2000);
        this.sending = false;
      }
    },
  },
};
</script>

<style scoped>
.target-card {
  padding: 26px;
  text-align: center;
}
.avatar {
  border-radius: 50%;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: #fff;
  font-weight: 600;
}
.avatar.big { width: 76px; height: 76px; font-size: 30px; margin-bottom: 12px; }
.t-name { font-size: 20px; font-weight: 700; }
.t-meta { font-size: 13px; color: var(--sub); margin-top: 4px; }

.section-title {
  font-size: 13px;
  font-weight: 600;
  color: var(--sub);
  margin: 18px 6px 8px;
}
.quick { display: flex; flex-wrap: wrap; gap: 8px; padding: 0 2px; }
.chip {
  border: 1.5px solid #e6e8f0;
  background: #fff;
  border-radius: 999px;
  padding: 9px 14px;
  font-size: 13px;
  color: var(--text);
  cursor: pointer;
  transition: all .15s;
}
.chip.active {
  background: linear-gradient(135deg, var(--primary), var(--primary-2));
  color: #fff;
  border-color: transparent;
}
.editor { padding: 6px 14px 10px; }
.editor textarea {
  width: 100%;
  border: none;
  outline: none;
  resize: none;
  font-size: 15px;
  line-height: 1.6;
  padding: 10px 4px;
  font-family: inherit;
}
.editor .count { text-align: right; font-size: 11px; color: #c0c4d4; }
.send { margin-top: 22px; }
.toast {
  position: fixed;
  left: 50%;
  bottom: 60px;
  transform: translateX(-50%);
  background: rgba(30,34,51,.92);
  color: #fff;
  padding: 12px 22px;
  border-radius: 999px;
  font-size: 14px;
  white-space: nowrap;
  z-index: 99;
}
</style>
