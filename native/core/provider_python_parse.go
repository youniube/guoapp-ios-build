package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"time"
)

func (d *Downloader) resolvePythonParsedMedia(ctx context.Context, address, prefix string, headers map[string]string) (string, map[string]string, error) {
	if prefix == "" && maccmsDirectMediaURL(address) != "" {
		return address, headers, nil
	}
	base := ""
	if parsed, err := url.Parse(address); err == nil && isProviderHTTPMediaURL(address) {
		base = parsed.Scheme + "://" + parsed.Host
	}
	jar, _ := cookiejar.New(nil)
	c := &attachedClient{d: d, p: attachedProvider{name: "Python 站源", base: base}, jar: jar,
		access: attachedAccess{Headers: headers}, catpaw: &catpawState{base: base, headers: headers}}
	pages := []string{}
	if prefix != "" {
		target := prefix + address
		attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
		resolved, extra, err := c.cpParse(attempt, prefix, address)
		cancel()
		if err == nil {
			return resolved, pythonParsedHeaders(address, resolved, headers, extra), nil
		}
		if isProviderHTTPMediaURL(target) {
			pages = append(pages, target)
		}
	}
	if base != "" {
		attempt, cancel := context.WithTimeout(ctx, 5*time.Second)
		direct, extra, err := c.cpParse(attempt, "", address)
		cancel()
		if err == nil {
			return direct, pythonParsedHeaders(address, direct, headers, extra), nil
		}
		pages = append(pages, address)
	}
	var parsers []map[string]any
	_ = json.Unmarshal([]byte(d.attachedAccess["catpaw_playback"].Settings["parses"]), &parsers)
	for _, parser := range parsers {
		if err := ctx.Err(); err != nil {
			return "", nil, err
		}
		api := mapString(parser, "url")
		if api == "" {
			continue
		}
		if nativeText(parser["type"]) == "0" {
			if target := api + address; isProviderHTTPMediaURL(target) {
				pages = append(pages, target)
			}
			continue
		}
		attempt, cancel := context.WithTimeout(ctx, 2*time.Second)
		resolved, extra, err := c.cpParse(attempt, api, address)
		cancel()
		if err == nil {
			return resolved, pythonParsedHeaders(address, resolved, headers, extra), nil
		}
	}
	return d.resolvePythonWebMedia(ctx, address, pages, headers)
}

func pythonParsedHeaders(original, media string, headers, extra map[string]string) map[string]string {
	result := map[string]string{}
	for key, value := range headers {
		result[http.CanonicalHeaderKey(key)] = value
	}
	for key, value := range extra {
		result[http.CanonicalHeaderKey(key)] = value
	}
	return result
}

func (d *Downloader) resolvePythonWebMedia(ctx context.Context, original string, pages []string, headers map[string]string) (string, map[string]string, error) {
	pythonInterpreter.mu.Lock()
	endpoint := pythonInterpreter.config.WebResolver
	pythonInterpreter.mu.Unlock()
	callback, err := url.Parse(endpoint)
	if err != nil || callback.Scheme != "http" || callback.Hostname() != "127.0.0.1" || callback.Port() == "" {
		return "", nil, errors.New("该线路需要网页解析，请在应用前台打开并使用包含网页解析组件的安装包")
	}
	ctx, cancel := context.WithTimeout(ctx, 28*time.Second)
	defer cancel()
	body, err := json.Marshal(map[string]any{"pages": pages, "headers": headers, "origin": original})
	if err != nil {
		return "", nil, err
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return "", nil, err
	}
	request.Header.Set("Content-Type", "application/json")
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		return "", nil, errors.New("网页解析超时或已取消")
	}
	defer response.Body.Close()
	var result struct {
		URL     string            `json:"url"`
		Headers map[string]string `json:"headers"`
		Error   string            `json:"error"`
	}
	if json.NewDecoder(io.LimitReader(response.Body, 64<<10)).Decode(&result) != nil || !isProviderHTTPMediaURL(result.URL) {
		return "", nil, errors.New("网页与解析线路未返回可播放的媒体地址")
	}
	return result.URL, pythonParsedHeaders(original, result.URL, headers, result.Headers), nil
}
