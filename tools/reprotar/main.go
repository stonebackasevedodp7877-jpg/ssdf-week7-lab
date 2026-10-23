// Command reprotar writes a deterministic .tar.gz release archive.
//
// Host tar/gzip are hidden build inputs: GNU tar and macOS bsdtar store
// different headers, gzip stores a timestamp, and entry order follows the
// filesystem. reprotar removes the machine from the archive (SSDF PO.3.2):
//
//   - entries sorted by name, under one top-level directory
//   - every mtime set to SOURCE_DATE_EPOCH (the commit time)
//   - owner/group 0/0 with empty user/group names
//   - modes normalized to 0755 (directories, executables) or 0644
//   - USTAR headers only (no atime/ctime, no PAX extended records)
//   - gzip header without file name or timestamp
//
// It uses only the Go standard library, so its output depends only on the
// pinned Go toolchain - the same bytes on Linux, macOS and CI.
//
// Usage: reprotar -o OUT.tar.gz -mtime EPOCH -dir NAME FILE...
package main

import (
	"archive/tar"
	"compress/gzip"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"sort"
	"time"
)

func main() {
	out := flag.String("o", "", "output .tar.gz path")
	epoch := flag.Int64("mtime", -1, "SOURCE_DATE_EPOCH used for every entry")
	dir := flag.String("dir", "", "top-level directory name inside the archive")
	flag.Parse()
	if *out == "" || *epoch < 0 || *dir == "" || flag.NArg() == 0 {
		fmt.Fprintln(os.Stderr, "usage: reprotar -o OUT.tar.gz -mtime EPOCH -dir NAME FILE...")
		os.Exit(2)
	}
	if err := write(*out, time.Unix(*epoch, 0).UTC(), *dir, flag.Args()); err != nil {
		fmt.Fprintln(os.Stderr, "reprotar:", err)
		os.Exit(1)
	}
}

func write(out string, mtime time.Time, dir string, files []string) error {
	sort.Slice(files, func(i, j int) bool { return filepath.Base(files[i]) < filepath.Base(files[j]) })

	f, err := os.Create(out)
	if err != nil {
		return err
	}
	defer f.Close()

	gz, err := gzip.NewWriterLevel(f, gzip.BestCompression)
	if err != nil {
		return err
	}
	// gzip.Header left zero: no Name, ModTime = 0, OS = 255 (unknown).
	tw := tar.NewWriter(gz)

	hdr := func(name string, mode int64, size int64, typ byte) *tar.Header {
		return &tar.Header{
			Typeflag: typ, Name: name, Mode: mode, Size: size,
			ModTime: mtime, Uid: 0, Gid: 0, Uname: "", Gname: "",
			Format: tar.FormatUSTAR,
		}
	}
	if err := tw.WriteHeader(hdr(dir+"/", 0o755, 0, tar.TypeDir)); err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, p := range files {
		st, err := os.Stat(p)
		if err != nil {
			return err
		}
		if !st.Mode().IsRegular() {
			return fmt.Errorf("%s: not a regular file", p)
		}
		name := filepath.Base(p)
		if seen[name] {
			return fmt.Errorf("duplicate entry %s", name)
		}
		seen[name] = true
		mode := int64(0o644)
		if st.Mode().Perm()&0o111 != 0 {
			mode = 0o755
		}
		if err := tw.WriteHeader(hdr(path.Join(dir, name), mode, st.Size(), tar.TypeReg)); err != nil {
			return err
		}
		src, err := os.Open(p)
		if err != nil {
			return err
		}
		_, err = io.Copy(tw, src)
		src.Close()
		if err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	return f.Close()
}
