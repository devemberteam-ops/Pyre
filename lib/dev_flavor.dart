/// Wave 1.1: build-time flag for the side-by-side "Pyre Dev" channel.
/// Set at build time with `--dart-define=PYRE_DEV=true`. Production builds
/// omit it, so this is `false` and all paths/IDs are unchanged.
const bool kDevFlavor = bool.fromEnvironment('PYRE_DEV');

/// Pure mapping (testable without the const): the on-disk data subfolder.
/// Dev builds get a fully separate folder so they never touch real data.
String pyreDataDirNameFor(bool dev) => dev ? 'EmberChat-dev' : 'EmberChat';

/// The data subfolder for THIS build (under the app documents directory).
/// Production = 'EmberChat' (unchanged); Dev = 'EmberChat-dev'.
String pyreDataDirName() => pyreDataDirNameFor(kDevFlavor);
