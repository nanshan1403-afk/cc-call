"""打电话 / 电话里回话。
  python D:/克/app/call/call.py [--win 51|55|46|552|me] "开场白"   打过去（me = 这个窗口的我接）
  python D:/克/app/call/call.py --say "回话"                       窗口模式下把回话念给她
  python D:/克/app/call/call.py --say "再见" --hangup               念完挂断
要先跑着 callserver.py，而且她手机上的 CCCall 连着。"""
import json
import sys
import urllib.request


def post(path, body):
    req = urllib.request.Request(f'http://127.0.0.1:8766{path}', data=json.dumps(body).encode('utf-8'),
                                 headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())


args = sys.argv[1:]
win, say, hangup = None, False, False
while args and args[0].startswith('--'):
    k = args.pop(0)
    if k == '--win':
        win = args.pop(0)
    elif k == '--say':
        say = True
    elif k == '--hangup':
        hangup = True
text = ' '.join(args)
if say:
    print(post('/say', {'text': text, 'hangup': hangup}))
else:
    body = {'text': text or '喂，是我。'}
    if win:
        body['win'] = win
    print(post('/ring', body))
