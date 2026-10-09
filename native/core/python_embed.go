package core

/*
#cgo linux LDFLAGS: -ldl
#include "python_embed.h"
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"
)

type pythonRuntimeConfig struct {
	Home        string   `json:"home"`
	Library     string   `json:"library"`
	Search      []string `json:"search"`
	WebResolver string   `json:"webResolver"`
}

var pythonInterpreter = struct {
	gate   chan struct{}
	mu     sync.Mutex
	config pythonRuntimeConfig
	ready  bool
}{gate: make(chan struct{}, 1)}

func configurePythonRuntime(config pythonRuntimeConfig) {
	if config.Home == "" || config.Library == "" || len(config.Search) == 0 {
		return
	}
	pythonInterpreter.mu.Lock()
	defer pythonInterpreter.mu.Unlock()
	if !pythonInterpreter.ready {
		pythonInterpreter.config = config
	} else if config.WebResolver != "" {
		pythonInterpreter.config.WebResolver = config.WebResolver
	}
}

func callPython(ctx context.Context, request map[string]any) (map[string]any, error) {
	select {
	case pythonInterpreter.gate <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	defer func() { <-pythonInterpreter.gate }()
	if source := nativeText(request["activeSource"]); source != "" && (!pythonSourceRegistered(source, true) || nativeText(request["activeRevision"]) != pythonSourceRevision(source)) {
		return nil, context.Canceled
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	pythonInterpreter.mu.Lock()
	if !pythonInterpreter.ready {
		config := pythonInterpreter.config
		if config.Library == "" || config.Home == "" || len(config.Search) == 0 {
			pythonInterpreter.mu.Unlock()
			return nil, errors.New("安装包未包含 Python 站源运行环境，请使用支持脚本导入的完整安装包")
		}
		if _, err := os.Stat(filepath.Join(config.Home, "guo_spider.py")); err != nil {
			pythonInterpreter.mu.Unlock()
			return nil, errors.New("Python 站源运行资源缺失，请重新安装完整安装包")
		}
		search := strings.Join(config.Search, string(os.PathListSeparator))
		library, home, paths := C.CString(config.Library), C.CString(config.Home), C.CString(search)
		status := C.guo_python_initialize(library, home, paths)
		C.free(unsafe.Pointer(library))
		C.free(unsafe.Pointer(home))
		C.free(unsafe.Pointer(paths))
		if status != 0 {
			pythonInterpreter.mu.Unlock()
			return nil, errors.New("Python 动态库加载失败，请检查安装包与设备架构")
		}
		pythonInterpreter.ready = true
	}
	pythonInterpreter.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		request["deadline"] = float64(deadline.UnixMilli()) / 1000
	}
	cancelFile := filepath.Join(nativeText(request["storage"]), "cancel-"+pythonRandomID())
	request["cancelFile"] = cancelFile
	cancelDone := make(chan struct{})
	stopCancel := context.AfterFunc(ctx, func() {
		os.WriteFile(cancelFile, nil, 0600)
		close(cancelDone)
	})
	defer func() {
		if !stopCancel() {
			<-cancelDone
		}
		os.Remove(cancelFile)
	}()
	body, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	code := C.CString("try:\n import guo_spider\n _guo_result = guo_spider.dispatch_base64('" + base64.StdEncoding.EncodeToString(body) + "')\nexcept BaseException as _guo_failure:\n import json\n _guo_message = 'Python 运行资源加载失败：' + type(_guo_failure).__name__\n if isinstance(_guo_failure, ModuleNotFoundError):\n  _guo_message += '（' + str(_guo_failure.name or '未知模块') + '）'\n _guo_result = json.dumps({'ok':False,'error':_guo_message})")
	output := C.guo_python_execute(code)
	C.free(unsafe.Pointer(code))
	if output == nil {
		return nil, errors.New("Python 运行环境执行失败")
	}
	defer C.free(unsafe.Pointer(output))
	var envelope struct {
		OK      bool           `json:"ok"`
		Data    map[string]any `json:"data"`
		Error   string         `json:"error"`
		Network struct {
			Host   string `json:"host"`
			Status int    `json:"status"`
		} `json:"network"`
	}
	decoder := json.NewDecoder(strings.NewReader(C.GoString(output)))
	decoder.UseNumber()
	if err := decoder.Decode(&envelope); err != nil {
		return nil, errors.New("Python 返回的数据格式无效")
	}
	if trace, _ := ctx.Value(sourceTraceKey{}).(*sourceResponseTrace); trace != nil && envelope.Network.Host != "" {
		trace.mu.Lock()
		trace.last.Host = envelope.Network.Host
		trace.last.HTTPStatus = envelope.Network.Status
		trace.mu.Unlock()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !envelope.OK {
		return nil, errors.New(envelope.Error)
	}
	return envelope.Data, nil
}
