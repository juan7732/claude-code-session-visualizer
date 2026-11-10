package serve

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Watch keeps the archive current: it watches <claude>/projects and every
// project directory in it, and archives a session a little after its
// transcript stops changing. New project directories are picked up as they
// appear. It returns when ctx is done. The hooks installer on the roadmap is
// the lighter alternative; this needs nothing installed.
func (s *Server) Watch(ctx context.Context, projectsDir string, settle time.Duration) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	addAll := func() {
		_ = w.Add(projectsDir)
		entries, err := os.ReadDir(projectsDir)
		if err != nil {
			return
		}
		for _, e := range entries {
			if e.IsDir() {
				_ = w.Add(filepath.Join(projectsDir, e.Name()))
			}
		}
	}
	if err := os.MkdirAll(projectsDir, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
		return err
	}
	addAll()

	var mu sync.Mutex
	pending := map[string]*time.Timer{}
	schedule := func(path string) {
		mu.Lock()
		defer mu.Unlock()
		if t, ok := pending[path]; ok {
			t.Reset(settle)
			return
		}
		pending[path] = time.AfterFunc(settle, func() {
			mu.Lock()
			delete(pending, path)
			mu.Unlock()
			res, err := s.IngestPath(path)
			if err != nil {
				s.Logf("watch: %s: %v", filepath.Base(path), err)
				return
			}
			s.Logf("watch: %s %s (%d records)", res.Action, short(res.ID), res.Records)
		})
	}
	for {
		select {
		case <-ctx.Done():
			mu.Lock()
			for _, t := range pending {
				t.Stop()
			}
			mu.Unlock()
			return nil
		case ev, ok := <-w.Events:
			if !ok {
				return nil
			}
			if ev.Has(fsnotify.Create) {
				if st, err := os.Stat(ev.Name); err == nil && st.IsDir() && filepath.Dir(ev.Name) == projectsDir {
					_ = w.Add(ev.Name)
					continue
				}
			}
			if strings.HasSuffix(ev.Name, ".jsonl") && filepath.Dir(filepath.Dir(ev.Name)) == projectsDir && (ev.Has(fsnotify.Write) || ev.Has(fsnotify.Create)) {
				schedule(ev.Name)
			}
		case err, ok := <-w.Errors:
			if !ok {
				return nil
			}
			s.Logf("watch: %v", err)
		}
	}
}
