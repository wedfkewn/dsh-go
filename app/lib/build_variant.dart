/// Whether this build is the Remote Only variant: it connects to remote hosts and
/// carries no local DSH engine, no NodeMobile, no iSH and no runtime archive.
///
/// The iOS packaging scripts pass `--dart-define=DSH_REMOTE_ONLY=true` for that
/// build (`tooling/ios/check-archive.sh --remote-only`); a Full build leaves it
/// false. Use it to hide entries that cannot work without the local engine.
const remoteOnlyBuild = bool.fromEnvironment('DSH_REMOTE_ONLY');
