// Hero demo: the same five windows under four TilePilot layout actions.
(() => {
  const demo = document.getElementById('demo');
  const stage = document.getElementById('stage');
  if (!demo || !stage) return;

  const pill = document.getElementById('demo-pill');
  const status = document.getElementById('demo-status');
  const buttons = Array.from(demo.querySelectorAll('.demo-actions button'));
  const wins = Object.fromEntries(Array.from(stage.querySelectorAll('.win')).map((el) => [el.dataset.win, el]));

  // [x, y, w, h, z, state] in percent of the stage.
  const layouts = {
    float: {
      pill: ['Tiling Off', false],
      status: 'Five floating windows, stacked wherever they were last dropped.',
      wins: {
        editor: [6, 9, 44, 54, 2, 'floating'],
        browser: [27, 17, 50, 60, 3, 'floating'],
        terminal: [55, 6, 36, 42, 4, 'floating'],
        notes: [12, 44, 32, 46, 5, 'floating'],
        calc: [70, 52, 17, 36, 6, 'floating'],
      },
    },
    tile: {
      pill: ['Tiling On', true],
      status: 'Four windows tiled side by side. Calculator is set to Never Auto-Tile, so it stays floating.',
      wins: {
        editor: [1.5, 2.5, 48, 95, 1, 'tiled'],
        browser: [51, 2.5, 47.5, 46.5, 1, 'tiled'],
        terminal: [51, 51, 23, 46.5, 1, 'tiled'],
        notes: [75.5, 51, 23, 46.5, 1, 'tiled'],
        calc: [60, 22, 17, 40, 6, 'floating'],
      },
    },
    grid: {
      pill: ['Tiling Off', false],
      status: 'A floating grid. The last column stretches one window instead of leaving a hole.',
      wins: {
        editor: [1.5, 2.5, 31.3, 46.5, 1, 'floating'],
        browser: [34.3, 2.5, 31.3, 46.5, 1, 'floating'],
        terminal: [67.2, 2.5, 31.3, 95, 1, 'floating'],
        notes: [1.5, 51, 31.3, 46.5, 1, 'floating'],
        calc: [34.3, 51, 31.3, 46.5, 1, 'floating'],
      },
    },
    template: {
      pill: ['Template', false],
      status: 'A saved Template: exact floating slots, with the browser always in the center.',
      wins: {
        browser: [22, 2.5, 56, 95, 1, 'floating'],
        editor: [1.5, 2.5, 19, 46.5, 1, 'floating'],
        notes: [1.5, 51, 19, 46.5, 1, 'floating'],
        terminal: [79.5, 2.5, 19, 46.5, 1, 'floating'],
        calc: [79.5, 51, 19, 46.5, 1, 'floating'],
      },
    },
  };
  const order = ['float', 'tile', 'grid', 'template'];
  let current = 'float';

  function apply(name) {
    const layout = layouts[name];
    if (!layout) return;
    current = name;
    stage.dataset.layout = name;
    for (const [key, [x, y, w, h, z, state]] of Object.entries(layout.wins)) {
      const el = wins[key];
      if (!el) continue;
      el.style.setProperty('--x', x);
      el.style.setProperty('--y', y);
      el.style.setProperty('--w', w);
      el.style.setProperty('--h', h);
      el.style.setProperty('--z', z);
      el.dataset.state = state;
    }
    pill.textContent = layout.pill[0];
    pill.classList.toggle('is-on', layout.pill[1]);
    status.textContent = layout.status;
    for (const button of buttons) {
      button.setAttribute('aria-pressed', String(button.dataset.layout === name));
    }
  }

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let timer = null;
  let userTookOver = false;
  let hovering = false;
  let visible = true;

  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
  }
  function start() {
    if (reduceMotion || userTookOver || hovering || !visible || document.hidden || timer) return;
    timer = setInterval(() => apply(order[(order.indexOf(current) + 1) % order.length]), 3400);
  }

  for (const button of buttons) {
    button.addEventListener('click', () => {
      userTookOver = true;
      stop();
      apply(button.dataset.layout);
    });
  }
  demo.addEventListener('pointerenter', () => { hovering = true; stop(); });
  demo.addEventListener('pointerleave', () => { hovering = false; start(); });
  demo.addEventListener('focusin', () => { hovering = true; stop(); });
  demo.addEventListener('focusout', () => { hovering = false; start(); });
  document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      visible ? start() : stop();
    }, { threshold: 0.25 }).observe(demo);
  }

  apply(reduceMotion ? 'tile' : 'float');
  if (!reduceMotion) setTimeout(() => { if (!userTookOver && current === 'float') apply('tile'); start(); }, 1600);
})();

