import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:yaml/yaml.dart';

/// One skill from the registry, fully fetched (front-matter parsed out).
class RegistrySkill {
  const RegistrySkill({
    required this.name,
    required this.description,
    required this.content,
  });

  final String name;
  final String description;

  /// Markdown body without the YAML front-matter.
  final String content;
}

/// One hit from the remote skills.sh search API (the same registry `npx
/// skills find` queries). [skillId] is the skill's front-matter name in
/// slug-safe form; [source] is the `owner/repo` it ships from.
class RegistrySkillHit {
  const RegistrySkillHit({
    required this.skillId,
    required this.name,
    required this.installs,
    required this.source,
  });

  final String skillId;
  final String name;
  final int installs;
  final String source;
}

class SkillRegistryException implements Exception {
  const SkillRegistryException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Client for Vercel's official skills registry (`vercel-labs/agent-skills`),
/// the same registry `npx skills` serves. The catalog is read through the
/// GitHub contents API and each skill's `SKILL.md` from
/// raw.githubusercontent.com, so no local CLI or npm download is needed.
class SkillRegistryClient {
  SkillRegistryClient({
    http.Client? httpClient,
    this.owner = 'vercel-labs',
    this.repository = 'agent-skills',
    this.branch = 'main',
    String? apiBaseUrl,
  }) : _http = httpClient ?? http.Client(),
       apiBaseUrl = apiBaseUrl ?? 'https://skills.sh';

  static const _registryRoot = 'skills';

  final http.Client _http;
  final String owner;
  final String repository;
  final String branch;
  final String apiBaseUrl;

  Uri _catalogUri() => Uri.parse(
    'https://api.github.com/repos/$owner/$repository/contents/$_registryRoot',
  );

  Uri _skillUri(String name) => Uri.parse(
    'https://raw.githubusercontent.com/$owner/$repository/$branch'
    '/$_registryRoot/$name/SKILL.md',
  );

  /// Lists the names of the skills in the registry, sorted alphabetically.
  /// Entries like `.zip` archives in the same directory are ignored.
  Future<List<String>> listSkills() async {
    final response = await _http.get(
      _catalogUri(),
      headers: const {'Accept': 'application/vnd.github+json'},
    );
    if (response.statusCode != 200) {
      throw SkillRegistryException(
        'Could not reach the skills registry (HTTP ${response.statusCode}).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const SkillRegistryException(
        'The skills registry returned an invalid catalog.',
      );
    }
    if (decoded is! List) {
      throw const SkillRegistryException(
        'The skills registry returned an invalid catalog.',
      );
    }
    final names = <String>[
      for (final entry in decoded)
        if (entry is Map<String, dynamic> &&
            entry['type'] == 'dir' &&
            entry['name'] is String)
          entry['name'] as String,
    ]..sort();
    return names;
  }

  /// Fetches and parses one skill's `SKILL.md`, extracting the YAML
  /// front-matter `description` and returning the markdown body as content.
  Future<RegistrySkill> fetchSkill(String name) async {
    final response = await _http.get(_skillUri(name));
    if (response.statusCode != 200) {
      throw SkillRegistryException(
        'Could not fetch skill "$name" (HTTP ${response.statusCode}).',
      );
    }
    return _parseSkill(name, response.body);
  }

  /// Searches the whole skills ecosystem through the skills.sh API, the same
  /// endpoint `npx skills find` uses. Results are sorted by install count.
  Future<List<RegistrySkillHit>> searchSkills(
    String query, {
    int limit = 10,
  }) async {
    final uri = Uri.parse(
      '$apiBaseUrl/api/search',
    ).replace(queryParameters: {'q': query, 'limit': '$limit'});
    final response = await _http.get(uri);
    if (response.statusCode != 200) {
      throw SkillRegistryException(
        'Skill search failed (HTTP ${response.statusCode}).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const SkillRegistryException('Skill search returned invalid data.');
    }
    if (decoded is! Map<String, dynamic> || decoded['skills'] is! List) {
      throw const SkillRegistryException('Skill search returned invalid data.');
    }
    final hits = <RegistrySkillHit>[
      for (final entry in decoded['skills'] as List)
        if (entry is Map<String, dynamic> &&
            entry['skillId'] is String &&
            entry['source'] is String)
          RegistrySkillHit(
            skillId: entry['skillId'] as String,
            name: entry['name'] as String? ?? entry['skillId'] as String,
            installs: entry['installs'] as int? ?? 0,
            source: entry['source'] as String,
          ),
    ]..sort((a, b) => b.installs.compareTo(a.installs));
    return hits;
  }

  /// Fetches a search hit's full `SKILL.md` through the skills.sh blob
  /// download API, the same fast path the CLI uses instead of cloning.
  Future<RegistrySkill> fetchSkillHit(RegistrySkillHit hit) async {
    final source = hit.source.split('/');
    if (source.length != 2 || source[0].isEmpty || source[1].isEmpty) {
      throw SkillRegistryException(
        'Skill "${hit.name}" has an invalid source "${hit.source}".',
      );
    }
    final uri = Uri.parse(
      '$apiBaseUrl/api/download/${source[0]}/${source[1]}/${hit.skillId}',
    );
    final response = await _http.get(uri);
    if (response.statusCode != 200) {
      throw SkillRegistryException(
        'Could not fetch skill "${hit.name}" (HTTP ${response.statusCode}).',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw SkillRegistryException('Could not fetch skill "${hit.name}".');
    }
    if (decoded is! Map<String, dynamic> || decoded['files'] is! List) {
      throw SkillRegistryException('Could not fetch skill "${hit.name}".');
    }
    String? markdown;
    for (final file in decoded['files'] as List) {
      if (file is! Map<String, dynamic>) continue;
      final path = file['path'];
      final contents = file['contents'];
      if (path is String &&
          path.toLowerCase().endsWith('skill.md') &&
          contents is String) {
        markdown = contents;
        break;
      }
    }
    if (markdown == null) {
      throw SkillRegistryException('Skill "${hit.name}" has no SKILL.md.');
    }
    return _parseSkill(hit.skillId, markdown);
  }

  static RegistrySkill _parseSkill(String name, String markdown) {
    var description = '';
    var body = markdown;
    if (markdown.startsWith('---')) {
      final end = markdown.indexOf('\n---', 3);
      if (end > 0) {
        final frontMatter = markdown.substring(3, end).trim();
        body = markdown.substring(end + 4).trim();
        try {
          final decoded = loadYaml(frontMatter);
          if (decoded is YamlMap) {
            final rawDescription = decoded['description'];
            if (rawDescription is String) description = rawDescription;
          }
        } catch (_) {
          // Malformed front-matter: keep the body as-is with no description.
          body = markdown;
        }
      }
    }
    return RegistrySkill(
      name: name,
      description: description,
      content: body.isEmpty ? markdown : body,
    );
  }
}
