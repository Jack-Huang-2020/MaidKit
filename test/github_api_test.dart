import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/github/github_api.dart';
import 'package:maid_kit/github/github_device_auth.dart';
import 'package:maid_kit/github/github_models.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => handler(options);

  @override
  void close({bool force = false}) {}
}

Dio _dio(
  Future<ResponseBody> Function(RequestOptions options) handler, {
  String baseUrl = 'https://api.github.com',
  Map<String, dynamic> headers = const {},
}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 5),
      headers: headers,
    ),
  );
  dio.httpClientAdapter = _FakeAdapter(handler);
  return dio;
}

ResponseBody _json(
  Object data, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    status,
    headers: {
      'content-type': ['application/json'],
      ...headers.map((key, value) => MapEntry(key, [value])),
    },
  );
}

ResponseBody _error(int status, {Map<String, String> headers = const {}}) {
  return ResponseBody.fromString(
    '{"message": "error"}',
    status,
    headers: {
      'content-type': ['application/json'],
      ...headers.map((key, value) => MapEntry(key, [value])),
    },
  );
}

void main() {
  group('GithubApi', () {
    test('currentUser parses the account profile', () async {
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async {
          expect(options.path, '/user');
          expect(options.headers['Authorization'], 'Bearer t');
          return _json({
            'login': 'octocat',
            'name': 'Octo Cat',
            'avatar_url': 'https://example.com/avatar.png',
          });
        }, headers: const {'Authorization': 'Bearer t'}),
      );
      final account = await api.currentUser();
      expect(account.login, 'octocat');
      expect(account.name, 'Octo Cat');
      expect(account.avatarUrl, 'https://example.com/avatar.png');
    });

    test('listRepos requests org member repos and paginates', () async {
      final pages = <int>[];
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async {
          expect(options.path, '/user/repos');
          expect(options.queryParameters['per_page'], 100);
          expect(
            options.queryParameters['affiliation'],
            'owner,collaborator,organization_member',
          );
          pages.add((options.queryParameters['page'] as num).toInt());
          if (pages.length == 1) {
            // A full page of 100 forces a second page fetch.
            return _json([
              for (var i = 0; i < 100; i++)
                {
                  'full_name': 'octocat/repo$i',
                  'name': 'repo$i',
                  'private': false,
                },
            ]);
          }
          return _json([
            {'full_name': 'my-org/project', 'name': 'project', 'private': true},
          ]);
        }),
      );
      final repos = await api.listRepos();
      expect(repos, hasLength(101));
      expect(pages, [1, 2]);
      expect(repos.last.slug, 'my-org/project');
      expect(repos.last.private, isTrue);
    });

    test('listRuns maps statuses and conclusions', () async {
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async {
          expect(options.path, '/repos/o/r/actions/runs');
          expect(options.queryParameters['per_page'], 20);
          return _json({
            'workflow_runs': [
              {
                'id': 1,
                'name': 'CI',
                'display_title': 'Build',
                'head_branch': 'main',
                'head_sha': 'abc123',
                'status': 'queued',
                'run_number': 5,
                'actor': {'login': 'octocat'},
              },
              {
                'id': 2,
                'name': 'CI',
                'display_title': 'Build',
                'head_branch': 'main',
                'head_sha': 'abc123',
                'status': 'in_progress',
                'run_number': 6,
                'actor': {'login': 'octocat'},
              },
              {
                'id': 3,
                'name': 'CI',
                'display_title': 'Build',
                'head_branch': 'main',
                'head_sha': 'abc123',
                'status': 'completed',
                'conclusion': 'failure',
                'run_number': 7,
                'actor': {'login': 'octocat'},
              },
              {
                'id': 4,
                'name': 'CI',
                'display_title': 'Build',
                'head_branch': 'main',
                'head_sha': 'abc123',
                'status': 'completed',
                'conclusion': 'success',
                'run_number': 8,
                'actor': {'login': 'octocat'},
              },
            ],
          });
        }),
      );
      final runs = await api.listRuns('o', 'r');
      expect(runs, hasLength(4));
      expect(runs[0].status, WorkflowRunStatus.queued);
      expect(runs[0].isLive, isTrue);
      expect(runs[1].status, WorkflowRunStatus.inProgress);
      expect(runs[1].isLive, isTrue);
      expect(runs[2].status, WorkflowRunStatus.completed);
      expect(runs[2].conclusion, WorkflowRunConclusion.failure);
      expect(runs[2].failed, isTrue);
      expect(runs[3].conclusion, WorkflowRunConclusion.success);
      expect(runs[3].failed, isFalse);
      expect(runs[0].actorLogin, 'octocat');
    });

    test('listRuns filters by workflow name', () async {
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async {
          expect(options.queryParameters['workflow_id'], 'Deploy');
          return _json({'workflow_runs': <Object>[]});
        }),
      );
      await api.listRuns('o', 'r', workflowName: 'Deploy');
    });

    test('latestRunForWorkflow returns the newest run or null', () async {
      var call = 0;
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async {
          call++;
          return _json({
            'workflow_runs': [
              {
                'id': 1,
                'name': 'CI',
                'display_title': 'A',
                'head_branch': 'main',
                'head_sha': 'x',
                'status': 'completed',
                'conclusion': 'success',
                'run_number': 1,
              },
            ],
          });
        }),
      );
      final run = await api.latestRunForWorkflow('o', 'r', 'CI');
      expect(run?.id, 1);
      expect(call, 1);
      expect(await api.latestRunForWorkflow('o', 'r', 'CI'), isNotNull);
    });

    test('401 maps to the auth error kind', () async {
      final api = GithubApi(
        token: 't',
        dio: _dio((options) async => _error(401)),
      );
      await expectLater(
        api.currentUser(),
        throwsA(
          isA<GitHubApiException>().having(
            (error) => error.kind,
            'kind',
            GitHubApiErrorKind.auth,
          ),
        ),
      );
    });

    test('403 with zero rate limit maps to rateLimited', () async {
      final api = GithubApi(
        token: 't',
        dio: _dio(
          (options) async => _error(
            403,
            headers: {
              'x-ratelimit-remaining': '0',
              'x-ratelimit-reset': '1700000000',
            },
          ),
        ),
      );
      await expectLater(
        api.listRuns('o', 'r'),
        throwsA(
          isA<GitHubApiException>().having(
            (error) => error.kind,
            'kind',
            GitHubApiErrorKind.rateLimited,
          ),
        ),
      );
    });
  });

  group('GithubDeviceAuth', () {
    test('requestDeviceCode parses the code', () async {
      final auth = GithubDeviceAuth(
        clientId: 'cid',
        dio: _dio((options) async {
          expect(options.path, '/login/device/code');
          expect(options.data, isA<Map>());
          expect((options.data as Map)['client_id'], 'cid');
          expect((options.data as Map)['scope'], contains('repo'));
          // GitHub answers with form-encoded text unless we ask for JSON.
          expect(options.headers['Accept'], contains('application/json'));
          return _json({
            'device_code': 'dc',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://github.com/login/device',
            'verification_uri_complete':
                'https://github.com/login/device?user_code=ABCD-EFGH',
            'expires_in': 900,
            'interval': 5,
          });
        }, baseUrl: 'https://github.com'),
      );
      final code = await auth.requestDeviceCode();
      expect(code.userCode, 'ABCD-EFGH');
      expect(code.verificationUriComplete, contains('ABCD-EFGH'));
      expect(code.interval, 5);
    });

    test('pollAccessToken waits, then returns the token', () async {
      var calls = 0;
      final auth = GithubDeviceAuth(
        clientId: 'cid',
        dio: _dio((options) async {
          calls++;
          expect(options.headers['Accept'], contains('application/json'));
          if (calls == 1) {
            return _json({'error': 'authorization_pending'});
          }
          return _json({'access_token': 'tok', 'token_type': 'bearer'});
        }, baseUrl: 'https://github.com'),
      );
      const code = GitHubDeviceCode(
        deviceCode: 'dc',
        userCode: 'uc',
        verificationUri: 'https://github.com/login/device',
        expiresIn: 900,
        interval: 5,
      );
      expect(await auth.pollAccessToken(code), (token: null, interval: null));
      expect(await auth.pollAccessToken(code), (token: 'tok', interval: null));
    });

    test(
      'pollAccessToken surfaces the escalated interval on slow_down',
      () async {
        final auth = GithubDeviceAuth(
          clientId: 'cid',
          dio: _dio(
            (options) async => _json({
              'error': 'slow_down',
              'error_description':
                  'Too many requests have been made '
                  'in the same timeframe.',
              'interval': 10,
            }),
            baseUrl: 'https://github.com',
          ),
        );
        const code = GitHubDeviceCode(
          deviceCode: 'dc',
          userCode: 'uc',
          verificationUri: 'https://github.com/login/device',
          expiresIn: 900,
          interval: 5,
        );
        expect(await auth.pollAccessToken(code), (token: null, interval: 10));
      },
    );

    test('pollAccessToken surfaces denial and expiry', () async {
      final denied = GithubDeviceAuth(
        clientId: 'cid',
        dio: _dio(
          (options) async => _json({'error': 'access_denied'}),
          baseUrl: 'https://github.com',
        ),
      );
      const code = GitHubDeviceCode(
        deviceCode: 'dc',
        userCode: 'uc',
        verificationUri: 'https://github.com/login/device',
        expiresIn: 900,
        interval: 5,
      );
      await expectLater(
        denied.pollAccessToken(code),
        throwsA(
          isA<DeviceFlowException>().having(
            (error) => error.kind,
            'kind',
            DeviceFlowError.denied,
          ),
        ),
      );

      final expired = GithubDeviceAuth(
        clientId: 'cid',
        dio: _dio(
          (options) async => _json({'error': 'expired_token'}),
          baseUrl: 'https://github.com',
        ),
      );
      await expectLater(
        expired.pollAccessToken(code),
        throwsA(
          isA<DeviceFlowException>().having(
            (error) => error.kind,
            'kind',
            DeviceFlowError.expired,
          ),
        ),
      );
    });
  });

  group('latestRunPerWorkflow', () {
    WorkflowRun run(int id, String workflow) => WorkflowRun(
      id: id,
      name: workflow,
      displayTitle: 'Run $id',
      headBranch: 'main',
      headSha: 'x',
      status: WorkflowRunStatus.completed,
      conclusion: WorkflowRunConclusion.success,
      runNumber: id,
    );

    test('keeps only the newest run of each workflow', () {
      final runs = [run(1, 'CI'), run(2, 'CI'), run(3, 'Deploy'), run(4, 'CI')];
      final latest = latestRunPerWorkflow(runs);
      expect(latest, hasLength(2));
      final byName = {for (final item in latest) item.name: item};
      expect(byName['CI']!.id, 4);
      expect(byName['Deploy']!.id, 3);
    });

    test('orders workflows newest first and tolerates empty input', () {
      expect(latestRunPerWorkflow(const []), isEmpty);
      final runs = [run(1, 'A'), run(2, 'B')];
      expect(latestRunPerWorkflow(runs).map((item) => item.name), ['B', 'A']);
    });
  });
}
