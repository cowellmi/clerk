package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
)

const id = "2026-09-16T14-05-33-chicken-and-rice-bowl"

const recipeJSON = `{"id":"` + id + `","title":"Chicken and Rice Bowl","ingredients":["1 cup rice"],"steps":["Cook the rice."],"createdAt":1789567533000,"updatedAt":1789567533000,"forkedFrom":null}`

func newServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	dir := t.TempDir()
	store, err := Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	static := fstest.MapFS{
		"index.html":           {Data: []byte("<!doctype html>")},
		"manifest.webmanifest": {Data: []byte("{}")},
	}
	srv := httptest.NewServer(New(store, static))
	t.Cleanup(srv.Close)
	return srv, dir
}

func do(t *testing.T, srv *httptest.Server, method, path, body string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(method, srv.URL+path, strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	data, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, string(data)
}

func expect(t *testing.T, gotStatus int, gotBody string, wantStatus int) {
	t.Helper()
	if gotStatus != wantStatus {
		t.Fatalf("status %d, want %d (body %q)", gotStatus, wantStatus, gotBody)
	}
}

func TestHealth(t *testing.T) {
	srv, _ := newServer(t)
	status, body := do(t, srv, "GET", "/api/health", "")
	expect(t, status, body, http.StatusOK)
	if strings.TrimSpace(body) != `{"app":"clerk"}` {
		t.Fatalf("health body %q", body)
	}
}

func TestStock(t *testing.T) {
	srv, dir := newServer(t)

	status, body := do(t, srv, "GET", "/api/stock", "")
	expect(t, status, body, http.StatusOK)
	if body != "" {
		t.Fatalf("fresh stock %q, want empty", body)
	}

	stock := "eggs\nrice\n"
	status, body = do(t, srv, "PUT", "/api/stock", stock)
	expect(t, status, body, http.StatusNoContent)

	status, body = do(t, srv, "GET", "/api/stock", "")
	expect(t, status, body, http.StatusOK)
	if body != stock {
		t.Fatalf("stock %q, want %q", body, stock)
	}
	onDisk, err := os.ReadFile(filepath.Join(dir, "stock.txt"))
	if err != nil || string(onDisk) != stock {
		t.Fatalf("stock.txt %q (%v), want %q", onDisk, err, stock)
	}
}

func TestRecipeLifecycle(t *testing.T) {
	srv, dir := newServer(t)

	status, body := do(t, srv, "GET", "/api/recipes", "")
	expect(t, status, body, http.StatusOK)
	if strings.TrimSpace(body) != "[]" {
		t.Fatalf("fresh list %q, want []", body)
	}

	status, body = do(t, srv, "POST", "/api/recipes", recipeJSON)
	expect(t, status, body, http.StatusCreated)
	if strings.TrimSpace(body) != `{"id":"`+id+`"}` {
		t.Fatalf("create returned %q", body)
	}

	status, body = do(t, srv, "POST", "/api/recipes", recipeJSON)
	expect(t, status, body, http.StatusConflict)

	status, body = do(t, srv, "GET", "/api/recipes/"+id, "")
	expect(t, status, body, http.StatusOK)
	var got, want Recipe
	json.Unmarshal([]byte(body), &got)
	json.Unmarshal([]byte(recipeJSON), &want)
	if got.Title != want.Title || got.ForkedFrom != nil || len(got.Steps) != 1 {
		t.Fatalf("got %+v, want %+v", got, want)
	}

	edited := strings.Replace(recipeJSON, `"Chicken and Rice Bowl"`, `"Rice Bowl"`, 1)
	edited = strings.Replace(edited, `"updatedAt":1789567533000`, `"updatedAt":1789567999000`, 1)
	status, body = do(t, srv, "PUT", "/api/recipes/"+id, edited)
	expect(t, status, body, http.StatusNoContent)

	status, body = do(t, srv, "GET", "/api/recipes", "")
	expect(t, status, body, http.StatusOK)
	var list []Recipe
	json.Unmarshal([]byte(body), &list)
	if len(list) != 1 || list[0].Title != "Rice Bowl" || list[0].UpdatedAt != 1789567999000 || len(list[0].Ingredients) != 1 || len(list[0].Steps) != 1 {
		t.Fatalf("list %+v", list)
	}

	status, body = do(t, srv, "DELETE", "/api/recipes/"+id, "")
	expect(t, status, body, http.StatusNoContent)
	status, body = do(t, srv, "DELETE", "/api/recipes/"+id, "")
	expect(t, status, body, http.StatusNotFound)
	status, body = do(t, srv, "GET", "/api/recipes/"+id, "")
	expect(t, status, body, http.StatusNotFound)

	entries, _ := os.ReadDir(filepath.Join(dir, "recipes"))
	if len(entries) != 0 {
		t.Fatalf("recipes/ still holds %v", entries)
	}
}

func TestRejectsBadRecipes(t *testing.T) {
	srv, _ := newServer(t)
	cases := map[string]string{
		"bad id":        strings.Replace(recipeJSON, id, "../../etc/passwd", 1),
		"missing steps": strings.Replace(recipeJSON, `"steps":["Cook the rice."],`, "", 1),
		"unknown field": strings.Replace(recipeJSON, `"forkedFrom":null`, `"forkedFrom":null,"response":"hi"`, 1),
		"not json":      "rice",
		"two values":    recipeJSON + recipeJSON,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			status, resBody := do(t, srv, "POST", "/api/recipes", body)
			expect(t, status, resBody, http.StatusBadRequest)
		})
	}
}

func TestPutRecipe(t *testing.T) {
	srv, _ := newServer(t)

	status, body := do(t, srv, "PUT", "/api/recipes/"+id, recipeJSON)
	expect(t, status, body, http.StatusNotFound)

	do(t, srv, "POST", "/api/recipes", recipeJSON)
	other := "2026-09-16T14-05-33-other"
	status, body = do(t, srv, "PUT", "/api/recipes/"+other, recipeJSON)
	expect(t, status, body, http.StatusBadRequest)

	status, body = do(t, srv, "GET", "/api/recipes/..%2Fstock", "")
	expect(t, status, body, http.StatusNotFound)
}

func TestListSkipsBadFiles(t *testing.T) {
	srv, dir := newServer(t)
	do(t, srv, "POST", "/api/recipes", recipeJSON)
	recipes := filepath.Join(dir, "recipes")
	os.WriteFile(filepath.Join(recipes, "2026-09-17T00-00-00-broken.json"), []byte("{"), 0o600)
	os.WriteFile(filepath.Join(recipes, "2026-09-17T00-00-00-wrong-id.json"), []byte(recipeJSON), 0o600)
	os.WriteFile(filepath.Join(recipes, "notes.txt"), []byte("hi"), 0o600)

	status, body := do(t, srv, "GET", "/api/recipes", "")
	expect(t, status, body, http.StatusOK)
	var list []Recipe
	json.Unmarshal([]byte(body), &list)
	if len(list) != 1 || list[0].ID != id {
		t.Fatalf("list %+v, want just %s", list, id)
	}
}

func TestStatic(t *testing.T) {
	srv, _ := newServer(t)

	res, err := srv.Client().Get(srv.URL + "/manifest.webmanifest")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if ct := res.Header.Get("Content-Type"); ct != "application/manifest+json" {
		t.Fatalf("manifest Content-Type %q", ct)
	}

	status, body := do(t, srv, "GET", "/", "")
	expect(t, status, body, http.StatusOK)

	status, body = do(t, srv, "GET", "/api/nope", "")
	expect(t, status, body, http.StatusNotFound)
}
