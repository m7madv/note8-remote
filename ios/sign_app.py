#!/usr/bin/env python3
"""Optional signing; secrets never printed, embedded profiles must match the bundle."""
import base64,os,plistlib,re,secrets,subprocess
from pathlib import Path
temp=Path(os.environ['RUNNER_TEMP'])
def run(*args): return subprocess.check_output(args,stderr=subprocess.STDOUT)
for key in ('CERTIFICATE_BASE64','PROFILE_BASE64'):
    if not os.environ.get(key): raise SystemExit('Missing Apple signing secrets. Configure repository Actions secrets first.')
cert=temp/'note8-cert.p12';profile=temp/'note8-profile.mobileprovision';keychain=temp/'note8-signing.keychain-db'
cert.write_bytes(base64.b64decode(os.environ['CERTIFICATE_BASE64'],validate=True));profile.write_bytes(base64.b64decode(os.environ['PROFILE_BASE64'],validate=True))
os.chmod(cert,0o600);os.chmod(profile,0o600)
data=plistlib.loads(run('security','cms','-D','-i',str(profile)))
ent=data['Entitlements'];bundle=os.environ['BUNDLE_ID'];app=Path('build/package/Payload/Note8Remote.app')
identifier=ent['application-identifier'];prefix=identifier.split('.',1)[0]
if identifier != prefix+'.'+bundle: raise SystemExit('Provisioning profile must explicitly match BUNDLE_ID; wildcard profiles are not accepted.')
password=secrets.token_urlsafe(32)
run('security','create-keychain','-p',password,str(keychain))
run('security','set-keychain-settings','-lut','21600',str(keychain))
run('security','unlock-keychain','-p',password,str(keychain))
run('security','import',str(cert),'-P',os.environ.get('CERTIFICATE_PASSWORD',''),'-k',str(keychain),'-T','/usr/bin/codesign')
run('security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,str(keychain))
identities=run('security','find-identity','-v','-p','codesigning',str(keychain)).decode()
match=re.search(r'\b([0-9A-F]{40})\b',identities)
if not match: raise SystemExit('No valid signing identity found.')
entfile=temp/'note8-entitlements.plist';entfile.write_bytes(plistlib.dumps(ent));(app/'embedded.mobileprovision').write_bytes(profile.read_bytes())
for nested in sorted(app.rglob('*.framework')): run('codesign','--force','--sign',match.group(1),'--keychain',str(keychain),str(nested))
run('codesign','--force','--sign',match.group(1),'--keychain',str(keychain),'--entitlements',str(entfile),str(app))
run('codesign','--verify','--deep','--strict',str(app))
print('Signed application verified. Device installation depends on the supplied provisioning profile.')
