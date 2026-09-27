import express from 'express';
import http from 'http';
import path from 'path';
import { fileURLToPath } from 'url';
import cookieParser from 'cookie-parser';
import { Server } from 'socket.io';
import { getDb, save, sha256, nextId } from './store.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
const server = http.createServer(app);
const io = new Server(server, { maxHttpBufferSize: 1e6 });

app.use(express.json());
app.use(cookieParser());

// ---------- auth ----------
function auth(req, res, next) {
  const db = getDb();
  const token = req.cookies.token;
  const user = token && db.sessions?.[token];
  if (!user) return res.status(401).json({ error: '未登录' });
  req.user = user;
  next();
}
// sessions 存内存 + db.sessions
if (!getDb().sessions) getDb().sessions = {};

app.post('/api/login', (req, res) => {
  const { username, password } = req.body || {};
  const db = getDb();
  const u = db.users.find(u => u.username === username && u.pass === sha256(password));
  if (!u) return res.status(401).json({ error: '用户名或密码错误' });
  const token = nextId('tk');
  db.sessions[token] = { username: u.username, name: u.name, role: u.role };
  save();
  res.cookie('token', token, { httpOnly: true, sameSite: 'lax' });
  res.json({ ok: 1, user: { username: u.username, name: u.name, role: u.role } });
});

app.post('/api/logout', (req, res) => {
  const db = getDb();
  const token = req.cookies.token;
  if (token) { delete db.sessions[token]; save(); }
  res.clearCookie('token');
  res.json({ ok: 1 });
});

app.get('/api/me', auth, (req, res) => res.json({ user: req.user }));

// ---------- 结构数据 ----------
app.get('/api/grades', auth, (req, res) => {
  const db = getDb();
  const grades = db.grades.map(g => ({
    ...g,
    classCount: db.classes.filter(c => c.gradeId === g.id).length,
  }));
  res.json({ grades });
});

app.get('/api/classes/:gradeId', auth, (req, res) => {
  const db = getDb();
  const classes = db.classes.filter(c => c.gradeId === req.params.gradeId).map(c => ({
    ...c,
    studentCount: db.students.filter(s => s.classId === c.id).length,
    teacherCount: db.teachers.filter(t => t.classId === c.id).length,
  }));
  res.json({ classes });
});

app.get('/api/classes/:classId/members', auth, (req, res) => {
  const db = getDb();
  const cls = db.classes.find(c => c.id === req.params.classId);
  if (!cls) return res.status(404).json({ error: '班级不存在' });
  res.json({
    class: cls,
    students: db.students.filter(s => s.classId === cls.id),
    teachers: db.teachers.filter(t => t.classId === cls.id),
  });
});

// 大屏定位单个目标(学生或老师)
app.get('/api/target/:id', auth, (req, res) => {
  const db = getDb();
  const s = db.students.find(x => x.id === req.params.id);
  if (s) {
    const cls = db.classes.find(c => c.id === s.classId);
    return res.json({ ...s, kind: 'student', className: cls?.name || '' });
  }
  const t = db.teachers.find(x => x.id === req.params.id);
  if (t) {
    const cls = db.classes.find(c => c.id === t.classId);
    return res.json({ ...t, kind: 'teacher', className: cls?.name || '' });
  }
  res.status(404).json({ error: '目标不存在' });
});

// ---------- 发消息 ----------
app.post('/api/call', auth, async (req, res) => {
  const { targetId, screenCode } = req.body || {};
  const text = String(req.body?.text || '').trim();
  if (!text) return res.status(400).json({ error: '消息内容不能为空' });
  if (text.length > 500) return res.status(400).json({ error: '消息最长 500 字' });
  const db = getDb();
  let target = db.students.find(s => s.id === targetId);
  let kind = 'student';
  if (!target) { target = db.teachers.find(t => t.id === targetId); kind = 'teacher'; }
  if (!target) return res.status(404).json({ error: '目标不存在' });
  const cls = db.classes.find(c => c.id === target.classId);

  // delivered = 配对码已注册 且 该房间确实有 socket 在线(实判,防僵尸配对码)
  let online = false;
  if (screenCode && db.screens[screenCode]) {
    try { online = (await io.in('screen:' + screenCode).fetchSockets()).length > 0; } catch {}
  }
  const msg = {
    id: nextId('m'),
    targetId: target.id,
    targetName: target.name,
    targetKind: kind,
    className: cls?.name || '',
    from: req.user.name,
    text: text.slice(0, 500),
    ts: Date.now(),
  };
  if (online) {
    io.to('screen:' + screenCode).emit('call', msg);
  }
  db.callLog.unshift({ ...msg, note: online ? '' : '未绑定大屏' });
  if (db.callLog.length > 500) db.callLog.length = 500;
  save();
  res.json({ ok: 1, msg, delivered: online });
});

app.get('/api/log', auth, (req, res) => {
  res.json({ log: getDb().callLog.slice(0, 100) });
});

// ---------- 大屏配对 ----------
app.post('/api/screen/register', (req, res) => {
  const db = getDb();
  const { screenCode, name } = req.body || {};
  if (!screenCode) return res.status(400).json({ error: '缺少 screenCode' });
  db.screens[screenCode] = { name: name || '大屏', registeredAt: Date.now() };
  save();
  res.json({ ok: 1 });
});

app.get('/api/screens', auth, (req, res) => {
  res.json({ screens: getDb().screens });
});

app.post('/api/screens/remove', auth, (req, res) => {
  const db = getDb();
  const { screenCode } = req.body || {};
  delete db.screens[screenCode];
  save();
  res.json({ ok: 1 });
});

// ---------- socket (大屏) ----------
io.on('connection', (socket) => {
  socket.on('screen:join', (code) => {
    socket.join('screen:' + code);
    socket.emit('screen:joined', { code });
  });
});

// ---------- static ----------
const webDist = path.join(__dirname, '..', 'web', 'dist');
app.use(express.static(webDist));
app.get('*', (req, res, next) => {
  if (req.path.startsWith('/api')) return next();
  res.sendFile(path.join(webDist, 'index.html'));
});

const PORT = process.env.PORT || 3311;
server.listen(PORT, () => {
  console.log(`teacher-call server listening on http://0.0.0.0:${PORT}`);
});
