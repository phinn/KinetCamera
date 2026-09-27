<template>
  <div class="login-wrap">
    <div class="login-card">
      <div class="logo">📣</div>
      <h1>教师呼叫</h1>
      <p class="slogan">一键呼叫学生 · 大屏语音播报</p>

      <div class="field">
        <input v-model.trim="username" placeholder="用户名" autocomplete="username" />
      </div>
      <div class="field">
        <input v-model="password" type="password" placeholder="密码" autocomplete="current-password" @keyup.enter="doLogin" />
      </div>
      <div class="err" v-if="err">{{ err }}</div>
      <button class="btn-primary" :disabled="loading || !username || !password" @click="doLogin">
        {{ loading ? '登录中…' : '登 录' }}
      </button>
      <div class="tip">默认账号:admin / admin123</div>
    </div>
  </div>
</template>

<script>
import { api } from '../api';

export default {
  data: () => ({ username: '', password: '', err: '', loading: false }),
  methods: {
    async doLogin() {
      this.err = '';
      this.loading = true;
      try {
        const { user } = await api('/api/login', { method: 'POST', body: { username: this.username, password: this.password } });
        localStorage.setItem('user', JSON.stringify(user));
        this.$router.push('/');
      } catch (e) {
        this.err = e.message;
      } finally {
        this.loading = false;
      }
    },
  },
};
</script>

<style scoped>
.login-wrap {
  min-height: 100vh;
  display: flex;
  align-items: center;
  justify-content: center;
  background: linear-gradient(160deg, #4f7cff 0%, #6c5ce7 55%, #8e5cf0 100%);
  padding: 24px;
}
.login-card {
  width: 100%;
  max-width: 360px;
  background: #fff;
  border-radius: 24px;
  padding: 36px 28px;
  text-align: center;
  box-shadow: 0 20px 60px rgba(20,30,80,.35);
}
.logo {
  width: 72px; height: 72px;
  margin: 0 auto 16px;
  border-radius: 22px;
  background: linear-gradient(135deg, #4f7cff, #6c5ce7);
  display: flex; align-items: center; justify-content: center;
  font-size: 34px;
  box-shadow: 0 8px 20px rgba(79,124,255,.35);
}
h1 { font-size: 22px; letter-spacing: 2px; }
.slogan { color: #8a90a5; font-size: 13px; margin: 8px 0 28px; }
.field { margin-bottom: 14px; }
.field input {
  width: 100%;
  border: 1.5px solid #e6e8f0;
  background: #f7f8fc;
  border-radius: 14px;
  padding: 14px 16px;
  font-size: 15px;
  outline: none;
  transition: border .2s;
}
.field input:focus { border-color: #4f7cff; background: #fff; }
.err { color: #e74c3c; font-size: 13px; text-align: left; margin: -4px 0 12px 4px; }
.tip { margin-top: 18px; font-size: 12px; color: #a0a5b8; }
</style>
