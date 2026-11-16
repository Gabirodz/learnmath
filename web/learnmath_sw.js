// A service worker that intercepts nothing: it has no fetch handler, so
// every request of the app goes straight to the network.
//
// It exists for when the app is hosted in a folder of a larger site that has
// its own caching service worker (a blog theme's offline cache, say). That
// one would also sit in front of this app's requests and cache them,
// including answers from the model API, which must never be served stale.
// A page is controlled by the service worker with the most specific scope,
// so registering this one for the app's folder keeps the other away.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});
