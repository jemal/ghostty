(() => {
  const q=selector=>document.querySelector(selector);
  const element=(tag,cls,text)=>{const node=document.createElement(tag);if(cls)node.className=cls;if(text!==undefined)node.textContent=text;return node;};
  const win=q('.window'), topbar=q('.topbar'), session=q('.session'), originalTabs=q('.tabs');
  const rail=element('nav','vertical-rail'); rail.setAttribute('aria-label','Tabs and activity');
  const sessionHome=document.createComment('session home');session.before(sessionHome);
  const heading=element('div','vertical-heading');heading.append(element('span',null,'WORKSPACE'));
  const actions=element('div','vertical-actions'); const add=element('button','vertical-new','+');add.type='button';add.setAttribute('aria-label','New tab');
  const collapse=element('button',null,'‹');collapse.type='button';collapse.id='collapse-rail';collapse.setAttribute('aria-label','Collapse tab rail');collapse.setAttribute('aria-expanded','true');
  actions.append(add,collapse);heading.append(actions); const items=element('div','vertical-items');
  rail.append(heading,items);win.prepend(rail);
  const context=element('div','vertical-context');const expand=element('button','vertical-expand','☷');expand.type='button';expand.setAttribute('aria-label','Toggle tab rail');const title=element('span');context.append(expand,title);topbar.prepend(context);
  const label=element('label',null,'Tab layout');const layout=element('select');layout.id='tab-layout';layout.append(new Option('Vertical · activity rail','vertical'),new Option('Horizontal · activity panel','horizontal'));label.append(layout);q('.controls').prepend(label);
  let records=[], enabled=true, collapsed=false;
  const rank={error:0,blocked:1,working:2,done:3,idle:4}; const symbols={error:'×',blocked:'!',working:'◌',done:'✓',idle:'·'};
  function select(id){originalTabs.querySelector(`[data-id="${id}"] .tab-select`)?.click();}
  function render(){
    const focus=document.activeElement?.dataset.railFocus;
    items.replaceChildren();
    for(const source of originalTabs.querySelectorAll('.tab')){
      const id=source.dataset.id,name=source.querySelector('.tab-label').textContent,selected=source.classList.contains('selected');
      const tasks=records.filter(record=>record.tab===id).sort((a,b)=>rank[a.state]-rank[b.state]);
      const status=tasks[0]?.state||'idle';const group=element('div','vertical-group');const row=element('div','vertical-tab');row.dataset.id=id;row.classList.toggle('selected',selected);
      const button=element('button','vertical-select');button.type='button';button.dataset.railFocus=id;button.title=[name,...tasks.map(task=>`${task.app}: ${task.message}${task.state==='working'&&task.progress!==undefined?' · '+task.progress+'%':''}`)].join('\n');button.setAttribute('aria-current',selected?'page':'false');button.setAttribute('aria-label',`${name}: ${status}`);
      const symbol=element('span','vertical-symbol',symbols[status]);symbol.dataset.state=status;symbol.setAttribute('aria-hidden','true');button.append(symbol,element('span','vertical-title',name));button.addEventListener('click',()=>select(id));
      button.addEventListener('keydown',event=>{if(!['ArrowUp','ArrowDown','Home','End'].includes(event.key))return;event.preventDefault();const buttons=[...items.querySelectorAll('.vertical-select')];const index=buttons.indexOf(button);const target=event.key==='Home'?0:event.key==='End'?buttons.length-1:(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;buttons[target].focus();buttons[target].click();});
      const close=element('button','vertical-close','×');close.type='button';close.setAttribute('aria-label',`Close ${name}`);close.addEventListener('click',()=>source.querySelector('.close')?.click());row.append(button,close);group.append(row);
      items.append(group);if(selected)title.textContent=name;
    }
    if(focus)items.querySelector(`[data-rail-focus="${focus}"]`)?.focus({preventScroll:true});
  }
  function setCollapsed(value){collapsed=value;win.classList.toggle('rail-collapsed',value);collapse.textContent=value?'›':'‹';collapse.setAttribute('aria-expanded',String(!value));collapse.setAttribute('aria-label',value?'Expand tab rail':'Collapse tab rail');}
  function apply(){enabled=layout.value==='vertical';q('.tag').textContent=enabled?'Draft 04 / quiet vertical tabs':'Draft 04 / horizontal tabs';win.classList.toggle('vertical-layout',enabled);rail.hidden=!enabled;context.hidden=!enabled;if(enabled){rail.prepend(session);if(!q('#activity-panel').hidden)q('.activity-close').click();}else{sessionHome.after(session);}win.classList.toggle('rail-collapsed',enabled&&collapsed);render();}
  layout.addEventListener('change',apply);collapse.addEventListener('click',()=>setCollapsed(!collapsed));expand.addEventListener('click',()=>setCollapsed(!collapsed));add.addEventListener('click',()=>q('#add-tab').click());
  document.addEventListener('draft:activity-update',event=>{records=event.detail;render();});
  document.addEventListener('draft:activity-attention',event=>{if(!enabled||!event.detail.attention)return;requestAnimationFrame(()=>{const row=items.querySelector(`.vertical-tab[data-id="${event.detail.tab}"]`);if(!row||row.classList.contains('selected'))return;row.classList.add('attention-pulse');setTimeout(()=>row.classList.remove('attention-pulse'),1200);});});
  new MutationObserver(render).observe(originalTabs,{childList:true,subtree:true,attributes:true,attributeFilter:['class','aria-selected']});
  q('#activity-toggle').title='Activity';
  document.dispatchEvent(new Event('draft:activity-request'));apply();
})();
