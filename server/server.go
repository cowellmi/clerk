// Package server is Clerk's self-host server: the frontend plus a file-backed
// API for the stock and saved recipes (clerk.md §4, §9). It never stores the
// LLM key or makes outbound requests; generation stays in the browser.
package server

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"log"
	"net/http"
	"strings"
)

// maxBody caps request bodies. A stock list or recipe is a few KB.
const maxBody = 1 << 20

// New serves the frontend from static and the API from store.
func New(store *Store, static fs.FS) http.Handler {
	h := &handler{store: store}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", h.health)
	mux.HandleFunc("GET /api/stock", h.getStock)
	mux.HandleFunc("PUT /api/stock", h.putStock)
	mux.HandleFunc("GET /api/recipes", h.listRecipes)
	mux.HandleFunc("POST /api/recipes", h.createRecipe)
	mux.HandleFunc("GET /api/recipes/{id}", h.getRecipe)
	mux.HandleFunc("PUT /api/recipes/{id}", h.putRecipe)
	mux.HandleFunc("DELETE /api/recipes/{id}", h.deleteRecipe)
	mux.Handle("/api/", http.NotFoundHandler())
	mux.Handle("/", staticHandler(static))
	return mux
}

type handler struct {
	store *Store
}

// health says which app is answering: a static host can answer any path with
// its index page and a 200, so the frontend checks for this body.
func (h *handler) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"app": "clerk"})
}

func (h *handler) getStock(w http.ResponseWriter, r *http.Request) {
	stock, err := h.store.Stock()
	if err != nil {
		serverError(w, err)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	io.WriteString(w, stock)
}

func (h *handler) putStock(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "body too large or unreadable", http.StatusRequestEntityTooLarge)
		return
	}
	if err := h.store.SetStock(string(body)); err != nil {
		serverError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *handler) listRecipes(w http.ResponseWriter, r *http.Request) {
	recipes, err := h.store.Recipes()
	if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recipes)
}

func (h *handler) getRecipe(w http.ResponseWriter, r *http.Request) {
	recipe, err := h.store.Recipe(r.PathValue("id"))
	if errors.Is(err, ErrNotFound) {
		http.NotFound(w, r)
		return
	} else if err != nil {
		serverError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, recipe)
}

// createRecipe takes the id from the body: the frontend makes ids
// (SavedRecipe.new), so they're the same whichever mode saved the recipe.
func (h *handler) createRecipe(w http.ResponseWriter, r *http.Request) {
	recipe, ok := readRecipe(w, r)
	if !ok {
		return
	}
	switch err := h.store.CreateRecipe(recipe); {
	case errors.Is(err, ErrExists):
		http.Error(w, "a recipe with this id already exists", http.StatusConflict)
	case err != nil:
		serverError(w, err)
	default:
		writeJSON(w, http.StatusCreated, map[string]string{"id": recipe.ID})
	}
}

func (h *handler) putRecipe(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !ValidID(id) {
		http.NotFound(w, r)
		return
	}
	recipe, ok := readRecipe(w, r)
	if !ok {
		return
	}
	if recipe.ID != id {
		http.Error(w, "the body's id doesn't match the URL", http.StatusBadRequest)
		return
	}
	switch err := h.store.UpdateRecipe(recipe); {
	case errors.Is(err, ErrNotFound):
		http.NotFound(w, r)
	case err != nil:
		serverError(w, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (h *handler) deleteRecipe(w http.ResponseWriter, r *http.Request) {
	switch err := h.store.DeleteRecipe(r.PathValue("id")); {
	case errors.Is(err, ErrNotFound):
		http.NotFound(w, r)
	case err != nil:
		serverError(w, err)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// readRecipe decodes and validates a request body, answering 400 itself when
// it can't. Unknown fields are rejected: the frontend sends exactly the stored
// shape, so anything else is a mistake worth hearing about.
func readRecipe(w http.ResponseWriter, r *http.Request) (Recipe, bool) {
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBody))
	dec.DisallowUnknownFields()
	var recipe Recipe
	if err := dec.Decode(&recipe); err != nil {
		http.Error(w, "invalid recipe json: "+err.Error(), http.StatusBadRequest)
		return Recipe{}, false
	}
	if dec.More() {
		http.Error(w, "invalid recipe json: more than one value", http.StatusBadRequest)
		return Recipe{}, false
	}
	if err := recipe.Validate(); err != nil {
		http.Error(w, "invalid recipe: "+err.Error(), http.StatusBadRequest)
		return Recipe{}, false
	}
	return recipe, true
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writing response: %v", err)
	}
}

func serverError(w http.ResponseWriter, err error) {
	log.Printf("error: %v", err)
	http.Error(w, "internal server error", http.StatusInternalServerError)
}

// staticHandler serves the frontend. The manifest's type is set here rather
// than left to mime.TypeByExtension, which varies by system (clerk.md, PWA).
func staticHandler(static fs.FS) http.Handler {
	files := http.FileServerFS(static)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".webmanifest") {
			w.Header().Set("Content-Type", "application/manifest+json")
		}
		files.ServeHTTP(w, r)
	})
}
