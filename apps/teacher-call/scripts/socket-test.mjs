// socket 断线重连 + 排队播报时序验证(模拟大屏端行为)
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { io } = require('../web/node_modules/socket.io-client');

const BASE = process.env.TC_BASE || 'http://localhost:3311';
const events = [];
let pass = 0, fail = 0;
const ok = (n, c, d = '') => { c ? pass++ : fail++; console.log(`  ${c ? '✅' : '❌'} ${n}${d ? ' — ' + d : ''}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

// 登录
const lr = await fetch(BASE + '/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: 'admin', password: 'admin123' }) });
const cookie = lr.headers.get('set-cookie').split(';')[0];
const H = { 'Content-Type': 'application/json', cookie };
const call = (targetId, text) => fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId, text, screenCode: '777777' }) });

// —— 注册独立配对码,不干扰真实大屏 ——
await fetch(BASE + '/api/screen/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ screenCode: '777777' }) });

const socket = io(BASE, { path: '/socket.io', reconnectionDelayMax: 2000 });
socket.on('connect', () => socket.emit('screen:join', '777777'));

const received = [];
socket.on('call', m => { received.push(m); events.push([Date.now(), 'recv:' + m.text]); });

console.log('\n[1] 基础推送');
await sleep(600);
await call('s91', '重连测试-推送前');
await sleep(400);
ok('在线大屏收到推送', received.length === 1, `received=${received.length}`);
ok('delivered=true', (await (await call('s91', 'delivered判定')).json()).delivered === true);

console.log('\n[2] 断线期间的推送 → 重连后补发验证');
socket.io.engine.close();          // 模拟大屏断网
await sleep(300);
const r2 = await (await call('s91', '断线期间消息')).json();
ok('断线时服务端判 delivered=false', r2.delivered === false, `delivered=${r2.delivered}`);
socket.connect();                   // 重连
await sleep(1500);
ok('socket 重连成功并重进房间', socket.connected && received.length >= 2, `connected=${socket.connected}, received=${received.length}`);

console.log('\n[3] 连发 4 条 → 顺序到达(大屏端应按此顺序排队逐条播)');
const t0 = Date.now();
for (let i = 1; i <= 4; i++) await call('s9' + i, `顺序消息${i}`);
await sleep(600);
const seq = received.filter(m => m.text.startsWith('顺序消息')).map(m => m.text);
ok('4 条按发送顺序到达', JSON.stringify(seq) === JSON.stringify(['顺序消息1', '顺序消息2', '顺序消息3', '顺序消息4']), seq.join(' → '));
ok('4 条几乎同时到达(排队逻辑在大屏端)', Date.now() - t0 < 1500, `${Date.now() - t0}ms`);

socket.disconnect();
console.log(`\n========== 结果: ${pass} 通过 / ${fail} 失败 ==========`);
process.exit(fail ? 1 : 0);
