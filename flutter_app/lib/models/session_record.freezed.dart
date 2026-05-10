// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'session_record.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
  'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models',
);

SessionRecord _$SessionRecordFromJson(Map<String, dynamic> json) {
  return _SessionRecord.fromJson(json);
}

/// @nodoc
mixin _$SessionRecord {
  String get timestamp => throw _privateConstructorUsedError;
  @JsonKey(name: 'book_title')
  String get bookTitle => throw _privateConstructorUsedError;
  String? get engine => throw _privateConstructorUsedError;
  @JsonKey(name: 'chapters_converted')
  int? get chaptersConverted => throw _privateConstructorUsedError;
  @JsonKey(name: 'duration_seconds')
  double? get durationSeconds => throw _privateConstructorUsedError;
  String? get outcome => throw _privateConstructorUsedError;
  String? get mode => throw _privateConstructorUsedError;

  /// Serializes this SessionRecord to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $SessionRecordCopyWith<SessionRecord> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SessionRecordCopyWith<$Res> {
  factory $SessionRecordCopyWith(
    SessionRecord value,
    $Res Function(SessionRecord) then,
  ) = _$SessionRecordCopyWithImpl<$Res, SessionRecord>;
  @useResult
  $Res call({
    String timestamp,
    @JsonKey(name: 'book_title') String bookTitle,
    String? engine,
    @JsonKey(name: 'chapters_converted') int? chaptersConverted,
    @JsonKey(name: 'duration_seconds') double? durationSeconds,
    String? outcome,
    String? mode,
  });
}

/// @nodoc
class _$SessionRecordCopyWithImpl<$Res, $Val extends SessionRecord>
    implements $SessionRecordCopyWith<$Res> {
  _$SessionRecordCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? timestamp = null,
    Object? bookTitle = null,
    Object? engine = freezed,
    Object? chaptersConverted = freezed,
    Object? durationSeconds = freezed,
    Object? outcome = freezed,
    Object? mode = freezed,
  }) {
    return _then(
      _value.copyWith(
            timestamp: null == timestamp
                ? _value.timestamp
                : timestamp // ignore: cast_nullable_to_non_nullable
                      as String,
            bookTitle: null == bookTitle
                ? _value.bookTitle
                : bookTitle // ignore: cast_nullable_to_non_nullable
                      as String,
            engine: freezed == engine
                ? _value.engine
                : engine // ignore: cast_nullable_to_non_nullable
                      as String?,
            chaptersConverted: freezed == chaptersConverted
                ? _value.chaptersConverted
                : chaptersConverted // ignore: cast_nullable_to_non_nullable
                      as int?,
            durationSeconds: freezed == durationSeconds
                ? _value.durationSeconds
                : durationSeconds // ignore: cast_nullable_to_non_nullable
                      as double?,
            outcome: freezed == outcome
                ? _value.outcome
                : outcome // ignore: cast_nullable_to_non_nullable
                      as String?,
            mode: freezed == mode
                ? _value.mode
                : mode // ignore: cast_nullable_to_non_nullable
                      as String?,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$SessionRecordImplCopyWith<$Res>
    implements $SessionRecordCopyWith<$Res> {
  factory _$$SessionRecordImplCopyWith(
    _$SessionRecordImpl value,
    $Res Function(_$SessionRecordImpl) then,
  ) = __$$SessionRecordImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({
    String timestamp,
    @JsonKey(name: 'book_title') String bookTitle,
    String? engine,
    @JsonKey(name: 'chapters_converted') int? chaptersConverted,
    @JsonKey(name: 'duration_seconds') double? durationSeconds,
    String? outcome,
    String? mode,
  });
}

/// @nodoc
class __$$SessionRecordImplCopyWithImpl<$Res>
    extends _$SessionRecordCopyWithImpl<$Res, _$SessionRecordImpl>
    implements _$$SessionRecordImplCopyWith<$Res> {
  __$$SessionRecordImplCopyWithImpl(
    _$SessionRecordImpl _value,
    $Res Function(_$SessionRecordImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? timestamp = null,
    Object? bookTitle = null,
    Object? engine = freezed,
    Object? chaptersConverted = freezed,
    Object? durationSeconds = freezed,
    Object? outcome = freezed,
    Object? mode = freezed,
  }) {
    return _then(
      _$SessionRecordImpl(
        timestamp: null == timestamp
            ? _value.timestamp
            : timestamp // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: null == bookTitle
            ? _value.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String,
        engine: freezed == engine
            ? _value.engine
            : engine // ignore: cast_nullable_to_non_nullable
                  as String?,
        chaptersConverted: freezed == chaptersConverted
            ? _value.chaptersConverted
            : chaptersConverted // ignore: cast_nullable_to_non_nullable
                  as int?,
        durationSeconds: freezed == durationSeconds
            ? _value.durationSeconds
            : durationSeconds // ignore: cast_nullable_to_non_nullable
                  as double?,
        outcome: freezed == outcome
            ? _value.outcome
            : outcome // ignore: cast_nullable_to_non_nullable
                  as String?,
        mode: freezed == mode
            ? _value.mode
            : mode // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$SessionRecordImpl extends _SessionRecord {
  const _$SessionRecordImpl({
    required this.timestamp,
    @JsonKey(name: 'book_title') required this.bookTitle,
    this.engine,
    @JsonKey(name: 'chapters_converted') this.chaptersConverted,
    @JsonKey(name: 'duration_seconds') this.durationSeconds,
    this.outcome,
    this.mode,
  }) : super._();

  factory _$SessionRecordImpl.fromJson(Map<String, dynamic> json) =>
      _$$SessionRecordImplFromJson(json);

  @override
  final String timestamp;
  @override
  @JsonKey(name: 'book_title')
  final String bookTitle;
  @override
  final String? engine;
  @override
  @JsonKey(name: 'chapters_converted')
  final int? chaptersConverted;
  @override
  @JsonKey(name: 'duration_seconds')
  final double? durationSeconds;
  @override
  final String? outcome;
  @override
  final String? mode;

  @override
  String toString() {
    return 'SessionRecord(timestamp: $timestamp, bookTitle: $bookTitle, engine: $engine, chaptersConverted: $chaptersConverted, durationSeconds: $durationSeconds, outcome: $outcome, mode: $mode)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SessionRecordImpl &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp) &&
            (identical(other.bookTitle, bookTitle) ||
                other.bookTitle == bookTitle) &&
            (identical(other.engine, engine) || other.engine == engine) &&
            (identical(other.chaptersConverted, chaptersConverted) ||
                other.chaptersConverted == chaptersConverted) &&
            (identical(other.durationSeconds, durationSeconds) ||
                other.durationSeconds == durationSeconds) &&
            (identical(other.outcome, outcome) || other.outcome == outcome) &&
            (identical(other.mode, mode) || other.mode == mode));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    timestamp,
    bookTitle,
    engine,
    chaptersConverted,
    durationSeconds,
    outcome,
    mode,
  );

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SessionRecordImplCopyWith<_$SessionRecordImpl> get copyWith =>
      __$$SessionRecordImplCopyWithImpl<_$SessionRecordImpl>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$$SessionRecordImplToJson(this);
  }
}

abstract class _SessionRecord extends SessionRecord {
  const factory _SessionRecord({
    required final String timestamp,
    @JsonKey(name: 'book_title') required final String bookTitle,
    final String? engine,
    @JsonKey(name: 'chapters_converted') final int? chaptersConverted,
    @JsonKey(name: 'duration_seconds') final double? durationSeconds,
    final String? outcome,
    final String? mode,
  }) = _$SessionRecordImpl;
  const _SessionRecord._() : super._();

  factory _SessionRecord.fromJson(Map<String, dynamic> json) =
      _$SessionRecordImpl.fromJson;

  @override
  String get timestamp;
  @override
  @JsonKey(name: 'book_title')
  String get bookTitle;
  @override
  String? get engine;
  @override
  @JsonKey(name: 'chapters_converted')
  int? get chaptersConverted;
  @override
  @JsonKey(name: 'duration_seconds')
  double? get durationSeconds;
  @override
  String? get outcome;
  @override
  String? get mode;

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SessionRecordImplCopyWith<_$SessionRecordImpl> get copyWith =>
      throw _privateConstructorUsedError;
}

SessionsResponse _$SessionsResponseFromJson(Map<String, dynamic> json) {
  return _SessionsResponse.fromJson(json);
}

/// @nodoc
mixin _$SessionsResponse {
  List<SessionRecord> get sessions => throw _privateConstructorUsedError;
  int get count => throw _privateConstructorUsedError;

  /// Serializes this SessionsResponse to a JSON map.
  Map<String, dynamic> toJson() => throw _privateConstructorUsedError;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $SessionsResponseCopyWith<SessionsResponse> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SessionsResponseCopyWith<$Res> {
  factory $SessionsResponseCopyWith(
    SessionsResponse value,
    $Res Function(SessionsResponse) then,
  ) = _$SessionsResponseCopyWithImpl<$Res, SessionsResponse>;
  @useResult
  $Res call({List<SessionRecord> sessions, int count});
}

/// @nodoc
class _$SessionsResponseCopyWithImpl<$Res, $Val extends SessionsResponse>
    implements $SessionsResponseCopyWith<$Res> {
  _$SessionsResponseCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? sessions = null, Object? count = null}) {
    return _then(
      _value.copyWith(
            sessions: null == sessions
                ? _value.sessions
                : sessions // ignore: cast_nullable_to_non_nullable
                      as List<SessionRecord>,
            count: null == count
                ? _value.count
                : count // ignore: cast_nullable_to_non_nullable
                      as int,
          )
          as $Val,
    );
  }
}

/// @nodoc
abstract class _$$SessionsResponseImplCopyWith<$Res>
    implements $SessionsResponseCopyWith<$Res> {
  factory _$$SessionsResponseImplCopyWith(
    _$SessionsResponseImpl value,
    $Res Function(_$SessionsResponseImpl) then,
  ) = __$$SessionsResponseImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({List<SessionRecord> sessions, int count});
}

/// @nodoc
class __$$SessionsResponseImplCopyWithImpl<$Res>
    extends _$SessionsResponseCopyWithImpl<$Res, _$SessionsResponseImpl>
    implements _$$SessionsResponseImplCopyWith<$Res> {
  __$$SessionsResponseImplCopyWithImpl(
    _$SessionsResponseImpl _value,
    $Res Function(_$SessionsResponseImpl) _then,
  ) : super(_value, _then);

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? sessions = null, Object? count = null}) {
    return _then(
      _$SessionsResponseImpl(
        sessions: null == sessions
            ? _value._sessions
            : sessions // ignore: cast_nullable_to_non_nullable
                  as List<SessionRecord>,
        count: null == count
            ? _value.count
            : count // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// @nodoc
@JsonSerializable()
class _$SessionsResponseImpl implements _SessionsResponse {
  const _$SessionsResponseImpl({
    required final List<SessionRecord> sessions,
    required this.count,
  }) : _sessions = sessions;

  factory _$SessionsResponseImpl.fromJson(Map<String, dynamic> json) =>
      _$$SessionsResponseImplFromJson(json);

  final List<SessionRecord> _sessions;
  @override
  List<SessionRecord> get sessions {
    if (_sessions is EqualUnmodifiableListView) return _sessions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_sessions);
  }

  @override
  final int count;

  @override
  String toString() {
    return 'SessionsResponse(sessions: $sessions, count: $count)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SessionsResponseImpl &&
            const DeepCollectionEquality().equals(other._sessions, _sessions) &&
            (identical(other.count, count) || other.count == count));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode => Object.hash(
    runtimeType,
    const DeepCollectionEquality().hash(_sessions),
    count,
  );

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SessionsResponseImplCopyWith<_$SessionsResponseImpl> get copyWith =>
      __$$SessionsResponseImplCopyWithImpl<_$SessionsResponseImpl>(
        this,
        _$identity,
      );

  @override
  Map<String, dynamic> toJson() {
    return _$$SessionsResponseImplToJson(this);
  }
}

abstract class _SessionsResponse implements SessionsResponse {
  const factory _SessionsResponse({
    required final List<SessionRecord> sessions,
    required final int count,
  }) = _$SessionsResponseImpl;

  factory _SessionsResponse.fromJson(Map<String, dynamic> json) =
      _$SessionsResponseImpl.fromJson;

  @override
  List<SessionRecord> get sessions;
  @override
  int get count;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SessionsResponseImplCopyWith<_$SessionsResponseImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
