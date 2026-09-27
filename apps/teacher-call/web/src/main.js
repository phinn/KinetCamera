import { createApp } from 'vue';
import { createRouter, createWebHistory } from 'vue-router';
import App from './App.vue';

import Login from './views/Login.vue';
import Grades from './views/Grades.vue';
import Classes from './views/Classes.vue';
import Members from './views/Members.vue';
import Call from './views/Call.vue';
import Screen from './views/Screen.vue';

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/', component: Grades, meta: { auth: true } },
    { path: '/login', component: Login },
    { path: '/grade/:gradeId', component: Classes, meta: { auth: true } },
    { path: '/class/:classId', component: Members, meta: { auth: true } },
    { path: '/call/:kind/:targetId', component: Call, meta: { auth: true } },
    { path: '/screen', component: Screen },
  ],
});

router.beforeEach((to) => {
  if (to.meta.auth && !localStorage.getItem('user')) {
    return '/login';
  }
});

createApp(App).use(router).mount('#app');
