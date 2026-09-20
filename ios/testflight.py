#!/usr/bin/env python3
"""Manual App Store distribution using repository secrets on an ephemeral runner."""
import base64
import datetime
import hashlib
import os
import plistlib
import re
import secrets
import subprocess
from pathlib import Path


def run(*args):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        # Emit only diagnostic error lines, with credential values and identities removed.
        output = result.stdout.decode('utf-8', errors='replace')
        for name in ('CERTIFICATE_BASE64', 'CERTIFICATE_PASSWORD', 'PROFILE_BASE64', 'ASC_KEY_BASE64', 'ASC_KEY_ID', 'ASC_ISSUER_ID'):
            value = os.environ.get(name)
            if value:
                output = output.replace(value, '[redacted]')
        for line in output.splitlines():
            if 'error:' in line.lower() or 'validation failed' in line.lower():
                line = re.sub(r'[\w.+-]+@[\w.-]+', '[email]', line)
                line = re.sub(r'\b[A-Fa-f0-9-]{36,}\b', '[identifier]', line)
                print(line[:1200], flush=True)
        raise RuntimeError(f'{Path(args[0]).name} failed with exit code {result.returncode}')
    return result.stdout


def main():
    required = ('CERTIFICATE_BASE64', 'PROFILE_BASE64', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_BASE64')
    missing = [key for key in required if not os.environ.get(key)]
    if missing:
        raise SystemExit('Missing repository secrets: ' + ', '.join(missing))
    bundle = os.environ['BUNDLE_ID']
    key_id = os.environ['ASC_KEY_ID']
    issuer = os.environ['ASC_ISSUER_ID']
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', bundle):
        raise SystemExit('Invalid bundle identifier')
    if not re.fullmatch(r'[A-Za-z0-9]{10}', key_id) or not re.fullmatch(r'[0-9a-fA-F-]{36}', issuer):
        raise SystemExit('Invalid App Store Connect API key identifiers')
    temp = Path(os.environ['RUNNER_TEMP'])
    keychain = temp / 'note8-testflight.keychain-db'
    cert = temp / 'note8-distribution.p12'
    profile = temp / 'note8-appstore.mobileprovision'
    key = temp / f'AuthKey_{key_id}.p8'
    export = temp / 'note8-export.plist'
    installed = None
    try:
        for path, variable in ((cert, 'CERTIFICATE_BASE64'), (profile, 'PROFILE_BASE64'), (key, 'ASC_KEY_BASE64')):
            path.write_bytes(base64.b64decode(os.environ[variable], validate=True))
            path.chmod(0o600)
        data = plistlib.loads(run('security', 'cms', '-D', '-i', str(profile)))
        ent = data['Entitlements']
        if data.get('ProvisionedDevices') or data.get('ProvisionsAllDevices') or ent.get('get-task-allow'):
            raise RuntimeError('Use an App Store distribution profile, not development, Ad Hoc or Enterprise')
        if data['ExpirationDate'] <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None):
            raise RuntimeError('Provisioning profile expired')
        if ent['application-identifier'].split('.', 1)[1] != bundle:
            raise RuntimeError('Provisioning profile does not match the app bundle')
        team = data['TeamIdentifier'][0]
        profile_uuid = data['UUID']
        if not re.fullmatch(r'[0-9A-Fa-f-]{36}', profile_uuid):
            raise RuntimeError('Invalid profile UUID')
        password = secrets.token_urlsafe(32)
        run('security', 'create-keychain', '-p', password, str(keychain))
        run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
        run('security', 'unlock-keychain', '-p', password, str(keychain))
        run('security', 'import', str(cert), '-P', os.environ.get('CERTIFICATE_PASSWORD', ''), '-k', str(keychain), '-T', '/usr/bin/codesign')
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, str(keychain))
        run('security', 'list-keychains', '-d', 'user', '-s', str(keychain))
        identities = run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)).decode()
        allowed = {hashlib.sha1(c).hexdigest().upper() for c in data['DeveloperCertificates']}
        identity = next((h for h in re.findall(r'\b[0-9A-F]{40}\b', identities) if h in allowed), None)
        if not identity:
            raise RuntimeError('Signing certificate is not included in the supplied profile')
        installed = Path.home() / 'Library/MobileDevice/Provisioning Profiles' / f'{profile_uuid}.mobileprovision'
        installed.parent.mkdir(parents=True, exist_ok=True)
        installed.write_bytes(profile.read_bytes())
        info_path = Path('ios/Note8Remote/Info.plist')
        info = plistlib.loads(info_path.read_bytes())
        # A fresh dispatch increases the first component; a rerun increases the second.
        build_number = int(os.environ['GITHUB_RUN_NUMBER'])
        attempt = int(os.environ['GITHUB_RUN_ATTEMPT'])
        if not 1 <= build_number <= 9999 or not 1 <= attempt <= 99:
            raise RuntimeError('Build number exceeded the supported range')
        info['CFBundleVersion'] = f'{build_number}.{attempt}'
        info_path.write_bytes(plistlib.dumps(info))
        print('Archiving App Store build with Xcode 26...', flush=True)
        run('xcodebuild', '-project', 'ios/Note8Remote.xcodeproj', '-scheme', 'Note8Remote', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', 'build/Note8Remote.xcarchive', f'PRODUCT_BUNDLE_IDENTIFIER={bundle}', f'DEVELOPMENT_TEAM={team}', 'CODE_SIGN_STYLE=Manual', f'CODE_SIGN_IDENTITY={identity}', f'PROVISIONING_PROFILE_SPECIFIER={profile_uuid}', 'archive')
        export.write_bytes(plistlib.dumps({'method': 'app-store-connect', 'destination': 'export', 'teamID': team, 'signingStyle': 'manual', 'signingCertificate': identity, 'provisioningProfiles': {bundle: profile_uuid}, 'manageAppVersionAndBuildNumber': False, 'uploadSymbols': True}))
        run('xcodebuild', '-exportArchive', '-archivePath', 'build/Note8Remote.xcarchive', '-exportPath', 'build/testflight', '-exportOptionsPlist', str(export))
        ipa = next(Path('build/testflight').glob('*.ipa'))
        os.environ['API_PRIVATE_KEYS_DIR'] = str(temp)
        print('Validating signed build with Apple...', flush=True)
        run('xcrun', 'altool', '--validate-app', '-f', str(ipa), '-t', 'ios', '--apiKey', key_id, '--apiIssuer', issuer)
        print('Uploading build to App Store Connect...', flush=True)
        run('xcrun', 'altool', '--upload-app', '-f', str(ipa), '-t', 'ios', '--apiKey', key_id, '--apiIssuer', issuer)
        print('Upload accepted. Apple processing and internal tester assignment remain; this is not an App Store release.')
    finally:
        if keychain.exists():
            subprocess.run(['security', 'delete-keychain', str(keychain)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for path in (cert, profile, key, export, installed):
            if path is not None:
                path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
