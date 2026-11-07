package kernel

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestStartStopREST is the CI smoke test for the embedding strategy: boot the
// real engine in a temp home, hit the loopback REST API, stop cleanly.
func TestStartStopREST(t *testing.T) {
	if testing.Short() {
		t.Skip("integration test")
	}
	home := t.TempDir()
	guiPort := 18384
	apiKey := "inkvault-test-key-1234567890"

	if Version() == "" {
		t.Fatal("Version() is empty")
	}

	done := make(chan error, 1)
	go func() { done <- Start(home, guiPort, apiKey) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Start: %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("Start timed out")
	}
	defer func() {
		if err := Stop(); err != nil {
			t.Errorf("Stop: %v", err)
		}
	}()

	if !IsRunning() {
		t.Fatal("IsRunning=false after Start")
	}
	if MyDeviceID() == "" {
		t.Fatal("MyDeviceID empty after Start")
	}

	// REST smoke: system/status must answer with the API key.
	url := fmt.Sprintf("http://127.0.0.1:%d/rest/system/status", guiPort)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-API-Key", apiKey)
	client := &http.Client{Timeout: 10 * time.Second}
	var resp *http.Response
	for i := 0; i < 30; i++ {
		resp, err = client.Do(req)
		if err == nil {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("REST unreachable after Start: %v", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		t.Fatalf("REST status=%d body=%s", resp.StatusCode, body)
	}
	var status map[string]any
	if err := json.Unmarshal(body, &status); err != nil {
		t.Fatalf("REST body not JSON: %v", err)
	}
	if status["myID"] != MyDeviceID() {
		t.Fatalf("myID mismatch: REST=%v kernel=%v", status["myID"], MyDeviceID())
	}

	// Wrong key must be rejected.
	req2, _ := http.NewRequest(http.MethodGet, url, nil)
	req2.Header.Set("X-API-Key", "wrong-key")
	resp2, err := client.Do(req2)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode == 200 {
		t.Fatal("wrong API key accepted")
	}

	// State artifacts must live inside homeDir only (D-07).
	for _, name := range []string{"config.xml", "cert.pem", "key.pem"} {
		if _, err := os.Stat(filepath.Join(home, name)); err != nil {
			t.Errorf("expected %s under homeDir: %v", name, err)
		}
	}
}
