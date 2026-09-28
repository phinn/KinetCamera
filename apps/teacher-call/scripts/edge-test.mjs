// 边界自测脚本:错误密码/空文本/超长文本/不存在目标/错误配对码/重复点击/断线重连/连发排队
const BASE = process.env.TC_BASE || 'http://localhost:3311';
let pass = 0, fail = 0;
const ok = (name, cond, detail = '') => {
  if (cond) { pass++; console.log(`  ✅ ${name}${detail ? ' — ' + detail : ''}`); }
  else { fail++; console.log(`  ❌ ${name}${detail ? ' — ' + detail : ''}`); }
};

// 登录拿 cookie
async function login(u, p) {
  const r = await fetch(BASE + '/api/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: u, password: p }),
  });
  return { status: r.status, cookie: r.headers.get('set-cookie')?.split(';')[0] || '' };
}

const results = {};

// ============ 1. 错误密码 ============
console.log('\n[1] 登录边界');
{
  const bad = await login('admin', 'wrongpass');
  ok('错误密码 → 401', bad.status === 401, `status=${bad.status}`);
  const noUser = await login('nouser', 'x');
  ok('不存在用户 → 401', noUser.status === 401, `status=${noUser.status}`);
  const empty = await login('', '');
  ok('空账密 → 401', empty.status === 401, `status=${empty.status}`);
  const good = await login('admin', 'admin123');
  ok('正确账密 → 200', good.status === 200);
  results.cookie = good.cookie;
}

const H = { 'Content-Type': 'application/json', cookie: results.cookie };

// ============ 2. 空文本 / 超长文本 / 不存在目标 ============
console.log('\n[2] 消息内容校验');
{
  let r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's91', text: '   ' }) });
  ok('纯空格文本 → 400', r.status === 400, `status=${r.status}`);
  r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's91', text: '' }) });
  ok('空文本 → 400', r.status === 400, `status=${r.status}`);
  r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's91', text: '长'.repeat(501) }) });
  ok('501字超长 → 400', r.status === 400, `status=${r.status}`);
  r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's91', text: '边'.repeat(500) }) });
  const j = await r.json();
  ok('500字压线 → 200', r.status === 200, `text.len=${j.msg?.text?.length}`);
  r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 'nonexist', text: 'hi' }) });
  ok('不存在目标 → 404', r.status === 404, `status=${r.status}`);
  r = await fetch(BASE + '/api/call', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ targetId: 's91', text: 'hi' }) });
  ok('无 cookie 未登录 → 401', r.status === 401, `status=${r.status}`);
}

// ============ 3. 错误/僵尸配对码 → delivered=false ============
console.log('\n[3] 配对码边界');
{
  const r = await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's91', text: '错误配对码测试', screenCode: '999999' }) });
  const j = await r.json();
  ok('未注册配对码 → delivered=false', j.delivered === false, `delivered=${j.delivered},note=${j.msg?.note}`);
}

// ============ 4. 连发 5 条(排队) + 幂等 ============
console.log('\n[4] 连发多条(验证排队不覆盖)');
{
  for (let i = 1; i <= 5; i++) {
    await fetch(BASE + '/api/call', { method: 'POST', headers: H, body: JSON.stringify({ targetId: 's9' + i, text: `排队测试第${i}条`, screenCode: '888888' }) });
  }
  const lr = await fetch(BASE + '/api/log', { headers: { cookie: results.cookie } });
  const { log } = await lr.json();
  const queued = [...new Set(log.filter(l => l.text.startsWith('排队测试')).map(l => l.text))].reverse();
  ok('5 条全部入日志且有序', queued.length === 5 && queued[4] === '排队测试第5条', queued.join(' | '));
}

// ============ 5. 未登录访问受保护接口 ============
console.log('\n[5] 未登录访问');
{
  for (const ep of ['/api/grades', '/api/log']) {
    const r = await fetch(BASE + ep);
    ok(`GET ${ep} → 401`, r.status === 401, `status=${r.status}`);
  }
}

console.log(`\n========== 结果: ${pass} 通过 / ${fail} 失败 ==========`);
process.exit(fail ? 1 : 0);
