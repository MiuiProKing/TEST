import unittest,sys,json,tempfile,sqlite3,copy,os,ast,threading,types
from datetime import datetime,timezone
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'onewin-clock-ios/OneWinClock'))
import source_manager as sm

class SourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get('KIBORG_CACHE_FILE')
        os.environ['KIBORG_CACHE_FILE'] = str(Path(self.temp.name)/'cache.json')
    def tearDown(self):
        self.temp.cleanup()
        if self.previous is None:os.environ.pop('KIBORG_CACHE_FILE',None)
        else:os.environ['KIBORG_CACHE_FILE']=self.previous
    def manager(self, transport, clock=lambda:1000000):
        return sm.SourceManager(copy.deepcopy(sm.CONFIG),transport,clock)
    def test_exact_one_and_finite(self):
        self.assertEqual(sm.normalize_round({'id':'a','coefficient':1})['coefficient'],1)
        for value in ('nan','inf',-1,0,True):
            self.assertIsNone(sm.normalize_round({'id':'b','coefficient':value}))
    def test_unique_id_required(self):
        self.assertIsNone(sm.normalize_round({'coefficient':2.3}))
        self.assertNotEqual(sm.normalize_round({'id':'a','coefficient':2.3})['id'],sm.normalize_round({'id':'b','coefficient':2.3})['id'])
    def test_fractional_ms_and_future(self):
        r=sm.normalize_round({'id':123,'finalValues':[1,9.8],'timestamp':'2026-10-03T10:00:00.123Z'},now=1)
        self.assertTrue(r['estimated']);self.assertEqual(r['coefficient'],9.8)
        r=sm.normalize_round({'id':'x','coefficient':1,'timestamp':1000000123},now=2000000000)
        self.assertFalse(r['estimated']);self.assertIsNotNone(r['timestamp'])
    def test_fallback_and_scoped_session(self):
        calls=[]
        def tx(url,headers,timeout):
            calls.append((url,headers))
            if 'xrniw' in url:raise TimeoutError('secret must not leak')
            return {'history':[{'id':'a','coefficient':3}]}
        m=self.manager(tx);self.assertEqual(m.fetch()[0]['coefficient'],3)
        self.assertEqual(m.active,'reserve');self.assertNotIn('session-id',calls[1][1])
        self.assertNotIn('secret',json.dumps({k:v for k,v in m.health['main'].items() if k!='ids'}))
    def test_offline_cache_recover_primary(self):
        online=[True];clock=[1000000]
        def tx(*args):
            if not online[0]:raise ConnectionError()
            return [{'id':'a','coefficient':1}]
        m=self.manager(tx,lambda:clock[0]);m.fetch();online[0]=False;m.fetch()
        self.assertTrue(m.cached);self.assertEqual(m.active,'local')
        online[0]=True;clock[0]+=31;m.fetch();self.assertFalse(m.cached);self.assertEqual(m.active,'main')
    def test_backoff_avoids_busy_loop(self):
        calls=[]
        def tx(*args):calls.append(1);raise TimeoutError()
        m=self.manager(tx)
        for _ in range(3):
            with self.assertRaises(ConnectionError):m.fetch()
        self.assertEqual(len(calls),2)
        self.assertEqual(m.health['legacy']['status'],'AUTH_REQUIRED')
    def test_pagination_and_dedup_complete_batch(self):
        calls=[]
        def tx(url,headers,timeout):
            calls.append(url)
            if 'offset=0' in url:return {'history':[{'id':'a','coefficient':4}],'hasMore':True,'nextOffset':1000}
            return {'data':{'history':[{'id':'a','coefficient':4},{'id':'b','coefficient':4}]},'hasMore':False}
        m=self.manager(tx);self.assertEqual([r['id'] for r in m.fetch(limit=1)],['a','b']);self.assertEqual(len(calls),2)
        m.fetch();self.assertEqual(len(calls),3) # fast head only, no second full scan
    def test_stale_is_not_online(self):
        clock=[1000000]
        def tx(*args):return [{'id':'a','coefficient':2}]
        m=self.manager(tx,lambda:clock[0]);m.fetch();clock[0]+=130;m.fetch()
        self.assertEqual(m.active,'reserve');self.assertEqual(m.health['main']['status'],'SLOW')
    def test_selection_persists(self):
        with tempfile.TemporaryDirectory() as d:
            old=os.environ.get('KIBORG_SOURCE_STATE')
            os.environ['KIBORG_SOURCE_STATE']=str(Path(d)/'state.json')
            try:
                m=self.manager(lambda *a:[{'id':'a','coefficient':2}]);m.select('reserve')
                n=self.manager(lambda *a:[{'id':'a','coefficient':2}]);self.assertEqual(n.selection,'reserve');n.fetch();self.assertEqual(n.active,'reserve')
            finally:
                if old is None:os.environ.pop('KIBORG_SOURCE_STATE',None)
                else:os.environ['KIBORG_SOURCE_STATE']=old
    def test_cache_survives_restart(self):
        m=self.manager(lambda *a:[{'id':'cached','coefficient':8}]);m.fetch()
        def fail(*args):raise TimeoutError()
        n=self.manager(fail);self.assertEqual(n.fetch()[0]['id'],'cached');self.assertTrue(n.cached)
    def test_sqlite_migration_keeps_legacy_and_no_duplicates(self):
        for schema in ["round_id TEXT PRIMARY KEY,coefficient REAL,ts TEXT", "id TEXT PRIMARY KEY,coef REAL,api_time TEXT,received_at TEXT"]:
            db=sqlite3.connect(':memory:');db.execute(f'CREATE TABLE rounds({schema})')
            if schema.startswith('round_id'):
                db.execute("INSERT INTO rounds VALUES('old',1,'2026-01-01')")
            else:db.execute("INSERT INTO rounds VALUES('old',1,NULL,'2026-01-01')")
            sm.migrate_rounds(db);sm.migrate_rounds(db)
            self.assertEqual(db.execute('SELECT count(*) FROM rounds').fetchone()[0],1)
            self.assertEqual(db.execute('SELECT source FROM rounds').fetchone()[0],'legacy')
            self.assertTrue({'source','created_at','estimated'} <= {r[1] for r in db.execute('PRAGMA table_info(rounds)')})
            db.close()
    def test_actual_python_store_adapters(self):
        # Compile only storage functions: importing the full bot would instantiate Telegram or start global DBs.
        root=Path(sm.__file__).parent
        for filename,names in [('KIBORG_V2.py',('db_connect','init_db','save_round')),('V0xFF3(1).py',('init_db','save_round'))]:
            with tempfile.TemporaryDirectory() as d:
                file=str(Path(d)/'history.sqlite3')
                scope={'sqlite3':sqlite3,'DB_PATH':file,'DB_FILE':file,'db_lock':threading.RLock(),'migrate_rounds':sm.migrate_rounds,'now_kyiv':lambda:datetime.now(timezone.utc),'now':lambda:datetime.now(timezone.utc),'Round':types.SimpleNamespace}
                tree=ast.parse((root/filename).read_text(encoding='utf-8'))
                selected=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in names]
                exec(compile(ast.Module(body=selected,type_ignores=[]),filename,'exec'),scope)
                result=scope['init_db']()
                if filename=='KIBORG_V2.py':
                    row={'id':'a','coef':1,'api_time':None,'source':'main','estimated':True}
                else:
                    scope['DB']=result
                    row=types.SimpleNamespace(round_id='a',coefficient=1,ts=datetime.now(timezone.utc),source='main',estimated=True)
                scope['save_round'](row);scope['save_round'](row)
                if result:result.close()
                with sqlite3.connect(file) as db:
                    self.assertEqual(db.execute('SELECT count(*) FROM rounds').fetchone()[0],1)
                    self.assertEqual(db.execute('SELECT id,round_id,coefficient,source,estimated FROM rounds').fetchone(),('a','a',1,'main',1))
    def test_html_is_not_a_coefficient_api(self):
        def tx(url,*a):
            if 'xrniw' in url:raise ValueError('HTML instead of JSON')
            return [{'id':'reserve','coefficient':2}]
        m=self.manager(tx);m.fetch();self.assertEqual(m.health['main']['status'],'ERROR');self.assertEqual(m.active,'reserve')

if __name__=='__main__':unittest.main()
