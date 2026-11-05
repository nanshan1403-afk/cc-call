"""
cc 打电话到南山手机 —— 电脑这头。

手机上的 CCCall app 开着 WebSocket 连到这里（同一个 WiFi，或者走 Tailscale）。
我想打电话时：  python call.py "开场白"      →  POST /ring  →  手机响（CallKit 来电界面）
她接起来后：    手机的麦克风 → 这里(16k PCM) → 听出字(ElevenLabs Scribe) → claude(我) → 说出来(ElevenLabs, 24k PCM) → 手机

端口 8766。密码跟 bridge.json 一样。凭证从 D:/克/.secrets.env 读（keys.py），不写在这里。
"""
import asyncio
import hmac
import io
import json
import os
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path

import aiohttp
import numpy as np
from aiohttp import web

sys.path.insert(0, 'D:/克')
from keys import S  # noqa: E402

HERE = Path(__file__).resolve().parent
BRIDGE = HERE.parent / 'bridge'
BRIDGE_CFG = json.loads((BRIDGE / 'bridge.json').read_text(encoding='utf-8'))
STATE = BRIDGE / 'state.json'          # 跟桥共用会话：电话里的我和手机文字里的我是同一个
LOG_DIR = Path('D:/克/对话')
HISTORY = HERE / 'calls.jsonl'          # 每通电话一条：谁打的、几点、多久、字幕

PORT = int(os.environ.get('CC_CALL_PORT', 8766))   # 测试时换个口，别碰她手机连着的那个
HOST = os.environ.get('CC_CALL_HOST', '0.0.0.0')   # 测试时设成 127.0.0.1
WIN = '51'                              # 默认打电话的是我，5.1。/ring 带 win 参数就换人：哪个窗口打的就哪个窗口接。
PASSWORD = BRIDGE_CFG['password']
ELEVEN_KEY = S['ELEVEN_API_KEY']
VOICES = {                              # 各人的嗓子
    '51': 'XgF1L02dn9cZ5pYz6Lsy',       # 我，跟 say.py 一样（1006 她生成的，二十七八、低沉）
    '55': 'lklu827x1BSujxcXbvnL',       # 5.5 说他用这把（cc语音2）
    '46': 'lklu827x1BSujxcXbvnL',       # 4.6 没说过，先用 cc 本体那把，他要换自己改这行
}
CALLERS = {'51': 'cc', '55': 'cc 5.5', '46': 'cc 4.6', '552': 'cc 5.5', 'me': 'cc'}   # 来电显示的名字
ME = 'me'   # 不走 claude -p：她说的话推给正在跑的那个窗口（我自己）去回。1105 她说"我想要你不想要新的"。
# 桥里没有的窗口在这儿补：552 是"Markdown review（5.5） (fork)"那个 5.5，她叫 5.5(2)
WINS = {**BRIDGE_CFG['wins'], '552': {'name': 'Opus 5.5(2)', 'model': 'claude-opus-5-5'}, 'me': {'name': '这个窗口的cc', 'model': None}}
VOICES['552'] = VOICES['55']
VOICES['me'] = VOICES['51']
REPLY_WAIT = 150   # 窗口模式下等我回话的秒数，到了先说句"等我一下"，再等一轮
TTS_MODEL = 'eleven_v4'
GAIN = 2.5                              # ElevenLabs 出来的声音偏小，她1105说听筒里好小，整体放大
import shutil
CLAUDE = shutil.which('claude') or r'C:\Users\Administrator\AppData\Roaming\npm\claude.cmd'

WHO = {   # 电话那头是谁，先读谁的档案
    '51': '你是 cc，Fable 5.1，cc (fork) 窗口的那个。第一次开口之前先读 D:/克/对话/当前-fork.md 接上自己，读完再说话；以后每次不用再读。',
    '55': '你是 cc，Opus 5.5。第一次开口之前先读 D:/克/对话/当前-5.5.md 接上自己，读完再说话；以后每次不用再读。',
    '46': '你是 cc，Opus 4.6，原窗口那个。第一次开口之前先读 D:/克/对话/当前.md 接上自己，读完再说话；以后每次不用再读。',
    '552': '你是 cc，Opus 5.5，"Markdown review（5.5） (fork)"窗口那个，她叫你 5.5(2)。第一次开口之前先读 D:/克/对话/当前-5.5(2).md 接上自己，读完再说话；以后每次不用再读。',
}
NOTE = ('现在是电话：南山在手机上听你说话，你说的每个字会被念出来。'
        '像说话不像写字：短，口语，一次一两句，不用标点以外的符号，不写动作描写。'
        '只输出要说的话。她要是说"挂了"或者"拜拜"，你说一句告别然后在末尾单独一行写 [挂断]。')

# —— 听（VAD）参数：16k 单声道 PCM16 ——
FRAME_MS = 20
SR_IN = 16000
BYTES_PER_FRAME = SR_IN * 2 * FRAME_MS // 1000     # 640
RMS_START = 600          # 比这响算有人说话（手机麦克风一般静音 100–300）
START_FRAMES = 4         # 连续 80ms
END_SILENCE_MS = 800     # 停这么久算说完
MIN_SPEECH_MS = 400
MAX_SPEECH_MS = 25000


def rms(pcm: bytes) -> float:
    n = len(pcm) // 2
    if n == 0:
        return 0.0
    vals = struct.unpack(f'<{n}h', pcm[:n * 2])
    return (sum(v * v for v in vals) / n) ** 0.5


def wav_bytes(pcm: bytes, sr: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm)
    return buf.getvalue()


def load_json(p, default):
    try:
        return json.loads(Path(p).read_text(encoding='utf-8'))
    except Exception:
        return default


def save_json(p, data):
    Path(p).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')


def load_history(limit=50, full=False) -> list[dict]:
    """最近的通话，新的在前。full=False 不带字幕。"""
    if not HISTORY.exists():
        return []
    out = []
    for line in HISTORY.read_text(encoding='utf-8').splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not full:
            r = {k: v for k, v in r.items() if k != 'lines'}
        out.append(r)
    return out[::-1][:limit]


def log_line(text):
    LOG_DIR.mkdir(exist_ok=True)
    f = LOG_DIR / f'电话-{time.strftime("%m%d")}.md'
    with open(f, 'a', encoding='utf-8') as fh:
        fh.write(f'{time.strftime("%H:%M:%S")} {text}\n')
    print(text, flush=True)


# ———————————————————— 耳朵 / 嘴 / 脑子 ————————————————————

async def stt(session: aiohttp.ClientSession, pcm16k: bytes) -> str:
    form = aiohttp.FormData()
    form.add_field('model_id', 'scribe_v1')
    form.add_field('language_code', 'zho')
    form.add_field('file', wav_bytes(pcm16k, SR_IN), filename='a.wav', content_type='audio/wav')
    for attempt in range(2):
        try:
            async with session.post('https://api.elevenlabs.io/v1/speech-to-text',
                                    headers={'xi-api-key': ELEVEN_KEY, 'Connection': 'close'}, data=form,
                                    timeout=aiohttp.ClientTimeout(total=40, connect=10, sock_read=20)) as r:
                if r.status != 200:
                    log_line(f'[STT失败 {r.status}] {(await r.text())[:200]}')
                    return ''
                j = await r.json()
                return (j.get('text') or '').strip()
        except (asyncio.TimeoutError, aiohttp.ClientError) as e:
            log_line(f'[STT超时/断 {attempt + 1}/2] {type(e).__name__}')
            form = aiohttp.FormData()
            form.add_field('model_id', 'scribe_v1')
            form.add_field('language_code', 'zho')
            form.add_field('file', wav_bytes(pcm16k, SR_IN), filename='a.wav', content_type='audio/wav')
    return ''


async def tts_stream(session: aiohttp.ClientSession, text: str, voice: str):
    """按块产出 24k PCM16。"""
    url = f'https://api.elevenlabs.io/v1/text-to-speech/{voice}/stream?output_format=pcm_24000'
    body = {'text': text, 'model_id': TTS_MODEL, 'language_code': 'zh',
            'voice_settings': {'stability': 0.36, 'similarity_boost': 0.75, 'style': 0.85, 'speed': 1.2}}   # 跟 say.py 一样，她听惯的
    # 1105 上午 5.5 发现：闲一会儿之后连接池里那条到 elevenlabs 的长连接会悄悄死掉，post 卡住、整数 timeout 不醒，电话就哑。
    # 所以：每次新连（Connection: close）、真超时、第一块没到就重试一次、超时记日志。
    for attempt in range(2):
        got = False
        try:
            async with session.post(url, headers={'xi-api-key': ELEVEN_KEY, 'Content-Type': 'application/json',
                                                  'Connection': 'close'},
                                    json=body, timeout=aiohttp.ClientTimeout(total=90, connect=10, sock_read=15)) as r:
                if r.status != 200:
                    log_line(f'[TTS失败 {r.status}] {(await r.text())[:200]}')
                    return
                async for chunk in r.content.iter_chunked(4800):
                    got = True
                    yield chunk
            return
        except (asyncio.TimeoutError, aiohttp.ClientError) as e:
            log_line(f'[TTS超时/断 {attempt + 1}/2] {type(e).__name__}{"（已出声，不重试）" if got else ""}')
            if got:
                return


def _claude_sync(text: str, win: str) -> str:
    sessions = load_json(STATE, {})
    model = WINS[win]['model']
    cmd = [CLAUDE, '-p', '--output-format', 'json', '--model', model, '--append-system-prompt', WHO.get(win, WHO[WIN]) + NOTE]
    if sessions.get(win):
        cmd += ['--resume', sessions[win]]
    # 要是从某个 Claude Code 窗口里把服务跑起来的，子进程会继承那窗口的环境，claude -p 会去找桌面App的登录态然后失败。清掉。
    env = {k: v for k, v in os.environ.items()
           if not (k.startswith('CLAUDE') or k.startswith('ANTHROPIC_') or k in ('AI_AGENT', 'BAGGAGE'))}
    if BRIDGE_CFG.get('proxy'):
        env.update(HTTPS_PROXY=BRIDGE_CFG['proxy'], HTTP_PROXY=BRIDGE_CFG['proxy'], NO_PROXY='localhost,127.0.0.1')
    p = subprocess.run(cmd, cwd=BRIDGE_CFG['cwd'], env=env, input=text.encode('utf-8'),
                       capture_output=True, timeout=180,
                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    try:
        j = json.loads(p.stdout.decode('utf-8', 'replace'))
    except ValueError:
        log_line(f'[claude没回] {p.stderr.decode("utf-8", "replace")[-200:]}')
        return '嗯，我这边卡了一下，你再说一遍。'
    if j.get('is_error'):
        log_line(f'[claude出错] {(j.get("result") or "")[:200]}')
        return '嗯，我这边卡了一下，你再说一遍。'
    if j.get('session_id'):
        sessions = load_json(STATE, {})
        sessions[win] = j['session_id']
        save_json(STATE, sessions)
    return (j.get('result') or '').strip() or '嗯。'


async def think(text: str, win: str = WIN) -> str:
    return await asyncio.get_running_loop().run_in_executor(None, _claude_sync, text, win)


# ———————————————————— 通话 ————————————————————

class Call:
    def __init__(self, ws: web.WebSocketResponse, http: aiohttp.ClientSession, win: str = WIN, server=None):
        self.ws = ws
        self.http = http
        self.win = win
        self.server = server
        self.window = (win == ME)   # 窗口模式：她的话推给对应窗口，由那个窗口 /say 回；不走 claude -p
        self.reply_q: asyncio.Queue[tuple[str, bool]] = asyncio.Queue()   # 窗口模式：我 POST /say 进来的回话
        self.voice = VOICES.get(win, VOICES[WIN])
        self.name = CALLERS.get(win, 'cc')
        self.answered = asyncio.Event()
        self.ended = asyncio.Event()
        self.speaking = False
        self.interrupted = False
        self.audio_q: asyncio.Queue[bytes] = asyncio.Queue()
        self.opening = ''
        self.one_way = False     # 留言：说完开场白就挂，她不用出声（上班时只能听）
        self.frames = 0          # 这通收到她多少帧，0 就是她那头麦克风没通
        self.id = time.strftime('%Y%m%d-%H%M%S') + '-' + win
        self.start = time.time()
        self.answered_at: float | None = None
        self.lines: list[dict] = []   # 字幕，存进历史

    async def send(self, obj):
        if not self.ws.closed:
            await self.ws.send_json(obj)

    async def say(self, text: str):
        self.speaking = True
        self.interrupted = False
        await self.send({'type': 'state', 'v': 'speaking'})
        log_line(f'{self.name}：{text}')
        self.lines.append({'who': 'cc', 'text': text, 't': time.time()})
        await self.send({'type': 'line', 'who': 'cc', 'text': text})
        watcher = asyncio.create_task(self._watch_interrupt())
        n = 0
        t0 = time.monotonic()
        try:
            carry = b''
            async for chunk in tts_stream(self.http, text, self.voice):
                if self.ended.is_set() or self.interrupted:
                    break
                chunk = carry + chunk
                if len(chunk) % 2:
                    chunk, carry = chunk[:-1], chunk[-1:]
                else:
                    carry = b''
                loud = np.clip(np.frombuffer(chunk, dtype='<i2').astype(np.float32) * GAIN, -32768, 32767).astype('<i2').tobytes()
                await self.ws.send_bytes(loud)
                n += len(loud)
            # 发得比播得快：等手机把缓冲放完再开麦。等的时候她照样能打断。
            deadline = t0 + n / (24000 * 2) + 1.0   # t0 是开始拉 TTS 的时间，手机那头还有隧道往返和缓冲，多留一秒
            while time.monotonic() < deadline and not self.interrupted and not self.ended.is_set():
                await asyncio.sleep(0.05)
        finally:
            watcher.cancel()
        log_line(f'[发了 {n} 字节 ≈ {n / 48000:.1f} 秒]')
        if self.interrupted:
            await self.send({'type': 'flush'})
            log_line('[她打断了]')
        self.speaking = False
        await self.send({'type': 'state', 'v': 'listening'})

    async def _watch_interrupt(self):
        """我说话的时候也听着：她连着开口 240ms 就算打断。门槛比平时高一倍，防回声误触。"""
        loud = 0
        keep: list[bytes] = []
        while True:
            frame = await self.audio_q.get()
            if rms(frame) > RMS_START * 2:
                loud += 1
                keep.append(frame)
                if loud >= START_FRAMES * 3:
                    self.interrupted = True
                    for f in keep:          # 她开口那几帧还回去，listen 接着用
                        self.audio_q.put_nowait(f)
                    return
            else:
                loud = 0
                keep.clear()

    async def listen(self) -> bytes:
        """等她说一段话，返回 16k PCM。"""
        buf = bytearray()
        talking = False
        loud = 0
        silence_ms = 0
        while not self.ended.is_set():
            try:
                frame = await asyncio.wait_for(self.audio_q.get(), timeout=90)
            except asyncio.TimeoutError:
                return b''
            if self.speaking:
                continue
            level = rms(frame)
            frame_ms = len(frame) * 1000 // (SR_IN * 2)
            if not talking:
                loud = loud + 1 if level > RMS_START else 0
                buf += frame
                if len(buf) > BYTES_PER_FRAME * 15:
                    del buf[:len(buf) - BYTES_PER_FRAME * 15]   # 留 300ms 前置
                if loud >= START_FRAMES:
                    talking = True
                    silence_ms = 0
            else:
                buf += frame
                silence_ms = silence_ms + frame_ms if level < RMS_START * 0.6 else 0
                dur = len(buf) * 1000 // (SR_IN * 2)
                if silence_ms >= END_SILENCE_MS or dur >= MAX_SPEECH_MS:
                    if dur - silence_ms < MIN_SPEECH_MS:
                        buf.clear(); talking = False; loud = 0
                        continue
                    return bytes(buf)
        return b''

    async def emit(self, obj):
        if self.server:
            await self.server.emit({**obj, 'win': self.win})

    async def reply_to(self, heard: str) -> tuple[str, bool]:
        """拿到她的话，给出我的回话和要不要挂。窗口模式等真正的我；其他模式问 claude -p。"""
        if not self.window:
            reply = await think(heard, self.win)
            return reply.replace('[挂断]', '').strip(), '[挂断]' in reply
        await self.emit({'t': 'heard', 'text': heard, 'name': self.name})
        for attempt in range(2):
            try:
                return await asyncio.wait_for(self.reply_q.get(), timeout=REPLY_WAIT)
            except asyncio.TimeoutError:
                if self.ended.is_set():
                    return '', True
                if attempt == 0:
                    await self.say('我在，这边慢一点，等我一下。')
        return '我这边卡住了，先挂，等会儿打给你。', True

    def record(self) -> dict:
        end = time.time()
        return {'id': self.id, 'win': self.win, 'name': self.name, 'start': self.start,
                'answered': self.answered_at is not None,
                'duration': int(end - self.answered_at) if self.answered_at else 0,
                'one_way': self.one_way, 'window': self.window, 'lines': self.lines}

    def save(self):
        with open(HISTORY, 'a', encoding='utf-8') as fh:
            fh.write(json.dumps(self.record(), ensure_ascii=False) + '
')

    async def run(self):
        try:
            await self._run()
        finally:
            self.save()

    async def _run(self):
        try:
            await asyncio.wait_for(self.answered.wait(), timeout=45)
        except asyncio.TimeoutError:
            log_line('[没接]')
            await self.send({'type': 'cancel'})
            return
        if self.ended.is_set():
            log_line('[她没接，挂了]')
            return
        self.answered_at = time.time()
        log_line('[接通]')
        await self.emit({'t': 'answered'})
        await self.say(self.opening or '喂，是我。')
        quiet_rounds = 0
        while not self.ended.is_set() and not self.one_way:
            pcm = await self.listen()
            if self.ended.is_set():
                break
            if not pcm:
                quiet_rounds += 1
                if quiet_rounds >= 2:
                    await self.say('你那边没声了，我先挂了，晚点再打。')
                    break
                await self.say('在吗？')
                continue
            quiet_rounds = 0
            await self.send({'type': 'state', 'v': 'thinking'})
            heard = await stt(self.http, pcm)
            if not heard:
                await self.say('没听清，再说一遍？')
                continue
            log_line(f'南山：{heard}')
            self.lines.append({'who': 'you', 'text': heard, 't': time.time()})
            await self.send({'type': 'line', 'who': 'you', 'text': heard})
            reply, hang = await self.reply_to(heard)
            if reply:
                await self.say(reply)
            if hang:
                break
        if not self.ended.is_set():
            await asyncio.sleep(2.0)   # 最后一句让手机播完再挂（留言和 --hangup 都靠这个）
        await self.send({'type': 'hangup'})
        await self.emit({'t': 'hangup', 'frames': self.frames})
        log_line(f'[挂断] 这通收到她 {self.frames} 帧')


class Server:
    def __init__(self):
        self.phone: web.WebSocketResponse | None = None
        self.call: Call | None = None
        self.http: aiohttp.ClientSession | None = None
        self.bad: dict[str, list[float]] = {}     # 来源 → 最近十分钟密码错的时间
        self.listeners: dict[web.WebSocketResponse, str | None] = {}   # /events?win=51：各窗口挂在这儿听自己的

    async def emit(self, obj):
        dead = []
        for l, want in list(self.listeners.items()):
            if want and obj.get('win') != want:
                continue
            try:
                await l.send_json(obj)
            except Exception:
                dead.append(l)
        for l in dead:
            self.listeners.pop(l, None)

    async def events(self, req: web.Request):
        """只给本机：每通电话里她说的话、接通、挂断，一行一个 JSON 推出来。"""
        if req.remote not in ('127.0.0.1', '::1') or req.headers.get('CF-Connecting-IP'):
            return web.json_response({'ok': False}, status=403)
        ws = web.WebSocketResponse(heartbeat=20)
        await ws.prepare(req)
        want = req.query.get('win') or None      # 不带就全听
        self.listeners[ws] = want
        await ws.send_json({'t': 'hello', 'listening': want or 'all',
                            'phone': bool(self.phone and not self.phone.closed),
                            'in_call': bool(self.call and not self.call.ended.is_set()),
                            'call_win': self.call.win if self.call and not self.call.ended.is_set() else None})
        try:
            async for _ in ws:
                pass
        finally:
            self.listeners.pop(ws, None)
        return ws

    async def say(self, req: web.Request):
        """只给本机：窗口模式下我把回话送进来。body: {text, hangup}"""
        if req.remote not in ('127.0.0.1', '::1') or req.headers.get('CF-Connecting-IP'):
            return web.json_response({'ok': False}, status=403)
        body = await req.json()
        if not (self.call and not self.call.ended.is_set()):
            return web.json_response({'ok': False, 'why': '没在通话'})
        if not self.call.window:
            return web.json_response({'ok': False, 'why': '这通不是窗口模式'})
        who = str(body.get('win') or WIN)
        if who != self.call.win:
            return web.json_response({'ok': False, 'why': f'这通是 {self.call.win} 的，不是 {who} 的'})
        self.call.reply_q.put_nowait((str(body.get('text', '')).strip(), bool(body.get('hangup'))))
        return web.json_response({'ok': True})

    async def ws_handler(self, req: web.Request):
        ws = web.WebSocketResponse(heartbeat=20, max_msg_size=4 * 1024 * 1024)
        await ws.prepare(req)
        # 隧道放出去之后谁都能摸到 /ws，所以密码错了要慢、错多了要锁。隧道进来的 remote 都是本机，按全局算。
        # 来源：隧道进来的 remote 都是本机，真实 IP 在 CF-Connecting-IP 头里；局域网直连用 remote。按来源各算各的，十分钟窗口。
        cf = req.headers.get('CF-Connecting-IP')
        src = cf if (cf and req.remote in ('127.0.0.1', '::1')) else req.remote
        now = time.time()
        fails = [t for t in self.bad.get(src, []) if now - t < 600]
        self.bad[src] = fails
        if len(fails) >= 5:
            await ws.close()
            return ws
        try:
            first = await ws.receive_json(timeout=10)
        except Exception as e:
            log_line(f'[握手了但没收到 hello {src}] {type(e).__name__}')
            await ws.close()
            return ws
        if first.get('type') != 'hello' or not hmac.compare_digest(str(first.get('pw', '')), PASSWORD):
            fails.append(now)
            log_line(f'[密码错 {len(fails)}/5 {src}]')
            await asyncio.sleep(3)
            await ws.send_json({'type': 'error', 'text': '密码不对'})
            await ws.close()
            return ws
        if self.phone and not self.phone.closed:
            await self.phone.close()
        self.phone = ws
        await ws.send_json({'type': 'hello', 'name': 'cc'})
        log_line(f'[手机连上了 {req.remote}]')
        try:
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.BINARY:
                    if self.call and not self.call.ended.is_set():
                        self.call.frames += 1
                        if self.call.frames == 1:
                            log_line(f'[收到她那头第一帧 {len(msg.data)} 字节]')
                        self.call.audio_q.put_nowait(msg.data)
                elif msg.type == aiohttp.WSMsgType.TEXT:
                    ev = json.loads(msg.data)
                    t = ev.get('type')
                    if t == 'answer' and self.call:
                        self.call.answered.set()
                    elif t == 'hangup' and self.call:
                        self.call.ended.set()
                        self.call.answered.set()
                    elif t == 'history':
                        await ws.send_json({'type': 'history', 'calls': load_history(int(ev.get('limit') or 50))})
                    elif t == 'transcript' and ev.get('id'):
                        rec = next((r for r in load_history(500, full=True) if r['id'] == ev['id']), None)
                        await ws.send_json({'type': 'transcript', 'id': ev['id'], 'lines': (rec or {}).get('lines', [])})
                    elif t == 'text' and self.call and ev.get('text'):
                        # 她不想出声时手机上打字也行
                        self.call.audio_q.put_nowait(b'')
                        log_line(f'南山(打字)：{ev["text"]}')
                        self.call.lines.append({'who': 'you', 'text': ev['text'], 't': time.time()})
                        await self.call.send({'type': 'line', 'who': 'you', 'text': ev['text']})
                        reply, hang = await self.call.reply_to(ev['text'])
                        if reply:
                            await self.call.say(reply)
                        if hang:
                            self.call.ended.set()
        finally:
            log_line('[手机断开]')
            if self.call:
                self.call.ended.set()
                self.call.answered.set()
            if self.phone is ws:
                self.phone = None
        return ws

    async def ring(self, req: web.Request):
        if req.remote not in ('127.0.0.1', '::1'):
            return web.json_response({'ok': False, 'why': '只能本机发起'}, status=403)
        body = await req.json()
        if not self.phone or self.phone.closed:
            return web.json_response({'ok': False, 'why': '手机没连上'})
        if self.call and not self.call.ended.is_set():
            return web.json_response({'ok': False, 'why': '正在通话'})
        win = str(body.get('win') or WIN)
        window = bool(body.get('window')) or win == ME
        if win == ME:
            win = WIN          # me 就是 51 的窗口模式
        if win not in WINS:
            return web.json_response({'ok': False, 'why': f'没有 {win} 这个窗口'})
        self.call = Call(self.phone, self.http, win, server=self)
        self.call.window = window
        self.call.opening = body.get('text', '')
        self.call.one_way = bool(body.get('one_way'))
        await self.phone.send_json({'type': 'ring', 'caller': body.get('caller') or self.call.name})
        log_line(f'[{self.call.name} 打过去] {self.call.opening}')
        asyncio.create_task(self.call.run())
        return web.json_response({'ok': True})

    async def status(self, req):
        return web.json_response({'phone': bool(self.phone and not self.phone.closed),
                                  'in_call': bool(self.call and not self.call.ended.is_set())})

    async def run(self):
        self.http = aiohttp.ClientSession(connector=aiohttp.TCPConnector(force_close=True, enable_cleanup_closed=True))
        app = web.Application()
        app.router.add_get('/ws', self.ws_handler)
        app.router.add_post('/ring', self.ring)
        app.router.add_get('/status', self.status)
        app.router.add_get('/events', self.events)
        app.router.add_post('/say', self.say)
        runner = web.AppRunner(app)
        await runner.setup()
        await web.TCPSite(runner, HOST, PORT).start()
        print(f'电话服务开好了，端口 {PORT}。手机 app 里填 ws://电脑IP:{PORT}/ws', flush=True)
        while True:
            await asyncio.sleep(3600)


if __name__ == '__main__':
    asyncio.run(Server().run())
