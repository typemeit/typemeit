"""Local web page for `review --set <name> --html`. Stdlib only, bound to 127.0.0.1, inline assets:
the audio and transcripts never leave this machine. Answers go to the same <name>-answers.jsonl the
terminal review writes, so the two are interchangeable."""
import contextlib, http.server, io, json, os, pathlib, re, shutil, socketserver, subprocess, tempfile, threading, time, webbrowser

# r: the words were said; m: said, but with or without them the meaning is the same; w: someone spoke
# there, but not those words; h: nothing was said.
ANSWERS = ('r', 'm', 'w', 'h')
NOTE_MAX = 2000
BODY_MAX = 16 * 1024
LOOPBACK = '127.0.0.1'

# A pick item asks which of its readings was said: choice is the reading's index, NONE_OF_THESE for none.
PICK = 'pick'
NONE_OF_THESE = -1
# A who item asks whose voice its words are: choice is the index of the voice sample.
WHO = 'who'
WHO_VOICES = 2
# The words alone, played after the voice samples, with this much either side.
TIGHT_PAD_S = 0.2

def answer_line(item, payload, now=None):
    """The jsonl record for one answer, or None when the payload is not a valid answer for this item."""
    answer = payload.get('answer') if isinstance(payload, dict) else None
    if item.get('who'):
        choice = payload.get('choice') if answer == WHO else None
        if not isinstance(choice, int) or isinstance(choice, bool) or not NONE_OF_THESE <= choice < WHO_VOICES:
            return None
    elif item.get('pick'):
        choice = payload.get('choice') if answer == PICK else None
        if not isinstance(choice, int) or isinstance(choice, bool) or not NONE_OF_THESE <= choice < len(item['readings']):
            return None
    elif answer not in ANSWERS:
        return None
    line = {'key': item['key'], 'clip': item['clip'], 'answer': answer, 'at': int(now if now is not None else time.time())}
    if item.get('pick') or item.get('who'):
        line['choice'] = choice
    note = payload.get('note')
    if isinstance(note, str) and note.strip():
        line['note'] = note.strip()[:NOTE_MAX]
    return line

def append_answer(path, line):
    with open(path, 'a') as f:
        f.write(json.dumps(line) + '\n')

def cut_window(item, context_s, max_play_s):
    """Start and length in seconds of the clip, and the disputed stretch's offset and length inside it."""
    gap_start = item['gapStartMs'] / 1000
    gap_s = (item['gapEndMs'] - item['gapStartMs']) / 1000
    begin = max(0.0, gap_start - context_s)
    length = min(gap_s + 2 * context_s, max_play_s)
    return {'begin': begin, 'length': length, 'gapOffset': gap_start - begin, 'gapLength': min(gap_s, max(0.0, length - (gap_start - begin)))}

def part_window(item, part, context_s, max_play_s):
    """Start and length in seconds of one of a who item's sounds: `tight` (its words alone),
    `voice0` or `voice1` (a sample of each voice), or else the window with context."""
    if part == 'tight':
        begin = max(0.0, item['gapStartMs'] / 1000 - TIGHT_PAD_S)
        return begin, min(item['gapEndMs'] / 1000 + TIGHT_PAD_S - begin, max_play_s)
    if part in ('voice0', 'voice1'):
        sample = item['samples'][int(part[-1])]
        return sample['startMs'] / 1000, (sample['endMs'] - sample['startMs']) / 1000
    window = cut_window(item, context_s, max_play_s)
    return window['begin'], window['length']

def default_readings(item):
    middle = ' '.join(item['words'])
    return item.get('readings') or [
        {'system': 'AssemblyAI', 'before': item['before'], 'text': '', 'after': item['after']},
        {'system': 'Parakeet', 'before': item['before'], 'text': '', 'after': item['after']},
        {'system': 'Ultra', 'before': item['before'], 'text': middle, 'after': item['after']}]

def make_handler(state):
    host_ok = re.compile(r'^(127\.0\.0\.1|localhost)(:%d)?$' % state['port'])

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send(self, code, body, kind, extra=None):
            data = body if isinstance(body, bytes) else body.encode()
            self.send_response(code)
            self.send_header('Content-Type', kind)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(data)

        def allowed(self):
            if not host_ok.match(self.headers.get('Host', '')):
                self.send(403, 'bad host', 'text/plain')
                return False
            origin = self.headers.get('Origin')
            if origin and not re.match(r'^http://(127\.0\.0\.1|localhost):%d$' % state['port'], origin):
                self.send(403, 'bad origin', 'text/plain')
                return False
            return True

        def do_GET(self):
            if not self.allowed():
                return
            path = self.path.split('?')[0]
            if path == '/':
                return self.send(200, PAGE, 'text/html; charset=utf-8')
            if path == '/api/state':
                return self.send(200, json.dumps(state['describe']()), 'application/json')
            if path == '/api/summary':
                return self.send(200, json.dumps({'text': state['summary']()}), 'application/json')
            found = re.match(r'^/clip/(\d+)(?:/(tight|voice0|voice1))?\.wav$', path)
            if found and int(found.group(1)) < len(state['items']) and (not found.group(2) or state['items'][int(found.group(1))].get('who')):
                return self.serve_clip(int(found.group(1)), found.group(2) or 'window')
            self.send(404, 'not found', 'text/plain')

        def serve_clip(self, index, part):
            try:
                data = pathlib.Path(state['cut'](index, part)).read_bytes()
            except (subprocess.CalledProcessError, OSError):
                return self.send(500, 'cut failed', 'text/plain')
            span = re.match(r'bytes=(\d*)-(\d*)$', self.headers.get('Range', ''))
            if span and (span.group(1) or span.group(2)):
                first = int(span.group(1)) if span.group(1) else max(0, len(data) - int(span.group(2)))
                last = min(int(span.group(2)), len(data) - 1) if span.group(1) and span.group(2) else len(data) - 1
                if first > last:
                    return self.send(416, '', 'text/plain', {'Content-Range': f'bytes */{len(data)}'})
                return self.send(206, data[first:last + 1], 'audio/wav', {'Content-Range': f'bytes {first}-{last}/{len(data)}', 'Accept-Ranges': 'bytes'})
            self.send(200, data, 'audio/wav', {'Accept-Ranges': 'bytes'})

        def do_POST(self):
            if not self.allowed():
                return
            if self.path != '/api/answer':
                return self.send(404, 'not found', 'text/plain')
            size = int(self.headers.get('Content-Length') or 0)
            if size > BODY_MAX:
                return self.send(413, 'too large', 'text/plain')
            try:
                payload = json.loads(self.rfile.read(size))
            except ValueError:
                return self.send(400, 'bad json', 'text/plain')
            item = state['by_key'].get(payload.get('key')) if isinstance(payload, dict) else None
            line = item and answer_line(item, payload)
            if not line:
                return self.send(400, 'bad answer', 'text/plain')
            with state['lock']:
                append_answer(state['answers_path'], line)
            self.send(200, json.dumps(line), 'application/json')

    return Handler

def serve(name, items, clip_file, answers_path, latest_answers, summary, context_s, max_play_s, open_browser=True, announce=print):
    tmp = tempfile.mkdtemp(prefix='asr-review-')
    lock = threading.Lock()
    cuts = {}

    def cut(index, part):
        with lock:
            if (index, part) in cuts:
                return cuts[(index, part)]
        begin, length = part_window(items[index], part, context_s, max_play_s)
        target = os.path.join(tmp, f'{index}-{part}.wav')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f"{begin:.2f}", '-t', f"{length:.2f}",
                        '-i', clip_file(items[index]), '-ac', '1', '-ar', '16000', target], check=True)
        with lock:
            cuts[(index, part)] = target
        return target

    def describe():
        answered = latest_answers()
        return {'name': name, 'items': [{
            'key': i['key'], 'clip': i['clip'], 'readings': [] if i.get('who') else default_readings(i),
            'window': cut_window(i, context_s, max_play_s), 'pick': bool(i.get('pick')), 'who': bool(i.get('who')), 'choice': answered.get(i['key'], {}).get('choice'),
            'answer': answered.get(i['key'], {}).get('answer'), 'note': answered.get(i['key'], {}).get('note', '')} for i in items]}

    state = {'items': items, 'by_key': {i['key']: i for i in items}, 'cut': cut, 'describe': describe, 'summary': summary,
             'lock': lock, 'answers_path': answers_path, 'port': 0}
    server = socketserver.ThreadingTCPServer((LOOPBACK, 0), lambda *a: make_handler(state)(*a))
    server.daemon_threads = True
    state['port'] = server.server_address[1]
    url = f"http://{LOOPBACK}:{state['port']}/"
    announce(f'{name}: {len(items)} spans at {url} (Ctrl-C to stop)')
    if open_browser:
        subprocess.run(['open', url])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        shutil.rmtree(tmp, ignore_errors=True)

PAGE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Listen review</title>
<style>
:root{color-scheme:light dark;--bg:#f6f5f2;--card:#fff;--ink:#1d1d1b;--dim:#6b6a65;--line:#dedcd5;--accent:#2f6f5e;--hl:#fde7a6;--hlink:#5a4300;--real:#2f6f5e;--wrong:#8a6100;--fake:#9a3b2e}
@media(prefers-color-scheme:dark){:root{--bg:#161615;--card:#201f1e;--ink:#ecebe6;--dim:#9a9890;--line:#383735;--accent:#6bbfa6;--hl:#5a4a14;--hlink:#ffe9a8;--real:#6bbfa6;--wrong:#e2b65c;--fake:#e08a7c}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,system-ui,sans-serif}
main{max-width:760px;margin:0 auto;padding:24px 16px 48px}
header{display:flex;justify-content:space-between;align-items:baseline;color:var(--dim);font-size:14px;margin-bottom:12px}
.bar{height:4px;background:var(--line);border-radius:2px;margin-bottom:20px}.bar i{display:block;height:100%;background:var(--accent);border-radius:2px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:24px}
.timeline{position:relative;height:28px;background:var(--line);border-radius:6px;overflow:hidden;margin:0 0 6px}
.timeline .gap{position:absolute;top:0;bottom:0;background:var(--hl);min-width:3px}
.timeline .head{position:absolute;top:0;bottom:0;width:2px;background:var(--ink)}
.ticks{display:flex;justify-content:space-between;font-size:12px;color:var(--dim);margin-bottom:20px}
.reading{display:grid;grid-template-columns:110px 1fr;gap:12px;padding:10px 0;border-top:1px solid var(--line);font-size:17px}
.reading:first-of-type{border-top:0}.reading b{font-weight:500;color:var(--dim);font-size:14px;padding-top:2px}
mark{background:var(--hl);color:var(--hlink);padding:0 3px;border-radius:3px}.empty{color:var(--dim);font-style:italic}
.gapmark{display:inline-block;min-width:24px;border-bottom:2px solid var(--hl)}
.buttons{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin:24px 0 12px}
button{font:inherit;border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:10px;padding:12px 16px;cursor:pointer}
button:hover{border-color:var(--dim)}button:focus-visible,textarea:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.big{font-size:20px;padding:22px 16px}.big.real{border-color:var(--real)}.big.wrong{border-color:var(--wrong)}.big.fake{border-color:var(--fake)}
.big.picked.real{background:var(--real);color:var(--bg)}.big.minor{border-color:var(--real);border-style:dashed}.big.picked.minor{background:var(--real);color:var(--bg)}.big.picked.wrong{background:var(--wrong);color:var(--bg)}.big.picked.fake{background:var(--fake);color:var(--bg)}
kbd{font:12px ui-monospace,monospace;border:1px solid var(--line);border-radius:4px;padding:1px 5px;margin-left:6px;color:var(--dim)}
.picked kbd{color:inherit}
.row{display:flex;gap:12px;flex-wrap:wrap}.row button{flex:1}
.picks{display:grid;gap:10px;margin:24px 0 12px}.picks button{text-align:left;font-size:18px;padding:16px}
.picks button.picked{background:var(--real);color:var(--bg);border-color:var(--real)}.picks button.picked mark{background:transparent;color:inherit}
.steps{display:grid;gap:10px}.steps button{text-align:left;font-size:18px;padding:16px}.steps button b{color:var(--dim);font-weight:500;margin-right:8px}
.steps button.playing{border-color:var(--accent);box-shadow:inset 4px 0 0 var(--accent)}
.ask{margin:20px 0 8px;color:var(--dim);font-size:14px}
.quiet{border:0;background:transparent;color:var(--dim);font-size:14px;padding:8px 0;text-align:left;text-decoration:underline}
textarea{width:100%;margin-top:16px;font:inherit;background:var(--bg);color:var(--ink);border:1px solid var(--line);border-radius:8px;padding:8px 10px;resize:vertical}
.status{color:var(--dim);font-size:14px;margin-top:12px;min-height:21px}
pre{white-space:pre-wrap;font:14px/1.5 ui-monospace,monospace}
#start{position:fixed;inset:0;background:var(--bg);display:flex;align-items:center;justify-content:center;flex-direction:column;gap:12px;z-index:2}
[hidden]{display:none!important}
</style></head><body>
<div id="start"><button class="big" id="startbtn">Start listening</button><span class="status">Any key works too</span></div>
<main>
<header><span id="pos"></span><span id="clipname"></span></header>
<div class="bar"><i id="fill" style="width:0"></i></div>
<section class="card" id="card">
<div class="timeline" id="timeline"><div class="gap" id="gap"></div><div class="head" id="head"></div></div>
<div class="ticks"><span id="t0"></span><span>disputed stretch highlighted</span><span id="t1"></span></div>
<div id="readings"></div>
<div class="buttons">
<button class="big real" id="bR">Real speech<kbd>R</kbd></button>
<button class="big minor" id="bM">Said, doesn't matter<kbd>M</kbd></button>
<button class="big wrong" id="bW">Speech, wrong words<kbd>W</kbd></button>
<button class="big fake" id="bH">Made up<kbd>H</kbd></button></div>
<div class="picks" id="picks" hidden></div>
<div id="whopanel" hidden>
<div class="steps"><button data-part="voice0"><b>1.</b>person A</button><button data-part="voice1"><b>2.</b>person B</button><button data-part="tight"><b>3.</b>who is this?</button></div>
<button class="quiet" data-part="window">hard to tell? hear 3 with a few seconds either side</button>
<p class="ask">3 is:</p>
<div class="picks" id="whopicks" style="margin-top:0"><button data-i="0"><kbd>1</kbd> person A</button><button data-i="1"><kbd>2</kbd> person B</button><button data-i="-1"><kbd>0</kbd> someone else / can't tell</button></div>
</div>
<div class="row"><button id="bB">Back<kbd>&larr;</kbd></button><button id="bP">Replay<kbd>Space</kbd></button><button id="bS">Skip<kbd>S</kbd></button></div>
<textarea id="note" rows="2" placeholder="Note (N)"></textarea>
<div class="status" id="status"></div>
</section>
<section class="card" id="done" hidden><h2 style="margin-top:0">Done</h2><pre id="summary"></pre>
<div class="row"><button id="bFirst">Back to first unanswered</button></div></section>
</main>
<audio id="audio" preload="auto"></audio>
<script>
const $=id=>document.getElementById(id);
let items=[],idx=0,started=false,queue=[];
const WHO_NAMES={'0':'person A','1':'person B','-1':'someone else / can\'t tell'};
const audio=$('audio');
function esc(s){return s.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]))}
function firstOpen(){const i=items.findIndex(x=>!x.answer);return i<0?items.length:i}
function nextOpen(){for(let i=idx+1;i<items.length;i++)if(!items[i].answer)return i;return firstOpen()}
function reading(r){
  const mid=r.text?'<mark>'+esc(r.text)+'</mark>':'<span class="gapmark"></span>';
  return '<div class="reading"><b>'+esc(r.system)+'</b><div>'+esc(r.before)+' '+mid+' '+esc(r.after)+(r.text?'':' <span class="empty">(nothing there)</span>')+'</div></div>';
}
function show(){
  if(idx>=items.length){return finish()}
  $('done').hidden=true;$('card').hidden=false;
  const it=items[idx],w=it.window;
  $('pos').textContent=items.filter(x=>x.answer).length+' done, '+items.filter(x=>!x.answer).length+' to go';$('clipname').textContent=it.clip;
  $('fill').style.width=(100*items.filter(x=>x.answer).length/items.length)+'%';
  $('readings').innerHTML=it.pick||it.who?'':it.readings.map(reading).join('');
  document.querySelector('.buttons').hidden=it.pick||it.who;$('picks').hidden=!it.pick;$('whopanel').hidden=!it.who;
  $('timeline').hidden=it.who;document.querySelector('.ticks').hidden=it.who;
  $('whopicks').querySelectorAll('button').forEach(b=>b.classList.toggle('picked',it.who&&it.choice===+b.dataset.i));
  if(it.pick){
    $('picks').innerHTML=it.readings.map((r,i)=>'<button data-i="'+i+'"'+(it.choice===i?' class="picked"':'')+'><kbd>'+(i+1)+'</kbd> '+esc(r.before)+' '+(r.text?'<mark>'+esc(r.text)+'</mark>':'<span class="empty">(nothing there)</span>')+' '+esc(r.after)+'</button>').join('')
      +'<button data-i="-1"'+(it.choice===-1?' class="picked"':'')+'><kbd>0</kbd> None of these</button>';
    $('picks').querySelectorAll('button').forEach(b=>b.onclick=()=>pick(+b.dataset.i));
  }
  $('gap').style.left=(100*w.gapOffset/w.length)+'%';$('gap').style.width=(100*w.gapLength/w.length)+'%';
  $('t0').textContent='0.0 s';$('t1').textContent=w.length.toFixed(1)+' s';
  $('bR').classList.toggle('picked',it.answer==='r');$('bM').classList.toggle('picked',it.answer==='m');$('bW').classList.toggle('picked',it.answer==='w');$('bH').classList.toggle('picked',it.answer==='h');
  $('note').value=it.note||'';
  $('status').textContent=!it.answer?'':it.who?'Picked '+WHO_NAMES[it.choice]+'. Pick again to change.':it.pick?'Picked '+(it.choice<0?'none of these':(it.choice+1))+'. Pick again to change.':'Answered: '+{r:'real speech',m:'said, doesn\'t matter',w:'speech, wrong words',h:'made up'}[it.answer]+'. Pick again to change.';
  play();
}
function play(){
  if(!started)return;
  if(items[idx]&&items[idx].who){queue=['voice0','voice1','tight'];return next()}
  playPart('window');
}
function playPart(part){
  audio.src='/clip/'+idx+(part==='window'?'':'/'+part)+'.wav';audio.currentTime=0;
  document.querySelectorAll('.steps button').forEach(b=>b.classList.toggle('playing',b.dataset.part===part));
  audio.play().catch(()=>{$('status').textContent='Press Space to play'});
}
function next(){if(queue.length)playPart(queue.shift())}
audio.addEventListener('ended',()=>{document.querySelectorAll('.steps button').forEach(b=>b.classList.remove('playing'));next()});
audio.addEventListener('timeupdate',()=>{const w=items[idx]&&items[idx].window;if(w&&audio.duration)$('head').style.left=(100*audio.currentTime/audio.duration)+'%'});
async function answer(a){
  const it=items[idx];if(!it)return;
  const body={key:it.key,answer:a,note:$('note').value};
  const res=await fetch('/api/answer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  if(!res.ok){$('status').textContent='Save failed ('+res.status+')';return}
  it.answer=a;it.note=$('note').value;idx=nextOpen();show();
}
async function pick(i){
  const it=items[idx];if(!it||!it.pick||i>=it.readings.length)return;
  const res=await fetch('/api/answer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:it.key,answer:'pick',choice:i,note:$('note').value})});
  if(!res.ok){$('status').textContent='Save failed ('+res.status+')';return}
  it.answer='pick';it.choice=i;it.note=$('note').value;idx=nextOpen();show();
}
async function whoPick(i){
  const it=items[idx];if(!it||!it.who)return;
  const res=await fetch('/api/answer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:it.key,answer:'who',choice:i,note:$('note').value})});
  if(!res.ok){$('status').textContent='Save failed ('+res.status+')';return}
  queue=[];it.answer='who';it.choice=i;it.note=$('note').value;idx=nextOpen();show();
}
async function saveNote(){
  const it=items[idx];if(!it||!it.answer||$('note').value===(it.note||''))return;
  const res=await fetch('/api/answer',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({key:it.key,answer:it.answer,choice:it.choice,note:$('note').value})});
  if(res.ok){it.note=$('note').value;$('status').textContent='Note saved'}
}
async function finish(){
  $('card').hidden=true;$('done').hidden=false;audio.pause();
  $('fill').style.width=(100*items.filter(x=>x.answer).length/items.length)+'%';
  $('pos').textContent=items.length+' / '+items.length;
  const skipped=items.filter(x=>!x.answer).length;
  $('summary').textContent='Loading summary...';
  const r=await (await fetch('/api/summary')).json();
  $('summary').textContent=(skipped?skipped+' not answered yet.\n\n':'')+r.text;
}
function go(i){idx=Math.max(0,i);show()}
function begin(){if(started)return;started=true;$('start').hidden=true;show()}
$('startbtn').onclick=begin;
document.querySelectorAll('#whopanel [data-part]').forEach(b=>b.onclick=()=>{queue=[];playPart(b.dataset.part)});
$('whopicks').querySelectorAll('button').forEach(b=>b.onclick=()=>whoPick(+b.dataset.i));
$('bR').onclick=()=>answer('r');$('bM').onclick=()=>answer('m');$('bW').onclick=()=>answer('w');$('bH').onclick=()=>answer('h');
$('bS').onclick=()=>go(nextOpen()===idx?items.length:nextOpen());$('bB').onclick=()=>go(idx-1);$('bP').onclick=play;
$('bFirst').onclick=()=>go(firstOpen()>=items.length?0:firstOpen());
$('note').addEventListener('blur',saveNote);
$('note').addEventListener('keydown',e=>{if(e.key==='Escape'||(e.key==='Enter'&&!e.shiftKey)){e.preventDefault();$('note').blur()}});
document.addEventListener('keydown',e=>{
  if(!started){begin();e.preventDefault();return}
  if(e.target===$('note')||e.metaKey||e.ctrlKey||e.altKey)return;
  const k=e.key.toLowerCase();
  const it=items[idx];
  if(it&&it.who&&/^[0-2]$/.test(k))whoPick(k==='0'?-1:+k-1);
  else if(it&&it.pick&&/^[0-9]$/.test(k))pick(k==='0'?-1:+k-1);
  else if(it&&!it.pick&&!it.who&&(k==='r'||k==='m'||k==='w'||k==='h'))answer(k);else if(k==='s')go(nextOpen()===idx?items.length:nextOpen());
  else if(k===' '||k==='p'){e.preventDefault();play()}
  else if(k==='arrowleft'){e.preventDefault();go(idx-1)}
  else if(k==='n'){e.preventDefault();$('note').focus()}
});
fetch('/api/state').then(r=>r.json()).then(s=>{items=s.items;document.title='Listen review: '+s.name;idx=firstOpen();
  if(idx>=items.length){started=true;$('start').hidden=true}show()});
</script></body></html>
"""
