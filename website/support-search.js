/* ============================================================================
   VectorLabel support docs — shared smart search (guide.html + faq.html).
   Plain JS, no dependencies, loaded with <script defer>.
   Each page provides a config BEFORE this script via window.VL_SEARCH:
     guide: {mode:'guide', input:'#guideq'} — ranked dropdown over .doc-sec
     faq:   {mode:'faq',   input:'#faqq'}   — filter + auto-open + highlight
   ============================================================================ */
(function(){
"use strict";
var cfg=window.VL_SEARCH;if(!cfg)return;
var input=document.querySelector(cfg.input);if(!input)return;

/* ---------- text helpers ---------- */
function toks(s){return (s||'').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);}
function rxEsc(w){return w.replace(/[.*+?^${}()|[\]\\]/g,'\\$&');}
// Matches any whole word that STARTS with a query word ("casset" hits "cassette").
function wordRx(ws){return new RegExp('(^|[^A-Za-z0-9])((?:'+ws.map(rxEsc).join('|')+')[A-Za-z0-9]*)','gi');}
function debounce(fn,ms){var t;return function(){clearTimeout(t);t=setTimeout(fn,ms);};}

/* ---------- scoring ---------- */
// Prefix-match stats for one query word over a token list: count + first index.
function stat(list,w){var c=0,f=-1,i;for(i=0;i<list.length;i++){if(list[i].lastIndexOf(w,0)===0){c++;if(f<0)f=i;}}return{c:c,f:f};}
// Every query word must match somewhere (else -1). Heading matches score far
// above chapter/body; more and earlier body occurrences break ties.
function score(it,ws){
  var s=0,i,h,c,b;
  for(i=0;i<ws.length;i++){
    h=stat(it.ht,ws[i]);c=stat(it.ct,ws[i]);b=stat(it.bt,ws[i]);
    if(!h.c&&!c.c&&!b.c)return -1;
    if(h.c)s+=100-Math.min(h.f,20)*2;
    else if(c.c)s+=40;
    if(b.c)s+=Math.min(b.c,8)*4+Math.max(0,12-Math.floor(b.f/25));
  }
  return s;
}

/* ---------- <mark> highlighting (cleanly reversible, never nests) ---------- */
function unmark(root){
  [].slice.call(root.querySelectorAll('mark.vl-mark')).forEach(function(m){
    var p=m.parentNode;p.replaceChild(document.createTextNode(m.textContent),m);p.normalize();
  });
}
function markUp(root,rx){
  var w=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,null),n,nodes=[];
  while((n=w.nextNode()))nodes.push(n);
  nodes.forEach(function(node){
    var t=node.nodeValue,m,ranges=[];rx.lastIndex=0;
    while((m=rx.exec(t)))ranges.push([m.index+m[1].length,m.index+m[1].length+m[2].length]);
    if(!ranges.length)return;
    var frag=document.createDocumentFragment(),pos=0;
    ranges.forEach(function(r){
      if(r[0]>pos)frag.appendChild(document.createTextNode(t.slice(pos,r[0])));
      var mk=document.createElement('mark');mk.className='vl-mark';mk.textContent=t.slice(r[0],r[1]);
      frag.appendChild(mk);pos=r[1];
    });
    if(pos<t.length)frag.appendChild(document.createTextNode(t.slice(pos)));
    node.parentNode.replaceChild(frag,node);
  });
}
// "…window around the first match…" of a section body, matches marked.
function snippet(text,rx){
  rx.lastIndex=0;var m=rx.exec(text),at=m?m.index:0,start=Math.max(0,at-50);
  var d=document.createElement('div');d.className='r-snip';
  d.textContent=(start>0?'…':'')+text.slice(start,at+130)+(at+130<text.length?'…':'');
  markUp(d,rx);return d;
}
// Brief outline flash on the section we just jumped to.
function flash(el){
  el.classList.remove('vl-flash','vl-flash-fade');
  void el.offsetWidth;
  el.classList.add('vl-flash');
  setTimeout(function(){el.classList.add('vl-flash-fade');},900);
  setTimeout(function(){el.classList.remove('vl-flash','vl-flash-fade');},1800);
}

/* ---------- guide: ranked dropdown over the .doc-sec sections ---------- */
function initGuide(){
  // Index: one record per section — h2 heading, containing chapter, body text.
  var index=[],chap='';
  [].slice.call(document.querySelectorAll('.article > *')).forEach(function(el){
    if(el.classList.contains('chapter')){chap=el.textContent.trim();return;}
    if(el.tagName!=='SECTION'||!el.classList.contains('doc-sec')||!el.id)return;
    var h=el.querySelector('h2'),title=h?h.textContent.trim():el.id,body='';
    [].slice.call(el.children).forEach(function(ch){if(ch!==h)body+=ch.textContent+' ';});
    body=body.replace(/\s+/g,' ').trim();
    index.push({el:el,id:el.id,title:title,chap:chap,body:body,ht:toks(title),ct:toks(chap),bt:toks(body)});
  });

  var box=input.closest('.faq-search')||input.parentNode;
  var drop=document.createElement('div');drop.className='vl-results';box.appendChild(drop);
  var shown=[],sel=-1;

  function close(){drop.classList.remove('open');drop.innerHTML='';shown=[];sel=-1;}
  function go(it){
    close();
    if(location.hash==='#'+it.id)it.el.scrollIntoView({behavior:'smooth'});
    else location.hash=it.id; // plain anchor semantics — deep links keep working
    flash(it.el);
  }
  function render(){
    var ws=toks(input.value);
    close();
    if(!ws.length)return;
    var rx=wordRx(ws),hits=[];
    index.forEach(function(it){var s=score(it,ws);if(s>=0)hits.push([s,it]);});
    hits.sort(function(a,b){return b[0]-a[0];});
    hits.slice(0,10).forEach(function(hit){
      var it=hit[1],a=document.createElement('a');a.href='#'+it.id;
      var c=document.createElement('div');c.className='r-chap';c.textContent=it.chap;
      var t=document.createElement('div');t.className='r-title';t.textContent=it.title;markUp(t,rx);
      a.appendChild(c);a.appendChild(t);a.appendChild(snippet(it.body,rx));
      a.addEventListener('click',function(e){e.preventDefault();go(it);});
      drop.appendChild(a);shown.push(it);
    });
    if(!shown.length){var d=document.createElement('div');d.className='r-none';d.textContent='No matching sections.';drop.appendChild(d);}
    drop.classList.add('open');
  }

  var run=debounce(render,120);
  input.addEventListener('input',run);
  input.addEventListener('search',run); // fired by the native ✕ / Esc clear
  input.addEventListener('focus',function(){if(toks(input.value).length)render();});
  input.addEventListener('keydown',function(e){
    if(e.key==='Escape'){close();return;}
    if(e.key==='Enter'){if(shown.length){e.preventDefault();go(shown[sel<0?0:sel]);}return;}
    if((e.key!=='ArrowDown'&&e.key!=='ArrowUp')||!shown.length)return;
    e.preventDefault();
    sel=(sel+(e.key==='ArrowDown'?1:-1)+shown.length)%shown.length;
    [].slice.call(drop.children).forEach(function(el,i){el.classList.toggle('sel',i===sel);});
    if(drop.children[sel].scrollIntoView)drop.children[sel].scrollIntoView({block:'nearest'});
  });
  document.addEventListener('click',function(e){if(!box.contains(e.target))close();});
}

/* ---------- faq: filter in place, auto-open + highlight matches ---------- */
function initFaq(){
  var list=document.getElementById('faqList'),empty=document.getElementById('faqEmpty');
  // Index live DOM text (summary + answer), not the stale-able data-text attr.
  var items=[].slice.call(list.querySelectorAll('details.faq')).map(function(d){
    var sum=d.querySelector('summary'),body=d.querySelector('.faq-body');
    return {el:d,ht:toks(sum?sum.textContent:''),ct:[],bt:toks(body?body.textContent:'')};
  });
  var cats=[].slice.call(list.querySelectorAll('.faq-cat'));
  var count=document.createElement('p');count.className='faq-count';
  count.setAttribute('aria-live','polite');count.style.display='none';
  empty.parentNode.insertBefore(count,empty);

  function run(){
    var ws=toks(input.value),rx=ws.length?wordRx(ws):null,n=0;
    unmark(list);
    items.forEach(function(it){
      var hit=!!ws.length&&score(it,ws)>=0;
      it.el.style.display=(!ws.length||hit)?'':'none'; // document order kept
      it.el.open=hit; // matches auto-open; empty query restores closed
      if(hit){n++;markUp(it.el,rx);}
    });
    cats.forEach(function(c){ // hide category headings with no visible questions
      var el=c.nextElementSibling,show=false;
      while(el&&el.classList.contains('faq')){if(el.style.display!=='none'){show=true;break;}el=el.nextElementSibling;}
      c.style.display=show?'':'none';
    });
    empty.style.display=(ws.length&&!n)?'block':'none';
    count.style.display=(ws.length&&n)?'':'none';
    count.textContent=(n===1?'1 result':n+' results');
  }
  var run120=debounce(run,120);
  input.addEventListener('input',run120);
  input.addEventListener('search',run120);
}

if(cfg.mode==='faq')initFaq();else initGuide();
})();
