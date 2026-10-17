package history

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// DirStore keeps blobs as files named by their key in one directory. relayd
// uses it for local segments and historyd for remote ones.
type DirStore struct {
	dir string

	// mu makes a replace's size accounting and rename one step.
	mu    sync.Mutex
	usage int64 // bytes in blob files: measured at open, then kept current
}

const tempPrefix = "tmp-"

// OpenDir creates dir (0700) if needed and measures what it holds.
func OpenDir(dir string) (*DirStore, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	d := &DirStore{dir: dir}
	list, err := d.List()
	if err != nil {
		return nil, err
	}
	for _, b := range list {
		if info, err := os.Stat(filepath.Join(dir, b.Key)); err == nil {
			d.usage += info.Size()
		}
	}
	return d, nil
}

// Dir is the directory the blobs live in.
func (d *DirStore) Dir() string { return d.dir }

// Usage is the bytes stored.
func (d *DirStore) Usage() int64 {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.usage
}

// Size returns a blob's size, or 0 if it doesn't exist.
func (d *DirStore) Size(key string) int64 {
	if !ValidKey(key) {
		return 0
	}
	info, err := os.Stat(filepath.Join(d.dir, key))
	if err != nil {
		return 0
	}
	return info.Size()
}

// Put writes data under key atomically (temp file, fsync, rename), so a
// reader never sees a partial blob and a replace never loses the old one to a
// crash halfway through.
func (d *DirStore) Put(key string, data []byte) error {
	if !ValidKey(key) {
		return errors.New("history: invalid blob key")
	}
	tmp, err := os.CreateTemp(d.dir, tempPrefix+"*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name()) // no-op after the rename
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	path := filepath.Join(d.dir, key)
	d.mu.Lock()
	defer d.mu.Unlock()
	var old int64
	if info, err := os.Stat(path); err == nil {
		old = info.Size()
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		return err
	}
	d.usage += int64(len(data)) - old
	return nil
}

func (d *DirStore) Get(key string) ([]byte, error) {
	if !ValidKey(key) {
		return nil, ErrNotFound
	}
	data, err := os.ReadFile(filepath.Join(d.dir, key))
	if errors.Is(err, os.ErrNotExist) {
		return nil, ErrNotFound
	}
	return data, err
}

// Delete removes a blob; a missing one is not an error.
func (d *DirStore) Delete(key string) error {
	if !ValidKey(key) {
		return nil
	}
	path := filepath.Join(d.dir, key)
	d.mu.Lock()
	defer d.mu.Unlock()
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	d.usage -= info.Size()
	return nil
}

// List returns every blob with its modification time.
func (d *DirStore) List() ([]BlobInfo, error) {
	entries, err := os.ReadDir(d.dir)
	if err != nil {
		return nil, err
	}
	out := make([]BlobInfo, 0, len(entries))
	for _, e := range entries {
		if !ValidKey(e.Name()) {
			continue
		}
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		out = append(out, BlobInfo{Key: e.Name(), Modified: info.ModTime().Unix()})
	}
	return out, nil
}

// CleanTemp removes temp files older than age, left by a crash mid-write.
func (d *DirStore) CleanTemp(age time.Duration) {
	entries, err := os.ReadDir(d.dir)
	if err != nil {
		return
	}
	cutoff := time.Now().Add(-age)
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), tempPrefix) {
			continue
		}
		if info, err := e.Info(); err == nil && info.ModTime().Before(cutoff) {
			os.Remove(filepath.Join(d.dir, e.Name()))
		}
	}
}
