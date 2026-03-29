import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pipeline_engine.dart';
import 'logging.dart';

// ─── TOS Keys ────────────────────────────────────────────────────────────────

const _kTosHandled   = 'tos_handled';
const _kImageConsent = 'image_consent';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  await PestDatabase.instance.init();
  await DetectionDatabase.instance.init();   // ← init logging DB alongside pest DB
  final cameras = await availableCameras();
  final prefs   = await SharedPreferences.getInstance();
  runApp(ProviderScope(child: GrowLivApp(cameras: cameras, prefs: prefs)));
}

// ─── Design System ────────────────────────────────────────────────────────────

class T {
  static const bg           = Color(0xFF080F0B);
  static const surface      = Color(0xFF0F1A13);
  static const card         = Color(0xFF162019);
  static const elevated     = Color(0xFF1D2B21);
  static const overlay      = Color(0xFF243328);
  static const accent       = Color(0xFF52E68E);
  static const accentMid    = Color(0xFF2A9E5C);
  static const accentDim    = Color(0xFF1A5E38);
  static const teal         = Color(0xFF3DD6C8);
  static const warn         = Color(0xFFFFBB3C);
  static const danger       = Color(0xFFFF5A5A);
  static const info         = Color(0xFF5AC8FA);
  static const textPri      = Color(0xFFF0F7F3);
  static const textSec      = Color(0xFF7DA890);
  static const textTer      = Color(0xFF4A6B57);
  static const border       = Color(0xFF1E3028);
  static const borderBright = Color(0xFF2A4535);

  static ThemeData get theme => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: bg,
        colorScheme: const ColorScheme.dark(surface: surface, primary: accent, error: danger),
        textTheme: TextTheme(
          displayLarge:  GoogleFonts.dmSans(fontSize: 30, fontWeight: FontWeight.w700, color: textPri, letterSpacing: -0.8, height: 1.1),
          displayMedium: GoogleFonts.dmSans(fontSize: 22, fontWeight: FontWeight.w700, color: textPri, letterSpacing: -0.5, height: 1.15),
          titleLarge:    GoogleFonts.dmSans(fontSize: 19, fontWeight: FontWeight.w600, color: textPri, letterSpacing: -0.3),
          titleMedium:   GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w600, color: textPri, letterSpacing: -0.1),
          titleSmall:    GoogleFonts.dmSans(fontSize: 13, fontWeight: FontWeight.w500, color: textSec),
          bodyLarge:     GoogleFonts.outfit(fontSize: 15, color: textSec, height: 1.6, letterSpacing: 0.1),
          bodyMedium:    GoogleFonts.outfit(fontSize: 14, color: textSec, height: 1.55),
          bodySmall:     GoogleFonts.outfit(fontSize: 12, color: textTer, height: 1.5),
          labelLarge:    GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w700, color: bg, letterSpacing: 0.1),
          labelMedium:   GoogleFonts.outfit(fontSize: 11, fontWeight: FontWeight.w600, color: textSec, letterSpacing: 1.0),
        ),
      );
}

// ─── Data Models ──────────────────────────────────────────────────────────────

class PestInfo {
  final String sqlName, displayName, bucketName, briefSummary, identification, managementTips;
  const PestInfo({required this.sqlName, required this.displayName, required this.bucketName,
    required this.briefSummary, required this.identification, required this.managementTips});
  factory PestInfo.fromMap(Map<String, Object?> row) => PestInfo(
    sqlName: row['sql_name'] as String? ?? '', displayName: row['display_name'] as String? ?? '',
    bucketName: row['bucket_name'] as String? ?? '', briefSummary: row['brief_summary'] as String? ?? '',
    identification: row['identification'] as String? ?? '', managementTips: row['management_tips'] as String? ?? '');
}

class CropNote {
  final String cropName, displayName, note;
  const CropNote({required this.cropName, required this.displayName, required this.note});
  factory CropNote.fromMap(Map<String, Object?> row) => CropNote(
    cropName: row['crop_name'] as String? ?? '', displayName: row['display_name'] as String? ?? '',
    note: row['crop_specific_notes'] as String? ?? '');
}

class PestBundle {
  final PestInfo? pest;
  final List<CropNote> crops;
  const PestBundle({required this.pest, required this.crops});
}

class HitlOption {
  final int order;
  final String optionText, targetSqlName;
  const HitlOption({required this.order, required this.optionText, required this.targetSqlName});
  factory HitlOption.fromMap(Map<String, Object?> row) => HitlOption(
    order: row['option_order'] as int? ?? 0,
    optionText: row['option_text'] as String? ?? '',
    targetSqlName: row['target_sql_name'] as String? ?? '');

  String get displayName => targetSqlName.replaceAll('_', ' ').split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  List<String> get candidateAssetPaths => [
    'assets/examples/$targetSqlName.jpg', 'assets/examples/$targetSqlName.jpeg',
    'assets/examples/$targetSqlName.png', 'assets/examples/$targetSqlName.webp'];
}

class HitlPrompt {
  final String question;
  final List<HitlOption> options;
  const HitlPrompt({required this.question, required this.options});
}

// ─── Database ─────────────────────────────────────────────────────────────────

class PestDatabase {
  PestDatabase._();
  static final PestDatabase instance = PestDatabase._();
  Database? _db;

  Future<void> init() async {
    if (_db != null) return;
    final dbDir  = await getDatabasesPath();
    final dbPath = p.join(dbDir, 'growliv.db');
    final outFile = File(dbPath);
    if (!await outFile.exists()) {
      await outFile.parent.create(recursive: true);
      final data  = await rootBundle.load('assets/database/growliv.db');
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      await outFile.writeAsBytes(bytes, flush: true);
    }
    _db = await openDatabase(dbPath, readOnly: true);
  }

  Future<Database> get _database async { await init(); return _db!; }

  Future<PestInfo?> getPest(String sqlName) async {
    final db   = await _database;
    final rows = await db.query('pests', where: 'sql_name = ?', whereArgs: [sqlName], limit: 1);
    if (rows.isEmpty) return null;
    return PestInfo.fromMap(rows.first);
  }

  Future<List<CropNote>> getCropNotes(String sqlName) async {
    final db   = await _database;
    final rows = await db.rawQuery('''
      SELECT c.crop_name, c.display_name, pc.crop_specific_notes
      FROM pest_crops pc JOIN crops c ON c.crop_name = pc.crop_name
      WHERE pc.pest_name = ? ORDER BY c.display_name ASC
    ''', [sqlName]);
    return rows.map(CropNote.fromMap).toList();
  }

  Future<PestBundle> getPestBundle(String sqlName) async {
    final pest = await getPest(sqlName);
    if (pest == null) return const PestBundle(pest: null, crops: []);
    return PestBundle(pest: pest, crops: await getCropNotes(sqlName));
  }

  Future<HitlPrompt> getHitlPrompt(String bucketName) async {
    final db         = await _database;
    final bucketRows = await db.query('buckets', columns: ['generic_question'],
        where: 'bucket_name = ?', whereArgs: [bucketName], limit: 1);
    final optionRows = await db.query('hitl_options',
        where: 'bucket_name = ?', whereArgs: [bucketName], orderBy: 'option_order ASC');
    final question = bucketRows.isNotEmpty
        ? bucketRows.first['generic_question'] as String? ?? 'How does it look?' : 'How does it look?';
    return HitlPrompt(question: question, options: optionRows.map(HitlOption.fromMap).toList());
  }
}

// ─── State ────────────────────────────────────────────────────────────────────

enum AppStatus { idle, loading, running, done, error }

class PState {
  final AppStatus       status;
  final String?         imagePath;
  final PipelineResult? result;
  final String?         error;
  final String          msg;
  final double?         progress;
  // The UUID of the current inference_events row — used to update feedback later.
  final String?         eventId;
  // Whether the image came from camera or gallery — needed for logging.
  final String          detectionType;

  const PState({
    this.status        = AppStatus.idle,
    this.imagePath,
    this.result,
    this.error,
    this.msg           = '',
    this.progress,
    this.eventId,
    this.detectionType = 'gallery',
  });

  PState copyWith({
    AppStatus?      status,
    String?         imagePath,
    PipelineResult? result,
    String?         error,
    String?         msg,
    double?         progress,
    String?         eventId,
    String?         detectionType,
  }) => PState(
        status:        status        ?? this.status,
        imagePath:     imagePath     ?? this.imagePath,
        result:        result        ?? this.result,
        error:         error         ?? this.error,
        msg:           msg           ?? this.msg,
        progress:      progress      ?? this.progress,
        eventId:       eventId       ?? this.eventId,
        detectionType: detectionType ?? this.detectionType,
      );
}

class PipelineNotifier extends Notifier<PState> {
  final _pipeline  = InsectopediaPipeline();
  bool   _ready    = false;
  // Shared prefs read once and cached so we can check image_consent in analyze()
  SharedPreferences? _prefs;

  @override
  PState build() => const PState();

  void _onProgress(PipelineProgress p) =>
      state = state.copyWith(status: AppStatus.running, msg: p.label, progress: p.fraction);

  Future<void> analyze(String path, {String detectionType = 'gallery'}) async {
    _prefs ??= await SharedPreferences.getInstance();
    final imageConsent = _prefs!.getBool(_kImageConsent) ?? false;
    final sw = Stopwatch()..start();     // ← measure inference wall-clock time

    try {
      state = PState(
        status:        AppStatus.loading,
        imagePath:     path,
        detectionType: detectionType,
        msg:           'Loading models…',
        progress:      0.0,
      );
      if (!_ready) { await _pipeline.loadModels(onProgress: _onProgress); _ready = true; }
      state = state.copyWith(status: AppStatus.running, msg: 'Detecting pests…', progress: 0.15);

      final bytes   = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Could not decode image');

      final result = await _pipeline.run(decoded, onProgress: _onProgress);
      sw.stop();

      // ── Log the inference event immediately after pipeline finishes ──
      final eventId = await EventLogger.logInference(
        result:        result,
        imagePath:     path,
        detectionType: detectionType,
        imageConsent:  imageConsent,
        inferenceMs:   sw.elapsedMilliseconds,
      );

      state = state.copyWith(
        status:   AppStatus.done,
        result:   result,
        msg:      'Done',
        progress: 1.0,
        eventId:  eventId,      // ← store event ID so result page can update feedback
      );
    } catch (e) {
      sw.stop();
      state = state.copyWith(status: AppStatus.error, error: e.toString());
    }
  }

  void reset() => state = const PState();
}

final pipelineProvider       = NotifierProvider<PipelineNotifier, PState>(PipelineNotifier.new);
final showConfidenceProvider = StateProvider<bool>((ref) => true);

// ─── App Root ─────────────────────────────────────────────────────────────────

class GrowLivApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  final SharedPreferences prefs;
  const GrowLivApp({super.key, required this.cameras, required this.prefs});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Insectopedia',
        debugShowCheckedModeBanner: false,
        theme: T.theme,
        home: prefs.getBool(_kTosHandled) == true
            ? HomeScreen(cameras: cameras)
            : TosScreen(cameras: cameras, prefs: prefs),
      );
}

// ─── TOS Screen ───────────────────────────────────────────────────────────────

class TosScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  final SharedPreferences prefs;
  const TosScreen({super.key, required this.cameras, required this.prefs});

  @override
  State<TosScreen> createState() => _TosScreenState();
}

class _TosScreenState extends State<TosScreen> {
  bool _imageConsent = false;
  bool _declining    = false;

  Future<void> _agree() async {
    await widget.prefs.setBool(_kTosHandled,   true);
    await widget.prefs.setBool(_kImageConsent, _imageConsent);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(cameras: widget.cameras)),
    );
  }

  Future<void> _decline() async {
    await widget.prefs.setBool(_kTosHandled,   true);
    await widget.prefs.setBool(_kImageConsent, false);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(cameras: widget.cameras)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 72, height: 72,
                decoration: BoxDecoration(
                  color: T.accent.withAlpha(18),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: T.accent.withAlpha(60)),
                ),
                child: const Icon(Icons.pest_control_rounded, color: T.accent, size: 34),
              ),
              const SizedBox(height: 20),
              Text('Insectopedia', style: T.theme.textTheme.displayLarge),
              const SizedBox(height: 6),
              Text('On-device agricultural pest identification',
                  style: T.theme.textTheme.bodyMedium, textAlign: TextAlign.center),
              const SizedBox(height: 40),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: T.card,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: T.borderBright),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(anim),
                      child: child,
                    ),
                  ),
                  child: _declining
                      ? _DeclineContent(key: const ValueKey('decline'))
                      : _ConsentContent(
                          key: const ValueKey('consent'),
                          imageConsent: _imageConsent,
                          onToggle: () => setState(() => _imageConsent = !_imageConsent),
                        ),
                ),
              ),
              const SizedBox(height: 28),
              if (!_declining) ...[
                _PrimaryBtn(icon: Icons.check_rounded, label: 'Agree & Continue', onTap: _agree),
                const SizedBox(height: 12),
                _GhostBtn(icon: Icons.close_rounded, label: 'Decline',
                    onTap: () => setState(() => _declining = true)),
              ] else ...[
                _PrimaryBtn(icon: Icons.arrow_back_rounded, label: 'Go Back',
                    onTap: () => setState(() => _declining = false)),
                const SizedBox(height: 12),
                _GhostBtn(icon: Icons.close_rounded, label: 'Continue without consent', onTap: _decline),
              ],
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 12, color: T.textTer),
                  const SizedBox(width: 5),
                  Text('Insectopedia v1.0 · University of Windsor',
                      style: T.theme.textTheme.bodySmall),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConsentContent extends StatelessWidget {
  final bool imageConsent;
  final VoidCallback onToggle;
  const _ConsentContent({super.key, required this.imageConsent, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: T.accent.withAlpha(18), borderRadius: BorderRadius.circular(8),
                border: Border.all(color: T.accent.withAlpha(50))),
            child: const Icon(Icons.privacy_tip_rounded, size: 14, color: T.accent),
          ),
          const SizedBox(width: 10),
          Text('Privacy & Data', style: T.theme.textTheme.titleMedium),
        ]),
        const SizedBox(height: 14),
        Text('Insectopedia uses on-device AI to identify agricultural pests from '
            'photos you take or upload. No image ever leaves your phone without '
            'your explicit permission.', style: T.theme.textTheme.bodyMedium),
        const SizedBox(height: 20),
        Container(height: 1, color: T.border),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: onToggle,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 22, height: 22,
                decoration: BoxDecoration(
                  color: imageConsent ? T.accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: imageConsent ? T.accent : T.borderBright, width: 1.5),
                ),
                child: imageConsent ? const Icon(Icons.check_rounded, size: 14, color: T.bg) : null,
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Allow image storage to improve Insectopedia',
                    style: T.theme.textTheme.titleSmall?.copyWith(color: T.textPri)),
                const SizedBox(height: 4),
                Text('Images are used only for model training and are never shared or sold.',
                    style: T.theme.textTheme.bodySmall),
              ])),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: T.surface, borderRadius: BorderRadius.circular(8),
              border: Border.all(color: T.border)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.info_outline_rounded, size: 12, color: T.textTer),
            const SizedBox(width: 6),
            Text('Optional — the app works fully either way.', style: T.theme.textTheme.bodySmall),
          ]),
        ),
      ],
    );
  }
}

class _DeclineContent extends StatelessWidget {
  const _DeclineContent({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(color: T.warn.withAlpha(18), borderRadius: BorderRadius.circular(8),
                border: Border.all(color: T.warn.withAlpha(50))),
            child: const Icon(Icons.help_outline_rounded, size: 14, color: T.warn),
          ),
          const SizedBox(width: 10),
          Text('Just to confirm', style: T.theme.textTheme.titleMedium),
        ]),
        const SizedBox(height: 14),
        Text('If you decline, Insectopedia still works fully — pest identification, '
            'HITL guidance, and crop notes are all available.', style: T.theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        Text('We will not store your images. Anonymous scan metadata (species '
            'predictions and confidence scores) may still be logged to help us '
            'understand real-world model performance.', style: T.theme.textTheme.bodyMedium),
      ],
    );
  }
}

// ─── Home Screen ──────────────────────────────────────────────────────────────

class HomeScreen extends ConsumerStatefulWidget {
  final List<CameraDescription> cameras;
  const HomeScreen({super.key, required this.cameras});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> with SingleTickerProviderStateMixin {
  late AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _pulse.dispose(); super.dispose(); }

  Future<void> _gallery() async {
    final f = await ImagePicker().pickImage(
        source: ImageSource.gallery, imageQuality: 90, maxWidth: 2048, maxHeight: 2048);
    if (f != null) ref.read(pipelineProvider.notifier).analyze(f.path, detectionType: 'gallery');
  }

  Future<void> _camera() async {
    if (widget.cameras.isEmpty) return;
    final path = await Navigator.push<String>(context,
        MaterialPageRoute(builder: (_) => CameraCapturePage(cameras: widget.cameras)));
    if (path != null) ref.read(pipelineProvider.notifier).analyze(path, detectionType: 'camera');
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(pipelineProvider);
    return Scaffold(
      backgroundColor: T.bg,
      body: SafeArea(
        child: ps.status == AppStatus.done && ps.result != null
            ? ResultPage(
                imagePath:     ps.imagePath!,
                result:        ps.result!,
                eventId:       ps.eventId,
                detectionType: ps.detectionType,
                onReset:       () => ref.read(pipelineProvider.notifier).reset(),
              )
            : _body(ps),
      ),
    );
  }

  Widget _body(PState ps) => Column(
        children: [
          _AppHeader(pulse: _pulse, onSettings: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const SettingsPage()))),
          const Spacer(),
          switch (ps.status) {
            AppStatus.idle   => _Idle(onCamera: _camera, onGallery: _gallery),
            AppStatus.loading || AppStatus.running =>
                _Loading(msg: ps.msg, progress: ps.progress ?? 0.0),
            AppStatus.error  => _Error(msg: ps.error ?? '',
                onRetry: () => ref.read(pipelineProvider.notifier).reset()),
            _ => const SizedBox.shrink(),
          },
          const Spacer(),
          const SizedBox(height: 24),
        ],
      );
}

class _AppHeader extends StatelessWidget {
  final AnimationController pulse;
  final VoidCallback onSettings;
  const _AppHeader({required this.pulse, required this.onSettings});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
        child: Row(children: [
          AnimatedBuilder(
            animation: pulse,
            builder: (_, __) => Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.lerp(T.accentDim, T.accent, pulse.value),
                boxShadow: [BoxShadow(color: T.accent.withAlpha((130 * pulse.value).toInt()),
                    blurRadius: 10, spreadRadius: 1)],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('Insectopedia', style: T.theme.textTheme.displayLarge),
          const Spacer(),
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: T.border)),
            child: IconButton(
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.tune_rounded, color: T.textSec, size: 20),
              onPressed: onSettings,
            ),
          ),
        ]),
      );
}

// ─── Animated Page Shell ──────────────────────────────────────────────────────

class _PageTransition extends StatelessWidget {
  final Widget child;
  final Object transitionKey;
  const _PageTransition({required this.child, required this.transitionKey});

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 280),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(anim),
            child: child,
          ),
        ),
        child: KeyedSubtree(key: ValueKey(transitionKey), child: child),
      );
}

// ─── Idle State ───────────────────────────────────────────────────────────────

class _Idle extends StatefulWidget {
  final VoidCallback onCamera, onGallery;
  const _Idle({required this.onCamera, required this.onGallery});

  @override
  State<_Idle> createState() => _IdleState();
}

class _IdleState extends State<_Idle> with SingleTickerProviderStateMixin {
  late AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(vsync: this, duration: const Duration(milliseconds: 2800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() { _breathe.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(children: [
          AnimatedBuilder(
            animation: _breathe,
            builder: (_, __) => SizedBox(
              width: 160, height: 160,
              child: CustomPaint(painter: _RingPainter(pulse: _breathe.value)),
            ),
          ),
          const SizedBox(height: 28),
          Text('Identify a pest', style: T.theme.textTheme.displayLarge?.copyWith(fontSize: 26)),
          const SizedBox(height: 10),
          Text(
            'Take a photo or upload from your gallery.\nOn-device AI will identify the pest and\nprovide actionable guidance.',
            textAlign: TextAlign.center, style: T.theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 32),
          _PrimaryBtn(icon: Icons.camera_alt_rounded, label: 'Open Camera', onTap: widget.onCamera),
          const SizedBox(height: 12),
          _SecondaryBtn(icon: Icons.photo_library_rounded, label: 'Choose from Gallery', onTap: widget.onGallery),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.lock_outline_rounded, size: 13, color: T.textTer),
            const SizedBox(width: 5),
            Text('100% on-device — no data ever leaves your phone', style: T.theme.textTheme.bodySmall),
          ]),
        ]),
      );
}

// ─── Loading State ────────────────────────────────────────────────────────────

class _Loading extends StatefulWidget {
  final String msg;
  final double progress;
  const _Loading({required this.msg, required this.progress});

  @override
  State<_Loading> createState() => _LoadingState();
}

class _LoadingState extends State<_Loading> with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  late Animation<double>   _smoothed;
  double _displayed = 0.0;

  @override
  void initState() {
    super.initState();
    _displayed = widget.progress;
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _anim.addListener(() => setState(() => _displayed = _smoothed.value));
  }

  @override
  void didUpdateWidget(_Loading old) {
    super.didUpdateWidget(old);
    if (widget.progress != old.progress) {
      _smoothed = Tween<double>(begin: _displayed, end: widget.progress)
          .animate(CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic));
      _anim.forward(from: 0);
    }
  }

  @override
  void dispose() { _anim.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final pct = (_displayed * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(children: [
        SizedBox(
          width: 80, height: 80,
          child: Stack(alignment: Alignment.center, children: [
            SizedBox(width: 80, height: 80,
                child: CircularProgressIndicator(value: _displayed, color: T.accent,
                    backgroundColor: T.border, strokeWidth: 3, strokeCap: StrokeCap.round)),
            Text('$pct%', style: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w700, color: T.accent)),
          ]),
        ),
        const SizedBox(height: 20),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          transitionBuilder: (child, anim) => FadeTransition(opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero).animate(anim),
              child: child)),
          child: Text(widget.msg.isEmpty ? 'Analysing…' : widget.msg,
              key: ValueKey(widget.msg), style: T.theme.textTheme.titleMedium, textAlign: TextAlign.center),
        ),
        const SizedBox(height: 6),
        Text('Processing on your device', textAlign: TextAlign.center, style: T.theme.textTheme.bodySmall),
        const SizedBox(height: 24),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: _displayed, minHeight: 4,
                backgroundColor: T.border, valueColor: const AlwaysStoppedAnimation(T.accent)),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            _StageDot(label: 'Load',     frac: 0.15, current: _displayed),
            _StageDot(label: 'Detect',   frac: 0.45, current: _displayed),
            _StageDot(label: 'Segment',  frac: 0.55, current: _displayed),
            _StageDot(label: 'Classify', frac: 0.85, current: _displayed),
            _StageDot(label: 'Done',     frac: 1.0,  current: _displayed),
          ]),
        ]),
      ]),
    );
  }
}

class _StageDot extends StatelessWidget {
  final String label;
  final double frac, current;
  const _StageDot({required this.label, required this.frac, required this.current});

  @override
  Widget build(BuildContext context) {
    final reached = current >= frac - 0.01;
    return Column(children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 6, height: 6,
        decoration: BoxDecoration(shape: BoxShape.circle, color: reached ? T.accent : T.border),
      ),
      const SizedBox(height: 4),
      Text(label, style: GoogleFonts.dmSans(fontSize: 9, fontWeight: FontWeight.w600,
          color: reached ? T.accentMid : T.textTer, letterSpacing: 0.3)),
    ]);
  }
}

// ─── Error State ──────────────────────────────────────────────────────────────

class _Error extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  const _Error({required this.msg, required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(children: [
          Container(width: 64, height: 64,
            decoration: BoxDecoration(color: T.danger.withAlpha(20), shape: BoxShape.circle,
                border: Border.all(color: T.danger.withAlpha(60))),
            child: const Icon(Icons.warning_amber_rounded, color: T.danger, size: 30)),
          const SizedBox(height: 16),
          Text('Analysis failed', style: T.theme.textTheme.titleLarge!.copyWith(color: T.danger)),
          const SizedBox(height: 8),
          Text(msg, textAlign: TextAlign.center, style: T.theme.textTheme.bodyMedium),
          const SizedBox(height: 28),
          _PrimaryBtn(icon: Icons.refresh_rounded, label: 'Try Again', onTap: onRetry),
        ]),
      );
}

// ─── Result Page ──────────────────────────────────────────────────────────────

class ResultPage extends ConsumerStatefulWidget {
  final String         imagePath;
  final PipelineResult result;
  final VoidCallback   onReset;
  final String?        eventId;        // logging row UUID — may be null on error
  final String         detectionType;  // "camera" | "gallery"

  const ResultPage({
    super.key,
    required this.imagePath,
    required this.result,
    required this.onReset,
    this.eventId,
    this.detectionType = 'gallery',
  });

  @override
  ConsumerState<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends ConsumerState<ResultPage> {
  bool    _showDetails  = false;
  bool    _showHitl     = false;
  String? _selectedSqlName;
  // Once HITL is shown, record it so markSkipped knows to set hitlTriggered = 1
  bool    _hitlWasShown = false;

  bool   get _hasPrediction => !const ['NO_DETECTION', 'LOW_CONF'].contains(widget.result.predSpecies);
  String get _activeSqlName => _selectedSqlName ?? widget.result.predSpecies;

  Future<PestBundle>  _bundleFuture() => PestDatabase.instance.getPestBundle(_activeSqlName);
  Future<HitlPrompt>  _hitlFuture()   => PestDatabase.instance.getHitlPrompt(widget.result.predBucket);

  String _fallbackName(String raw) => raw.replaceAll('_', ' ').split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  String _headline(String name) {
    if (_selectedSqlName != null)   return 'Corrected to $name';
    if (widget.result.joint >= 0.7) return 'Identified as $name';
    return 'Possibly $name';
  }

  // ── Logging helpers ────────────────────────────────────────────────────────

  Future<void> _logCorrect() async {
    if (widget.eventId == null) return;
    // If HITL was shown but user went back and confirmed original, use markCorrectAfterHitl
    if (_hitlWasShown) {
      await EventLogger.markCorrectAfterHitl(widget.eventId!);
    } else {
      await EventLogger.markCorrect(widget.eventId!);
    }
  }

  Future<void> _logCorrected(String correctedSpecies) async {
    if (widget.eventId == null) return;
    await EventLogger.markCorrected(widget.eventId!, correctedSpecies: correctedSpecies);
  }

  Future<void> _logSkipped() async {
    if (widget.eventId == null) return;
    await EventLogger.markSkipped(widget.eventId!, hitlWasShown: _hitlWasShown);
  }

  // ── UI handlers ────────────────────────────────────────────────────────────

  void _openLightbox(BuildContext context, int initialIndex, String imagePath, String speciesName) {
    Navigator.of(context).push(PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black87,
      barrierDismissible: true,
      pageBuilder: (_, __, ___) => _Lightbox(
        initialIndex: initialIndex, imagePath: imagePath,
        sqlName: _activeSqlName, speciesName: speciesName),
      transitionsBuilder: (_, anim, __, child) =>
          FadeTransition(opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut), child: child),
    ));
  }

  void _handleNo() {
    setState(() { _showHitl = true; _showDetails = false; _hitlWasShown = true; });
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasPrediction) {
      return _UnknownResultPage(
        imagePath: widget.imagePath,
        onReset: () { _logSkipped(); widget.onReset(); },
      );
    }

    return FutureBuilder<PestBundle>(
      future: _bundleFuture(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done)
          return const Center(child: CircularProgressIndicator(color: T.accent, strokeWidth: 2));

        final bundle      = snap.data;
        final pest        = bundle?.pest;
        final crops       = bundle?.crops ?? const <CropNote>[];
        final displayName = pest?.displayName ?? _fallbackName(_activeSqlName);
        final summary     = pest?.briefSummary.isNotEmpty == true
            ? pest!.briefSummary : 'Please confirm whether this result looks correct.';

        if (_showDetails && pest != null) {
          return _PageTransition(
            transitionKey: 'details',
            child: PestDetailsPage(
              imagePath: widget.imagePath, pest: pest, crops: crops,
              onBack: () => setState(() => _showDetails = false),
              // Retake from details page = skipped
              onReset: () { _logSkipped(); widget.onReset(); },
            ),
          );
        }

        if (_showHitl) {
          return _PageTransition(
            transitionKey: 'hitl',
            child: FutureBuilder<HitlPrompt>(
              future: _hitlFuture(),
              builder: (context, hitlSnap) {
                if (hitlSnap.connectionState != ConnectionState.done)
                  return const Center(child: CircularProgressIndicator(color: T.accent, strokeWidth: 2));
                final prompt = hitlSnap.data;
                return _HitlQuestionPage(
                  imagePath:  widget.imagePath,
                  bucketName: widget.result.predBucket,
                  question:   prompt?.question ?? 'How does it look?',
                  options:    prompt?.options  ?? const <HitlOption>[],
                  onSelect: (opt) {
                    // User picked a correction — log it then show details
                    _logCorrected(opt.targetSqlName);
                    setState(() {
                      _selectedSqlName = opt.targetSqlName;
                      _showHitl        = false;
                      _showDetails     = false;
                    });
                  },
                  onBack:   () => setState(() => _showHitl = false),
                  // Retake from HITL = skipped
                  onRetake: () { _logSkipped(); widget.onReset(); },
                );
              },
            ),
          );
        }

        final highConf     = widget.result.joint >= 0.7;
        final isCorrection = _selectedSqlName != null;
        final chipColor    = isCorrection ? T.info : highConf ? T.accent : T.warn;
        final chipLabel    = isCorrection ? 'Result Corrected'
            : highConf ? 'High Confidence' : 'Needs Confirmation';

        return _PageTransition(
          transitionKey: 'result-$_activeSqlName',
          child: CustomScrollView(slivers: [
            SliverToBoxAdapter(
              child: Stack(children: [
                SizedBox(
                  width: double.infinity, height: 300,
                  child: Row(children: [
                    Expanded(child: GestureDetector(
                      onTap: () => _openLightbox(context, 0, widget.imagePath, displayName),
                      child: Stack(fit: StackFit.expand, children: [
                        Image.file(File(widget.imagePath), fit: BoxFit.cover),
                        Positioned(bottom: 10, left: 10, child: _ImageLabel(text: 'Your photo')),
                        const Positioned(top: 10, right: 10, child: _ExpandHint()),
                      ]),
                    )),
                    Container(width: 2, color: T.bg),
                    Expanded(child: GestureDetector(
                      onTap: () => _openLightbox(context, 1, widget.imagePath, displayName),
                      child: Stack(fit: StackFit.expand, children: [
                        _ExampleImage(sqlName: _activeSqlName),
                        Positioned(bottom: 10, right: 10,
                            child: _ImageLabel(text: displayName, alignRight: true)),
                        const Positioned(top: 10, left: 10, child: _ExpandHint()),
                      ]),
                    )),
                  ]),
                ),
                Positioned(bottom: 0, left: 0, right: 0,
                  child: Container(height: 100,
                    decoration: BoxDecoration(gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.transparent, T.bg])))),
                Positioned(top: 12, left: 8,
                  child: SafeArea(child: Container(
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    // Back from result = skipped
                    child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                        onPressed: () { _logSkipped(); widget.onReset(); })))),
              ]),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              sliver: SliverList(delegate: SliverChildListDelegate([
                _Chip(text: chipLabel, color: chipColor),
                const SizedBox(height: 10),
                Text(_headline(displayName), style: T.theme.textTheme.displayMedium),
                const SizedBox(height: 8),
                Text(summary, style: T.theme.textTheme.bodyMedium),
                const SizedBox(height: 16),
                if (!isCorrection && ref.watch(showConfidenceProvider)) _ConfidenceRow(
                  joint: widget.result.joint, yolo: widget.result.yoloConf, clf: widget.result.clfConf),
                if (!isCorrection && ref.watch(showConfidenceProvider)) const SizedBox(height: 20),
                _GlassCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.help_outline_rounded, size: 18, color: T.textSec),
                    const SizedBox(width: 8),
                    Text('Is this correct?', style: T.theme.textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 4),
                  Text('Confirm the identification or get a follow-up question to refine the result.',
                      style: T.theme.textTheme.bodySmall),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _PrimaryBtn(
                      icon:  Icons.check_rounded,
                      label: 'Yes, show details',
                      onTap: () {
                        // Log correct then show details
                        _logCorrect();
                        setState(() => _showDetails = true);
                      },
                    )),
                    const SizedBox(width: 10),
                    Expanded(child: _SecondaryBtn(
                        icon: Icons.close_rounded, label: 'Not quite', onTap: _handleNo)),
                  ]),
                  const SizedBox(height: 10),
                  // Retake from confirmation card = skipped
                  _GhostBtn(icon: Icons.camera_alt_rounded, label: 'Retake Image',
                      onTap: () { _logSkipped(); widget.onReset(); }),
                ])),
              ])),
            ),
          ]),
        );
      },
    );
  }
}

// ─── Example Reference Image ──────────────────────────────────────────────────

class _ExampleImage extends StatelessWidget {
  final String sqlName;
  final BoxFit fit;
  const _ExampleImage({required this.sqlName, this.fit = BoxFit.cover});

  static const _extensions = ['jpg', 'JPG', 'jpeg', 'png', 'webp'];
  List<String> get _candidates => _extensions.map((ext) => 'assets/examples/$sqlName.$ext').toList();

  @override
  Widget build(BuildContext context) => _tryAsset(_candidates, 0);

  Widget _tryAsset(List<String> paths, int i) {
    if (i >= paths.length) {
      return Container(color: T.surface, alignment: Alignment.center,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.image_not_supported_rounded, color: T.textSec, size: 32),
          const SizedBox(height: 8),
          Text('No reference\nimage', textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(fontSize: 11, color: T.textTer)),
        ]));
    }
    return Image.asset(paths[i], fit: fit,
      width:  fit == BoxFit.cover ? double.infinity : null,
      height: fit == BoxFit.cover ? double.infinity : null,
      errorBuilder: (_, __, ___) => _tryAsset(paths, i + 1));
  }
}

class _ImageLabel extends StatelessWidget {
  final String text;
  final bool   alignRight;
  const _ImageLabel({required this.text, this.alignRight = false});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: Colors.black.withAlpha(160), borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withAlpha(30))),
        child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: GoogleFonts.dmSans(fontSize: 11, fontWeight: FontWeight.w600,
                color: Colors.white, letterSpacing: 0.1)));
}

class _ExpandHint extends StatelessWidget {
  const _ExpandHint();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(color: Colors.black.withAlpha(140), borderRadius: BorderRadius.circular(8)),
        child: const Icon(Icons.open_in_full_rounded, size: 14, color: Colors.white));
}

// ─── Lightbox ─────────────────────────────────────────────────────────────────

class _Lightbox extends StatefulWidget {
  final int    initialIndex;
  final String imagePath, sqlName, speciesName;
  const _Lightbox({required this.initialIndex, required this.imagePath,
    required this.sqlName, required this.speciesName});

  @override
  State<_Lightbox> createState() => _LightboxState();
}

class _LightboxState extends State<_Lightbox> {
  late final PageController _page;
  late int _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialIndex;
    _page    = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() { _page.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final labels = ['Your photo', widget.speciesName];
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        PageView(
          controller: _page,
          onPageChanged: (i) => setState(() => _current = i),
          children: [
            InteractiveViewer(minScale: 0.8, maxScale: 4.0,
              child: SizedBox.expand(child: Image.file(File(widget.imagePath), fit: BoxFit.contain))),
            InteractiveViewer(minScale: 0.8, maxScale: 4.0,
              child: SizedBox.expand(child: _ExampleImage(sqlName: widget.sqlName, fit: BoxFit.contain))),
          ],
        ),
        Positioned(top: 0, left: 0, right: 0,
          child: SafeArea(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(10)),
                  child: const Icon(Icons.close_rounded, color: Colors.white, size: 20))),
              const Spacer(),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Container(
                  key: ValueKey(_current),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)),
                  child: Text(labels[_current], style: GoogleFonts.dmSans(
                      fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)))),
              const Spacer(),
              const SizedBox(width: 36),
            ]),
          ))),
        Positioned(bottom: 40, left: 0, right: 0,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _LightboxDot(active: _current == 0, label: 'Photo'),
            const SizedBox(width: 12),
            _LightboxDot(active: _current == 1, label: 'Reference'),
          ])),
        if (_current == widget.initialIndex)
          Positioned(bottom: 80, left: 0, right: 0,
            child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.swipe_rounded, size: 16, color: Colors.white54),
              const SizedBox(width: 6),
              Text('Swipe to compare', style: GoogleFonts.dmSans(fontSize: 12, color: Colors.white54)),
            ]))),
      ]),
    );
  }
}

class _LightboxDot extends StatelessWidget {
  final bool   active;
  final String label;
  const _LightboxDot({required this.active, required this.label});

  @override
  Widget build(BuildContext context) => Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: active ? 24 : 8, height: 8,
          decoration: BoxDecoration(color: active ? T.accent : Colors.white30,
              borderRadius: BorderRadius.circular(999))),
        const SizedBox(height: 5),
        Text(label, style: GoogleFonts.dmSans(fontSize: 10,
            color: active ? T.accent : Colors.white30,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400)),
      ]);
}

// ─── Confidence Stats Row ─────────────────────────────────────────────────────

class _ConfidenceRow extends StatelessWidget {
  final double joint, yolo, clf;
  const _ConfidenceRow({required this.joint, required this.yolo, required this.clf});

  static Color _confColor(double v) {
    if (v >= 0.7) return T.accent;
    if (v >= 0.4) return T.warn;
    return T.danger;
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: T.border)),
        child: Row(children: [
          _StatCell(label: 'Confidence', value: '${(joint * 100).round()}%', color: _confColor(joint)),
          _StatDivider(),
          _StatCell(label: 'Detection',  value: '${(yolo  * 100).round()}%', color: T.textSec),
          _StatDivider(),
          _StatCell(label: 'Classifier', value: clf > 0 ? '${(clf * 100).round()}%' : '—', color: T.textSec),
        ]),
      );
}

class _StatCell extends StatelessWidget {
  final String label, value;
  final Color  color;
  const _StatCell({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(child: Column(children: [
        Text(value, style: GoogleFonts.dmSans(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 2),
        Text(label, style: T.theme.textTheme.bodySmall),
      ]));
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(width: 1, height: 32, color: T.border,
      margin: const EdgeInsets.symmetric(horizontal: 4));
}

// ─── HITL Question Page ───────────────────────────────────────────────────────

class _HitlQuestionPage extends StatelessWidget {
  final String imagePath, bucketName, question;
  final List<HitlOption>         options;
  final ValueChanged<HitlOption> onSelect;
  final VoidCallback onBack, onRetake;

  const _HitlQuestionPage({required this.imagePath, required this.bucketName,
    required this.question, required this.options, required this.onSelect,
    required this.onBack, required this.onRetake});

  static String _prettyBucket(String raw) => raw.replaceAll('_', ' ').split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  @override
  Widget build(BuildContext context) => CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Stack(children: [
          SizedBox(width: double.infinity, height: 380,
              child: Image.file(File(imagePath), fit: BoxFit.cover)),
          Positioned(bottom: 0, left: 0, right: 0,
            child: Container(height: 140, decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, T.bg])))),
          Positioned(bottom: 20, left: 20, child: _Chip(text: _prettyBucket(bucketName), color: T.teal)),
          Positioned(top: 12, left: 8, child: SafeArea(child: Container(
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: onBack)))),
        ])),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Which looks closest to your pest?', style: T.theme.textTheme.displayMedium),
            const SizedBox(height: 6),
            Text(question.isEmpty
                ? 'Tap the image and description that best matches what you uploaded.' : question,
                style: T.theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            _Divider(),
          ])),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          sliver: SliverList.separated(
            itemCount: options.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) =>
                _HitlOptionCard(option: options[i], onTap: () => onSelect(options[i])),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
          sliver: SliverToBoxAdapter(
            child: _GhostBtn(icon: Icons.camera_alt_rounded, label: 'Retake Image', onTap: onRetake)),
        ),
      ]);
}

class _HitlAssetImage extends StatelessWidget {
  final HitlOption option;
  final double width, height, borderRadius;
  const _HitlAssetImage({required this.option, this.width = double.infinity,
    this.height = 180, this.borderRadius = 14});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox(width: width, height: height,
            child: _buildCandidate(option.candidateAssetPaths, 0)));

  Widget _buildCandidate(List<String> paths, int index) {
    if (index >= paths.length) {
      return Container(color: T.surface, alignment: Alignment.center,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.image_not_supported_rounded, color: T.textSec, size: 36),
          const SizedBox(height: 8),
          Text('No preview', style: GoogleFonts.dmSans(fontSize: 12, color: T.textTer)),
        ]));
    }
    return Image.asset(paths[index], fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _buildCandidate(paths, index + 1));
  }
}

class _HitlOptionCard extends StatelessWidget {
  final HitlOption   option;
  final VoidCallback onTap;
  const _HitlOptionCard({required this.option, required this.onTap});

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap, borderRadius: BorderRadius.circular(20),
          child: Container(
            decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(20),
                border: Border.all(color: T.borderBright)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                child: Stack(children: [
                  _HitlAssetImage(option: option, width: double.infinity, height: 180, borderRadius: 0),
                  Positioned(bottom: 0, left: 0, right: 0,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(14, 32, 14, 12),
                      decoration: BoxDecoration(gradient: LinearGradient(
                        begin: Alignment.topCenter, end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black.withAlpha(190)])),
                      child: Text(option.displayName, style: GoogleFonts.dmSans(
                          fontSize: 18, fontWeight: FontWeight.w700,
                          color: Colors.white, letterSpacing: -0.3)))),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(option.optionText, style: T.theme.textTheme.bodyMedium?.copyWith(
                      color: T.textPri, height: 1.5)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 14),
                    decoration: BoxDecoration(color: T.accent.withAlpha(18),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: T.accent.withAlpha(60))),
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      const Icon(Icons.check_circle_outline_rounded, size: 16, color: T.accent),
                      const SizedBox(width: 7),
                      Text('This matches my pest', style: GoogleFonts.dmSans(
                          fontSize: 13, fontWeight: FontWeight.w700,
                          color: T.accent, letterSpacing: 0.1)),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      );
}

// ─── Unknown Result Page ──────────────────────────────────────────────────────

class _UnknownResultPage extends StatelessWidget {
  final String     imagePath;
  final VoidCallback onReset;
  const _UnknownResultPage({required this.imagePath, required this.onReset});

  @override
  Widget build(BuildContext context) => CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Stack(children: [
          SizedBox(width: double.infinity, height: 300,
              child: Image.file(File(imagePath), fit: BoxFit.cover)),
          Positioned(bottom: 0, left: 0, right: 0,
            child: Container(height: 100, decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, T.bg])))),
          Positioned(top: 12, left: 8, child: SafeArea(child: Container(
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: onReset)))),
        ])),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          sliver: SliverToBoxAdapter(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Chip(text: 'No Detection', color: T.warn),
            const SizedBox(height: 10),
            Text('Couldn\'t identify this pest', style: T.theme.textTheme.displayMedium),
            const SizedBox(height: 8),
            Text('Try retaking the image with better lighting and a closer, clearer view of the insect.',
                style: T.theme.textTheme.bodyMedium),
            const SizedBox(height: 24),
            _PrimaryBtn(icon: Icons.camera_alt_rounded, label: 'Try Another Image', onTap: onReset),
          ])),
        ),
      ]);
}

// ─── Pest Details Page ────────────────────────────────────────────────────────

class PestDetailsPage extends StatefulWidget {
  final String     imagePath;
  final PestInfo   pest;
  final List<CropNote> crops;
  final VoidCallback onBack, onReset;
  const PestDetailsPage({super.key, required this.imagePath, required this.pest,
    required this.crops, required this.onBack, required this.onReset});

  @override
  State<PestDetailsPage> createState() => _PestDetailsPageState();
}

class _PestDetailsPageState extends State<PestDetailsPage> with SingleTickerProviderStateMixin {
  late TabController _tab;

  @override
  void initState() {
    super.initState();
    final count = 2 + (widget.crops.isNotEmpty ? 1 : 0);
    _tab = TabController(length: count, vsync: this);
    _tab.addListener(() => setState(() {}));
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  static String _prettyBucket(String raw) => raw.replaceAll('_', ' ').split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');

  @override
  Widget build(BuildContext context) {
    final pest  = widget.pest;
    final crops = widget.crops;

    return Scaffold(
      backgroundColor: T.bg,
      body: Column(children: [
        Stack(children: [
          SizedBox(width: double.infinity, height: 260,
              child: Image.file(File(widget.imagePath), fit: BoxFit.cover)),
          Positioned(bottom: 0, left: 0, right: 0,
            child: Container(height: 130, decoration: BoxDecoration(gradient: LinearGradient(
              begin: Alignment.topCenter, end: Alignment.bottomCenter,
              colors: [Colors.transparent, T.bg])))),
          Positioned(top: 12, left: 8, child: SafeArea(child: Container(
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
            child: IconButton(icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                onPressed: widget.onBack)))),
          Positioned(bottom: 0, left: 20, right: 20,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 6, children: [
                _Chip(text: _prettyBucket(pest.bucketName), color: T.accent),
                if (crops.isNotEmpty)
                  _Chip(text: '${crops.length} crop${crops.length == 1 ? '' : 's'}', color: T.teal),
              ]),
              const SizedBox(height: 8),
              Text(pest.displayName, style: T.theme.textTheme.displayLarge?.copyWith(fontSize: 26)),
              const SizedBox(height: 4),
            ])),
        ]),
        if (pest.briefSummary.isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Text(pest.briefSummary, style: T.theme.textTheme.bodyMedium)),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Container(
            decoration: BoxDecoration(color: T.surface, borderRadius: BorderRadius.circular(14),
                border: Border.all(color: T.border)),
            padding: const EdgeInsets.all(4),
            child: TabBar(
              controller: _tab,
              indicatorSize: TabBarIndicatorSize.tab,
              labelColor: T.bg, unselectedLabelColor: T.textSec,
              indicator: BoxDecoration(color: T.accent, borderRadius: BorderRadius.circular(11)),
              labelPadding: EdgeInsets.zero, dividerColor: Colors.transparent,
              labelStyle: GoogleFonts.dmSans(fontSize: 13, fontWeight: FontWeight.w600),
              unselectedLabelStyle: GoogleFonts.dmSans(fontSize: 13, fontWeight: FontWeight.w500),
              tabs: [
                _DetailTab(icon: Icons.search_rounded, label: 'Identify'),
                _DetailTab(icon: Icons.eco_rounded,    label: 'Manage'),
                if (crops.isNotEmpty) _DetailTab(icon: Icons.grass_rounded, label: 'Crops'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: TabBarView(controller: _tab, children: [
          _DetailTextSection(icon: Icons.search_rounded, title: 'How to recognise it', text: pest.identification),
          _DetailTextSection(icon: Icons.eco_rounded,    title: 'What to do',          text: pest.managementTips),
          if (crops.isNotEmpty) _CropNotesPanel(crops: crops),
        ])),
        Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          child: _PrimaryBtn(icon: Icons.camera_alt_rounded, label: 'Scan Another Pest',
              onTap: widget.onReset)),
      ]),
    );
  }
}

class _DetailTab extends StatelessWidget {
  final IconData icon;
  final String   label;
  const _DetailTab({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Tab(height: 44,
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 15), const SizedBox(width: 5), Text(label)]));
}

class _DetailTabItem {
  final String label; final IconData icon; final Widget child;
  const _DetailTabItem({required this.label, required this.icon, required this.child});
}
class _DetailHeroCard extends StatelessWidget {
  final PestInfo pest; final List<CropNote> crops;
  const _DetailHeroCard({required this.pest, required this.crops});
  @override Widget build(BuildContext context) => const SizedBox.shrink();
  static String _prettyBucket(String raw) => raw.replaceAll('_', ' ').split(' ')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}
class _SegmentedTabCard extends StatelessWidget {
  final List<_DetailTabItem> tabs;
  const _SegmentedTabCard({required this.tabs});
  @override Widget build(BuildContext context) => const SizedBox.shrink();
}

class _DetailTextSection extends StatelessWidget {
  final IconData? icon;
  final String    title, text;
  const _DetailTextSection({required this.title, required this.text, this.icon});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        children: [
          Row(children: [
            if (icon != null) ...[
              Container(padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: T.accent.withAlpha(18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: T.accent.withAlpha(50))),
                child: Icon(icon, size: 15, color: T.accent)),
              const SizedBox(width: 10),
            ],
            Text(title, style: T.theme.textTheme.titleMedium),
          ]),
          const SizedBox(height: 14),
          if (text.trim().isEmpty) _EmptyState(message: 'No information available yet.')
          else ..._buildBullets(text),
        ],
      );

  static List<Widget> _buildBullets(String text) {
    final cleaned = text.replaceAll('\n', ' ').replaceAll(RegExp(r'\s*[-•]\s+'), ' ').trim();
    final sentences = cleaned
        .splitMapJoin(RegExp(r'(?<=[.!?])\s+(?=[A-Z])'), onMatch: (_) => '\n', onNonMatch: (s) => s)
        .split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    final widgets = <Widget>[];
    for (int i = 0; i < sentences.length; i++) {
      widgets.add(_BulletRow(text: sentences[i]));
      if (i < sentences.length - 1) widgets.add(const SizedBox(height: 8));
    }
    return widgets;
  }
}

class _BulletRow extends StatelessWidget {
  final String text;
  const _BulletRow({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: T.border)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 6, height: 6, margin: const EdgeInsets.only(top: 6, right: 10),
              decoration: const BoxDecoration(shape: BoxShape.circle, color: T.accent)),
          Expanded(child: Text(text, style: T.theme.textTheme.bodyMedium?.copyWith(
              color: T.textPri, height: 1.55))),
        ]));
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: T.border)),
        child: Column(children: [
          Icon(Icons.info_outline_rounded, color: T.textTer, size: 28),
          const SizedBox(height: 8),
          Text(message, style: T.theme.textTheme.bodySmall, textAlign: TextAlign.center),
        ]));
}

class _CropNotesPanel extends StatelessWidget {
  final List<CropNote> crops;
  const _CropNotesPanel({required this.crops});

  @override
  Widget build(BuildContext context) => ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        itemCount: crops.length + 1,
        separatorBuilder: (_, i) => i == 0 ? const SizedBox(height: 14) : const SizedBox(height: 10),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Row(children: [
              Container(padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(color: T.teal.withAlpha(18),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: T.teal.withAlpha(50))),
                child: const Icon(Icons.grass_rounded, size: 15, color: T.teal)),
              const SizedBox(width: 10),
              Text('Crop-specific notes', style: T.theme.textTheme.titleMedium),
            ]);
          }
          final crop = crops[i - 1];
          return Container(
            decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(16),
                border: Border.all(color: T.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(color: T.teal.withAlpha(14),
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                    border: Border(bottom: BorderSide(color: T.border))),
                child: Row(children: [
                  const Icon(Icons.grass_rounded, size: 14, color: T.teal),
                  const SizedBox(width: 8),
                  Text(crop.displayName, style: T.theme.textTheme.titleSmall?.copyWith(
                      color: T.teal, fontWeight: FontWeight.w700)),
                ])),
              Padding(padding: const EdgeInsets.all(14),
                  child: Text(crop.note, style: T.theme.textTheme.bodyMedium?.copyWith(
                      color: T.textPri, height: 1.6))),
            ]),
          );
        },
      );
}

// ─── Camera Page ──────────────────────────────────────────────────────────────

class CameraCapturePage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraCapturePage({super.key, required this.cameras});

  @override
  State<CameraCapturePage> createState() => _CameraState();
}

class _CameraState extends State<CameraCapturePage> {
  late CameraController _ctrl;
  bool _ready = false, _busy = false;

  @override
  void initState() {
    super.initState();
    _ctrl = CameraController(widget.cameras.first, ResolutionPreset.high, enableAudio: false);
    _ctrl.initialize().then((_) { if (mounted) setState(() => _ready = true); });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _shoot() async {
    if (_busy || !_ctrl.value.isInitialized) return;
    setState(() => _busy = true);
    try {
      final f = await _ctrl.takePicture();
      if (mounted) Navigator.pop(context, f.path);
    } catch (_) { setState(() => _busy = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: _ready
            ? Stack(children: [
                Positioned.fill(child: CameraPreview(_ctrl)),
                Positioned.fill(child: CustomPaint(painter: _FramePainter())),
                Positioned(bottom: 48, left: 0, right: 0,
                  child: Center(child: GestureDetector(
                    onTap: _shoot,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 78, height: 78,
                      decoration: BoxDecoration(shape: BoxShape.circle,
                          border: Border.all(color: Colors.white.withAlpha(180), width: 3)),
                      child: Padding(padding: const EdgeInsets.all(5),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          decoration: BoxDecoration(shape: BoxShape.circle,
                              color: _busy ? T.accentMid : Colors.white),
                          child: _busy
                              ? const Center(child: SizedBox(width: 24, height: 24,
                                  child: CircularProgressIndicator(color: T.bg, strokeWidth: 2.5)))
                              : const SizedBox.shrink())),
                  )))),
                Positioned(top: 12, left: 8, child: SafeArea(child: Container(
                  margin: const EdgeInsets.all(4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                  child: IconButton(icon: const Icon(Icons.close_rounded, color: Colors.white, size: 24),
                      onPressed: () => Navigator.pop(context))))),
              ])
            : const Center(child: CircularProgressIndicator(color: T.accent)),
      );
}

// ─── Settings Page ────────────────────────────────────────────────────────────

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsState();
}

class _SettingsState extends ConsumerState<SettingsPage> {
  double _ft = 0.6, _lc = 0.4;
  bool   _rescue = true, _pts = true;
  String _mode   = 'hybrid';

  @override
  Widget build(BuildContext context) {
    final showConf = ref.watch(showConfidenceProvider);
    return Scaffold(
      backgroundColor: T.bg,
      appBar: AppBar(
        backgroundColor: T.surface, elevation: 0, surfaceTintColor: Colors.transparent,
        title: Text('Settings', style: T.theme.textTheme.titleLarge),
        iconTheme: const IconThemeData(color: T.textSec),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: T.border)),
      ),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        _Section('Display', [
          _Switch('Show Confidence Scores',
            'Displays detection & classifier scores on the result screen. Useful for demos and debugging.',
            showConf, (v) => ref.read(showConfidenceProvider.notifier).state = v),
        ]),
        const SizedBox(height: 24),
        _Section('Detection', [
          _Slider('Fusion Threshold', _ft, 0.3, 0.9,
              'Below this: fusion over top-K instead of TOP1.', (v) => setState(() => _ft = v)),
          _Slider('Low-Conf Floor', _lc, 0.1, 0.7,
              'Detections below this are rescued or discarded.', (v) => setState(() => _lc = v)),
        ]),
        const SizedBox(height: 24),
        _Section('SAM Mode', [
          _Switch('Use Point Prompts', 'Adds centre + corner points for better masks.',
              _pts, (v) => setState(() => _pts = v)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
            child: SegmentedButton<String>(
              style: SegmentedButton.styleFrom(
                backgroundColor: T.surface, selectedBackgroundColor: T.accent,
                selectedForegroundColor: T.bg, foregroundColor: T.textSec,
                side: const BorderSide(color: T.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              segments: const [
                ButtonSegment(value: 'box',    label: Text('Box')),
                ButtonSegment(value: 'mask',   label: Text('Mask')),
                ButtonSegment(value: 'hybrid', label: Text('Hybrid')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
        ]),
        const SizedBox(height: 24),
        _Section('Rescue', [
          _Switch('Low-Conf Rescue', 'Run classifier on weak detections before discarding.',
              _rescue, (v) => setState(() => _rescue = v)),
        ]),
        const SizedBox(height: 32),
        _PrimaryBtn(icon: Icons.check_rounded, label: 'Save Settings',
            onTap: () => Navigator.pop(context)),
        const SizedBox(height: 24),

        // ── Legal / Privacy ───────────────────────────────────────────
        _Section('Legal', [
          ListTile(
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const _TosViewPage())),
            leading: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: T.accent.withAlpha(18),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: T.accent.withAlpha(50)),
              ),
              child: const Icon(Icons.privacy_tip_rounded, size: 16, color: T.accent),
            ),
            title: Text('Privacy & Data', style: T.theme.textTheme.titleMedium),
            subtitle: Text('View consent and data usage policy',
                style: T.theme.textTheme.bodySmall),
            trailing: const Icon(Icons.chevron_right_rounded, color: T.textTer),
          ),
        ]),
        const SizedBox(height: 24),
      ]),
    );
  }
}

// ─── TOS View Page (read-only, accessible from Settings) ─────────────────────

class _TosViewPage extends StatelessWidget {
  const _TosViewPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      appBar: AppBar(
        backgroundColor: T.surface,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        title: Text('Privacy & Data', style: T.theme.textTheme.titleLarge),
        iconTheme: const IconThemeData(color: T.textSec),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: T.border),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── Header card ───────────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: T.card,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: T.borderBright),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Container(
                      padding: const EdgeInsets.all(7),
                      decoration: BoxDecoration(
                        color: T.accent.withAlpha(18),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: T.accent.withAlpha(50)),
                      ),
                      child: const Icon(Icons.privacy_tip_rounded, size: 16, color: T.accent),
                    ),
                    const SizedBox(width: 12),
                    Text('Privacy & Data', style: T.theme.textTheme.titleLarge),
                  ]),
                  const SizedBox(height: 14),
                  Text(
                    'Insectopedia uses on-device AI to identify agricultural pests from '
                    'photos you take or upload. No image ever leaves your phone without '
                    'your explicit permission.',
                    style: T.theme.textTheme.bodyMedium,
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Image storage section ─────────────────────────────────
            _TosSection(
              icon: Icons.photo_library_rounded,
              iconColor: T.accent,
              title: 'Image Storage',
              body: 'If you opted in during setup, images you scan may be '
                  'securely stored to help improve Insectopedia\'s pest detection '
                  'accuracy. Images are used only for model training and are '
                  'never shared with or sold to third parties.',
            ),

            const SizedBox(height: 12),

            // ── Metadata logging section ──────────────────────────────
            _TosSection(
              icon: Icons.analytics_rounded,
              iconColor: T.teal,
              title: 'Anonymous Scan Metadata',
              body: 'Regardless of image consent, anonymous scan metadata is '
                  'logged locally on your device. This includes species predictions, '
                  'confidence scores, pipeline decision types, and inference timing. '
                  'This data helps us understand real-world model performance. '
                  'It is stored locally and will only be transmitted to our servers '
                  'when an internet connection is available and you have agreed to sync.',
            ),

            const SizedBox(height: 12),

            // ── On-device processing ──────────────────────────────────
            _TosSection(
              icon: Icons.lock_rounded,
              iconColor: T.info,
              title: 'On-Device Processing',
              body: 'All pest identification runs entirely on your device using '
                  'local AI models. No image or camera feed is sent to any server '
                  'during analysis. The app works fully without an internet connection.',
            ),

            const SizedBox(height: 12),

            // ── Data sources ──────────────────────────────────────────
            _TosSection(
              icon: Icons.agriculture_rounded,
              iconColor: T.warn,
              title: 'Data Sources',
              body: 'Pest identification guidance, management tips, and crop-specific '
                  'notes are sourced from OMAFRA CropIPM (Ontario Ministry of '
                  'Agriculture, Food & Rural Affairs). Reference example images are '
                  'sourced from iNaturalist and the IP102 benchmark dataset '
                  '(Wu et al., CVPR 2019).',
            ),

            const SizedBox(height: 28),

            // ── Footer ────────────────────────────────────────────────
            Center(
              child: Text(
                'Insectopedia v1.0 · University of Windsor',
                style: T.theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _TosSection extends StatelessWidget {
  final IconData icon;
  final Color    iconColor;
  final String   title, body;
  const _TosSection({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: T.card,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: T.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: iconColor.withAlpha(18),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: iconColor.withAlpha(50)),
                ),
                child: Icon(icon, size: 14, color: iconColor),
              ),
              const SizedBox(width: 10),
              Text(title, style: T.theme.textTheme.titleMedium),
            ]),
            const SizedBox(height: 12),
            Text(body, style: T.theme.textTheme.bodyMedium),
          ],
        ),
      );
}

// ─── Shared UI Components ─────────────────────────────────────────────────────

class _GlassCard extends StatelessWidget {
  final Widget child;
  const _GlassCard({required this.child});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(20),
            border: Border.all(color: T.borderBright)),
        child: child);
}

class _Chip extends StatelessWidget {
  final String text; final Color color;
  const _Chip({required this.text, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: color.withAlpha(22), borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withAlpha(80))),
        child: Text(text, style: GoogleFonts.dmSans(fontSize: 11, fontWeight: FontWeight.w700,
            color: color, letterSpacing: 0.3)));
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Container(height: 1, color: T.border));
}

class _PrimaryBtn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap;
  const _PrimaryBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: T.accent, foregroundColor: T.bg,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0, shadowColor: Colors.transparent,
          textStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w700),
        ).copyWith(overlayColor: WidgetStateProperty.all(Colors.black12)),
        icon: Icon(icon, size: 18), label: Text(label),
        onPressed: () { HapticFeedback.lightImpact(); onTap(); });
}

class _SecondaryBtn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap;
  const _SecondaryBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: T.textPri, side: const BorderSide(color: T.borderBright, width: 1.5),
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.dmSans(fontSize: 14, fontWeight: FontWeight.w600)),
        icon: Icon(icon, size: 18), label: Text(label), onPressed: onTap);
}

class _GhostBtn extends StatelessWidget {
  final IconData icon; final String label; final VoidCallback onTap;
  const _GhostBtn({required this.icon, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) => TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: T.textSec, padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.dmSans(fontSize: 13, fontWeight: FontWeight.w500)),
        onPressed: onTap, icon: Icon(icon, size: 16), label: Text(label));
}

class _Section extends StatelessWidget {
  final String title; final List<Widget> children;
  const _Section(this.title, this.children);
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(bottom: 10, left: 2),
          child: Text(title.toUpperCase(), style: GoogleFonts.dmSans(fontSize: 10,
              letterSpacing: 1.4, color: T.accentMid, fontWeight: FontWeight.w700))),
        Container(decoration: BoxDecoration(color: T.card, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: T.border)),
          child: Column(children: children)),
      ]);
}

class _Slider extends StatelessWidget {
  final String label, hint; final double value, min, max;
  final ValueChanged<double> onChanged;
  const _Slider(this.label, this.value, this.min, this.max, this.hint, this.onChanged);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: T.theme.textTheme.titleMedium),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: T.accent.withAlpha(20), borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: T.accent.withAlpha(50))),
              child: Text(value.toStringAsFixed(2),
                  style: GoogleFonts.outfit(fontSize: 13, fontWeight: FontWeight.w600, color: T.accent))),
          ]),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(activeTrackColor: T.accent,
                inactiveTrackColor: T.border, thumbColor: T.accent,
                overlayColor: T.accent.withAlpha(30), trackHeight: 3),
            child: Slider(value: value, min: min, max: max,
                divisions: ((max - min) * 20).round(), onChanged: onChanged)),
          Text(hint, style: T.theme.textTheme.bodySmall),
          const SizedBox(height: 8),
        ]));
}

class _Switch extends StatelessWidget {
  final String label, subtitle; final bool value;
  final ValueChanged<bool> onChanged;
  const _Switch(this.label, this.subtitle, this.value, this.onChanged);
  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: Text(label, style: T.theme.textTheme.titleMedium),
        subtitle: Text(subtitle, style: T.theme.textTheme.bodySmall),
        value: value, onChanged: onChanged, activeColor: T.accent,
        activeTrackColor: T.accent.withAlpha(50), inactiveTrackColor: T.border);
}

// ─── Custom Painters ──────────────────────────────────────────────────────────

class _RingPainter extends CustomPainter {
  final double pulse;
  const _RingPainter({this.pulse = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final r  = math.min(cx, cy) - 8;
    canvas.drawCircle(Offset(cx, cy), r,
        Paint()..color = T.accentDim.withAlpha((40 + 40 * pulse).toInt())
          ..style = PaintingStyle.stroke..strokeWidth = 1);
    canvas.drawCircle(Offset(cx, cy), r * 0.65,
        Paint()..color = T.border..style = PaintingStyle.stroke..strokeWidth = 1);
    final innerR = r * (0.35 + 0.04 * pulse);
    canvas.drawCircle(Offset(cx, cy), innerR,
        Paint()..color = T.accent.withAlpha((18 + 20 * pulse).toInt())..style = PaintingStyle.fill);
    canvas.drawCircle(Offset(cx, cy), 5 + pulse * 1.5,
        Paint()..color = T.accent..maskFilter = MaskFilter.blur(BlurStyle.normal, pulse * 4));
    canvas.drawCircle(Offset(cx, cy), 4, Paint()..color = T.accent);
    final tk = Paint()..color = T.accent..style = PaintingStyle.stroke
      ..strokeWidth = 2..strokeCap = StrokeCap.round;
    const o = 22.0;
    for (final (fx, fy) in [(cx - r, cy - r), (cx + r, cy - r), (cx + r, cy + r), (cx - r, cy + r)]) {
      final sx = fx < cx ? 1 : -1, sy = fy < cy ? 1 : -1;
      canvas.drawLine(Offset(fx, fy + sy * o), Offset(fx, fy), tk);
      canvas.drawLine(Offset(fx, fy), Offset(fx + sx * o, fy), tk);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.pulse != pulse;
}

class _FramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = T.accent..style = PaintingStyle.stroke
      ..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    const m = 56.0, cl = 26.0;
    final l = m, r = size.width - m, t = size.height * 0.15, b = size.height * 0.85;
    canvas
      ..drawLine(Offset(l, t + cl), Offset(l, t), p)..drawLine(Offset(l, t), Offset(l + cl, t), p)
      ..drawLine(Offset(r - cl, t), Offset(r, t), p)..drawLine(Offset(r, t), Offset(r, t + cl), p)
      ..drawLine(Offset(r, b - cl), Offset(r, b), p)..drawLine(Offset(r, b), Offset(r - cl, b), p)
      ..drawLine(Offset(l + cl, b), Offset(l, b), p)..drawLine(Offset(l, b), Offset(l, b - cl), p);
  }

  @override
  bool shouldRepaint(_) => false;
}