from base.spider import Spider as BaseSpider


class Spider(BaseSpider):
    def init(self, extend=''):
        self.token = 'synthetic-fixture-token'
        self.cookie = 'fixture=synthetic'

    def getName(self):
        return 'Python 合成站源'

    def homeContent(self, filter):
        return {'class': [{'type_id': 'demo', 'type_name': '合成分类'}]}

    def categoryContent(self, tid, pg, filter, extend):
        return {'page': int(pg), 'pagecount': 2, 'list': [
            {'vod_id': '7', 'vod_name': '合成剧集', 'vod_pic': '', 'vod_content': '仅用于验证'}]}

    def searchContent(self, key, quick, pg='1'):
        return self.categoryContent('demo', pg, False, {})

    def detailContent(self, ids):
        return {'list': [{'vod_id': ids[0], 'vod_name': '合成剧集',
                          'vod_play_from': 'A$$$B',
                          'vod_play_url': '第1集$one#第2集$two$$$第2集$two-b#第1集$one-b'}]}

    def playerContent(self, flag, id, vipFlags):
        return {'parse': 0, 'url': 'https://fixture.invalid/' + id + '.mp4',
                'header': {'Authorization': 'Bearer ' + self.token, 'Cookie': self.cookie}}
