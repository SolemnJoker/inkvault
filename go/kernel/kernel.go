// Package kernel embeds the Syncthing engine for InkVault.
//
// The binding surface is intentionally minimal: the Swift layer drives all
// configuration (devices, folders, relay addresses) through the kernel's
// localhost REST API, so only Start/Stop/Version/IsRunning/MyDeviceID are
// exposed.
//
// Power discipline (docs/decisions.md D-05): the kernel only runs between
// Start and Stop calls made by the Swift lifecycle coordinator. Nothing here
// schedules background work of its own.
//
// Compliance notes:
//   - NoUpgrade prevents any self-upgrade attempts.
//   - Default listen addresses are reduced to LAN-only TCP/QUIC; global
//     discovery and NAT traversal are disabled while relay usage stays
//     enabled (private relay only, per-device address set via REST). Public
//     relay pools are never contacted (D-06).
//   - The GUI/API is bound to 127.0.0.1 only; access requires the caller
//     supplied API key (D-07: credentials stay in the app sandbox).
package kernel

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"strconv"
	"sync"
	"time"

	"github.com/syncthing/syncthing/lib/build"
	"github.com/syncthing/syncthing/lib/config"
	"github.com/syncthing/syncthing/lib/events"
	"github.com/syncthing/syncthing/lib/locations"
	"github.com/syncthing/syncthing/lib/logger"
	"github.com/syncthing/syncthing/lib/protocol"
	"github.com/syncthing/syncthing/lib/svcutil"
	"github.com/syncthing/syncthing/lib/syncthing"
	"github.com/thejerf/suture/v4"
)

var (
	mu          sync.Mutex
	app         *syncthing.App
	myID        string
	earlyCancel context.CancelFunc
)

// Version returns the embedded Syncthing version string.
func Version() string {
	return build.LongVersion
}

// IsRunning reports whether the kernel is currently running.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return app != nil
}

// MyDeviceID returns this kernel's Syncthing device ID, or "" when stopped.
func MyDeviceID() string {
	mu.Lock()
	defer mu.Unlock()
	return myID
}

// Start boots the engine with its state under homeDir and the REST API on
// 127.0.0.1:guiPort protected by apiKey. It blocks until the API is ready.
func Start(homeDir string, guiPort int, apiKey string) error {
	mu.Lock()
	defer mu.Unlock()
	if app != nil {
		return errors.New("kernel already running")
	}
	if homeDir == "" || apiKey == "" || guiPort <= 0 {
		return errors.New("homeDir, guiPort and apiKey are required")
	}

	// Keep every artifact (config.xml, certificates, database, logs) inside
	// the sandbox directory handed to us. Nothing touches the vault (D-07).
	if err := locations.SetBaseDir(locations.ConfigBaseDir, homeDir); err != nil {
		return fmt.Errorf("set config base dir: %w", err)
	}
	if err := locations.SetBaseDir(locations.DataBaseDir, homeDir); err != nil {
		return fmt.Errorf("set data base dir: %w", err)
	}

	cert, err := syncthing.LoadOrGenerateCertificate(
		locations.Get(locations.CertFile),
		locations.Get(locations.KeyFile),
	)
	if err != nil {
		return fmt.Errorf("load or generate device certificate: %w", err)
	}
	id := protocol.NewDeviceID(cert.Certificate[0])

	earlySup, cancelEarly := startEarlyServices()
	evLogger := events.NewLogger()
	earlySup.Add(evLogger)

	cfgWrapper, err := loadOrCreateConfig(
		locations.Get(locations.ConfigFile), id, evLogger, guiPort, apiKey,
	)
	if err != nil {
		return fmt.Errorf("load config: %w", err)
	}
	// The wrapper's modification queue must be served for the whole lifetime
	// of the app (this is what cmd/syncthing does via its early supervisor).
	earlySup.Add(cfgWrapper)

	ldb, err := syncthing.OpenDBBackend(
		locations.Get(locations.Database),
		cfgWrapper.Options().DatabaseTuning,
	)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}

	newApp, err := syncthing.New(cfgWrapper, ldb, evLogger, cert, syncthing.Options{
		NoUpgrade: true,
	})
	if err != nil {
		return fmt.Errorf("create app: %w", err)
	}
	if err := newApp.Start(); err != nil {
		return fmt.Errorf("start app: %w", err)
	}

	if err := waitAPIReady(guiPort, 30*time.Second); err != nil {
		newApp.Stop(svcutil.ExitError)
		return fmt.Errorf("api did not become ready: %w", err)
	}

	app = newApp
	myID = id.String()
	earlyCancel = cancelEarly
	return nil
}

// Stop shuts the engine down and releases network and memory resources.
func Stop() error {
	mu.Lock()
	defer mu.Unlock()
	if app == nil {
		return nil
	}
	a := app
	app = nil
	myID = ""
	a.Stop(svcutil.ExitSuccess)
	if earlyCancel != nil {
		earlyCancel()
		earlyCancel = nil
	}
	return nil
}

// loadOrCreateConfig loads config.xml (creating a default one on first run)
// and applies the app's fixed policy before the wrapper is ever served.
//
// It deliberately avoids LoadConfigAtStartup + Modify: wrapper.Modify blocks
// until a subscriber serves the queue, which only happens once the app is
// running — and the policy must already be in effect at first listen. Raw
// mutation + Wrap + Save achieves that without races (D-06/D-07).
func loadOrCreateConfig(path string, id protocol.DeviceID, evLogger events.Logger, guiPort int, apiKey string) (config.Wrapper, error) {
	_, ver, err := config.Load(path, id, evLogger)
	var w config.Wrapper
	switch {
	case errors.Is(err, fs.ErrNotExist):
		// noDefaultFolder=true: never fabricate a sync folder (D-12).
		// skipPortProbing=true: don't scan LAN ports on a mobile device.
		w, err = syncthing.DefaultConfig(path, id, evLogger, true, true)
		if err != nil {
			return nil, fmt.Errorf("generate default config: %w", err)
		}
	case err != nil:
		return nil, fmt.Errorf("read config: %w", err)
	default:
		if ver > config.CurrentVersion {
			return nil, fmt.Errorf("config version %d is newer than supported %d", ver, config.CurrentVersion)
		}
	}

	raw := w.RawCopy()
	applyPolicy(&raw, guiPort, apiKey)
	out := config.Wrap(path, raw, id, evLogger)
	if err := out.Save(); err != nil {
		return nil, fmt.Errorf("save config: %w", err)
	}
	return out, nil
}

// applyPolicy pins the configuration choices the app guarantees:
// loopback-only GUI with the given API key, LAN-only listen addresses,
// no public discovery, no NAT traversal, private relays allowed.
func applyPolicy(cfg *config.Configuration, guiPort int, apiKey string) {
	gui := &cfg.GUI
	gui.Enabled = true
	gui.RawAddress = net.JoinHostPort("127.0.0.1", strconv.Itoa(guiPort))
	gui.RawUseTLS = false // loopback only
	gui.User = ""
	gui.Password = ""
		// Always pin our own key: the app is the only legitimate REST client
		// and must be able to authenticate right after first start.
		gui.APIKey = apiKey

	opts := &cfg.Options
	opts.RawListenAddresses = []string{
		"tcp://0.0.0.0:22000",
		"quic://0.0.0.0:22000",
	}
	opts.GlobalAnnEnabled = false // no public discovery (D-06)
	opts.RawGlobalAnnServers = []string{"disabled"}
	opts.LocalAnnEnabled = true // LAN direct when available
	opts.RelaysEnabled = true   // private relay only, per-device
	opts.NATEnabled = false     // no NAT traversal (D-06)
}

// startEarlyServices mirrors cmd/syncthing's boot order: the event logger
// and the config wrapper are themselves services whose queues must be served
// before App.start() runs. The returned cancel func shuts them down.
func startEarlyServices() (sup *suture.Supervisor, cancel context.CancelFunc) {
	ctx, cancel := context.WithCancel(context.Background())
	sup = suture.New("inkvault-early", svcutil.SpecWithDebugLogger(logger.DefaultLogger))
	sup.ServeBackground(ctx)
	return sup, cancel
}

func waitAPIReady(port int, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, 500*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", addr)
}
