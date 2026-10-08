package core

import (
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestPythonRepeatedTitlesKeepDistinctEpisodes(t *testing.T) {
	source := "py:" + strings.Repeat("d", 32)
	row := map[string]any{"vod_id": "7", "vod_name": "Synthetic", "vod_play_from": "A$$$B",
		"vod_play_url": "播放$one#播放$two#播放$two$$$播放$one-b#播放$two-b"}
	_, chapters, err := pythonDetailResult(source, "7", map[string]any{"list": []any{row}})
	if err != nil || len(chapters) != 2 || chapters[0].ID == chapters[1].ID {
		t.Fatal("distinct repeated titles lost", err, chapters)
	}
	for index, chapter := range chapters {
		encoded, _ := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(chapter.VideoURL, "python-spider://"))
		var routes []pythonEpisodeRoute
		if json.Unmarshal(encoded, &routes) != nil || len(routes) != 2 || routes[1].ID != []string{"one-b", "two-b"}[index] {
			t.Fatal("repeated title routes crossed", routes)
		}
	}
}

func TestPythonCatalogFilterEncodingAndHeaders(t *testing.T) {
	body, _ := json.Marshal(map[string]any{"category": "demo", "filters": map[string]string{"year": "2026"}})
	category, filters, err := pythonCatalogFilters("py-filter:" + base64.RawURLEncoding.EncodeToString(body))
	if err != nil || category != "demo" || filters["year"] != "2026" {
		t.Fatal("filter selection lost", category, filters, err)
	}
	if _, _, err := pythonCatalogFilters("py-filter:invalid"); err == nil {
		t.Fatal("malformed filters accepted")
	}
	headers := pythonParsedHeaders("https://fixture.invalid/page", "https://media.invalid/video.m3u8",
		map[string]string{"authorization": "synthetic", "cookie": "fixture=1"}, map[string]string{"referer": "https://parser.invalid/"})
	if headers["Authorization"] != "synthetic" || headers["Cookie"] != "fixture=1" || headers["Referer"] != "https://parser.invalid/" {
		t.Fatal("explicit script media headers lost", headers)
	}
}

func TestPythonParserUsesConfiguredJSONResolverAndKeepsMediaHeaders(t *testing.T) {
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "synthetic-source" {
			t.Error("source request lost explicit header")
		}
		io.WriteString(w, "<html>synthetic script player</html>")
	}))
	defer page.Close()
	parser := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" {
			t.Error("source credentials leaked to external parser")
		}
		if r.URL.Query().Get("url") != page.URL {
			t.Error("parser received wrong target")
		}
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"url":"https://fixture.invalid/resolved.m3u8","header":{"X-Media":"synthetic"}}`)
	}))
	defer parser.Close()
	engine := sourceFixtureEngine(t, nil)
	engine.downloader.client.Transport = http.DefaultTransport
	config, _ := json.Marshal([]map[string]any{{"type": 1, "url": parser.URL + "?url="}})
	engine.downloader.attachedAccess["catpaw_playback"] = attachedAccess{Settings: map[string]string{"parses": string(config)}}
	address, headers, err := engine.downloader.resolvePythonParsedMedia(context.Background(), page.URL, "", map[string]string{"Authorization": "synthetic-source", "Cookie": "fixture=synthetic"})
	if err != nil || address != "https://fixture.invalid/resolved.m3u8" || headers["X-Media"] != "synthetic" || headers["Authorization"] != "synthetic-source" {
		t.Fatal("configured Python parser failed", address, headers, err)
	}
}

func TestPythonRuntimeEmptyHomeUnknownPagesParametersAndThreadNetwork(t *testing.T) {
	pythonRuntimeForTest(t)
	started, unblock := make(chan struct{}), make(chan struct{})
	background := make(chan string, 1)
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(unblock) }) }
	defer release()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/barrier":
			close(started)
			select {
			case <-unblock:
				io.WriteString(w, "ready")
			case <-r.Context().Done():
			}
		case "/background":
			background <- r.Header.Get("X-Synthetic-Name")
			io.WriteString(w, "synthetic-body")
		case "/cookie":
			http.SetCookie(w, &http.Cookie{Name: "first", Value: "synthetic", Path: "/"})
			http.SetCookie(w, &http.Cookie{Name: "second", Value: "synthetic", Path: "/"})
			io.WriteString(w, "cookie")
		case "/compressed":
			if !strings.Contains(r.Header.Get("Cookie"), "first=synthetic") || !strings.Contains(r.Header.Get("Cookie"), "second=synthetic") {
				http.Error(w, "cookie lost", 400)
				return
			}
			w.Header().Set("Content-Encoding", "gzip")
			body := gzip.NewWriter(w)
			_, _ = body.Write([]byte("synthetic-body"))
			_ = body.Close()
		case "/plain":
			io.WriteString(w, "synthetic-body")
		default:
			http.Error(w, "external media forbidden", 400)
		}
	}))
	defer func() { release(); server.Close() }()
	engine := sourceFixtureEngine(t, nil)
	engine.downloader.client.Transport = http.DefaultTransport
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	body := []byte("FIXTURE_URL = " + strconv.Quote(server.URL) + "\n" + `
from base.spider import Spider as Base
import json, gzip, http.client, http.cookiejar, urllib.request, urllib.parse, threading
class Spider(Base):
    def init(self, extend=''):
        self.options = json.loads(extend or '{}')
    def homeContent(self, filter):
        return {'class':[{'type_id':'demo','type_name':'Synthetic'}], 'filters':{'demo':[{'key':'year','name':'Year','value':[{'n':'2026','v':'2026'}]}]}}
    def homeVideoContent(self, filter=None):
        return {'list':[]}
    def categoryContent(self, tid, pg, filter, extend):
        if tid == 'background':
            def background_worker():
                urllib.request.urlopen(FIXTURE_URL + '/barrier').read()
                request = urllib.request.Request(FIXTURE_URL + '/background', headers={'X-Synthetic-Name':self.options['name']})
                urllib.request.urlopen(request).read()
            threading.Thread(target=background_worker, daemon=True).start()
            return {'list':[]}
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        assert opener.open(FIXTURE_URL + '/cookie').read() == b'cookie'
        request = urllib.request.Request(FIXTURE_URL + '/compressed', headers={'Accept-Encoding':'gzip'})
        assert gzip.decompress(opener.open(request).read()) == b'synthetic-body'
        address = urllib.parse.urlparse(FIXTURE_URL)
        connection = http.client.HTTPConnection(address.hostname, address.port)
        connection.request('GET', '/plain')
        assert connection.getresponse().read() == b'synthetic-body'
        connection.close()
        errors = []
        def worker():
            try: assert urllib.request.urlopen(FIXTURE_URL + '/plain').read() == b'synthetic-body'
            except BaseException as error: errors.append(type(error).__name__)
        thread = threading.Thread(target=worker); thread.start(); thread.join(5)
        assert not errors and not thread.is_alive()
        page = min(int(pg), 2)
        return {'page':int(pg), 'list':[{'vod_id':str(page), 'vod_name':self.options.get('name','Synthetic') + extend.get('year','')}]}
    def searchContent(self, key, quick, pg='1'):
        return self.categoryContent('demo', pg, False, {})
    def detailContent(self, ids):
        return {'list':[{'vod_id':ids[0], 'vod_name':'Synthetic','vod_play_from':'A','vod_play_url':'One$one'}]}
    def playerContent(self, flag, id, vipFlags):
        return {'parse':0,'url':'https://fixture.invalid/media.mp4'}
`)
	extend := `{"name":"First"}`
	if _, err := engine.importPythonSource(ctx, nativeInput{Filename: "synthetic.py", ScriptBody: base64.StdEncoding.EncodeToString(body), ScriptExtend: &extend}); err != nil {
		t.Fatal(err)
	}
	first := pythonSourceSnapshot()[0]
	rows, more, err := engine.downloader.fetchPythonCatalog(ctx, first.ID, 1, "", "")
	if err != nil || len(rows) != 1 || !more || rows[0].Title != "First" {
		t.Fatal("empty home or unknown pagination failed", rows, more, err)
	}
	if rows, more, err = engine.downloader.fetchPythonCatalog(ctx, first.ID, 2, "", ""); err != nil || len(rows) != 1 || !more {
		t.Fatal("next page failed", rows, more, err)
	}
	if rows, more, err = engine.downloader.fetchPythonCatalog(ctx, first.ID, 3, "", ""); err != nil || len(rows) != 0 || more {
		t.Fatal("repeated page did not stop", rows, more, err)
	}
	categories, err := engine.nativeCategories(ctx, first.ID, false)
	if err != nil || len(categories) != 2 || len(categories[1].Filters) != 1 {
		t.Fatal("filter metadata lost", categories, err)
	}
	selection := "py-filter:" + base64.RawURLEncoding.EncodeToString([]byte(`{"category":"demo","filters":{"year":"2026"}}`))
	if rows, _, err := engine.downloader.fetchPythonCatalog(ctx, first.ID, 1, selection, ""); err != nil || len(rows) != 1 || rows[0].Title != "First2026" {
		t.Fatal("selected filter lost", rows, err)
	}
	secondExtend := `{"name":"Second"}`
	if _, _, err := engine.downloader.fetchPythonCatalog(ctx, first.ID, 1, "background", ""); err != nil {
		t.Fatal(err)
	}
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("background request did not start")
	}
	if _, err := engine.importPythonSource(ctx, nativeInput{Filename: "synthetic.py", ScriptBody: base64.StdEncoding.EncodeToString(body), ScriptExtend: &secondExtend}); err != nil || len(pythonSourceSnapshot()) != 2 {
		t.Fatal("same script with different parameters rejected", err)
	}
	release()
	select {
	case name := <-background:
		if name != "First" {
			t.Fatal("background source context changed", name)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("background request lost its source context")
	}
	for _, item := range pythonSourceSnapshot() {
		if _, err := engine.managePythonSource(ctx, nativeInput{Source: item.ID, Command: "delete"}); err != nil {
			t.Fatal(err)
		}
	}
}
