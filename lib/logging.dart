// ============================================================
// Insectopedia — Inference Event Logging
// ============================================================
// This file owns everything related to the detections.db database:
//
//   InferenceEvent  — the data model, mirrors the SQL schema exactly
//   DetectionDatabase — SQLite singleton, creates the DB on first launch
//   EventLogger     — high-level helper called from the UI layer
//
// Usage from main.dart / result screens:
//
//   // When the pipeline finishes:
//   final eventId = await EventLogger.logInference(
//     result:        pipelineResult,
//     imagePath:     path,
//     detectionType: 'camera',
//     imageConsent:  prefs.getBool('image_consent') ?? false,
//     startedAt:     stopwatch.elapsedMilliseconds,
//   );
//
//   // When the user confirms (Yes, show details):
//   await EventLogger.markCorrect(eventId);
//
//   // When the user corrects via HITL:
//   await EventLogger.markCorrected(eventId, correctedSpecies: 'aphids');
//
//   // When the user retakes without confirming:
//   await EventLogger.markSkipped(eventId);
//
// ============================================================

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'pipeline_engine.dart';

// ─── Constants ────────────────────────────────────────────────────────────────

// Bump this string whenever you ship new model weights.
// This is the value stored in every inference_events row under model_version,
// letting query 7 in the analytics compare model generations.
const kModelVersion = 'yolo26_v1_rn18_v1';

// App version — update this to match pubspec.yaml version on each release.
const kAppVersion = '1.0.0+1';

// Shared preferences keys (must match the keys in main.dart)
const _kSessionId    = 'session_id';
const _kImageConsent = 'image_consent';

// ─── InferenceEvent ───────────────────────────────────────────────────────────
// Mirrors the inference_events table column-for-column.
// Nullable fields are null in the DB when not yet known.

class InferenceEvent {
  final String  id;
  final String  timestamp;
  final String  sessionId;
  final String? deviceInfo;
  final String  appVersion;
  final String  modelVersion;
  final String  detectionType;   // "camera" | "gallery"
  final int     retaken;         // 0 = first attempt, 1 = user retook
  final String? imagePath;       // null if image_consent = false
  final int     imageConsent;    // 1 = consented, 0 = declined
  final String? predictedBucket;
  final String? predictedSpecies;
  final double? yoloConf;
  final double? clfConf;
  final double? predictionConfidence;
  final String? decisionType;
  final int?    inferenceTimeMs;
  final int     hitlTriggered;   // 1 if HITL page was shown
  final String? feedbackStatus;  // "correct" | "corrected" | "skipped" | null
  final String? correctedSpecies;
  final String  syncStatus;      // "pending" | "synced" | "failed"
  final String? syncedAt;

  const InferenceEvent({
    required this.id,
    required this.timestamp,
    required this.sessionId,
    this.deviceInfo,
    required this.appVersion,
    required this.modelVersion,
    required this.detectionType,
    required this.retaken,
    this.imagePath,
    required this.imageConsent,
    this.predictedBucket,
    this.predictedSpecies,
    this.yoloConf,
    this.clfConf,
    this.predictionConfidence,
    this.decisionType,
    this.inferenceTimeMs,
    required this.hitlTriggered,
    this.feedbackStatus,
    this.correctedSpecies,
    required this.syncStatus,
    this.syncedAt,
  });

  // Convert to a map for SQLite insertion
  Map<String, Object?> toMap() => {
        'id':                   id,
        'timestamp':            timestamp,
        'session_id':           sessionId,
        'device_info':          deviceInfo,
        'app_version':          appVersion,
        'model_version':        modelVersion,
        'detection_type':       detectionType,
        'retaken':              retaken,
        'image_path':           imagePath,
        'image_consent':        imageConsent,
        'predicted_bucket':     predictedBucket,
        'predicted_species':    predictedSpecies,
        'yolo_conf':            yoloConf,
        'clf_conf':             clfConf,
        'prediction_confidence': predictionConfidence,
        'decision_type':        decisionType,
        'inference_time_ms':    inferenceTimeMs,
        'hitl_triggered':       hitlTriggered,
        'feedback_status':      feedbackStatus,
        'corrected_species':    correctedSpecies,
        'sync_status':          syncStatus,
        'synced_at':            syncedAt,
      };

  // Reconstruct from a row returned by sqflite
  factory InferenceEvent.fromMap(Map<String, Object?> row) => InferenceEvent(
        id:                   row['id']                   as String,
        timestamp:            row['timestamp']            as String,
        sessionId:            row['session_id']           as String,
        deviceInfo:           row['device_info']          as String?,
        appVersion:           row['app_version']          as String? ?? '',
        modelVersion:         row['model_version']        as String? ?? '',
        detectionType:        row['detection_type']       as String? ?? '',
        retaken:              row['retaken']               as int? ?? 0,
        imagePath:            row['image_path']            as String?,
        imageConsent:         row['image_consent']         as int? ?? 0,
        predictedBucket:      row['predicted_bucket']      as String?,
        predictedSpecies:     row['predicted_species']     as String?,
        yoloConf:             row['yolo_conf']             as double?,
        clfConf:              row['clf_conf']              as double?,
        predictionConfidence: row['prediction_confidence'] as double?,
        decisionType:         row['decision_type']         as String?,
        inferenceTimeMs:      row['inference_time_ms']     as int?,
        hitlTriggered:        row['hitl_triggered']        as int? ?? 0,
        feedbackStatus:       row['feedback_status']       as String?,
        correctedSpecies:     row['corrected_species']     as String?,
        syncStatus:           row['sync_status']           as String? ?? 'pending',
        syncedAt:             row['synced_at']             as String?,
      );
}

// ─── DetectionDatabase ────────────────────────────────────────────────────────
// Singleton that owns the detections.db connection.
// Created fresh on each device at runtime — never shipped as an asset.

class DetectionDatabase {
  DetectionDatabase._();
  static final DetectionDatabase instance = DetectionDatabase._();

  Database? _db;

  Future<void> init() async {
    if (_db != null) return;

    final dbDir  = await getDatabasesPath();
    final dbPath = p.join(dbDir, 'detections.db');

    _db = await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        // Create the table — matches detections_schema.sql exactly,
        // minus the comments which SQLite's Dart driver handles fine.
        await db.execute('''
          CREATE TABLE IF NOT EXISTS inference_events (
            id                    TEXT PRIMARY KEY,
            timestamp             TEXT NOT NULL,
            session_id            TEXT NOT NULL,
            device_info           TEXT,
            app_version           TEXT,
            model_version         TEXT,
            detection_type        TEXT NOT NULL,
            retaken               INTEGER NOT NULL DEFAULT 0,
            image_path            TEXT,
            image_consent         INTEGER NOT NULL DEFAULT 0,
            predicted_bucket      TEXT,
            predicted_species     TEXT,
            yolo_conf             REAL,
            clf_conf              REAL,
            prediction_confidence REAL,
            decision_type         TEXT,
            inference_time_ms     INTEGER,
            hitl_triggered        INTEGER NOT NULL DEFAULT 0,
            feedback_status       TEXT,
            corrected_species     TEXT,
            sync_status           TEXT NOT NULL DEFAULT 'pending',
            synced_at             TEXT
          )
        ''');

        // Create indexes for fast querying and sync batching
        await db.execute('CREATE INDEX IF NOT EXISTS idx_sync_status ON inference_events(sync_status)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_session     ON inference_events(session_id)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_timestamp   ON inference_events(timestamp)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_species     ON inference_events(predicted_species, predicted_bucket)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_feedback    ON inference_events(feedback_status, corrected_species)');
      },
    );
  }

  Future<Database> get _database async {
    await init();
    return _db!;
  }

  // ── Write ──────────────────────────────────────────────────────────────────

  Future<void> insert(InferenceEvent event) async {
    final db = await _database;
    await db.insert(
      'inference_events',
      event.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Update just the feedback columns once the user has responded.
  Future<void> updateFeedback(
    String id, {
    required String feedbackStatus,
    String?  correctedSpecies,
    int      hitlTriggered = 0,
  }) async {
    final db = await _database;
    await db.update(
      'inference_events',
      {
        'feedback_status':   feedbackStatus,
        'corrected_species': correctedSpecies,
        'hitl_triggered':    hitlTriggered,
      },
      where:     'id = ?',
      whereArgs: [id],
    );
  }

  // Mark rows as synced after a successful upload to the server.
  Future<void> markSynced(List<String> ids) async {
    final db        = await _database;
    final now       = DateTime.now().toUtc().toIso8601String();
    final placeholders = ids.map((_) => '?').join(', ');
    await db.rawUpdate(
      "UPDATE inference_events SET sync_status = 'synced', synced_at = ? "
      "WHERE id IN ($placeholders)",
      [now, ...ids],
    );
  }

  // Mark rows as failed so they can be retried next sync cycle.
  Future<void> markFailed(List<String> ids) async {
    final db           = await _database;
    final placeholders = ids.map((_) => '?').join(', ');
    await db.rawUpdate(
      "UPDATE inference_events SET sync_status = 'failed' "
      "WHERE id IN ($placeholders)",
      ids,
    );
  }

  // ── Read ───────────────────────────────────────────────────────────────────

  // All rows that haven't been synced yet — used by the sync job.
  Future<List<InferenceEvent>> getPending() async {
    final db   = await _database;
    final rows = await db.query(
      'inference_events',
      where: "sync_status = 'pending' OR sync_status = 'failed'",
      orderBy: 'timestamp ASC',
    );
    return rows.map(InferenceEvent.fromMap).toList();
  }

  // Total number of events logged — useful for debugging / settings display.
  Future<int> count() async {
    final db  = await _database;
    final result = await db.rawQuery('SELECT COUNT(*) as n FROM inference_events');
    return result.first['n'] as int? ?? 0;
  }
}

// ─── EventLogger ─────────────────────────────────────────────────────────────
// High-level helper — the only thing main.dart / result screens need to call.
// Returns the event UUID so the caller can update feedback status later.

class EventLogger {
  EventLogger._(); // not instantiable

  static const _uuid = Uuid();

  // ── Session ID ─────────────────────────────────────────────────────────────
  // Generated once per app launch, stored in shared_preferences.
  // Resets each launch so you can group scans from the same session.

  static String? _sessionId;

  static Future<String> _getSessionId() async {
    if (_sessionId != null) return _sessionId!;
    final prefs = await SharedPreferences.getInstance();
    // Generate a fresh session UUID every launch
    _sessionId = _uuid.v4();
    return _sessionId!;
  }

  // ── Device info ────────────────────────────────────────────────────────────
  // Returns a basic device string. For a richer value you'd add
  // the device_info_plus package, but this works without it.

  static String _deviceInfo() {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS)     return 'iOS';
    return 'Unknown';
  }

  // ── Log a new inference event ──────────────────────────────────────────────
  // Call this immediately after the pipeline returns a result.
  //
  // Parameters:
  //   result         — the PipelineResult from InsectopediaPipeline.run()
  //   imagePath      — path to the image file on disk
  //   detectionType  — "camera" or "gallery"
  //   imageConsent   — from prefs.getBool(_kImageConsent) ?? false
  //   inferenceMs    — elapsed milliseconds (optional — use a Stopwatch)
  //   retaken        — true if the user retook the image before this scan

  static Future<String> logInference({
    required PipelineResult result,
    required String         imagePath,
    required String         detectionType,
    required bool           imageConsent,
    int?                    inferenceMs,
    bool                    retaken = false,
  }) async {
    final id        = _uuid.v4();
    final sessionId = await _getSessionId();
    final now       = DateTime.now().toUtc().toIso8601String();

    final event = InferenceEvent(
      id:                   id,
      timestamp:            now,
      sessionId:            sessionId,
      deviceInfo:           _deviceInfo(),
      appVersion:           kAppVersion,
      modelVersion:         kModelVersion,
      detectionType:        detectionType,
      retaken:              retaken ? 1 : 0,
      // Only store the image path if user consented
      imagePath:            imageConsent ? imagePath : null,
      imageConsent:         imageConsent ? 1 : 0,
      predictedBucket:      result.predBucket,
      predictedSpecies:     result.predSpecies,
      yoloConf:             result.yoloConf,
      clfConf:              result.clfConf,
      predictionConfidence: result.joint,
      decisionType:         result.decisionMode,
      inferenceTimeMs:      inferenceMs,
      // HITL and feedback are unknown at this point — updated later
      hitlTriggered:        0,
      feedbackStatus:       null,
      correctedSpecies:     null,
      syncStatus:           'pending',
    );

    await DetectionDatabase.instance.insert(event);
    return id; // caller stores this to update feedback later
  }

  // ── Feedback updates ───────────────────────────────────────────────────────
  // Call the appropriate method once the user responds on the result screen.

  // User tapped "Yes, show details" — prediction was correct.
  static Future<void> markCorrect(String eventId) async {
    await DetectionDatabase.instance.updateFeedback(
      eventId,
      feedbackStatus: 'correct',
      hitlTriggered:  0,
    );
  }

  // User went through HITL and selected a different species.
  static Future<void> markCorrected(
    String eventId, {
    required String correctedSpecies,
  }) async {
    await DetectionDatabase.instance.updateFeedback(
      eventId,
      feedbackStatus:   'corrected',
      correctedSpecies: correctedSpecies,
      hitlTriggered:    1,
    );
  }

  // User tapped "Retake Image" without confirming anything.
  // hitlTriggered is passed through so we know if they at least saw HITL.
  static Future<void> markSkipped(
    String eventId, {
    bool hitlWasShown = false,
  }) async {
    await DetectionDatabase.instance.updateFeedback(
      eventId,
      feedbackStatus: 'skipped',
      hitlTriggered:  hitlWasShown ? 1 : 0,
    );
  }

  // HITL page was shown but user went back and confirmed the original result.
  // Marks correct but also records that HITL was triggered.
  static Future<void> markCorrectAfterHitl(String eventId) async {
    await DetectionDatabase.instance.updateFeedback(
      eventId,
      feedbackStatus: 'correct',
      hitlTriggered:  1,
    );
  }
}