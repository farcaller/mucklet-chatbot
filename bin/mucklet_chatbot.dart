import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dotenv/dotenv.dart';
import 'package:glog/glog.dart';
import 'package:res_client/client.dart';
import 'package:res_client/debug.dart' as res_debug;
import 'package:res_client/event.dart';
import 'package:res_client/model.dart';
import 'package:res_client/password.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_router/shelf_router.dart';
import 'package:yaml/yaml.dart';
import 'package:prometheus_client/format.dart' as format;
import 'package:prometheus_client/prometheus_client.dart';
import 'package:prometheus_client/runtime_metrics.dart' as runtime_metrics;

const logger = GlogContext('main');

Counter? queryRequestsCounter;
Counter? cacheSizeCounter;
Counter? resEventsCounter;
Counter? messageCounter;
Gauge? roomPopsGauge;

Router statusRouter(ResClient client) {
  final app = Router();
  app.get('/debugz/cache', (Request request) async {
    final html = res_debug.cacheIndex(client).toString();

    return Response.ok(html, headers: {'content-type': 'text/html'});
  });

  app.get('/debugz/cache/<rid>', (Request request) async {
    final rid = request.params['rid'] ?? '';
    final cacheItem = client.get(rid);
    if (cacheItem == null) {
      return Response.notFound('');
    }
    final html = res_debug.cacheItem(cacheItem).toString();

    return Response.ok(html, headers: {'content-type': 'text/html'});
  });

  app.post('/debugz/cache/subscribe/<rid>', (Request request) async {
    final rid = request.params['rid'] ?? '';
    final resp = client.subscribe(rid, null);

    return Response.ok(jsonEncode(resp),
        headers: {'content-type': 'text/plain'});
  });

  app.get('/debugz/metrics', (Request request) async {
    final metrics =
        await CollectorRegistry.defaultRegistry.collectMetricFamilySamples();
    final buffer = StringBuffer('');
    format.write004(buffer, metrics);
    return Response.ok(buffer.toString(),
        headers: {'content-type': format.contentType});
  });

  return app;
}

ResModel findCharacter(ResModel user, String name, String surname) {
  try {
    return (user['chars'] as ResCollection)
        .items
        .where((e) => e['name'] == name && e['surname'] == surname)
        .first;
  } catch (e) {
    logger.error('failed to resolve the character: $e');
    rethrow;
  }
}

Future<ResModel> controlCharacter(
    ResClient client, ResModel player, ResModel char) async {
  final charId = char['id'] as String;
  var ctrl = (player['controlled'] as ResCollection)
      .items
      .firstWhere((c) => c['id'] == charId, orElse: () => null) as ResModel?;
  logger.debug('existing ctrl: $ctrl');
  ctrl ??=
      await client.call(player.rid, 'controlChar', params: {'charId': charId});
  logger.debug('final ctrl: $ctrl');
  if (ctrl == null) {
    throw 'failed to get ctrl';
  }
  if (ctrl['state'] != 'awake') {
    logger.info('ctrl state is ${ctrl['state']}, waking up');
    await client.call(ctrl.rid, 'wakeup', params: {'hidden': true});
  }
  return ctrl;
}

Future workerLoop(
  ResClient client, {
  required Uri uri,
  required Stream events,
  required String token,
  required dynamic config,
}) async {
  ResModel? ctrl;
  ResModel? bot;

  roomPopsGauge = Gauge(
    name: 'mucklet_room_population',
    help: 'The current population of the room.',
    labelNames: ['parent', 'room'],
    collectCallback: (collector) {
      final rids = client.cachedRids
          .where((r) => r.startsWith('core.area.') && r.endsWith('.children'));
      for (final r in rids) {
        final parent = r.split('.')[2];
        final children = client.get(r)!.item as ResModel;
        final childrenKv = children.toJson();
        for (final m in childrenKv.values) {
          final v = (m as ResModel).toJson();
          final name = v['name'];
          final pop = v['pop'] as int;
          roomPopsGauge!.labels([parent, name]).value = pop.toDouble();
        }
      }
    },
  )..register();

  await for (final e in events) {
    resEventsCounter!.labels(['${e.runtimeType}']).inc();
    switch (e.runtimeType) {
      case ConnectedEvent:
        logger.info('authenticating');
        await client.auth('auth', 'authenticateBot', params: {
          'token': token,
        });
        logger.info('auth success');
        bot = await client.call('core', 'getBot') as ResModel;
        logger.info('got bot $bot');
        await client.subscribe('core.chars', 'awake');
        ctrl = bot['controlled'] != null
            ? bot['controlled'] as ResModel
            : await client.call(bot.rid, 'controlChar') as ResModel;
        if (ctrl['state'] != 'awake') {
          await client.call(ctrl.rid, 'wakeup', params: {'hidden': true});
        }
        break;
      case DisconnectedEvent:
        logger.warning('disconnected, trying to reconnect');
        await client.reconnect(uri);
        break;
      case GenericEvent:
        final evt = e as GenericEvent;

        if (ctrl != null) {
          if (evt.rid == ctrl.rid && evt.name == 'out') {
            await handleOutEvent(client, ctrl, config, evt.payload);
          }
        }
        break;
      case PingEvent:
        if (ctrl != null) {
          try {
            await client.call(ctrl.rid, 'ping');
            await client.call(ctrl.rid, 'look', params: {'charId': ctrl['id']});
          } catch (e) {
            logger.error('ping failed: $e');
            rethrow;
          }
        }
        break;
    }
  }
}

Future handleOutEvent(
    ResClient client, ResModel ctrl, dynamic config, dynamic payload) async {
  final target = payload['target'];
  if (target is! Map<String, dynamic>) return;
  final char = payload['char'];
  if (char is! Map<String, dynamic>) return;
  if (target['id'] != ctrl['id']) return;
  if (char['id'] == ctrl['id']) return;
  var msg = payload['msg'] as String?;
  if (msg == null) {
    logger.warning('no message in $payload');
    return;
  }
  messageCounter!.labels([payload['type']]).inc();

  msg = msg.toLowerCase();
  final reply = config[msg] as List?;
  if (reply != null) {
    queryRequestsCounter!.labels([msg]).inc();
    for (final r in reply) {
      final method = r['whisper'] == true ? 'whisper' : 'address';
      var text = r['pose'] as String?;
      var pose = true;
      if (text == null) {
        text = r['say'] as String;
        pose = false;
      }
      text = text.replaceAll('%NAME%', char['name']);
      logger.trace('will reply with $text to ${char['id']}');
      await client.call(ctrl.rid, method, params: {
        'charId': char['id'],
        'msg': text,
        'pose': pose,
      });
    }
  } else {
    logger.warning('no repl for `$msg`');
  }
}

class PingEvent extends ResEvent {}

class PingableEvents {
  final ResClient _client;
  late final StreamController<ResEvent> _eventsController;
  late final StreamSubscription _periodic;

  PingableEvents(this._client)
      : _eventsController = StreamController.broadcast() {
    _periodic = Stream.periodic(const Duration(minutes: 3))
        .listen((_) => _eventsController.add(PingEvent()));
    _client.events.listen((event) => _eventsController.add(event));
  }

  dispose() {
    _periodic.cancel();
  }

  Stream<ResEvent> get events => _eventsController.stream;
}

final parser = ArgParser()
  ..addOption('config', help: 'path to the config file');

void main(List<String> arguments) async {
  runtime_metrics.register();

  queryRequestsCounter = Counter(
    name: 'mucklet_chatbot_query_requests_total',
    help: 'The total amount of queries.',
    labelNames: ['query'],
  )..register();

  resEventsCounter = Counter(
    name: 'mucklet_res_events_total',
    help: 'The total amount of RES events.',
    labelNames: ['event'],
  )..register();

  messageCounter = Counter(
    name: 'mucklet_incoming_messages_total',
    help: 'The total amount of incoming messages.',
    labelNames: ['type'],
  )..register();

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    print('mucklet_chatbot usage:');
    print('mucklet_chatbot [--config CONFIG]');
    print(parser.usage);
    exit(2);
  }

  final env = DotEnv(includePlatformEnvironment: true);
  if (args['config'] != null) {
    env.load(args['config']);
  }

  String token = env['AUTH_TOKEN']!;
  final server = env['SERVER'] ?? '';
  final statusWebserverHost = env['STATUS_WEBSERVER_HOST'];
  final statusWebserverPort = env['STATUS_WEBSERVER_PORT'];

  final file = File(env['CONFIG'] ?? '');
  final config = loadYaml(await file.readAsString());

  final client = ResClient();
  final pe = PingableEvents(client);

  client.reconnect(Uri.parse(server));

  final worker = workerLoop(client,
      uri: Uri.parse(server), events: pe.events, token: token, config: config);

  final statusServer =
      statusWebserverHost != null && statusWebserverPort != null
          ? io.serve(statusRouter(client), statusWebserverHost,
              int.parse(statusWebserverPort))
          : null;

  final futures = [worker];
  if (statusServer != null) {
    futures.add(statusServer);
  }

  Future.wait(futures);
}
