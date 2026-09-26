package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

// ServiceType is what the Mac app browses for.
const ServiceType = "_snapcast-src._tcp"

func main() {
	cfg := DefaultConfig()
	listen := flag.String("listen", ":4953", "TCP address sources connect to")
	fifo := flag.String("fifo", "/tmp/snapcast-relay/audio.fifo", "FIFO snapserver reads as a pipe:// source")
	flag.StringVar(&cfg.Format, "format", cfg.Format, "sampleformat sources must send; must match the snapserver source")
	flag.StringVar(&cfg.Token, "token", os.Getenv("SNAPSRC_TOKEN"), "shared secret sources must present (default $SNAPSRC_TOKEN); disables raw mode")
	flag.BoolVar(&cfg.AllowRaw, "allow-raw", cfg.AllowRaw, "accept raw PCM connections without a hello (snapcap | nc)")
	flag.DurationVar(&cfg.ReadTimeout, "read-timeout", cfg.ReadTimeout, "drop a source after this long without audio")
	host, _ := os.Hostname()
	mdnsName := flag.String("mdns-name", "Snapcast on "+host, "name advertised over mDNS")
	noMDNS := flag.Bool("no-mdns", false, "do not advertise over mDNS")
	flag.Parse()
	log.SetFlags(0) // journald timestamps it

	// Create the FIFO before binding the port. If the port is still taken (snapserver's
	// old tcp:// source during migration), this process exits and systemd retries — but
	// the FIFO already exists, so snapserver can open its pipe:// source meanwhile.
	if err := ensureFIFO(*fifo); err != nil {
		log.Fatalf("%v", err)
	}

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	log.Printf("listening on %s, writing %s as %s", ln.Addr(), *fifo, cfg.Format)

	r := NewRelay(cfg)
	stop := make(chan struct{})
	go r.RunSink(func() (io.WriteCloser, error) { return openFIFO(*fifo) }, stop)
	go r.Serve(ln)
	if !*noMDNS {
		go advertise(*mdnsName, port, cfg.Format, stop)
	}
	go logStats(r, stop)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	close(stop)
	_ = ln.Close()
	log.Printf("stopped")
}

// fifoWriter reopens when the FIFO is deleted or replaced underneath it, e.g. by a
// /tmp cleaner. Without this, the relay would write happily into an orphaned inode
// while snapserver opened the new path and heard nothing.
type fifoWriter struct {
	f       *os.File
	path    string
	ino     uint64
	checked time.Time
}

var errFIFOReplaced = fmt.Errorf("fifo replaced on disk")

func (w *fifoWriter) Write(b []byte) (int, error) {
	if time.Since(w.checked) > 5*time.Second {
		w.checked = time.Now()
		if ino, err := inode(w.path); err != nil || ino != w.ino {
			return 0, errFIFOReplaced
		}
	}
	return w.f.Write(b)
}

func (w *fifoWriter) Close() error { return w.f.Close() }

func ensureFIFO(path string) error {
	// The directory is ours and not world-writable, which matters: Linux's
	// fs.protected_fifos restricts opening another user's FIFO inside a sticky,
	// world-writable directory like /tmp itself, and snapserver runs as root.
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if fi, err := os.Stat(path); err == nil {
		if fi.Mode()&os.ModeNamedPipe == 0 {
			return fmt.Errorf("%s exists and is not a FIFO", path)
		}
		return nil
	}
	if err := syscall.Mkfifo(path, 0o644); err != nil {
		return fmt.Errorf("mkfifo %s: %w", path, err)
	}
	return nil
}

func openFIFO(path string) (io.WriteCloser, error) {
	if err := ensureFIFO(path); err != nil {
		return nil, err
	}
	// O_RDWR, not O_WRONLY: a write-only open blocks until a reader appears, and
	// writes fail with EPIPE whenever snapserver restarts. Holding both ends means the
	// open never blocks and snapserver can come and go freely.
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	ino, err := inode(path)
	if err != nil {
		f.Close()
		return nil, err
	}
	return &fifoWriter{f: f, path: path, ino: ino, checked: time.Now()}, nil
}

func inode(path string) (uint64, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return 0, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return 0, fmt.Errorf("no inode for %s", path)
	}
	return uint64(st.Ino), nil
}

// advertise publishes the relay via avahi's CLI rather than an mDNS library: the host
// already runs avahi-daemon (for shairport-sync), and a second responder on the same
// machine would fight it over port 5353.
func advertise(name string, port int, format string, stop <-chan struct{}) {
	bin, err := exec.LookPath("avahi-publish-service")
	if err != nil {
		log.Printf("mdns: avahi-publish-service not found, not advertising")
		return
	}
	for {
		cmd := exec.Command(bin, name, ServiceType, strconv.Itoa(port), "format="+format, "proto=1")
		if err := cmd.Start(); err != nil {
			log.Printf("mdns: %v", err)
		} else {
			log.Printf("mdns: advertising %q as %s", name, ServiceType)
			exited := make(chan error, 1)
			go func() { exited <- cmd.Wait() }()
			select {
			case <-stop:
				_ = cmd.Process.Kill()
				return
			case err := <-exited:
				log.Printf("mdns: publisher exited (%v), restarting", err)
			}
		}
		select {
		case <-stop:
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func logStats(r *Relay, stop <-chan struct{}) {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	var lastDropped uint64
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			_, dropped := r.Stats()
			if dropped > lastDropped {
				log.Printf("dropped %d bytes in the last minute: snapserver is not reading the FIFO", dropped-lastDropped)
				lastDropped = dropped
			}
		}
	}
}
