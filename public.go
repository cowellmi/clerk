// Package clerk embeds the frontend in public/, which the self-host server
// (cmd/clerk) serves alongside api/*. Build the frontend first
// (`npm run build`), or the embedded copy has no public/main.js.
package clerk

import (
	"embed"
	"io/fs"
)

//go:embed public
var public embed.FS

// Public is the contents of public/, rooted at that directory.
func Public() fs.FS {
	sub, err := fs.Sub(public, "public")
	if err != nil {
		panic(err) // "public" is a valid path, so this can't happen
	}
	return sub
}
