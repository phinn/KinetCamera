// 用户/数据存储(JSON 文件持久化)
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_DIR = process.env.TC_DATA_DIR || path.join(__dirname, '..', 'data');
const DB_FILE = path.join(DATA_DIR, 'db.json');

export function sha256(s) {
  return crypto.createHash('sha256').update(String(s)).digest('hex');
}

function seedDb() {
  const grades = [
    { id: 'g1', name: '一年级' },
    { id: 'g2', name: '二年级' },
    { id: 'g3', name: '三年级' },
    { id: 'g4', name: '四年级' },
    { id: 'g5', name: '五年级' },
    { id: 'g6', name: '六年级' },
  ];
  const classes = [];
  const students = [];
  const teachers = [];
  let sid = 1;
  let tid = 1;
  const surname = ['王', '李', '张', '刘', '陈', '杨', '黄', '赵', '周', '吴', '徐', '孙', '马', '朱', '胡', '郭', '何', '林', '罗', '郑'];
  const given = ['子涵', '雨桐', '浩然', '诗涵', '宇轩', '梦琪', '思远', '佳怡', '俊杰', '欣怡', '梓萱', '一诺', '博文', '语嫣', '天佑', '可欣', '志强', '静怡', '明轩', '晓东'];
  const subjects = ['语文', '数学', '英语', '体育', '音乐', '美术', '科学'];
  const surnames2 = ['王', '李', '张', '刘', '陈'];

  grades.forEach((g, gi) => {
    const classCount = 4;
    for (let c = 1; c <= classCount; c++) {
      const cid = `g${gi + 1}c${c}`;
      classes.push({ id: cid, gradeId: g.id, name: `${g.name.slice(0, -1)}${c}班` });
      // 学生 20-24 人
      const n = 20 + ((gi + c) % 5);
      for (let i = 0; i < n; i++) {
        const name = surname[(sid * 7 + i * 3) % surname.length] + given[(sid * 5 + i) % given.length];
        students.push({
          id: `s${sid++}`,
          classId: cid,
          name,
          seat: i + 1,
        });
      }
      // 班级任课老师 3-4 名
      const tn = 3 + (c % 2);
      for (let i = 0; i < tn; i++) {
        teachers.push({
          id: `t${tid++}`,
          classId: cid,
          name: surnames2[(tid * 3) % surnames2.length] + subjects[(i + gi) % subjects.length] + '老师',
        });
      }
    }
  });

  return {
    users: [
      { username: 'admin', pass: sha256('admin123'), name: '管理员', role: 'admin' },
      { username: 'wang', pass: sha256('123456'), name: '王老师', role: 'teacher' },
    ],
    grades, classes, students, teachers,
    screens: {},     // screenCode -> { name, lastSeen }
    callLog: [],     // { id, screenCode, targetId, targetName, targetKind, from, text, ts }
  };
}

let db;
if (fs.existsSync(DB_FILE)) {
  db = JSON.parse(fs.readFileSync(DB_FILE, 'utf8'));
} else {
  db = seedDb();
  fs.mkdirSync(DATA_DIR, { recursive: true });
  save();
}

export function save() {
  const tmp = DB_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(db));
  fs.renameSync(tmp, DB_FILE);
}

export function getDb() { return db; }
export function nextId(prefix) {
  return prefix + Math.random().toString(36).slice(2, 10);
}
