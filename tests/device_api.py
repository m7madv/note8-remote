"""Local integration checks. Explicitly selects the supplied fixture; does not record or send messages.
Run with --config PATH (private JSON host/token) --fixture PATH --kind video.
Requires requests. Restore the previous selected source after testing.
"""
import argparse,hashlib,json,pathlib,requests
p=argparse.ArgumentParser();p.add_argument('--config',required=True);p.add_argument('--fixture',required=True);p.add_argument('--kind',choices=['video','image'],default='video');a=p.parse_args()
c=json.loads(pathlib.Path(a.config).read_text());base='http://'+c['host'];headers={'Authorization':'Bearer '+c['token']}
def req(path,method='GET',**kw):return requests.request(method,base+path,headers=headers,timeout=40,**kw)
assert requests.get(base+'/status',timeout=5).status_code==401
assert requests.get(base+'/status',headers={**headers,'Origin':'https://example.invalid'},timeout=5).status_code==403
assert req('/command','POST',json={'type':'touch','action':0,'x':-1,'y':0.5}).status_code==400
assert req('/command','POST',json={'type':'shell','command':'id'}).status_code==400
assert req('/../etc/passwd').status_code==404
initial=req('/status').json();assert initial['ready']
data=pathlib.Path(a.fixture).read_bytes();sha=hashlib.sha256(data).hexdigest()
def begin(digest):
 r=req('/upload/begin','POST',json={'bytes':len(data),'sha256':digest,'kind':a.kind});r.raise_for_status();return r.json()
b=begin('0'*64);uid=b['id'];offset=0
for start in range(0,len(data),512*1024):
 chunk=data[start:start+512*1024];r=req(f'/upload/chunk?id={uid}&offset={start}','POST',data=chunk);assert r.status_code==200,r.text
assert req('/upload/finish','POST',json={'id':uid}).status_code==400
assert req('/status').json()['media']['bytes']==initial['media']['bytes']
b=begin(sha);uid=b['id'];chunk=data[:min(512*1024,len(data))]
r=req(f'/upload/chunk?id={uid}&offset=0','POST',data=chunk);assert r.status_code==200;r=req(f'/upload/chunk?id={uid}&offset=0','POST',data=chunk);assert r.status_code==409
# A new begin with the same file must resume the completed chunk.
b=begin(sha);assert b['id']==uid and b['offset']==len(chunk)
for start in range(len(chunk),len(data),512*1024):
 r=req(f'/upload/chunk?id={uid}&offset={start}','POST',data=data[start:start+512*1024]);assert r.status_code==200,r.text
r=req('/upload/finish','POST',json={'id':uid});assert r.status_code==200,r.text
assert r.json()['sha256']==sha
print(json.dumps({'passed':['authentication','browser-origin-rejected','invalid-touch','no-shell-endpoint','path-traversal','wrong-hash-preserves-source','duplicate-chunk','resume-offset','verified-commit'],'sha256':sha,'bytes':len(data),'media':r.json()['media']},ensure_ascii=True))
