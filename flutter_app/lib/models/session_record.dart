// ignore_for_file: invalid_annotation_target
import 'package:freezed_annotation/freezed_annotation.dart';

part 'session_record.freezed.dart';
part 'session_record.g.dart';

/// `GET /api/sessions` — see `python_app/src/session_logger.py`.
/// Wire format is snake_case here (legacy log entries).
@freezed
class SessionRecord with _$SessionRecord {
  const SessionRecord._();
  const factory SessionRecord({
    required String timestamp,
    @JsonKey(name: 'book_title') required String bookTitle,
    String? engine,
    @JsonKey(name: 'chapters_converted') int? chaptersConverted,
    @JsonKey(name: 'duration_seconds') double? durationSeconds,
    String? outcome,
    String? mode,
  }) = _SessionRecord;

  factory SessionRecord.fromJson(Map<String, dynamic> json) =>
      _$SessionRecordFromJson(json);

  String get id => '$timestamp|$bookTitle';
}

@freezed
class SessionsResponse with _$SessionsResponse {
  const factory SessionsResponse({
    required List<SessionRecord> sessions,
    required int count,
  }) = _SessionsResponse;

  factory SessionsResponse.fromJson(Map<String, dynamic> json) =>
      _$SessionsResponseFromJson(json);
}
