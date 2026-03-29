// ============================================================
// Insectopedia Pipeline Engine — On-Device Inference (Flutter/ONNX)
// ============================================================

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

// ---------------------------------------------------------------------------
// Progress reporting
// ---------------------------------------------------------------------------

class PipelineProgress {
  /// 0.0–1.0
  final double fraction;
  /// Human-readable label shown in the UI
  final String label;
  const PipelineProgress(this.fraction, this.label);
}

typedef ProgressCallback = void Function(PipelineProgress progress);

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const Map<String, String> kCoarseToGroup = {
  'tiny_pests':     'tiny_pests',
  'flea_beetle':    'flea_beetle',
  'caterpillars':   'caterpillars',
  'plant_bugs':     'plant_bugs',
  'soil_larvae':    'soil_larvae',
  'weevils':        'weevils',
  'stink_bugs':     'stink_bugs',
  'blister_beetle': 'blister_beetle',
  'potato_beetle':  'potato_beetle',
};

const Map<String, String> kYoloOnlyBuckets = {};

const List<String> kYoloBucketNames = [
  'tiny_pests', 'flea_beetle', 'caterpillars', 'plant_bugs',
  'soil_larvae', 'weevils', 'stink_bugs', 'blister_beetle', 'potato_beetle',
];

const Map<String, List<String>> kClassifierLabels = {
  'tiny_pests':     ['aphids', 'spider_mite', 'thrips'],
  'flea_beetle':    ['grape_flea_beetle', 'striped_flea_beetle'],
  'caterpillars':   ['army_worm', 'black_cutworm', 'corn_borer', 'peach_borer'],
  'plant_bugs':     ['four_lined_plant_bug', 'tarnished_plant_bug'],
  'soil_larvae':    ['grub', 'wireworm'],
  'weevils':        ['alfalfa_weevil', 'strawberry_root_weevil'],
  'stink_bugs':     ['brown_marmorated_stink_bug', 'green_stink_bug'],
  'blister_beetle': ['black_blister_beetle', 'striped_blister_beetle'],
  'potato_beetle':  ['colorado_potato_beetle', 'striped_cucumber_beetle'],
};

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

class PipelineConfig {
  final int imgsz, retryImgsz, fusionTopk, lowConfRescueTopk;
  final int tilePerTileTopk, tileTopk, maskMinArea, clfPrescale;
  final double pad, bgAlpha, yoloLowConf, yoloFusionThresh;
  final double lowConfWeightClf, lowConfWeightYolo, lowConfAcceptThresh;
  final double? tinyPestLowConf;
  final double tileSizeMult, tileOverlap, tileConfThresh, tileJointThresh;
  final double minMaskFrac, maxMaskFrac;
  final bool lowConfRescue, usePoints;
  final Set<String> retryBuckets, forceTileBuckets;
  final Map<String, String> bucketModeOverrides;
  final String? overrideBucket;
  final String mode;

  const PipelineConfig({
    this.imgsz = 896, this.retryImgsz = 1280,
    this.retryBuckets = const {
      'caterpillars', 'flea_beetle', 'weevils', 'tiny_pests',
    },
    this.pad = 0.05, this.bgAlpha = 0.2,
    this.yoloLowConf = 0.4, this.yoloFusionThresh = 0.6,
    this.fusionTopk = 3, this.lowConfRescue = true,
    this.lowConfRescueTopk = 3, this.lowConfWeightClf = 0.7,
    this.lowConfWeightYolo = 0.3, this.lowConfAcceptThresh = 0.5,
    this.tinyPestLowConf = 0.2,
    this.tileSizeMult = 1.5, this.tileOverlap = 0.25,
    this.tileConfThresh = 0.50, this.tileJointThresh = 0.35,
    this.tilePerTileTopk = 3, this.tileTopk = 3,
    this.maskMinArea = 200, this.minMaskFrac = 0.005, this.maxMaskFrac = 0.85,
    this.clfPrescale = 224, this.usePoints = true,
    this.forceTileBuckets = const {},
    this.bucketModeOverrides = const {
      'blister_beetle': 'box',
      'caterpillars':   'mask',
      'tiny_pests':     'mask',
    },
    this.overrideBucket, this.mode = 'hybrid',
  });
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

class BoundingBox {
  final double x1, y1, x2, y2, conf;
  final int cls;
  const BoundingBox({required this.x1, required this.y1,
    required this.x2, required this.y2, required this.conf, required this.cls});
}

class CandidateResult {
  final String predBucket, group, predSpecies;
  final double yoloConf, clfConf, joint;
  const CandidateResult({required this.predBucket, required this.yoloConf,
    required this.group, required this.predSpecies,
    required this.clfConf, required this.joint});
}

class PipelineResult {
  final String predBucket, predSpecies, decisionMode;
  final double yoloConf, clfConf, joint;
  final List<BoundingBox> allBoxes;
  const PipelineResult({required this.predBucket, required this.yoloConf,
    required this.predSpecies, required this.clfConf, required this.joint,
    required this.decisionMode, required this.allBoxes});
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

Future<OrtSession> _sessionFromAsset(String path) async {
  final data = await rootBundle.load(path);
  final opts  = OrtSessionOptions();
  final s     = OrtSession.fromBuffer(data.buffer.asUint8List(), opts);
  opts.release();
  return s;
}

// ---------------------------------------------------------------------------
// YOLO26
// ---------------------------------------------------------------------------

class Yolo26Model {
  OrtSession? _session;

  Future<void> load() async {
    _session ??= await _sessionFromAsset('assets/models/yolo26.onnx');
  }

  Future<List<BoundingBox>> predict(img.Image image, int imgsz) async {
    final scale   = imgsz / math.max(image.width, image.height);
    final scaledW = (image.width  * scale).round();
    final scaledH = (image.height * scale).round();
    final padX    = (imgsz - scaledW) ~/ 2;
    final padY    = (imgsz - scaledH) ~/ 2;

    final scaled = img.copyResize(image, width: scaledW, height: scaledH,
        interpolation: img.Interpolation.linear);
    final letterboxed = img.Image(width: imgsz, height: imgsz);
    img.fill(letterboxed, color: img.ColorRgb8(114, 114, 114));
    img.compositeImage(letterboxed, scaled, dstX: padX, dstY: padY);

    final input   = _nchw(letterboxed, imgsz);
    final runOpts = OrtRunOptions();
    final t = OrtValueTensor.createTensorWithDataList(input, [1, 3, imgsz, imgsz]);
    final out = await _session!.runAsync(runOpts, {'images': t});
    t.release(); runOpts.release();

    final raw = (out![0] as OrtValueTensor).value as List;
    out.forEach((e) => e?.release());

    return _parse(raw, 1.0 / scale, 1.0 / scale,
        padX: padX.toDouble(), padY: padY.toDouble());
  }

  List<BoundingBox> _parse(List raw, double sx, double sy,
      {double padX = 0, double padY = 0}) {
    final dets = (raw[0] is List) ? raw[0] as List : raw;
    final boxes = <BoundingBox>[];
    for (final d in dets) {
      final row  = d as List;
      final conf = (row[4] as num).toDouble();
      if (conf < 0.25) continue;
      boxes.add(BoundingBox(
        x1: ((row[0] as num).toDouble() - padX) * sx,
        y1: ((row[1] as num).toDouble() - padY) * sy,
        x2: ((row[2] as num).toDouble() - padX) * sx,
        y2: ((row[3] as num).toDouble() - padY) * sy,
        conf: conf, cls: (row[5] as num).toInt(),
      ));
    }
    boxes.sort((a, b) => b.conf.compareTo(a.conf));
    return boxes;
  }

  Float32List _nchw(img.Image im, int sz) {
    final buf = Float32List(3 * sz * sz);
    for (int y = 0; y < sz; y++) for (int x = 0; x < sz; x++) {
      final p = im.getPixel(x, y); final i = y * sz + x;
      buf[i] = p.r / 255.0; buf[sz*sz+i] = p.g / 255.0; buf[2*sz*sz+i] = p.b / 255.0;
    }
    return buf;
  }

  void dispose() { _session?.release(); _session = null; }
}

// ---------------------------------------------------------------------------
// RepViT-SAM
// ---------------------------------------------------------------------------

class RepVitSamModel {
  OrtSession? _enc, _dec;
  List<List<List<List<double>>>>? _emb;
  int _embW = 0, _embH = 0;

  Future<void> load() async {
    if (_enc != null) return;
    _enc = await _sessionFromAsset('assets/models/repvit_sam_encoder.onnx');
    _dec = await _sessionFromAsset('assets/models/repvit_sam_decoder.onnx');
  }

  Future<void> encodeImage(img.Image image) async {
    _embW = image.width; _embH = image.height;
    const sz = 1024;
    final r = img.copyResize(image, width: sz, height: sz,
        interpolation: img.Interpolation.linear);
    final input = _ncwNorm(r, sz);
    final ro = OrtRunOptions();
    final t  = OrtValueTensor.createTensorWithDataList(input, [1, 3, sz, sz]);
    final out = await _enc!.runAsync(ro, {'input': t});
    t.release(); ro.release();
    _emb = (out![0] as OrtValueTensor).value as List<List<List<List<double>>>>;
    out.forEach((e) => e?.release());
  }

  Future<List<List<bool>>?> predict(BoundingBox box,
      {bool usePoints = true}) async {
    assert(_emb != null);
    const s = 1024.0;
    final sx = s / _embW, sy = s / _embH;
    final b1x = box.x1 * sx, b1y = box.y1 * sy;
    final b2x = box.x2 * sx, b2y = box.y2 * sy;

    final coords = Float32List.fromList([
      (b1x + b2x) / 2, (b1y + b2y) / 2,
      b1x + 2.0, b1y + 2.0,
      b2x - 2.0, b2y - 2.0,
    ]);
    final labels = Int32List.fromList([1, 0, 0]);
    final nPts   = labels.length;

    final flat   = Float32List.fromList(
        [for (final a in _emb!) for (final b in a) for (final c in b) ...c]);
    final eShape = [1, _emb![0].length, _emb![0][0].length, _emb![0][0][0].length];

    final ro   = OrtRunOptions();
    final tEmb = OrtValueTensor.createTensorWithDataList(flat, eShape);
    final tPts = OrtValueTensor.createTensorWithDataList(coords, [1, nPts, 2]);
    final tLbl = OrtValueTensor.createTensorWithDataList(labels, [1, nPts]);
    final out  = await _dec!.runAsync(ro, {
      'image_embeddings': tEmb,
      'point_coords':     tPts,
      'point_labels':     tLbl,
    });
    for (final t in [tEmb, tPts, tLbl]) t.release();
    ro.release();

    final logits = (out![0] as OrtValueTensor).value as List<List<List<List<double>>>>;
    final ious   = (out[1] as OrtValueTensor).value as List<List<double>>;
    out.forEach((e) => e?.release());

    int best = 0;
    for (int i = 1; i < ious[0].length; i++) {
      if (ious[0][i] > ious[0][best]) best = i;
    }

    final lr = logits[0][best];
    final lH = lr.length, lW = lr[0].length;
    return List.generate(_embH, (y) {
      final sy2 = (y * lH / _embH).floor().clamp(0, lH - 1);
      return List.generate(_embW, (x) {
        final sx2 = (x * lW / _embW).floor().clamp(0, lW - 1);
        return lr[sy2][sx2] > 0.0;
      });
    });
  }

  Float32List _ncwNorm(img.Image im, int sz) {
    const mean = [0.485, 0.456, 0.406];
    const std  = [0.229, 0.224, 0.225];
    final buf = Float32List(3 * sz * sz);
    for (int y = 0; y < sz; y++) for (int x = 0; x < sz; x++) {
      final p = im.getPixel(x, y); final i = y * sz + x;
      buf[i]               = (p.r / 255.0 - mean[0]) / std[0];
      buf[sz * sz + i]     = (p.g / 255.0 - mean[1]) / std[1];
      buf[2 * sz * sz + i] = (p.b / 255.0 - mean[2]) / std[2];
    }
    return buf;
  }

  void dispose() {
    _enc?.release(); _dec?.release();
    _enc = null; _dec = null;
  }
}

// ---------------------------------------------------------------------------
// ResNet-18 classifier bank
// ---------------------------------------------------------------------------

class ResNet18ClassifierBank {
  final Map<String, OrtSession> _cache = {};

  Future<OrtSession> _load(String group) async {
    return _cache[group] ??=
        await _sessionFromAsset('assets/models/rn18_$group.onnx');
  }

  Future<(String, double)> predict(String group, img.Image crop) async {
    final s   = await _load(group);
    const sz  = 224;
    const prescale = 256;
    final shortSide = math.min(crop.width, crop.height);
    final scale     = prescale / shortSide;
    final scaledW   = (crop.width  * scale).round().clamp(sz, 99999);
    final scaledH   = (crop.height * scale).round().clamp(sz, 99999);
    final scaled    = img.copyResize(crop, width: scaledW, height: scaledH,
        interpolation: img.Interpolation.linear);
    final cx = (scaledW - sz) ~/ 2;
    final cy = (scaledH - sz) ~/ 2;
    final r  = img.copyCrop(scaled, x: cx, y: cy, width: sz, height: sz);

    const mean = [0.485, 0.456, 0.406];
    const std  = [0.229, 0.224, 0.225];
    final buf  = Float32List(3 * sz * sz);
    for (int y = 0; y < sz; y++) for (int x = 0; x < sz; x++) {
      final p = r.getPixel(x, y); final i = y * sz + x;
      buf[i]               = (p.r / 255.0 - mean[0]) / std[0];
      buf[sz * sz + i]     = (p.g / 255.0 - mean[1]) / std[1];
      buf[2 * sz * sz + i] = (p.b / 255.0 - mean[2]) / std[2];
    }

    final ro  = OrtRunOptions();
    final t   = OrtValueTensor.createTensorWithDataList(buf, [1, 3, sz, sz]);
    final out = await s.runAsync(ro, {'input': t});
    t.release(); ro.release();

    final logits = (out![0] as OrtValueTensor).value as List<List<double>>;
    out.forEach((e) => e?.release());

    final mx    = logits[0].reduce(math.max);
    final exp   = logits[0].map((v) => math.exp(v - mx)).toList();
    final sum   = exp.reduce((a, b) => a + b);
    final probs = exp.map((v) => v / sum).toList();
    int bi = 0;
    for (int i = 1; i < probs.length; i++) {
      if (probs[i] > probs[bi]) bi = i;
    }
    final labels = kClassifierLabels[group] ?? [];
    return (bi < labels.length ? labels[bi] : 'unknown', probs[bi]);
  }

  void dispose() {
    for (final s in _cache.values) s.release();
    _cache.clear();
  }
}

// ---------------------------------------------------------------------------
// Pipeline orchestrator
// ---------------------------------------------------------------------------

class InsectopediaPipeline {
  final PipelineConfig config;
  final _yolo = Yolo26Model();
  final _sam  = RepVitSamModel();
  final _clf  = ResNet18ClassifierBank();
  bool _ready = false;

  InsectopediaPipeline({this.config = const PipelineConfig()});

  // ── Model loading ─────────────────────────────────────────────────────────
  // Loads YOLO + SAM encoder/decoder in parallel and reports sub-step
  // progress so the bar visibly moves during the ~2–4s cold start.
  Future<void> loadModels({ProgressCallback? onProgress}) async {
    if (_ready) return;
    OrtEnv.instance.init();

    // Track which of the two parallel loads has finished.
    int done = 0;
    void tick(String label) {
      done++;
      // 0 → 0.15 window for model loading
      onProgress?.call(PipelineProgress(done / 2 * 0.15, label));
    }

    await Future.wait([
      _yolo.load().then((_) => tick('YOLO detector loaded')),
      _sam.load().then((_)  => tick('SAM segmenter loaded')),
    ]);
    _ready = true;
    onProgress?.call(const PipelineProgress(0.15, 'Models ready'));
  }

  // ── Main inference ────────────────────────────────────────────────────────
  Future<PipelineResult> run(
    img.Image image, {
    ProgressCallback? onProgress,
  }) async {
    assert(_ready);
    final origW = image.width, origH = image.height;

    // ── Step 1: First YOLO pass (0.15 → 0.30) ────────────────────────────
    onProgress?.call(const PipelineProgress(0.15, 'Detecting pests…'));
    var boxes = await _yolo.predict(image, config.imgsz);
    onProgress?.call(const PipelineProgress(0.30, 'Detection complete'));

    final noDetect = boxes.isEmpty;
    String? top1B  = noDetect ? null : kYoloBucketNames[boxes.first.cls];

    // ── Step 2: Retry pass if needed (0.30 → 0.45) ───────────────────────
    if (noDetect || (top1B != null && config.retryBuckets.contains(top1B))) {
      onProgress?.call(const PipelineProgress(0.30, 'Retrying at higher resolution…'));
      boxes = await _yolo.predict(image, config.retryImgsz);
      onProgress?.call(const PipelineProgress(0.45, 'High-res detection complete'));
      if (boxes.isEmpty) return _noDet();
      top1B = kYoloBucketNames[boxes.first.cls];
    }
    if (boxes.isEmpty) return _noDet();

    final top1 = boxes.first;
    top1B = kYoloBucketNames[top1.cls];

    if (kYoloOnlyBuckets.containsKey(top1B)) {
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      return PipelineResult(predBucket: top1B, yoloConf: top1.conf,
        predSpecies: kYoloOnlyBuckets[top1B]!, clfConf: 0,
        joint: top1.conf, decisionMode: 'YOLO_ONLY', allBoxes: boxes);
    }

    final lowFloor = (config.tinyPestLowConf != null && top1B == 'tiny_pests')
        ? config.tinyPestLowConf! : config.yoloLowConf;

    // ── Step 3: Low-conf rescue path (0.45 → 0.85) ───────────────────────
    if (top1.conf < lowFloor) {
      if (config.lowConfRescue) {
        onProgress?.call(const PipelineProgress(0.45, 'Encoding image for segmentation…'));
        await _sam.encodeImage(image);
        onProgress?.call(const PipelineProgress(0.55, 'Running low-confidence rescue…'));

        CandidateResult? best;
        final rescueTopk = boxes.take(config.lowConfRescueTopk).toList();
        for (int i = 0; i < rescueTopk.length; i++) {
          final bb = rescueTopk[i];
          // Spread 0.55 → 0.85 across rescue candidates
          final frac = 0.55 + (i + 1) / rescueTopk.length * 0.30;
          final c     = await _eval(image, origW, origH, bb);
          onProgress?.call(PipelineProgress(frac, 'Classifying candidate ${i + 1} of ${rescueTopk.length}…'));
          final score = config.lowConfWeightYolo * bb.conf +
              config.lowConfWeightClf * c.clfConf;
          if (score >= config.lowConfAcceptThresh &&
              (best == null || c.joint > best.joint)) best = c;
        }
        onProgress?.call(const PipelineProgress(1.0, 'Done'));
        if (best != null) return _fc(best, 'LOW_CONF_RESCUE', boxes);
      }
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      return PipelineResult(predBucket: top1B, yoloConf: top1.conf,
        predSpecies: 'LOW_CONF', clfConf: 0, joint: 0,
        decisionMode: 'LOW_CONF', allBoxes: boxes);
    }

    // ── Step 4: SAM encode (0.45 → 0.55) ─────────────────────────────────
    onProgress?.call(const PipelineProgress(0.45, 'Encoding image for segmentation…'));
    await _sam.encodeImage(image);
    onProgress?.call(const PipelineProgress(0.55, 'Segmentation ready'));

    // ── Step 5: Forced tiling (0.55 → 1.0) ───────────────────────────────
    if (config.forceTileBuckets.contains(top1B)) {
      onProgress?.call(const PipelineProgress(0.55, 'Running tiled detection…'));
      final t = await _tiled(image, onProgress: onProgress, progressStart: 0.55, progressEnd: 0.92);
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      if (t != null) return _fc(t, 'TILED_FORCED', boxes);
      return _fc(await _eval(image, origW, origH, top1), 'TOP1_FALLBACK', boxes);
    }

    if (_isLarge(origW, origH)) {
      onProgress?.call(const PipelineProgress(0.55, 'Large image — running tiled detection…'));
      final t = await _tiled(image, onProgress: onProgress, progressStart: 0.55, progressEnd: 0.92);
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      if (t != null) return _fc(t, 'TILED_SIZE', boxes);
      return _fc(await _eval(image, origW, origH, top1), 'TOP1_FALLBACK', boxes);
    }

    // ── Step 6a: High-conf TOP1 path (0.55 → 1.0) ────────────────────────
    if (top1.conf >= config.yoloFusionThresh) {
      onProgress?.call(const PipelineProgress(0.55, 'Segmenting best detection…'));
      final result = _fc(await _eval(image, origW, origH, top1), 'TOP1', boxes);
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      return result;
    }

    // ── Step 6b: Fusion over top-K (0.55 → 1.0) ──────────────────────────
    final topk = boxes.take(config.fusionTopk).toList();
    onProgress?.call(PipelineProgress(0.55, 'Classifying top ${topk.length} candidates…'));

    CandidateResult? best;
    for (int i = 0; i < topk.length; i++) {
      final bb   = topk[i];
      final frac = 0.55 + (i + 1) / topk.length * 0.30;
      final c    = await _eval(image, origW, origH, bb);
      onProgress?.call(PipelineProgress(frac, 'Classifying candidate ${i + 1} of ${topk.length}…'));
      if (best == null || c.joint > best.joint) best = c;
    }

    final confs = topk.map((b) => b.conf).toList();
    if (_shouldTile(origW, origH, confs, best!.joint)) {
      onProgress?.call(const PipelineProgress(0.85, 'Running tiled verification…'));
      final t = await _tiled(image, onProgress: onProgress, progressStart: 0.85, progressEnd: 0.97);
      onProgress?.call(const PipelineProgress(1.0, 'Done'));
      if (t != null && t.joint > best.joint) {
        return _fc(t, 'TILED_FUSION', boxes);
      }
    }

    onProgress?.call(const PipelineProgress(1.0, 'Done'));
    return _fc(best, 'FUSION_TOP${topk.length}', boxes);
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  PipelineResult _noDet() => const PipelineResult(
    predBucket: 'unknown', yoloConf: 0, predSpecies: 'NO_DETECTION',
    clfConf: 0, joint: 0, decisionMode: 'NO_DETECTION', allBoxes: []);

  PipelineResult _fc(CandidateResult c, String mode, List<BoundingBox> boxes) =>
    PipelineResult(predBucket: c.predBucket, yoloConf: c.yoloConf,
      predSpecies: c.predSpecies, clfConf: c.clfConf,
      joint: c.joint, decisionMode: mode, allBoxes: boxes);

  Future<CandidateResult> _eval(img.Image image, int w, int h,
      BoundingBox box, {String? ob}) async {
    final bucket = ob ?? kYoloBucketNames[box.cls];
    if (kYoloOnlyBuckets.containsKey(bucket)) {
      return CandidateResult(predBucket: bucket, yoloConf: box.conf, group: '',
        predSpecies: kYoloOnlyBuckets[bucket]!, clfConf: 0, joint: box.conf);
    }
    if (!kCoarseToGroup.containsKey(bucket)) {
      return CandidateResult(predBucket: bucket, yoloConf: box.conf, group: '',
        predSpecies: 'NO_GROUP_MAP', clfConf: 0, joint: 0);
    }
    final group = kCoarseToGroup[bucket]!;
    var crop    = _padCrop(image, box);
    final mode  = config.bucketModeOverrides[bucket] ?? config.mode;
    if (mode != 'box') {
      final mask = await _sam.predict(box, usePoints: config.usePoints);
      crop = _applyMask(crop, mask, box, mode);
    }
    if (config.clfPrescale > 0) {
      final mx = math.max(crop.width, crop.height);
      if (mx > config.clfPrescale) {
        final sc = config.clfPrescale / mx;
        crop = img.copyResize(crop,
          width:  (crop.width  * sc).round(),
          height: (crop.height * sc).round());
      }
    }
    final (species, clfConf) = await _clf.predict(group, crop);
    return CandidateResult(predBucket: bucket, yoloConf: box.conf, group: group,
      predSpecies: species, clfConf: clfConf, joint: box.conf * clfConf);
  }

  Future<CandidateResult?> _tiled(
    img.Image image, {
    ProgressCallback? onProgress,
    double progressStart = 0.55,
    double progressEnd   = 0.92,
  }) async {
    final tiles = _makeTiles(image);
    final cands = <(double, BoundingBox)>[];

    // ── Tile YOLO pass (progressStart → midpoint) ─────────────────────────
    final mid = progressStart + (progressEnd - progressStart) * 0.4;
    for (int ti = 0; ti < tiles.length; ti++) {
      final (tile, xo, yo) = tiles[ti];
      for (final bb in
          (await _yolo.predict(tile, config.imgsz)).take(config.tilePerTileTopk)) {
        cands.add((bb.conf, BoundingBox(
          x1: bb.x1 + xo, y1: bb.y1 + yo,
          x2: bb.x2 + xo, y2: bb.y2 + yo,
          conf: bb.conf, cls: bb.cls)));
      }
      final frac = progressStart + (ti + 1) / tiles.length * (mid - progressStart);
      onProgress?.call(PipelineProgress(frac, 'Scanning tile ${ti + 1} of ${tiles.length}…'));
    }

    if (cands.isEmpty) return null;
    cands.sort((a, b) => b.$1.compareTo(a.$1));

    await _sam.encodeImage(image);

    // ── Tile classify pass (midpoint → progressEnd) ───────────────────────
    CandidateResult? best;
    final topCands = (config.tileTopk > 0 ? cands.take(config.tileTopk) : cands).toList();
    for (int i = 0; i < topCands.length; i++) {
      final (_, bb) = topCands[i];
      final c = await _eval(image, image.width, image.height, bb);
      final frac = mid + (i + 1) / topCands.length * (progressEnd - mid);
      onProgress?.call(PipelineProgress(frac, 'Classifying tile candidate ${i + 1} of ${topCands.length}…'));
      if (best == null || c.joint > best.joint) best = c;
    }
    return best;
  }

  img.Image _padCrop(img.Image im, BoundingBox box) {
    final bw = box.x2 - box.x1, bh = box.y2 - box.y1;
    final px = bw * config.pad * 0.5, py = bh * config.pad * 0.5;
    final x1 = (box.x1 - px).clamp(0, im.width  - 1.0).toInt();
    final y1 = (box.y1 - py).clamp(0, im.height - 1.0).toInt();
    final x2 = (box.x2 + px).clamp(1, im.width.toDouble()).toInt();
    final y2 = (box.y2 + py).clamp(1, im.height.toDouble()).toInt();
    return img.copyCrop(im, x: x1, y: y1, width: x2 - x1, height: y2 - y1);
  }

  img.Image _applyMask(img.Image crop, List<List<bool>>? mask,
      BoundingBox box, String mode) {
    if (mask == null) return crop;
    final out = img.Image(width: crop.width, height: crop.height);
    for (int y = 0; y < crop.height; y++) for (int x = 0; x < crop.width; x++) {
      final my = (box.y1 + y).toInt().clamp(0, mask.length - 1);
      final mx = (box.x1 + x).toInt().clamp(0, mask[0].length - 1);
      final p  = crop.getPixel(x, y);
      final inM = mask[my][mx];
      if (mode == 'mask') {
        out.setPixelRgba(x, y,
            inM ? p.r.toInt() : 0,
            inM ? p.g.toInt() : 0,
            inM ? p.b.toInt() : 0, 255);
      } else {
        final a = inM ? 1.0 : config.bgAlpha;
        out.setPixelRgba(x, y,
            (p.r * a).round(), (p.g * a).round(), (p.b * a).round(), 255);
      }
    }
    return out;
  }

  List<(img.Image, int, int)> _makeTiles(img.Image im) {
    final h = im.height, w = im.width, ts = config.imgsz;
    final stride = (ts * (1 - config.tileOverlap)).toInt().clamp(1, ts);
    final tiles  = <(img.Image, int, int)>[];
    final ys = <int>[], xs = <int>[];
    for (int y = 0; y < h - ts + 1; y += stride) ys.add(y);
    if (ys.isEmpty || ys.last != math.max(0, h - ts)) ys.add(math.max(0, h - ts));
    for (int x = 0; x < w - ts + 1; x += stride) xs.add(x);
    if (xs.isEmpty || xs.last != math.max(0, w - ts)) xs.add(math.max(0, w - ts));
    for (final y0 in ys) for (final x0 in xs) {
      tiles.add((img.copyCrop(im, x: x0, y: y0,
        width:  math.min(w, x0 + ts) - x0,
        height: math.min(h, y0 + ts) - y0), x0, y0));
    }
    return tiles;
  }

  bool _isLarge(int w, int h) =>
    math.max(w, h) >= (config.tileSizeMult * config.imgsz).ceil();

  bool _shouldTile(int w, int h, List<double> confs, double joint) =>
    _isLarge(w, h) ||
    (confs.isNotEmpty && confs.reduce(math.max) < config.tileConfThresh) ||
    joint < config.tileJointThresh;

  void dispose() { _yolo.dispose(); _sam.dispose(); _clf.dispose(); }
}