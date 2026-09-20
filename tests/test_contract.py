import importlib.util,pathlib,plistlib,unittest

class ContractTests(unittest.TestCase):
    def test_plist_is_native_and_has_required_privacy_string(self):
        p=pathlib.Path(__file__).parents[1]/'ios/Note8Remote/Info.plist'
        v=plistlib.loads(p.read_bytes());self.assertTrue(v['NSLocalNetworkUsageDescription']);self.assertEqual(v['CFBundlePackageType'],'APPL')
    def test_dependency_hashes(self):
        import hashlib
        p=pathlib.Path(__file__).parents[1]/'android/libs'
        expected={'nanohttpd-2.3.1.jar':'de864c47818157141a24c9acb36df0c47d7bf15b7ff48c90610f3eb4e5df0e58','nanohttpd-websocket-2.3.1.jar':'8f81a852052b62dee7bb85c232e367369c3ac25fbc59fb62151e56a31aa3bb8a'}
        for name,digest in expected.items():self.assertEqual(hashlib.sha256((p/name).read_bytes()).hexdigest(),digest)

if __name__=='__main__':unittest.main()
