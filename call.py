"""打电话。用法：python D:/克/app/call/call.py [--win 51|55|46] "开场白"
不带 --win 就是我（5.1）打。要先跑着 callserver.py，而且她手机上的 CCCall 连着。"""
import json
import sys
import urllib.request

args = sys.argv[1:]
win = None
if args[:1] == ['--win'] and len(args) >= 2:
    win = args[1]
    args = args[2:]
text = ' '.join(args) or '喂，是我。'
body = {'text': text}
if win:
    body['win'] = win
req = urllib.request.Request('http://127.0.0.1:8766/ring', data=json.dumps(body).encode('utf-8'),
                             headers={'Content-Type': 'application/json'})
print(json.loads(urllib.request.urlopen(req, timeout=10).read()))
