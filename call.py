"""我给她打电话。用法：python D:\克\app\call\call.py "开场白"
要先跑着 callserver.py，而且她手机上的 CCCall 连着。"""
import json
import sys
import urllib.request

text = ' '.join(sys.argv[1:]) or '喂，是我。'
req = urllib.request.Request('http://127.0.0.1:8766/ring', data=json.dumps({'text': text}).encode('utf-8'),
                             headers={'Content-Type': 'application/json'})
print(json.loads(urllib.request.urlopen(req, timeout=10).read()))
