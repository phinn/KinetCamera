// 将 web/dist 拷贝到 server 旁边的静态目录(server 直接读 ../web/dist,此脚本仅校验产物存在)
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(__dirname, '..', 'web', 'dist');
if (!fs.existsSync(path.join(dist, 'index.html'))) {
  console.error('web/dist/index.html 不存在,build 失败');
  process.exit(1);
}
console.log('web build OK:', dist);
