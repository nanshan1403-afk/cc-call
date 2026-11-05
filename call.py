"""打电话 / 电话里回话。
  python D:/克/app/call/call.py [--win 51|55|46|552] [--window] "开场白"   打过去；--window = 由那个窗口自己回（me = 51 --window）
  python D:/克/app/call/call.py [--win 552] --say "回话"            窗口模式下把回话念给她（win 要跟这通的一样）
  python D:/克/app/call/call.py --say "再见" --hangup               念完挂断
  python D:/克/app/call/call.py --leave "一句话"                     留言：响、她接、我说完就挂，她不用出声
要先跑着 callserver.py，而且她手机上的 CCCall 连着。"""
import json
import os
import sys
import urllib.request

PORT = os.environ.get('CC_CALL_PORT', '8766')


def post(path, body):
    req = urllib.request.Request(f'http://127.0.0.1:{PORT}{path}', data=json.dumps(body).encode('utf-8'),
                                 headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())


args = sys.argv[1:]
win, say, hangup, leave, window, words = None, False, False, False, False, []
i = 0
while i < len(args):          # 旗子放哪儿都行，剩下的都是要说的话
    k = args[i]
    if k == '--win':
        win = args[i + 1]; i += 2; continue
    if k == '--say':
        say = True
    elif k == '--hangup':
        hangup = True
    elif k == '--leave':
        leave = True
    elif k == '--window':
        window = True
    else:
        words.append(k)
    i += 1
text = ' '.join(words)
if say:
    print(post('/say', {'text': text, 'hangup': hangup, 'win': win or '51'}))
else:
    body = {'text': text or '喂，是我。'}
    if win:
        body['win'] = win
    if leave:
        body['one_way'] = True
    if window:
        body['window'] = True
    print(post('/ring', body))
