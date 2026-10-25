(() => {
  const q = selector => document.querySelector(selector);
  const strip = q('.tabs');
  const viewport = q('.tab-viewport');
  const preview = q('.tab-preview');
  const marker = q('.drop-marker');
  let sequence = 3;
  const initialTabs = () => [
    {id: 'ghostty', title: 'ghostty', path: '~/dev/projects/ghostty', panes: 4},
    {id: 'dotfiles', title: 'dotfiles', path: '~/.config/hamlet', panes: 2},
    {id: 'notes', title: 'notes', path: '~/notes', panes: 1},
  ];
  const state = {tabs: initialTabs(), active: 'ghostty', dragged: null, dragX: 0, lastClosed: null, pickerIndex: 0};
  const sessions = [
    {name: 'hamlet', saved: false},
    {name: 'ember', saved: true},
    {name: 'quiet meadow', saved: true},
  ];
  let currentSession = sessions[0];
  let hoverTimer, toastTimer, dragFrame;
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const behavior = () => reducedMotion.matches ? 'instant' : 'smooth';
  const chip = id => [...strip.children].find(node => node.dataset.id === id);
  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };

  function hidePreview() {
    clearTimeout(hoverTimer);
    preview.hidden = true;
    document.querySelectorAll('[aria-describedby="tab-preview"]').forEach(node => node.removeAttribute('aria-describedby'));
  }

  function position(panel, anchor, alignRight = false) {
    const rect = anchor.getBoundingClientRect();
    panel.style.left = Math.max(12, Math.min(alignRight ? rect.right - panel.offsetWidth : rect.left, innerWidth - panel.offsetWidth - 12)) + 'px';
    panel.style.top = Math.max(8, Math.min(rect.bottom + 7, innerHeight - panel.offsetHeight - 12)) + 'px';
  }

  function closePanels() {
    q('.session-menu').hidden = true;
    q('.tab-picker').hidden = true;
    q('.session').setAttribute('aria-expanded', 'false');
    q('#find-tab').setAttribute('aria-expanded', 'false');
    hidePreview();
  }

  function showPreview(tab, root) {
    clearTimeout(hoverTimer);
    hoverTimer = setTimeout(() => {
      if (state.dragged || !q('.tab-picker').hidden || !root.isConnected) return;
      preview.querySelector('strong').textContent = tab.title;
      preview.querySelector('code').textContent = tab.path;
      preview.querySelector('span').textContent = `${tab.panes} ${tab.panes === 1 ? 'pane' : 'panes'} · ${tab.id === state.active ? 'Active tab' : 'Click to switch'}`;
      preview.hidden = false;
      position(preview, root);
      root.querySelector('.tab-select').setAttribute('aria-describedby', 'tab-preview');
    }, 450);
  }

  function updateOverflow() {
    const overflow = strip.scrollWidth > strip.clientWidth + 2;
    q('#scroll-left').hidden = !overflow;
    q('#scroll-right').hidden = !overflow;
    q('#scroll-left').disabled = strip.scrollLeft <= 2;
    q('#scroll-right').disabled = strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 2;
    viewport.classList.toggle('can-left', overflow && !q('#scroll-left').disabled);
    viewport.classList.toggle('can-right', overflow && !q('#scroll-right').disabled);
  }

  function reveal(id) {
    requestAnimationFrame(() => {
      const node = chip(id);
      if (!node) return;
      const bounds = node.getBoundingClientRect();
      const visible = strip.getBoundingClientRect();
      if (bounds.left < visible.left + 8) strip.scrollBy({left: bounds.left - visible.left - 8, behavior: behavior()});
      else if (bounds.right > visible.right - 8) strip.scrollBy({left: bounds.right - visible.right + 8, behavior: behavior()});
    });
  }

  function activate(id, focus = false) {
    const tab = state.tabs.find(item => item.id === id);
    if (!tab) return;
    state.active = id;
    tab.attention = false;
    [...strip.children].forEach(root => {
      const selected = root.dataset.id === id;
      root.classList.toggle('selected', selected);
      if (selected) root.classList.remove('needs-attention', 'attention-pulse');
      const button = root.querySelector('.tab-select');
      button.setAttribute('aria-selected', String(selected));
      if (selected) button.setAttribute('aria-label', tab.title);
      button.tabIndex = selected ? 0 : -1;
      if (selected) root.querySelector('.attention-dot').hidden = true;
    });
    if (focus) chip(id)?.querySelector('.tab-select').focus({preventScroll: true});
    reveal(id);
  }

  // The activity study uses the same finite-pulse behavior as manual attention.
  document.addEventListener('draft:activity-attention', event => {
    const tab = state.tabs.find(item => item.id === event.detail.tab);
    if (!tab) return;
    tab.attention = Boolean(event.detail.attention);
    if (tab.attention) tab.attentionAt = performance.now();
    renderTabs();
  });

  function renderTabs(focusId) {
    hidePreview();
    strip.replaceChildren();
    for (const tab of state.tabs) {
      const root = element('div', 'tab' + (tab.id === state.active ? ' selected' : ''));
      root.classList.toggle('needs-attention', Boolean(tab.attention && tab.id !== state.active));
      if (tab.attention && tab.id !== state.active && tab.attentionAt !== undefined && !reducedMotion.matches) {
        const elapsed = performance.now() - tab.attentionAt;
        if (elapsed < 1200) {
          root.style.setProperty('--attention-delay', `-${elapsed}ms`);
          root.classList.add('attention-pulse');
          root.addEventListener('animationend', event => {
            if (event.animationName === 'attention-arrival') root.classList.remove('attention-pulse');
          });
        }
      }
      root.dataset.id = tab.id;
      root.setAttribute('role', 'presentation');
      root.draggable = true;
      const select = element('button', 'tab-select');
      select.setAttribute('role', 'tab');
      select.setAttribute('aria-selected', String(tab.id === state.active));
      select.setAttribute('aria-label', tab.title + (tab.attention && tab.id !== state.active ? ', needs attention' : ''));
      select.setAttribute('aria-controls', 'draft-workspace');
      select.tabIndex = tab.id === state.active ? 0 : -1;
      select.append(element('span', 'tab-label', tab.title));
      select.addEventListener('click', () => activate(tab.id));
      select.addEventListener('keydown', event => {
        const index = state.tabs.findIndex(item => item.id === tab.id);
        let target;
        if (event.key === 'ArrowRight') target = (index + 1) % state.tabs.length;
        else if (event.key === 'ArrowLeft') target = (index + state.tabs.length - 1) % state.tabs.length;
        else if (event.key === 'Home') target = 0;
        else if (event.key === 'End') target = state.tabs.length - 1;
        else if (event.key === 'Delete') { event.preventDefault(); closeTab(tab.id); return; }
        if (target !== undefined) { event.preventDefault(); activate(state.tabs[target].id, true); }
      });
      const close = element('button', 'close', '×');
      close.setAttribute('aria-label', `Close ${tab.title}`);
      close.title = 'Close tab';
      close.tabIndex = -1;
      close.addEventListener('pointerenter', hidePreview);
      close.addEventListener('click', () => closeTab(tab.id));
      const dot = element('span', 'attention-dot');
      dot.hidden = !tab.attention || tab.id === state.active;
      dot.setAttribute('aria-hidden', 'true');
      root.append(select, close, dot);
      root.addEventListener('pointerenter', () => showPreview(tab, root));
      root.addEventListener('pointerleave', hidePreview);
      select.addEventListener('focus', () => showPreview(tab, root));
      select.addEventListener('blur', hidePreview);
      root.addEventListener('auxclick', event => { if (event.button === 1) { event.preventDefault(); closeTab(tab.id); } });
      root.addEventListener('dragstart', event => {
        if (event.target.closest('.close')) { event.preventDefault(); return; }
        closePanels();
        state.dragged = tab.id;
        event.dataTransfer.effectAllowed = 'move';
        event.dataTransfer.setData('application/x-ghostty-draft-tab', tab.id);
        root.classList.add('dragging');
      });
      root.addEventListener('dragend', finishDrag);
      strip.append(root);
    }
    q('.workspace').classList.toggle('no-tabs', state.tabs.length === 0);
    requestAnimationFrame(() => { updateOverflow(); reveal(state.active); });
    if (focusId) chip(focusId)?.querySelector('.tab-select').focus({preventScroll: true});
  }

  function toast(message, undo = false) {
    clearTimeout(toastTimer);
    q('.draft-toast > span').textContent = message;
    q('#undo-close').hidden = !undo;
    q('.draft-toast').hidden = false;
    toastTimer = setTimeout(() => { q('.draft-toast').hidden = true; }, 6000);
  }

  function closeTab(id) {
    const index = state.tabs.findIndex(item => item.id === id);
    if (index === -1) return;
    const [tab] = state.tabs.splice(index, 1);
    state.lastClosed = {tab, index};
    if (state.active === id) state.active = state.tabs[Math.min(index, state.tabs.length - 1)]?.id ?? null;
    renderTabs(state.active);
    toast(`Closed “${tab.title}”`, true);
  }

  q('#undo-close').addEventListener('click', () => {
    if (!state.lastClosed) return;
    const {tab, index} = state.lastClosed;
    state.tabs.splice(Math.min(index, state.tabs.length), 0, tab);
    state.active = tab.id;
    state.lastClosed = null;
    q('.draft-toast').hidden = true;
    clearTimeout(toastTimer);
    renderTabs(tab.id);
  });

  q('#add-tab').addEventListener('click', () => {
    const number = ++sequence;
    const tab = {id: `shell-${number}`, title: `shell ${number - 3}`, path: '~/dev', panes: 1};
    state.tabs.push(tab);
    state.active = tab.id;
    renderTabs(tab.id);
  });

  function filteredTabs() {
    const query = q('#tab-search').value.trim().toLocaleLowerCase();
    return state.tabs.filter(tab => `${tab.title} ${tab.path}`.toLocaleLowerCase().includes(query));
  }

  function renderResults() {
    const results = q('#tab-results');
    results.replaceChildren();
    const tabs = filteredTabs();
    state.pickerIndex = Math.max(0, Math.min(state.pickerIndex, tabs.length - 1));
    tabs.forEach((tab, index) => {
      const row = element('button', 'result' + (index === state.pickerIndex ? ' focused' : ''));
      row.tabIndex = -1;
      const copy = element('span', 'result-copy');
      copy.append(element('span', 'result-title', tab.title), element('span', 'result-detail', `${tab.path} · ${tab.panes} ${tab.panes === 1 ? 'pane' : 'panes'}`));
      row.append(copy);
      if (tab.id === state.active) row.append(element('span', 'result-check', '✓'));
      row.addEventListener('click', () => { activate(tab.id, true); closePanels(); });
      results.append(row);
    });
    if (!tabs.length) results.append(element('div', 'no-results', 'No matching tabs'));
    results.querySelector('.focused')?.scrollIntoView({block: 'nearest'});
  }

  q('#find-tab').addEventListener('click', () => {
    const open = q('.tab-picker').hidden;
    closePanels();
    if (!open) return;
    q('.tab-picker').hidden = false;
    q('#find-tab').setAttribute('aria-expanded', 'true');
    q('#tab-search').value = '';
    state.pickerIndex = Math.max(0, state.tabs.findIndex(tab => tab.id === state.active));
    renderResults();
    position(q('.tab-picker'), q('#find-tab'), true);
    q('#tab-search').focus();
  });
  q('#tab-search').addEventListener('input', () => { state.pickerIndex = 0; renderResults(); });
  q('#tab-search').addEventListener('keydown', event => {
    const tabs = filteredTabs();
    if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && tabs.length) {
      event.preventDefault();
      state.pickerIndex = (state.pickerIndex + (event.key === 'ArrowDown' ? 1 : tabs.length - 1)) % tabs.length;
      renderResults();
    } else if (event.key === 'Enter' && tabs[state.pickerIndex]) {
      event.preventDefault();
      activate(tabs[state.pickerIndex].id, true);
      closePanels();
    }
  });

  function updateSession() {
    q('#session-name').textContent = currentSession.name;
    q('.session').dataset.saved = String(currentSession.saved);
    q('.session').title = `Sessions · ${currentSession.name} · ${currentSession.saved ? 'saved' : 'unsaved'}`;
    q('.session').setAttribute('aria-label', q('.session').title);
    q('.session-state').title = currentSession.saved ? 'Saved session' : 'Unsaved session';
    q('.session-state').setAttribute('aria-hidden', 'true');
    q('#saved-label').textContent = currentSession.saved ? 'Saved' : 'Unsaved';
    q('#save-session').textContent = currentSession.saved ? 'Session is saved' : 'Save this session';
    q('#save-session').disabled = currentSession.saved;
    q('#session-options').replaceChildren();
    sessions.forEach(session => {
      const button = element('button', '');
      const copy = element('span', '');
      copy.append(element('span', '', session.name), element('span', 'session-detail', session.saved ? 'Saved session' : 'Unsaved · available in this window'));
      button.append(copy);
      if (session === currentSession) button.append(element('span', 'session-check', '✓'));
      button.addEventListener('click', () => { currentSession = session; updateSession(); closePanels(); });
      q('#session-options').append(button);
    });
  }
  q('.session').addEventListener('click', () => {
    const open = q('.session-menu').hidden;
    closePanels();
    if (open) {
      q('.session-menu').hidden = false;
      q('.session').setAttribute('aria-expanded', 'true');
      position(q('.session-menu'), q('.session'));
    }
  });
  q('#save-session').addEventListener('click', () => {
    currentSession.saved = true;
    updateSession();
    closePanels();
    toast(`Session “${currentSession.name}” saved`);
  });

  function dropLocation(x) {
    const candidates = [...strip.children].filter(root => root.dataset.id !== state.dragged);
    const index = candidates.findIndex(root => x < root.getBoundingClientRect().left + root.offsetWidth / 2);
    const slot = index === -1 ? candidates.length : index;
    const edge = candidates[slot]?.getBoundingClientRect().left ?? candidates.at(-1)?.getBoundingClientRect().right ?? strip.getBoundingClientRect().left + 4;
    return {slot, x: edge - viewport.getBoundingClientRect().left - 2};
  }

  function drawDrop() {
    if (!state.dragged) return;
    const location = dropLocation(state.dragX);
    marker.hidden = false;
    marker.style.left = Math.max(0, Math.min(location.x, viewport.clientWidth - 2)) + 'px';
    const bounds = strip.getBoundingClientRect();
    const delta = state.dragX < bounds.left + 28 ? -9 : state.dragX > bounds.right - 28 ? 9 : 0;
    if (delta) {
      strip.scrollLeft += delta;
      dragFrame = requestAnimationFrame(drawDrop);
    }
  }

  function finishDrag() {
    state.dragged = null;
    cancelAnimationFrame(dragFrame);
    marker.hidden = true;
    strip.querySelector('.dragging')?.classList.remove('dragging');
  }
  strip.addEventListener('dragover', event => {
    if (!state.dragged) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'move';
    state.dragX = event.clientX;
    cancelAnimationFrame(dragFrame);
    drawDrop();
  });
  viewport.addEventListener('dragleave', event => {
    if (!viewport.contains(event.relatedTarget)) { marker.hidden = true; cancelAnimationFrame(dragFrame); }
  });
  strip.addEventListener('drop', event => {
    if (!state.dragged) return;
    event.preventDefault();
    const {slot} = dropLocation(event.clientX);
    const id = state.dragged;
    const index = state.tabs.findIndex(tab => tab.id === id);
    if (index === -1) { finishDrag(); return; }
    const [tab] = state.tabs.splice(index, 1);
    state.tabs.splice(slot, 0, tab);
    state.active = id;
    finishDrag();
    renderTabs(id);
  });

  strip.addEventListener('scroll', () => { updateOverflow(); hidePreview(); }, {passive: true});
  strip.addEventListener('wheel', event => {
    if (strip.scrollWidth <= strip.clientWidth || Math.abs(event.deltaY) < Math.abs(event.deltaX)) return;
    event.preventDefault();
    strip.scrollBy({left: event.deltaY, behavior: behavior()});
  }, {passive: false});
  q('#scroll-left').addEventListener('click', () => strip.scrollBy({left: -Math.max(140, strip.clientWidth * .65), behavior: behavior()}));
  q('#scroll-right').addEventListener('click', () => strip.scrollBy({left: Math.max(140, strip.clientWidth * .65), behavior: behavior()}));
  new ResizeObserver(updateOverflow).observe(q('.tab-navigation'));

  q('#overflow-demo').addEventListener('change', event => {
    state.tabs = state.tabs.filter(tab => !tab.demo);
    if (event.target.checked) {
      ['feature/session-restoration', 'review · compact tab strip', 'logs', 'docs', 'build · release', 'ssh · workstation', 'scratch', 'A very long title that should truncate without shifting its close button', 'tests', 'last workspace'].forEach((title, index) => {
        state.tabs.push({id: `demo-${index}`, title, path: '~/dev/projects/ghostty', panes: index % 3 + 1, demo: true});
      });
    }
    if (!state.tabs.some(tab => tab.id === state.active)) state.active = state.tabs[0]?.id ?? null;
    renderTabs();
  });
  q('#attention-demo').addEventListener('change', event => {
    state.tabs.forEach(tab => { tab.attention = false; });
    const tab = state.tabs.find(tab => tab.id !== state.active);
    if (tab) {
      tab.attention = event.target.checked;
      if (tab.attention) tab.attentionAt = performance.now();
    }
    renderTabs();
  });
  q('#replay-attention').addEventListener('click', () => {
    q('#attention-demo').checked = true;
    q('#attention-demo').dispatchEvent(new Event('change'));
  });
  q('#reset-tabs').addEventListener('click', () => {
    finishDrag();
    closePanels();
    clearTimeout(toastTimer);
    q('.draft-toast').hidden = true;
    state.tabs = initialTabs();
    state.active = 'ghostty';
    state.lastClosed = null;
    q('#overflow-demo').checked = false;
    q('#attention-demo').checked = false;
    renderTabs();
  });

  document.addEventListener('pointerdown', event => {
    if (!event.target.closest('.session-menu, .session, .tab-picker, #find-tab')) closePanels();
  });
  document.addEventListener('keydown', event => {
    if (event.key !== 'Escape') return;
    const pickerOpen = !q('.tab-picker').hidden;
    const sessionOpen = !q('.session-menu').hidden;
    closePanels();
    finishDrag();
    if (pickerOpen) q('#find-tab').focus();
    else if (sessionOpen) q('.session').focus();
    else document.body.classList.remove('fullscreen');
  });
  addEventListener('resize', () => { closePanels(); updateOverflow(); });
  addEventListener('scroll', closePanels, {passive: true});
  reducedMotion.addEventListener('change', event => {
    if (event.matches) strip.querySelectorAll('.attention-pulse').forEach(root => root.classList.remove('attention-pulse'));
  });
  q('.workspace').id = 'draft-workspace';
  updateSession();
  renderTabs();
})();
