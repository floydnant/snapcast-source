package main

// Wire protocol, v1.
//
// A client opens one TCP connection and does exactly one of:
//
//   - Protocol mode: sends the 8-byte magic "SNAPSRC1", one JSON hello line, then raw
//     PCM in the relay's format (s16le interleaved) until it disconnects. The relay
//     answers with newline-delimited JSON control messages: "welcome" once, "ping"
//     every PingInterval, "replaced" when another client takes over, "error" before
//     refusing. Clients treat missing pings as a dead relay and reconnect.
//
//   - Status mode: magic, then a hello with "mode":"status". The relay answers with a
//     single "status" message naming the active source, and closes.
//
//   - Raw mode: sends PCM from the first byte, as `snapcap | nc relay 4953` does. No
//     control messages, since nobody on the other end would read them.
//
// Only one source streams at a time and the newest connection wins. That is the whole
// multi-Mac story: no configuration per Mac, and a Mac that went away without closing
// its socket never blocks the next one — the failure snapserver's own tcp:// source
// has, where one half-open socket wedges the stream until snapserver is restarted.

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

const (
	ProtocolMagic = "SNAPSRC1"

	// s16le stereo. Only whole frames are ever forwarded, so a client that disconnects
	// mid-frame cannot leave the next client's audio misaligned by a byte, which would
	// come out as full-scale noise with the channels swapped.
	frameBytes    = 4
	maxHelloBytes = 4096
)

type Hello struct {
	Mode   string `json:"mode,omitempty"`
	Name   string `json:"name"`
	Format string `json:"format,omitempty"`
	Token  string `json:"token,omitempty"`
}

type Control struct {
	Type   string `json:"type"`
	By     string `json:"by,omitempty"`
	Reason string `json:"reason,omitempty"`
	Active string `json:"active,omitempty"`
	Since  int64  `json:"since,omitempty"`
	Format string `json:"format,omitempty"`
}

type Config struct {
	Format   string
	Token    string
	AllowRaw bool

	// Sources send continuous PCM (silence included), so a quiet socket means the
	// source is gone — asleep, off WiFi, or crashed without closing.
	ReadTimeout  time.Duration
	HelloTimeout time.Duration
	PingInterval time.Duration

	// Chunks buffered between network reads and the sink. When the sink stalls
	// (snapserver stopped), newest audio is dropped rather than blocking the reader.
	QueueChunks int
}

func DefaultConfig() Config {
	return Config{
		Format:       "48000:16:2",
		AllowRaw:     true,
		ReadTimeout:  3 * time.Second,
		HelloTimeout: 5 * time.Second,
		PingInterval: time.Second,
		QueueChunks:  256,
	}
}

type Relay struct {
	cfg Config

	mu      sync.Mutex
	current *session

	nextID    atomic.Uint64
	audio     chan []byte
	forwarded atomic.Uint64
	dropped   atomic.Uint64
}

func NewRelay(cfg Config) *Relay {
	return &Relay{cfg: cfg, audio: make(chan []byte, cfg.QueueChunks)}
}

type session struct {
	id      uint64
	name    string
	remote  string
	conn    net.Conn
	started time.Time
	raw     bool

	writeMu   sync.Mutex
	closeOnce sync.Once
	done      chan struct{}
}

func (s *session) String() string { return fmt.Sprintf("#%d %q (%s)", s.id, s.name, s.remote) }

func (s *session) send(m Control) error {
	if s.raw {
		return nil
	}
	b, _ := json.Marshal(m)
	b = append(b, '\n')
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	_, err := s.conn.Write(b)
	return err
}

func (s *session) close() {
	s.closeOnce.Do(func() {
		close(s.done)
		_ = s.conn.Close()
	})
}

// Serve accepts connections until ln is closed.
func (r *Relay) Serve(ln net.Listener) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			log.Printf("accept: %v", err)
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go r.handle(c)
	}
}

// RunSink drains audio into writers from open, reopening whenever a write fails,
// until stop is closed.
func (r *Relay) RunSink(open func() (io.WriteCloser, error), stop <-chan struct{}) {
	for {
		w, err := open()
		if err != nil {
			log.Printf("sink: %v (retrying)", err)
			select {
			case <-stop:
				return
			case <-time.After(2 * time.Second):
				continue
			}
		}
		keepGoing := r.drain(w, stop)
		_ = w.Close()
		if !keepGoing {
			return
		}
	}
}

func (r *Relay) drain(w io.Writer, stop <-chan struct{}) bool {
	for {
		select {
		case <-stop:
			return false
		case b := <-r.audio:
			if _, err := w.Write(b); err != nil {
				log.Printf("sink write: %v (reopening)", err)
				return true
			}
		}
	}
}

func (r *Relay) Status() Control {
	r.mu.Lock()
	defer r.mu.Unlock()
	m := Control{Type: "status", Format: r.cfg.Format}
	if c := r.current; c != nil {
		m.Active = c.name
		m.Since = c.started.Unix()
	}
	return m
}

func (r *Relay) Stats() (forwarded, dropped uint64) {
	return r.forwarded.Load(), r.dropped.Load()
}

func (r *Relay) claim(s *session) {
	r.mu.Lock()
	prev := r.current
	r.current = s
	r.mu.Unlock()
	if prev != nil {
		log.Printf("%v replaced by %v", prev, s)
		_ = prev.send(Control{Type: "replaced", By: s.name})
		prev.close()
	}
	log.Printf("%v streaming", s)
}

func (r *Relay) release(s *session, reason string) {
	r.mu.Lock()
	wasCurrent := r.current == s
	if wasCurrent {
		r.current = nil
	}
	r.mu.Unlock()
	if wasCurrent {
		log.Printf("%v ended: %s", s, reason)
	}
}

func (r *Relay) isCurrent(s *session) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.current == s
}

func (r *Relay) forward(b []byte) {
	select {
	case r.audio <- b:
		r.forwarded.Add(uint64(len(b)))
	default:
		r.dropped.Add(uint64(len(b)))
	}
}

func refuse(c net.Conn, reason string) {
	b, _ := json.Marshal(Control{Type: "error", Reason: reason})
	_ = c.SetWriteDeadline(time.Now().Add(time.Second))
	_, _ = c.Write(append(b, '\n'))
	_ = c.Close()
	log.Printf("refused %s: %s", c.RemoteAddr(), reason)
}

func (r *Relay) handle(c net.Conn) {
	remote := c.RemoteAddr().String()
	if tc, ok := c.(*net.TCPConn); ok {
		// Belt and braces under the read timeout: lets the kernel reap a peer that
		// vanished even while we are blocked writing control messages to it.
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(5 * time.Second)
		_ = tc.SetNoDelay(true)
	}

	br := bufio.NewReaderSize(c, 64*1024)
	_ = c.SetReadDeadline(time.Now().Add(r.cfg.HelloTimeout))
	head, err := br.Peek(len(ProtocolMagic))
	if err != nil {
		_ = c.Close()
		return
	}

	s := &session{
		id:      r.nextID.Add(1),
		remote:  remote,
		conn:    c,
		started: time.Now(),
		done:    make(chan struct{}),
	}

	if string(head) == ProtocolMagic {
		_, _ = br.Discard(len(ProtocolMagic))
		line, err := readLine(br, maxHelloBytes)
		if err != nil {
			refuse(c, "bad hello: "+err.Error())
			return
		}
		var h Hello
		if err := json.Unmarshal(line, &h); err != nil {
			refuse(c, "bad hello json")
			return
		}
		if r.cfg.Token != "" && h.Token != r.cfg.Token {
			refuse(c, "bad token")
			return
		}
		if h.Mode == "status" {
			b, _ := json.Marshal(r.Status())
			_ = c.SetWriteDeadline(time.Now().Add(time.Second))
			_, _ = c.Write(append(b, '\n'))
			_ = c.Close()
			return
		}
		if h.Format != r.cfg.Format {
			refuse(c, fmt.Sprintf("format %q not supported, relay expects %q", h.Format, r.cfg.Format))
			return
		}
		s.name = h.Name
		if s.name == "" {
			s.name = remote
		}
	} else {
		// A token is pointless if raw mode lets anyone in without one.
		if !r.cfg.AllowRaw || r.cfg.Token != "" {
			_ = c.Close()
			log.Printf("refused raw connection from %s", remote)
			return
		}
		s.raw = true
		s.name = "raw " + remote
	}

	r.claim(s)
	defer s.close()

	if err := s.send(Control{Type: "welcome", Format: r.cfg.Format}); err != nil {
		r.release(s, "welcome failed: "+err.Error())
		return
	}
	if !s.raw {
		go r.ping(s)
	}
	r.release(s, r.pump(s, br))
}

func (r *Relay) ping(s *session) {
	t := time.NewTicker(r.cfg.PingInterval)
	defer t.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
			if err := s.send(Control{Type: "ping"}); err != nil {
				s.close()
				return
			}
		}
	}
}

// pump forwards whole frames until the source stops, and says why.
func (r *Relay) pump(s *session, rd io.Reader) string {
	buf := make([]byte, 16*1024)
	var carry []byte
	for {
		_ = s.conn.SetReadDeadline(time.Now().Add(r.cfg.ReadTimeout))
		n, err := rd.Read(buf)
		if n > 0 {
			data := append(carry, buf[:n]...)
			whole := len(data) - len(data)%frameBytes
			if whole > 0 && r.isCurrent(s) {
				out := make([]byte, whole)
				copy(out, data[:whole])
				r.forward(out)
			}
			carry = append(carry[:0:0], data[whole:]...)
		}
		if err != nil {
			select {
			case <-s.done:
				return "closed"
			default:
			}
			var ne net.Error
			switch {
			case errors.Is(err, io.EOF):
				return "disconnected"
			case errors.As(err, &ne) && ne.Timeout():
				return fmt.Sprintf("no audio for %v", r.cfg.ReadTimeout)
			default:
				return err.Error()
			}
		}
	}
}

func readLine(br *bufio.Reader, limit int) ([]byte, error) {
	var line []byte
	for {
		chunk, err := br.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > limit {
			return nil, errors.New("hello too long")
		}
		if err == nil {
			return bytes.TrimRight(line, "\r\n"), nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

