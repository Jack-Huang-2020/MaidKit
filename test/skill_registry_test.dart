import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:maid_kit/agent/skill_registry.dart';

MockClient _mockClient(Map<String, http.Response Function()> routes) {
  return MockClient((request) async {
    final path = request.url.path;
    final handler = routes[path];
    if (handler == null) {
      return http.Response('Not found', 404);
    }
    return handler();
  });
}

void main() {
  group('SkillRegistryClient', () {
    test('listSkills returns only directory entries, sorted', () async {
      final client = SkillRegistryClient(
        httpClient: _mockClient({
          '/repos/vercel-labs/agent-skills/contents/skills': () =>
              http.Response(
                jsonEncode([
                  {'name': 'web-design-guidelines', 'type': 'dir'},
                  {'name': 'web-design-guidelines.zip', 'type': 'file'},
                  {'name': 'composition-patterns', 'type': 'dir'},
                ]),
                200,
                headers: {'content-type': 'application/json'},
              ),
        }),
      );
      final names = await client.listSkills();
      expect(names, ['composition-patterns', 'web-design-guidelines']);
    });

    test(
      'listSkills fails with a readable error on bad status or payload',
      () async {
        final missing = SkillRegistryClient(httpClient: _mockClient({}));
        await expectLater(
          missing.listSkills(),
          throwsA(isA<SkillRegistryException>()),
        );

        final broken = SkillRegistryClient(
          httpClient: _mockClient({
            '/repos/vercel-labs/agent-skills/contents/skills': () =>
                http.Response('{"unexpected": true}', 200),
          }),
        );
        await expectLater(
          broken.listSkills(),
          throwsA(isA<SkillRegistryException>()),
        );
      },
    );

    test('fetchSkill extracts the description and markdown body', () async {
      final client = SkillRegistryClient(
        httpClient: _mockClient({
          '/vercel-labs/agent-skills/main/skills/web/SKILL.md': () =>
              http.Response('''
---
name: web-design-guidelines
description: Review UI code for guidelines compliance.
metadata:
  author: vercel
---

# Web Interface Guidelines

Body content here.
''', 200),
        }),
      );
      final skill = await client.fetchSkill('web');
      expect(skill.name, 'web');
      expect(skill.description, 'Review UI code for guidelines compliance.');
      expect(skill.content, contains('# Web Interface Guidelines'));
      expect(skill.content, isNot(contains('description:')));
      expect(skill.content, endsWith('Body content here.'));
    });

    test(
      'fetchSkill falls back when front-matter is missing or malformed',
      () async {
        final plain = SkillRegistryClient(
          httpClient: _mockClient({
            '/vercel-labs/agent-skills/main/skills/plain/SKILL.md': () =>
                http.Response('# Plain\n\nNo front matter.', 200),
          }),
        );
        final skill = await plain.fetchSkill('plain');
        expect(skill.description, isEmpty);
        expect(skill.content, startsWith('# Plain'));

        final broken = SkillRegistryClient(
          httpClient: _mockClient({
            '/vercel-labs/agent-skills/main/skills/broken/SKILL.md': () =>
                http.Response('---\nname: [unclosed\n---\nBody.', 200),
          }),
        );
        final malformed = await broken.fetchSkill('broken');
        expect(malformed.description, isEmpty);
        expect(malformed.content, isNotEmpty);
      },
    );

    test('fetchSkill fails with a readable error on missing skill', () async {
      final client = SkillRegistryClient(httpClient: _mockClient({}));
      await expectLater(
        client.fetchSkill('nope'),
        throwsA(
          isA<SkillRegistryException>().having(
            (error) => error.message,
            'message',
            contains('nope'),
          ),
        ),
      );
    });

    test('searchSkills parses remote hits sorted by installs', () async {
      final client = SkillRegistryClient(
        httpClient: _mockClient({
          '/api/search': () => http.Response(
            jsonEncode({
              'query': 'react',
              'skills': [
                {
                  'skillId': 'small',
                  'name': 'small',
                  'installs': 5,
                  'source': 'a/b',
                },
                {
                  'skillId': 'big',
                  'name': 'big',
                  'installs': 604235,
                  'source': 'vercel-labs/agent-skills',
                },
              ],
            }),
            200,
          ),
        }),
      );
      final hits = await client.searchSkills('react');
      expect(hits, hasLength(2));
      expect(hits.first.skillId, 'big');
      expect(hits.first.installs, 604235);
      expect(hits.last.source, 'a/b');
    });

    test('searchSkills reports HTTP and payload failures', () async {
      final failing = SkillRegistryClient(httpClient: _mockClient({}));
      await expectLater(
        failing.searchSkills('x'),
        throwsA(isA<SkillRegistryException>()),
      );

      final broken = SkillRegistryClient(
        httpClient: _mockClient({
          '/api/search': () => http.Response('[]', 200),
        }),
      );
      await expectLater(
        broken.searchSkills('x'),
        throwsA(isA<SkillRegistryException>()),
      );
    });

    test('default construction (provider path) has a valid api base url', () {
      final client = SkillRegistryClient();
      expect(client.apiBaseUrl, 'https://skills.sh');
      expect(client.owner, 'vercel-labs');
    });

    test('fetchSkillHit downloads the SKILL.md from the blob API', () async {
      final client = SkillRegistryClient(
        httpClient: _mockClient({
          '/api/download/vercel-labs/agent-skills/vercel-react-best-practices':
              () => http.Response(
                jsonEncode({
                  'hash': 'abc',
                  'files': [
                    {'path': 'rules/extra.md', 'contents': '# Extra'},
                    {
                      'path': 'SKILL.md',
                      'contents':
                          '---\nname: vercel-react-best-practices\n'
                          'description: React performance guidelines.\n---\n'
                          '\n# React Best Practices\n\nBody.\n',
                    },
                  ],
                }),
                200,
              ),
        }),
      );
      final skill = await client.fetchSkillHit(
        const RegistrySkillHit(
          skillId: 'vercel-react-best-practices',
          name: 'vercel-react-best-practices',
          installs: 1,
          source: 'vercel-labs/agent-skills',
        ),
      );
      expect(skill.name, 'vercel-react-best-practices');
      expect(skill.description, 'React performance guidelines.');
      expect(skill.content, contains('# React Best Practices'));
      expect(skill.content, isNot(contains('# Extra')));
    });

    test(
      'fetchSkillHit rejects invalid sources and missing SKILL.md',
      () async {
        final badSource = SkillRegistryClient(httpClient: _mockClient({}));
        await expectLater(
          badSource.fetchSkillHit(
            const RegistrySkillHit(
              skillId: 'x',
              name: 'x',
              installs: 0,
              source: 'not-a-source',
            ),
          ),
          throwsA(isA<SkillRegistryException>()),
        );

        final noSkillMd = SkillRegistryClient(
          httpClient: _mockClient({
            '/api/download/a/b/x': () => http.Response(
              jsonEncode({
                'files': [
                  {'path': 'README.md', 'contents': 'no skill here'},
                ],
              }),
              200,
            ),
          }),
        );
        await expectLater(
          noSkillMd.fetchSkillHit(
            const RegistrySkillHit(
              skillId: 'x',
              name: 'x',
              installs: 0,
              source: 'a/b',
            ),
          ),
          throwsA(
            isA<SkillRegistryException>().having(
              (error) => error.message,
              'message',
              contains('SKILL.md'),
            ),
          ),
        );
      },
    );
  });
}
