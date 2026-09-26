package main

// Automatic source selection: points Snapcast groups at whichever source started most
// recently, and back at the fallback (AirPlay) when the Macs stop.
//
//   - A Mac starts streaming         -> groups switch to the Mac stream.
//   - AirPlay starts playing         -> groups switch to AirPlay.
//   - The newer one stops            -> groups go back to the other, if still active.
//   - Nothing active                 -> groups go to the fallback, after a grace period.
//
// Only "managed" groups are touched: those currently on the Mac or fallback stream. A
// group you deliberately put on some third stream stays there. And the switcher only
// acts when its decision CHANGES, so moving a group by hand in Snapweb is never undone
// until something new actually starts or stops.
//
// The grace period is what keeps this invisible in practice: a Mac that reconnects
// after a WiFi blip, a relay restart, or a sleep/wake cycle is back well within it, so
// the speakers never flip to a silent AirPlay stream and back.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// decide returns the stream groups should be on, or "" to leave them alone.
func decide(now time.Time, st switchState, mac, fallback string, grace time.Duration) string {
	macActive := !st.macSince.IsZero()
	airActive := !st.airplaySince.IsZero()
	switch {
	case macActive && airActive:
		if st.airplaySince.After(st.macSince) {
			return fallback
		}
		return mac
	case macActive:
		return mac
	case airActive:
		return fallback
	case !st.macEndedAt.IsZero() && now.Sub(st.macEndedAt) < grace:
		return "" // a Mac just went away; give it the chance to come back
	default:
		return fallback
	}
}

type switchState struct {
	macSince     time.Time // zero when no Mac is streaming
	macEndedAt   time.Time
	lastMacSince time.Time // restored when a Mac comes back within the grace period
	airplaySince time.Time // zero when the fallback stream is idle
}

type Switcher struct {
	Addr           string // snapserver JSON-RPC, e.g. 127.0.0.1:1705
	MacStream      string
	FallbackStream string
	Grace          time.Duration

	mu      sync.Mutex
	state   switchState
	applied string
	kick    chan struct{}
	now     func() time.Time
}

func NewSwitcher(addr, mac, fallback string, grace time.Duration) *Switcher {
	w := &Switcher{
		Addr: addr, MacStream: mac, FallbackStream: fallback, Grace: grace,
		kick: make(chan struct{}, 1),
		now:  time.Now,
	}
	// Treat startup like a Mac that just left: a Mac that was streaming before a relay
	// restart reconnects within the grace period and nothing gets switched.
	w.state.macEndedAt = w.now()
	return w
}

// SetMacActive is wired to Relay.OnActiveChange.
func (w *Switcher) SetMacActive(active bool) {
	w.mu.Lock()
	now := w.now()
	switch {
	case active && w.state.macSince.IsZero():
		if !w.state.lastMacSince.IsZero() && now.Sub(w.state.macEndedAt) < w.Grace {
			w.state.macSince = w.state.lastMacSince // a reconnect, not a new start
		} else {
			w.state.macSince = now
		}
	case active:
		w.state.macSince = now // another Mac took over: that is a new start
	case !w.state.macSince.IsZero():
		w.state.lastMacSince = w.state.macSince
		w.state.macSince = time.Time{}
		w.state.macEndedAt = now
	}
	w.mu.Unlock()
	w.poke()
}

func (w *Switcher) setFallbackPlaying(playing bool) {
	w.mu.Lock()
	changed := false
	if playing && w.state.airplaySince.IsZero() {
		w.state.airplaySince = w.now()
		changed = true
	} else if !playing && !w.state.airplaySince.IsZero() {
		w.state.airplaySince = time.Time{}
		changed = true
	}
	w.mu.Unlock()
	if changed {
		w.poke()
	}
}

func (w *Switcher) poke() {
	select {
	case w.kick <- struct{}{}:
	default:
	}
}

// Run keeps a control connection to snapserver open until stop is closed.
func (w *Switcher) Run(stop <-chan struct{}) {
	failing := false
	for {
		err := w.session(stop)
		select {
		case <-stop:
			return
		default:
		}
		if !failing {
			log.Printf("switch: snapserver control %s: %v (retrying)", w.Addr, err)
			failing = true
		}
		select {
		case <-stop:
			return
		case <-time.After(5 * time.Second):
		}
	}
}

func (w *Switcher) session(stop <-chan struct{}) error {
	conn, err := net.DialTimeout("tcp", w.Addr, 3*time.Second)
	if err != nil {
		return err
	}
	rpc := newRPC(conn, func(method string, params json.RawMessage) {
		w.onNotification(method, params)
	})
	defer rpc.Close()

	status, err := rpc.status()
	if err != nil {
		return err
	}
	w.observeStreams(status.Server.Streams)
	log.Printf("switch: connected to snapserver; managing %q and %q", w.MacStream, w.FallbackStream)

	// A reconnect to snapserver must re-evaluate, since groups may have been changed
	// while we were away. Forgetting what was applied forces that.
	w.mu.Lock()
	w.applied = ""
	w.mu.Unlock()

	tick := time.NewTicker(time.Second) // lets the grace period expire on its own
	defer tick.Stop()
	for {
		if err := w.reconcile(rpc); err != nil {
			return err
		}
		select {
		case <-stop:
			return nil
		case <-rpc.done:
			return errors.New("connection closed")
		case <-w.kick:
		case <-tick.C:
		}
	}
}

func (w *Switcher) reconcile(rpc *rpcClient) error {
	w.mu.Lock()
	want := decide(w.now(), w.state, w.MacStream, w.FallbackStream, w.Grace)
	if want == "" || want == w.applied {
		w.mu.Unlock()
		return nil
	}
	w.mu.Unlock()

	status, err := rpc.status()
	if err != nil {
		return err
	}
	moved := 0
	for _, g := range status.Server.Groups {
		if g.StreamID == want || (g.StreamID != w.MacStream && g.StreamID != w.FallbackStream) {
			continue
		}
		if err := rpc.call("Group.SetStream", map[string]string{"id": g.ID, "stream_id": want}, nil); err != nil {
			return fmt.Errorf("Group.SetStream: %w", err)
		}
		moved++
	}
	log.Printf("switch: -> %q (%d group(s) moved)", want, moved)
	w.mu.Lock()
	w.applied = want
	w.mu.Unlock()
	return nil
}

func (w *Switcher) observeStreams(streams []snapStream) {
	for _, s := range streams {
		if s.ID == w.FallbackStream {
			w.setFallbackPlaying(s.Status == "playing")
		}
	}
}

func (w *Switcher) onNotification(method string, params json.RawMessage) {
	switch method {
	case "Stream.OnUpdate":
		var p struct {
			ID     string     `json:"id"`
			Stream snapStream `json:"stream"`
		}
		if json.Unmarshal(params, &p) == nil && p.ID == w.FallbackStream {
			w.setFallbackPlaying(p.Stream.Status == "playing")
		}
	case "Server.OnUpdate":
		var p struct {
			Server struct {
				Streams []snapStream `json:"streams"`
			} `json:"server"`
		}
		if json.Unmarshal(params, &p) == nil {
			w.observeStreams(p.Server.Streams)
		}
	}
}

// ---- minimal snapserver JSON-RPC client (newline-delimited, over TCP)

type snapStream struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

type snapStatus struct {
	Server struct {
		Groups []struct {
			ID       string `json:"id"`
			StreamID string `json:"stream_id"`
		} `json:"groups"`
		Streams []snapStream `json:"streams"`
	} `json:"server"`
}

type rpcMessage struct {
	ID     *int64          `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error,omitempty"`
}

type rpcClient struct {
	conn    net.Conn
	writeMu sync.Mutex
	nextID  atomic.Int64
	pending sync.Map // int64 -> chan rpcMessage
	done    chan struct{}
	once    sync.Once
}

func newRPC(conn net.Conn, notify func(string, json.RawMessage)) *rpcClient {
	c := &rpcClient{conn: conn, done: make(chan struct{})}
	go func() {
		defer c.Close()
		sc := bufio.NewScanner(conn)
		sc.Buffer(make([]byte, 64*1024), 8*1024*1024) // full status can be large
		for sc.Scan() {
			var m rpcMessage
			if json.Unmarshal(sc.Bytes(), &m) != nil {
				continue
			}
			if m.ID == nil {
				if m.Method != "" {
					notify(m.Method, m.Params)
				}
				continue
			}
			if ch, ok := c.pending.Load(*m.ID); ok {
				ch.(chan rpcMessage) <- m
			}
		}
	}()
	return c
}

func (c *rpcClient) Close() {
	c.once.Do(func() {
		close(c.done)
		_ = c.conn.Close()
	})
}

func (c *rpcClient) call(method string, params any, result any) error {
	id := c.nextID.Add(1)
	ch := make(chan rpcMessage, 1)
	c.pending.Store(id, ch)
	defer c.pending.Delete(id)

	req := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		req["params"] = params
	}
	b, _ := json.Marshal(req)
	c.writeMu.Lock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
	_, err := c.conn.Write(append(b, '\n'))
	c.writeMu.Unlock()
	if err != nil {
		return err
	}
	select {
	case m := <-ch:
		if m.Error != nil {
			return fmt.Errorf("%s: %s", method, m.Error.Message)
		}
		if result != nil {
			return json.Unmarshal(m.Result, result)
		}
		return nil
	case <-time.After(5 * time.Second):
		return fmt.Errorf("%s: timed out", method)
	case <-c.done:
		return errors.New("connection closed")
	}
}

func (c *rpcClient) status() (snapStatus, error) {
	var s snapStatus
	err := c.call("Server.GetStatus", nil, &s)
	return s, err
}
