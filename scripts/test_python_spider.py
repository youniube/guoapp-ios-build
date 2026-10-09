import importlib.util
import json
import base64
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch


class PythonSpiderProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).resolve().parents[1] / 'assets/python_sources/guo_spider.py'
        spec = importlib.util.spec_from_file_location('guo_spider_protocol_test', path)
        cls.runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.runner)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.counter = 0
        self.instance = self.root.name
        session = type('Session', (), {'close': lambda self: None})
        requests = types.ModuleType('requests')
        requests.Session = session
        requests.sessions = types.SimpleNamespace(Session=session)
        self.modules = patch.dict(sys.modules, {'requests': requests, 'urllib3': types.ModuleType('urllib3')})
        self.modules.start()
        self.addCleanup(self.modules.stop)
        for owner, name in [(self.runner.urllib.request, 'urlopen'),
                            (self.runner.http.client, 'HTTPConnection'),
                            (self.runner.http.client, 'HTTPSConnection'),
                            (self.runner.threading.Thread, 'start'),
                            (self.runner.tempfile, 'gettempdir')]:
            value = getattr(owner, name)
            self.addCleanup(setattr, owner, name, value)
        self.addCleanup(self.runner._drop, self.instance)

    def source(self, methods):
        body = '''from base.spider import Spider as Base
class Spider(Base):
    def init(self, extend=''): self.calls = 0
    def homeContent(self, filter): return {'class':[{'type_id':'demo','type_name':'Synthetic'}]}
    def categoryContent(self, tid, pg, filter, extend): return {'list':[]}
    def detailContent(self, ids): return {'list':[]}
    def playerContent(self, flag, id, vipFlags): return {'url':''}
''' + methods
        (self.root / 'source.py').write_text(body, encoding='utf-8')

    def call(self, operation, **options):
        self.counter += 1
        request = {'instance': self.instance, 'operation': operation,
                   'file': str(self.root / 'source.py'), 'storage': str(self.root),
                   'network': 'http://127.0.0.1:9/net/' + str(self.counter),
                   'proxy': 'http://127.0.0.1:9/proxy/synthetic',
                   'page': 1, 'category': '', 'filters': {}, 'deadline': time.time() + 5}
        request.update(options)
        encoded = base64.b64encode(json.dumps(request).encode()).decode()
        return json.loads(self.runner.dispatch_base64(encoded))

    def test_category_pagination_precedes_home_recommendations_and_applies_defaults(self):
        self.source('''
    def homeContent(self, filter):
        return {'class':[{'type_id':'demo','type_name':'Synthetic'}],
                'list':[{'vod_id':'recommendation','vod_name':'Synthetic'}],
                'filters':{'demo':[{'key':'sort','init':'updated','value':[{'v':'popular'}]},
                                   {'key':'cat','value':[{'v':'all'}]}]}}
    def homeVideoContent(self): raise AssertionError('rank should not truncate the category')
    def categoryContent(self, tid, pg, filter, extend):
        assert tid == 'demo' and filter and extend['cat'] == 'all'
        return {'list':[{'vod_id':pg, 'vod_name':extend['sort']}], 'page':int(pg), 'pagecount':3}
''')
        first = self.call('catalog')
        self.assertTrue(first['ok'], first)
        self.assertEqual(first['data']['list'][0]['vod_id'], '1')
        self.assertEqual(first['data']['list'][0]['vod_name'], 'updated')
        self.assertTrue(first['data']['hasMore'])
        second = self.call('catalog', page=2, filters={'sort':'selected'})
        self.assertEqual(second['data']['list'][0]['vod_name'], 'selected')
        self.assertTrue(second['data']['hasMore'])

    def test_home_content_rows_survive_empty_category_and_rank(self):
        self.source('''
    def homeContent(self, filter):
        return {'class':[{'type_id':'demo','type_name':'Synthetic'}],
                'list':[{'vod_id':'home','vod_name':'Synthetic'}]}
    def homeVideoContent(self): return {'list':[]}
''')
        result = self.call('catalog')
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['data']['list'][0]['vod_id'], 'home')
        self.assertFalse(result['data']['hasMore'])

    def test_failed_home_metadata_reloads_and_force_refreshes(self):
        self.source('''
    def homeContent(self, filter):
        self.calls += 1
        return {'class':[] if self.calls == 1 else [{'type_id':str(self.calls),'type_name':'Synthetic'}]}
''')
        self.assertEqual(self.call('inspect')['data']['categories'], [])
        self.assertEqual(self.call('categories')['data']['categories'][0]['type_id'], '2')
        self.assertEqual(self.call('categories')['data']['categories'][0]['type_id'], '2')
        self.assertEqual(self.call('categories', force=True)['data']['categories'][0]['type_id'], '3')

    def test_swallowed_urllib_failure_is_reported_with_host(self):
        self.source('''
    def categoryContent(self, tid, pg, filter, extend):
        import urllib.request
        try: urllib.request.urlopen('https://fixture.invalid/api?token=private')
        except Exception: pass
        return {'list':[]}
''')
        with patch.object(self.runner, '_urlopen', side_effect=ConnectionRefusedError('private')):
            result = self.call('catalog')
        self.assertFalse(result['ok'])
        self.assertIn('ConnectionRefusedError', result['error'])
        self.assertEqual(result['network']['host'], 'fixture.invalid')
        self.assertEqual(result['network']['status'], 0)
        self.assertNotIn('private', json.dumps(result))

    def test_swallowed_script_exception_reports_type_and_line_without_values(self):
        self.source('''
    def categoryContent(self, tid, pg, filter, extend):
        try: raise KeyError('private-signing-value')
        except Exception: return {'list':[]}
''')
        result = self.call('catalog')
        self.assertFalse(result['ok'])
        self.assertIn('KeyError', result['error'])
        self.assertIn('行', result['error'])
        self.assertNotIn('private-signing-value', json.dumps(result))

    def test_script_signature_session_does_not_break_base_cleanup(self):
        self.source('''
    def init(self, extend=''): self.session = 'synthetic-signing-value'
''')
        self.assertTrue(self.call('inspect')['ok'])
        self.assertTrue(self.call('drop')['ok'])

    def test_script_temporary_session_stays_in_private_source_storage(self):
        self.source('''
    def init(self, extend=''):
        import tempfile, os
        with open(os.path.join(tempfile.gettempdir(), 'synthetic-session.json'), 'w') as destination:
            destination.write('synthetic-private-session')
''')
        self.assertTrue(self.call('inspect')['ok'])
        self.assertEqual((self.root / 'synthetic-session.json').read_text(), 'synthetic-private-session')

    def test_watchdog_still_stops_python_loop(self):
        self.source('''
    def categoryContent(self, tid, pg, filter, extend):
        while True:
            self.calls += 1
''')
        started = time.monotonic()
        result = self.call('catalog', deadline=time.time() + .04)
        self.assertFalse(result['ok'])
        self.assertIn('超时', result['error'])
        self.assertLess(time.monotonic() - started, 2)


if __name__ == '__main__':
    unittest.main()
