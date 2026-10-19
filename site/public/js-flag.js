// Помечает страницу как «с JS»: до монтирования Svelte-островов их SSR-фолбэк скрыт, чтобы не мигать (см. resources/css/site.css).
document.documentElement.classList.add('js');
