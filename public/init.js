// Boots the Elm app and wires its ports to localStorage. Kept out of
// index.html so the page needs no inline script, ready for a strict CSP
// (`script-src 'self'`) at deployment.

// Load the stored data from previous sessions.
var stock = null;
var settings = null;
try {
	// Stock is just a string.
	stock = localStorage.getItem('clerk.stock');

	// The rest of the stored data is JSON and must be parsed.
	var rawSettings = localStorage.getItem('clerk.settings');
	if (rawSettings !== null) {
		settings = JSON.parse(rawSettings);
	}
} catch (e) {
	console.warn('Load err', e);
}

// Saved recipes are a JSON array. Loaded separately, so a problem with the
// other data can't leave Elm with an empty list that the next save would
// write over the stored recipes.
var recipes = null;
try {
	var rawRecipes = localStorage.getItem('clerk.recipes');
	if (rawRecipes !== null) {
		recipes = JSON.parse(rawRecipes);
	}
} catch (e) {
	console.warn('Load err', e);
}

// The recipe last shown on the generator page, as JSON. Loaded separately for
// the same reason as the saved recipes.
var generated = null;
try {
	var rawGenerated = localStorage.getItem('clerk.generated');
	if (rawGenerated !== null) {
		generated = JSON.parse(rawGenerated);
	}
} catch (e) {
	console.warn('Load err', e);
}

// Whether this browser has loaded data from the self-host server before,
// stored as "true" once it has.
var serverKnown = false;
try {
	serverKnown = localStorage.getItem('clerk.server') === 'true';
} catch (e) {
	console.warn('Load err', e);
}

// Load the Elm app, passing in the stored data.
var app = Elm.Main.init({
	node: document.getElementById('app'),
	flags: {
		stock: stock,
		settings: settings,
		recipes: recipes,
		generated: generated,
		serverKnown: serverKnown
	}
});

// Listen for commands from the `saveStock` port.
// The stock is raw free-form text, stored as is.
app.ports.saveStock.subscribe(function (text) {
	try {
		localStorage.setItem('clerk.stock', text);
	} catch (e) {
		console.error('Save err', e);
	}
});

// Listen for commands from the `saveSettings` port.
// The settings are a JSON object, encoded by Elm.
app.ports.saveSettings.subscribe(function (settings) {
	try {
		localStorage.setItem('clerk.settings', JSON.stringify(settings));
	} catch (e) {
		console.error('Save err', e);
	}
});

// Listen for commands from the `saveRecipes` port.
// The whole list of saved recipes, a JSON array encoded by Elm.
app.ports.saveRecipes.subscribe(function (recipes) {
	try {
		localStorage.setItem('clerk.recipes', JSON.stringify(recipes));
	} catch (e) {
		console.error('Save err', e);
	}
});

// Listen for commands from the `saveGenerated` port.
// The recipe on the generator page as a JSON object, or null for none.
app.ports.saveGenerated.subscribe(function (generated) {
	try {
		if (generated === null) {
			localStorage.removeItem('clerk.generated');
		} else {
			localStorage.setItem('clerk.generated', JSON.stringify(generated));
		}
	} catch (e) {
		console.error('Save err', e);
	}
});

// Listen for commands from the `rememberServer` port.
app.ports.rememberServer.subscribe(function () {
	try {
		localStorage.setItem('clerk.server', 'true');
	} catch (e) {
		console.error('Save err', e);
	}
});

// Cmd/Ctrl+S saves the current page, wherever focus is. Handled here rather
// than in Elm because only a DOM listener can stop the browser's own "Save
// page" dialog. Elm decides what, if anything, to save.
document.addEventListener('keydown', function (event) {
	if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') {
		event.preventDefault();
		app.ports.saveShortcut.send(null);
	}
});

// Listen for commands from the `askConfirm` port: show the browser's confirm
// dialog and send the answer (true for OK) back on the `confirmed` port. Elm
// remembers which action it asked about.
app.ports.askConfirm.subscribe(function (message) {
	app.ports.confirmed.send(window.confirm(message));
});

// Listen for messages from the `logError` port.
app.ports.logError.subscribe(function (message) {
	console.error(message);
});

// The service worker makes the app installable from the browser's own menu;
// it sits at the origin root so its scope covers every page.
if ('serviceWorker' in navigator) {
	navigator.serviceWorker.register('/sw.js').catch(function (e) {
		console.warn('Service worker err', e);
	});
}
