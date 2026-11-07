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
                other.completedAt == _this.completedAt));
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
    );
  }

  @override
  String toString() {
    final _this = this as ChapterProgress;
    return 'ChapterProgress(index: ${_this.index}, name: ${_this.name}, status: ${_this.status}, downloadUrl: ${_this.downloadUrl}, chars: ${_this.chars}, charsProcessed: ${_this.charsProcessed}, progressRatio: ${_this.progressRatio}, durationSeconds: ${_this.durationSeconds}, startedAt: ${_this.startedAt}, completedAt: ${_this.completedAt})';
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
                other.completedAt == completedAt));
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
    );
  }

  @override
  String toString() {
    return 'ChapterProgress(index: $index, name: $name, status: $status, downloadUrl: $downloadUrl, chars: $chars, charsProcessed: $charsProcessed, progressRatio: $progressRatio, durationSeconds: $durationSeconds, startedAt: $startedAt, completedAt: $completedAt)';
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
      ),
    );
  }
}

/// @nodoc
mixin _$OutputAsset {
  String get name;
  String get url;
  int? get sizeBytes;

  /// Create a copy of OutputAsset
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $OutputAssetCopyWith<OutputAsset> get copyWith =>
      _$OutputAssetCopyWithImpl<OutputAsset>(this as OutputAsset, _$identity);

  /// Serializes this OutputAsset to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as OutputAsset;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is OutputAsset &&
            (identical(other.name, _this.name) || other.name == _this.name) &&
            (identical(other.url, _this.url) || other.url == _this.url) &&
            (identical(other.sizeBytes, _this.sizeBytes) ||
                other.sizeBytes == _this.sizeBytes));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as OutputAsset;
    return Object.hash(runtimeType, _this.name, _this.url, _this.sizeBytes);
  }

  @override
  String toString() {
    final _this = this as OutputAsset;
    return 'OutputAsset(name: ${_this.name}, url: ${_this.url}, sizeBytes: ${_this.sizeBytes})';
  }
}

/// @nodoc
abstract mixin class $OutputAssetCopyWith<$Res> {
  factory $OutputAssetCopyWith(
    OutputAsset value,
    $Res Function(OutputAsset) _then,
  ) = _$OutputAssetCopyWithImpl;
  @useResult
  $Res call({String name, String url, int? sizeBytes});
}

/// @nodoc
class _$OutputAssetCopyWithImpl<$Res> implements $OutputAssetCopyWith<$Res> {
  _$OutputAssetCopyWithImpl(this._self, this._then);

  final OutputAsset _self;
  final $Res Function(OutputAsset) _then;

  /// Create a copy of OutputAsset
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? name = null,
    Object? url = null,
    Object? sizeBytes = freezed,
  }) {
    return _then(
      OutputAsset(
        name: null == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        url: null == url
            ? _self.url
            : url // ignore: cast_nullable_to_non_nullable
                  as String,
        sizeBytes: freezed == sizeBytes
            ? _self.sizeBytes
            : sizeBytes // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [OutputAsset].
extension OutputAssetPatterns on OutputAsset {
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
    TResult Function(_OutputAsset value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _OutputAsset() when $default != null:
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
    TResult Function(_OutputAsset value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _OutputAsset():
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
    TResult? Function(_OutputAsset value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _OutputAsset() when $default != null:
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
    TResult Function(String name, String url, int? sizeBytes)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _OutputAsset() when $default != null:
        return $default(_that.name, _that.url, _that.sizeBytes);
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
    TResult Function(String name, String url, int? sizeBytes) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _OutputAsset():
        return $default(_that.name, _that.url, _that.sizeBytes);
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
    TResult? Function(String name, String url, int? sizeBytes)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _OutputAsset() when $default != null:
        return $default(_that.name, _that.url, _that.sizeBytes);
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _OutputAsset extends OutputAsset {
  const _OutputAsset({required this.name, required this.url, this.sizeBytes})
    : super._();
  factory _OutputAsset.fromJson(Map<String, dynamic> json) =>
      _$OutputAssetFromJson(json);

  @override
  final String name;
  @override
  final String url;
  @override
  final int? sizeBytes;

  /// Create a copy of OutputAsset
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$OutputAssetCopyWith<_OutputAsset> get copyWith =>
      __$OutputAssetCopyWithImpl<_OutputAsset>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$OutputAssetToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _OutputAsset &&
            (identical(other.name, name) || other.name == name) &&
            (identical(other.url, url) || other.url == url) &&
            (identical(other.sizeBytes, sizeBytes) ||
                other.sizeBytes == sizeBytes));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(runtimeType, name, url, sizeBytes);
  }

  @override
  String toString() {
    return 'OutputAsset(name: $name, url: $url, sizeBytes: $sizeBytes)';
  }
}

/// @nodoc
abstract mixin class _$OutputAssetCopyWith<$Res>
    implements $OutputAssetCopyWith<$Res> {
  factory _$OutputAssetCopyWith(
    _OutputAsset value,
    $Res Function(_OutputAsset) _then,
  ) = __$OutputAssetCopyWithImpl;
  @override
  @useResult
  $Res call({String name, String url, int? sizeBytes});
}

/// @nodoc
class __$OutputAssetCopyWithImpl<$Res> implements _$OutputAssetCopyWith<$Res> {
  __$OutputAssetCopyWithImpl(this._self, this._then);

  final _OutputAsset _self;
  final $Res Function(_OutputAsset) _then;

  /// Create a copy of OutputAsset
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? name = null,
    Object? url = null,
    Object? sizeBytes = freezed,
  }) {
    return _then(
      _OutputAsset(
        name: null == name
            ? _self.name
            : name // ignore: cast_nullable_to_non_nullable
                  as String,
        url: null == url
            ? _self.url
            : url // ignore: cast_nullable_to_non_nullable
                  as String,
        sizeBytes: freezed == sizeBytes
            ? _self.sizeBytes
            : sizeBytes // ignore: cast_nullable_to_non_nullable
                  as int?,
      ),
    );
  }
}

/// @nodoc
mixin _$JobSnapshot {
  String get jobId;
  String get state;
  String? get bookTitle;
  String? get bookAuthor;
  String? get coverUrl;
  String? get coverMimeType;
  String? get engine;
  String? get voice;
  String? get language;
  double? get progressPercent;
  int? get chaptersTotal;
  int? get chaptersCompleted;
  List<ChapterProgress>? get chapterProgress;
  List<OutputAsset>? get outputs;
  String? get logUrl;
  String? get error;
  double? get lastActivityAt;

  /// Create a copy of JobSnapshot
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  $JobSnapshotCopyWith<JobSnapshot> get copyWith =>
      _$JobSnapshotCopyWithImpl<JobSnapshot>(this as JobSnapshot, _$identity);

  /// Serializes this JobSnapshot to a JSON map.
  Map<String, dynamic> toJson();

  @override
  bool operator ==(Object other) {
    final _this = this as JobSnapshot;
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is JobSnapshot &&
            (identical(other.jobId, _this.jobId) ||
                other.jobId == _this.jobId) &&
            (identical(other.state, _this.state) ||
                other.state == _this.state) &&
            (identical(other.bookTitle, _this.bookTitle) ||
                other.bookTitle == _this.bookTitle) &&
            (identical(other.bookAuthor, _this.bookAuthor) ||
                other.bookAuthor == _this.bookAuthor) &&
            (identical(other.coverUrl, _this.coverUrl) ||
                other.coverUrl == _this.coverUrl) &&
            (identical(other.coverMimeType, _this.coverMimeType) ||
                other.coverMimeType == _this.coverMimeType) &&
            (identical(other.engine, _this.engine) ||
                other.engine == _this.engine) &&
            (identical(other.voice, _this.voice) ||
                other.voice == _this.voice) &&
            (identical(other.language, _this.language) ||
                other.language == _this.language) &&
            (identical(other.progressPercent, _this.progressPercent) ||
                other.progressPercent == _this.progressPercent) &&
            (identical(other.chaptersTotal, _this.chaptersTotal) ||
                other.chaptersTotal == _this.chaptersTotal) &&
            (identical(other.chaptersCompleted, _this.chaptersCompleted) ||
                other.chaptersCompleted == _this.chaptersCompleted) &&
            const DeepCollectionEquality().equals(
              other.chapterProgress,
              _this.chapterProgress,
            ) &&
            const DeepCollectionEquality().equals(
              other.outputs,
              _this.outputs,
            ) &&
            (identical(other.logUrl, _this.logUrl) ||
                other.logUrl == _this.logUrl) &&
            (identical(other.error, _this.error) ||
                other.error == _this.error) &&
            (identical(other.lastActivityAt, _this.lastActivityAt) ||
                other.lastActivityAt == _this.lastActivityAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    final _this = this as JobSnapshot;
    return Object.hash(
      runtimeType,
      _this.jobId,
      _this.state,
      _this.bookTitle,
      _this.bookAuthor,
      _this.coverUrl,
      _this.coverMimeType,
      _this.engine,
      _this.voice,
      _this.language,
      _this.progressPercent,
      _this.chaptersTotal,
      _this.chaptersCompleted,
      const DeepCollectionEquality().hash(_this.chapterProgress),
      const DeepCollectionEquality().hash(_this.outputs),
      _this.logUrl,
      _this.error,
      _this.lastActivityAt,
    );
  }

  @override
  String toString() {
    final _this = this as JobSnapshot;
    return 'JobSnapshot(jobId: ${_this.jobId}, state: ${_this.state}, bookTitle: ${_this.bookTitle}, bookAuthor: ${_this.bookAuthor}, coverUrl: ${_this.coverUrl}, coverMimeType: ${_this.coverMimeType}, engine: ${_this.engine}, voice: ${_this.voice}, language: ${_this.language}, progressPercent: ${_this.progressPercent}, chaptersTotal: ${_this.chaptersTotal}, chaptersCompleted: ${_this.chaptersCompleted}, chapterProgress: ${_this.chapterProgress}, outputs: ${_this.outputs}, logUrl: ${_this.logUrl}, error: ${_this.error}, lastActivityAt: ${_this.lastActivityAt})';
  }
}

/// @nodoc
abstract mixin class $JobSnapshotCopyWith<$Res> {
  factory $JobSnapshotCopyWith(
    JobSnapshot value,
    $Res Function(JobSnapshot) _then,
  ) = _$JobSnapshotCopyWithImpl;
  @useResult
  $Res call({
    String jobId,
    String state,
    String? bookTitle,
    String? bookAuthor,
    String? coverUrl,
    String? coverMimeType,
    String? engine,
    String? voice,
    String? language,
    double? progressPercent,
    int? chaptersTotal,
    int? chaptersCompleted,
    List<ChapterProgress>? chapterProgress,
    List<OutputAsset>? outputs,
    String? logUrl,
    String? error,
    double? lastActivityAt,
  });
}

/// @nodoc
class _$JobSnapshotCopyWithImpl<$Res> implements $JobSnapshotCopyWith<$Res> {
  _$JobSnapshotCopyWithImpl(this._self, this._then);

  final JobSnapshot _self;
  final $Res Function(JobSnapshot) _then;

  /// Create a copy of JobSnapshot
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? jobId = null,
    Object? state = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? coverUrl = freezed,
    Object? coverMimeType = freezed,
    Object? engine = freezed,
    Object? voice = freezed,
    Object? language = freezed,
    Object? progressPercent = freezed,
    Object? chaptersTotal = freezed,
    Object? chaptersCompleted = freezed,
    Object? chapterProgress = freezed,
    Object? outputs = freezed,
    Object? logUrl = freezed,
    Object? error = freezed,
    Object? lastActivityAt = freezed,
  }) {
    return _then(
      JobSnapshot(
        jobId: null == jobId
            ? _self.jobId
            : jobId // ignore: cast_nullable_to_non_nullable
                  as String,
        state: null == state
            ? _self.state
            : state // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: freezed == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookAuthor: freezed == bookAuthor
            ? _self.bookAuthor
            : bookAuthor // ignore: cast_nullable_to_non_nullable
                  as String?,
        coverUrl: freezed == coverUrl
            ? _self.coverUrl
            : coverUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        coverMimeType: freezed == coverMimeType
            ? _self.coverMimeType
            : coverMimeType // ignore: cast_nullable_to_non_nullable
                  as String?,
        engine: freezed == engine
            ? _self.engine
            : engine // ignore: cast_nullable_to_non_nullable
                  as String?,
        voice: freezed == voice
            ? _self.voice
            : voice // ignore: cast_nullable_to_non_nullable
                  as String?,
        language: freezed == language
            ? _self.language
            : language // ignore: cast_nullable_to_non_nullable
                  as String?,
        progressPercent: freezed == progressPercent
            ? _self.progressPercent
            : progressPercent // ignore: cast_nullable_to_non_nullable
                  as double?,
        chaptersTotal: freezed == chaptersTotal
            ? _self.chaptersTotal
            : chaptersTotal // ignore: cast_nullable_to_non_nullable
                  as int?,
        chaptersCompleted: freezed == chaptersCompleted
            ? _self.chaptersCompleted
            : chaptersCompleted // ignore: cast_nullable_to_non_nullable
                  as int?,
        chapterProgress: freezed == chapterProgress
            ? _self.chapterProgress
            : chapterProgress // ignore: cast_nullable_to_non_nullable
                  as List<ChapterProgress>?,
        outputs: freezed == outputs
            ? _self.outputs
            : outputs // ignore: cast_nullable_to_non_nullable
                  as List<OutputAsset>?,
        logUrl: freezed == logUrl
            ? _self.logUrl
            : logUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        error: freezed == error
            ? _self.error
            : error // ignore: cast_nullable_to_non_nullable
                  as String?,
        lastActivityAt: freezed == lastActivityAt
            ? _self.lastActivityAt
            : lastActivityAt // ignore: cast_nullable_to_non_nullable
                  as double?,
      ),
    );
  }
}

/// Adds pattern-matching-related methods to [JobSnapshot].
extension JobSnapshotPatterns on JobSnapshot {
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
    TResult Function(_JobSnapshot value)? $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot() when $default != null:
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
    TResult Function(_JobSnapshot value) $default,
  ) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot():
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
    TResult? Function(_JobSnapshot value)? $default,
  ) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot() when $default != null:
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
      String jobId,
      String state,
      String? bookTitle,
      String? bookAuthor,
      String? coverUrl,
      String? coverMimeType,
      String? engine,
      String? voice,
      String? language,
      double? progressPercent,
      int? chaptersTotal,
      int? chaptersCompleted,
      List<ChapterProgress>? chapterProgress,
      List<OutputAsset>? outputs,
      String? logUrl,
      String? error,
      double? lastActivityAt,
    )?
    $default, {
    required TResult orElse(),
  }) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot() when $default != null:
        return $default(
          _that.jobId,
          _that.state,
          _that.bookTitle,
          _that.bookAuthor,
          _that.coverUrl,
          _that.coverMimeType,
          _that.engine,
          _that.voice,
          _that.language,
          _that.progressPercent,
          _that.chaptersTotal,
          _that.chaptersCompleted,
          _that.chapterProgress,
          _that.outputs,
          _that.logUrl,
          _that.error,
          _that.lastActivityAt,
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
      String jobId,
      String state,
      String? bookTitle,
      String? bookAuthor,
      String? coverUrl,
      String? coverMimeType,
      String? engine,
      String? voice,
      String? language,
      double? progressPercent,
      int? chaptersTotal,
      int? chaptersCompleted,
      List<ChapterProgress>? chapterProgress,
      List<OutputAsset>? outputs,
      String? logUrl,
      String? error,
      double? lastActivityAt,
    )
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot():
        return $default(
          _that.jobId,
          _that.state,
          _that.bookTitle,
          _that.bookAuthor,
          _that.coverUrl,
          _that.coverMimeType,
          _that.engine,
          _that.voice,
          _that.language,
          _that.progressPercent,
          _that.chaptersTotal,
          _that.chaptersCompleted,
          _that.chapterProgress,
          _that.outputs,
          _that.logUrl,
          _that.error,
          _that.lastActivityAt,
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
      String jobId,
      String state,
      String? bookTitle,
      String? bookAuthor,
      String? coverUrl,
      String? coverMimeType,
      String? engine,
      String? voice,
      String? language,
      double? progressPercent,
      int? chaptersTotal,
      int? chaptersCompleted,
      List<ChapterProgress>? chapterProgress,
      List<OutputAsset>? outputs,
      String? logUrl,
      String? error,
      double? lastActivityAt,
    )?
    $default,
  ) {
    final _that = this;
    switch (_that) {
      case _JobSnapshot() when $default != null:
        return $default(
          _that.jobId,
          _that.state,
          _that.bookTitle,
          _that.bookAuthor,
          _that.coverUrl,
          _that.coverMimeType,
          _that.engine,
          _that.voice,
          _that.language,
          _that.progressPercent,
          _that.chaptersTotal,
          _that.chaptersCompleted,
          _that.chapterProgress,
          _that.outputs,
          _that.logUrl,
          _that.error,
          _that.lastActivityAt,
        );
      case _:
        return null;
    }
  }
}

/// @nodoc
@JsonSerializable()
class _JobSnapshot extends JobSnapshot {
  const _JobSnapshot({
    required this.jobId,
    required this.state,
    this.bookTitle,
    this.bookAuthor,
    this.coverUrl,
    this.coverMimeType,
    this.engine,
    this.voice,
    this.language,
    this.progressPercent,
    this.chaptersTotal,
    this.chaptersCompleted,
    List<ChapterProgress>? chapterProgress,
    List<OutputAsset>? outputs,
    this.logUrl,
    this.error,
    this.lastActivityAt,
  }) : _chapterProgress = chapterProgress,
       _outputs = outputs,
       super._();
  factory _JobSnapshot.fromJson(Map<String, dynamic> json) =>
      _$JobSnapshotFromJson(json);

  @override
  final String jobId;
  @override
  final String state;
  @override
  final String? bookTitle;
  @override
  final String? bookAuthor;
  @override
  final String? coverUrl;
  @override
  final String? coverMimeType;
  @override
  final String? engine;
  @override
  final String? voice;
  @override
  final String? language;
  @override
  final double? progressPercent;
  @override
  final int? chaptersTotal;
  @override
  final int? chaptersCompleted;
  final List<ChapterProgress>? _chapterProgress;
  @override
  List<ChapterProgress>? get chapterProgress {
    final value = _chapterProgress;
    if (value == null) return null;
    if (_chapterProgress is EqualUnmodifiableListView) return _chapterProgress;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  final List<OutputAsset>? _outputs;
  @override
  List<OutputAsset>? get outputs {
    final value = _outputs;
    if (value == null) return null;
    if (_outputs is EqualUnmodifiableListView) return _outputs;
    // ignore: implicit_dynamic_type
    return EqualUnmodifiableListView(value);
  }

  @override
  final String? logUrl;
  @override
  final String? error;
  @override
  final double? lastActivityAt;

  /// Create a copy of JobSnapshot
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  @pragma('vm:prefer-inline')
  _$JobSnapshotCopyWith<_JobSnapshot> get copyWith =>
      __$JobSnapshotCopyWithImpl<_JobSnapshot>(this, _$identity);

  @override
  Map<String, dynamic> toJson() {
    return _$JobSnapshotToJson(this);
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _JobSnapshot &&
            (identical(other.jobId, jobId) || other.jobId == jobId) &&
            (identical(other.state, state) || other.state == state) &&
            (identical(other.bookTitle, bookTitle) ||
                other.bookTitle == bookTitle) &&
            (identical(other.bookAuthor, bookAuthor) ||
                other.bookAuthor == bookAuthor) &&
            (identical(other.coverUrl, coverUrl) ||
                other.coverUrl == coverUrl) &&
            (identical(other.coverMimeType, coverMimeType) ||
                other.coverMimeType == coverMimeType) &&
            (identical(other.engine, engine) || other.engine == engine) &&
            (identical(other.voice, voice) || other.voice == voice) &&
            (identical(other.language, language) ||
                other.language == language) &&
            (identical(other.progressPercent, progressPercent) ||
                other.progressPercent == progressPercent) &&
            (identical(other.chaptersTotal, chaptersTotal) ||
                other.chaptersTotal == chaptersTotal) &&
            (identical(other.chaptersCompleted, chaptersCompleted) ||
                other.chaptersCompleted == chaptersCompleted) &&
            const DeepCollectionEquality().equals(
              other.chapterProgress,
              _chapterProgress,
            ) &&
            const DeepCollectionEquality().equals(other.outputs, _outputs) &&
            (identical(other.logUrl, logUrl) || other.logUrl == logUrl) &&
            (identical(other.error, error) || other.error == error) &&
            (identical(other.lastActivityAt, lastActivityAt) ||
                other.lastActivityAt == lastActivityAt));
  }

  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  int get hashCode {
    return Object.hash(
      runtimeType,
      jobId,
      state,
      bookTitle,
      bookAuthor,
      coverUrl,
      coverMimeType,
      engine,
      voice,
      language,
      progressPercent,
      chaptersTotal,
      chaptersCompleted,
      const DeepCollectionEquality().hash(_chapterProgress),
      const DeepCollectionEquality().hash(_outputs),
      logUrl,
      error,
      lastActivityAt,
    );
  }

  @override
  String toString() {
    return 'JobSnapshot(jobId: $jobId, state: $state, bookTitle: $bookTitle, bookAuthor: $bookAuthor, coverUrl: $coverUrl, coverMimeType: $coverMimeType, engine: $engine, voice: $voice, language: $language, progressPercent: $progressPercent, chaptersTotal: $chaptersTotal, chaptersCompleted: $chaptersCompleted, chapterProgress: $chapterProgress, outputs: $outputs, logUrl: $logUrl, error: $error, lastActivityAt: $lastActivityAt)';
  }
}

/// @nodoc
abstract mixin class _$JobSnapshotCopyWith<$Res>
    implements $JobSnapshotCopyWith<$Res> {
  factory _$JobSnapshotCopyWith(
    _JobSnapshot value,
    $Res Function(_JobSnapshot) _then,
  ) = __$JobSnapshotCopyWithImpl;
  @override
  @useResult
  $Res call({
    String jobId,
    String state,
    String? bookTitle,
    String? bookAuthor,
    String? coverUrl,
    String? coverMimeType,
    String? engine,
    String? voice,
    String? language,
    double? progressPercent,
    int? chaptersTotal,
    int? chaptersCompleted,
    List<ChapterProgress>? chapterProgress,
    List<OutputAsset>? outputs,
    String? logUrl,
    String? error,
    double? lastActivityAt,
  });
}

/// @nodoc
class __$JobSnapshotCopyWithImpl<$Res> implements _$JobSnapshotCopyWith<$Res> {
  __$JobSnapshotCopyWithImpl(this._self, this._then);

  final _JobSnapshot _self;
  final $Res Function(_JobSnapshot) _then;

  /// Create a copy of JobSnapshot
  /// with the given fields replaced by the non-null parameter values.
  @override
  @pragma('vm:prefer-inline')
  $Res call({
    Object? jobId = null,
    Object? state = null,
    Object? bookTitle = freezed,
    Object? bookAuthor = freezed,
    Object? coverUrl = freezed,
    Object? coverMimeType = freezed,
    Object? engine = freezed,
    Object? voice = freezed,
    Object? language = freezed,
    Object? progressPercent = freezed,
    Object? chaptersTotal = freezed,
    Object? chaptersCompleted = freezed,
    Object? chapterProgress = freezed,
    Object? outputs = freezed,
    Object? logUrl = freezed,
    Object? error = freezed,
    Object? lastActivityAt = freezed,
  }) {
    return _then(
      _JobSnapshot(
        jobId: null == jobId
            ? _self.jobId
            : jobId // ignore: cast_nullable_to_non_nullable
                  as String,
        state: null == state
            ? _self.state
            : state // ignore: cast_nullable_to_non_nullable
                  as String,
        bookTitle: freezed == bookTitle
            ? _self.bookTitle
            : bookTitle // ignore: cast_nullable_to_non_nullable
                  as String?,
        bookAuthor: freezed == bookAuthor
            ? _self.bookAuthor
            : bookAuthor // ignore: cast_nullable_to_non_nullable
                  as String?,
        coverUrl: freezed == coverUrl
            ? _self.coverUrl
            : coverUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        coverMimeType: freezed == coverMimeType
            ? _self.coverMimeType
            : coverMimeType // ignore: cast_nullable_to_non_nullable
                  as String?,
        engine: freezed == engine
            ? _self.engine
            : engine // ignore: cast_nullable_to_non_nullable
                  as String?,
        voice: freezed == voice
            ? _self.voice
            : voice // ignore: cast_nullable_to_non_nullable
                  as String?,
        language: freezed == language
            ? _self.language
            : language // ignore: cast_nullable_to_non_nullable
                  as String?,
        progressPercent: freezed == progressPercent
            ? _self.progressPercent
            : progressPercent // ignore: cast_nullable_to_non_nullable
                  as double?,
        chaptersTotal: freezed == chaptersTotal
            ? _self.chaptersTotal
            : chaptersTotal // ignore: cast_nullable_to_non_nullable
                  as int?,
        chaptersCompleted: freezed == chaptersCompleted
            ? _self.chaptersCompleted
            : chaptersCompleted // ignore: cast_nullable_to_non_nullable
                  as int?,
        chapterProgress: freezed == chapterProgress
            ? _self._chapterProgress
            : chapterProgress // ignore: cast_nullable_to_non_nullable
                  as List<ChapterProgress>?,
        outputs: freezed == outputs
            ? _self._outputs
            : outputs // ignore: cast_nullable_to_non_nullable
                  as List<OutputAsset>?,
        logUrl: freezed == logUrl
            ? _self.logUrl
            : logUrl // ignore: cast_nullable_to_non_nullable
                  as String?,
        error: freezed == error
            ? _self.error
            : error // ignore: cast_nullable_to_non_nullable
                  as String?,
        lastActivityAt: freezed == lastActivityAt
            ? _self.lastActivityAt
            : lastActivityAt // ignore: cast_nullable_to_non_nullable
                  as double?,
      ),
    );
  }
}
