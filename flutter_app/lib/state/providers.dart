import '../app/app_destination.dart';
export '../app/app_destination.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/tts_catalog.dart';
import '../models/tts_preferences.dart';
import '../services/playback/audio_player_service.dart';
import '../services/playback/background_audio_handler.dart';
import '../services/storage/book_derived_data_remover.dart';
import '../services/storage/bookmark_store.dart';
import '../services/conversion/embedded_converter.dart';
import '../services/storage/local_fulltext_cache.dart';
import '../services/conversion/local_conversion_job.dart';
import '../services/playback/playback_snapshot.dart';
import '../services/playback/playback_resume_persistence.dart';
import '../services/storage/resume_store.dart';
import '../services/playback/sync_engine.dart';

part 'settings_providers.dart';
part 'reader_providers.dart';
part 'playback_providers.dart';
part 'conversion_providers.dart';
