<template>
  <div class="screen" :class="{ night: muted }" @click="ensureKeepAlive">
    <!-- 未配对 -->
    <div class="pair" v-if="!code">
      <div class="p-logo">
        <div class="p-logo-icon">📣</div>
      </div>
      <h1>校园呼叫大屏</h1>
      <p class="p-sub">绑定本教室大屏,接收教师端实时呼叫</p>
      <div class="code-display">{{ genCode || '· · · · · ·' }}</div>
      <button class="p-btn" @click="bind">{{ binding ? '配对中…' : '生成本屏配对码' }}</button>
      <div class="p-tip p-err" v-if="pairErr">{{ pairErr }}</div>
      <div class="p-tip">配对后,手机端呼叫将自动推送到本屏并语音播报</div>
    </div>

    <!-- 已配对:待机 -->
    <div class="idle" v-else-if="!current">
      <div class="clock-wrap">
        <div class="clock">{{ timeStr }}</div>
        <div class="date">{{ dateStr }}</div>
      </div>
      <div class="status-row">
        <span class="pill" :class="connected ? 'on' : 'off'">
          <span class="dot"></span>{{ connected ? '已连接 · 等待呼叫' : '连接中…' }}
        </span>
        <span class="pill code">本屏码 {{ code }}</span>
        <span class="pill" v-if="muted">🔇 已静音</span>
      </div>
      <div class="history" v-if="history.length">
        <div class="h-title">最近呼叫</div>
        <div class="h-item" v-for="h in history.slice(0, 6)" :key="h.id">
          <span class="h-time">{{ fmtTime(h.ts) }}</span>
          <span class="h-name" :class="{ t: h.targetKind === 'teacher' }">{{ h.targetName }}</span>
          <span class="h-cls">{{ h.className }}</span>
          <span class="h-text">{{ h.text }}</span>
        </div>
      </div>
      <div class="idle-empty" v-else>
        <div class="ie-icon">📮</div>
        <div class="ie-text">暂无呼叫记录</div>
      </div>
    </div>

    <!-- 呼叫中 -->
    <div class="calling" v-else key="calling">
      <div class="c-kind">
        <span class="eq" v-if="speaking && !muted"><i></i><i></i><i></i><i></i></span>
        {{ current.targetKind === 'teacher' ? '老师呼叫' : '学生呼叫' }}
        <span class="eq" v-if="speaking && !muted"><i></i><i></i><i></i><i></i></span>
      </div>
      <div class="c-name">{{ current.targetName }}</div>
      <div class="c-class" v-if="current.className">{{ current.className }}</div>
      <div class="c-text">“{{ current.text }}”</div>
      <div class="c-from">—— {{ current.from }}</div>
      <div class="c-queue" v-if="queue.length">还有 {{ queue.length }} 条呼叫排队播报</div>
      <div class="c-progress"><div class="c-bar" :style="{ animationDuration: duration + 's' }"></div></div>
    </div>

    <!-- 控制角标 -->
    <div class="ctrl" v-if="code">
      <button :title="muted ? '取消静音' : '静音'" @click.stop="toggleMute">{{ muted ? '🔇' : '🔊' }}</button>
      <button title="重播上一条" @click.stop="replay">↻</button>
      <button title="全屏/退出全屏" @click.stop="toggleFullscreen">{{ isFullscreen ? '⛶' : '⛶' }}</button>
      <button title="解绑本屏" @click.stop="unbind">⚙</button>
    </div>
  </div>
</template>

<script>
import { io } from 'socket.io-client';

const DISPLAY_MIN = 8; // 单条最短展示秒数

export default {
  data: () => ({
    code: localStorage.getItem('screenCode') || '',
    genCode: '',
    binding: false,
    pairErr: '',
    connected: false,
    queue: [],          // 待播报队列
    current: null,      // 当前展示的消息
    speaking: false,
    duration: DISPLAY_MIN,
    muted: false,
    history: [],
    timeStr: '',
    dateStr: '',
    isFullscreen: false,
    socket: null,
    clockTimer: null,
    displayTimer: null,
    wakeLock: null,
    keepAlive: null,    // 静音保活 audio
  }),
  async mounted() {
    this.tick();
    this.clockTimer = setInterval(this.tick, 1000);
    if (this.code) this.connect(this.code);
    try {
      const { log } = await fetch('/api/log').then(r => r.json());
      if (Array.isArray(log)) this.history = log.filter(l => !l.note);
    } catch {}

    // 标签重新可见:重申请唤醒锁 + 恢复播报
    document.addEventListener('visibilitychange', this.onVisible);
    document.addEventListener('fullscreenchange', this.onFsChange);
    if (this.code) this.ensureKeepAlive();
  },
  beforeUnmount() {
    this.socket?.disconnect();
    clearInterval(this.clockTimer);
    clearTimeout(this.displayTimer);
    document.removeEventListener('visibilitychange', this.onVisible);
    document.removeEventListener('fullscreenchange', this.onFsChange);
    this.wakeLock?.release?.().catch(() => {});
    this.keepAlive?.pause();
    try { speechSynthesis?.cancel(); } catch {}
  },
  methods: {
    tick() {
      const d = new Date();
      const p = n => String(n).padStart(2, '0');
      this.timeStr = `${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
      const week = '日一二三四五六'[d.getDay()];
      this.dateStr = `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日 星期${week}`;
    },
    fmtTime(ts) { const d = new Date(ts); const p = n => String(n).padStart(2, '0'); return `${p(d.getHours())}:${p(d.getMinutes())}`; },

    // ---------- 保活:静音音频 + 唤醒锁 + 全屏 ----------
    async ensureKeepAlive() {
      // 1) 静音循环音频:防止 Chrome 挂起后台标签的 speechSynthesis(音量≈0,听不见)
      //    首次 play 需用户手势;失败时保留实例,后续手势/可见时重试 play()
      if (!this.keepAlive) {
        const au = new Audio('data:audio/wav;base64,UklGRigAAABXQVZFZm10IBIAAAABAAEARKwAAIhYAQACABAAAABkYXRhAgAAAAEA');
        au.loop = true;
        au.volume = 0.0001;
        try {
          await au.play();
        } catch {}
        this.keepAlive = au; // 无论首次是否成功,持有实例供后续重试
      } else if (this.keepAlive.paused) {
        this.keepAlive.play().catch(() => {});
      }
      // 2) 屏幕唤醒锁:大屏不熄屏(需要 HTTPS/localhost 已满足)
      try {
        if (!this.wakeLock || this.wakeLock.released) {
          this.wakeLock = await navigator.wakeLock?.request?.('screen') || null;
        }
      } catch {}
    },
    async onVisible() {
      if (document.visibilityState !== 'visible') return;
      await this.ensureKeepAlive();
      // 回到可见时若正在展示却没在说话,重新播一遍
      if (this.current && !this.muted && !this.speaking) this.speak(this.current);
    },
    async bind() {
      this.binding = true;
      this.pairErr = '';
      const code = Math.random().toString().slice(2, 8);
      this.genCode = code;
      try {
        const r = await fetch('/api/screen/register', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ screenCode: code, name: '教室大屏' }),
        });
        if (!r.ok) throw new Error('配对失败,请检查服务是否正常');
        this.code = code;
        localStorage.setItem('screenCode', code);
        this.connect(code);
        // 配对动作本身是用户手势:顺势解锁音频 + 申请唤醒锁 + 自动全屏
        await this.ensureKeepAlive();
        this.goFullscreen();
      } catch (e) {
        this.pairErr = e.message;
      } finally {
        this.binding = false;
      }
    },
    unbind() {
      if (!confirm('解绑后需要重新生成配对码,确定?')) return;
      localStorage.removeItem('screenCode');
      this.socket?.disconnect();
      this.code = '';
      this.genCode = '';
      this.current = null;
      this.queue = [];
      this.connected = false;
    },
    async goFullscreen() {
      try { if (!document.fullscreenElement) await document.documentElement.requestFullscreen(); } catch {}
    },
    async toggleFullscreen() {
      try {
        if (document.fullscreenElement) await document.exitFullscreen();
        else await document.documentElement.requestFullscreen();
      } catch {}
    },
    onFsChange() { this.isFullscreen = !!document.fullscreenElement; },

    connect(code) {
      this.socket?.disconnect();
      this.socket = io({ path: '/socket.io', reconnectionDelayMax: 5000 });
      this.socket.on('connect', () => this.socket.emit('screen:join', code));
      this.socket.on('screen:joined', () => { this.connected = true; });
      this.socket.on('disconnect', () => { this.connected = false; });
      this.socket.on('call', (msg) => this.onCall(msg));
    },

    // ---------- 消息队列:逐条展示+播报,不互相覆盖 ----------
    onCall(msg) {
      this.history.unshift(msg);
      if (this.history.length > 100) this.history.length = 100;
      this.queue.push(msg);
      this.processQueue();
    },
    processQueue() {
      if (this.current || !this.queue.length) return;
      const msg = this.queue.shift();
      this.current = msg;
      this.duration = Math.max(DISPLAY_MIN, 4 + Math.ceil((msg.text || '').length / 5));
      // 重启进度条动画
      this.$nextTick(() => {
        const bar = document.querySelector('.c-bar');
        if (bar) { bar.style.animation = 'none'; void bar.offsetWidth; bar.style.animation = ''; }
      });
      if (!this.muted) this.speak(msg);
      clearTimeout(this.displayTimer);
      this.displayTimer = setTimeout(() => {
        this.current = null;
        this.speaking = false;
        this.processQueue();
      }, this.duration * 1000);
    },
    replay() {
      const last = this.history[0];
      if (last && !this.current) this.onCall({ ...last, id: last.id + ':replay' });
    },
    toggleMute() {
      this.muted = !this.muted;
      if (this.muted) { try { speechSynthesis.cancel(); } catch {} this.speaking = false; }
      else if (this.current) this.speak(this.current);
    },

    speak(msg) {
      try {
        const synth = window.speechSynthesis;
        synth.cancel();
        const name = msg.targetKind === 'teacher'
          ? msg.targetName
          : `${msg.className},${msg.targetName}`;
        const full = `请${name},${msg.text}`;
        // 3 个 utterance 一次性入队(synth 自带顺序队列),不依赖 onend 链 —— onend 链在 Chrome 会丢第 3 遍
        for (let i = 0; i < 3; i++) {
          const u = new SpeechSynthesisUtterance(full);
          u.lang = 'zh-CN';
          u.rate = 0.95;
          if (i === 0) u.onstart = () => { this.speaking = true; };
          if (i === 2) u.onend = () => { this.speaking = false; };
          synth.speak(u);
        }
      } catch (e) {
        console.warn('TTS 不可用:', e);
      }
    },
  },
};
</script>

<style scoped>
.screen {
  position: fixed;
  inset: 0;
  background:
    radial-gradient(1200px 800px at 20% -10%, rgba(99,132,255,.28), transparent 60%),
    radial-gradient(1000px 700px at 90% 110%, rgba(150,92,240,.22), transparent 60%),
    linear-gradient(150deg, #141b3d 0%, #1b2258 45%, #2c2260 100%);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  font-family: -apple-system, 'PingFang SC', 'Microsoft YaHei', sans-serif;
  cursor: default;
}
.screen.night { filter: saturate(.55) brightness(.92); }

/* ---------- 配对页 ---------- */
.pair { text-align: center; padding: 30px; animation: fadeIn .5s; }
.p-logo-icon {
  width: 108px; height: 108px; margin: 0 auto 18px;
  border-radius: 32px;
  background: linear-gradient(135deg, rgba(79,124,255,.9), rgba(140,92,240,.9));
  display: flex; align-items: center; justify-content: center;
  font-size: 52px;
  box-shadow: 0 20px 60px rgba(79,124,255,.4), inset 0 1px 0 rgba(255,255,255,.25);
}
.pair h1 { font-size: 34px; letter-spacing: 6px; font-weight: 700; }
.p-sub { color: rgba(255,255,255,.55); margin: 12px 0 34px; font-size: 16px; letter-spacing: 1px; }
.code-display {
  font-size: 72px;
  font-weight: 800;
  letter-spacing: 18px;
  text-indent: 18px;
  font-variant-numeric: tabular-nums;
  background: rgba(255,255,255,.07);
  border: 1px solid rgba(255,255,255,.12);
  border-radius: 28px;
  padding: 24px 48px;
  display: inline-block;
  margin-bottom: 34px;
  text-shadow: 0 0 40px rgba(130,160,255,.6);
}
.p-btn {
  display: block;
  margin: 0 auto 22px;
  padding: 18px 64px;
  font-size: 20px;
  font-weight: 600;
  letter-spacing: 2px;
  color: #fff;
  background: linear-gradient(135deg, #4f7cff, #8e5cf0);
  border: none;
  border-radius: 999px;
  cursor: pointer;
  box-shadow: 0 12px 40px rgba(79,124,255,.45);
  transition: transform .15s, box-shadow .15s;
}
.p-btn:hover { transform: translateY(-2px); box-shadow: 0 16px 48px rgba(79,124,255,.55); }
.p-btn:active { transform: translateY(0); }
.p-tip { color: rgba(255,255,255,.45); font-size: 14px; margin-top: 6px; }
.p-err { color: #ff7675; font-weight: 500; }

/* ---------- 待机 ---------- */
.idle { text-align: center; padding: 40px; width: 100%; animation: fadeIn .5s; }
.clock-wrap { margin-bottom: 22px; }
.clock {
  font-size: clamp(90px, 14vw, 190px);
  font-weight: 200;
  letter-spacing: 6px;
  font-variant-numeric: tabular-nums;
  line-height: 1;
  text-shadow: 0 0 80px rgba(130,160,255,.35);
}
.date { font-size: clamp(18px, 2.6vw, 30px); color: rgba(255,255,255,.6); margin-top: 14px; letter-spacing: 4px; }
.status-row { display: flex; gap: 12px; justify-content: center; flex-wrap: wrap; margin-bottom: 36px; }
.pill {
  display: inline-flex; align-items: center; gap: 8px;
  padding: 9px 20px;
  border-radius: 999px;
  font-size: 15px;
  background: rgba(255,255,255,.08);
  border: 1px solid rgba(255,255,255,.12);
  color: rgba(255,255,255,.85);
}
.pill.on .dot { background: #2ed573; box-shadow: 0 0 12px #2ed573; }
.pill.off .dot { background: #ffa502; box-shadow: 0 0 12px #ffa502; animation: blink 1s infinite; }
.dot { width: 10px; height: 10px; border-radius: 50%; }
.pill.code { font-variant-numeric: tabular-nums; letter-spacing: 2px; }

.history { max-width: 860px; margin: 0 auto; text-align: left; }
.h-title {
  font-size: 15px; color: rgba(255,255,255,.45);
  margin: 0 8px 12px; letter-spacing: 3px;
  display: flex; align-items: center; gap: 10px;
}
.h-title::after { content: ''; flex: 1; height: 1px; background: rgba(255,255,255,.1); }
.h-item {
  display: flex; align-items: baseline; gap: 16px;
  background: rgba(255,255,255,.055);
  border: 1px solid rgba(255,255,255,.08);
  border-radius: 16px;
  padding: 14px 22px;
  margin-bottom: 10px;
  backdrop-filter: blur(6px);
}
.h-time { font-size: 14px; color: rgba(255,255,255,.4); font-variant-numeric: tabular-nums; min-width: 44px; }
.h-name { font-size: 19px; font-weight: 700; color: #9db4ff; }
.h-name.t { color: #ffb38a; }
.h-cls { font-size: 13px; color: rgba(255,255,255,.4); }
.h-text {
  flex: 1; font-size: 16px; color: rgba(255,255,255,.85);
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
  text-align: right;
}
.idle-empty { color: rgba(255,255,255,.35); margin-top: 10px; }
.ie-icon { font-size: 40px; margin-bottom: 8px; }
.ie-text { font-size: 15px; letter-spacing: 2px; }

/* ---------- 呼叫中 ---------- */
.calling { text-align: center; padding: 30px; animation: popIn .35s cubic-bezier(.2,1.4,.4,1); width: 100%; }
.c-kind {
  display: inline-flex; align-items: center; gap: 14px;
  font-size: clamp(16px, 2.2vw, 24px);
  font-weight: 600;
  letter-spacing: 6px;
  color: #ffd280;
  background: rgba(255,210,128,.1);
  border: 1px solid rgba(255,210,128,.25);
  padding: 10px 28px;
  border-radius: 999px;
  margin-bottom: 26px;
}
.c-name {
  font-size: clamp(72px, 13vw, 160px);
  font-weight: 800;
  letter-spacing: 10px;
  text-indent: 10px;
  line-height: 1.15;
  text-shadow: 0 0 90px rgba(130,160,255,.9), 0 10px 40px rgba(0,0,0,.4);
  animation: breathe 2s ease-in-out infinite;
}
@keyframes breathe {
  0%, 100% { transform: scale(1); }
  50% { transform: scale(1.025); }
}
.c-class { font-size: clamp(20px, 3vw, 34px); color: rgba(255,255,255,.6); margin-top: 8px; letter-spacing: 6px; }
.c-text {
  font-size: clamp(28px, 4.6vw, 52px);
  font-weight: 600;
  margin-top: 28px;
  color: #ffe28a;
  max-width: 78vw;
  margin-left: auto; margin-right: auto;
  line-height: 1.5;
  text-shadow: 0 4px 24px rgba(0,0,0,.35);
}
.c-from { margin-top: 20px; font-size: clamp(15px, 2vw, 22px); color: rgba(255,255,255,.5); letter-spacing: 2px; }
.c-queue {
  margin-top: 14px;
  display: inline-block;
  font-size: 14px;
  color: rgba(255,255,255,.55);
  background: rgba(255,255,255,.08);
  padding: 6px 16px;
  border-radius: 999px;
}
.c-progress {
  width: min(480px, 60vw);
  height: 5px;
  background: rgba(255,255,255,.12);
  border-radius: 999px;
  margin: 40px auto 0;
  overflow: hidden;
}
.c-bar {
  height: 100%;
  width: 100%;
  background: linear-gradient(90deg, #4f7cff, #a78bfa);
  border-radius: 999px;
  animation: shrink linear forwards;
  transform-origin: left;
}
@keyframes shrink { from { transform: scaleX(1); } to { transform: scaleX(0); } }

/* 播报音浪 */
.eq { display: inline-flex; align-items: flex-end; gap: 3px; height: 16px; }
.eq i {
  width: 3px;
  background: #ffd280;
  border-radius: 2px;
  animation: eq .9s ease-in-out infinite;
}
.eq i:nth-child(1) { height: 40%; animation-delay: 0s; }
.eq i:nth-child(2) { height: 90%; animation-delay: .15s; }
.eq i:nth-child(3) { height: 60%; animation-delay: .3s; }
.eq i:nth-child(4) { height: 100%; animation-delay: .45s; }
@keyframes eq { 0%, 100% { transform: scaleY(.5); } 50% { transform: scaleY(1); } }

/* ---------- 控制角标 ---------- */
.ctrl { position: fixed; right: 24px; bottom: 24px; display: flex; gap: 10px; z-index: 10; }
.ctrl button {
  width: 52px; height: 52px;
  border-radius: 50%;
  border: 1px solid rgba(255,255,255,.15);
  background: rgba(255,255,255,.08);
  backdrop-filter: blur(8px);
  color: #fff;
  font-size: 20px;
  cursor: pointer;
  transition: background .15s, transform .15s;
}
.ctrl button:hover { background: rgba(255,255,255,.18); transform: scale(1.06); }

@keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
@keyframes popIn { from { opacity: 0; transform: scale(.94); } to { opacity: 1; transform: scale(1); } }
@keyframes blink { 50% { opacity: .4; } }
</style>
