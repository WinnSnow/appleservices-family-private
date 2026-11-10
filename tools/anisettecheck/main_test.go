package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/Laky-64/appleservices/anisette"
)

// TestAgainstAnisetteV3WireShape replays anisette-v3-server's documented
// responses (source/app.d: /v3/client_info and /v3/get_headers) and drives the
// real client package against them.
func TestAgainstAnisetteV3WireShape(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v3/client_info":
			fmt.Fprint(w, `{"client_info":"<MacBookPro15,1> <Mac OS X;13.1;22C65> <com.apple.AuthKit/1 (com.apple.akd/1.0)>","user_agent":"akd/1.0 CFNetwork/808.1.4"}`)
		case "/v3/get_headers":
			if r.Method != http.MethodPost {
				t.Errorf("get_headers must be POST, got %s", r.Method)
			}
			fmt.Fprint(w, `{"result":"Headers","X-Apple-I-MD":"bWQtdmFsdWU=","X-Apple-I-MD-M":"bWRtLXZhbHVl","X-Apple-I-MD-RINFO":"17106176"}`)
		default:
			t.Errorf("unexpected path %s", r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	// A seeded adi_pb skips the provisioning handshake, which by design talks to
	// Apple's albert endpoints; this test pins the two HTTP responses only.
	seeded := anisette.NewState()
	seeded.AdiPB = []byte("provisioned-blob")
	if err := run(server.URL, false, &seeded); err != nil {
		t.Fatal(err)
	}
}
