// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'session_record.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$SessionRecord {
  String get timestamp;
  @JsonKey(name: 'book_title')
  String get bookTitle;
  String? get engine;
  @JsonKey(name: 'chapters_converted')
  int? get chaptersConverted;
  @JsonKey(name: 'duration_seconds')
  double? get durationSeconds;
  String? get outcome;
  String? get mode;

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SessionRecordCopyWith<SessionRecord> get copyWith =>
      _$SessionRecordCopyWithImpl<SessionRecord>(
        this as SessionRecord,
        _$identity,
      );

  /// Serializes this SessionRecord to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as SessionRecord;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SessionRecord &&
            (identical(other.timestamp, _this.timestamp) ||
                other.timestamp == _this.timestamp) &&
            (identical(other.bookTitle, _this.bookTitle) ||
                other.bookTitle == _this.bookTitle) &&
            (identical(other.engine, _this.engine) ||
                other.engine == _this.engine) &&
            (identical(other.chaptersConverted, _this.chaptersConverted) ||
                other.chaptersConverted == _this.chaptersConverted) &&
            (identical(other.durationSeconds, _this.durationSeconds) ||
                other.durationSeconds == _this.durationSeconds) &&
            (identical(other.outcome, _this.outcome) ||
                other.outcome == _this.outcome) &&
            (identical(other.mode, _this.mode) || other.mode == _this.mode));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as SessionRecord;
    return Object.hash(
      runtimeType,
      _this.timestamp,
      _this.bookTitle,
      _this.engine,
      _this.chaptersConverted,
      _this.durationSeconds,
      _this.outcome,
      _this.mode,
    );
  }

  @override
  String toString() {
    final _this = this as SessionRecord;
    return 'SessionRecord(timestamp: ${_this.timestamp}, bookTitle: ${_this.bookTitle}, engine: ${_this.engine}, chaptersConverted: ${_this.chaptersConverted}, durationSeconds: ${_this.durationSeconds}, outcome: ${_this.outcome}, mode: ${_this.mode})';
  }
}

/// @nodoc
abstract mixin class $SessionRecordCopyWith<$Res> {
  factory $SessionRecordCopyWith(
    SessionRecord value,
    $Res Function(SessionRecord) _then,
  ) = _$SessionRecordCopyWithImpl;
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
class _$SessionRecordCopyWithImpl<$Res>
    implements $SessionRecordCopyWith<$Res> {
  _$SessionRecordCopyWithImpl(this._self, this._then);

  final SessionRecord _self;
  final $Res Function(SessionRecord) _then;

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
      SessionRecord(
        timestamp: null == timestamp
            ? _self.timestamp
            : timestamp // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: null == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String,
        engine: freezed == engine
            ? _self.engine
            : engine // ignore: cast_nullable_to_non_nullable
                  as String?,
        chaptersConverted: freezed == chaptersConverted
            ? _self.chaptersConverted
            : chaptersConverted // ignore: cast_nullable_to_non_nullable
                  as int?,
        durationSeconds: freezed == durationSeconds
            ? _self.durationSeconds
            : durationSeconds // ignore: cast_nullable_to_non_nullable
                  as double?,
        outcome: freezed == outcome
            ? _self.outcome
            : outcome // ignore: cast_nullable_to_non_nullable
                  as String?,
        mode: freezed == mode
            ? _self.mode
            : mode // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [SessionRecord].
extension SessionRecordPatterns on SessionRecord {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_SessionRecord value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SessionRecord() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_SessionRecord value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionRecord():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_SessionRecord value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionRecord() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(
      String timestamp,
      @JsonKey(name: 'book_title') String bookTitle,
      String? engine,
      @JsonKey(name: 'chapters_converted') int? chaptersConverted,
      @JsonKey(name: 'duration_seconds') double? durationSeconds,
      String? outcome,
      String? mode,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SessionRecord() when $default != null:
        return $default(
          _that.timestamp,
          _that.bookTitle,
          _that.engine,
          _that.chaptersConverted,
          _that.durationSeconds,
          _that.outcome,
          _that.mode,
        );
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(
      String timestamp,
      @JsonKey(name: 'book_title') String bookTitle,
      String? engine,
      @JsonKey(name: 'chapters_converted') int? chaptersConverted,
      @JsonKey(name: 'duration_seconds') double? durationSeconds,
      String? outcome,
      String? mode,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionRecord():
        return $default(
          _that.timestamp,
          _that.bookTitle,
          _that.engine,
          _that.chaptersConverted,
          _that.durationSeconds,
          _that.outcome,
          _that.mode,
        );
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(
      String timestamp,
      @JsonKey(name: 'book_title') String bookTitle,
      String? engine,
      @JsonKey(name: 'chapters_converted') int? chaptersConverted,
      @JsonKey(name: 'duration_seconds') double? durationSeconds,
      String? outcome,
      String? mode,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionRecord() when $default != null:
        return $default(
          _that.timestamp,
          _that.bookTitle,
          _that.engine,
          _that.chaptersConverted,
          _that.durationSeconds,
          _that.outcome,
          _that.mode,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _SessionRecord extends SessionRecord {
  const _SessionRecord({
    required this.timestamp,
    @JsonKey(name: 'book_title') required this.bookTitle,
    this.engine,
    @JsonKey(name: 'chapters_converted') this.chaptersConverted,
    @JsonKey(name: 'duration_seconds') this.durationSeconds,
    this.outcome,
    this.mode,
  }) : super._();
  factory _SessionRecord.fromJson(Map<String, dynamic> json) =>
      _$SessionRecordFromJson(json);

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

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$SessionRecordCopyWith<_SessionRecord> get copyWith =>
      __$SessionRecordCopyWithImpl<_SessionRecord>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$SessionRecordToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _SessionRecord &&
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
  int get hashCode {
    return Object.hash(
      runtimeType,
      timestamp,
      bookTitle,
      engine,
      chaptersConverted,
      durationSeconds,
      outcome,
      mode,
    );
  }

  @override
  String toString() {
    return 'SessionRecord(timestamp: $timestamp, bookTitle: $bookTitle, engine: $engine, chaptersConverted: $chaptersConverted, durationSeconds: $durationSeconds, outcome: $outcome, mode: $mode)';
  }
}

/// @nodoc
abstract mixin class _$SessionRecordCopyWith<$Res>
    implements $SessionRecordCopyWith<$Res> {
  factory _$SessionRecordCopyWith(
    _SessionRecord value,
    $Res Function(_SessionRecord) _then,
  ) = __$SessionRecordCopyWithImpl;
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
class __$SessionRecordCopyWithImpl<$Res>
    implements _$SessionRecordCopyWith<$Res> {
  __$SessionRecordCopyWithImpl(this._self, this._then);

  final _SessionRecord _self;
  final $Res Function(_SessionRecord) _then;

  /// Create a copy of SessionRecord
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
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
      _SessionRecord(
        timestamp: null == timestamp
            ? _self.timestamp
            : timestamp // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: null == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String,
        engine: freezed == engine
            ? _self.engine
            : engine // ignore: cast_nullable_to_non_nullable
                  as String?,
        chaptersConverted: freezed == chaptersConverted
            ? _self.chaptersConverted
            : chaptersConverted // ignore: cast_nullable_to_non_nullable
                  as int?,
        durationSeconds: freezed == durationSeconds
            ? _self.durationSeconds
            : durationSeconds // ignore: cast_nullable_to_non_nullable
                  as double?,
        outcome: freezed == outcome
            ? _self.outcome
            : outcome // ignore: cast_nullable_to_non_nullable
                  as String?,
        mode: freezed == mode
            ? _self.mode
            : mode // ignore: cast_nullable_to_non_nullable
                  as String?,
      ),
    );
  }
}

/// @nodoc
mixin _$SessionsResponse {
  List<SessionRecord> get sessions;
  int get count;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $SessionsResponseCopyWith<SessionsResponse> get copyWith =>
      _$SessionsResponseCopyWithImpl<SessionsResponse>(
        this as SessionsResponse,
        _$identity,
      );

  /// Serializes this SessionsResponse to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as SessionsResponse;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is SessionsResponse &&
            const DeepCollectionEquality().equals(
              other.sessions,
              _this.sessions,
            ) &&
            (identical(other.count, _this.count) ||
                other.count == _this.count));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as SessionsResponse;
    return Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_this.sessions),
      _this.count,
    );
  }

  @override
  String toString() {
    final _this = this as SessionsResponse;
    return 'SessionsResponse(sessions: ${_this.sessions}, count: ${_this.count})';
  }
}

/// @nodoc
abstract mixin class $SessionsResponseCopyWith<$Res> {
  factory $SessionsResponseCopyWith(
    SessionsResponse value,
    $Res Function(SessionsResponse) _then,
  ) = _$SessionsResponseCopyWithImpl;
  @useResult
  $Res call({List<SessionRecord> sessions, int count});
}

/// @nodoc
class _$SessionsResponseCopyWithImpl<$Res>
    implements $SessionsResponseCopyWith<$Res> {
  _$SessionsResponseCopyWithImpl(this._self, this._then);

  final SessionsResponse _self;
  final $Res Function(SessionsResponse) _then;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({Object? sessions = null, Object? count = null}) {
    return _then(
      SessionsResponse(
        sessions: null == sessions
            ? _self.sessions
            : sessions // ignore: cast_nullable_to_non_nullable
                  as List<SessionRecord>,
        count: null == count
            ? _self.count
            : count // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [SessionsResponse].
extension SessionsResponsePatterns on SessionsResponse {
  /// A variant of `map` that fallback to returning `orElse`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeMap<TResult extends Object?>(
    TResult Function(_SessionsResponse value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse() when $default != null:
        return $default(_that);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// Callbacks receives the raw object, upcasted.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case final Subclass2 value:
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult map<TResult extends Object?>(
    TResult Function(_SessionsResponse value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse():
        return $default(_that);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `map` that fallback to returning `null`.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case final Subclass value:
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? mapOrNull<TResult extends Object?>(
    TResult? Function(_SessionsResponse value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse() when $default != null:
        return $default(_that);
      case _:
        return null;
    }
  }

  /// A variant of `when` that fallback to an `orElse` callback.
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return orElse();
  /// }
  /// ```

  @optionalTypeArgs
  TResult maybeWhen<TResult extends Object?>(
    TResult Function(List<SessionRecord> sessions, int count)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse() when $default != null:
        return $default(_that.sessions, _that.count);
      case _:
        return orElse();
    }
  }

  /// A `switch`-like method, using callbacks.
  ///
  /// As opposed to `map`, this offers destructuring.
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case Subclass2(:final field2):
  ///     return ...;
  /// }
  /// ```

  @optionalTypeArgs
  TResult when<TResult extends Object?>(
    TResult Function(List<SessionRecord> sessions, int count) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse():
        return $default(_that.sessions, _that.count);
      case _:
        throw StateError('Unexpected subclass');
    }
  }

  /// A variant of `when` that fallback to returning `null`
  ///
  /// It is equivalent to doing:
  /// ```dart
  /// switch (sealedClass) {
  ///   case Subclass(:final field):
  ///     return ...;
  ///   case _:
  ///     return null;
  /// }
  /// ```

  @optionalTypeArgs
  TResult? whenOrNull<TResult extends Object?>(
    TResult? Function(List<SessionRecord> sessions, int count)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _SessionsResponse() when $default != null:
        return $default(_that.sessions, _that.count);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _SessionsResponse implements SessionsResponse {
  const _SessionsResponse({
    required List<SessionRecord> sessions,
    required this.count,
  }) : _sessions = sessions;
  factory _SessionsResponse.fromJson(Map<String, dynamic> json) =>
      _$SessionsResponseFromJson(json);

  final List<SessionRecord> _sessions;
  @override
  List<SessionRecord> get sessions {
    if (_sessions is EqualUnmodifiableListView) return _sessions;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(_sessions);
  }

  @override
  final int count;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$SessionsResponseCopyWith<_SessionsResponse> get copyWith =>
      __$SessionsResponseCopyWithImpl<_SessionsResponse>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$SessionsResponseToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _SessionsResponse &&
            const DeepCollectionEquality().equals(other.sessions, _sessions) &&
            (identical(other.count, count) || other.count == count));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      const DeepCollectionEquality().hash(_sessions),
      count,
    );
  }

  @override
  String toString() {
    return 'SessionsResponse(sessions: $sessions, count: $count)';
  }
}

/// @nodoc
abstract mixin class _$SessionsResponseCopyWith<$Res>
    implements $SessionsResponseCopyWith<$Res> {
  factory _$SessionsResponseCopyWith(
    _SessionsResponse value,
    $Res Function(_SessionsResponse) _then,
  ) = __$SessionsResponseCopyWithImpl;
  @override
  @useResult
  $Res call({List<SessionRecord> sessions, int count});
}

/// @nodoc
class __$SessionsResponseCopyWithImpl<$Res>
    implements _$SessionsResponseCopyWith<$Res> {
  __$SessionsResponseCopyWithImpl(this._self, this._then);

  final _SessionsResponse _self;
  final $Res Function(_SessionsResponse) _then;

  /// Create a copy of SessionsResponse
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({Object? sessions = null, Object? count = null}) {
    return _then(
      _SessionsResponse(
        sessions: null == sessions
            ? _self._sessions
            : sessions // ignore: cast_nullable_to_non_nullable
                  as List<SessionRecord>,
        count: null == count
            ? _self.count
            : count // ignore: cast_nullable_to_non_nullable
                  as int,
      ),
    );
  }
}
