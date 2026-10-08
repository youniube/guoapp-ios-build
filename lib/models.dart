import 'dart:convert';

import 'app_build.dart';
import 'python_sources.dart';

class SourceSite {
  const SourceSite(this.id, this.name, this.description);
  final String id;
  final String name;
  final String description;
  bool get onlineSearch => id == 'hongguo' || pagedSearch;
  bool get python => id.startsWith('py:');
  String get revision =>
      pythonSources.where((source) => source.id == id).firstOrNull?.revision ??
      '';
  String get identity => '$id:$name:$revision';
  bool get pagedSearch =>
      python &&
          pythonSources.any((source) => source.id == id && source.search) ||
      id == 'huangju' ||
      id == 'yeguo' ||
      id == 'dsd' ||
      id == 'sorani' ||
      id == 'guipian' ||
      id == 'hanxiaoquan' ||
      collectorValues.any((site) => site.id == id) ||
      catpawValues.any((site) => site.id == id) ||
      const {
        "batvideo",
        "honeypeach",
        "weiguan",
        "hema",
        "shanhai",
        "xingya",
        "qimao",
        "xifan",
        "qixing",
        "niuniudj",
        "xiaopingguo",
        "luoxue",
        "jumi",
        "nnvideo",
        "dj91",
        "yizk",
      }.contains(id);
  bool get searchSuggestions => id == 'hongguo';
  String get groupId => switch (id) {
    'huangguo-video' || 'huangguoai' || 'cloudfront' => 'huangguo',
    _ => id,
  };
  String get groupName => groupId == 'huangguo' ? '黄果' : name;
  String get entryName => switch (id) {
    'huangguo-video' => '视频',
    'huangguoai' => 'AI',
    'cloudfront' => '旧版',
    _ => name,
  };

  static const hongguo = SourceSite('hongguo', '红果', '短剧 · 漫剧 · AI 剧');
  static const dsd = SourceSite('dsd', '帝果', '分类视频 · 在线搜索');
  static const sorani = SourceSite('sorani', '青空', '番剧 · 剧场动画 · 特摄');
  static const guipian = SourceSite('guipian', '鬼片', '鬼片 · 电视剧 · 动漫');
  static const hanxiaoquan = SourceSite(
    'hanxiaoquan',
    '韩小圈',
    '韩剧 · 韩国电影 · 综艺动漫',
  );

  static const collectorValues = [
    SourceSite('zy155', '155资源', '影视 · 分类 · 在线搜索'),
    SourceSite('ikun', 'ikun', '电影 · 剧集 · 综艺 · 动漫'),
    SourceSite('guangsu', '光速', '电影 · 剧集 · 在线搜索'),
    SourceSite('dazhong', '大众资源', '影视 · 分类 · 在线搜索'),
    SourceSite('tianya', '天涯', '影视 · 分类 · 在线搜索'),
    SourceSite('wushuiyin', '无水印', '影视 · 分类 · 在线搜索'),
    SourceSite('baofeng', '暴风', '电影 · 剧集 · 综艺 · 动漫'),
    SourceSite('zuida', '最大', '电影 · 剧集 · 综艺 · 动漫'),
    SourceSite('maotai', '茅台', '电影 · 剧集 · 在线搜索'),
    SourceSite('xigua', '西瓜资源', '影视 · 分类 · 在线搜索'),
    SourceSite('douban2', '豆瓣2', '影视 · 分类 · 在线搜索'),
  ];

  static const attachedValues = [
    SourceSite('xiaopingguo', '小苹果', '电影 · 剧集 · 4K专区'),
    SourceSite('luoxue', '洛雪TV', '电影 · 剧集 · 动漫 · 综艺'),
    SourceSite('jumi', '剧迷', '影视 · 分类 · 在线搜索'),
    SourceSite('nnvideo', '牛牛视频', '影视 · 多线路 · 在线搜索'),
    SourceSite("batvideo", "蝙蝠视频", "分类视频 · 在线搜索"),
    SourceSite("honeypeach", "暗黑蜜桃", "分类视频 · 在线搜索"),
    SourceSite("weiguan", "围观", "分类视频 · 在线搜索"),
    SourceSite("hema", "河马", "分类视频 · 在线搜索"),
    SourceSite("shanhai", "山海", "分类视频 · 在线搜索"),
    SourceSite("haokan", "好看", "分类视频 · 本地搜索"),
    SourceSite("xingya", "星芽", "分类视频 · 在线搜索"),
    SourceSite("qimao", "七猫", "分类视频 · 在线搜索"),
    SourceSite("xifan", "西饭", "分类视频 · 在线搜索"),
    SourceSite("yimi", "薏米", "分类视频 · 本地搜索"),
    SourceSite("qixing", "七星", "分类视频 · 在线搜索"),
    SourceSite("niuniudj", "牛牛短剧", "分类视频 · 在线搜索"),
    SourceSite("kuangbiao", "狂飙", "分类视频 · 本地搜索"),
    SourceSite("dj91", "91", "分类视频 · 在线搜索"),
    SourceSite("yizk", "一直看", "分类视频 · 在线搜索"),
  ];

  static const catpawValues = [
    SourceSite('catpaw_bajie', '八戒影视', '电影 · 剧集 · 多线路'),
    SourceSite('catpaw_duboku', '独播库', '电影 · 剧集 · 动漫 · 综艺'),
    SourceSite('catpaw_yiys', '壹影视', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_xifandongman', '稀饭动漫', '动漫 · 分类 · 在线搜索'),
    SourceSite('catpaw_meijuxia', '美剧侠', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_rebo', '热播影视大全', '影视 · 分类 · 在线搜索'),
    SourceSite('catpaw_xinxin', '欣欣影视', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_quanyingshi', '全影视PRO', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_bidi', '哔嘀影视', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_bilfun', 'BILFUN影视大全', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_kankelm', '看客联盟', '影视 · 分类 · 在线搜索'),
    SourceSite('catpaw_2kdm', '2k动漫', '动漫 · 分类 · 在线搜索'),
    SourceSite('catpaw_maitian', '麦田影院', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_xingma', '星马视', '影视 · 多线路 · 在线搜索'),
    SourceSite('catpaw_gotto', 'gotto', '影视 · 分类 · 在线搜索'),
    SourceSite('catpaw_kaiduan', '开端', '电影 · 剧集 · 动漫 · 短剧'),
    SourceSite('catpaw_247', '247看', '电影 · 剧集 · 动漫 · 短剧'),
  ];

  static const allValues = [
    hongguo,
    hanxiaoquan,
    guipian,
    sorani,
    SourceSite('huangdou', '黄豆', '精选短剧'),
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧'),
    SourceSite('yeguo', '野果', '分类短剧 · 在线搜索'),
    dsd,
    SourceSite('huangguo-video', '黄果视频', '视频剧集'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    ...collectorValues,
    SourceSite('xifu', '喜福', '分类短剧'),
    ...attachedValues,
    ...catpawValues,
  ];
  static List<PythonSourceInfo> pythonSources = [];
  static List<SourceSite> get values => [
    ...(allSourcesEnabled ? allValues : [hongguo]),
    for (final source in pythonSources)
      if (source.enabled) SourceSite(source.id, source.name, 'Python 导入站源'),
  ];
  static bool isAvailable(String id) => values.any((site) => site.id == id);
  static bool isKnown(String id) =>
      allValues.any((site) => site.id == id) ||
      RegExp(r'^py:[a-f0-9]{32}$').hasMatch(id);
  static bool isRetired(String id) => const {
    'wuwu',
    'yingtan',
    'qiwei',
    'uku',
    'zy1080',
    'hongdou',
    'baidu',
    'chengguo',
    'damang',
    'dj51',
    'duanjuone',
    'huangdou2',
    'huanggua',
    'kuwo',
    'md2048',
    'souju',
    'wusheng',
    'xiangjiao',
    'xingxing',
    'yeguo-worker',
    'liangzi',
    'jciyuan',
    'ruyi',
    'jiuyao',
    'xinlang',
    'wujin',
    'jisu',
    'yinghua',
    'niuniu',
    'dytt',
    'baiduyun',
    'suoni',
    'hongniu',
    'huya',
    'haohua',
    'jinying',
    'shandian',
    'feifan',
    'modu',
    'xiaobao',
    'catpaw_xinlang',
    'catpaw_ciyuancheng',
    'catpaw_gulu',
    'catpaw_zhuifan',
    'catpaw_fanxi',
    'catpaw_silisili',
    'catpaw_jikan',
    'catpaw_gugu',
    'catpaw_jiuxiao',
    'catpaw_yiyi',
    'catpaw_luogongge',
  }.contains(id);
  static SourceSite byId(String id) {
    for (final source in pythonSources) {
      if (source.id == id) return SourceSite(id, source.name, 'Python 导入站源');
    }
    return allValues.firstWhere(
      (site) => site.id == id,
      orElse: () => id.startsWith('py:')
          ? SourceSite(id, '已移除的 Python 站源', '来源不可用')
          : hongguo,
    );
  }
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(
    this.id,
    this.name, {
    this.local = false,
    this.filters = const [],
  });
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  final List<PythonCatalogFilter> filters;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
        filters: [
          for (final row in json['filters'] as List? ?? const [])
            if (row is Map)
              PythonCatalogFilter.fromJson(Map<String, dynamic>.from(row)),
        ],
      );
}

class PythonCatalogFilter {
  PythonCatalogFilter.fromJson(Map<String, dynamic> json)
    : key = '${json['key'] ?? ''}',
      name = '${json['name'] ?? ''}',
      initial = '${json['init'] ?? ''}',
      values = {
        for (final value in json['value'] as List? ?? const [])
          if (value is Map && value['v'] != null)
            '${value['v']}': '${value['n'] ?? value['v']}',
      };
  final String key, name, initial;
  final Map<String, String> values;
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
  String get lineId => raw['lineId'] as String? ?? '';
  String get lineName => raw['lineName'] as String? ?? '';
  String get browserKey => lineId.isEmpty ? '$number' : '$lineId:$id';
}

class EpisodeLine {
  const EpisodeLine(this.id, this.name, this.episodes);
  final String id;
  final String name;
  final List<Episode> episodes;

  static List<EpisodeLine> group(List<Episode> episodes) {
    final groups = <String, List<Episode>>{};
    for (final episode in episodes) {
      (groups[episode.lineId] ??= []).add(episode);
    }
    return [
      for (final entry in groups.entries)
        EpisodeLine(
          entry.key,
          entry.value.first.lineName.isEmpty
              ? '默认线路'
              : entry.value.first.lineName,
          entry.value,
        ),
    ];
  }
}

int episodeNeighborIndex(List<Episode> episodes, int index, int direction) {
  if (index < 0 || index >= episodes.length || direction == 0) return -1;
  final lineId = episodes[index].lineId;
  final step = direction > 0 ? 1 : -1;
  for (
    var next = index + step;
    next >= 0 && next < episodes.length;
    next += step
  ) {
    if (episodes[next].lineId == lineId) return next;
  }
  return -1;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, {this.warning = ''});
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  late final List<EpisodeLine> lines = EpisodeLine.group(episodes);
  List<Episode> episodesForLine(String? id) => lines.isEmpty
      ? const []
      : lines
            .firstWhere((line) => line.id == id, orElse: () => lines.first)
            .episodes;
  List<Episode> get defaultEpisodes => episodesForLine(null);
  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
  });
  final String url;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.episodeId = '',
    this.lineId = '',
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  final String episodeId;
  final String lineId;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
    if (episodeId.isNotEmpty) 'episodeId': episodeId,
    if (lineId.isNotEmpty) 'lineId': lineId,
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
    episodeId: json['episodeId'] as String? ?? '',
    lineId: json['lineId'] as String? ?? '',
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
