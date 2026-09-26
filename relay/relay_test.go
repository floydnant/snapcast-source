package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// sink collects everything the relay forwards.
type sink struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (s *sink) Write(b []byte) (int, error) { s.mu.Lock(); defer s.mu.Unlock(); return s.buf.Write(b) }
func (s *sink) Close() error                { return nil }
func (s *sink) Bytes() []byte               { s.mu.Lock(); defer s.mu.Unlock(); return append([]byte(nil), s.buf.Bytes()...) }

func start(t *testing.T, mutate func(*Config)) (*Relay, *sink, string) {
	t.Helper()
	cfg := DefaultConfig()
	cfg.ReadTimeout = 300 * time.Millisecond
	cfg.PingInterval = 50 * time.Millisecond
	if mutate != nil {
		mutate(&cfg)
	}
	r := NewRelay(cfg)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	stop := make(chan struct{})
	s := &sink{}
	go r.RunSink(func() (io.WriteCloser, error) { return s, nil }, stop)
	go r.Serve(ln)
	t.Cleanup(func() { close(stop); ln.Close() })
	return r, s, ln.Addr().String()
}

type client struct {
	t    *testing.T
	conn net.Conn
	rd   *bufio.Reader
}

func dial(t *testing.T, addr string) *client {
	t.Helper()
	c, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return &client{t: t, conn: c, rd: bufio.NewReader(c)}
}

func (c *client) hello(h Hello) {
	c.t.Helper()
	b, _ := json.Marshal(h)
	if _, err := c.conn.Write(append([]byte(ProtocolMagic), append(b, '\n')...)); err != nil {
		c.t.Fatal(err)
	}
}

// next returns the next control message that is not a ping.
func (c *client) next() (Control, error) {
	for {
		_ = c.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		line, err := c.rd.ReadBytes('\n')
		if err != nil {
			return Control{}, err
		}
		var m Control
		if err := json.Unmarshal(line, &m); err != nil {
			c.t.Fatalf("bad control line %q: %v", line, err)
		}
		if m.Type != "ping" {
			return m, nil
		}
	}
}

func (c *client) expect(typ string) Control {
	c.t.Helper()
	m, err := c.next()
	if err != nil {
		c.t.Fatalf("waiting for %q: %v", typ, err)
	}
	if m.Type != typ {
		c.t.Fatalf("got %+v, want type %q", m, typ)
	}
	return m
}

func (c *client) send(b []byte) {
	c.t.Helper()
	if _, err := c.conn.Write(b); err != nil {
		c.t.Fatal(err)
	}
}

func pcm(n int, fill byte) []byte { return bytes.Repeat([]byte{fill}, n) }

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

func TestProtocolStreamIsForwarded(t *testing.T) {
	_, s, addr := start(t, nil)
	c := dial(t, addr)
	c.hello(Hello{Name: "Mac A", Format: "48000:16:2"})
	if w := c.expect("welcome"); w.Format != "48000:16:2" {
		t.Fatalf("welcome format = %q", w.Format)
	}
	c.send(pcm(4000, 1))
	eventually(t, "4000 bytes forwarded", func() bool { return len(s.Bytes()) == 4000 })
}

func TestOnlyWholeFramesAreForwarded(t *testing.T) {
	_, s, addr := start(t, nil)
	c := dial(t, addr)
	c.hello(Hello{Name: "Mac A", Format: "48000:16:2"})
	c.expect("welcome")

	// 4001 bytes: the trailing byte must be held back, then completed by the next 3.
	c.send(pcm(4001, 1))
	eventually(t, "4000 forwarded", func() bool { return len(s.Bytes()) == 4000 })
	c.send(pcm(3, 1))
	eventually(t, "4004 forwarded", func() bool { return len(s.Bytes()) == 4004 })

	// A partial frame at disconnect is discarded, never forwarded.
	c.send(pcm(2, 1))
	c.conn.Close()
	time.Sleep(100 * time.Millisecond)
	if n := len(s.Bytes()); n%frameBytes != 0 || n != 4004 {
		t.Fatalf("forwarded %d bytes after partial-frame disconnect, want 4004", n)
	}
}

func TestNewestSourceTakesOver(t *testing.T) {
	r, s, addr := start(t, nil)
	a := dial(t, addr)
	a.hello(Hello{Name: "Mac A", Format: "48000:16:2"})
	a.expect("welcome")
	a.send(pcm(400, 0xAA))
	eventually(t, "A forwarded", func() bool { return len(s.Bytes()) == 400 })

	b := dial(t, addr)
	b.hello(Hello{Name: "Mac B", Format: "48000:16:2"})
	b.expect("welcome")

	if m := a.expect("replaced"); m.By != "Mac B" {
		t.Fatalf("replaced by %q, want Mac B", m.By)
	}
	if _, err := a.next(); err == nil {
		t.Fatal("A's connection still open after being replaced")
	}
	if st := r.Status(); st.Active != "Mac B" {
		t.Fatalf("status active = %q, want Mac B", st.Active)
	}

	b.send(pcm(400, 0xBB))
	eventually(t, "B forwarded", func() bool { return len(s.Bytes()) == 800 })
	for i, v := range s.Bytes()[400:] {
		if v != 0xBB {
			t.Fatalf("byte %d after takeover = %#x, want only B's audio", 400+i, v)
		}
	}
}

func TestSilentSourceIsDropped(t *testing.T) {
	r, _, addr := start(t, nil)
	c := dial(t, addr)
	c.hello(Hello{Name: "Mac A", Format: "48000:16:2"})
	c.expect("welcome")
	if r.Status().Active != "Mac A" {
		t.Fatal("not active after welcome")
	}
	// Stop sending, as a sleeping Mac would. The relay must free the slot on its own.
	eventually(t, "silent source released", func() bool { return r.Status().Active == "" })
}

func TestRawModeForSnapcapPipe(t *testing.T) {
	r, s, addr := start(t, nil)
	c := dial(t, addr)
	c.send(pcm(800, 7))
	eventually(t, "raw audio forwarded", func() bool { return len(s.Bytes()) == 800 })
	if a := r.Status().Active; a == "" {
		t.Fatal("raw source not reported as active")
	}
}

func TestRawModeRefusedWhenTokenSet(t *testing.T) {
	_, s, addr := start(t, func(c *Config) { c.Token = "secret" })
	c := dial(t, addr)
	c.send(pcm(800, 7))
	time.Sleep(150 * time.Millisecond)
	if n := len(s.Bytes()); n != 0 {
		t.Fatalf("forwarded %d raw bytes despite token", n)
	}
}

func TestBadTokenAndFormatAreRefused(t *testing.T) {
	_, _, addr := start(t, func(c *Config) { c.Token = "secret" })

	c := dial(t, addr)
	c.hello(Hello{Name: "Mac A", Format: "48000:16:2", Token: "wrong"})
	if m := c.expect("error"); m.Reason != "bad token" {
		t.Fatalf("reason = %q", m.Reason)
	}

	d := dial(t, addr)
	d.hello(Hello{Name: "Mac A", Format: "44100:16:2", Token: "secret"})
	d.expect("error")

	e := dial(t, addr)
	e.hello(Hello{Name: "Mac A", Format: "48000:16:2", Token: "secret"})
	e.expect("welcome")
}

func TestStatusQuery(t *testing.T) {
	_, _, addr := start(t, nil)
	a := dial(t, addr)
	a.hello(Hello{Name: "Mac A", Format: "48000:16:2"})
	a.expect("welcome")

	q := dial(t, addr)
	q.hello(Hello{Mode: "status"})
	m := q.expect("status")
	if m.Active != "Mac A" || m.Since == 0 {
		t.Fatalf("status = %+v", m)
	}
	// A status query must not displace the streaming source.
	a.send(pcm(4, 1))
	time.Sleep(50 * time.Millisecond)
	q2 := dial(t, addr)
	q2.hello(Hello{Mode: "status"})
	if m := q2.expect("status"); m.Active != "Mac A" {
		t.Fatalf("status after query = %+v", m)
	}
}

func TestSinkStallDropsInsteadOfBlocking(t *testing.T) {
	cfg := DefaultConfig()
	cfg.QueueChunks = 1
	r := NewRelay(cfg)
	// No sink running at all: forward must never block.
	done := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			r.forward(pcm(4, 0))
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("forward blocked on a stalled sink")
	}
	if _, dropped := r.Stats(); dropped == 0 {
		t.Fatal("expected drops with a stalled sink")
	}
}
