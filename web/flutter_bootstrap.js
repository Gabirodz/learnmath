// Flutter's loader without its service worker (deprecated in Flutter, and it
// would replace learnmath_sw.js, which has the same scope).
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  // What Flutter does by default, plus a word to the loading screen in
  // index.html once the app's code is here and it starts up.
  onEntrypointLoaded: async (engineInitializer) => {
    window.learnmathLoading?.starting();
    const appRunner = await engineInitializer.initializeEngine();
    await appRunner.runApp();
  },
});
