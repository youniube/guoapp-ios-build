import ast
import base64
import contextlib
import email.message
import gzip
import http.client
import hashlib
import inspect
import io
import json
import os
from pathlib import Path
import re
import sys
import ssl
import threading
import tempfile
import time
import tokenize
import types
import urllib.request

_instances = {}
_context = threading.local()
_urlopen = urllib.request.urlopen
_http_connection = http.client.HTTPConnection
_https_connection = http.client.HTTPSConnection
_thread_start = threading.Thread.start
_gettempdir = tempfile.gettempdir


def _current():
    return getattr(_context, 'request', {})


def _temporary_directory():
    return _current().get('storage') or _gettempdir()


class DiscardOutput:
    def write(self, value):
        return len(value)

    def flush(self):
        pass


class NetworkResponse(io.BytesIO):
    def __init__(self, response):
        super().__init__(response.content)
        self.status = self.code = response.status_code
        self.reason = response.reason or str(response.status_code)
        self.msg = self.reason
        self.length = len(response.content)
        self.will_close = True
        self.chunked = False
        self.url = response.url
        self.headers = email.message.Message()
        values = getattr(response, '_guo_header_values', None)
        if values:
            for key, entries in values.items():
                for value in entries:
                    self.headers[key] = value
        else:
            for key, value in response.headers.items():
                self.headers[key] = value

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def info(self):
        return self.headers

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def getheaders(self):
        return list(self.headers.items())


def _urllib_open(url, data=None, timeout=20, **kwargs):
    address = url.full_url if isinstance(url, urllib.request.Request) else str(url)
    _current()['_network'] = {'host': urllib.parse.urlparse(address).hostname or '', 'status': 0}
    try:
        return _urlopen(url, data=data, timeout=timeout, **kwargs)
    except Exception as error:
        _network_failure(address, error, 'urllib')
        raise


def _network_failure(address, error, stage):
    current = _current()
    previous = current.get('_network', {})
    message = str(error) if isinstance(error, ScriptFailure) else stage + ' 请求失败：' + type(error).__name__
    status = getattr(error, 'code', 0) or previous.get('status', 0)
    if status >= 400:
        message = '站源返回 HTTP ' + str(status)
    current['_network'] = {'host': urllib.parse.urlparse(address).hostname or '',
                           'status': status, 'error': message}


class BridgeHTTPConnection(_http_connection):
    scheme = 'http'

    def request(self, method, url, body=None, headers=None, *, encode_chunked=False):
        import requests
        host = getattr(self, '_tunnel_host', None) or self.host
        port = getattr(self, '_tunnel_port', None) or self.port
        host = '[' + host + ']' if ':' in host and not host.startswith('[') else host
        address = url if url.startswith(('http://', 'https://')) else self.scheme + '://' + host + ':' + str(port) + url
        prepared = requests.Request(method, address, headers=headers or {}, data=body).prepare()
        prepared.url = address
        self._prepared = prepared

    def getresponse(self):
        timeout = self.timeout if isinstance(self.timeout, (int, float)) else 20
        response = _network(self._prepared, timeout=timeout, allow_redirects=False,
                            verify=getattr(self, '_verify', True), decode_content=False)
        return NetworkResponse(response)

    def close(self):
        self._prepared = None


class BridgeHTTPSConnection(BridgeHTTPConnection):
    scheme = 'https'
    default_port = 443

    def __init__(self, host, port=None, *, context=None, **kwargs):
        super().__init__(host, port=port, **kwargs)
        self._verify = context is None or context.verify_mode != ssl.CERT_NONE


def _start_thread(thread, *args, **kwargs):
    request = dict(_current())
    if request:
        request['network'] = request.get('backgroundNetwork', request['network'])
        run = thread.run

        def run_with_context():
            _context.request = request
            try:
                return run()
            finally:
                _context.request = {}

        thread.run = run_with_context
    return _thread_start(thread, *args, **kwargs)


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
    current = _current()
    current['_network'] = {'host': urllib.parse.urlparse(prepared.url).hostname or '', 'status': 0}
    remaining = current.get('deadline', time.time() + 60) - time.time()
    if remaining <= 0:
        error = ScriptFailure('脚本运行超时')
        _network_failure(prepared.url, error, 'network')
        raise error
    timeout = max(.1, min(float(timeout), 30, remaining))
    body = prepared.body or b""
    if isinstance(body, str):
        body = body.encode()
    if not isinstance(body, bytes):
        raise ScriptFailure("暂不支持流式上传")
    payload = json.dumps({"url": prepared.url, "method": prepared.method,
                          "headers": dict(prepared.headers),
                          "body": base64.b64encode(body).decode(), "timeout": timeout,
                          "allowRedirects": kwargs.get('allow_redirects', True),
                          "verify": kwargs.get('verify', True) is not False}).encode()
    endpoint = urllib.parse.urlparse(current['network'])
    connection = _http_connection(endpoint.hostname, endpoint.port, timeout=timeout + 2)
    try:
        connection.request('POST', endpoint.path, body=payload, headers={'Content-Type': 'application/json'})
        envelope = json.loads(connection.getresponse().read())
    except Exception as error:
        failure = ScriptFailure('Python 网络桥接失败：' + type(error).__name__)
        _network_failure(prepared.url, failure, 'bridge')
        raise failure from None
    finally:
        connection.close()
    if not envelope.get("ok"):
        error = ScriptFailure(envelope.get("error", "站源请求失败"))
        _network_failure(prepared.url, error, 'network')
        raise error
    current['_network'] = {'host': urllib.parse.urlparse(envelope['url']).hostname or '',
                           'status': envelope['status']}
    response = requests.Response()
    response.status_code = envelope["status"]
    response.reason = envelope.get('reason', '')
    response.headers = requests.structures.CaseInsensitiveDict(envelope["headers"])
    response._guo_header_values = envelope.get('headerValues')
    response.url = envelope["url"]
    response.request = prepared
    response.encoding = requests.utils.get_encoding_from_headers(response.headers)
    response.raw = urllib3.HTTPResponse(body=io.BytesIO(base64.b64decode(envelope["body"])), headers=response.headers,
                                       status=response.status_code, preload_content=False)
    response._content = response.raw.read(decode_content=kwargs.get('decode_content', True))
    response._content_consumed = True
    if 'json' in response.headers.get('Content-Type', '').lower() and len(response.content) <= 1024 * 1024:
        try:
            content = response.content
            if content.startswith(b'\x1f\x8b'):
                content = gzip.decompress(content)
            value = json.loads(content)
            code = value.get('code') if isinstance(value, dict) else None
            if isinstance(code, int):
                current['_network']['apiCode'] = code
                if code == 1004:
                    current['_apiFailure'] = '站源接口返回状态 1004（HTTP ' + str(response.status_code) + '）'
        except (ValueError, OSError, EOFError):
            pass
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
        self._http_session = self.session = requests.Session()
        self._initialize_cache()

    def _initialize_cache(self):
        self._cache_lock = threading.RLock()
        self._cache_path = os.path.join(_current()["storage"], "cache.json")
        self._cache = {}
        try:
            with open(self._cache_path, encoding="utf-8") as source:
                self._cache = json.load(source)
        except (OSError, ValueError):
            pass

    def fetch(self, url, headers=None, **kwargs):
        kwargs.setdefault("timeout", 20)
        if headers is not None:
            kwargs['headers'] = headers
        return self._request_session().request(kwargs.pop('method', 'GET'), url, **kwargs)

    def _request_session(self):
        import requests
        session = getattr(self, 'session', None)
        if isinstance(session, requests.Session):
            return session
        if not hasattr(self, '_http_session'):
            self._http_session = requests.Session()
        return self._http_session

    def post(self, url, **kwargs):
        kwargs.setdefault("timeout", 20)
        return self._request_session().post(url, **kwargs)

    def getCache(self, key):
        with self._cache_lock:
            return self._cache.get(str(key))

    def setCache(self, key, value):
        with self._cache_lock:
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
        with self._cache_lock:
            self._cache.pop(str(key), None)
            self._save_cache()

    def getProxyUrl(self, local=True):
        return _current()["proxy"] + '?do=py'

    def html(self, content):
        from lxml import etree
        return etree.HTML(content)

    def cleanText(self, text):
        return re.sub(r"<[^>]*>", "", str(text)).strip()

    def log(self, *args):
        pass

    def destroy(self):
        for name in ('session', '_http_session'):
            close = getattr(getattr(self, name, None), 'close', None)
            if callable(close):
                close()


_base = types.ModuleType("base")
_base.__path__ = []
_spider = types.ModuleType("base.spider")
_spider.Spider = Spider
_base.spider = _spider
sys.modules["base"] = _base
sys.modules["base.spider"] = _spider


def _object(value):
    if isinstance(value, str):
        value = json.loads(value)
    if isinstance(value, list):
        value = {'list': value}
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
            if not hasattr(instance, '_cache_lock'):
                instance._cache_lock = threading.RLock()
        for name in ("homeContent", "categoryContent", "detailContent", "playerContent"):
            if not callable(getattr(instance, name, None)):
                raise ScriptFailure("脚本缺少方法：" + name)
        _call(instance, "init", [request.get("extend", "")])
        name = _call(instance, "getName", []) if callable(getattr(instance, "getName", None)) else ""
        metadata = {"name": str(name or request.get("name", "Python 站源"))[:80],
                    "search": callable(getattr(instance, "searchContent", None))}
        _refresh_home(instance, metadata)
        _instances[key] = (instance, metadata, module.__name__)
        return _instances[key]
    except BaseException:
        sys.modules.pop(module.__name__, None)
        raise


def _refresh_home(instance, metadata):
    _current().pop('_scriptFailure', None)
    home = _object(_call(instance, 'homeContent', [True]))
    if not isinstance(home.get('class', []), list):
        raise ScriptFailure('脚本分类返回格式无效')
    metadata.update(categories=home.get('class', []), home=home,
                    _home_request=_current().get('network'))


def _empty_result_failure():
    network = _current().get('_network', {})
    if network.get('error'):
        raise ScriptFailure(network['error'])
    if network.get('status', 0) >= 400:
        raise ScriptFailure('站源返回 HTTP ' + str(network['status']))
    if _current().get('_apiFailure'):
        raise ScriptFailure(_current()['_apiFailure'])
    failure = _current().get('_scriptFailure')
    if failure:
        raise ScriptFailure('脚本返回空结果：' + failure['kind'] + '，脚本第 ' + str(failure['line']) + ' 行')


def _category_filters(metadata, category, selection):
    filters = {}
    definitions = metadata.get('home', {}).get('filters', {}).get(category, [])
    for option in definitions:
        if not isinstance(option, dict) or not option.get('key'):
            continue
        values = option.get('value') or []
        default = option.get('init')
        if default is None and values and isinstance(values[0], dict):
            default = values[0].get('v', '')
        if default is not None:
            filters[str(option['key'])] = str(default)
    filters.update(selection or {})
    return filters


def _drop(key):
    entry = _instances.pop(key, None)
    if entry:
        try:
            method = getattr(entry[0], "destroy", None)
            if callable(method):
                method()
        finally:
            sys.modules.pop(entry[2], None)


def _catalog_result(value, request, metadata):
    value = _object(value)
    rows = value.get('list', [])
    if not isinstance(rows, list):
        raise ScriptFailure('脚本目录未返回 list 数组')
    page = int(request['page'])
    try:
        actual = int(value.get('page') or page)
        pages = int(value.get('pagecount') or 0)
        total = int(value.get('total') or 0)
        limit = int(value.get('limit') or 0)
    except (ValueError, TypeError):
        actual, pages, total, limit = page, 0, 0, 0
    if actual < page:
        rows = value['list'] = []
    elif actual > page:
        raise ScriptFailure('脚本返回页码与请求不符')
    key = json.dumps([request.get('category', ''), request.get('query', ''),
                      request.get('filters') or {}], sort_keys=True)
    fingerprint = hashlib.sha256(json.dumps([str(row.get('vod_id', '')) for row in rows
                                            if isinstance(row, dict)], ensure_ascii=False).encode()).hexdigest()
    history = metadata.setdefault('_pagination', {})
    previous = history.get(key)
    repeated = page > 1 and previous and previous[0] < page and previous[1] == fingerprint
    if repeated:
        rows = value['list'] = []
    history[key] = (page, fingerprint)
    if len(history) > 64:
        history.pop(next(iter(history)))
    if not rows:
        _empty_result_failure()
        more = False
    elif 'hasMore' in value:
        more = value['hasMore'] is True
    elif pages > 0:
        more = page < pages
    elif total > 0 and limit > 0:
        more = page * limit < total
    else:
        more = True
    value.update(page=page, hasMore=more)
    return value


def _dispatch(request):
    import requests
    sys.stdout = DiscardOutput()
    sys.stderr = DiscardOutput()
    requests.sessions.Session.send = _send
    urllib.request.urlopen = _urllib_open
    http.client.HTTPConnection = BridgeHTTPConnection
    http.client.HTTPSConnection = BridgeHTTPSConnection
    threading.Thread.start = _start_thread
    tempfile.gettempdir = _temporary_directory
    _patch_crypto_frameworks()
    sys.dont_write_bytecode = True
    _context.request = request
    operation = request["operation"]
    if operation == "drop":
        _drop(request["instance"])
        return {}
    instance, metadata, _ = _load(request)
    if operation == 'inspect':
        return metadata
    _current().pop('_scriptFailure', None)
    if operation in ('categories', 'catalog') and not request.get('query'):
        if (request.get('force') or not metadata['categories']) and metadata.get('_home_request') != request.get('network'):
            _refresh_home(instance, metadata)
    if operation == 'categories':
        if not metadata['categories'] and not metadata['home'].get('list'):
            _empty_result_failure()
        return metadata
    if operation == "catalog":
        if request.get("query"):
            return _catalog_result(_call(instance, "searchContent", [request["query"], False, str(request["page"])]), request, metadata)
        category = request.get("category", "")
        if not category:
            categories = metadata["categories"]
            category = str(categories[0].get("type_id", "")) if categories else ""
        filters = _category_filters(metadata, category, request.get('filters'))
        value = _object(_call(instance, "categoryContent", [category, str(request["page"]), bool(filters), filters]))
        if not value.get('list') and not request.get('category') and request['page'] == 1:
            home = metadata['home']
            if home.get('list'):
                value = dict(home, pagecount=1)
            elif callable(getattr(instance, 'homeVideoContent', None)):
                fallback = _object(_call(instance, 'homeVideoContent', [False]))
                if fallback.get('list'):
                    value = dict(fallback, pagecount=1)
        return _catalog_result(value, request, metadata)
    if operation == "detail":
        value = _object(_call(instance, "detailContent", [[request["id"]]]))
        if not value.get('list'):
            _empty_result_failure()
        return value
    if operation == "play":
        value = _object(_call(instance, "playerContent", [request["flag"], request["id"], []]))
        if not value.get('url'):
            _empty_result_failure()
        return value
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
    request['deadline'] = deadline
    ticks = 0

    def trace(frame, event, arg):
        nonlocal ticks
        ticks += 1
        if event == 'exception' and frame.f_code.co_filename == 'imported_source.py':
            kind = arg[0]
            if kind not in (StopIteration, StopAsyncIteration, GeneratorExit):
                request['_scriptFailure'] = {'kind': kind.__name__, 'line': frame.f_lineno}
        if ticks % 1024 == 0:
            if time.time() > deadline or os.path.exists(request.get('cancelFile', '')):
                raise TimeoutError()
        return trace

    previous = sys.gettrace()
    try:
        sys.settrace(trace)
        with contextlib.redirect_stdout(DiscardOutput()), contextlib.redirect_stderr(DiscardOutput()):
            data = _dispatch(request)
        return json.dumps({"ok": True, "data": data, 'network': request.get('_network', {})}, ensure_ascii=False)
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
        return json.dumps({"ok": False, "error": message, 'network': request.get('_network', {})}, ensure_ascii=False)
    finally:
        sys.settrace(previous)
        _context.request = {}
