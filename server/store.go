package server

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
)

// Recipe is a saved recipe, in the same flat shape the frontend stores in
// localStorage (`clerk.recipes`, see SavedRecipe.elm). Timestamps are Unix
// milliseconds.
type Recipe struct {
	ID          string      `json:"id"`
	Title       string      `json:"title"`
	Ingredients []string    `json:"ingredients"`
	Steps       []string    `json:"steps"`
	CreatedAt   int64       `json:"createdAt"`
	UpdatedAt   int64       `json:"updatedAt"`
	ForkedFrom  *ForkOrigin `json:"forkedFrom"`
}

// ForkOrigin is a snapshot of the recipe another was forked from, not a
// reference: the original may since have been deleted.
type ForkOrigin struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

var (
	ErrNotFound = errors.New("not found")
	ErrExists   = errors.New("already exists")
)

// idPattern is SavedRecipe.new's id: a UTC datetime with colons as dashes,
// then the title's slug. Ids become file names, so nothing else is accepted.
var idPattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-[a-z0-9]+(-[a-z0-9]+)*$`)

// ValidID reports whether id is a well-formed recipe id.
func ValidID(id string) bool {
	return len(id) <= 200 && idPattern.MatchString(id)
}

// Validate checks what the frontend's decoder requires, so the server never
// stores a recipe the frontend would drop.
func (r Recipe) Validate() error {
	switch {
	case !ValidID(r.ID):
		return fmt.Errorf("invalid id %q", r.ID)
	case r.Ingredients == nil:
		return errors.New("missing ingredients")
	case r.Steps == nil:
		return errors.New("missing steps")
	case r.CreatedAt <= 0:
		return errors.New("missing createdAt")
	case r.UpdatedAt <= 0:
		return errors.New("missing updatedAt")
	}
	return nil
}

// Store keeps the stock and saved recipes as plain files under one directory,
// hand-editable when self-hosting:
//
//	stock.txt
//	recipes/{id}.json
//
// Every write goes to a temporary file that is synced and then renamed over
// the target, so a crash leaves either the old file or the new one.
type Store struct {
	dir string
	mu  sync.Mutex // serializes writes, so create and update can check first
}

// Open creates the directory layout if needed.
func Open(dir string) (*Store, error) {
	if err := os.MkdirAll(filepath.Join(dir, "recipes"), 0o700); err != nil {
		return nil, err
	}
	return &Store{dir: dir}, nil
}

func (s *Store) stockPath() string {
	return filepath.Join(s.dir, "stock.txt")
}

func (s *Store) recipePath(id string) string {
	return filepath.Join(s.dir, "recipes", id+".json")
}

// Stock is the stock list, empty if none has been saved.
func (s *Store) Stock() (string, error) {
	data, err := os.ReadFile(s.stockPath())
	if errors.Is(err, fs.ErrNotExist) {
		return "", nil
	}
	return string(data), err
}

func (s *Store) SetStock(stock string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return writeFileAtomic(s.stockPath(), []byte(stock))
}

// Recipes is every saved recipe in full, oldest first (ids start with their
// creation time), like the `recipes` flag the frontend loads at startup. A file that doesn't read as a valid recipe is logged and
// skipped rather than failing the whole list, like the frontend's decoder.
func (s *Store) Recipes() ([]Recipe, error) {
	entries, err := os.ReadDir(filepath.Join(s.dir, "recipes"))
	if err != nil {
		return nil, err
	}
	recipes := []Recipe{}
	for _, entry := range entries {
		id, ok := strings.CutSuffix(entry.Name(), ".json")
		if !ok || !entry.Type().IsRegular() || !ValidID(id) {
			continue
		}
		r, err := s.Recipe(id)
		if err != nil {
			log.Printf("skipping recipe %s: %v", entry.Name(), err)
			continue
		}
		recipes = append(recipes, r)
	}
	return recipes, nil
}

func (s *Store) Recipe(id string) (Recipe, error) {
	if !ValidID(id) {
		return Recipe{}, ErrNotFound
	}
	data, err := os.ReadFile(s.recipePath(id))
	if errors.Is(err, fs.ErrNotExist) {
		return Recipe{}, ErrNotFound
	} else if err != nil {
		return Recipe{}, err
	}
	var r Recipe
	if err := json.Unmarshal(data, &r); err != nil {
		return Recipe{}, err
	}
	if r.ID != id {
		return Recipe{}, fmt.Errorf("file holds id %q", r.ID)
	}
	if err := r.Validate(); err != nil {
		return Recipe{}, err
	}
	return r, nil
}

// CreateRecipe saves a new recipe under its own (client-made) id.
func (s *Store) CreateRecipe(r Recipe) error {
	return s.writeRecipe(r, false)
}

// UpdateRecipe overwrites an existing recipe.
func (s *Store) UpdateRecipe(r Recipe) error {
	return s.writeRecipe(r, true)
}

func (s *Store) writeRecipe(r Recipe, mustExist bool) error {
	if err := r.Validate(); err != nil {
		return err
	}
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	path := s.recipePath(r.ID)
	_, err = os.Stat(path)
	exists := err == nil
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if mustExist && !exists {
		return ErrNotFound
	}
	if !mustExist && exists {
		return ErrExists
	}
	return writeFileAtomic(path, append(data, '\n'))
}

func (s *Store) DeleteRecipe(id string) error {
	if !ValidID(id) {
		return ErrNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	err := os.Remove(s.recipePath(id))
	if errors.Is(err, fs.ErrNotExist) {
		return ErrNotFound
	} else if err != nil {
		return err
	}
	return syncDir(filepath.Join(s.dir, "recipes"))
}

// writeFileAtomic replaces path's contents durably: temp file, fsync, rename,
// then fsync the directory so the rename itself survives a crash. The temp
// file starts with a dot, so the recipe list never sees it.
func writeFileAtomic(path string, data []byte) (err error) {
	dir := filepath.Dir(path)
	f, err := os.CreateTemp(dir, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			f.Close()
			os.Remove(f.Name())
		}
	}()
	if _, err = f.Write(data); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if err = os.Rename(f.Name(), path); err != nil {
		return err
	}
	return syncDir(dir)
}

func syncDir(dir string) error {
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer d.Close()
	return d.Sync()
}
