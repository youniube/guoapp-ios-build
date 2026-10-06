package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var pythonSourcePattern = regexp.MustCompile(`^py:[a-f0-9]{32}$`)
var pythonSources = struct {
	sync.RWMutex
	entries map[string]pythonSource
}{entries: map[string]pythonSource{}}

type pythonSource struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	Filename  string    `json:"filename"`
	Revision  string    `json:"revision"`
	Enabled   bool      `json:"enabled"`
	Search    bool      `json:"search"`
	UpdatedAt time.Time `json:"updatedAt"`
}

func isPythonSourceID(source string) bool { return pythonSourcePattern.MatchString(source) }

func pythonSourceRevision(source string) string {
	pythonSources.RLock()
	defer pythonSources.RUnlock()
	return pythonSources.entries[source].Revision
}
func pythonSourceRegistered(source string, active bool) bool {
	pythonSources.RLock()
	defer pythonSources.RUnlock()
	item, found := pythonSources.entries[source]
	return found && (!active || item.Enabled)
}

func pythonSourceFolder(source string) string {
	if isPythonSourceID(source) {
		return strings.Replace(source, ":", "-", 1)
	}
	return source
}

func (engine *nativeEngine) stopPythonSource(source string) error {
	engine.cancelSourceTask(source)
	engine.downloader.pythonMu.Lock()
	bridge := engine.downloader.pythonHTTP
	engine.downloader.pythonMu.Unlock()
	if bridge != nil {
		bridge.mu.Lock()
		for _, ticket := range bridge.tickets {
			if ticket.source.ID == source {
				ticket.cancel()
			}
		}
		bridge.mu.Unlock()
	}
	engine.mu.Lock()
	tokens := []string{}
	for token, choice := range engine.playbacks {
		for _, media := range choice.media {
			if media.pythonSource == source {
				tokens = append(tokens, token)
				break
			}
		}
	}
	engine.mu.Unlock()
	for _, token := range tokens {
		engine.nativeReleasePlayback(token)
	}
	if manager := engine.downloads; manager != nil {
		manager.mu.Lock()
		for _, job := range manager.jobs {
			if job.Drama.Source == source && (job.State == "queued" || job.State == "downloading") {
				job.State = "paused"
				if cancel := manager.active[job.ID]; cancel != nil {
					cancel()
				}
			}
		}
		err := manager.saveLocked()
		manager.mu.Unlock()
		if err != nil {
			return errors.New("相关任务已停止，但下载队列状态尚未保存")
		}
	}
	return nil
}

func pythonSourceSnapshot() []pythonSource {
	pythonSources.RLock()
	defer pythonSources.RUnlock()
	items := make([]pythonSource, 0, len(pythonSources.entries))
	for _, item := range pythonSources.entries {
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool {
		if items[i].Name == items[j].Name {
			return items[i].ID < items[j].ID
		}
		return items[i].Name < items[j].Name
	})
	return items
}

func pythonRandomID() string {
	body := make([]byte, 16)
	if _, err := rand.Read(body); err != nil {
		panic(err)
	}
	return hex.EncodeToString(body)
}

func (d *Downloader) pythonDirectory() string { return filepath.Join(d.cfg.dataDir, "python-sources") }
func (d *Downloader) pythonFile(item pythonSource) string {
	return filepath.Join(d.pythonDirectory(), strings.TrimPrefix(item.ID, "py:"), item.Revision+".py")
}

func (d *Downloader) loadPythonSources() error {
	directory := d.pythonDirectory()
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	body, err := os.ReadFile(filepath.Join(directory, "registry.json"))
	entries := map[string]pythonSource{}
	if err != nil && !os.IsNotExist(err) {
		return errors.New("无法读取 Python 站源登记文件，原文件已保留")
	}
	if err == nil {
		var items []pythonSource
		if len(body) > 1<<20 || json.Unmarshal(body, &items) != nil {
			return errors.New("Python 站源登记文件损坏，原文件已保留")
		}
		for _, item := range items {
			if !isPythonSourceID(item.ID) || !regexp.MustCompile(`^[a-f0-9]{64}$`).MatchString(item.Revision) || item.Name == "" {
				return errors.New("Python 站源登记格式无效")
			}
			if _, duplicate := entries[item.ID]; duplicate {
				return errors.New("Python 站源登记重复")
			}
			entries[item.ID] = item
		}
	}
	pythonSources.Lock()
	pythonSources.entries = entries
	pythonSources.Unlock()
	return nil
}

func (d *Downloader) savePythonSource(item pythonSource, remove bool) error {
	pythonSources.Lock()
	defer pythonSources.Unlock()
	next := make(map[string]pythonSource, len(pythonSources.entries)+1)
	for id, value := range pythonSources.entries {
		next[id] = value
	}
	if remove {
		delete(next, item.ID)
	} else {
		next[item.ID] = item
	}
	items := make([]pythonSource, 0, len(next))
	for _, value := range next {
		items = append(items, value)
	}
	body, err := json.Marshal(items)
	if err != nil {
		return err
	}
	if err = writeNativeCacheFile(filepath.Join(d.pythonDirectory(), "registry.json"), body); err != nil {
		return errors.New("Python 站源登记保存失败，未应用更改")
	}
	pythonSources.entries = next
	return nil
}

type pythonNetworkTicket struct {
	ctx    context.Context
	source pythonSource
	cancel context.CancelFunc
}
type pythonHTTPBridge struct {
	mu      sync.Mutex
	base    string
	tickets map[string]pythonNetworkTicket
	proxies map[string]pythonSource
}

func (d *Downloader) pythonHTTPServer() (*pythonHTTPBridge, error) {
	d.pythonMu.Lock()
	defer d.pythonMu.Unlock()
	if d.pythonHTTP != nil {
		return d.pythonHTTP, nil
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	bridge := &pythonHTTPBridge{base: "http://" + listener.Addr().String(), tickets: map[string]pythonNetworkTicket{}, proxies: map[string]pythonSource{}}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { d.servePythonHTTP(bridge, w, r) }), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 35 * time.Second, WriteTimeout: 65 * time.Second, MaxHeaderBytes: 64 << 10}
	d.pythonHTTP = bridge
	go server.Serve(listener)
	return bridge, nil
}

func (d *Downloader) pythonCall(ctx context.Context, item pythonSource, operation string, params map[string]any) (map[string]any, error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	bridge, err := d.pythonHTTPServer()
	if err != nil {
		return nil, err
	}
	ticket := pythonRandomID()
	proxyKey := item.ID + ":" + item.Revision
	bridge.mu.Lock()
	bridge.tickets[ticket] = pythonNetworkTicket{ctx: ctx, source: item, cancel: cancel}
	proxyToken := ""
	for token, candidate := range bridge.proxies {
		if candidate.ID+":"+candidate.Revision == proxyKey {
			proxyToken = token
			break
		}
	}
	if proxyToken == "" {
		proxyToken = pythonRandomID()
		bridge.proxies[proxyToken] = item
	}
	bridge.mu.Unlock()
	defer func() { bridge.mu.Lock(); delete(bridge.tickets, ticket); bridge.mu.Unlock() }()
	if params == nil {
		params = map[string]any{}
	}
	storage := filepath.Join(filepath.Dir(d.pythonFile(item)), "state-"+item.Revision)
	if err := os.MkdirAll(storage, 0700); err != nil {
		return nil, err
	}
	params["instance"], params["operation"], params["file"] = proxyKey, operation, d.pythonFile(item)
	params["storage"], params["name"] = storage, strings.TrimSuffix(item.Filename, filepath.Ext(item.Filename))
	params["network"], params["proxy"] = bridge.base+"/net/"+ticket, bridge.base+"/proxy/"+proxyToken
	return callPython(ctx, params)
}

func (d *Downloader) pythonSourceCall(ctx context.Context, source, operation string, params map[string]any) (map[string]any, error) {
	pythonSources.RLock()
	item, found := pythonSources.entries[source]
	pythonSources.RUnlock()
	if !found || !item.Enabled {
		return nil, errors.New("Python 站源已禁用或删除")
	}
	if params == nil {
		params = map[string]any{}
	}
	params["activeSource"], params["activeRevision"] = source, item.Revision
	return d.pythonCall(ctx, item, operation, params)
}

func (engine *nativeEngine) importPythonSource(ctx context.Context, input nativeInput) (any, error) {
	d := engine.downloader
	d.pythonManageMu.Lock()
	defer d.pythonManageMu.Unlock()
	body, err := base64.StdEncoding.DecodeString(input.ScriptBody)
	if err != nil || len(body) == 0 || len(body) > 512<<10 {
		return nil, errors.New("请选择不超过 512 KiB 的 Python 单文件脚本")
	}
	filename := filepath.Base(strings.ReplaceAll(input.Filename, "\\", "/"))
	if !strings.EqualFold(filepath.Ext(filename), ".py") {
		return nil, errors.New("请选择 .py 文件")
	}
	digest := sha256.Sum256(body)
	item := pythonSource{ID: "py:" + pythonRandomID(), Filename: filename, Revision: hex.EncodeToString(digest[:]), Enabled: true, UpdatedAt: time.Now()}
	var previous pythonSource
	if input.Source != "" {
		pythonSources.RLock()
		previous, _ = pythonSources.entries[input.Source]
		pythonSources.RUnlock()
		if previous.ID == "" {
			return nil, errors.New("待更新的 Python 站源不存在")
		}
		item.ID, item.Enabled = previous.ID, previous.Enabled
	}
	for _, candidate := range pythonSourceSnapshot() {
		if candidate.Revision == item.Revision {
			return nil, errors.New("相同脚本已导入，无需重复导入")
		}
	}
	file := d.pythonFile(item)
	if err := os.MkdirAll(filepath.Dir(file), 0700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(file, body, 0600); err != nil {
		return nil, errors.New("脚本文件保存失败")
	}
	committed := false
	defer func() {
		if !committed {
			cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			d.pythonCall(cleanup, item, "drop", nil)
			os.Remove(file)
			os.RemoveAll(filepath.Join(filepath.Dir(file), "state-"+item.Revision))
		}
	}()
	metadata, err := d.pythonCall(ctx, item, "inspect", nil)
	if err != nil {
		return nil, err
	}
	item.Name, item.Search = nativeText(metadata["name"]), metadata["search"] == true
	if item.Name == "" {
		return nil, errors.New("脚本未返回站源名称")
	}
	if err := d.savePythonSource(item, false); err != nil {
		return nil, err
	}
	committed = true
	warnings := []string{}
	if previous.ID != "" {
		if err := engine.stopPythonSource(item.ID); err != nil {
			warnings = append(warnings, err.Error())
		}
		d.pythonCall(ctx, previous, "drop", nil)
		if err := os.Remove(d.pythonFile(previous)); err != nil && !os.IsNotExist(err) {
			warnings = append(warnings, "旧版私有脚本清理失败")
		}
		if err := os.RemoveAll(filepath.Join(filepath.Dir(d.pythonFile(previous)), "state-"+previous.Revision)); err != nil {
			warnings = append(warnings, "旧版私有会话清理失败")
		}
		if err := engine.clearPythonCatalog(item.ID); err != nil {
			warnings = append(warnings, "旧目录缓存清理尚未保存，新脚本已生效")
		}
	}
	return map[string]any{"items": pythonSourceSnapshot(), "warning": strings.Join(warnings, "；")}, nil
}

func (engine *nativeEngine) clearPythonCatalog(source string) error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	for key := range engine.catalogs {
		if key == source || strings.HasPrefix(key, source+"|") {
			delete(engine.catalogs, key)
			delete(engine.catalogStates, key)
			delete(engine.categoryOptions, key)
		}
	}
	delete(engine.categoryOptions, source)
	delete(engine.sourceRecords, source)
	return errors.Join(engine.writeCatalogDiskLocked(), engine.saveSourceRecordsLocked())
}

func (engine *nativeEngine) managePythonSource(ctx context.Context, input nativeInput) (any, error) {
	d := engine.downloader
	d.pythonManageMu.Lock()
	defer d.pythonManageMu.Unlock()
	pythonSources.RLock()
	item, found := pythonSources.entries[input.Source]
	pythonSources.RUnlock()
	if !found {
		return nil, errors.New("Python 站源不存在")
	}
	remove := input.Command == "delete"
	if input.Command != "enable" && input.Command != "disable" && !remove {
		return nil, errors.New("脚本站源操作无效")
	}
	if remove || input.Command == "disable" {
		item.Enabled = false
	} else {
		item.Enabled = true
	}
	if err := d.savePythonSource(item, false); err != nil {
		return nil, err
	}
	warning := ""
	if !item.Enabled {
		if err := engine.stopPythonSource(item.ID); err != nil {
			warning = err.Error()
		}
		d.pythonCall(ctx, item, "drop", nil)
		d.pythonMu.Lock()
		bridge := d.pythonHTTP
		d.pythonMu.Unlock()
		if bridge != nil {
			bridge.mu.Lock()
			for token, value := range bridge.proxies {
				if value.ID == item.ID {
					delete(bridge.proxies, token)
				}
			}
			bridge.mu.Unlock()
		}
	}
	if remove {
		if err := engine.clearPythonCatalog(item.ID); err != nil {
			warning = joinNativeWarnings(warning, "旧目录缓存清理尚未保存")
		}
		directory := filepath.Dir(d.pythonFile(item))
		if filepath.Dir(directory) != d.pythonDirectory() {
			return nil, errors.New("脚本目录无效")
		}
		if err := os.RemoveAll(directory); err != nil {
			return nil, errors.New("站源已禁用，但私有脚本文件清理失败，可重新删除")
		}
		if err := d.savePythonSource(item, true); err != nil {
			return nil, err
		}
	}
	return map[string]any{"items": pythonSourceSnapshot(), "warning": warning}, nil
}

func (d *Downloader) servePythonHTTP(bridge *pythonHTTPBridge, w http.ResponseWriter, r *http.Request) {
	if strings.HasPrefix(r.URL.Path, "/proxy/") {
		bridge.mu.Lock()
		item, found := bridge.proxies[strings.TrimPrefix(r.URL.Path, "/proxy/")]
		bridge.mu.Unlock()
		if !found || !pythonSourceRegistered(item.ID, true) || item.Revision != pythonSourceRevision(item.ID) {
			http.Error(w, "脚本站源不可用", 404)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
		defer cancel()
		params := map[string]any{}
		for key, values := range r.URL.Query() {
			if len(values) > 0 {
				params[key] = values[0]
			}
		}
		params["headers"] = r.Header
		result, err := d.pythonCall(ctx, item, "proxy", map[string]any{"params": params, "activeSource": item.ID, "activeRevision": item.Revision})
		if err != nil {
			http.Error(w, "脚本媒体代理失败", 502)
			return
		}
		body, err := base64.StdEncoding.DecodeString(nativeText(result["body"]))
		status, _ := strconv.Atoi(nativeText(result["status"]))
		if err != nil || status < 100 || status > 599 {
			http.Error(w, "脚本代理返回无效", 502)
			return
		}
		if headers, ok := result["headers"].(map[string]any); ok {
			for key, value := range headers {
				if !strings.EqualFold(key, "Content-Length") && !strings.EqualFold(key, "Transfer-Encoding") && !strings.EqualFold(key, "Connection") {
					w.Header().Set(key, nativeText(value))
				}
			}
		}
		w.Header().Set("Content-Type", nativeText(result["mime"]))
		w.WriteHeader(status)
		w.Write(body)
		return
	}
	bridge.mu.Lock()
	ticket, found := bridge.tickets[strings.TrimPrefix(r.URL.Path, "/net/")]
	bridge.mu.Unlock()
	if !strings.HasPrefix(r.URL.Path, "/net/") || !found || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	fail := func(message string) { json.NewEncoder(w).Encode(map[string]any{"ok": false, "error": message}) }
	var input struct {
		URL            string            `json:"url"`
		Method         string            `json:"method"`
		Headers        map[string]string `json:"headers"`
		Body           string            `json:"body"`
		Timeout        float64           `json:"timeout"`
		AllowRedirects *bool             `json:"allowRedirects"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 8<<20)).Decode(&input) != nil || !isProviderHTTPMediaURL(input.URL) {
		fail("脚本 HTTP 请求无效")
		return
	}
	body, err := base64.StdEncoding.DecodeString(input.Body)
	if err != nil {
		fail("脚本请求内容无效")
		return
	}
	ctx, cancel := context.WithTimeout(ticket.ctx, time.Duration(max(1, min(input.Timeout, 30)))*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, input.Method, input.URL, bytes.NewReader(body))
	if err != nil {
		fail("脚本 HTTP 请求无效")
		return
	}
	for key, value := range input.Headers {
		request.Header.Set(key, value)
	}
	if d.limiter != nil {
		release, err := d.limiter.acquire(ctx, request)
		if err != nil {
			fail("站源请求已暂停或超时")
			return
		}
		defer release()
	}
	client := *d.client
	client.Jar, _ = cookiejar.New(nil)
	client.Jar.SetCookies(request.URL, request.Cookies())
	cookies := []map[string]string{}
	collectCookies := func(response *http.Response) {
		path := response.Request.URL.Path
		if index := strings.LastIndex(path, "/"); index > 0 {
			path = path[:index]
		} else {
			path = "/"
		}
		for _, cookie := range response.Cookies() {
			cookies = append(cookies, map[string]string{"name": cookie.Name, "value": cookie.Value, "domain": firstNonEmpty(cookie.Domain, response.Request.URL.Hostname()), "path": firstNonEmpty(cookie.Path, path)})
		}
	}
	previousRedirect := client.CheckRedirect
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if input.AllowRedirects != nil && !*input.AllowRedirects {
			return http.ErrUseLastResponse
		}
		if request.Response != nil {
			collectCookies(request.Response)
		}
		if previousRedirect != nil {
			return previousRedirect(request, via)
		}
		if len(via) >= 10 {
			return errors.New("站源重定向次数过多")
		}
		return nil
	}
	response, err := client.Do(request)
	if err != nil {
		fail("站源网络请求失败或超时")
		return
	}
	defer response.Body.Close()
	body, err = io.ReadAll(io.LimitReader(response.Body, providerMaxBodyBytes+1))
	if err != nil || len(body) > providerMaxBodyBytes {
		fail("站源响应读取失败或超过 20 MiB")
		return
	}
	headers := map[string]string{}
	for key, values := range response.Header {
		headers[key] = strings.Join(values, ", ")
	}
	collectCookies(response)
	json.NewEncoder(w).Encode(map[string]any{"ok": true, "status": response.StatusCode, "url": response.Request.URL.String(), "headers": headers, "body": base64.StdEncoding.EncodeToString(body), "cookies": cookies})
}

func pythonDrama(source string, row map[string]any) Drama {
	id, title := nativeText(row["vod_id"]), nativeText(row["vod_name"])
	if id == "" || title == "" {
		return Drama{}
	}
	return Drama{ID: providerDramaID(source, id), Source: source, SourceID: id, Title: title, Name: title, Desc: cleanText(nativeText(row["vod_content"])), Cover: nativeText(row["vod_pic"]), CategoryName: nativeText(row["type_name"]), Remark: nativeText(row["vod_remarks"])}
}

func (d *Downloader) fetchPythonCatalog(ctx context.Context, source string, page int, category, query string) ([]Drama, bool, error) {
	result, err := d.pythonSourceCall(ctx, source, "catalog", map[string]any{"page": page, "category": category, "query": query})
	if err != nil {
		return nil, false, err
	}
	rows, valid := result["list"].([]any)
	if !valid {
		return nil, false, errors.New("脚本目录未返回 list 数组")
	}
	items := []Drama{}
	for _, raw := range rows {
		if row, ok := raw.(map[string]any); ok {
			if drama := pythonDrama(source, row); drama.ID != "" {
				items = append(items, drama)
			}
		}
	}
	pages, _ := strconv.Atoi(nativeText(result["pagecount"]))
	actual, _ := strconv.Atoi(nativeText(result["page"]))
	if actual > 0 && actual != page {
		return nil, false, errors.New("脚本返回页码与请求不符")
	}
	return items, pages > page, nil
}

type pythonEpisodeRoute struct {
	Flag  string `json:"flag"`
	ID    string `json:"id"`
	Title string `json:"title"`
}

func (d *Downloader) fetchPythonDetail(ctx context.Context, source, id string) (Drama, []Chapter, error) {
	revision := pythonSourceRevision(source)
	result, err := d.pythonSourceCall(ctx, source, "detail", map[string]any{"id": id})
	if err != nil {
		return Drama{}, nil, err
	}
	if revision != pythonSourceRevision(source) || !pythonSourceRegistered(source, true) {
		return Drama{}, nil, context.Canceled
	}
	return pythonDetailResult(source, id, result)
}

func pythonDetailResult(source, id string, result map[string]any) (Drama, []Chapter, error) {
	rows, _ := result["list"].([]any)
	var row map[string]any
	for _, raw := range rows {
		if value, ok := raw.(map[string]any); ok && nativeText(value["vod_id"]) == id {
			row = value
			break
		}
	}
	if row == nil {
		return Drama{}, nil, errors.New("脚本详情未返回所选剧集")
	}
	drama := pythonDrama(source, row)
	flags := strings.Split(nativeText(row["vod_play_from"]), "$$$")
	groups := strings.Split(nativeText(row["vod_play_url"]), "$$$")
	routes := map[string][]pythonEpisodeRoute{}
	order := []string{}
	for line, group := range groups {
		flag := ""
		if line < len(flags) {
			flag = flags[line]
		}
		seen := map[string]bool{}
		for index, entry := range strings.Split(group, "#") {
			title, address, named := strings.Cut(entry, "$")
			if !named {
				address, title = title, fmt.Sprintf("第%d集", index+1)
			}
			title = strings.TrimSpace(title)
			if title == "" {
				title = fmt.Sprintf("第%d集", index+1)
			}
			if strings.TrimSpace(address) == "" || seen[title] {
				continue
			}
			seen[title] = true
			if len(routes[title]) == 0 {
				order = append(order, title)
			}
			routes[title] = append(routes[title], pythonEpisodeRoute{Flag: flag, ID: address, Title: title})
		}
	}
	chapters := []Chapter{}
	for index, title := range order {
		entries := routes[title]
		body, _ := json.Marshal(entries)
		key := sha256.Sum256([]byte(title))
		chapters = append(chapters, Chapter{ID: providerChapterID(source, id, hex.EncodeToString(key[:8])), Source: source, Title: title, VideoURL: "python-spider://" + base64.RawURLEncoding.EncodeToString(body), CurrentEpisode: json.RawMessage(strconv.Itoa(index + 1))})
	}
	drama.TotalEpisode = len(chapters)
	return drama, chapters, nil
}

func (d *Downloader) resolvePythonMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, id, valid := splitProviderDramaID(task.DramaID)
	if !valid || !pythonSourceRegistered(source, true) {
		return providerMedia{}, errors.New("Python 站源不可用")
	}
	_, chapters, err := d.fetchPythonDetail(ctx, source, id)
	if err != nil {
		return providerMedia{}, err
	}
	var chapter Chapter
	for _, entry := range chapters {
		if entry.ID == task.Chapter.ID {
			chapter = entry
			break
		}
	}
	if chapter.ID == "" {
		return providerMedia{}, errors.New("脚本章节已变化，请刷新详情")
	}
	body, err := base64.RawURLEncoding.DecodeString(strings.TrimPrefix(chapter.VideoURL, "python-spider://"))
	var entries []pythonEpisodeRoute
	if err != nil || json.Unmarshal(body, &entries) != nil {
		return providerMedia{}, errors.New("脚本播放线路无效")
	}
	variants := []providerMedia{}
	for _, route := range entries {
		result, callErr := d.pythonSourceCall(ctx, source, "play", map[string]any{"flag": route.Flag, "id": route.ID})
		if callErr != nil {
			err = callErr
			continue
		}
		if result["parse"] == true || result["jx"] == true || nativeText(result["parse"]) == "1" || nativeText(result["jx"]) == "1" {
			err = errors.New("该脚本线路需要额外网页解析，当前未返回直接播放地址")
			continue
		}
		addresses := []string{}
		if values, ok := result["url"].([]any); ok {
			for _, value := range values {
				if address := nativeText(value); isProviderHTTPMediaURL(address) {
					addresses = append(addresses, address)
				}
			}
		} else if address := nativeText(result["url"]); isProviderHTTPMediaURL(address) {
			addresses = append(addresses, address)
		}
		if len(addresses) == 0 {
			err = errors.New("脚本未返回 HTTP 播放地址")
			continue
		}
		headers := map[string]string{}
		raw := result["header"]
		if text, ok := raw.(string); ok {
			json.Unmarshal([]byte(text), &raw)
		}
		if object, ok := raw.(map[string]any); ok {
			for key, value := range object {
				headers[key] = nativeText(value)
			}
		}
		for _, address := range addresses {
			parsed, _ := url.Parse(address)
			credentials := &providerMediaCredentials{origin: providerMediaOrigin(parsed), headers: headers}
			for key, value := range headers {
				switch strings.ToLower(key) {
				case "cookie":
					credentials.cookie = value
				case "referer":
					credentials.referer = value
				case "user-agent":
					credentials.userAgent = value
				}
			}
			variants = append(variants, providerMedia{URL: address, Referer: credentials.referer, credentials: credentials, pythonSource: source})
		}
	}
	if len(variants) == 0 {
		return providerMedia{}, firstPythonError(err)
	}
	media := variants[0]
	media.Variants = variants
	return media, nil
}

func firstPythonError(err error) error {
	if err != nil {
		return err
	}
	return errors.New("脚本未返回可播放线路")
}
