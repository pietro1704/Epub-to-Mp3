import '../app/app_destination.dart';
export '../app/app_destination.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/tts_preferences.dart';
import '../services/audio_player_service.dart';
import '../services/background_audio_handler.dart';
import '../services/bookmark_store.dart';
import '../services/embedded_converter.dart';
import '../services/local_fulltext_cache.dart';
import '../services/local_conversion_job.dart';
import '../services/playback_snapshot.dart';
import '../services/playback_resume_persistence.dart';
import '../services/resume_store.dart';
import '../services/sync_engine.dart';

part 'settings_providers.dart';
part 'reader_providers.dart';
part 'playback_providers.dart';
part 'conversion_providers.dart';
