package main

import (
	"errors"
	"net"
	"os"
	"strings"
	"testing"
)

func TestCLIRefusesSocketAnotherUserServes(t *testing.T) {
	for _, test := range []struct {
		name    string
		lookup  func(net.Conn) (uint32, error)
		allowed bool
	}{
		{name: "native same user", allowed: true},
		{name: "another user", lookup: func(net.Conn) (uint32, error) { return uint32(os.Geteuid()) + 1, nil }},
		{name: "credential lookup failure", lookup: func(net.Conn) (uint32, error) { return uint32(os.Geteuid()), errors.New("lookup failed") }},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.lookup != nil {
				previous := cliSocketPeerUserID
				cliSocketPeerUserID = test.lookup
				t.Cleanup(func() { cliSocketPeerUserID = previous })
			}
			path, requests := startMockV2SocketWithRequestCapture(t)
			_, err := socketRoundTripV2(path, "system.ping", nil, nil)
			if test.allowed {
				if err != nil {
					t.Fatalf("same-user request failed: %v", err)
				}
				receiveRequest(t, requests)
				return
			}
			if err == nil {
				t.Fatal("CLI sent a request to a socket another user serves")
			}
			if test.name == "another user" && strings.Contains(err.Error(), "uid") {
				t.Fatalf("peer UID leaked in user-facing error: %v", err)
			}
			select {
			case request := <-requests:
				t.Fatalf("request reached a socket another user serves: %v", request)
			default:
			}
		})
	}
}
