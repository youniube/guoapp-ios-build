package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var fixtureLegacyProtocol = legacyProtocol{InterfaceKey: "fixture-interface", ParamKey: "0123456789abcdef", ParamIV: "fedcba9876543210"}

func legacyFixtureDownloader(t *testing.T, transport sourceFixtureTransport) *Downloader {
	t.Helper()
	d := sourceFixtureDownloader(t, transport)
	d.cfg.APIBase = "https://legacy.example.test"
	d.cfg.MaxPagesPerSort, d.cfg.PageSize = 1, 3
	return d
}

func legacyFixtureResponse(request *http.Request, payload any) *http.Response {
	body, _ := json.Marshal(map[string]any{"code": 200, "hash": false, "data": payload})
	return sourceFixtureResponse(request, 200, string(body))
}

func legacyFixtureLogin(t *testing.T, request *http.Request) {
	t.Helper()
	var body struct {
		Data string `json:"data"`
	}
	if request.Method != http.MethodPost || request.Header.Get("Authorization") != "" || json.NewDecoder(request.Body).Decode(&body) != nil {
		t.Error("anonymous login must use an encrypted POST without another user's token")
		return
	}
	encrypted, err := base64.StdEncoding.DecodeString(body.Data)
	if err != nil || len(encrypted) == 0 || len(encrypted)%16 != 0 {
		t.Error("invalid encrypted login")
		return
	}
	block, _ := aes.NewCipher([]byte(fixtureLegacyProtocol.ParamKey))
	cipher.NewCBCDecrypter(block, []byte(fixtureLegacyProtocol.ParamIV)).CryptBlocks(encrypted, encrypted)
	plain, err := pkcs7Unpad(encrypted, 16)
	var fields struct {
		Device string `json:"devID"`
		System string `json:"sysType"`
		Store  bool   `json:"isAppStore"`
	}
	if err != nil || json.Unmarshal(plain, &fields) != nil || len(fields.Device) != 29 || fields.System != "ios" || fields.Store ||
		!strings.Contains(request.Header.Get("X-User-Agent"), "DevID="+fields.Device+";") {
		t.Error("login must carry a fresh consistent H5 device identity")
	}
}

func TestLegacyAnonymousCatalogAndSessionReuse(t *testing.T) {
	var loginCalls, scriptCalls atomic.Int32
	transport := sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/":
			return sourceFixtureResponse(request, 200, `<script src="https://unrelated.example/main-bad.js"></script><script src="/js/main-fixture.js"></script>`), nil
		case "/js/main-fixture.js":
			scriptCalls.Add(1)
			return sourceFixtureResponse(request, 200, `t(F,"interfaceKey","fixture-interface");t(F,"parameterKey","0123456789abcdef");t(F,"parameterIv","fedcba9876543210")`), nil
		case "/api/app/mine/login/h5":
			loginCalls.Add(1)
			legacyFixtureLogin(t, request)
			return legacyFixtureResponse(request, map[string]string{"token": "own-anonymous-session"}), nil
		case "/api/app/playlet-tab/all":
			if request.Header.Get("Authorization") != "own-anonymous-session" {
				t.Error("catalog lost its session")
			}
			return legacyFixtureResponse(request, map[string]any{"list": []Tab{{ID: "current-tab", Name: "当前分类"}}}), nil
		case "/api/app/playlet/home/tab/current-tab":
			return legacyFixtureResponse(request, map[string]any{"list": []Drama{{ID: "current-drama", Title: "无图剧库样本", TotalEpisode: 2}}}), nil
		case "/api/app/playlet/detail/current-drama":
			return legacyFixtureResponse(request, map[string]any{"title": "无图剧库样本", "chapters": []Chapter{{ID: "episode-1", VideoURL: "opaque-video-id"}}}), nil
		default:
			t.Errorf("unexpected request blocked: %s", request.URL.Path)
			return nil, errors.New("unexpected endpoint")
		}
	})
	d := legacyFixtureDownloader(t, transport)
	items, _, err := d.fetchLegacyCatalogPage(context.Background(), 1)
	if err != nil || len(items) != 1 || items[0].Source != "cloudfront" || items[0].ChannelName != "当前分类" {
		t.Fatalf("catalog: count=%d error=%v", len(items), err)
	}
	_, chapters, err := d.fetchLegacyChapters(context.Background(), "current-drama")
	if err != nil || len(chapters) != 1 {
		t.Fatalf("chapters: count=%d error=%v", len(chapters), err)
	}
	if d.cfg.Token != "" || d.cfg.AESKeyHex != "" || d.cfg.InterfaceKey != "" {
		t.Fatal("automatic session changed user configuration")
	}
	info, err := os.Stat(filepath.Join(d.cfg.dataDir, "huangguo-session.json"))
	if err != nil || runtime.GOOS != "windows" && info.Mode().Perm() != 0600 {
		t.Fatal("anonymous session must be private", err)
	}
	restarted := &Downloader{cfg: d.cfg, providerHosts: map[string]string{}}
	restarted.client = &http.Client{Transport: transport}
	restarted.limiter = newRequestLimiter(8, time.Nanosecond)
	if _, err := restarted.legacyCredentials(context.Background()); err != nil {
		t.Fatal(err)
	}
	if loginCalls.Load() != 1 || scriptCalls.Load() != 1 {
		t.Fatal("restart did not reuse the anonymous session and public protocol")
	}
}

func TestLegacyLoginWaiterCancellationAndSingleFlight(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var logins atomic.Int32
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		logins.Add(1)
		close(started)
		select {
		case <-release:
		case <-request.Context().Done():
			return nil, request.Context().Err()
		}
		return legacyFixtureResponse(request, map[string]string{"token": "shared-own-session"}), nil
	})
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	var group sync.WaitGroup
	group.Add(1)
	go func() {
		defer group.Done()
		if _, err := d.legacyCredentials(context.Background()); err != nil {
			t.Error(err)
		}
	}()
	<-started
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	if _, err := d.legacyCredentials(ctx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("a waiting caller cannot be canceled", err)
	}
	for i := 0; i < 8; i++ {
		group.Add(1)
		go func() {
			defer group.Done()
			if _, err := d.legacyCredentials(context.Background()); err != nil {
				t.Error(err)
			}
		}()
	}
	close(release)
	group.Wait()
	if logins.Load() != 1 {
		t.Fatal("concurrent callers created multiple anonymous logins")
	}
}

func TestLegacyExpiredAnonymousSessionRefreshesOnce(t *testing.T) {
	var logins atomic.Int32
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/api/app/mine/login/h5" {
			logins.Add(1)
			return legacyFixtureResponse(request, map[string]string{"token": "renewed-session"}), nil
		}
		if request.Header.Get("Authorization") == "expired-session" {
			return sourceFixtureResponse(request, 200, `{"code":5005,"msg":"no token"}`), nil
		}
		return legacyFixtureResponse(request, []Tab{{ID: "valid", Name: "当前分类"}}), nil
	})
	state := legacySessionState{Version: 1, Scope: d.legacySessionScope(), DeviceID: "0123456789ABCDEF1789290000000", Token: "expired-session", Protocol: fixtureLegacyProtocol, UpdatedAt: time.Now()}
	if err := d.saveLegacySession(state); err != nil {
		t.Fatal(err)
	}
	var tabs legacyTabList
	if err := d.fetchAPI(context.Background(), "/api/app/playlet-tab/all", nil, &tabs); err != nil || len(tabs) != 1 {
		t.Fatal("anonymous recovery failed", err)
	}
	if logins.Load() != 1 {
		t.Fatal("session refresh did not stay bounded")
	}
}

func TestLegacyExplicitTokenIsPreservedWithoutMediaKey(t *testing.T) {
	var calls atomic.Int32
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		calls.Add(1)
		if request.URL.Path != "/api/app/playlet-tab/all" || request.Header.Get("Authorization") != "configured-session" {
			t.Error("explicit configuration was replaced or sent to another endpoint")
		}
		return sourceFixtureResponse(request, 200, `{"code":5005,"msg":"expired configured session"}`), nil
	})
	d.cfg.Token = "configured-session"
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	var tabs legacyTabList
	if err := d.fetchAPI(context.Background(), "/api/app/playlet-tab/all", nil, &tabs); err == nil {
		t.Fatal("expired explicit token was ignored")
	}
	if calls.Load() != 1 || d.cfg.Token != "configured-session" {
		t.Fatal("explicit token was silently renewed")
	}
}

func TestLegacyPublicProtocolValidation(t *testing.T) {
	for _, script := range []string{"", `t(F,"parameterKey","short")`, `t(F,"interfaceKey","fixture");t(F,"parameterKey","short");t(F,"parameterIv","fedcba9876543210")`} {
		if _, err := parseLegacyProtocol(script); err == nil {
			t.Fatal("accepted incomplete or invalid public protocol")
		}
	}
	var tabs legacyTabList
	for _, raw := range []string{`[{"id":"a","name":"甲"}]`, `{"list":[{"id":"a","name":"甲"}],"count":1}`} {
		if json.Unmarshal([]byte(raw), &tabs) != nil || len(tabs) != 1 || tabs[0].ID != "a" {
			t.Fatal("tab response format not supported")
		}
	}
}

func TestLegacyFailedLoginDoesNotPersistSession(t *testing.T) {
	var logins atomic.Int32
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/api/app/mine/login/h5" {
			t.Fatal("unexpected request", request.URL.Path)
		}
		logins.Add(1)
		legacyFixtureLogin(t, request)
		return sourceFixtureResponse(request, 200, `{"code":4007,"msg":"login too frequently"}`), nil
	})
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	_, err := d.legacyCredentials(context.Background())
	var apiErr *legacyAPIError
	if !errors.As(err, &apiErr) || apiErr.code != "4007" || logins.Load() != 1 {
		t.Fatal("login error was replaced or retried", err, logins.Load())
	}
	if _, err := os.Stat(filepath.Join(d.cfg.dataDir, "huangguo-session.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("unsuccessful login was persisted", err)
	}
	if _, err := d.legacyCredentials(context.Background()); !errors.As(err, &apiErr) || logins.Load() != 1 {
		t.Fatal("in-memory retry protection did not retain the original error", err)
	}
}

func TestLegacyFailedLoginSnapshotMigrationPreservesValidSessions(t *testing.T) {
	for _, token := range []string{"", "saved-valid-session"} {
		t.Run(token, func(t *testing.T) {
			d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
				t.Fatal("session migration sent a request")
				return nil, errors.New("unexpected request")
			})
			state := legacySessionState{Version: 1, Scope: d.legacySessionScope(), DeviceID: "0123456789ABCDEF1789290000000", Token: token, Protocol: fixtureLegacyProtocol, UpdatedAt: time.Now()}
			if err := d.saveLegacySession(state); err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(d.cfg.dataDir, "huangguo-session.json")
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var fields map[string]any
			if err := json.Unmarshal(raw, &fields); err != nil {
				t.Fatal(err)
			}
			fields["loginRetryAt"] = time.Now().Add(-time.Minute)
			raw, err = json.Marshal(fields)
			if err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, raw, 0600); err != nil {
				t.Fatal(err)
			}
			loaded := d.loadLegacySession()
			if loaded.Token != token || loaded.Protocol != fixtureLegacyProtocol || loaded.Scope != state.Scope {
				t.Fatal("session migration lost valid credentials or protocol")
			}
			if token == "" && loaded.DeviceID != "" || token != "" && loaded.DeviceID != state.DeviceID {
				t.Fatal("session migration reused a failed identity or discarded a valid one")
			}
		})
	}
}

func TestLegacyBundledSessionStartsWithoutLoginAndPreservesLocalSession(t *testing.T) {
	previous := bundledLegacySessionBase64
	t.Cleanup(func() { bundledLegacySessionBase64 = previous })
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		t.Fatal("bundled session attempted a fresh login", request.URL.Path)
		return nil, errors.New("unexpected request")
	})
	seed := legacySessionState{Version: 1, Scope: d.legacySessionScope(), DeviceID: "0123456789ABCDEF1789290000000", Token: "bundled-fixture-session", Protocol: fixtureLegacyProtocol, UpdatedAt: time.Now()}
	raw, err := json.Marshal(seed)
	if err != nil {
		t.Fatal(err)
	}
	bundledLegacySessionBase64 = base64.StdEncoding.EncodeToString(raw)
	access, err := d.legacyCredentials(context.Background())
	if err != nil || access.Token != seed.Token || access.DeviceID != seed.DeviceID {
		t.Fatal("bundled credentials were not used", err)
	}
	if saved := d.loadLegacySession(); saved.Token != seed.Token {
		t.Fatal("bundled session was not saved for subsequent launches")
	}
	local := seed
	local.Token = "existing-local-session"
	local.DeviceID = "FEDCBA98765432101789290000001"
	if err := d.saveLegacySession(local); err != nil {
		t.Fatal(err)
	}
	if loaded := d.loadLegacySession(); loaded.Token != local.Token || loaded.DeviceID != local.DeviceID {
		t.Fatal("bundled session overwrote existing valid local credentials")
	}
	local.Token = ""
	if err := d.saveLegacySession(local); err != nil {
		t.Fatal(err)
	}
	if loaded := d.loadLegacySession(); loaded.Token != seed.Token || loaded.DeviceID != seed.DeviceID {
		t.Fatal("empty local session did not bootstrap from bundled credentials")
	}
	seed.Scope = "https://different-api.example.test"
	raw, _ = json.Marshal(seed)
	bundledLegacySessionBase64 = base64.StdEncoding.EncodeToString(raw)
	if loaded := d.loadLegacySession(); loaded.Token != "" || loaded.DeviceID != "" {
		t.Fatal("bundled credentials leaked across API scopes")
	}
}
