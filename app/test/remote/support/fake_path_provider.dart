// A fake temporary directory for tests that download into the cache: the app
// resolves the cache through path_provider, whose platform instance a test can
// replace (the interface is a dev dependency for this).

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempRootPlatform extends PathProviderPlatform {
  _TempRootPlatform(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

/// Makes `getTemporaryDirectory()` answer [root] for the rest of the test.
void useTempRoot(String root) => PathProviderPlatform.instance = _TempRootPlatform(root);
