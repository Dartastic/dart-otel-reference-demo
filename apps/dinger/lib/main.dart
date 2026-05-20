// Dinger — last night's baseball, with stats live from the MLB Stats API,
// recaps written by Genkit (running on Dartastic OpenTelemetry), and every
// step lit up in Dartastic Hosted.

import 'package:dartastic_opentelemetry/dartastic_opentelemetry.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'data_source.dart';
import 'highlights_ai.dart';
import 'models.dart';
import 'schemas.dart';
import 'telemetry.dart';

late final HighlightService highlights;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Stand up Dartastic OpenTelemetry first so everything below traces.
  await initTelemetry();

  // 2. Route uncaught Flutter errors onto a span.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    final span = OTel.tracer().startSpan('flutter.error');
    span.recordException(details.exception, stackTrace: details.stack);
    span.setStatus(SpanStatusCode.Error, details.exceptionAsString());
    span.end();
  };

  // 3. Build the Genkit-backed highlight service once.
  highlights = HighlightService.create();

  runApp(const DingerApp());
}

class DingerApp extends StatelessWidget {
  const DingerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dinger',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF002D72)),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _service = LineupService();
  Lineup? _lineup;
  Object? _loadError;
  final _recaps = <int, Recap>{};
  final _busy = <int>{};
  final _watchBusy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadError = null;
      _lineup = null;
    });
    try {
      final lineup = await _service.loadLatest();
      if (mounted) setState(() => _lineup = lineup);
    } catch (e) {
      if (mounted) setState(() => _loadError = e);
    }
  }

  Future<void> _generate(GamePerformance p) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy.add(p.playerId));
    final tracer = OTel.tracer();
    final span = tracer.startSpan(
      'generate_highlight',
      attributes: OTel.attributesFromMap(<String, Object>{
        'app.player': p.player,
        'app.player_id': p.playerId,
        'app.home_runs': p.homeRuns,
      }),
    );
    try {
      // The Genkit flow runs inside this span, so its genkit:* spans nest
      // under "generate_highlight" in the trace.
      final recap =
          await tracer.withSpanAsync(span, () => highlights.generate(p.player));
      if (mounted) setState(() => _recaps[p.playerId] = recap);
    } catch (e, st) {
      span.recordException(e, stackTrace: st);
      span.setStatus(SpanStatusCode.Error, e.toString());
      messenger.showSnackBar(SnackBar(content: Text('Highlight failed: $e')));
    } finally {
      span.end();
      if (mounted) setState(() => _busy.remove(p.playerId));
    }
  }

  Future<void> _watch(GamePerformance p) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _watchBusy.add(p.playerId));
    try {
      final clips = await _service.highlightsFor(p);
      final url = clips.isNotEmpty ? clips.first.mlbUrl : kFilmRoomReels;
      if (clips.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No clip tagged — opening MLB Film Room')),
        );
      }
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open video: $e')));
    } finally {
      if (mounted) setState(() => _watchBusy.remove(p.playerId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dinger ⚾'),
        actions: [
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: _TelemetryBanner(label: _lineup?.label),
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Could not load live MLB data.'),
              const SizedBox(height: 8),
              Text('$_loadError', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }
    final lineup = _lineup;
    if (lineup == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (lineup.games.isEmpty) {
      return const Center(child: Text('No recent games found for your favorites.'));
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: lineup.games.length,
      itemBuilder: (context, i) {
        final p = lineup.games[i];
        return _PlayerCard(
          performance: p,
          recap: _recaps[p.playerId],
          generating: _busy.contains(p.playerId),
          watching: _watchBusy.contains(p.playerId),
          onGenerate: () => _generate(p),
          onWatch: () => _watch(p),
        );
      },
    );
  }
}

class _TelemetryBanner extends StatelessWidget {
  const _TelemetryBanner({this.label});
  final String? label;

  @override
  Widget build(BuildContext context) {
    final ai = highlights.hasModel ? 'Gemini' : 'template (set GEMINI_API_KEY)';
    final dest = sendingToHosted ? 'Dartastic Hosted' : 'local collector';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: Colors.black.withValues(alpha: 0.15),
      child: Text(
        '${label ?? 'Loading'} · stats live from MLB · recaps by $ai · traces → $dest',
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
    );
  }
}

class _PlayerCard extends StatelessWidget {
  const _PlayerCard({
    required this.performance,
    required this.recap,
    required this.generating,
    required this.watching,
    required this.onGenerate,
    required this.onWatch,
  });

  final GamePerformance performance;
  final Recap? recap;
  final bool generating;
  final bool watching;
  final VoidCallback onGenerate;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) {
    final p = performance;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(p.player, style: Theme.of(context).textTheme.titleLarge),
            Text('${p.team}  ${p.matchup}   ·   ${p.result}   ·   ${p.date}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            Text(p.summary,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            if (recap != null) ...[
              Text(recap!.headline,
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(recap!.body),
              const SizedBox(height: 6),
              Text('💡 ${recap!.funFact}',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(fontStyle: FontStyle.italic)),
              const SizedBox(height: 4),
              Chip(
                visualDensity: VisualDensity.compact,
                label: Text('by ${highlights.generatedBy}'),
              ),
            ],
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              children: [
                if (recap == null)
                  FilledButton.icon(
                    onPressed: generating ? null : onGenerate,
                    icon: generating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(generating ? 'Writing…' : 'Generate highlight'),
                  ),
                if (p.gamePk != null)
                  OutlinedButton.icon(
                    onPressed: watching ? null : onWatch,
                    icon: watching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_circle_outline),
                    label: const Text('Watch on MLB'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
