package core

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPythonSourceIDsAndWindowsFolders(t *testing.T) {
	source := "py:" + strings.Repeat("a", 32)
	id := providerDramaID(source, "https://fixture.invalid/detail?id=7")
	actual, item, valid := splitProviderDramaID(id)
	if !valid || actual != source || item != "https://fixture.invalid/detail?id=7" {
		t.Fatalf("script ID lost opaque source ID: %q %q %v", actual, item, valid)
	}
	if strings.Contains(pythonSourceFolder(source), ":") || pythonSourceFolder(sourceHongguo) != sourceHongguo {
		t.Fatal("download folder must be valid on Windows")
	}
	if isPythonSourceID("py:../../outside") {
		t.Fatal("unsafe source ID accepted")
	}
}

func TestPythonLANSourceRangeAllowsRegisteredSources(t *testing.T) {
	pythonSources.Lock()
	previous := pythonSources.entries
	pythonSources.entries = map[string]pythonSource{}
	config := nativeLANConfig{Name: "Synthetic", Account: strings.Repeat("a", 32), Kind: "computer", Sources: []string{sourceHongguo}}
	for index := range 100 {
		source := fmt.Sprintf("py:%032x", index)
		pythonSources.entries[source] = pythonSource{ID: source, Enabled: true}
		config.Sources = append(config.Sources, source)
	}
	pythonSources.Unlock()
	defer func() { pythonSources.Lock(); pythonSources.entries = previous; pythonSources.Unlock() }()
	if err := nativeLANValidateConfig(config); err != nil {
		t.Fatal("registered source range was rejected", err)
	}
	config.Sources = append(config.Sources, "py:"+strings.Repeat("f", 32))
	if err := nativeLANValidateConfig(config); err == nil {
		t.Fatal("unregistered Python source was advertised")
	}
}

func TestPythonEpisodeRoutesFollowTitles(t *testing.T) {
	source := "py:" + strings.Repeat("b", 32)
	row := map[string]any{"vod_id": "7", "vod_name": "Synthetic", "vod_play_from": "A$$$B",
		"vod_play_url": "第1集$one#第2集$two$$$第2集$second-two#第1集$second-one"}
	result := map[string]any{"list": []any{row}}
	_, chapters, err := pythonDetailResult(source, "7", result)
	if err != nil || len(chapters) != 2 {
		t.Fatalf("detail failed: %v", err)
	}
	encoded, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(chapters[0].VideoURL, "python-spider://"))
	var routes []pythonEpisodeRoute
	if err != nil || json.Unmarshal(encoded, &routes) != nil || len(routes) != 2 || routes[1].ID != "second-one" {
		t.Fatalf("different episodes joined as fallback routes: %+v", routes)
	}
	original := chapters[0].ID
	row["vod_play_url"] = "第2集$two#第1集$one$$$第1集$second-one#第2集$second-two"
	_, reordered, err := pythonDetailResult(source, "7", result)
	if err != nil || reordered[1].ID != original {
		t.Fatal("chapter identity changed after reordering")
	}
	if _, _, err := pythonDetailResult(source, "8", result); err == nil {
		t.Fatal("wrong detail ID accepted")
	}
}

func TestPythonRegistrySaveFailurePreservesPreviousState(t *testing.T) {
	pythonSources.Lock()
	previous := pythonSources.entries
	pythonSources.entries = map[string]pythonSource{}
	pythonSources.Unlock()
	defer func() { pythonSources.Lock(); pythonSources.entries = previous; pythonSources.Unlock() }()
	directory := t.TempDir()
	d := &Downloader{cfg: Config{dataDir: directory}}
	if err := d.loadPythonSources(); err != nil {
		t.Fatal(err)
	}
	item := pythonSource{ID: "py:" + strings.Repeat("c", 32), Name: "Synthetic", Revision: strings.Repeat("d", 64), Enabled: true}
	if err := d.savePythonSource(item, false); err != nil {
		t.Fatal(err)
	}
	registry := filepath.Join(d.pythonDirectory(), "registry.json")
	if err := os.Remove(registry); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(registry, 0700); err != nil {
		t.Fatal(err)
	}
	changed := item
	changed.Enabled = false
	if err := d.savePythonSource(changed, false); err == nil {
		t.Fatal("save unexpectedly succeeded")
	}
	if !pythonSourceRegistered(item.ID, true) {
		t.Fatal("failed save modified active registry")
	}
}

func TestPythonMediaHeadersRemainScopedAndDistinct(t *testing.T) {
	address, _ := url.Parse("https://fixture.invalid/video.mp4")
	first := &providerMediaCredentials{origin: providerMediaOrigin(address), headers: map[string]string{"Authorization": "Bearer synthetic-A"}}
	second := &providerMediaCredentials{origin: providerMediaOrigin(address), headers: map[string]string{"Authorization": "Bearer synthetic-B"}}
	media := providerMedia{URL: address.String(), credentials: first, Variants: []providerMedia{{URL: address.String(), credentials: second}}}
	if len(nativePlaybackChoices(media, 0).media) != 2 {
		t.Fatal("different route authorizations were merged")
	}
	request, _ := http.NewRequest("GET", address.String(), nil)
	if err := first.apply(request); err != nil || request.Header.Get("Authorization") != "Bearer synthetic-A" {
		t.Fatal("media authorization missing")
	}
	request.URL, _ = url.Parse("https://other.invalid/video.mp4")
	if err := first.apply(request); err != nil || request.Header.Get("Authorization") != "" {
		t.Fatal("authorization leaked to another origin")
	}
}
