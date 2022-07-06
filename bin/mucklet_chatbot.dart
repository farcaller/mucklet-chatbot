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
    final resp = client.subscribe(rid);

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
    await client.call(ctrl.rid, 'wakeup');
  }
  return ctrl;
}

Future workerLoop(
  ResClient client, {
  required Stream events,
  required String name,
  required String hash,
  required String characterName,
  required String characterSurname,
  required dynamic config,
}) async {
  ResModel? ctrl;

  await for (final e in events) {
    switch (e.runtimeType) {
      case ConnectedEvent:
        logger.info('authenticating as $name');
        await client.auth('auth', 'login', params: {
          'name': name,
          'hash': hash,
        });
        logger.info('auth success');
        final player = await client.call('core', 'getPlayer') as ResModel;
        logger.info('got player $player');
        final char = findCharacter(player, characterName, characterSurname);
        logger.info('got character $char');
        ctrl = await controlCharacter(client, player, char);
        break;
      case DisconnectedEvent:
        logger.warning('disconnected, trying to reconnect');
        client.reconnect();
        break;
      case ModelChangedEvent:
        // logger.debug(
        //     '=== model changed ${e.rid}:\nnew: ${e.newProps}\nold: ${e.oldProps}');
        break;
      case CollectionAddEvent:
        // logger.debug(
        //     '=== collection add ${e.rid}:\nidx: ${e.index}\nval: ${e.value}');
        break;
      case CollectionRemoveEvent:
        // logger.debug(
        //     '=== collection remove ${e.rid}:\nidx: ${e.index}\nval: ${e.value}');
        break;
      case GenericEvent:
        final evt = e as GenericEvent;
        // logger.debug(
        //     '=== generic ${evt.rid}:\nname: ${evt.name}\ndata: ${evt.payload}');

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

  PingableEvents(this._client)
      : _eventsController = StreamController.broadcast() {
    _client.events.listen((event) => _eventsController.add(event));
  }

  Stream<ResEvent> get events => _eventsController.stream;
}

final parser = ArgParser()
  ..addOption('config', help: 'path to the config file', mandatory: true);

void main(List<String> arguments) async {
  runtime_metrics.register();

  queryRequestsCounter = Counter(
    name: 'query_requests_total',
    help: 'The total amount of queries.',
    labelNames: ['query'],
  )..register();

  var args;
  try {
    args = parser.parse(arguments);
  } catch (e) {
    print('mucklet_chatbot usage:');
    print('mucklet_chatbot --config CONFIG');
    print(parser.usage);
    exit(2);
  }

  final env = DotEnv(includePlatformEnvironment: true)..load([args['config']]);

  final name = env['USER'] ?? '';
  var hash = env['HASH'];
  if (hash == null) {
    final password = env['PASSWORD'] ?? '';
    hash = saltPassword(password);
  }
  final characterName = env['CHARACTER_NAME'] ?? '';
  final characterSurname = env['CHARACTER_SURNAME'] ?? '';
  final server = env['SERVER'] ?? '';
  final statusWebserverHost = env['STATUS_WEBSERVER_HOST'];
  final statusWebserverPort = env['STATUS_WEBSERVER_PORT'];

  final file = File(env['CONFIG'] ?? '');
  final config = loadYaml(await file.readAsString());

  logger.info(
      'running as character $characterName $characterSurname owned by $name');

  final client = ResClient(Uri.parse(server));
  final pe = PingableEvents(client);

  client.reconnect();

  final worker = workerLoop(client,
      events: pe.events,
      name: name,
      hash: hash,
      characterName: characterName,
      characterSurname: characterSurname,
      config: config);

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
