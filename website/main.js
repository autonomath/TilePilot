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

// Work Area demo: a desktop on a big TV, then inside a Work Area, then with the menu bar shown above it.
(() => {
  const demo = document.getElementById('wa-demo');
  const screen = document.getElementById('wa-screen');
  if (!demo || !screen) return;

  const status = document.getElementById('wa-status');
  const buttons = Array.from(demo.querySelectorAll('.wa-actions button'));
  const wins = Object.fromEntries(Array.from(screen.querySelectorAll('.win')).map((el) => [el.dataset.win, el]));
  const pointer = screen.querySelector('.wa-pointer');
  const mirrorBar = screen.querySelector('.mirror-bar');
  const fileItem = screen.querySelector('.mirror-file');

  // [x, y, w, h, z, state] in percent of the screen. The Work Area is x 15–85, y 24–94.
  const inside = {
    editor: [15.6, 24.8, 34.2, 68.4, 1, 'tiled'],
    browser: [50.4, 24.8, 34, 33.9, 1, 'tiled'],
    terminal: [50.4, 59.3, 34, 33.9, 1, 'tiled'],
    notes: [64, 29, 16, 26, 5, 'floating'],
  };
  const steps = {
    whole: {
      status: 'A 4K TV across the room. Tiled windows stretch to the far corners, and the menu bar sits at the very top edge.',
      wins: {
        editor: [0.6, 4.4, 49.2, 95, 1, 'tiled'],
        browser: [50.4, 4.4, 49, 47.2, 1, 'tiled'],
        terminal: [50.4, 52.2, 49, 47.2, 1, 'tiled'],
        notes: [79, 8, 18, 30, 5, 'floating'],
      },
    },
    area: {
      status: 'With a Work Area, everything stays in a comfortable rectangle. A floating window dropped outside moves back in.',
      wins: inside,
    },
    bar: {
      status: "Turn on the menu bar and the app's menus and icons sit right above your windows. Choosing an item uses the real menu.",
      wins: inside,
    },
  };
  const order = ['whole', 'area', 'bar'];
  let current = 'whole';

  function placePointer() {
    if (current === 'bar' && mirrorBar && fileItem) {
      // Offsets ignore the bar's slide-in transform, so this is where File ends up.
      const x = mirrorBar.offsetLeft + fileItem.offsetLeft + fileItem.offsetWidth * 0.6;
      const y = mirrorBar.offsetTop + fileItem.offsetTop + fileItem.offsetHeight * 0.55;
      pointer.style.left = (x / screen.clientWidth) * 100 + '%';
      pointer.style.top = (y / screen.clientHeight) * 100 + '%';
    } else {
      pointer.style.left = '';
      pointer.style.top = '';
    }
  }

  function apply(name) {
    const step = steps[name];
    if (!step) return;
    current = name;
    screen.dataset.step = name;
    for (const [key, [x, y, w, h, z, state]] of Object.entries(step.wins)) {
      const el = wins[key];
      if (!el) continue;
      el.style.setProperty('--x', x);
      el.style.setProperty('--y', y);
      el.style.setProperty('--w', w);
      el.style.setProperty('--h', h);
      el.style.setProperty('--z', z);
      el.dataset.state = state;
    }
    placePointer();
    status.textContent = step.status;
    for (const button of buttons) {
      button.setAttribute('aria-pressed', String(button.dataset.step === name));
    }
  }

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  let timer = null;
  let userTookOver = false;
  let hovering = false;
  let visible = false;

  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
  }
  function start() {
    if (reduceMotion || userTookOver || hovering || !visible || document.hidden || timer) return;
    timer = setInterval(() => apply(order[(order.indexOf(current) + 1) % order.length]), 3800);
  }

  for (const button of buttons) {
    button.addEventListener('click', () => {
      userTookOver = true;
      stop();
      apply(button.dataset.step);
    });
  }
  demo.addEventListener('pointerenter', () => { hovering = true; stop(); });
  demo.addEventListener('pointerleave', () => { hovering = false; start(); });
  demo.addEventListener('focusin', () => { hovering = true; stop(); });
  demo.addEventListener('focusout', () => { hovering = false; start(); });
  document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));
  window.addEventListener('resize', placePointer);
  if ('IntersectionObserver' in window) {
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      visible ? start() : stop();
    }, { threshold: 0.35 }).observe(demo);
  } else {
    visible = true;
  }

  apply(reduceMotion ? 'bar' : 'whole');
  start();
})();
