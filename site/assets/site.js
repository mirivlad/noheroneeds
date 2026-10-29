(function site(){
 "use strict";
 const $=(s,r=document)=>r.querySelector(s);
 const $$=(s,r=document)=>[...r.querySelectorAll(s)];
 const esc=x=>String(x??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
 const clean=x=>String(x??"").toLowerCase().replace(/ё/g,"е");
 const wikiURL=id=>"wiki.html?item="+encodeURIComponent(id);
 const req=p=>fetch(p).then(r=>{if(!r.ok)throw Error("HTTP "+r.status);return r.json()});
 let W=null,R=null;
 const pw=req("data/wiki.json").then(x=>(W=x)).catch(()=>{});
 const pr=req("data/releases.json").then(x=>(R=x)).catch(()=>{});
 function nameOf(id){return W?.items.find(x=>x.id===id)?.name||id.replace(/^base:/,"")}
 const sym=c=>({"Руда":"◇","Металлы":"⬡","Материалы":"✦","Оружие":"⚔","Инструменты":"⚒","Постройки и транспорт":"⌂","Одежда и броня":"♜","Особое":"✧","Еда и хозяйство":"❧","Рецепты":"✜","Жители":"♙"}[c]||"✦");
 function glyph(e){let c=e.category||"Материалы";return '<span class="itemglyph '+(c==="Руда"?"mineral":c==="Оружие"?"weapon":c==="Еда и хозяйство"?"food":"")+'">'+sym(c)+"</span>"}
 function initMenu(){const n=$("#main-nav"),b=$("#menu-toggle");if(n&&b)b.addEventListener("click",()=>{n.classList.toggle("open");b.setAttribute("aria-expanded",String(n.classList.contains("open")))})}
 function initWiki(){
  const items=$('#wiki-items'), side=$('#wiki-categories'), detail=$('#wiki-detail'),input=$('#wiki-search');
  if(!items)return;
  if(!W){items.innerHTML='<p class="nothing">Каталог временно недоступен.</p>';return}
  const categories=["Все знания","Руда","Металлы","Материалы","Оружие","Инструменты","Одежда и броня","Еда и хозяйство","Постройки и транспорт","Особое","Рецепты","Жители"];
  const records=[...W.items.map(x=>({...x,type:"item"})),...W.recipes.map(x=>({...x,type:"recipe",category:"Рецепты"})),...W.professions.map(x=>({...x,type:"npc",category:"Жители"}))];
  const index=new Map(records.map(x=>[x.id,x]));
  let category="Все знания",selected="",query="";
  const link=(id,qty)=>'<a href="'+esc(wikiURL(id))+'" data-item="'+esc(id)+'" class="tiny-link">'+esc(nameOf(id))+(qty?' ×'+esc(qty):"")+"</a>";
  const links=m=>'<div class="ingredient-links">'+Object.entries(m||{}).map(([k,v])=>link(k,v)).join("")+"</div>";
  const li=(parts,none="Нет данных")=>parts.length?'<ul class="detail-list">'+parts.map(p=>"<li>"+p+"</li>").join("")+"</ul>":'<p class="detail-empty">'+esc(none)+"</p>";
  const teacherInfo=c=>Object.entries(c.skill||{}).map(([k,v])=>" · "+esc(W.skills[k]||k)+" от "+v).join("");
  function cats(){
   $$(".side-filter",side).forEach(x=>x.remove());
   for(const c of categories){
    const b=document.createElement("button");b.className="side-filter"+(category===c?" active":"");b.type="button";b.innerHTML="<span>"+esc(c)+"</span><span>"+(c==="Все знания"?records.length:records.filter(x=>x.category===c).length)+"</span>";
    b.addEventListener("click",()=>{category=c;cats();list();detail.classList.remove("open")});side.append(b);
   }
  }
  function list(){
   const found=records.filter(x=>(category==="Все знания"||x.category===category)&&(!query||clean(x.name+" "+x.id).includes(query)));
   $('#catalog-title').textContent=category;
   $('#catalog-count').textContent=found.length+" записей";
   items.innerHTML=found.length?found.map(x=>'<button type="button" class="item-card'+(x.id===selected?" selected":"")+'" data-item="'+esc(x.id)+'" aria-pressed="'+(x.id===selected)+'">'+glyph(x)+'<span style="min-width:0"><strong>'+esc(x.name)+'</strong><small>'+esc(x.category)+'</small></span></button>').join(""):'<div class="nothing">Ничего не найдено</div>';
  }
  function render(e){
   let content="";
   const block=(title,body)=>'<h4>'+esc(title)+'</h4>'+body;
   if(e.type==="item"){
    if(e.source)content+=block("Как получить",li(e.source.where.map(esc))+('<p>'+esc(e.source.note||"")+'</p>'));
    const made=W.recipes.filter(r=>Object.hasOwn(r.outputs,e.id));
    const used=W.recipes.filter(r=>Object.hasOwn(r.inputs,e.id));
    const sellers=W.professions.filter(p=>p.sells.includes(e.id));
    content+=block("Изготавливается по рецептам",li(made.map(r=>'<a href="'+esc(wikiURL(r.id))+'" data-item="'+esc(r.id)+'">'+esc(r.name)+'</a><span class="minor">Выход: '+esc(r.outputs[e.id])+" шт.</span>"),"Рецепт не указан."));
    content+=block("Используется в рецептах",li(used.map(r=>'<a href="'+esc(wikiURL(r.id))+'" data-item="'+esc(r.id)+'">'+esc(r.name)+'</a><span class="minor">Нужно: '+esc(r.inputs[e.id])+" шт.</span>"),"В известных рецептах пока не используется."));
    if(sellers.length)content+=block("Продаётся у",li(sellers.map(x=>'<a data-item="'+esc(x.id)+'" href="'+esc(wikiURL(x.id))+'">'+esc(x.name)+"</a>")));
   }else if(e.type==="recipe"){
    content+=block("Результат",links(e.outputs))+block("Потребуется",links(e.inputs));
    content+=block("Мастерство",li(["Место: "+esc(({forge:"Кузница",workbench:"Верстак",fire:"Костёр"}[e.station]||"Без станка")),"Навык: "+esc(W.skills[e.skill]||e.skill||"—"),"Сложность: "+esc(e.difficulty)]));
    const teachers=W.professions.map(x=>({npc:x,c:x.teaches[e.id]})).filter(x=>x.c);
    content+=block("Как изучить",e.innate?"<p>Известен с самого начала.</p>":li(teachers.map(({npc,c})=>'<a data-item="'+esc(npc.id)+'" href="'+esc(wikiURL(npc.id))+'">'+esc(npc.name)+'</a><span class="minor">Цена: '+c.price+" монет · доверие "+c.standing+teacherInfo(c)+"</span>"),"Учитель не указан. Возможен чертёж."));
   }else{
    content+=block("Обучает",li(Object.entries(e.teaches).map(([id,c])=>'<a data-item="'+esc(id)+'" href="'+esc(wikiURL(id))+'">'+esc(W.recipes.find(r=>r.id===id)?.name||id)+'</a><span class="minor">'+c.price+" монет · доверие "+c.standing+teacherInfo(c)+"</span>"),"Обучение не задано."));
    content+=block("Продаёт",e.sells.length?'<div class="ingredient-links">'+e.sells.map(id=>link(id)).join("")+"</div>":'<p class="detail-empty">Ассортимент меняется в мире.</p>');
    content+=block("Покупает",e.buys.length?'<div class="ingredient-links">'+e.buys.map(id=>link(id)).join("")+"</div>":'<p class="detail-empty">Заранее определённого списка нет.</p>');
   }
   detail.innerHTML='<div class="detail-head"><button id="detail-back" class="back-detail">← Назад к списку</button>'+glyph(e)+'<span class="tag">'+esc(e.category)+'</span><h3>'+esc(e.name)+'</h3><p class="detail-sub"><code>'+esc(e.id)+'</code></p></div><div class="detail-body">'+content+'<p class="guide-note">Данные базового игрового контента v0.16.0. Торговля и доступность зависят от условий игрового мира.</p></div>';
   $('#detail-back').addEventListener("click",()=>detail.classList.remove("open"));detail.scrollTop=0;
  }
  function jump(id){
   const e=index.get(id);if(!e)return;
   selected=id;category="Все знания";cats();list();render(e);detail.classList.add("open");history.replaceState(null,"",wikiURL(id));
  }
  items.addEventListener("click",ev=>{const b=ev.target.closest("[data-item]");if(b)jump(b.dataset.item)});
  detail.addEventListener("click",ev=>{const b=ev.target.closest("a[data-item]");if(b){ev.preventDefault();jump(b.dataset.item)}});
  input.addEventListener("input",ev=>{query=clean(ev.target.value.trim());list()});
  cats();list();const id=new URLSearchParams(location.search).get("item");if(id&&index.has(id)){jump(id);if(innerWidth<1150)detail.classList.remove("open")}else if(records.length)render(records[0]);
 }
 function initGuides(){
  const root=$("#guide-content");if(!root)return;
  const articles=$$(".guide-article",root), toc=$("#guide-toc");
  for(const a of articles){const link=document.createElement("a");link.href="#"+a.id;link.textContent=a.querySelector("h2")?.textContent||a.id;link.addEventListener("click",ev=>{ev.preventDefault();choose(a.id,true);scrollTo({top:0,behavior:"instant"})});toc.append(link)}
  function choose(id,replace){const a=articles.find(x=>x.id===id)||articles[0];if(!a)return;articles.forEach(x=>x.classList.toggle("active",x===a));$$("a",toc).forEach(x=>x.classList.toggle("active",x.hash==="#"+a.id));if(replace)history.replaceState(null,"","#"+a.id);}
  choose(decodeURIComponent(location.hash.slice(1)));addEventListener("hashchange",()=>choose(decodeURIComponent(location.hash.slice(1))));
 }
 function initUpdates(){
  const root=$("#release-list"),nav=$("#release-index");if(!root)return;if(!R){root.innerHTML='<p class="nothing">История временно недоступна.</p>';return}
  nav.innerHTML="<h3>Версии</h3>";
  R.forEach((r,i)=>{
   const id="v"+r.version.replace(/\./g,"-");
   const l=document.createElement("a");l.className="release-index-link";l.href="#"+id;l.innerHTML='<span>v'+esc(r.version)+'</span><span>'+(i===R.length-1?"НОВОЕ":"")+"</span>";nav.append(l);
   const article=document.createElement("article");article.id=id;article.className="release-article"+(i===R.length-1?" latest":"");
   const groups=(r.groups||[]).map(g=>'<section><h3>'+esc(g.title)+'</h3><ul>'+(g.bullets||[]).map(b=>'<li>'+esc(b)+'</li>').join("")+"</ul></section>").join("");
   article.innerHTML='<details '+(i===R.length-1?"open":"")+'><summary><div class="eyebrow">ОБНОВЛЕНИЕ v'+esc(r.version)+(i===R.length-1?'<span class="release-badge">Последний релиз</span>':"")+'</div><h2>'+esc(r.title)+'</h2><div class="rev-date">'+esc(r.date)+'</div><p class="rev-lead">'+esc(r.tagline)+'</p></summary><div class="release-content">'+groups+'<a class="link" target="_blank" rel="noopener noreferrer" href="'+esc(r.url)+'">Посмотреть релиз на GitHub ↗</a></div></details>';
   root.append(article);
  });
  const links=$$(".release-index-link",nav), articles=$$(".release-article",root);
  let selectionLock=0,raf=0;
  function active(i){links.forEach((l,j)=>{l.classList.toggle("active",i===j);if(i===j)l.setAttribute("aria-current","location");else l.removeAttribute("aria-current")})}
  function current(){
   if(innerHeight+scrollY>=document.documentElement.scrollHeight-5)return articles.length-1;
   const y=scrollY+Math.min(190,innerHeight*.3);
   let ix=0;articles.forEach((a,i)=>{if(a.offsetTop<=y)ix=i});return ix;
  }
  links.forEach((l,i)=>l.addEventListener("click",ev=>{
   ev.preventDefault();const a=articles[i];a.querySelector("details").open=true;active(i);selectionLock=Date.now()+1200;
   history.replaceState(null,"","#"+a.id);requestAnimationFrame(()=>a.scrollIntoView({behavior:"smooth",block:"start"}));
  }));
  addEventListener("scroll",()=>{if(raf)return;raf=requestAnimationFrame(()=>{raf=0;if(Date.now()>selectionLock)active(current())})},{passive:true});
  const hash=location.hash.slice(1),idx=articles.findIndex(x=>x.id===hash);
  if(idx>=0){articles[idx].querySelector("details").open=true;setTimeout(()=>{articles[idx].scrollIntoView();active(idx)},100)}else active(current());
 }
 async function initSearch(){
  const modal=$("#search-dialog"),box=$("#global-search"),out=$("#global-results");if(!modal)return;
  await Promise.allSettled([pw,pr]);
  function render(){
   const q=clean(box.value.trim());let arr=[];
   if(W)arr.push(...W.items.map(x=>({name:x.name,tag:x.category,url:wikiURL(x.id)})),...W.recipes.map(x=>({name:x.name,tag:"Рецепт",url:wikiURL(x.id)})),...W.professions.map(x=>({name:x.name,tag:"Житель",url:wikiURL(x.id)})));
   const guide=$$(".guide-article").map(a=>({name:a.querySelector("h2")?.textContent||a.id,tag:"Руководство",url:"guides.html#"+a.id}));
   if(guide.length===0)guide.push(...[{id:"start",name:"Первые шаги"},{id:"mining",name:"Добыча руды"},{id:"craft",name:"Ремёсла"},{id:"caravans",name:"Караваны и разбойники"}].map(a=>({name:a.name,tag:"Руководство",url:"guides.html#"+a.id})));
   arr.push(...guide,...(R||[]).map(r=>({name:"v"+r.version+" — "+r.title,tag:"Обновление",url:"updates.html#v"+r.version.replace(/\./g,"-")})));
   const chosen=(q?arr.filter(x=>clean(x.name+" "+x.tag).includes(q)):guide).slice(0,18);
   out.innerHTML=chosen.length?chosen.map(x=>'<a class="search-result" href="'+esc(x.url)+'"><strong>'+esc(x.name)+'</strong><small>'+esc(x.tag)+'</small></a>').join(""):'<p class="nothing">Ничего не найдено.</p>';
  }
  function open(){modal.classList.add("open");box.value="";render();box.focus()}
  function close(){modal.classList.remove("open")}
  $("#open-search")?.addEventListener("click",open);$("#search-close")?.addEventListener("click",close);
  modal.addEventListener("click",ev=>{if(ev.target===modal)close()});
  addEventListener("keydown",ev=>{if((ev.ctrlKey||ev.metaKey)&&ev.key.toLowerCase()==="k"){ev.preventDefault();open()}if(ev.key==="Escape")close()});
  box.addEventListener("input",render);
 }
 initMenu();
 if($("#wiki-items"))pw.then(initWiki);
 if($("#release-list"))pr.then(initUpdates);
 if($("#guide-content"))initGuides();
 initSearch();
})();
