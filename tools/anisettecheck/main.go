// anisettecheck verifies a self-hosted anisette-v3 endpoint with the same
// client the login flow uses. It proves the server returns Apple-shaped
// device headers before any Apple ID is involved.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/Laky-64/appleservices/anisette"
)

func main() {
	url := flag.String("url", "http://127.0.0.1:6969", "self-hosted anisette-v3 base URL")
	requireProvisioning := flag.Bool("require-provisioning", true, "fail when the server returns no adi_pb provisioning data")
	flag.Parse()

	if err := run(*url, *requireProvisioning, nil); err != nil {
		fmt.Fprintln(os.Stderr, "anisettecheck: "+err.Error())
		os.Exit(1)
	}
}

// run verifies the endpoint. A nil state means a brand new identity, which
// exercises the provisioning handshake; a seeded state that already carries
// adi_pb goes straight to get_headers.
func run(baseURL string, requireProvisioning bool, seeded *anisette.State) error {
	// NewClient performs GET /v3/client_info and rejects a non-200 answer.
	client, err := anisette.NewClient(baseURL)
	if err != nil {
		return fmt.Errorf("client_info failed: %w", err)
	}
	fmt.Println("client_info OK")

	// A fresh state is not provisioned, so Headers() drives the full
	// /v3/provisioning_session handshake and then POST /v3/get_headers.
	state := anisette.NewState()
	if seeded != nil {
		state = *seeded
	}
	provider := anisette.NewProviderFromState(state, []string{baseURL})
	headers, err := provider.Headers()
	if err != nil {
		return fmt.Errorf("get_headers failed: %w", err)
	}

	required := []string{"X-Apple-I-MD", "X-Apple-I-MD-M", "X-Apple-I-MD-RINFO", "X-Mme-Client-Info", "X-Mme-Device-Id"}
	missing := make([]string, 0, len(required))
	for _, name := range required {
		if headers[name] == "" {
			missing = append(missing, name)
		}
	}
	encoded, _ := json.Marshal(map[string]any{
		"missing":   missing,
		"device_id": headers["X-Mme-Device-Id"],
		"md_bytes":  len(headers["X-Apple-I-MD"]),
		"mdm_bytes": len(headers["X-Apple-I-MD-M"]),
		"rinfo":     headers["X-Apple-I-MD-RINFO"],
	})
	fmt.Println("headers " + string(encoded))
	if len(missing) > 0 {
		return fmt.Errorf("server returned an incomplete header set")
	}

	provisioned := provider.State().Provisioned()
	fmt.Printf("provisioning adi_pb present=%t bytes=%d\n", provisioned, len(provider.State().AdiPB))
	if requireProvisioning && !provisioned {
		return fmt.Errorf("server did not return provisioning data for a fresh identifier")
	}
	fmt.Println("anisette-v3 endpoint verified")
	_ = client
	return nil
}
