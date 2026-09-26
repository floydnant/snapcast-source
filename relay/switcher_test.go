package main

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"
)

func TestDecide(t *testing.T) {
	t0 := time.Unix(1000, 0)
	grace := 8 * time.Second
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	cases := []struct {
		name string
		now  time.Time
		st   switchState
		want string
	}{
		{"nothing active, long ago", at(100), switchState{macEndedAt: at(0)}, "AirPlay"},
		{"nothing active, Mac just left", at(3), switchState{macEndedAt: at(0)}, ""},
		{"Mac only", at(5), switchState{macSince: at(1)}, "Mac"},
		{"AirPlay only", at(5), switchState{airplaySince: at(1)}, "AirPlay"},
		{"AirPlay started after Mac", at(9), switchState{macSince: at(1), airplaySince: at(5)}, "AirPlay"},
		{"Mac started after AirPlay", at(9), switchState{macSince: at(5), airplaySince: at(1)}, "Mac"},
		{"AirPlay wins even inside Mac's grace", at(2), switchState{macEndedAt: at(0), airplaySince: at(1)}, "AirPlay"},
	}
	for _, c := range cases {
		if got := decide(c.now, c.st, "Mac", "AirPlay", grace); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

func TestReconnectWithinGraceKeepsOriginalStart(t *testing.T) {
	now := time.Unix(1000, 0)
	w := NewSwitcher("", "Mac", "AirPlay", 8*time.Second)
	w.now = func() time.Time { return now }

	w.SetMacActive(true)
	started := w.state.macSince
	now = now.Add(10 * time.Second)
	w.setFallbackPlaying(true) // someone AirPlays; they are now the newest
	now = now.Add(time.Second)
	w.SetMacActive(false) // the Mac's WiFi blips...
	now = now.Add(2 * time.Second)
	w.SetMacActive(true) // ...and it reconnects

	if !w.state.macSince.Equal(started) {
		t.Fatal("a reconnect must not count as a new start, or it would steal the speakers back from AirPlay")
	}
	if got := decide(now, w.state, "Mac", "AirPlay", w.Grace); got != "AirPlay" {
		t.Fatalf("after reconnect decide = %q, want AirPlay to keep the speakers", got)
	}
}

// ---- fake snapserver

type fakeSnap struct {
	t      *testing.T
	ln     net.Listener
	mu     sync.Mutex
	groups map[string]string // group id -> stream id
	status map[string]string // stream id -> status
	sets   []string          // "group=stream" in order
	conns  []net.Conn
}

func newFakeSnap(t *testing.T, groups map[string]string) *fakeSnap {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeSnap{t: t, ln: ln, groups: groups, status: map[string]string{"Mac": "idle", "AirPlay": "idle"}}
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			f.mu.Lock()
			f.conns = append(f.conns, c)
			f.mu.Unlock()
			go f.serve(c)
		}
	}()
	t.Cleanup(func() { ln.Close() })
	return f
}

func (f *fakeSnap) serve(c net.Conn) {
	sc := bufio.NewScanner(c)
	for sc.Scan() {
		var req struct {
			ID     int64             `json:"id"`
			Method string            `json:"method"`
			Params map[string]string `json:"params"`
		}
		if json.Unmarshal(sc.Bytes(), &req) != nil {
			continue
		}
		f.mu.Lock()
		var result any
		switch req.Method {
		case "Server.GetStatus":
			var gs []map[string]string
			for id, s := range f.groups {
				gs = append(gs, map[string]string{"id": id, "stream_id": s})
			}
			var ss []map[string]string
			for id, s := range f.status {
				ss = append(ss, map[string]string{"id": id, "status": s})
			}
			result = map[string]any{"server": map[string]any{"groups": gs, "streams": ss}}
		case "Group.SetStream":
			f.groups[req.Params["id"]] = req.Params["stream_id"]
			f.sets = append(f.sets, req.Params["id"]+"="+req.Params["stream_id"])
			result = map[string]string{"stream_id": req.Params["stream_id"]}
		}
		f.mu.Unlock()
		b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": result})
		c.Write(append(b, '\n'))
	}
}

func (f *fakeSnap) setStreamStatus(id, status string) {
	f.mu.Lock()
	f.status[id] = status
	conns := append([]net.Conn(nil), f.conns...)
	f.mu.Unlock()
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "method": "Stream.OnUpdate",
		"params": map[string]any{"id": id, "stream": map[string]string{"id": id, "status": status}}})
	for _, c := range conns {
		c.Write(append(b, '\n'))
	}
}

func (f *fakeSnap) group(id string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.groups[id]
}

func (f *fakeSnap) moveByHand(id, stream string) {
	f.mu.Lock()
	f.groups[id] = stream
	f.mu.Unlock()
}

func (f *fakeSnap) setCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.sets)
}

func TestSwitcherAgainstSnapserver(t *testing.T) {
	snap := newFakeSnap(t, map[string]string{"living": "AirPlay", "kitchen": "Mac", "office": "Radio"})
	w := NewSwitcher(snap.ln.Addr().String(), "Mac", "AirPlay", 300*time.Millisecond)
	stop := make(chan struct{})
	t.Cleanup(func() { close(stop) })
	go w.Run(stop)

	// Startup inside the grace period: nothing moves yet...
	time.Sleep(100 * time.Millisecond)
	if n := snap.setCount(); n != 0 {
		t.Fatalf("switched %d group(s) during startup grace", n)
	}
	// ...then, with no Mac back, managed groups settle on the fallback.
	eventually(t, "kitchen to AirPlay after grace", func() bool { return snap.group("kitchen") == "AirPlay" })

	w.SetMacActive(true)
	eventually(t, "managed groups to Mac", func() bool {
		return snap.group("living") == "Mac" && snap.group("kitchen") == "Mac"
	})
	if snap.group("office") != "Radio" {
		t.Fatal("a group on an unmanaged stream was moved")
	}

	snap.setStreamStatus("AirPlay", "playing")
	eventually(t, "AirPlay started last, wins", func() bool { return snap.group("living") == "AirPlay" })

	snap.setStreamStatus("AirPlay", "idle")
	eventually(t, "back to the still-streaming Mac", func() bool { return snap.group("living") == "Mac" })

	// A hand-made change is not undone while nothing starts or stops.
	snap.moveByHand("kitchen", "AirPlay")
	before := snap.setCount()
	time.Sleep(1500 * time.Millisecond) // well past a reconcile tick
	if snap.group("kitchen") != "AirPlay" || snap.setCount() != before {
		t.Fatal("switcher fought a manual change")
	}

	w.SetMacActive(false)
	eventually(t, "fallback after the Mac stops", func() bool { return snap.group("living") == "AirPlay" })
}
