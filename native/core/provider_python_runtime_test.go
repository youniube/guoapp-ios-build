package core

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"
)

func pythonRuntimeForTest(t *testing.T) {
	t.Helper()
	home := os.Getenv("GUOAPP_TEST_PYTHON_HOME")
	if home == "" {
		t.Skip("set GUOAPP_TEST_PYTHON_HOME to test the bundled interpreter")
	}
	if runtime.GOOS != "windows" {
		t.Skip("this runtime fixture uses the Windows embedded distribution")
	}
	configurePythonRuntime(pythonRuntimeConfig{Home: home, Library: filepath.Join(home, "python314.dll"),
		Search: []string{filepath.Join(home, "python314.zip"), home, filepath.Join(home, "Lib", "site-packages")}})
}

func pythonImportForTest(engine *nativeEngine, ctx context.Context, body []byte, source string) (pythonSource, error) {
	_, err := engine.importPythonSource(ctx, nativeInput{Filename: "synthetic.py", ScriptBody: base64.StdEncoding.EncodeToString(body), Source: source})
	if err != nil {
		return pythonSource{}, err
	}
	items := pythonSourceSnapshot()
	if len(items) != 1 {
		return pythonSource{}, errors.New("expected one registered fixture")
	}
	return items[0], nil
}

func TestPythonRuntimeLifecycleAndFailedUpdateRollback(t *testing.T) {
	pythonRuntimeForTest(t)
	engine := sourceFixtureEngine(t, func(*http.Request) (*http.Response, error) {
		return nil, errors.New("external network forbidden")
	})
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	body, err := os.ReadFile("testdata/python_spider_fixture.py")
	if err != nil {
		t.Fatal(err)
	}
	item, err := pythonImportForTest(engine, ctx, body, "")
	if err != nil {
		t.Fatal("embedded import failed", err)
	}
	if !item.Search || !item.Enabled || item.Name != "Python 合成站源" {
		t.Fatal("source metadata lost", item)
	}
	if _, err := pythonImportForTest(engine, ctx, body, ""); err == nil {
		t.Fatal("duplicate import accepted")
	}
	categories, err := engine.nativeCategories(ctx, item.ID, false)
	if err != nil || len(categories) != 2 || categories[1].ID != "demo" {
		t.Fatal("categories failed", err, categories)
	}
	page, err := engine.nativeCatalog(ctx, nativeInput{Source: item.ID, Page: 1})
	if err != nil || len(page.Items) != 1 || !page.HasMore {
		t.Fatal("catalog failed", err, page)
	}
	if engine.catalogStates[item.ID].PythonRevision != item.Revision {
		t.Fatal("catalog revision was not persisted")
	}
	rows, more, err := engine.downloader.fetchPythonCatalog(ctx, item.ID, 2, "", "synthetic")
	if err != nil || len(rows) != 1 || more {
		t.Fatal("paged search failed", err)
	}
	_, chapters, err := engine.downloader.fetchPythonDetail(ctx, item.ID, "7")
	if err != nil || len(chapters) != 2 {
		t.Fatal("detail failed", err)
	}
	media, err := engine.downloader.resolvePythonMedia(ctx, Task{DramaID: providerDramaID(item.ID, "7"), Chapter: chapters[0]})
	if err != nil || len(media.Variants) != 2 || media.Variants[1].URL != "https://fixture.invalid/one-b.mp4" {
		t.Fatal("episode routes failed", err)
	}
	request, _ := http.NewRequest("GET", media.URL, nil)
	if err := media.credentials.apply(request); err != nil || request.Header.Get("Authorization") != "Bearer synthetic-fixture-token" || request.Header.Get("Cookie") != "fixture=synthetic" {
		t.Fatal("script authorization was not preserved")
	}
	oldFile := engine.downloader.pythonFile(item)
	for _, invalid := range []string{"def broken(:\n", "import guoapp_missing_fixture_dependency\n" + string(body)} {
		if _, err := pythonImportForTest(engine, ctx, []byte(invalid), item.ID); err == nil {
			t.Fatal("invalid update accepted")
		}
		if pythonSourceRevision(item.ID) != item.Revision {
			t.Fatal("failed update replaced the old registry")
		}
		if _, err := os.Stat(oldFile); err != nil {
			t.Fatal("failed update removed the old script", err)
		}
	}
	updated, err := pythonImportForTest(engine, ctx, []byte(strings.ReplaceAll(string(body), "Python 合成站源", "Python 更新站源")), item.ID)
	if err != nil || updated.ID != item.ID || updated.Revision == item.Revision {
		t.Fatal("update failed to preserve source identity", err)
	}
	if _, err := os.Stat(oldFile); !os.IsNotExist(err) || len(engine.catalogs[item.ID]) != 0 {
		t.Fatal("update retained the old script or stale catalog")
	}
	restarted := reopenCatalogEngine(t, engine.directory, engine.downloader.client.Transport.(sourceFixtureTransport))
	if !pythonSourceRegistered(item.ID, true) || pythonSourceSnapshot()[0].Name != updated.Name {
		t.Fatal("restart lost the imported source")
	}
	for _, command := range []string{"disable", "enable", "delete"} {
		if _, err := restarted.managePythonSource(ctx, nativeInput{Source: item.ID, Command: command}); err != nil {
			t.Fatal(command, err)
		}
		_, _, err := restarted.downloader.fetchPythonCatalog(ctx, item.ID, 1, "", "")
		if (command == "enable") != (err == nil) {
			t.Fatal("source availability did not follow management state", command, err)
		}
	}
	if len(pythonSourceSnapshot()) != 0 {
		t.Fatal("deleted source remained registered")
	}
	if _, err := os.Stat(filepath.Dir(restarted.downloader.pythonFile(updated))); !os.IsNotExist(err) {
		t.Fatal("deleted script state remained on disk", err)
	}
}

func TestPythonRuntimeDependenciesNetworkCacheProxyAndCancellation(t *testing.T) {
	pythonRuntimeForTest(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect" {
			w.Header().Set("Location", "/content")
			w.WriteHeader(http.StatusFound)
			return
		}
		if r.URL.Path != "/content" || r.Header.Get("X-Synthetic") != "fixture" {
			http.Error(w, "unexpected fixture request", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, "<html><body><h1>synthetic</h1></body></html>")
	}))
	defer server.Close()
	engine := sourceFixtureEngine(t, nil)
	engine.downloader.client.Transport = http.DefaultTransport
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	body, err := os.ReadFile("testdata/python_spider_fixture.py")
	if err != nil {
		t.Fatal(err)
	}
	extra := `
    def __init__(self):
        self.custom_constructor = True

    def init(self, extend=''):
        from Crypto.Cipher import AES
        from Crypto.PublicKey import RSA
        from Crypto.Hash import SHA256
        from Crypto.Signature import pkcs1_15
        from lxml import etree
        from pyquery import PyQuery
        from bs4 import BeautifulSoup
        data = b'0123456789abcdef'
        assert AES.new(data, AES.MODE_ECB).decrypt(AES.new(data, AES.MODE_ECB).encrypt(data)) == data
        key = RSA.generate(1024)
        digest = SHA256.new(data)
        pkcs1_15.new(key.public_key()).verify(digest, pkcs1_15.new(key).sign(digest))
        assert etree.HTML('<h1>synthetic</h1>').xpath('//h1/text()') == ['synthetic']
        assert PyQuery('<h1>synthetic</h1>')('h1').text() == 'synthetic'
        assert BeautifulSoup('<h1>synthetic</h1>', 'html.parser').h1.text == 'synthetic'
        self.setCache('session', 'synthetic-private')
        self.delCache('session')

    def categoryContent(self, tid, pg, filter, extend):
        import requests
        import urllib.request
        redirected = requests.get(FIXTURE_URL + '/redirect', allow_redirects=False)
        assert redirected.status_code == 302 and redirected.headers['Location'] == '/content'
        assert 'synthetic' in self.fetch(FIXTURE_URL + '/content', headers={'X-Synthetic': 'fixture'}).text
        request = urllib.request.Request(FIXTURE_URL + '/content', headers={'X-Synthetic': 'fixture'})
        assert b'synthetic' in urllib.request.urlopen(request).read()
        self.session.headers['X-Synthetic'] = 'fixture'
        assert self.post(FIXTURE_URL + '/content').status_code == 200
        return {'page': int(pg), 'pagecount': 1, 'list': [{'vod_id': '7', 'vod_name': 'synthetic'}]}

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': self.getProxyUrl() + '&type=fixture'}

    def localProxy(self, params):
        return [200, 'video/mp4', b'synthetic-media', {'X-Synthetic': 'proxy'}]
`
	body = []byte("FIXTURE_URL = " + strconv.Quote(server.URL) + "\n" + string(body) + extra)
	item, err := pythonImportForTest(engine, ctx, body, "")
	if err != nil {
		t.Fatal("bundled native dependency import failed", err)
	}
	cache, err := os.ReadFile(filepath.Join(filepath.Dir(engine.downloader.pythonFile(item)), "state-"+item.Revision, "cache.json"))
	if err != nil || strings.Contains(string(cache), "synthetic-private") {
		t.Fatal("deleted cache key survived on disk", err)
	}
	if _, _, err := engine.downloader.fetchPythonCatalog(ctx, item.ID, 1, "", ""); err != nil {
		t.Fatal("network bridge failed", err)
	}
	_, chapters, err := engine.downloader.fetchPythonDetail(ctx, item.ID, "7")
	if err != nil {
		t.Fatal(err)
	}
	media, err := engine.downloader.resolvePythonMedia(ctx, Task{DramaID: providerDramaID(item.ID, "7"), Chapter: chapters[0]})
	if err != nil {
		t.Fatal("local proxy resolution failed", err)
	}
	response, err := http.Get(media.URL)
	if err != nil {
		t.Fatal(err)
	}
	proxyBody, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil || response.StatusCode != 200 || string(proxyBody) != "synthetic-media" || response.Header.Get("X-Synthetic") != "proxy" {
		t.Fatal("localProxy failed", err)
	}
	spinning := []byte(strings.Replace(string(body), "self.custom_constructor = True", "while True: pass", 1))
	short, stop := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer stop()
	if _, err := pythonImportForTest(engine, short, spinning, item.ID); err == nil {
		t.Fatal("runaway Python code ignored the deadline")
	}
	if pythonSourceRevision(item.ID) != item.Revision {
		t.Fatal("timed-out update replaced the old script")
	}
	if _, err := engine.managePythonSource(ctx, nativeInput{Source: item.ID, Command: "delete"}); err != nil {
		t.Fatal(err)
	}
}
