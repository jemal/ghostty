(() => {
  const q = selector => document.querySelector(selector);
  const node = (tag, cls, text) => {
    const element = document.createElement(tag);
    if (cls) element.className = cls;
    if (text !== undefined) element.textContent = text;
    return element;
  };
  const initial = () => [
    {id:'agent', app:'Claude', state:'blocked', kind:'permission', message:'Waiting for permission to run tests', tab:'dotfiles', pane:0, location:'dotfiles · configuration', since:Date.now()-42000},
    {id:'build', app:'zig build', state:'working', message:'Compiling Ghostty', progress:64, tab:'ghostty', pane:2, location:'ghostty · build', since:Date.now()-88000},
    {id:'notes', app:'Export notes', state:'done', message:'Exported 12 documents', tab:'notes', pane:0, location:'notes · export', since:Date.now()-15000},
    {id:'shell', app:'Shell', state:'idle', message:'Ready for a command', tab:'ghostty', pane:0, location:'ghostty · shell', since:Date.now()-180000},
  ];
  let records = initial();
  const trigger = node('button','activity-trigger');
  trigger.id='activity-toggle'; trigger.type='button'; trigger.setAttribute('aria-expanded','true'); trigger.setAttribute('aria-controls','activity-panel');
  q('.tools').prepend(trigger);
  const panel = node('aside','activity-panel'); panel.id='activity-panel'; panel.setAttribute('aria-label','Activity in this window');
  const heading=node('div','activity-heading'); heading.append(node('h2',null,'Activity'));
  const close=node('button','activity-close','×'); close.type='button'; close.setAttribute('aria-label','Close activity'); heading.append(close);
  panel.append(heading,node('div','activity-scope','This window · all tabs and panes'));
  const summary=node('div','activity-summary'); panel.append(summary);
  const search=node('input','activity-search'); search.type='search'; search.placeholder='Filter activity…'; search.setAttribute('aria-label','Filter activity'); panel.append(search);
  const list=node('div','activity-list'); panel.append(list);
  const notice=node('div','activity-navigation'); notice.setAttribute('role','status'); panel.append(notice);
  const footer=node('div','activity-footer'); const idleLabel=node('label'); const idle=node('input'); idle.type='checkbox'; idle.id='activity-show-idle'; idleLabel.append(idle,document.createTextNode('Show idle panes')); footer.append(idleLabel,node('div',null,'Sample tasks · no processes are monitored.')); panel.append(footer);
  q('.window').append(panel);
  const demo=node('div','activity-demo'); demo.append(node('span',null,'Activity study'));
  const states=[['working','Resume task'],['blocked','Needs input'],['done','Complete task'],['error','Fail task'],['reset','Reset activity']];
  for (const [state,label] of states) { const button=node('button',null,label); button.type='button'; button.dataset.activityState=state; button.addEventListener('click',()=>transition(state)); demo.append(button); }
  q('.controls').append(demo);
  const symbols={blocked:'!',working:'◌',done:'✓',error:'×',idle:'·'};
  const names={blocked:'Needs attention',working:'Running',done:'Finished',error:'Needs attention',idle:'Idle'};
  function age(since) { const seconds=Math.max(0,Math.floor((Date.now()-since)/1000)); return seconds<60 ? `${seconds}s` : `${Math.floor(seconds/60)}m`; }
  function setOpen(open,focus=false) { panel.hidden=!open; trigger.setAttribute('aria-expanded',String(open)); if(open&&focus)search.focus(); if(!open)trigger.focus(); }
  function attention(tab,active) { document.dispatchEvent(new CustomEvent('draft:activity-attention',{detail:{tab,attention:active}})); }
  function go(record) {
    const tab=document.querySelector(`.tabs .tab[data-id="${record.tab}"] .tab-select`);
    if (!tab) { notice.textContent='That tab is closed in this draft. Reset tabs to reopen it.'; return; }
    tab.click();
    const panes=[...document.querySelectorAll('.pane')];
    const pane=panes[record.pane];
    if(pane) { panes.forEach(item=>item.classList.toggle('active',item===pane)); pane.focus({preventScroll:true}); }
    notice.textContent=`Focused ${record.location}`;
  }
  function render() {
    const urgent=records.filter(record=>record.state==='blocked'||record.state==='error').length;
    const running=records.filter(record=>record.state==='working').length;
    trigger.replaceChildren(node('span',null,'◌'),node('span','activity-word','Activity'),node('span','activity-count',String(urgent||running||'')));
    trigger.setAttribute('aria-label',`Activity: ${urgent} need attention, ${running} running`);
    summary.replaceChildren(node('span',null,`${urgent} need attention`),node('span',null,`${running} running`));
    list.replaceChildren(); const query=search.value.trim().toLocaleLowerCase(); let count=0;
    for (const category of ['Needs attention','Running','Finished','Idle']) {
      const matches=records.filter(record=>names[record.state]===category && (record.state!=='idle'||idle.checked) && `${record.app} ${record.message} ${record.location} ${record.kind||''}`.toLocaleLowerCase().includes(query));
      if(!matches.length)continue;
      const group=node('section','activity-group'); group.append(node('h3',null,category));
      for(const record of matches) {
        const row=node('button','activity-row'); row.type='button'; row.dataset.state=record.state; row.dataset.record=record.id;
        row.setAttribute('aria-label',`${record.app}: ${record.state==='blocked' ? record.kind||'needs input' : record.state}. ${record.message}. Open ${record.location}`);
        row.append(node('span','activity-symbol',symbols[record.state])); const copy=node('span','activity-copy');
        const title=node('span','activity-title'); title.append(node('strong',null,record.app),node('span','activity-time',age(record.since))); copy.append(title,node('span','activity-message',record.message));
        if(record.state==='working' && record.progress!==undefined) {
          const progress=node('span','activity-progress'); progress.setAttribute('role','progressbar'); progress.setAttribute('aria-label',record.app); progress.setAttribute('aria-valuenow',String(record.progress)); progress.setAttribute('aria-valuemin','0'); progress.setAttribute('aria-valuemax','100');
          const fill=node('span'); fill.style.width=`${record.progress}%`; progress.append(fill); copy.append(progress);
        }
        copy.append(node('span','activity-location',`${record.location}${record.state==='blocked' ? ' · '+(record.kind||'input') : ''}`)); row.append(copy); row.addEventListener('click',()=>go(record)); group.append(row); count++;
      }
      list.append(group);
    }
    if(!count)list.append(node('div','activity-empty',query?'No matching activity':'Nothing needs your attention'));
    document.dispatchEvent(new CustomEvent('draft:activity-update',{detail:structuredClone(records)}));
  }
  function transition(state) {
    if(state==='reset') { records=initial(); notice.textContent=''; attention('dotfiles',true); }
    else {
      const record=records.find(item=>item.id==='agent'); const previous=record.state; record.state=state; record.since=Date.now();
      record.message={working:'Applying configuration changes',blocked:'Waiting for permission to run tests',done:'Configuration changes completed',error:'Tests failed · open the pane for details'}[state];
      record.progress=state==='working'?32:undefined;
      if(previous!==state)attention(record.tab,state==='blocked'||state==='error'||state==='done');
    }
    render();
  }
  trigger.addEventListener('click',()=>setOpen(panel.hidden,true)); close.addEventListener('click',()=>setOpen(false));
  search.addEventListener('input',render); idle.addEventListener('change',render);
  panel.addEventListener('keydown',event=>{ if(event.key==='Escape'){event.preventDefault();event.stopPropagation();setOpen(false);} if(event.key==='Enter'&&event.target===search){list.querySelector('.activity-row')?.click();} });
  document.addEventListener('draft:activity-request',render);
  document.addEventListener('draft:activity-focus',event=>{const record=records.find(item=>item.id===event.detail);if(record)go(record);});
  render(); attention('dotfiles',true);
})();
