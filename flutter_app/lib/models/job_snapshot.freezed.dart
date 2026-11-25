// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'job_snapshot.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
T _$identity<T>(T value) => value;

/// @nodoc
mixin _$ChapterProgress {
  int get index;
  String? get name;
  String? get status;
  String? get downloadUrl;
  int? get chars;
  int? get charsProcessed;
  double? get progressRatio;
  double? get durationSeconds;
  double? get startedAt;
  double? get completedAt;

  /// Unicode scalar offset in the chapter text where this audio starts (a
  /// listening started inside the chapter, e.g. Play from here); 0 or null
  /// for audio of the whole chapter. Mirrors iOS `ChapterProgress.textOffset`.
  int? get textOffset;

  /// Create a copy of ChapterProgress
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $ChapterProgressCopyWith<ChapterProgress> get copyWith =>
      _$ChapterProgressCopyWithImpl<ChapterProgress>(
        this as ChapterProgress,
        _$identity,
      );

  /// Serializes this ChapterProgress to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as ChapterProgress;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is ChapterProgress &&
            (identical(other.index, _this.index) ||
                other.index == _this.index) &&
            (identical(other.name, _this.name) || other.name == _this.name) &&
            (identical(other.status, _this.status) ||
                other.status == _this.status) &&
            (identical(other.downloadUrl, _this.downloadUrl) ||
                other.downloadUrl == _this.downloadUrl) &&
            (identical(other.chars, _this.chars) ||
                other.chars == _this.chars) &&
            (identical(other.charsProcessed, _this.charsProcessed) ||
                other.charsProcessed == _this.charsProcessed) &&
            (identical(other.progressRatio, _this.progressRatio) ||
                other.progressRatio == _this.progressRatio) &&
            (identical(other.durationSeconds, _this.durationSeconds) ||
                other.durationSeconds == _this.durationSeconds) &&
            (identical(other.startedAt, _this.startedAt) ||
                other.startedAt == _this.startedAt) &&
            (identical(other.completedAt, _this.completedAt) ||
                other.completedAt == _this.completedAt) &&
            (identical(other.textOffset, _this.textOffset) ||
                other.textOffset == _this.textOffset));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as ChapterProgress;
    return Object.hash(
      runtimeType,
      _this.index,
      _this.name,
      _this.status,
      _this.downloadUrl,
      _this.chars,
      _this.charsProcessed,
      _this.progressRatio,
      _this.durationSeconds,
      _this.startedAt,
      _this.completedAt,
      _this.textOffset,
    );
  }

  @override
  String toString() {
    final _this = this as ChapterProgress;
    return 'ChapterProgress(index: ${_this.index}, name: ${_this.name}, status: ${_this.status}, downloadUrl: ${_this.downloadUrl}, chars: ${_this.chars}, charsProcessed: ${_this.charsProcessed}, progressRatio: ${_this.progressRatio}, durationSeconds: ${_this.durationSeconds}, startedAt: ${_this.startedAt}, completedAt: ${_this.completedAt}, textOffset: ${_this.textOffset})';
  }
}

/// @nodoc
abstract mixin class $ChapterProgressCopyWith<$Res> {
  factory $ChapterProgressCopyWith(
    ChapterProgress value,
    $Res Function(ChapterProgress) _then,
  ) = _$ChapterProgressCopyWithImpl;
  @useResult
  $Res call({
    int index,
    String? name,
    String? status,
    String? downloadUrl,
    int? chars,
    int? charsProcessed,
    double? progressRatio,
    double? durationSeconds,
    double? startedAt,
    double? completedAt,
    int? textOffset,
  });
}

/// @nodoc
class _$ChapterProgressCopyWithImpl<$Res>
    implements $ChapterProgressCopyWith<$Res> {
  _$ChapterProgressCopyWithImpl(this._self, this._then);

  final ChapterProgress _self;
  final $Res Function(ChapterProgress) _then;

  /// Create a copy of ChapterProgress
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? index = null,
    Object? name = freezed,
    Object? status = freezed,
    Object? downloadUrl = freezed,
    Object? chars = freezed,
    Object? charsProcessed = freezed,
    Object? progressRatio = freezed,
    Object? durationSeconds = freezed,
    Object? startedAt = freezed,
    Object? completedAt = freezed,
    Object? textOffset = freezed,
  }) {
    return _then(
      ChapterProgress(
        index: null == index
            ? _self.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: freezed == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String?,
        status: freezed == status
            ? _self.status
            : status // ignore: cast_nullable_to_non_nullable
                  as String?,
        downloadUrl: freezed == downloadUrl
            ? _self.downloadUrl
            : downloadUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        chars: freezed == chars
            ? _self.chars
            : chars // ignore: cast_nullable_to_non_nullable
                  as int?,
        charsProcessed: freezed == charsProcessed
            ? _self.charsProcessed
            : charsProcessed // ignore: cast_nullable_to_non_nullable
                  as int?,
        progressRatio: freezed == progressRatio
            ? _self.progressRatio
            : progressRatio // ignore: cast_nullable_to_non_nullable
                  as double?,
        durationSeconds: freezed == durationSeconds
            ? _self.durationSeconds
            : durationSeconds // ignore: cast_nullable_to_non_nullable
                  as double?,
        startedAt: freezed == startedAt
            ? _self.startedAt
            : startedAt // ignore: cast_nullable_to_non_nullable
                  as double?,
        completedAt: freezed == completedAt
            ? _self.completedAt
            : completedAt // ignore: cast_nullable_to_non_nullable
                  as double?,
        textOffset: freezed == textOffset
            ? _self.textOffset
            : textOffset // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [ChapterProgress].
extension ChapterProgressPatterns on ChapterProgress {
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
    TResult Function(_ChapterProgress value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress() when $default != null:
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
    TResult Function(_ChapterProgress value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress():
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
    TResult? Function(_ChapterProgress value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress() when $default != null:
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
      int index,
      String? name,
      String? status,
      String? downloadUrl,
      int? chars,
      int? charsProcessed,
      double? progressRatio,
      double? durationSeconds,
      double? startedAt,
      double? completedAt,
      int? textOffset,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress() when $default != null:
        return $default(
          _that.index,
          _that.name,
          _that.status,
          _that.downloadUrl,
          _that.chars,
          _that.charsProcessed,
          _that.progressRatio,
          _that.durationSeconds,
          _that.startedAt,
          _that.completedAt,
          _that.textOffset,
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
      int index,
      String? name,
      String? status,
      String? downloadUrl,
      int? chars,
      int? charsProcessed,
      double? progressRatio,
      double? durationSeconds,
      double? startedAt,
      double? completedAt,
      int? textOffset,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress():
        return $default(
          _that.index,
          _that.name,
          _that.status,
          _that.downloadUrl,
          _that.chars,
          _that.charsProcessed,
          _that.progressRatio,
          _that.durationSeconds,
          _that.startedAt,
          _that.completedAt,
          _that.textOffset,
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
      int index,
      String? name,
      String? status,
      String? downloadUrl,
      int? chars,
      int? charsProcessed,
      double? progressRatio,
      double? durationSeconds,
      double? startedAt,
      double? completedAt,
      int? textOffset,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _ChapterProgress() when $default != null:
        return $default(
          _that.index,
          _that.name,
          _that.status,
          _that.downloadUrl,
          _that.chars,
          _that.charsProcessed,
          _that.progressRatio,
          _that.durationSeconds,
          _that.startedAt,
          _that.completedAt,
          _that.textOffset,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _ChapterProgress extends ChapterProgress {
  const _ChapterProgress({
    required this.index,
    this.name,
    this.status,
    this.downloadUrl,
    this.chars,
    this.charsProcessed,
    this.progressRatio,
    this.durationSeconds,
    this.startedAt,
    this.completedAt,
    this.textOffset,
  }) : super._();
  factory _ChapterProgress.fromJson(Map<String, dynamic> json) =>
      _$ChapterProgressFromJson(json);

  @override
  final int index;
  @override
  final String? name;
  @override
  final String? status;
  @override
  final String? downloadUrl;
  @override
  final int? chars;
  @override
  final int? charsProcessed;
  @override
  final double? progressRatio;
  @override
  final double? durationSeconds;
  @override
  final double? startedAt;
  @override
  final double? completedAt;

  /// Unicode scalar offset in the chapter text where this audio starts (a
  /// listening started inside the chapter, e.g. Play from here); 0 or null
  /// for audio of the whole chapter. Mirrors iOS `ChapterProgress.textOffset`.
  @override
  final int? textOffset;

  /// Create a copy of ChapterProgress
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$ChapterProgressCopyWith<_ChapterProgress> get copyWith =>
      __$ChapterProgressCopyWithImpl<_ChapterProgress>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$ChapterProgressToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _ChapterProgress &&
            (identical(other.index, index) || other.index == index) &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.status, status) || other.status == status) &&
            (identical(other.downloadUrl, downloadUrl) ||
                other.downloadUrl == downloadUrl) &&
            (identical(other.chars, chars) || other.chars == chars) &&
            (identical(other.charsProcessed, charsProcessed) ||
                other.charsProcessed == charsProcessed) &&
            (identical(other.progressRatio, progressRatio) ||
                other.progressRatio == progressRatio) &&
            (identical(other.durationSeconds, durationSeconds) ||
                other.durationSeconds == durationSeconds) &&
            (identical(other.startedAt, startedAt) ||
                other.startedAt == startedAt) &&
            (identical(other.completedAt, completedAt) ||
                other.completedAt == completedAt) &&
            (identical(other.textOffset, textOffset) ||
                other.textOffset == textOffset));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      index,
      name,
      status,
      downloadUrl,
      chars,
      charsProcessed,
      progressRatio,
      durationSeconds,
      startedAt,
      completedAt,
      textOffset,
    );
  }

  @override
  String toString() {
    return 'ChapterProgress(index: $index, name: $name, status: $status, downloadUrl: $downloadUrl, chars: $chars, charsProcessed: $charsProcessed, progressRatio: $progressRatio, durationSeconds: $durationSeconds, startedAt: $startedAt, completedAt: $completedAt, textOffset: $textOffset)';
  }
}

/// @nodoc
abstract mixin class _$ChapterProgressCopyWith<$Res>
    implements $ChapterProgressCopyWith<$Res> {
  factory _$ChapterProgressCopyWith(
    _ChapterProgress value,
    $Res Function(_ChapterProgress) _then,
  ) = __$ChapterProgressCopyWithImpl;
  @override
  @useResult
  $Res call({
    int index,
    String? name,
    String? status,
    String? downloadUrl,
    int? chars,
    int? charsProcessed,
    double? progressRatio,
    double? durationSeconds,
    double? startedAt,
    double? completedAt,
    int? textOffset,
  });
}

/// @nodoc
class __$ChapterProgressCopyWithImpl<$Res>
    implements _$ChapterProgressCopyWith<$Res> {
  __$ChapterProgressCopyWithImpl(this._self, this._then);

  final _ChapterProgress _self;
  final $Res Function(_ChapterProgress) _then;

  /// Create a copy of ChapterProgress
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? index = null,
    Object? name = freezed,
    Object? status = freezed,
    Object? downloadUrl = freezed,
    Object? chars = freezed,
    Object? charsProcessed = freezed,
    Object? progressRatio = freezed,
    Object? durationSeconds = freezed,
    Object? startedAt = freezed,
    Object? completedAt = freezed,
    Object? textOffset = freezed,
  }) {
    return _then(
      _ChapterProgress(
        index: null == index
            ? _self.index
            : index // ignore: cast_nullable_to_non_nullable
                  as int,
        name: freezed == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String?,
        status: freezed == status
            ? _self.status
            : status // ignore: cast_nullable_to_non_nullable
                  as String?,
        downloadUrl: freezed == downloadUrl
            ? _self.downloadUrl
            : downloadUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        chars: freezed == chars
            ? _self.chars
            : chars // ignore: cast_nullable_to_non_nullable
                  as int?,
        charsProcessed: freezed == charsProcessed
            ? _self.charsProcessed
            : charsProcessed // ignore: cast_nullable_to_non_nullable
                  as int?,
        progressRatio: freezed == progressRatio
            ? _self.progressRatio
            : progressRatio // ignore: cast_nullable_to_non_nullable
                  as double?,
        durationSeconds: freezed == durationSeconds
            ? _self.durationSeconds
            : durationSeconds // ignore: cast_nullable_to_non_nullable
                  as double?,
        startedAt: freezed == startedAt
            ? _self.startedAt
            : startedAt // ignore: cast_nullable_to_non_nullable
                  as double?,
        completedAt: freezed == completedAt
            ? _self.completedAt
            : completedAt // ignore: cast_nullable_to_non_nullable
                  as double?,
        textOffset: freezed == textOffset
            ? _self.textOffset
            : textOffset // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}
