import ast
import base64
import contextlib
import email.message
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import re
import sys
import threading
import time
import tokenize
import types
import urllib.request

_instances = {}
_current = {}
_urlopen = urllib.request.urlopen


class DiscardOutput:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


class NetworkResponse(io.BytesIO):
    def __init__(self, response):
        super().__init__(response.content)
        self.status = self.code = response.status_code
        self.url = response.url
        self.headers = email.message.Message()
        for key, value in response.headers.items():
            self.headers[key] = value

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def info(self):
        return self.headers


def _urllib_open(url, data=None, timeout=20, **kwargs):
    import requests
    if isinstance(url, urllib.request.Request):
        method, address, headers = url.get_method(), url.full_url, dict(url.header_items())
        data = url.data if data is None else data
    else:
        method, address, headers = ('POST' if data is not None else 'GET'), str(url), {}
    prepared = requests.Request(method, address, headers=headers, data=data).prepare()
    response = _network(prepared, timeout=timeout)
    if response.status_code >= 400:
        raise urllib.error.HTTPError(address, response.status_code, 'HTTP request failed', response.headers, NetworkResponse(response))
    return NetworkResponse(response)


def _patch_crypto_frameworks():
    if sys.platform != 'ios':
        return
    from Crypto.Util import _raw_api
    if getattr(_raw_api, '_guo_frameworks', False):
        return
    original = _raw_api.load_pycryptodome_raw_lib

    def load(name, cdecl):
        folder = Path(_raw_api.__file__).parents[2]
        module = folder.joinpath(*name.split('.'))
        for marker in module.parent.glob(module.name + '*.fwork'):
            binary = Path(__file__).parent.parent / marker.read_text(encoding='utf-8').strip()
            return _raw_api.load_lib(str(binary), cdecl)
        return original(name, cdecl)

    _raw_api.load_pycryptodome_raw_lib = load
    _raw_api._guo_frameworks = True


class ScriptFailure(Exception):
    pass


def _network(prepared, **kwargs):
    import requests
    import urllib3
    timeout = kwargs.get("timeout") or 20
    if isinstance(timeout, tuple):
        timeout = max(value or 20 for value in timeout)
    timeout = max(1, min(float(timeout), 30, _current["deadline"] - time.time()))
    body = prepared.body or b""
    if isinstance(body, str):
        body = body.encode()
    if not isinstance(body, bytes):
        raise ScriptFailure("暂不支持流式上传")
    payload = json.dumps({"url": prepared.url, "method": prepared.method,
                          "headers": dict(prepared.headers),
                          "body": base64.b64encode(body).decode(), "timeout": timeout,
                          "allowRedirects": kwargs.get('allow_redirects', True)}).encode()
    request = urllib.request.Request(_current["network"], data=payload,
                                     headers={"Content-Type": "application/json"})
    try:
        with _urlopen(request, timeout=timeout + 2) as response:
            envelope = json.load(response)
    except Exception:
        raise ScriptFailure("站源网络请求失败或超时") from None
    if not envelope.get("ok"):
        raise ScriptFailure(envelope.get("error", "站源请求失败"))
    response = requests.Response()
    response.status_code = envelope["status"]
    response.headers = requests.structures.CaseInsensitiveDict(envelope["headers"])
    response.url = envelope["url"]
    response.request = prepared
    response.encoding = requests.utils.get_encoding_from_headers(response.headers)
    response.raw = urllib3.HTTPResponse(body=io.BytesIO(base64.b64decode(envelope["body"])), headers=response.headers,
                                       status=response.status_code, preload_content=False)
    response._content = response.raw.read(decode_content=True)
    response._content_consumed = True
    for cookie in envelope.get("cookies", []):
        response.cookies.set(cookie["name"], cookie["value"], domain=cookie["domain"], path=cookie["path"])
    return response


def _send(session, prepared, **kwargs):
    response = _network(prepared, **kwargs)
    session.cookies.update(response.cookies)
    return response


class Spider:
    def __init__(self):
        import requests
        self.session = requests.Session()
        self._initialize_cache()

    def _initialize_cache(self):
        self._cache_path = os.path.join(_current["storage"], "cache.json")
        self._cache = {}
        try:
            with open(self._cache_path, encoding="utf-8") as source:
                self._cache = json.load(source)
        except (OSError, ValueError):
            pass

    def fetch(self, url, **kwargs):
        import requests
        kwargs.setdefault("timeout", 20)
        return getattr(self, 'session', requests.Session()).request(kwargs.pop('method', 'GET'), url, **kwargs)

    def post(self, url, **kwargs):
        kwargs.setdefault("timeout", 20)
        return self.session.post(url, **kwargs)

    def getCache(self, key):
        return self._cache.get(str(key))

    def setCache(self, key, value):
        self._cache[str(key)] = value
        self._save_cache()

    def _save_cache(self):
        body = json.dumps(self._cache, ensure_ascii=False)
        if len(body.encode()) > 4 * 1024 * 1024:
            raise ScriptFailure("脚本缓存超过 4 MiB")
        temporary = self._cache_path + ".tmp"
        with open(temporary, "w", encoding="utf-8") as destination:
            destination.write(body)
        os.replace(temporary, self._cache_path)

    def delCache(self, key):
        self._cache.pop(str(key), None)
        self._save_cache()

    def getProxyUrl(self, local=True):
        return _current["proxy"] + '?do=py'

    def html(self, content):
        from lxml import etree
        return etree.HTML(content)

    def cleanText(self, text):
        return re.sub(r"<[^>]*>", "", str(text)).strip()

    def log(self, *args):
        pass

    def destroy(self):
        self.session.close()


_base = types.ModuleType("base")
_base.__path__ = []
_spider = types.ModuleType("base.spider")
_spider.Spider = Spider
_base.spider = _spider
sys.modules["base"] = _base
sys.modules["base.spider"] = _spider


def _check_dependencies(tree):
    names = set()
    for node in tree.body:
        if isinstance(node, ast.Import):
            names.update(alias.name.split(".")[0] for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level:
                raise ScriptFailure("单文件导入不支持相对模块依赖")
            if node.module:
                names.add(node.module.split(".")[0])
    for name in sorted(names - {"base", "__future__"}):
        if importlib.util.find_spec(name) is None:
            raise ScriptFailure("缺少 Python 依赖：" + name)


def _object(value):
    if isinstance(value, str):
        value = json.loads(value)
    if not isinstance(value, dict):
        raise ScriptFailure("脚本返回值必须为字典或 JSON 对象")
    return value


def _call(instance, name, arguments):
    method = getattr(instance, name, None)
    if not callable(method):
        raise ScriptFailure("脚本缺少方法：" + name)
    signature = inspect.signature(method)
    for count in range(len(arguments), -1, -1):
        try:
            signature.bind(*arguments[:count])
        except TypeError:
            continue
        return method(*arguments[:count])
    raise ScriptFailure("脚本方法参数不兼容：" + name)


def _load(request):
    key = request["instance"]
    if key in _instances:
        return _instances[key]
    with tokenize.open(request["file"]) as source:
        content = source.read()
    tree = ast.parse(content, filename="imported_source.py")
    _check_dependencies(tree)
    module = types.ModuleType("guo_source_" + key.replace("-", "_").replace(":", "_"))
    module.__file__ = request["file"]
    sys.modules[module.__name__] = module
    try:
        exec(compile(tree, "imported_source.py", "exec"), module.__dict__)
        factory = getattr(module, "Spider", None)
        if not inspect.isclass(factory) or factory is Spider:
            raise ScriptFailure("脚本需要定义 Spider 类")
        instance = factory()
        if isinstance(instance, Spider):
            if not hasattr(instance, 'session'):
                import requests
                instance.session = requests.Session()
            if not hasattr(instance, '_cache_path'):
                Spider._initialize_cache(instance)
        for name in ("homeContent", "categoryContent", "detailContent", "playerContent"):
            if not callable(getattr(instance, name, None)):
                raise ScriptFailure("脚本缺少方法：" + name)
        _call(instance, "init", [request.get("extend", "")])
        home = _object(_call(instance, "homeContent", [False]))
        if not isinstance(home.get("class", []), list):
            raise ScriptFailure("脚本分类返回格式无效")
        name = _call(instance, "getName", []) if callable(getattr(instance, "getName", None)) else ""
        metadata = {"name": str(name or request.get("name", "Python 站源"))[:80],
                    "categories": home.get("class", []), "home": home,
                    "search": callable(getattr(instance, "searchContent", None))}
        _instances[key] = (instance, metadata, module.__name__)
        return _instances[key]
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise


def _drop(key):
    entry = _instances.pop(key, None)
    if entry:
        try:
            method = getattr(entry[0], "destroy", None)
            if callable(method):
                method()
        finally:
            sys.modules.pop(entry[2], None)


def _dispatch(request):
    import requests
    requests.sessions.Session.send = _send
    urllib.request.urlopen = _urllib_open
    _patch_crypto_frameworks()
    sys.dont_write_bytecode = True
    _current.clear()
    _current.update(request)
    operation = request["operation"]
    if operation == "drop":
        _drop(request["instance"])
        return {}
    instance, metadata, _ = _load(request)
    if operation in ("inspect", "categories"):
        return metadata
    if operation == "catalog":
        if request.get("query"):
            return _object(_call(instance, "searchContent", [request["query"], False, str(request["page"])]))
        category = request.get("category", "")
        if not category:
            if request["page"] == 1 and callable(getattr(instance, "homeVideoContent", None)):
                value = _object(_call(instance, "homeVideoContent", []))
                value.setdefault("pagecount", 1)
                return value
            categories = metadata["categories"]
            category = str(categories[0].get("type_id", "")) if categories else ""
        return _object(_call(instance, "categoryContent", [category, str(request["page"]), False, {}]))
    if operation == "detail":
        return _object(_call(instance, "detailContent", [[request["id"]]]))
    if operation == "play":
        return _object(_call(instance, "playerContent", [request["flag"], request["id"], []]))
    if operation == "proxy":
        value = _call(instance, "localProxy", [request["params"]])
        if not isinstance(value, (tuple, list)) or len(value) < 3:
            raise ScriptFailure("localProxy 返回格式无效")
        body = value[2]
        if isinstance(body, str):
            body = body.encode()
        if not isinstance(body, bytes):
            raise ScriptFailure("localProxy 需要返回文本或字节内容")
        if len(body) > 20 * 1024 * 1024:
            raise ScriptFailure("localProxy 内容超过 20 MiB")
        return {"status": int(value[0]), "mime": str(value[1]),
                "body": base64.b64encode(body).decode(),
                "headers": dict(value[3]) if len(value) > 3 and isinstance(value[3], dict) else {}}
    raise ScriptFailure("未知脚本操作")


def dispatch_base64(encoded):
    request = json.loads(base64.b64decode(encoded))
    deadline = request.get("deadline", time.time() + 60)
    ticks = 0

    def trace(frame, event, arg):
        nonlocal ticks
        ticks += 1
        if time.time() > deadline:
            raise TimeoutError()
        if ticks % 64 == 0 and os.path.exists(request.get('cancelFile', '')):
            raise TimeoutError()
        return trace

    previous = sys.gettrace()
    try:
        sys.settrace(trace)
        with contextlib.redirect_stdout(DiscardOutput()), contextlib.redirect_stderr(DiscardOutput()):
            data = _dispatch(request)
        return json.dumps({"ok": True, "data": data}, ensure_ascii=False)
    except BaseException as error:
        sys.settrace(previous)
        if isinstance(error, ScriptFailure):
            message = str(error)
        elif isinstance(error, SyntaxError):
            message = "Python 语法错误，第 " + str(error.lineno or 0) + " 行"
        elif isinstance(error, ModuleNotFoundError):
            message = "缺少 Python 依赖：" + str(error.name or "未知模块")
        elif isinstance(error, TimeoutError):
            message = "脚本运行超时"
        else:
            message = "脚本执行失败：" + type(error).__name__
            traceback = error.__traceback__
            while traceback:
                if traceback.tb_frame.f_code.co_filename == "imported_source.py":
                    message += "，脚本第 " + str(traceback.tb_lineno) + " 行"
                traceback = traceback.tb_next
        return json.dumps({"ok": False, "error": message}, ensure_ascii=False)
    finally:
        sys.settrace(previous)
