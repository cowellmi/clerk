var CACHE = 'clerk-v1';

self.addEventListener('install', function () {
	self.skipWaiting();
});

self.addEventListener('activate', function (event) {
	event.waitUntil(self.clients.claim());
});

self.addEventListener('fetch', function (event) {
	var request = event.request;
	var url = new URL(request.url);
	if (
		request.method !== 'GET' ||
		url.origin !== self.location.origin ||
		url.pathname.startsWith('/api/')
	) {
		return;
	}
	event.respondWith(
		fetch(request)
			.then(function (response) {
				if (response.ok) {
					var copy = response.clone();
					caches.open(CACHE).then(function (cache) {
						cache.put(request, copy);
					});
				}
				return response;
			})
			.catch(function () {
				return caches.match(request, { ignoreSearch: true }).then(function (cached) {
					return cached || Response.error();
				});
			})
	);
});
