import '../services/conversion/chapter_name_store.dart';
import '../models/book_voices.dart';
import '../models/book_language_corrections.dart';
import '../app/app_destination.dart';
export '../app/app_destination.dart';

import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:just_audio/just_audio.dart' show AudioPlayer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/language_model_choices.dart';
import '../models/reading_overrides.dart';
import '../models/tts_catalog.dart';
import '../models/tts_preferences.dart';
import '../services/playback/playback_narration_resolver.dart';
import '../services/playback/system_voice_languages.dart';
import '../services/playback/audio_player_service.dart';
import '../services/playback/background_audio_handler.dart';
import '../services/playback/mpris_service.dart';
import '../services/storage/book_derived_data_remover.dart';
import '../services/storage/bookmark_store.dart';
import '../services/conversion/embedded_converter.dart';
import '../services/conversion/android_voice_audition.dart';
import '../services/conversion/desktop_embedded_converter.dart'
    show DesktopEmbeddedConverter;
import '../services/conversion/voice_audition.dart';
import '../services/storage/local_fulltext_cache.dart';
import '../services/conversion/local_conversion_job.dart';
import '../services/playback/playback_snapshot.dart';
import '../services/playback/playback_resume_persistence.dart';
import '../services/playback/background_pacing_controller.dart';
import '../services/storage/resume_store.dart';
import '../services/playback/sync_engine.dart';

part 'settings_providers.dart';
part 'reader_providers.dart';
part 'playback_providers.dart';
part 'conversion_providers.dart';
