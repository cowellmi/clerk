// Command clerk is the self-host server: one binary serving the frontend and
// file storage for the stock and saved recipes.
//
// There is no authentication yet, so it listens on localhost by default. Only
// bind it to a wider interface on a network you control (clerk.md §2.2).
package main

import (
	"context"
	"errors"
	"flag"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"git.cowell.dev/clerk"
	"git.cowell.dev/clerk/server"
)

func main() {
	addr := flag.String("addr", "localhost:8080", "address to listen on")
	dataDir := flag.String("data", "data", "directory for stock.txt and recipes/")
	staticDir := flag.String("static", "", "serve the frontend from this directory instead of the embedded copy (for development, e.g. public)")
	flag.Parse()

	store, err := server.Open(*dataDir)
	if err != nil {
		log.Fatalf("opening data directory: %v", err)
	}

	var static fs.FS = clerk.Public()
	if *staticDir != "" {
		static = os.DirFS(*staticDir)
	}

	srv := &http.Server{
		Addr:              *addr,
		Handler:           server.New(store, static),
		ReadHeaderTimeout: 10 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	// ListenAndServe returns as soon as Shutdown starts, so wait for Shutdown
	// to let in-flight requests (writes, say) finish before exiting.
	shutDown := make(chan struct{})
	go func() {
		defer close(shutDown)
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			log.Printf("shutting down: %v", err)
		}
	}()

	log.Printf("clerk listening on http://%s, data in %s", *addr, *dataDir)
	if err := srv.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
	<-shutDown
}
